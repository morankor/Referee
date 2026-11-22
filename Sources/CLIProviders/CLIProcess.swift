import Foundation
import Darwin
import RefereeCore

/// One running command-line tool (plan.md section 5.6.3).
///
/// - stdout is read by a `PipeReader` (a thread that owns the descriptor) and cut into lines by `LineSplitter`; see
///   `PipeReader` for why neither `FileHandle.bytes` (it serialises reads across handles: with twelve silent children,
///   a thirteenth child's two lines arrived only after three seconds) nor `readabilityHandler` is used.
/// - stderr is drained continuously into a 64 KB ring; `.exit` carries its last 4 KB.
/// - stdin is written by a `StdinWriter`, a thread of its own, so a large prompt cannot deadlock against a full stdout.
/// - The output ends with `.exit` once the process has exited and both pipes are closed, or throws
///   `LLMError.cliTimeout(phase:)` after a timeout has ended the process.
/// - Descendants are listed with `proc_listchildpids` twice a second while the process runs, so that a SIGKILL reaches
///   the whole tree, including children that a dying parent leaves behind.
final class CLIProcess: @unchecked Sendable {
    let output: AsyncThrowingStream<CLIOutput, Error>
    var processIdentifier: pid_t { process.processIdentifier }

    private let invocation: CLIInvocation
    private let process = Process()
    private let writer: StdinWriter
    private var stdoutReader: PipeReader?
    private var stderrReader: PipeReader?
    private let continuation: AsyncThrowingStream<CLIOutput, Error>.Continuation
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant

    private static let stderrCapacity = 64 * 1024
    private static let stderrTailBytes = 4 * 1024

    private let lock = NSLock()
    // Guarded by `lock`.
    private var rootIdentity: ProcessIdentity?
    private var tracked: [pid_t: ProcessIdentity] = [:]
    private var lastTrackedAt: ContinuousClock.Instant
    private var sawFirstByte = false
    private var lastLineAt: ContinuousClock.Instant
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitCode: Int32?
    private var exitedAt: ContinuousClock.Instant?
    private var orphansKilled = false
    private var pipesForced = false
    /// Set by `kill()` and by the last step of `terminate()`: from then on the watchdog sweeps the process group on
    /// every tick until the process is finished.
    private var killRequested = false
    private var failure: LLMError?
    private var finished = false
    private var terminationTask: Task<Void, Never>?
    private var goneWaiters: [CheckedContinuation<Void, Never>] = []
    private var stderrBuffer = Data()
    private var watchdog: Task<Void, Never>?

    // Touched only by the stdout reader's thread.
    private var splitter = LineSplitter()

