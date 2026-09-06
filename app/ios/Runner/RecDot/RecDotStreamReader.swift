import ExternalAccessory
import Foundation

/// Owns one External Accessory session's input and output streams for a viaim RecDot.
///
/// External Accessory input streams have a long-standing habit of stalling when serviced
/// on the main run loop, so this reader runs the session's streams on its own thread's run
/// loop and drains `hasBytesAvailable` fully on every event. It never interprets the bytes;
/// it hands whatever it reads to `onBytes` and writes whatever it is given. All STAROT
/// framing lives in Dart.
final class RecDotStreamReader: NSObject, StreamDelegate {
    /// Called with each block of bytes read from the accessory, on an arbitrary thread.
    var onBytes: ((Data) -> Void)?

    /// Called when the session's streams close unexpectedly.
    var onClosed: (() -> Void)?

    private let session: EASession
    private var thread: Thread?
    private let readBufferSize = 4096
    private let pendingWrites = NSMutableData()
    private let writeLock = NSLock()

    init(session: EASession) {
        self.session = session
        super.init()
    }

    /// Opens the streams on a dedicated thread and begins reading.
    func start() {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            self.configureStreams()
            RunLoop.current.run()
        }
        thread.name = "viaim.recdot.link"
        self.thread = thread
        thread.start()
    }

    /// Queues bytes to write to the accessory; flushed as the output stream reports space.
    func write(_ data: Data) {
        writeLock.lock()
        pendingWrites.append(data)
        writeLock.unlock()
        flushPendingWrites()
    }

    /// Closes both streams and stops the reader thread.
    func stop() {
        guard let input = session.inputStream, let output = session.outputStream else { return }
        for stream in [input, output] {
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
    }

    private func configureStreams() {
        guard let input = session.inputStream, let output = session.outputStream else {
            onClosed?()
            return
        }
        for stream in [input, output] {
            stream.delegate = self
            stream.schedule(in: .current, forMode: .default)
            stream.open()
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            drain(aStream as? InputStream)
        case .hasSpaceAvailable:
            flushPendingWrites()
        case .endEncountered, .errorOccurred:
            onClosed?()
        default:
            break
        }
    }

    private func drain(_ input: InputStream?) {
        guard let input = input else { return }
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: readBufferSize)
            if read <= 0 { break }
            onBytes?(Data(buffer[0..<read]))
        }
    }

    private func flushPendingWrites() {
        guard let output = session.outputStream, output.hasSpaceAvailable else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        while pendingWrites.length > 0, output.hasSpaceAvailable {
            let written = pendingWrites.bytes.assumingMemoryBound(to: UInt8.self)
            let count = output.write(written, maxLength: pendingWrites.length)
            if count <= 0 { break }
            pendingWrites.replaceBytes(in: NSRange(location: 0, length: count), withBytes: nil, length: 0)
        }
    }
}
