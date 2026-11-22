import Foundation
import RefereeCore

/// A subscription provider that runs a vendor's own CLI (plan.md section 5.6). The CLI-specific parts are the adapter;
/// everything here is shared: binary and flag check, working directory, environment, arguments, the run and its end.
final class CLIProvider: LLMProvider, @unchecked Sendable {
    let adapter: any CLIAdapter
    let environment: ProviderEnvironment
    let host: CLIHost
    private let resolver: BinaryResolver

    var descriptor: ProviderDescriptor { adapter.descriptor }

    init(adapter: any CLIAdapter, environment: ProviderEnvironment, host: CLIHost) {
        self.adapter = adapter
        self.environment = environment
        self.host = host
        self.resolver = BinaryResolver(host: host, extraEnvironment: adapter.extraEnvironment)
    }

    /// The delivery a PDF request uses: the adapter's constant unless a test or the experiment replaces it.
    var pdfDelivery: CLIPDFDelivery { host.pdfDelivery ?? adapter.pdfDelivery }

    // MARK: - LLMProvider

    func availability() async -> ProviderAvailability {
        switch await resolve() {
        case .failure(.notConfigured(let reason)):
            return .needsSetup(reason: reason, hint: adapter.installHint)
        case .failure(let error):
            return .unavailable(reason: error.userMessage)
        case .success(let binary):
            if let problem = flagProblem(binary) { return .unavailable(reason: problem) }
            return await adapter.signInStatus(binary, host: host)
        }
    }

    func listModels() async throws -> [ModelInfo] {
        try await adapter.listModels(host: host, binary: { [self] in await self.resolveChecked() })
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let run = ColdRun { [self] continuation in
            Task { await self.run(request, continuation) }
        }
        return AsyncThrowingStream(unfolding: { try await run.next() })
    }

    // MARK: - Binary

    func resolve() async -> Result<ResolvedBinary, LLMError> {
        await resolver.resolve(adapter.spec, explicitPath: environment.settings(descriptor.id).executablePath)
    }

