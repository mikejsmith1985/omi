import AVFoundation
import Foundation

/// Decodes audio files with Core Audio's own decoders, on demand.
///
/// The reason this exists is that nothing in the Omi app can read an `.m4a` — the
/// existing transcoders handle only the PCM and Opus its own hardware produces. iOS
/// already decodes every format a consumer voice recorder emits, so this reaches those
/// rather than adding a decoding library to the app.
///
/// **Pull-based on purpose.** Nothing is decoded until `readChunk` asks for it. A
/// decoder running ahead as fast as it could would hold an entire recording in memory
/// while transcription was still near the beginning, which is the failure SC-005 exists
/// to prevent. Letting the caller set the pace keeps peak memory flat with respect to
/// how long the recording is.
///
/// **Difference from the Android side worth knowing**: `AVAudioConverter` performs
/// sample-rate conversion with its own anti-aliasing, so unlike `PcmResampler.kt` there
/// is no hand-written filter here. Both paths must still produce the same thing —
/// 16 kHz mono PCM16 — and T011 compares them against a known-good decode rather than
/// trusting that they agree.
public class AudioDecoderPlugin: NSObject, AudioDecoderHostApi {

    private var sessions: [Int64: DecodeSession] = [:]

    public func probe(filePath: String) throws -> AudioProbeResult {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw AudioDecoderPigeonError(code: "file_unreadable", message: "the file is not there", details: nil)
        }

