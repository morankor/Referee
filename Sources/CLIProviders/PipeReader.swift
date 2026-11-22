import Foundation
import Darwin

/// A pipe created for one child process. Both ends have close-on-exec set, so no other child started at the same
/// moment inherits them (the child's own copy is made by `Process` with dup2, which clears the flag).
struct ChildPipe {
    let readEnd: Int32
    let writeEnd: Int32

    static func make() throws -> ChildPipe {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return ChildPipe(readEnd: fds[0], writeEnd: fds[1])
    }
}

/// Reads one pipe on a thread of its own until end of file, then closes it; nothing else ever closes the descriptor.
///
/// Why not `FileHandle.readabilityHandler` or `FileHandle.bytes`: under the parallel tests, handlers stopped firing for
/// some pipes while unrelated children came and went (fd numbers are reused at once, and a dispatch source must not
/// outlive its descriptor), and `FileHandle.bytes` serialises reads across handles. A thread that owns its descriptor
/// has neither problem. `poll` with a short timeout lets `stop()` end the thread when something we cannot reach
/// keeps the other end open.
final class PipeReader: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    /// `onData` is called with each chunk, in order, on the reader's thread; `onEnd` once, after the last chunk.
    init(fd: Int32, name: String, onData: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.fd = fd
        let thread = Thread { [self] in
            self.run(onData: onData)
            Darwin.close(fd)
            onEnd()
        }
        thread.name = name
        thread.start()
    }

    /// Makes the thread give up within about 250 ms, even if the pipe is still open at the other end.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func run(onData: @Sendable (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                onData(Data(buffer[0..<count]))
            } else if count == 0 {
                return
            } else if errno != EINTR && errno != EAGAIN {
                return
            }
        }
    }
}
