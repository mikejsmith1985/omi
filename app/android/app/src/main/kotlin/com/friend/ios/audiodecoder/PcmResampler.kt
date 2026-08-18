package com.friend.ios.audiodecoder

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Converts decoded PCM to the single shape the transcription pipeline accepts:
 * 16 kHz, mono, signed 16-bit.
 *
 * Why this is not just "take every third sample": a recording at 48 kHz carries sound
 * up to 24 kHz, and dropping samples to reach 16 kHz folds everything above 8 kHz back
 * down into the speech band as noise that was never there. Aliasing of that kind does
 * not sound like distortion so much as a slightly worse microphone, which is exactly
 * the failure that would show up as an unexplained drop in transcript quality against
 * SC-004 and be blamed on the engine instead of on us.
 *
 * So the order is: downmix to mono, low-pass below the new Nyquist limit, and only then
 * change the rate. The filter is a windowed sinc — the textbook answer, cheap enough at
 * these rates, and it keeps its history between calls so chunk boundaries introduce no
 * discontinuity (contract obligation P-2 depends on that holding).
 */
internal class PcmResampler(
    private val sourceSampleRate: Int,
    private val sourceChannelCount: Int,
    private val targetSampleRate: Int = TARGET_SAMPLE_RATE,
) {
    private val filterTaps: FloatArray = buildLowPassTaps()
    private val filterHistory = FloatArray(filterTaps.size)
    private var historyPosition = 0

    /** Fractional read position into the filtered stream, carried across chunks. */
    private var resamplePosition = 0.0

    /** The last filtered sample of the previous chunk, so interpolation spans the join. */
    private var previousFilteredSample = 0.0f
    private var hasPreviousSample = false

    /** Converts one chunk of interleaved source PCM into 16 kHz mono PCM16. */
    fun process(interleaved: ShortArray, sampleCount: Int): ShortArray {
        if (sampleCount <= 0) return ShortArray(0)
        val mono = downmixToMono(interleaved, sampleCount)
        val filtered = applyLowPass(mono)
        return changeRate(filtered)
    }

    /**
     * Emits the tail still inside the filter.
     *
     * Without this the last few milliseconds of every recording are silently discarded —
     * a small enough loss to go unnoticed in testing and large enough to clip the final
     * word of a conversation.
     */
    fun drain(): ShortArray {
        val flushLength = filterTaps.size
        return process(ShortArray(flushLength * sourceChannelCount), flushLength * sourceChannelCount)
    }

    /** Averages the channels, because a transcript needs one voice stream, not two. */
    private fun downmixToMono(interleaved: ShortArray, sampleCount: Int): FloatArray {
        if (sourceChannelCount == 1) {
            return FloatArray(sampleCount) { interleaved[it].toFloat() }
        }
        val frameCount = sampleCount / sourceChannelCount
        val mono = FloatArray(frameCount)
        for (frame in 0 until frameCount) {
            var sum = 0f
            val base = frame * sourceChannelCount
            for (channel in 0 until sourceChannelCount) {
                sum += interleaved[base + channel].toFloat()
            }
            mono[frame] = sum / sourceChannelCount
        }
        return mono
    }

    /** Runs the windowed-sinc low-pass, carrying history across chunk boundaries. */
    private fun applyLowPass(input: FloatArray): FloatArray {
        if (filterTaps.size <= 1) return input
        val output = FloatArray(input.size)
        for (i in input.indices) {
            filterHistory[historyPosition] = input[i]
            historyPosition = (historyPosition + 1) % filterHistory.size
            output[i] = convolveAt(historyPosition)
        }
        return output
    }

    /** One filter output sample, reading the ring buffer backwards from [startIndex]. */
    private fun convolveAt(startIndex: Int): Float {
        var accumulator = 0f
        var index = startIndex
        for (tap in filterTaps.indices) {
            index = if (index == 0) filterHistory.size - 1 else index - 1
            accumulator += filterHistory[index] * filterTaps[tap]
        }
        return accumulator
    }

    /** Resamples the filtered stream by linear interpolation onto the target rate. */
    private fun changeRate(filtered: FloatArray): ShortArray {
        if (filtered.isEmpty()) return ShortArray(0)
        val step = sourceSampleRate.toDouble() / targetSampleRate.toDouble()
        val outputs = ArrayList<Short>(ceil(filtered.size / step).toInt() + 1)

        while (resamplePosition < filtered.size) {
            outputs.add(interpolateAt(filtered, resamplePosition))
            resamplePosition += step
        }
        resamplePosition -= filtered.size

        previousFilteredSample = filtered[filtered.size - 1]
        hasPreviousSample = true
        return outputs.toShortArray()
    }

    /** Reads [position] out of [filtered], interpolating across the previous chunk's tail. */
    private fun interpolateAt(filtered: FloatArray, position: Double): Short {
        val lowerIndex = position.toInt()
        val fraction = (position - lowerIndex).toFloat()

        val lower = when {
            lowerIndex >= 0 && lowerIndex < filtered.size -> filtered[lowerIndex]
            hasPreviousSample -> previousFilteredSample
            else -> 0f
        }
        val upperIndex = lowerIndex + 1
        val upper = if (upperIndex < filtered.size) filtered[upperIndex] else lower

        val value = lower + (upper - lower) * fraction
        return clampToPcm16(value)
    }

    /** Clamps to the 16-bit range, because arithmetic can overshoot it and wrap. */
    private fun clampToPcm16(value: Float): Short {
        val rounded = value.toInt()
        return when {
            rounded > Short.MAX_VALUE -> Short.MAX_VALUE
            rounded < Short.MIN_VALUE -> Short.MIN_VALUE
            else -> rounded.toShort()
        }
    }

    /**
     * Builds the low-pass taps.
     *
     * Cutoff sits slightly below the target Nyquist rather than exactly on it, leaving a
     * transition band so the filter can actually reach its stopband within a practical
     * number of taps. When the source is already at or below the target rate there is
     * nothing to remove, so the filter collapses to a pass-through.
     */
    private fun buildLowPassTaps(): FloatArray {
        if (sourceSampleRate <= targetSampleRate) return floatArrayOf(1f)

        val cutoffHz = targetSampleRate / 2.0 * CUTOFF_MARGIN
        val normalisedCutoff = cutoffHz / sourceSampleRate
        val tapCount = FILTER_TAP_COUNT
        val taps = FloatArray(tapCount)
        val centre = (tapCount - 1) / 2.0
        var sum = 0.0

        for (i in 0 until tapCount) {
            val offset = i - centre
            val sinc = if (abs(offset) < 1e-9) {
                2.0 * normalisedCutoff
            } else {
                sin(2.0 * PI * normalisedCutoff * offset) / (PI * offset)
            }
            // Hamming window, to keep the stopband ripple down at this tap count.
            val window = 0.54 - 0.46 * cos(2.0 * PI * i / (tapCount - 1))
            val tap = sinc * window
            taps[i] = tap.toFloat()
            sum += tap
        }
        return normalise(taps, sum)
    }

    /** Scales taps to unit gain, so resampling never changes how loud the audio is. */
    private fun normalise(taps: FloatArray, sum: Double): FloatArray {
        if (abs(sum) < 1e-9) return taps
        for (i in taps.indices) {
            taps[i] = (taps[i] / sum).toFloat()
        }
        return taps
    }

    companion object {
        /** The rate the pipeline expects. Pinned by `test/unit/audio_source_test.dart`. */
        const val TARGET_SAMPLE_RATE = 16000

        /**
         * Number of filter taps. 64 puts the stopband far enough down for speech while
         * staying cheap enough to run over an hour of audio on a phone without the
         * filter becoming the reason an import is slow.
         */
        private const val FILTER_TAP_COUNT = 64

        /** Cutoff as a fraction of the target Nyquist, leaving a transition band. */
        private const val CUTOFF_MARGIN = 0.9

        /** Largest chunk the decoder hands over in one go, in samples. */
        fun maxSamplesFor(byteCount: Int): Int = min(byteCount / 2, Int.MAX_VALUE / 2)
    }
}
