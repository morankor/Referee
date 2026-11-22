import Foundation
import RefereeCore
@testable import ScholarKit
import TestSupport

/// A resolver on a temporary folder, with a test clock and a session that only talks to `StubURLProtocol`.
/// The stub's rules apply (docs/contract-notes/gate0.md): call `StubURLProtocol.setHandler` first, then make the
/// harness in the test function itself (it makes the session), and read `recordedRequests` there too.
struct ResolverHarness {
    let home: URL
    let clock: TestClock
    let settings: SettingsBox
    let session: URLSession
    let maxPDFBytes: Int
    let resolver: ReferenceResolver

    init(mailto: String = "", pdfCacheLimitMB: Int = 500, clock: TestClock = TestClock(), maxPDFBytes: Int = PDFDownloader.defaultMaxBytes) {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-scholarkit-\(UUID().uuidString)", isDirectory: true)
        self.clock = clock
        settings = SettingsBox(ReferenceSettings(crossrefMailto: mailto, pdfCacheLimitMB: pdfCacheLimitMB))
        session = StubURLProtocol.session()
        self.maxPDFBytes = maxPDFBytes
        resolver = Self.makeResolver(home: home, clock: clock, settings: settings, session: session, maxPDFBytes: maxPDFBytes)
    }

    /// Another resolver on the same folders, clock and session: the app after a restart.
    func restartedResolver() -> ReferenceResolver {
        Self.makeResolver(home: home, clock: clock, settings: settings, session: session, maxPDFBytes: maxPDFBytes)
    }

    var cacheDirectory: URL { home.appendingPathComponent("Caches", isDirectory: true) }
    var papersDirectory: URL { cacheDirectory.appendingPathComponent("papers", isDirectory: true) }

    func documentFolder(_ document: String) -> URL {
        home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(document, isDirectory: true)
    }

    /// <dataDirectory>/sessions/<sha256>/references.json
    func referencesFile(_ document: String) -> URL {
        documentFolder(document).appendingPathComponent("references.json")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }

    private static func makeResolver(home: URL, clock: TestClock, settings: SettingsBox, session: URLSession, maxPDFBytes: Int) -> ReferenceResolver {
        ReferenceResolver(settings: { settings.current }, urlSession: session, dataDirectory: home,
                          cacheDirectory: home.appendingPathComponent("Caches", isDirectory: true), clock: clock, maxPDFBytes: maxPDFBytes)
    }
}

/// Reference settings that a test can change while the resolver reads them.
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ReferenceSettings

    init(_ value: ReferenceSettings) { self.value = value }

    var current: ReferenceSettings { lock.withLock { value } }
}

/// Two documents under review.
enum Documents {
    static let first = String(repeating: "a", count: 64)
    static let second = String(repeating: "b", count: 64)
}

// ---- stubbed answers ----

enum Stub {
    static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> StubURLProtocol.Response {
        StubURLProtocol.Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { mine, _ in mine },
                                 chunks: [Data(body.utf8)])
    }

    static func status(_ status: Int, headers: [String: String] = [:]) -> StubURLProtocol.Response {
        StubURLProtocol.Response(status: status, headers: headers, chunks: [])
    }

    /// A body that starts with the PDF signature, `size` bytes in all.
    static func pdfBody(size: Int = 2_000) -> Data {
        let head = Data("%PDF-1.4\n".utf8), tail = Data("\n%%EOF\n".utf8)
        return head + Data(repeating: 0x20, count: max(0, size - head.count - tail.count)) + tail
    }

    static func pdf(size: Int = 2_000) -> StubURLProtocol.Response {
        StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/pdf"], chunks: [pdfBody(size: size)])
    }

    /// Crossref and OpenAlex answer with these bodies; every other host is refused.
    static func services(crossref: String, openAlex: String) -> @Sendable (URLRequest) -> StubURLProtocol.Response? {
        { request in
            switch request.url?.host {
            case "api.crossref.org": return json(crossref)
            case "api.openalex.org": return json(openAlex)
            default: return nil
            }
        }
    }
}

/// Answers each host with its responses in turn, the last one repeating; a host without responses is refused.
final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [StubURLProtocol.Response]]

    init(_ queues: [String: [StubURLProtocol.Response]]) { self.queues = queues }

    func next(for request: URLRequest) -> StubURLProtocol.Response? {
        lock.withLock {
            guard let host = request.url?.host, var queue = queues[host], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                queues[host] = queue
            }
            return first
        }
    }
}

/// When each request reached the stub: in the test clock's time and in real time.
final class ArrivalLog: @unchecked Sendable {
    struct Arrival {
        let host: String
        let uptime: Double
        let instant: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private var arrivals: [Arrival] = []
    private let clock: TestClock

    init(clock: TestClock) { self.clock = clock }

    func record(_ request: URLRequest) {
        let arrival = Arrival(host: request.url?.host ?? "", uptime: clock.uptime(), instant: .now)
        lock.withLock { arrivals.append(arrival) }
    }

    func at(_ host: String) -> [Arrival] {
        lock.withLock { arrivals.filter { $0.host == host } }
    }
}

extension URLRequest {
    /// The decoded query of the URL; a name given twice keeps its last value (`queryNames` shows repeats).
    var query: [String: String] {
        Dictionary((queryItemList ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    var queryNames: [String] { (queryItemList ?? []).map(\.name) }

    private var queryItemList: [URLQueryItem]? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
    }
}

/// Files of a folder, without the hidden ones; empty when the folder does not exist.
func visibleFiles(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

/// All files of a folder, hidden ones included.
func allFiles(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}
