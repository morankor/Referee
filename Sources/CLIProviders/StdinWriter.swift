import Foundation
import Darwin
import RefereeCore

/// Writes a child's standard input on a thread of its own, one item after the other, then closes it.
///
/// Why a thread: a write blocks until the child reads, and a CLI may not read stdin before it has written a lot of
/// output; a blocked write on the cooperative thread pool would stall unrelated tasks. Why `F_SETNOSIGPIPE`: a child
/// that exits without reading its input must give EPIPE here, not a SIGPIPE that ends the app.
final class StdinWriter: @unchecked Sendable {
    private enum Item {
        case write(Data, (@Sendable (Error?) -> Void)?)
        case close
    }

    private let fd: Int32
    private let condition = NSCondition()
    private var items: [Item] = []
    private var closeRequested = false
    private var broken = false

    /// Takes ownership of `fd`: it is closed by the writer's thread, once, after the last write.
    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let thread = Thread { [self] in self.drain() }
        thread.name = "referee.cli.stdin"
        thread.start()
    }

    /// Queues `data`; returns at once. The data is dropped if the input is already closed.
    func enqueue(_ data: Data) {
        condition.lock()
        if !closeRequested { items.append(.write(data, nil)) }
        condition.signal()
        condition.unlock()
    }

    /// Writes `data` and returns when it has been written. Throws `.cliExited`-style broken-pipe errors as `LLMError`.
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            condition.lock()
            if closeRequested || broken {
                condition.unlock()
                continuation.resume(throwing: LLMError.cliLaunchFailed("the command-line tool's input is closed"))
                return
            }
            items.append(.write(data, { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }))
            condition.signal()
            condition.unlock()
        }
    }

    /// Closes the input after everything queued so far has been written (or has failed). Idempotent.
    func close() {
        condition.lock()
        if !closeRequested {
            closeRequested = true
            items.append(.close)
            condition.signal()
        }
        condition.unlock()
    }

    private func drain() {
        while true {
            condition.lock()
            while items.isEmpty { condition.wait() }
            let item = items.removeFirst()
            let isBroken = broken
            condition.unlock()

            switch item {
            case .write(let data, let done):
                if isBroken {
                    done?(LLMError.cliLaunchFailed("the command-line tool stopped reading its input"))
                    continue
                }
                let ok = Self.writeAll(data, to: fd)
                if !ok {
                    condition.lock(); broken = true; condition.unlock()
                }
                done?(ok ? nil : LLMError.cliLaunchFailed("the command-line tool stopped reading its input"))
            case .close:
                Darwin.close(fd)
                // Fail whatever was queued behind the close (nothing normally is).
                condition.lock()
                let rest = items
                items.removeAll()
                condition.unlock()
                for case .write(_, let done) in rest {
                    done?(LLMError.cliLaunchFailed("the command-line tool's input is closed"))
                }
                return
            }
        }
    }

    /// Blocking write of the whole buffer; false on EPIPE or another error.
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}
