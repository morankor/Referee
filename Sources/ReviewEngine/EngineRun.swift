import Foundation
import RefereeCore

/// What every job needs from the engine.
struct EngineDependencies: Sendable {
    let providers: any ProviderResolving
    let paperService: any PaperService
    let matcherFactory: @Sendable (PaperText) -> any QuoteMatching
    let renderer: any PaperRendering
    let physicalMemoryBytes: UInt64
    let debugDump: DebugDump
}

/// Why a job stopped before it was done.
enum JobInterruption: Error {
    case cancelled
    case failed(LLMError)
}

/// One provider answer that streamed to its end.
struct StreamOutcome {
    var stop: StopReason
    var usage: Usage?
}

/// The run record of one job and the bookkeeping around it: requests sent, whether the PDF went, usage summed over
/// requests (section 6.6), and the streaming of one request with the cancellation rules of Gate 0: a provider stream
/// may simply end when the job is cancelled, so `Task.isCancelled` is checked after the loop, not only the error.
///
/// Logging is limited to event names of the form "engine.*" with ids, numbers and booleans (section 12.2): never a
/// prompt, a quote, model output, a file name or a model id typed by the user.
final class RunBook {
    let provider: (any LLMProvider)?
    let reference: ProviderRef
    private(set) var run: RunRecord
    private(set) var requestCount = 0
    private(set) var sentPDF = false
    private(set) var usage: Usage?
    private let debugDump: DebugDump
    private let started = ContinuousClock.now

    init(kind: RunKind, context: EngineContext, dependencies: EngineDependencies) {
        provider = dependencies.providers.provider(id: context.provider.providerID)
        reference = context.provider
        debugDump = dependencies.debugDump
        run = RunRecord(id: UUID(), kind: kind, provider: context.provider, destination: provider?.descriptor.destination ?? "", sentPDF: false,
                        requestCount: 0, startedAt: Date(), status: .running)
    }

    /// The error of a job whose provider is not registered.
    var missingProvider: LLMError {
        .notConfigured("no provider with the id \(reference.providerID) is registered")
    }

    /// The record as it stands, with this status, the requests so far and the summed usage.
    func finished(_ status: RunStatus) -> RunRecord {
        var record = run
        record.status = status
        record.finishedAt = Date()
        record.requestCount = requestCount
        record.sentPDF = sentPDF
        record.usage = usage
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        Log.event("engine.run.finished", ["kind": .id(run.kind.rawValue), "provider": .id(reference.providerID), "status": .id(status.logName),
                                          "requests": .int(requestCount), "pdf": .bool(sentPDF), "seconds": .double(seconds)])
        return record
    }

    /// Sends one request and reads its stream to the end. `onDelta` sees every text delta, `onStatus` every status line.
    /// Throws `.cancelled` when the job was cancelled, whatever the provider did, and `.failed` for a provider error.
    func stream(_ request: LLMRequest, onDelta: (String) async -> Void, onStatus: (String) -> Void = { _ in }) async throws -> StreamOutcome {
        guard let provider else { throw JobInterruption.failed(missingProvider) }
        if Task.isCancelled { throw JobInterruption.cancelled }
        requestCount += 1
        let hasPDF = request.parts.contains { if case .pdf = $0 { return true } else { return false } }
        if hasPDF { sentPDF = true }
        let characters = request.parts.reduce(request.system.count) { total, part in
            if case .text(let text) = part { return total + text.count }
            return total
        }
        Log.event("engine.request", ["provider": .id(reference.providerID), "purpose": .id(request.purpose.rawValue), "pdf": .bool(hasPDF),
                                     "parts": .int(request.parts.count), "characters": .int(characters), "number": .int(requestCount)])
        var output = ""
        var deltas = 0
        var stop: StopReason = .endOfTurn
        var answerUsage: Usage?
        do {
            for try await event in provider.stream(request) {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let text):
                    deltas += 1
                    if debugDump.isOn { output += text }
                    await onDelta(text)
                case .status(let line):
                    onStatus(line)
                case .finished(let reason, let reported):
                    stop = reason
                    answerUsage = reported
                }
            }
        } catch {
            let interruption = Self.interruption(for: error)
            record(request, output: output, deltas: deltas, outcome: interruption.logName)
            throw interruption
        }
        if Task.isCancelled {
            record(request, output: output, deltas: deltas, outcome: "cancelled")
            throw JobInterruption.cancelled
        }
        if let answerUsage { usage = Self.sum(usage, answerUsage) }
        record(request, output: output, deltas: deltas, outcome: "completed:\(stop.rawValue)")
        return StreamOutcome(stop: stop, usage: answerUsage)
    }

    private func record(_ request: LLMRequest, output: String, deltas: Int, outcome: String) {
        Log.event("engine.response", ["provider": .id(reference.providerID), "purpose": .id(request.purpose.rawValue), "deltas": .int(deltas),
                                      "outcome": .id(outcome)])
        debugDump.write(request: request, provider: reference, output: output, outcome: outcome)
    }

    static func interruption(for error: Error) -> JobInterruption {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        guard let llmError = error as? LLMError else {
            return .failed(.malformedResponse("the provider failed with an error of type \(type(of: error))"))
        }
        return llmError == .cancelled ? .cancelled : .failed(llmError)
    }

    static func sum(_ total: Usage?, _ more: Usage) -> Usage {
        func add(_ a: Int?, _ b: Int?) -> Int? { a.map { $0 + (b ?? 0) } ?? b }
        return Usage(inputTokens: add(total?.inputTokens, more.inputTokens), outputTokens: add(total?.outputTokens, more.outputTokens))
    }

    /// Section 6.2: in PDF mode these errors restart the job once in text mode.
    static func isPDFRejection(_ error: LLMError) -> Bool {
        switch error {
        case .contextTooLong: return true
        case .invalidRequest(let message):
            let lowered = message.lowercased()
            return ["pdf", "file", "document", "image"].contains { lowered.contains($0) }
        default: return false
        }
    }
}

extension JobInterruption {
    var logName: String {
        switch self {
        case .cancelled: return "cancelled"
        case .failed(let error): return "failed:" + error.logName
        }
    }
}

extension RunStatus {
    var logName: String {
        switch self {
        case .running: return "running"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

extension LLMError {
    /// The case name, for logs (never the message, which may quote the provider).
    var logName: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .auth: return "auth"
        case .rateLimited: return "rateLimited"
        case .quotaExhausted: return "quotaExhausted"
        case .overloaded: return "overloaded"
        case .contextTooLong: return "contextTooLong"
        case .invalidRequest: return "invalidRequest"
        case .modelNotFound: return "modelNotFound"
        case .refused: return "refused"
        case .network: return "network"
        case .server: return "server"
        case .cliLaunchFailed: return "cliLaunchFailed"
        case .cliTimeout: return "cliTimeout"
        case .cliExited: return "cliExited"
        case .toolUseBlocked: return "toolUseBlocked"
        case .malformedResponse: return "malformedResponse"
        case .cancelled: return "cancelled"
        }
    }
}
