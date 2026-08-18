package com.friend.ios.audiodecoder

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes audio files with Android's own codecs, on demand.
 *
 * The whole reason this exists is that nothing in the Omi app can read an `.m4a` — the
 * existing transcoders handle only the PCM and Opus its own hardware produces. Android
 * already ships hardware-accelerated decoders for every format a consumer voice recorder
 * emits, so this reaches those rather than adding a decoding library to the app.
 *
 * **Pull-based on purpose.** Nothing is decoded until [readChunk] asks for it. A decoder
 * that ran ahead as fast as it could would put an entire recording in memory while
 * transcription was still near the beginning, which is the failure SC-005 exists to
 * prevent. Letting the caller set the pace is what keeps peak memory flat with respect
 * to how long the recording is.
 */
class AudioDecoderPlugin : AudioDecoderHostApi {

    private val sessions = HashMap<Long, DecodeSession>()

    override fun probe(filePath: String): AudioProbeResult {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(filePath)
        } catch (error: Exception) {
            throw AudioDecoderPigeonError("file_unreadable", error.message ?: "cannot open", null)
        }

        try {
            val trackIndex = findAudioTrack(extractor)
                ?: return AudioProbeResult(false, 0.0, 0, 0, null, "no audio track", null)
            return describeTrack(extractor.getTrackFormat(trackIndex), filePath)
        } finally {
            extractor.release()
        }
    }

    override fun openSession(filePath: String, sessionId: Long) {
        closeSession(sessionId)
        sessions[sessionId] = DecodeSession.open(filePath)
    }

    override fun readChunk(sessionId: Long, maxBytes: Long): ByteArray {
        val session = sessions[sessionId] ?: return ByteArray(0)
        return session.read(maxBytes.toInt())
    }

    override fun closeSession(sessionId: Long) {
        sessions.remove(sessionId)?.release()
    }

    /** Reads what a track is, without committing to decoding it. */
    private fun describeTrack(format: MediaFormat, filePath: String): AudioProbeResult {
        val durationSeconds = if (format.containsKey(MediaFormat.KEY_DURATION)) {
            format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0
        } else {
            0.0
        }
        return AudioProbeResult(
            true,
            durationSeconds,
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE, 0).toLong(),
            format.getInteger(MediaFormat.KEY_CHANNEL_COUNT, 0).toLong(),
            format.getString(MediaFormat.KEY_MIME),
            null,
            readCreationEpochMillis(filePath),
        )
    }

    /**
     * Reads the recording date written inside the file, or null if there is none.
     *
     * `MediaExtractor` does not expose this, so it takes a second reader. Worth the
     * extra open: this is the only evidence of when a recording was made that survives
     * being copied, shared or re-exported, and every other source is a guess by
     * comparison.
     *
     * Never throws. A missing or unparseable date is the ordinary case, not a failure —
     * plenty of recorders write none — and refusing an import over it would be absurd.
     */
    private fun readCreationEpochMillis(filePath: String): Long? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(filePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE)?.let(::parseIso8601Basic)
        } catch (error: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    /**
     * Parses the compact timestamp Android reports, e.g. `20260805T143022.000Z`.
     *
     * Hand-parsed rather than handed to a formatter because the field is not reliably
     * well-formed across devices, and a lenient reader that returns null beats one that
     * throws inside a probe.
     */
    private fun parseIso8601Basic(raw: String): Long? {
        val match = Regex("""(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})""").find(raw) ?: return null
        val (year, month, day, hour, minute, second) = match.destructured
        return try {
            java.util.GregorianCalendar(
                java.util.TimeZone.getTimeZone("UTC"),
            ).apply {
                clear()
                set(year.toInt(), month.toInt() - 1, day.toInt(), hour.toInt(), minute.toInt(), second.toInt())
            }.timeInMillis
        } catch (error: Exception) {
            null
        }
    }

    internal companion object {
        /** How long to wait on a codec buffer. Short, so cancellation stays responsive. */
        const val CODEC_TIMEOUT_MICROSECONDS = 10_000L

        /** Finds the first audio track, or null when the file has none. */
        fun findAudioTrack(extractor: MediaExtractor): Int? {
            for (index in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                if (mime?.startsWith("audio/") == true) return index
            }
            return null
        }
    }
}

/**
 * One file open for decoding, with its extractor, codec and resampler.
 *
 * Holds a hardware codec, so it must always be released — including on failure. That is
 * why the Dart wrapper's `close()` tolerates being called on a session that already
 * finished: the cleanup path must not have to know how the session ended.
 */
