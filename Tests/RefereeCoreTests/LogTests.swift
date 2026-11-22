import Foundation
import Testing
import RefereeCore

/// Log (Appendix A.8): test sinks see every event, with identifiers already filtered.
///
/// Tests of all targets run in parallel in one process, and every sink sees the events of every test running at that
/// moment. So each test here logs under an event name of its own and looks only at events with that name; that is
/// the rule for any test that adds a sink (WP6's privacy test included).
@Suite struct LogTests {
    /// What a sink collected, readable from any thread.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(name: String, fields: [String: LogValue])] = []
        func add(_ name: String, _ fields: [String: LogValue]) { lock.withLock { events.append((name, fields)) } }
        func fields(named name: String) -> [[String: LogValue]] { lock.withLock { events.filter { $0.name == name }.map(\.fields) } }
    }

    /// Adds a sink, logs the event once, removes the sink, and returns the fields the sink saw under that name.
    private func deliver(_ name: StaticString, _ fields: [String: LogValue]) -> [[String: LogValue]] {
        let collected = Collected()
        let sink = Log.addTestSink { event, values in collected.add(event, values) }
        Log.event(name, fields)
        Log.removeTestSink(sink)
        return collected.fields(named: name.description)
    }

    @Test func theSinkReceivesTheEventWithItsFields() {
        let fields: [String: LogValue] = ["provider": .id("anthropic-api"), "bytes": .int(1_024), "pdf": .bool(true), "seconds": .double(1.5)]
        #expect(deliver("test.log.fields", fields) == [fields])
        #expect(deliver("test.log.empty", [:]) == [[:]])
    }

    @Test func identifiersThatCouldCarryTextAreReplaced() {
        let seen = deliver("test.log.filter", [
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

    @Test func afterItsSinkIsRemovedATestSeesNothingMore() {
        let collected = Collected()
        let sink = Log.addTestSink { event, values in collected.add(event, values) }
        Log.event("test.log.removed", ["n": .int(1)])
        Log.removeTestSink(sink)
        Log.event("test.log.removed", ["n": .int(2)])
        #expect(collected.fields(named: "test.log.removed") == [["n": .int(1)]])
        Log.removeTestSink(sink)                    // removing it again changes nothing
        Log.removeTestSink(UUID())                  // nor does an id that was never handed out
    }

    /// Two tests that add sinks at the same time both see every event, and each removes only its own sink.
    @Test func severalSinksSeeTheSameEventsAndEachIsRemovedAlone() {
        let first = Collected()
        let second = Collected()
        let firstSink = Log.addTestSink { event, values in first.add(event, values) }
        let secondSink = Log.addTestSink { event, values in second.add(event, values) }
        #expect(firstSink != secondSink)
        Log.event("test.log.shared", ["n": .int(1)])
        Log.removeTestSink(firstSink)
        Log.event("test.log.shared", ["n": .int(2)])
        Log.removeTestSink(secondSink)
        Log.event("test.log.shared", ["n": .int(3)])
        #expect(first.fields(named: "test.log.shared") == [["n": .int(1)]])
        #expect(second.fields(named: "test.log.shared") == [["n": .int(1)], ["n": .int(2)]])
    }

    /// Eight "tests" with a sink each log at the same time: every sink sees every event, which is why a test that
    /// asserts something of the events it sees must first keep only its own.
    @Test func aSinkSeesTheEventsOfEveryTestRunningAtThatMoment() async {
        let workers = 8
        let collected = (0..<workers).map { _ in Collected() }
        let sinks = collected.map { box in Log.addTestSink { event, values in box.add(event, values) } }
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workers {
                group.addTask { Log.event("test.log.concurrent", ["worker": .int(worker)]) }
            }
        }
        for sink in sinks { Log.removeTestSink(sink) }
        for box in collected {
            let seen = box.fields(named: "test.log.concurrent").compactMap { fields -> Int? in
                if case .int(let worker)? = fields["worker"] { return worker } else { return nil }
            }
            #expect(seen.sorted() == Array(0..<workers))
        }
    }
}
