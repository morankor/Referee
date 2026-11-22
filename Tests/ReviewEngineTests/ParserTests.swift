import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// `CommentStreamParser` (plan.md section 6.5): rows "parser, clean", "parser, chunking", "parser, sloppy" and
/// "parser, garbage" of WP6.
@Suite struct ParserTests {
    private let categories = CategoryTable(rubric: DefaultSettings.make().rubric)

    /// A closed block without its id, so that blocks from two runs can be compared.
    struct Closed: Equatable {
        var kind: CommentKind?, category: String?, page: Int?, quote: String?, title: String?, body: String, suggestion: String?
        init(_ draft: DraftComment) {
            kind = draft.kind; category = draft.category; page = draft.page; quote = draft.quote; title = draft.title; body = draft.body
            suggestion = draft.suggestion
        }
    }

    struct Run {
        var outputs: [CommentStreamParser.Output] = []
        var parser: CommentStreamParser
        var closed: [DraftComment] {
            outputs.compactMap { if case .blockClosed(let draft) = $0 { return draft } else { return nil } }
        }
        var notes: [String] { outputs.compactMap { if case .notes(let text) = $0 { return text } else { return nil } } }
    }

    /// Feeds `text` in pieces of `size` characters (or unicode scalars), then finishes.
    private func parse(_ text: String, chunk size: Int = .max, byScalars: Bool = false) -> Run {
        var run = Run(parser: CommentStreamParser(mode: .review, categories: categories))
        if byScalars {
            let scalars = Array(text.unicodeScalars)
            var start = 0
            while start < scalars.count {
                let end = min(scalars.count, start + size)
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[start..<end])
                run.outputs += run.parser.feed(String(piece))
                start = end
            }
        } else if size >= text.count {
            run.outputs += run.parser.feed(text)
        } else {
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
                run.outputs += run.parser.feed(String(text[start..<end]))
                start = end
            }
        }
        run.outputs += run.parser.finish()
        return run
    }

    // ---- parser, clean ----

    @Test func theCleanFixtureGivesSixCommentsAndDone() throws {
        let run = parse(try Fixtures.text("llm/review_clean.txt"))
        let closed = run.closed
        #expect(closed.count == 6)
        #expect(closed.map(\.kind) == [.major, .major, .major, .minor, .question, .minor])
        #expect(closed.map(\.category) == ["claims", "assumptions", "claims", "math", "math", "positioning"])
        #expect(closed.map(\.page) == [1, 1, 1, 2, 2, 1])
        #expect(closed.map(\.quote) == [
            "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one",
            "Our identification strategy exploits the staggered rollout of a disclosure rule.",
            "The effect is statistically significant but economically small.",
            "It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.",
            "Proposition 1 states that an information cascade begins with positive probability.",
            "network structure determines whether learning is efficient",
        ])
        #expect(closed.map(\.title) == [
            "The interval includes one, yet the effect is called robust",
            "Nothing shows that rollout timing is unrelated to outcomes",
            "Abstract and introduction disagree about the result",
            "The sign of the multiplier is not established",
            "Which signal structure does Proposition 1 need?",
            "Relation to the network-learning results is asserted, not shown",
        ])
        #expect(closed[0].body.hasPrefix("The introduction reports a coefficient of 0.91"))
        #expect(closed[0].body.hasSuffix("As reported, the data are consistent with no effect."))
        #expect(closed[0].suggestion == "State the interval wherever the estimate is quoted and drop \"robust\" unless a specific robustness check supports it.")
        #expect(closed[1].suggestion == "Describe how the rollout order was set and show an event-study plot with pre-period coefficients.")
        #expect(closed[2...].allSatisfy { $0.suggestion == nil })
        #expect(run.parser.sawDone)
        #expect(run.parser.sawAnyBlock)
        #expect(!run.parser.hasOpenBlock)
        #expect(run.parser.rawText == (try Fixtures.text("llm/review_clean.txt")))
        #expect(run.outputs.last == .done)
        // Every block was announced before it closed, with the same id.
        let started = run.outputs.compactMap { if case .draftStarted(let id) = $0 { return id } else { return nil } }
        #expect(started == closed.map(\.id))
    }

    // ---- parser, chunking ----

    @Test(arguments: ["llm/review_clean.txt", "sloppy", "dupes"])
    func anyChunkingGivesTheSameBlocksAndDraftsOnlyGrow(_ name: String) throws {
        let text = name.hasPrefix("llm/") ? try Fixtures.text(name) : try EngineTest.fixture("review_\(name).txt")
        let whole = parse(text).closed.map(Closed.init)
        #expect(!whole.isEmpty)
        for size in [1, 7, 4_096] {
            let run = parse(text, chunk: size)
            #expect(run.closed.map(Closed.init) == whole, "chunks of \(size) characters")
            #expect(run.parser.sawDone == parse(text).parser.sawDone)
            expectDraftsOnlyGrow(run.outputs, label: "\(name), chunks of \(size)", requireUpdates: size < 100)
        }
        // Unicode scalars one at a time: a CR LF split between two deltas, a letter and its accent apart.
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(parse(crlf, chunk: 1, byScalars: true).closed.map(Closed.init) == whole)
        #expect(parse(text, chunk: 3, byScalars: true).closed.map(Closed.init) == whole)
    }

    /// For each draft, successive updates never lose anything: kind, category and page do not change once set, and
    /// quote, title, body and suggestion only get longer.
    private func expectDraftsOnlyGrow(_ outputs: [CommentStreamParser.Output], label: String, requireUpdates: Bool) {
        var last: [UUID: DraftComment] = [:]
        var updates = 0
        for output in outputs {
            guard case .draftUpdated(let draft) = output else { continue }
            updates += 1
            defer { last[draft.id] = draft }
            guard let before = last[draft.id] else { continue }
            func grows(_ old: String?, _ new: String?) -> Bool { old == nil || (new ?? "").hasPrefix(old!) }
            #expect(before.kind == nil || before.kind == draft.kind, "\(label): kind changed")
            #expect(before.category == nil || before.category == draft.category, "\(label): category changed")
            #expect(before.page == nil || before.page == draft.page, "\(label): page changed")
            #expect(grows(before.quote, draft.quote), "\(label): quote shrank from \(before.quote ?? "") to \(draft.quote ?? "")")
            #expect(grows(before.title, draft.title), "\(label): title shrank from \(before.title ?? "") to \(draft.title ?? "")")
            #expect(draft.body.hasPrefix(before.body), "\(label): body shrank from \(before.body) to \(draft.body)")
            #expect(grows(before.suggestion, draft.suggestion), "\(label): suggestion shrank")
        }
        if requireUpdates { #expect(updates > 0, "\(label): no draft updates") }
    }

    @Test func theUnfinishedLastLineFeedsTheDraft() {
        var parser = CommentStreamParser(mode: .review, categories: categories)
        _ = parser.feed("@@COMMENT\nkind: major\nquote: The effect is")
        var outputs = parser.feed(" statistically signif")
        guard case .draftUpdated(let draft)? = outputs.last else {
            Issue.record("expected a draft update, got \(outputs)")
            return
        }
        #expect(draft.kind == .major)
        #expect(draft.quote == "The effect is statistically signif")
        // A line that may still become a marker is not shown: "@@EN" is not body text.
        _ = parser.feed("icant.\ntitle: A title\nbody:\nFirst line\n")
        outputs = parser.feed("@@EN")
        #expect(outputs.isEmpty)
        outputs = parser.feed("D\n")
        guard case .blockClosed(let closed)? = outputs.first else {
            Issue.record("expected the block to close, got \(outputs)")
            return
        }
        #expect(closed.body == "First line")
        #expect(closed.title == "A title")
    }

    // ---- parser, sloppy ----

    @Test func theSloppyFixtureGivesTheFiveExpectedComments() throws {
        let run = parse(try EngineTest.fixture("review_sloppy.txt"))
        let closed = run.closed
        #expect(closed.count == 5)
        guard closed.count == 5 else { return }
        #expect(closed.map(\.kind) == [.major, .minor, .minor, .major, .question])
        #expect(closed.map(\.category) == ["claims", "math", "positioning", "assumptions", "math"])
        #expect(closed.map(\.page) == [1, 2, 1, 1, 2])
        #expect(closed.map(\.quote) == [
            "The effect is statistically significant but economically small.",
            "It is easy to see that the inequality is preserved when both sides are multiplied by the likelihood ratio.",
            "network structure determines whether learning is efficient",
            "Our identification strategy exploits the staggered rollout of a disclosure rule.",
            "Proposition 1 states that an information cascade begins with positive probability.",
        ])
        #expect(closed.map(\.title) == [
            "The abstract and the introduction disagree",
            "The step needs the sign of the likelihood ratio",
            "Relation to the network results is asserted",
            "Rollout timing is not shown to be unrelated to outcomes",
            "Does Proposition 1 need bounded signals?",
        ])
        // A line that looks like a field is body text once the body has started.
        #expect(closed[0].body == """
            The abstract calls the effect statistically significant, while the introduction reports an interval that crosses one.
            Title: this is part of the body
            Both statements cannot hold for the same specification.
            """)
        #expect(closed[0].suggestion == "Say which specification each statement refers to.")
        #expect(closed[1].body == "Multiplying by the ratio keeps the direction of the inequality only if the ratio is positive.")
        #expect(closed[1].suggestion == "Show the step and say where positivity is used.")       // "- Fix:"
        #expect(closed[2].suggestion == nil)
        #expect(closed[3].suggestion == "Show an event-study plot with pre-period coefficients.")   // "resolution:"
        #expect(closed[4].suggestion == nil)                                                       // "suggestion: N/A"
        #expect(!run.parser.sawDone)
        #expect(!run.parser.hasOpenBlock)
    }

    @Test(arguments: [
        ("kind: Major concern", CommentKind.major), ("type: minor", .minor), ("severity: critical", .major), ("kind: query", .question),
        ("kind: praise", .strength), ("kind: positive", .strength), ("kind: weakness", .minor), ("kind:", .minor), ("kind: question", .question),
    ])
    func kindValuesAreCleanedUp(_ line: String, _ expected: CommentKind) {
        let run = parse("@@COMMENT\n\(line)\ntitle: T\nbody:\nB\n@@END\n")
        #expect(run.closed.first?.kind == expected)
    }

    @Test func valuesAreCleanedUpWhenTheBlockCloses() {
        let text = """
            @@COMMENT
            kind: minor
            category: Claims vs. evidence
            pages: p. 12-13
            quote: «The coefficient in Table 2 is 0.91»
            title: **A title that goes on and on** \(String(repeating: "and on ", count: 30))
            body:

            The body, with an empty line before it.

            suggestion: No suggestion.
            @@END
            @@COMMENT
            category: something else entirely
            body:
            A comment without a title gets the first ten words of its body as one, like this one does.
            @@END
            @@COMMENT
            kind: major
            page: 3
            quote: only a quote, so the block is dropped
            @@END
            @@DONE
            """
        let closed = parse(text).closed
        #expect(closed.count == 2)
        guard closed.count == 2 else { return }
        #expect(closed[0].category == "claims")
        #expect(closed[0].page == 12)
        #expect(closed[0].quote == "The coefficient in Table 2 is 0.91")
        #expect(closed[0].title?.hasPrefix("A title that goes on and on and on") == true)
        #expect(closed[0].title!.count <= 120)
        #expect(closed[0].title?.contains("*") == false)
        #expect(closed[0].body == "The body, with an empty line before it.")
        #expect(closed[0].suggestion == nil)
        #expect(closed[1].kind == .minor)
        #expect(closed[1].category == "other")
        #expect(closed[1].title == "A comment without a title gets the first ten words")
    }

    @Test func notesFollowTheNotesMarker() {
        let run = parse("""
            @@COMMENT
            kind: minor
            title: On this part
            body:
            Text.
            @@END
            @@NOTES
            The paper asks whether traders herd.
            p.2: Proposition 1 states that an information cascade begins with positive probability.
            @@DONE
            """)
        #expect(run.closed.count == 1)
        #expect(run.notes.last == "The paper asks whether traders herd.\np.2: Proposition 1 states that an information cascade begins with positive probability.")
        #expect(run.parser.sawNotes)
        #expect(run.parser.sawDone)
    }

    @Test func aBlockLeftOpenIsClosedByFinish() {
        var parser = CommentStreamParser(mode: .review, categories: categories)
        _ = parser.feed("@@COMMENT\nkind: major\ntitle: Cut off\nbody:\nThe body was cut in the mid")
        #expect(parser.hasOpenBlock)
        let outputs = parser.finish()
        guard case .blockClosed(let draft)? = outputs.first else {
            Issue.record("expected the open block to close, got \(outputs)")
            return
        }
        #expect(draft.body == "The body was cut in the mid")
        #expect(!parser.hasOpenBlock)
        #expect(parser.finish().isEmpty)
        #expect(parser.feed("more").isEmpty)
    }

    // ---- parser, garbage ----

    @Test(.timeLimit(.minutes(2))) func randomBytesNeitherCrashNorStall() {
        var generator = SplitMix64(seed: 0x5EED)
        for round in 0..<4 {
            var bytes = (0..<200_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            if round % 2 == 1 {
                // Garbage with structure in it: markers and field names among the bytes.
                let pieces = ["\n@@COMMENT\n", "\nkind: major\n", "\nbody:\n", "\n@@END\n", "\n@@NOTES\n", "\n**Quote:** ", "\n@@DONE\n", "\r\n"]
                for position in stride(from: 0, to: bytes.count, by: 997) {
                    let piece = Array(pieces[Int(generator.next() % UInt64(pieces.count))].utf8)
                    bytes.replaceSubrange(position..<min(bytes.count, position + piece.count), with: piece)
                }
            }
            let text = String(decoding: bytes, as: UTF8.self)
            let started = ContinuousClock.now
            var parser = CommentStreamParser(mode: .review, categories: categories)
            var start = text.startIndex
            while start < text.endIndex {
                let size = Int(generator.next() % 64) + 1
                let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
                _ = parser.feed(String(text[start..<end]))
                start = end
            }
            _ = parser.finish()
            #expect(ContinuousClock.now - started < .seconds(30))
            #expect(parser.rawText == text)
            _ = ParserFallbacks.jsonComments(in: text, categories: categories)
        }
    }

    @Test(.timeLimit(.minutes(2))) func aFiveMegabyteLineNeitherCrashesNorStalls() {
        let long = String(repeating: "x", count: 5_000_000)
        let started = ContinuousClock.now
        // Outside a block, in a body, and as an unfinished line fed in small pieces.
        var outside = CommentStreamParser(mode: .review, categories: categories)
        _ = outside.feed(long + "\n")
        #expect(outside.finish().isEmpty)

        var inBody = CommentStreamParser(mode: .review, categories: categories)
        var outputs = inBody.feed("@@COMMENT\nkind: major\ntitle: Long\nbody:\n")
        var start = long.startIndex
        while start < long.endIndex {
            let end = long.index(start, offsetBy: 65_536, limitedBy: long.endIndex) ?? long.endIndex
            outputs += inBody.feed(String(long[start..<end]))
            start = end
        }
        outputs += inBody.feed("\n@@END\n")
        outputs += inBody.finish()
        let closed = outputs.compactMap { if case .blockClosed(let draft) = $0 { return draft } else { return nil } }
        #expect(closed.count == 1)
        #expect(closed.first?.body.count ?? 0 <= CommentStreamParser.maxStoredLineLength)
        #expect(ContinuousClock.now - started < .seconds(60))

        // A long line of brackets for the JSON fallback, and the unstructured fallback's cut.
        let brackets = String(repeating: "[", count: 1_000_000)
        #expect(ParserFallbacks.jsonComments(in: brackets, categories: categories).isEmpty)
        #expect(ParserFallbacks.unstructuredDraft(from: long).body.count == ParserFallbacks.unstructuredBodyLength)
    }
}

/// A small deterministic generator, so that the garbage is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
