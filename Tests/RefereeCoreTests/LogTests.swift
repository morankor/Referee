import Foundation
import Testing
import RefereeCore

/// Log (Appendix A.8): the test sink sees every event, with identifiers already filtered.
///
/// The sink is one per process and other tests log too, so every test here uses an event name of its own and looks
/// only at events with that name. The suite is serialized because two tests cannot hold the sink at once.
@Suite(.serialized) struct LogTests {
    /// What a sink collected, readable from any thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(name: String, fields: [String: LogValue])] = []
        func add(_ name: String, _ fields: [String: LogValue]) { lock.withLock { events.append((name, fields)) } }
        func fields(named name: String) -> [[String: LogValue]] { lock.withLock { events.filter { $0.name == name }.map(\.fields) } }
    }

    @Test func theSinkReceivesTheEventWithItsFields() {
        let collected = Collected()
        Log.setTestSink { name, fields in collected.add(name, fields) }
        defer { Log.setTestSink(nil) }

        Log.event("test.log.fields", ["provider": .id("anthropic-api"), "bytes": .int(1_024), "pdf": .bool(true), "seconds": .double(1.5)])
        #expect(collected.fields(named: "test.log.fields") == [
            ["provider": .id("anthropic-api"), "bytes": .int(1_024), "pdf": .bool(true), "seconds": .double(1.5)],
        ])

        Log.event("test.log.empty")
        #expect(collected.fields(named: "test.log.empty") == [[:]])
    }

    @Test func identifiersThatCouldCarryTextAreReplaced() {
        let collected = Collected()
        Log.setTestSink { name, fields in collected.add(name, fields) }
        defer { Log.setTestSink(nil) }

        Log.event("test.log.filter", [
            "allowed": .id("gemma4:e4b/Q4_K_M-1.0"),
            "longest": .id(String(repeating: "a", count: 64)),
            "tooLong": .id(String(repeating: "a", count: 65)),
            "space": .id("The coefficient in Table 2"),
            "quote": .id("\"robust\""),
            "accent": .id("Sørensen"),
            "empty": .id(""),
        ])
        let fields = collected.fields(named: "test.log.filter").first
        #expect(fields?["allowed"] == .id("gemma4:e4b/Q4_K_M-1.0"))
        #expect(fields?["longest"] == .id(String(repeating: "a", count: 64)))
        #expect(fields?["tooLong"] == .id("invalid-id"))
        #expect(fields?["space"] == .id("invalid-id"))
        #expect(fields?["quote"] == .id("invalid-id"))
        #expect(fields?["accent"] == .id("invalid-id"))
        #expect(fields?["empty"] == .id(""))
    }

    @Test func afterTheSinkIsRemovedNothingArrives() {
        let collected = Collected()
        Log.setTestSink { name, fields in collected.add(name, fields) }
        Log.event("test.log.removed", ["n": .int(1)])
        Log.setTestSink(nil)
        Log.event("test.log.removed", ["n": .int(2)])
        #expect(collected.fields(named: "test.log.removed") == [["n": .int(1)]])
    }
}
