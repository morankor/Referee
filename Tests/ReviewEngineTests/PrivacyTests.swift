import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// No manuscript text in logs (plan.md section 12.2): row "privacy" of WP6, and the debug transcript of section 10.5.
@Suite struct PrivacyTests {
    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(name: String, fields: [String: LogValue])] = []
        func add(_ name: String, _ fields: [String: LogValue]) { lock.withLock { events.append((name, fields)) } }
        var all: [(name: String, fields: [String: LogValue])] { lock.withLock { events } }
    }

    /// Every 12-character piece of `text`.
    private func windows(_ text: String, into set: inout Set<String>) {
        let characters = Array(text)
        guard characters.count >= 12 else { return }
        for start in 0...(characters.count - 12) { set.insert(String(characters[start..<(start + 12)])) }
    }

    @Test func theEnginesLogEventsCarryNoManuscriptTextAndNoInvalidIDs() async throws {
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: paper)
        let context = EngineTest.context(meta: ManuscriptMeta(targetVenue: "Journal of Examples", reviewerNotes: "Focus on the identification strategy."))

        let captured = Captured()
        let sink = Log.addTestSink { name, fields in
            // The sink sees the events of every test running now: keep the engine's own.
            if name.hasPrefix("engine.") { captured.add(name, fields) }
        }
        let events = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: context))
        var comments = events.comments
        for index in comments.indices { comments[index].status = .approved }
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: context.meta, comments: comments, createdAt: Date(),
                                    updatedAt: Date())
        _ = try await EngineTest.collect(engine.discuss(paper: paper, comment: comments[0], message: "Is the interval really in the text?", context: context))
        _ = try await EngineTest.collect(engine.ask(paper: paper, conversation: Conversation(id: UUID(), anchor: comments[2].anchor, createdAt: Date()),
                                                    question: "Is this supported?", context: context))
        _ = try await EngineTest.collect(engine.generateReport(paper: paper, session: session, context: context))
        Log.removeTestSink(sink)

        #expect(events.finishedRun?.status == .completed)
        let logged = captured.all
        #expect(logged.contains { $0.name == "engine.request" })
        #expect(logged.contains { $0.name == "engine.run.finished" })

        var forbidden: Set<String> = []
        for page in paper.text.pages { windows(page.string, into: &forbidden) }
        windows(paper.ref.fileName, into: &forbidden)
        for request in mock.recordedRequests { windows(EngineTest.text(of: request), into: &forbidden) }
        #expect(forbidden.count > 1_000)

        for (name, fields) in logged {
            for (key, value) in fields {
                let rendered: String
                switch value {
                case .id(let id):
                    #expect(id != "invalid-id", "\(name).\(key) was not a valid id")
                    rendered = id
                case .int(let number): rendered = String(number)
                case .double(let number): rendered = String(number)
                case .bool(let flag): rendered = String(flag)
                }
                var pieces: Set<String> = []
                windows(rendered, into: &pieces)
                #expect(pieces.isDisjoint(with: forbidden), "\(name).\(key) carries manuscript or prompt text")
            }
        }
    }

    @Test func theDebugTranscriptHoldsThePromptAndTheRawOutput() async throws {
        let directory = EngineTest.temporaryDirectory("dump")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paper = try makeSamplePaper()
        let mock = MockLLMProvider()
        let engine = EngineTest.engine([mock], paper: paper, dump: directory)
        _ = try await EngineTest.collect(engine.review(paper: paper, existing: [], context: EngineTest.context()))
        _ = try await EngineTest.collect(engine.discuss(paper: paper, comment: ReviewComment(
            id: UUID(), origin: .user, status: .pending, kind: .minor, category: "other", title: "T", body: "B",
            anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: Date(), updatedAt: Date()),
            message: "Why?", context: EngineTest.context()))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.count == 2)
        let review = try #require(files.first { $0.hasSuffix("-review.txt") })
        #expect(files.contains { $0.hasSuffix("-discussion.txt") })
        #expect(review.range(of: #"^\d{8}T\d{6}\.\d{3}Z(\.\d+)?-review\.txt$"#, options: .regularExpression) != nil)
        let url = directory.appendingPathComponent(review)
        let transcript = try String(contentsOf: url, encoding: .utf8)
        #expect(transcript.contains("OUTPUT FORMAT. Your output is read by a program"))
        #expect(transcript.contains("[[page 1]]"))
        #expect(transcript.contains("=== model output ===\n" + (try Fixtures.text("llm/review_clean.txt"))))
        #expect(transcript.contains("purpose: review"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func withoutADirectoryNothingIsWritten() {
        #expect(DebugDump(environment: [:]).isOn == false)
        #expect(DebugDump(environment: ["REFEREE_DEBUG_DUMP": ""]).isOn == false)
        #expect(DebugDump(environment: ["REFEREE_DEBUG_DUMP": "relative/dir"]).directory?.lastPathComponent == "dir")
    }
}
