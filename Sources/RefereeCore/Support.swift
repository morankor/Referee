import Foundation
import os

/// Accumulates bytes and returns complete lines (without the line terminator). Keeps empty lines.
/// Used for SSE, NDJSON and CLI output. (URLSession.AsyncBytes.lines drops empty lines, so it is not used.)
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func push(_ byte: UInt8) -> String? {
        if byte == 0x0A {
            defer { buffer.removeAll(keepingCapacity: true) }
            if buffer.last == 0x0D { buffer.removeLast() }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }
    /// Call once at end of input; returns the unterminated last line, if any.
    public mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// What a provider needs from the app. Settings are read at call time so edits apply without restarting.
public struct ProviderEnvironment: Sendable {
    public var settings: @Sendable (ProviderID) -> ProviderSettings
    public var secrets: any SecretStoring
    public var urlSession: URLSession
    public var processEnvironment: [String: String]     // the app's own environment (tests inject fakes)
    public init(settings: @escaping @Sendable (ProviderID) -> ProviderSettings, secrets: any SecretStoring, urlSession: URLSession, processEnvironment: [String: String]) {
        self.settings = settings; self.secrets = secrets; self.urlSession = urlSession; self.processEnvironment = processEnvironment
    }
}

/// Everything the application layer needs, as protocols. Built once by Composition.LiveDependencies.
public struct AppDependencies: Sendable {
    public var paperService: any PaperService
    public var matcherFactory: @Sendable (PaperText) -> any QuoteMatching
    public var citationIndexer: any CitationIndexing
    public var engine: any ReviewEngineProtocol
    public var resolver: any ReferenceResolving
    public var sessions: any SessionStoring
    public var settings: any SettingsStoring
    public var providers: any ProviderResolving
    public var secrets: any SecretStoring
    public init(paperService: any PaperService, matcherFactory: @escaping @Sendable (PaperText) -> any QuoteMatching, citationIndexer: any CitationIndexing,
                engine: any ReviewEngineProtocol, resolver: any ReferenceResolving, sessions: any SessionStoring, settings: any SettingsStoring,
                providers: any ProviderResolving, secrets: any SecretStoring) {
        self.paperService = paperService; self.matcherFactory = matcherFactory; self.citationIndexer = citationIndexer; self.engine = engine
        self.resolver = resolver; self.sessions = sessions; self.settings = settings; self.providers = providers; self.secrets = secrets
    }
}

public final class ProviderRegistry: ProviderResolving {
    public let all: [any LLMProvider]
    public init(_ providers: [any LLMProvider]) { self.all = providers }
    public func provider(id: ProviderID) -> (any LLMProvider)? { all.first { $0.descriptor.id == id } }
}

/// The only logging API. Values are restricted so manuscript text, prompts, model output, quotes and file names
/// cannot be logged: numbers and booleans, plus `.id` for identifiers the code itself defines (provider ids, model ids,
/// error codes, scene names). An `.id` that is longer than 64 characters or contains anything outside
/// A-Z a-z 0-9 . _ : / - is replaced by "invalid-id" before it is written.
public enum LogValue: Sendable, Equatable {
    case int(Int), double(Double), bool(Bool)
    case id(String)
}
public enum Log {
    private static let logger = Logger(subsystem: "local.referee.app", category: "app")
    private static let sinkLock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String, [String: LogValue]) -> Void)?
    /// Tests install a sink to inspect what is logged (it receives the sanitised fields); nil removes it.
    public static func setTestSink(_ newSink: (@Sendable (String, [String: LogValue]) -> Void)?) {
        sinkLock.lock(); sink = newSink; sinkLock.unlock()
    }
    static func sanitised(_ value: LogValue) -> LogValue {
        guard case .id(let s) = value else { return value }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/-")
        let ok = s.count <= 64 && s.unicodeScalars.allSatisfy { allowed.contains($0) }
        return ok ? value : .id("invalid-id")
    }
    public static func event(_ name: StaticString, _ fields: [String: LogValue] = [:]) {
        let clean = fields.mapValues(sanitised)
        let rendered = clean.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.info("\(name.description, privacy: .public) \(rendered, privacy: .public)")
        sinkLock.lock(); let current = sink; sinkLock.unlock()
        current?(name.description, clean)
    }
}