    /// The binary, or `.notConfigured` with the reason the provider cannot be used (missing, or failing the flag check).
    func resolveChecked() async -> Result<ResolvedBinary, LLMError> {
        switch await resolve() {
        case .success(let binary):
            if let problem = flagProblem(binary) { return .failure(.notConfigured(problem)) }
            return .success(binary)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Section 5.6.1: every protected flag must be in the first help text as a whole word, and every help command must
    /// have exited 0.
    func flagProblem(_ binary: ResolvedBinary) -> String? {
        let name = adapter.spec.name
        if let failure = binary.helpFailure {
            return "\(name) \(binary.version) did not answer as expected (\(failure)), so Referee cannot run it safely"
        }
        if let missing = CLIArguments.firstMissingFlag(adapter.protectedFlags, in: binary.helpText) {
            return "\(name) \(binary.version) does not list the option \(missing), which Referee needs in order to run it safely"
        }
        return nil
    }

    // MARK: - A run

    private enum RunEnd {
        case success(StopReason, Usage?, statuses: [String])
        case failure(LLMError)
        case cancelled
    }

    private func run(_ request: LLMRequest, _ out: AsyncThrowingStream<LLMEvent, Error>.Continuation) async {
        let started = ContinuousClock.now
        let id = descriptor.id
        var workspace: CLIWorkspace?
        do {
            let prompt = try CLIPrompt(request)
            let delivery = prompt.pdf == nil ? CLIPDFDelivery.none : pdfDelivery
            if prompt.pdf != nil && delivery == .none {
                throw LLMError.invalidRequest("\(descriptor.displayName) does not accept pdf files; this route sends extracted text only")
            }
            let model = try CLIArguments.checkedModel(request.model)
            let settings = environment.settings(id)
            let binary = try await resolveChecked().get()
            Self.removeStaleWorkspacesOnce(in: host.temporaryRoot)

            let directory = try CLIWorkspace.create(in: host.temporaryRoot)
            workspace = directory
            let input = try adapter.prepareInput(prompt, workspace: directory, delivery: delivery)
            if let limit = descriptor.maxPromptBytes, input.payloadBytes > limit {
                throw LLMError.contextTooLong("the prompt is \(input.payloadBytes) bytes; \(descriptor.displayName) takes at most \(limit)")
            }
            var table = adapter.argumentTable(workspace: directory.url, model: model, delivery: delivery)
            table.model += input.attachmentArguments
            let arguments = CLIArguments.build(table, extraArguments: settings.extraArguments)
            for status in arguments.statuses { out.yield(.status(status)) }

            let timeouts = host.runTimeouts ?? adapter.timeouts
            let invocation = CLIInvocation(executable: binary.path, arguments: arguments.arguments, input: input.input,
                                           workingDirectory: directory.url,
                                           environment: await host.childEnvironment(extra: adapter.extraEnvironment),
                                           firstOutputTimeout: timeouts.firstOutput, idleTimeout: timeouts.idle, totalTimeout: timeouts.total)
            if Task.isCancelled { throw CancellationError() }
            let process = try CLIRunner().start(invocation)
            Log.event("cli.run.start", ["provider": .id(id), "bytes": .int(input.payloadBytes), "pdf": .bool(delivery != .none),
                                        "delivery": .id(delivery.rawValue)])

            let end: RunEnd
            switch adapter.makeSession(workspace: directory.url, delivery: delivery, input: input) {
            case .lines(let parser): end = await driveLines(parser, process: process, out: out)
            case .acp(let client): end = await driveACP(client, binary: binary, process: process, out: out)
            }
            directory.remove()
            workspace = nil
            let milliseconds = Self.milliseconds(since: started)
            switch end {
            case .success(let stop, let usage, let statuses):
                Log.event("cli.run.end", ["provider": .id(id), "outcome": .id("finished"), "ms": .int(milliseconds)])
                for status in statuses { out.yield(.status(status)) }
                out.yield(.finished(stop, usage))
                out.finish()
            case .failure(let error):
                Log.event("cli.run.end", ["provider": .id(id), "outcome": .id(Self.outcomeName(error)), "ms": .int(milliseconds)])
                out.finish(throwing: error)
            case .cancelled:
                Log.event("cli.run.end", ["provider": .id(id), "outcome": .id("cancelled"), "ms": .int(milliseconds)])
                out.finish()
            }
        } catch {
            workspace?.remove()
            let failure: LLMError = (error as? LLMError) ?? (error is CancellationError ? .cancelled : .cliLaunchFailed(error.localizedDescription))
            out.finish(throwing: failure)
        }
    }

    /// Claude Code, Codex, Antigravity: JSON lines on stdout, nothing read back.
    private func driveLines(_ parser: any CLIStreamParser, process: CLIProcess, out: AsyncThrowingStream<LLMEvent, Error>.Continuation) async -> RunEnd {
        var parser = parser
        let inputs = DriverInputs(process)
        defer { inputs.stop() }
        let clock = ContinuousClock()
        var successAt: ContinuousClock.Instant?
        for await input in inputs.stream {
            switch input {
            case .line(let line):
                host.lineObserver?(descriptor.id, line)
                do {
                    for event in try parser.consume(line) { out.yield(event) }
                } catch {
                    let failure = (error as? LLMError) ?? .malformedResponse("unreadable output")
                    if case .toolUseBlocked(let tool) = failure {
                        process.kill()
                        Log.event("cli.tripwire", ["provider": .id(descriptor.id), "tool": .id(tool)])
                    } else {
                        await end(process)
                    }
                    await process.waitUntilGone()
                    return .failure(failure)
                }
                switch parser.outcome {
                case .failure(let error)?:
                    await end(process)
                    return .failure(error)
                case .success?:
                    if successAt == nil { successAt = clock.now }
                case nil:
                    break
                }
            case .exit(let code, let tail):
                switch parser.finalResult(exitCode: code, stderrTail: tail) {
                case .success(let stop, let usage): return .success(stop, usage, statuses: [])
                case .failure(let error): return .failure(error)
                }
            case .failed(let error):
                await process.waitUntilGone()
                return .failure(error)
            case .tick:
                if let successAt, clock.now - successAt >= host.postResultGrace, case .success(let stop, let usage)? = parser.outcome {
                    await process.terminate()
                    return .success(stop, usage, statuses: [])
                }
            }
        }
        await process.terminate()
        return .cancelled
    }

    /// Grok Build: the Agent Client Protocol over stdin and stdout.
    private func driveACP(_ client: GrokACPClient, binary: ResolvedBinary, process: CLIProcess,
                          out: AsyncThrowingStream<LLMEvent, Error>.Continuation) async -> RunEnd {
        var client = client
        let inputs = DriverInputs(process)
        defer { inputs.stop() }
        let clock = ContinuousClock()
        var lastLineAt = clock.now
        var deleteSentAt: ContinuousClock.Instant?
        var result: RunEnd?

        func send(_ messages: [Data]) async -> Bool {
            for message in messages {
                do { try await process.send(message) } catch { return false }
            }
            return true
        }

        var answered: Bool { client.phase == .draining || client.phase == .deleting || client.phase == .done }

        // A write that fails means the agent closed its input, nearly always because it exited: the exit (or a timeout)
        // decides how the run ends, not the failed write.
        _ = await send(client.start())
        loop: for await input in inputs.stream {
            if result != nil { break }
            switch input {
            case .line(let line):
                host.lineObserver?(descriptor.id, line)
                lastLineAt = clock.now
                guard client.phase != .done else { break }
                let step: GrokACPClient.Step
                do { step = try client.receive(line) } catch {
                    result = .failure((error as? LLMError) ?? .malformedResponse("unreadable output"))
                    break loop
                }
                let sent = await send(step.outgoing)
                if let tool = step.tripwire {
                    process.kill()
                    Log.event("cli.tripwire", ["provider": .id(descriptor.id), "tool": .id(tool)])
                    result = .failure(tripwire(tool))
                    break loop
                }
                for event in step.events { out.yield(event) }
                if !sent && client.phase == .deleting { client.giveUpDeleting() }
                if client.phase == .deleting && deleteSentAt == nil { deleteSentAt = clock.now }
            case .tick:
                if client.phase == .draining && clock.now - lastLineAt >= host.quietPeriod {
                    let step = client.quietPeriodElapsed()
                    if !(await send(step.outgoing)) { client.giveUpDeleting() }
                    if client.phase == .deleting { deleteSentAt = clock.now }
                } else if client.phase == .deleting, let sentAt = deleteSentAt, clock.now - sentAt >= .seconds(5) {
                    client.giveUpDeleting()
                }
            case .exit(let code, let tail):
                if answered {
                    client.giveUpDeleting()
                    break loop
                }
                result = .failure(GrokACPClient.classifyStderr(tail)
                                  ?? (code != 0 ? .cliExited(code: code, stderrTail: tail) : .malformedResponse("Grok Build ended before it answered")))
            case .failed(let error):
                result = .failure(error)
            }
            if result != nil || client.phase == .done { break loop }
        }
        // The stream of inputs also ends when the consumer cancels. Once the prompt is answered the run has succeeded,
        // whether the agent then went quiet, answered `session/delete`, or exited.
        if result == nil && !answered { result = .cancelled }

        // End the process. After a tripwire it is already killed; a cancelled run is terminated at once; otherwise stdin is
        // closed and the agent gets 2 s to exit by itself.
        switch result {
        case .failure(.toolUseBlocked)?:
            await process.waitUntilGone()
        case .cancelled?:
            await process.terminate()
        default:
            process.closeInput()
            if !(await process.waitUntilGone(upTo: .seconds(2))) { await process.terminate() }
        }
        // Delete the local copy of the conversation if the protocol did not. In a task of its own, because the run's
        // task may be cancelled, and a cancelled task cannot run a command.
        var statuses: [String] = []
        if let sessionID = client.sessionID, !client.sessionDeleted {
            let host = self.host, extra = adapter.extraEnvironment
            let deleted = await Task {
                await host.command(binary, GrokBuildAdapter.deleteSessionCommand(sessionID), extraEnvironment: extra)
            }.value
            if case .success(let output) = deleted, output.exitCode == 0 {} else {
                statuses.append("could not delete Grok Build's local copy of this conversation")
            }
        }
        if let result { return result }
        return .success(client.stopReason ?? .other, nil, statuses: statuses)
    }

    /// After a result: give the CLI 2 s to exit by itself, then end it.
    private func end(_ process: CLIProcess) async {
        if !(await process.waitUntilGone(upTo: .seconds(2))) { await process.terminate() }
    }

    // MARK: - Helpers

    private static let staleLock = NSLock()
    nonisolated(unsafe) private static var sweptRoots: Set<String> = []

    /// Section 12.4: working directories a crash left behind are removed on the next run after launch.
    private static func removeStaleWorkspacesOnce(in root: URL) {
        staleLock.lock()
        let first = sweptRoots.insert(root.path).inserted
        staleLock.unlock()
        if first { CLIWorkspace.removeStale(in: root) }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func outcomeName(_ error: LLMError) -> String {
        switch error {
        case .toolUseBlocked: return "tripwire"
        case .cliTimeout(let phase): return "timeout-\(phase)"
        case .auth: return "auth"
        case .quotaExhausted: return "quota"
        case .cliExited: return "exited"
        case .cancelled: return "cancelled"
        default: return "error"
        }
    }
}

/// The process's output and a 100 ms tick in one stream, so that a driver can notice silence without cancelling a read.
private struct DriverInputs {
    enum Input { case line(String), exit(Int32, String), failed(LLMError), tick }

    let stream: AsyncStream<Input>
    private let continuation: AsyncStream<Input>.Continuation
    private let pump: Task<Void, Never>
    private let ticker: Task<Void, Never>

    init(_ process: CLIProcess) {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        self.stream = stream
        self.continuation = continuation
        pump = Task {
            do {
                for try await output in process.output {
                    switch output {
                    case .line(let line): continuation.yield(.line(line))
                    case .exit(let code, let tail): continuation.yield(.exit(code, tail))
                    }
                }
            } catch {
                continuation.yield(.failed((error as? LLMError) ?? .malformedResponse("unreadable output")))
            }
        }
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                continuation.yield(.tick)
            }
        }
    }

    func stop() {
        pump.cancel()
        ticker.cancel()
        continuation.finish()
    }
}

/// A stream whose work starts on the first `next()` (the provider contract: cold streams). The work is cancelled when
/// the consumer cancels, or when the stream is dropped.
private final class ColdRun: @unchecked Sendable {
    private let lock = NSLock()
    private let start: @Sendable (AsyncThrowingStream<LLMEvent, Error>.Continuation) -> Task<Void, Never>
    private var iterator: AsyncThrowingStream<LLMEvent, Error>.AsyncIterator?
    private var task: Task<Void, Never>?

    init(start: @escaping @Sendable (AsyncThrowingStream<LLMEvent, Error>.Continuation) -> Task<Void, Never>) {
        self.start = start
    }

    func next() async throws -> LLMEvent? {
        var current = lock.withLock { () -> AsyncThrowingStream<LLMEvent, Error>.AsyncIterator in
            if let iterator { return iterator }
            let (stream, continuation) = AsyncThrowingStream<LLMEvent, Error>.makeStream()
            let work = start(continuation)
            continuation.onTermination = { _ in work.cancel() }
            task = work
            let made = stream.makeAsyncIterator()
            iterator = made
            return made
        }
        return try await current.next()
    }

    deinit { task?.cancel() }
}