    init(_ invocation: CLIInvocation) throws {
        self.invocation = invocation
        let (stream, continuation) = AsyncThrowingStream<CLIOutput, Error>.makeStream()
        self.output = stream
        self.continuation = continuation
        let now = clock.now
        self.startedAt = now
        self.lastLineAt = now
        self.lastTrackedAt = now

        var pipes: [ChildPipe] = []
        do {
            for _ in 0..<3 { pipes.append(try ChildPipe.make()) }
        } catch {
            for pipe in pipes { Darwin.close(pipe.readEnd); Darwin.close(pipe.writeEnd) }
            continuation.finish()
            throw LLMError.cliLaunchFailed("could not create pipes for the command-line tool")
        }
        let (stdin, stdout, stderr) = (pipes[0], pipes[1], pipes[2])
        self.writer = StdinWriter(fd: stdin.writeEnd)

        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory
        process.standardInput = FileHandle(fileDescriptor: stdin.readEnd, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: stdout.writeEnd, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: stderr.writeEnd, closeOnDealloc: false)
        process.terminationHandler = { [self] finishedProcess in self.rootExited(finishedProcess) }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.consumerWentAway() }
        }

        do {
            try process.run()
        } catch {
            for fd in [stdin.readEnd, stdout.readEnd, stdout.writeEnd, stderr.readEnd, stderr.writeEnd] { Darwin.close(fd) }
            writer.close()
            continuation.finish()
            throw LLMError.cliLaunchFailed(error.localizedDescription)
        }
        // The child has its own copies; `Process` leaves the parent's open when it is given file handles.
        for fd in [stdin.readEnd, stdout.writeEnd, stderr.writeEnd] { Darwin.close(fd) }

        let identity = ProcessTree.identity(of: process.processIdentifier)
        lock.lock(); rootIdentity = identity; lock.unlock()

        let out = PipeReader(fd: stdout.readEnd, name: "referee.cli.stdout",
                             onData: { [self] data in self.receiveStdout(data) }, onEnd: { [self] in self.stdoutEnded() })
        let err = PipeReader(fd: stderr.readEnd, name: "referee.cli.stderr",
                             onData: { [self] data in self.receiveStderr(data) }, onEnd: { [self] in self.stderrEnded() })
        lock.lock(); stdoutReader = out; stderrReader = err; lock.unlock()
        if case .data(let data) = invocation.input {
            writer.enqueue(data)
            writer.close()
        }
        let dog = Task { [self] in await self.watch() }
        lock.lock(); watchdog = dog; lock.unlock()
    }

    // MARK: - Input

    /// Interactive input only: writes one message (the caller adds the line break).
    func send(_ line: Data) async throws { try await writer.write(line) }

    /// Closes stdin after what was sent so far.
    func closeInput() { writer.close() }

    // MARK: - Ending the process

    /// SIGKILL to the process and every descendant, at once (the tripwire).
    func kill() {
        lock.lock(); killRequested = true; lock.unlock()
        let targets = currentTree()
        let root = currentRoot()
        if let root, ProcessTree.isRunning(root) { _ = killpg(root.pid, SIGKILL) }
        ProcessTree.signal(targets, SIGKILL)
        if let root { ProcessTree.killGroup(of: root) }
        writer.close()
    }

    /// SIGINT, wait 2 s, SIGTERM, wait 3 s, SIGKILL to the whole tree; returns when the process is gone. Idempotent.
    func terminate() async {
        await startTermination().value
    }

    /// Returns when the process has exited, its pipes are closed and a termination in progress has finished.
    func waitUntilGone() async {
        if let task = lock.withLock({ terminationTask }) { await task.value }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let alreadyGone = lock.withLock { () -> Bool in
                if finished { return true }
                goneWaiters.append(waiter)
                return false
            }
            if alreadyGone { waiter.resume() }
        }
    }

    /// Waits at most `limit` for the process to be gone; true if it is. Works in a cancelled task too.
    func waitUntilGone(upTo limit: Duration) async -> Bool {
        let waiter = Task { [self] () -> Bool in
            let deadline = ContinuousClock.now + limit
            while !self.isFinished && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return self.isFinished
        }
        return await waiter.value
    }

    /// All of stderr that the ring still holds (at most 64 KB).
    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    // MARK: - Pipes and exit

    private func receiveStdout(_ data: Data) {
        var lines: [String] = []
        for byte in data {
            if let line = splitter.push(byte) { lines.append(line) }
        }
        deliver(lines, byteCount: data.count, endOfFile: false)
    }

    private func stdoutEnded() {
        let last = splitter.finish()
        deliver(last.map { [$0] } ?? [], byteCount: 0, endOfFile: true)
    }

    private func deliver(_ lines: [String], byteCount: Int, endOfFile: Bool) {
        lock.lock()
        let now = clock.now
        if byteCount > 0 && !sawFirstByte {
            sawFirstByte = true
            lastLineAt = now
        }
        if !lines.isEmpty { lastLineAt = now }
        let open = !finished && failure == nil && !pipesForced
        if endOfFile { stdoutClosed = true }
        lock.unlock()
        if open {
            for line in lines { continuation.yield(.line(line)) }
        }
        if endOfFile { maybeFinish() }
    }

    private func stderrEnded() {
        lock.lock(); stderrClosed = true; lock.unlock()
        maybeFinish()
    }

    private func receiveStderr(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.stderrCapacity {
            stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrCapacity)
        }
        lock.unlock()
    }

    private func rootExited(_ finishedProcess: Process) {
        let status = finishedProcess.terminationStatus
        let code: Int32 = finishedProcess.terminationReason == .uncaughtSignal ? 128 + status : status
        lock.lock()
        if exitCode == nil { exitCode = code }
        if exitedAt == nil { exitedAt = clock.now }
        lock.unlock()
        maybeFinish()
    }

    private func maybeFinish() {
        lock.lock()
        guard !finished, stdoutClosed, stderrClosed, let code = exitCode else {
            lock.unlock()
            return
        }
        finished = true
        let failure = self.failure
        let tail = String(decoding: stderrBuffer.suffix(Self.stderrTailBytes), as: UTF8.self)
        let waiters = goneWaiters
        goneWaiters = []
        let dog = watchdog
        let sweep = killRequested ? rootIdentity : nil
        lock.unlock()

        dog?.cancel()
        if let sweep { ProcessTree.killGroup(of: sweep) }
        writer.close()
        if let failure {
            continuation.finish(throwing: failure)
        } else {
            continuation.yield(.exit(code: code, stderrTail: tail))
            continuation.finish()
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Gives up on pipes that something outside our reach keeps open: the readers stop within about 250 ms, and their
    /// end finishes the output; lines that arrive meanwhile are dropped.
    private func forceClosePipes() {
        lock.lock()
        pipesForced = true
        let readers = [stdoutReader, stderrReader]
        let root = rootIdentity
        if exitCode == nil, root.map({ !ProcessTree.isRunning($0) }) ?? true {
            exitCode = 128 + SIGKILL
            exitedAt = clock.now
        }
        lock.unlock()
        for reader in readers { reader?.stop() }
        maybeFinish()
    }

    // MARK: - Watchdog: timeouts, descendants, orphans holding the pipes

    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled || tick() { return }
        }
    }

    /// One look at the clock. Returns true once the process is finished.
    private func tick() -> Bool {
        let now = clock.now
        lock.lock()
        if finished {
            lock.unlock()
            return true
        }
        var refresh = false
        if exitCode == nil && now - lastTrackedAt >= .milliseconds(500) {
            lastTrackedAt = now
            refresh = true
        }
        var timedOut = false
        if failure == nil && terminationTask == nil {
            var phase: String?
            if !sawFirstByte && now - startedAt >= invocation.firstOutputTimeout {
                phase = "start"
            } else if sawFirstByte && now - lastLineAt >= invocation.idleTimeout {
                phase = "idle"
            }
            if phase == nil && now - startedAt >= invocation.totalTimeout { phase = "total" }
            if let phase {
                failure = .cliTimeout(phase: phase)
                timedOut = true
            }
        }
        var killOrphans = false
        var forcePipes = false
        if let exited = exitedAt, !(stdoutClosed && stderrClosed) {
            if !orphansKilled && now - exited >= .seconds(2) {
                orphansKilled = true
                killOrphans = true
            } else if orphansKilled && now - exited >= .seconds(4) {
                forcePipes = true
            }
        }
        let sweep = killRequested || killOrphans
        let orphans = sweep ? Array(tracked.values) : []
        let root = rootIdentity
        lock.unlock()

        if refresh { track() }
        if timedOut {
            switch invocation.termination {
            case .graceful: startTermination()
            case .immediate: kill()
            }
        }
        if sweep {
            ProcessTree.signal(orphans, SIGKILL)
            if let root { ProcessTree.killGroup(of: root) }
        }
        if forcePipes { forceClosePipes() }
        return false
    }

    private func track() {
        guard let root = currentRoot(), ProcessTree.isRunning(root) else { return }
        let descendants = ProcessTree.snapshot(root: root.pid).dropFirst()
        lock.lock()
        for process in descendants { tracked[process.pid] = process }
        lock.unlock()
    }

    private func currentRoot() -> ProcessIdentity? {
        lock.lock(); defer { lock.unlock() }
        return rootIdentity
    }

    /// The root (while it runs), its descendants now, and every descendant seen earlier.
    private func currentTree() -> [ProcessIdentity] {
        lock.lock()
        var all = tracked
        let root = rootIdentity
        lock.unlock()
        if let root, ProcessTree.isRunning(root) {
            for process in ProcessTree.snapshot(root: root.pid) { all[process.pid] = process }
        }
        return Array(all.values)
    }

    private func consumerWentAway() {
        switch invocation.termination {
        case .graceful: startTermination()
        case .immediate: kill()
        }
    }

    @discardableResult
    private func startTermination() -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        if let task = terminationTask { return task }
        let task = Task { [self] in await self.gracefulTermination() }
        terminationTask = task
        return task
    }

    private func gracefulTermination() async {
        if isFinished { return }
        let before = currentTree()                       // collected before the first signal
        let root = currentRoot()
        if let root, ProcessTree.isRunning(root) { _ = Darwin.kill(root.pid, SIGINT) }
        await waitForRootExit(root, limit: .seconds(2))
        if let root, ProcessTree.isRunning(root) { _ = Darwin.kill(root.pid, SIGTERM) }
        await waitForRootExit(root, limit: .seconds(3))
        var targets: [pid_t: ProcessIdentity] = [:]
        for process in before { targets[process.pid] = process }
        for process in currentTree() { targets[process.pid] = process }
        lock.withLock { killRequested = true }
        if let root, ProcessTree.isRunning(root) { _ = killpg(root.pid, SIGKILL) }
        ProcessTree.signal(Array(targets.values), SIGKILL)
        if let root { ProcessTree.killGroup(of: root) }
        writer.close()
        let deadline = clock.now + .seconds(3)
        while !isFinished && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !isFinished { forceClosePipes() }
    }

    private func waitForRootExit(_ root: ProcessIdentity?, limit: Duration) async {
        guard let root else { return }
        let deadline = clock.now + limit
        while ProcessTree.isRunning(root) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