        do {
            let file = try AVAudioFile(forReading: url)
            return Self.describe(file, at: url)
        } catch {
            // Core Audio cannot read Ogg or Vorbis, which Android can. A rejection here
            // names the format so the user can convert it, rather than reporting a
            // generic read failure for a file that is perfectly valid.
            return AudioProbeResult(
                isDecodable: false,
                durationSeconds: 0,
                sourceSampleRate: 0,
                sourceChannelCount: 0,
                codecDescription: url.pathExtension.uppercased(),
                rejectionReason: "this phone cannot decode \(url.pathExtension.uppercased()) files",
                creationEpochMillis: nil
            )
        }
    }

    public func openSession(filePath: String, sessionId: Int64) throws {
        closeSession(sessionId: sessionId)
        sessions[sessionId] = try DecodeSession(filePath: filePath)
    }

    public func readChunk(sessionId: Int64, maxBytes: Int64) throws -> FlutterStandardTypedData {
        guard let session = sessions[sessionId] else {
            return FlutterStandardTypedData(bytes: Data())
        }
        return FlutterStandardTypedData(bytes: try session.read(maxBytes: Int(maxBytes)))
    }

    public func closeSession(sessionId: Int64) {
        sessions.removeValue(forKey: sessionId)
    }

    /// Reads what a file is, without committing to decoding it.
    private static func describe(_ file: AVAudioFile, at url: URL) -> AudioProbeResult {
        let format = file.fileFormat
        let duration = format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
        return AudioProbeResult(
            isDecodable: true,
            durationSeconds: duration,
            sourceSampleRate: Int64(format.sampleRate),
            sourceChannelCount: Int64(format.channelCount),
            codecDescription: Self.describeCodec(format),
            rejectionReason: nil,
            creationEpochMillis: Self.readCreationEpochMillis(at: url)
        )
    }

    /// Reads the recording date written inside the file, or nil if there is none.
    ///
    /// Worth reading even though it is often absent: this is the only evidence of when
    /// a recording was made that survives being copied, shared or re-exported. Every
    /// other source — the filename, the filesystem timestamp — is a guess by comparison.
    ///
    /// `AVAsset.creationDate` is preferred over the common metadata list because it is
    /// the one Core Audio normalises across container formats.
    private static func readCreationEpochMillis(at url: URL) -> Int64? {
        let asset = AVURLAsset(url: url)
        if let created = asset.creationDate?.dateValue {
            return Int64(created.timeIntervalSince1970 * 1000)
        }
        for item in asset.commonMetadata where item.commonKey == .commonKeyCreationDate {
            if let date = item.dateValue {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    /// A readable name for the file's codec, for diagnostics and refusal messages.
    private static func describeCodec(_ format: AVAudioFormat) -> String {
        guard let description = format.streamDescription?.pointee else { return "unknown" }
        let identifier = description.mFormatID
        let bytes = [
            UInt8((identifier >> 24) & 0xFF),
            UInt8((identifier >> 16) & 0xFF),
            UInt8((identifier >> 8) & 0xFF),
            UInt8(identifier & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
    }
}

/// One file open for decoding, with its reader and converter.
final class DecodeSession {

    /// The shape the transcription pipeline requires.
    ///
    /// Not a preference: `test/unit/audio_source_test.dart` pins `PhoneMicSource` at
    /// 320-byte frames described as 10 ms at 16 kHz 16-bit mono, and frames of any
    /// other shape will not survive the pipeline.
    static let targetSampleRate: Double = 16000

    /// How many source frames to read per pass.
    ///
    /// Roughly a second of audio at typical recording rates — large enough that the
    /// per-call overhead is irrelevant, small enough that a cancelled import stops
    /// promptly rather than after finishing a large read.
    private static let readFrameCapacity: AVAudioFrameCount = 48000

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var pending = Data()
    private var hasReachedEnd = false

    init(filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecoderPigeonError(code: "file_unreadable", message: error.localizedDescription, details: nil)
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioDecoderPigeonError(code: "decoder_init_failed", message: "cannot build output format", details: nil)
        }
        targetFormat = target
        converter = try Self.makeConverter(from: file.processingFormat, to: target)
    }

    /// Decodes until `maxBytes` of output are ready, or the recording ends.
    func read(maxBytes: Int) throws -> Data {
        while pending.count < maxBytes && !hasReachedEnd {
            try decodeOnePass()
        }
        let takeCount = min(maxBytes, pending.count)
        let chunk = pending.prefix(takeCount)
        pending.removeFirst(takeCount)
        return Data(chunk)
    }

    /// Builds the converter that resamples and downmixes in one step.
    ///
    /// `AVAudioConverter` applies its own anti-aliasing during rate conversion, which is
    /// why there is no hand-written filter on this platform. Quality is set high rather
    /// than maximum: maximum costs materially more over an hour of audio and the
    /// difference is inaudible to a speech model.
    private static func makeConverter(from source: AVAudioFormat, to target: AVAudioFormat) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw AudioDecoderPigeonError(
                code: "format_unsupported",
                message: "cannot convert this audio to 16 kHz mono",
                details: nil
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        return converter
    }

    /// Runs one conversion pass, appending whatever came out.
    private func decodeOnePass() throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: Self.readFrameCapacity) else {
            throw AudioDecoderPigeonError(code: "decoder_init_failed", message: "cannot allocate output", details: nil)
        }

        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [weak self] _, statusOut in
            self?.supplyInput(statusOut: statusOut)
        }
        try handle(status: status, error: conversionError, output: output)
    }

    /// Feeds the converter the next piece of decoded source audio.
    ///
    /// Returning nil with `.endOfStream` is what lets the converter flush its own tail;
    /// without it the last fraction of a second of every recording is discarded, which
    /// is small enough to pass testing and large enough to clip a final word.
    private func supplyInput(statusOut: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        guard !hasReachedEnd,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.readFrameCapacity) else {
            statusOut.pointee = .endOfStream
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            statusOut.pointee = .endOfStream
            hasReachedEnd = true
            return nil
        }

        if buffer.frameLength == 0 {
            statusOut.pointee = .endOfStream
            hasReachedEnd = true
            return nil
        }
        statusOut.pointee = .haveData
        return buffer
    }

    /// Interprets one conversion result, appending its audio or raising its failure.
    private func handle(status: AVAudioConverterOutputStatus, error: NSError?, output: AVAudioPCMBuffer) throws {
        if let error = error {
            throw AudioDecoderPigeonError(code: "decoder_init_failed", message: error.localizedDescription, details: nil)
        }
        switch status {
        case .haveData:
            append(output)
        case .endOfStream, .inputRanDry:
            append(output)
            hasReachedEnd = true
        case .error:
            throw AudioDecoderPigeonError(code: "decoder_init_failed", message: "conversion failed", details: nil)
        @unknown default:
            hasReachedEnd = true
        }
    }

    /// Copies converted samples out of the buffer as little-endian PCM16 bytes.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channel = buffer.int16ChannelData else { return }
        let sampleCount = Int(buffer.frameLength)
        var bytes = Data(capacity: sampleCount * 2)

        for index in 0..<sampleCount {
            let sample = channel[0][index]
            bytes.append(UInt8(truncatingIfNeeded: sample))
            bytes.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        pending.append(bytes)
    }
}
