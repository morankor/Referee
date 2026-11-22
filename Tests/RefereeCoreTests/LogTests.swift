import Foundation
import Testing
import RefereeCore

/// Log (Appendix A.8): the test sink sees every event, with identifiers already filtered.
///
/// The sink is one per process, and tests run in parallel. Three precautions follow from that. Every test here uses
/// an event name of its own and looks only at events with that name, because other tests log too. The suite is
/// serialized, because two of its tests cannot hold the sink at once. And an event that did not arrive is logged
/// again, because a test of another target may have installed its own sink in the same instant.
@Suite(.serialized) struct LogTests {
    /// What a sink collected, readable from any thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(name: String, fields: [String: LogValue])] = []
        func add(_ name: String, _ fields: [String: LogValue]) { lock.withLock { events.append((name, fields)) } }
        func fields(named name: String) -> [[String: LogValue]] { lock.withLock { events.filter { $0.name == name }.map(\.fields) } }
    }

    /// Installs a sink, logs the event once, removes the sink, and returns the fields the sink saw under that name.
    /// Empty means the event went to somebody else's sink; the caller's attempt is then repeated a few times.
    private func deliver(_ name: StaticString, _ fields: [String: LogValue]) async -> [[String: LogValue]] {
        for _ in 0..<50 {
            let collected = Collected()
            Log.setTestSink { event, values in collected.add(event, values) }
            Log.event(name, fields)
            Log.setTestSink(nil)
            let seen = collected.fields(named: name.description)
            if !seen.isEmpty { return seen }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return []
    }

    @Test func theSinkReceivesTheEventWithItsFields() async {
        let fields: [String: LogValue] = ["provider": .id("anthropic-api"), "bytes": .int(1_024), "pdf": .bool(true), "seconds": .double(1.5)]
        #expect(await deliver("test.log.fields", fields) == [fields])
        #expect(await deliver("test.log.empty", [:]) == [[:]])
    }

    @Test func identifiersThatCouldCarryTextAreReplaced() async {
        let seen = await deliver("test.log.filter", [
            "allowed": .id("gemma4:e4b/Q4_K_M-1.0"),
            "longest": .id(String(repeating: "a", count: 64)),
            "tooLong": .id(String(repeating: "a", count: 65)),
            "space": .id("The coefficient in Table 2"),
            "quote": .id("\"robust\""),
            "accent": .id("Sørensen"),
            "empty": .id(""),
            "number": .int(7),
        ]).first
        #expect(seen?["allowed"] == .id("gemma4:e4b/Q4_K_M-1.0"))
        #expect(seen?["longest"] == .id(String(repeating: "a", count: 64)))
        #expect(seen?["tooLong"] == .id("invalid-id"))
        #expect(seen?["space"] == .id("invalid-id"))
        #expect(seen?["quote"] == .id("invalid-id"))
        #expect(seen?["accent"] == .id("invalid-id"))
        #expect(seen?["empty"] == .id(""))
        #expect(seen?["number"] == .int(7))
    }

    @Test func afterTheSinkIsRemovedNothingArrives() async {
        #expect(await deliver("test.log.removed", ["n": .int(1)]) == [["n": .int(1)]])
        let removed = Collected()
        Log.setTestSink { event, values in removed.add(event, values) }
        Log.setTestSink(nil)
        Log.event("test.log.removed", ["n": .int(2)])
        #expect(removed.fields(named: "test.log.removed").isEmpty)
    }
}