internal class DecodeSession private constructor(
    private val extractor: MediaExtractor,
    private val codec: MediaCodec,
) {
    private val pending = ByteArrayOutputStream()
    private var resampler: PcmResampler? = null
    private var hasSeenInputEnd = false
    private var hasSeenOutputEnd = false
    private var hasDrained = false

    /** Decodes until [maxBytes] of output are ready, or the recording ends. */
    fun read(maxBytes: Int): ByteArray {
        while (pending.size() < maxBytes && !hasSeenOutputEnd) {
            feedInput()
            drainOutput()
        }
        if (hasSeenOutputEnd && !hasDrained) {
            hasDrained = true
            resampler?.drain()?.let { appendSamples(it) }
        }
        return takePending(maxBytes)
    }

    /** Releases the codec and extractor. Safe to call more than once. */
    fun release() {
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { extractor.release() }
    }

    /** Hands the codec the next compressed sample, or tells it the input has ended. */
    private fun feedInput() {
        if (hasSeenInputEnd) return
        val index = codec.dequeueInputBuffer(AudioDecoderPlugin.CODEC_TIMEOUT_MICROSECONDS)
        if (index < 0) return

        val buffer = codec.getInputBuffer(index) ?: return
        val sampleSize = extractor.readSampleData(buffer, 0)
        if (sampleSize < 0) {
            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            hasSeenInputEnd = true
            return
        }
        codec.queueInputBuffer(index, 0, sampleSize, extractor.sampleTime, 0)
        extractor.advance()
    }

    /** Takes whatever the codec has produced and converts it to the pipeline's shape. */
    private fun drainOutput() {
        val info = MediaCodec.BufferInfo()
        val index = codec.dequeueOutputBuffer(info, AudioDecoderPlugin.CODEC_TIMEOUT_MICROSECONDS)

        if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            adoptOutputFormat(codec.outputFormat)
            return
        }
        if (index < 0) return

        if (info.size > 0) {
            convertAndAppend(codec.getOutputBuffer(index), info)
        }
        codec.releaseOutputBuffer(index, false)
        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
            hasSeenOutputEnd = true
        }
    }

    /**
     * Builds the resampler from the *output* format.
     *
     * The output format is the one that matters and it is not always the input format —
     * a decoder may report the track's rate up front and then produce something else.
     * Building the resampler from the input format is a bug that only shows on the
     * devices where the two differ.
     */
    private fun adoptOutputFormat(format: MediaFormat) {
        val encoding = format.getInteger(MediaFormat.KEY_PCM_ENCODING, ENCODING_PCM_16BIT)
        if (encoding != ENCODING_PCM_16BIT) {
            throw AudioDecoderPigeonError(
                "decoder_init_failed",
                "decoder produced an unsupported sample format",
                null,
            )
        }
        resampler = PcmResampler(
            sourceSampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
            sourceChannelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
        )
    }

    /** Converts one codec output buffer into 16 kHz mono PCM16 and queues it. */
    private fun convertAndAppend(buffer: ByteBuffer?, info: MediaCodec.BufferInfo) {
        val active = resampler ?: return
        if (buffer == null) return

        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val shorts = ShortArray(info.size / 2)
        buffer.order(ByteOrder.nativeOrder()).asShortBuffer().get(shorts)

        appendSamples(active.process(shorts, shorts.size))
    }

    /** Writes converted samples to the pending queue as little-endian bytes. */
    private fun appendSamples(samples: ShortArray) {
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) bytes.putShort(sample)
        pending.write(bytes.array())
    }

    /** Removes and returns up to [maxBytes] from the pending queue. */
    private fun takePending(maxBytes: Int): ByteArray {
        val available = pending.toByteArray()
        val takeCount = minOf(maxBytes, available.size)
        pending.reset()
        if (takeCount < available.size) {
            pending.write(available, takeCount, available.size - takeCount)
        }
        return available.copyOfRange(0, takeCount)
    }

    companion object {
        /** `AudioFormat.ENCODING_PCM_16BIT`, restated to keep this file free of that import. */
        private const val ENCODING_PCM_16BIT = 2

        /** Opens a file and starts its decoder. */
        fun open(filePath: String): DecodeSession {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(filePath)
            } catch (error: Exception) {
                extractor.release()
                throw AudioDecoderPigeonError("file_unreadable", error.message ?: "cannot open", null)
            }

            val trackIndex = AudioDecoderPlugin.findAudioTrack(extractor)
            if (trackIndex == null) {
                extractor.release()
                throw AudioDecoderPigeonError("no_audio_track", "the file contains no audio", null)
            }
            return startCodec(extractor, trackIndex)
        }

        /** Selects the track and starts a decoder for it. */
        private fun startCodec(extractor: MediaExtractor, trackIndex: Int): DecodeSession {
            extractor.selectTrack(trackIndex)
            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw AudioDecoderPigeonError("format_unsupported", "unknown codec", null)

            return try {
                val codec = MediaCodec.createDecoderByType(mime)
                codec.configure(format, null, null, 0)
                codec.start()
                DecodeSession(extractor, codec)
            } catch (error: Exception) {
                extractor.release()
                throw AudioDecoderPigeonError("format_unsupported", error.message ?: mime, null)
            }
        }
    }
}
