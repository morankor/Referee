import Foundation
import Testing
import RefereeCore
import TestSupport

/// The committed fixtures (plan.md section 3.6, Appendices C and D.9): every file is present and decodable, and the
/// facts later work packages rely on hold. No PDFKit here: the PDFs are only checked for being PDFs, and everything
/// about their text comes from the raw dumps.
@Suite struct FixturesTests {
    /// Fixture name and page count, as section 3.6 lists them.
    static let manuscripts: [(name: String, pages: Int)] = [
        ("ay_nolinks", 4), ("s1_ruler", 4), ("ay_round_nolinks", 4), ("ay_links", 4), ("num_links", 4), ("num_twocol_links", 2), ("scanned", 1),
        ("ay_long", 16),                     // Gate 1: long enough for a small local model to read in parts
    ]
    /// The four fixtures made from one LaTeX source: they share every sentence.
    static let sameText = ["ay_nolinks", "s1_ruler", "ay_round_nolinks", "ay_links"]

    /// The folding of section 6.7, enough of it for these checks: compatibility decomposition, then letters and digits
    /// only, in lower case. Hyphens, spaces and line breaks vanish, so a quote is found however its lines were broken.
    private func fold(_ text: String) -> String {
        String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }))
    }
    private func foldedPage(_ raw: RawDocument, _ page: Int) -> String {
        raw.pages[page - 1].lines.map { fold($0.text) }.joined()
    }

    // ---- files ----

    @Test func theRootIsTheRepository() {
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: Fixtures.root.appendingPathComponent("Package.swift").path))
        #expect(Fixtures.url("pdf/ay_nolinks.pdf").path == Fixtures.root.path + "/Fixtures/pdf/ay_nolinks.pdf")
    }

    @Test func everyFixturePDFIsPresentAndIsAPDF() throws {
        for (name, _) in Self.manuscripts {
            let data = try Data(contentsOf: Fixtures.url("pdf/\(name).pdf"))
            #expect(data.count > 10_000, "\(name).pdf")
            #expect(data.prefix(5) == Data("%PDF-".utf8), "\(name).pdf")
        }
        let committed = try FileManager.default.contentsOfDirectory(atPath: Fixtures.url("pdf").path).filter { $0.hasSuffix(".pdf") }
        #expect(committed.sorted() == Self.manuscripts.map { $0.name + ".pdf" }.sorted())
    }

    @Test func everyRawDumpIsPresentAndDecodable() throws {
        for (name, pages) in Self.manuscripts {
            let raw = try Fixtures.rawDocument(name)
            #expect(raw.pages.count == pages, "\(name)")
            #expect(raw.pages.map(\.index) == Array(0..<pages), "\(name)")
            #expect(raw.pages.allSatisfy { $0.size.width > 500 && $0.size.height > 700 }, "\(name)")
        }
        let committed = try FileManager.default.contentsOfDirectory(atPath: Fixtures.url("raw").path).filter { $0.hasSuffix(".raw.json") }
        #expect(committed.sorted() == Self.manuscripts.map { $0.name + ".raw.json" }.sorted())
    }

    @Test func aMissingFixtureIsAnErrorThatNamesTheFile() {
        #expect(throws: (any Error).self) { try Fixtures.rawDocument("no_such_fixture") }
        do {
            _ = try Fixtures.text("llm/no_such_file.txt")
            Issue.record("reading a missing fixture should throw")
        } catch {
            #expect(String(describing: error).contains("Fixtures/llm/no_such_file.txt"))
            #expect(!String(describing: error).contains(Fixtures.root.path))        // no absolute path in the message
        }
    }

    // ---- what the dumps contain ----

    /// The guarantee of section 7.2: a line's text is the page string at its range, and ranges increase without overlap.
    @Test func everyLineIsTheSubstringAtItsRangeAndRangesIncrease() throws {
        for (name, _) in Self.manuscripts {
            for page in try Fixtures.rawDocument(name).pages {
                let string = page.string as NSString
                var end = 0
                for line in page.lines {
                    #expect(line.range.location >= end, "\(name) page \(page.index + 1)")
                    #expect(line.range.upperBound <= string.length, "\(name) page \(page.index + 1)")
                    guard line.range.location >= end, line.range.upperBound <= string.length else { break }
                    #expect(string.substring(with: line.range.nsRange) == line.text, "\(name) page \(page.index + 1)")
                    #expect(!line.text.hasSuffix("\n"))
                    #expect(line.bounds?.pageIndex == page.index)
                    end = line.range.upperBound
                }
            }
        }
    }

    @Test func theNumberOfLinesIsNotTheNumberOfLineBreaks() throws {
        let page = try Fixtures.rawDocument("ay_round_nolinks").pages[1]
        #expect(page.lines.count == 22)
        #expect(page.string.split(separator: "\n", omittingEmptySubsequences: false).count == 21)
        #expect(try Fixtures.rawDocument("ay_round_nolinks").pages.map(\.lines.count) == [17, 22, 21, 7])
    }

    @Test func linksAreWhatSection36Lists() throws {
        for name in ["ay_nolinks", "ay_round_nolinks", "s1_ruler", "scanned"] {
            #expect(try Fixtures.rawDocument(name).links.isEmpty, "\(name)")
        }

        let author = try Fixtures.rawDocument("ay_links").links
        #expect(author.count == 36)
        #expect(author.allSatisfy { if case .internalDestination = $0.target { return true } else { return false } })
        #expect(author.first?.text == "Banerjee")

        let numeric = try Fixtures.rawDocument("num_links").links
        #expect(numeric.count == 12)
        var internalPages: [Int] = []
        var urls: [String] = []
        for link in numeric {
            switch link.target {
            case .internalDestination(let pageIndex, _, _): internalPages.append(pageIndex)
            case .url(let url): urls.append(url)
            case .other: Issue.record("num_links has a link without a target")
            }
        }
        #expect(internalPages.count == 10)
        #expect(Set(internalPages) == [2, 3])
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.contains("doi.org/10.3115/v1/D14-1179") })

        #expect(try Fixtures.rawDocument("num_twocol_links").links.count == 12)
    }

    @Test func hyperrefFixturesHaveAnOutlineAndTheOthersHaveNone() throws {
        #expect(try Fixtures.rawDocument("ay_links").outline.map(\.title) == ["Introduction", "Model", "Results"])
        #expect(try Fixtures.rawDocument("num_links").outline.map(\.pageIndex) == [0, 1, 2])
        #expect(try Fixtures.rawDocument("num_links").outline.map(\.id) == [0, 1, 2])
        #expect(try Fixtures.rawDocument("ay_round_nolinks").outline.isEmpty)
    }

    @Test func theScannedFixtureHasNoText() throws {
        let page = try #require(try Fixtures.rawDocument("scanned").pages.first)
        #expect(page.string.isEmpty)
        #expect(page.lines.isEmpty)
    }

    @Test func theJournalStampsAreInTheRawText() throws {
        let numbered = try Fixtures.rawDocument("ay_nolinks")
        #expect(numbered.pages.allSatisfy { page in page.lines.contains { $0.text == "CONFIDENTIAL" } })
        #expect(numbered.pages[0].lines.contains { $0.text == "Table 2 is 0.91 with a confidence interval that crosses one, which is difficult to14" })
        #expect(numbered.pages[1].lines.prefix(2).map(\.text) == ["17", "function."])

        let ruler = try Fixtures.rawDocument("s1_ruler")
        for page in ruler.pages {
            #expect(page.lines.filter { Int($0.text) != nil }.count >= 60)           // the ruler 1…60, restarting on each page
            #expect(page.lines.contains { $0.text == "Page \(page.index + 1) of 4" })
            #expect(page.lines.contains { $0.text == "https://mc.example.org/jse" })
            #expect(page.lines.contains { $0.text == "For Peer Review" })
        }
    }

    // ---- model outputs ----

    @Test func theReviewAnswerHasSixBlocksWhoseQuotesAreInThePaper() throws {
        let review = try Fixtures.text("llm/review_clean.txt")
        let lines = review.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.filter { $0 == "@@COMMENT" }.count == 6)
        #expect(lines.filter { $0 == "@@END" }.count == 6)
        #expect(review.hasSuffix("@@END\n@@DONE\n"))
        #expect(lines.filter { $0.hasPrefix("kind: ") } == ["kind: major", "kind: major", "kind: major", "kind: minor", "kind: question", "kind: minor"])

        // Every quote stands on the page it names. Checked on the two fixtures whose raw text is clean; in the two
        // journal-stamped ones the same sentences are interrupted by margin numbers until PaperText has cleaned them.
        var page = 0
        var quotes: [(page: Int, quote: String)] = []
        for line in lines {
            if line.hasPrefix("page: ") { page = Int(line.dropFirst(6)) ?? 0 }
            if line.hasPrefix("quote: ") { quotes.append((page, String(line.dropFirst(7)))) }
        }
        #expect(quotes.map(\.page) == [1, 1, 1, 2, 2, 1])
        for name in ["ay_round_nolinks", "ay_links"] {
            let raw = try Fixtures.rawDocument(name)
            for (page, quote) in quotes {
                #expect(foldedPage(raw, page).contains(fold(quote)), "\(name), page \(page): \(quote)")
            }
        }
    }

    @Test func theOtherAnswersAreWhatAppendixD9Describes() throws {
        let discussion = try Fixtures.text("llm/discussion_revise.txt")
        #expect(discussion.contains("\n@@REVISED\nkind: minor\n"))
        #expect(discussion.hasSuffix("\n@@END\n"))

        let answer = try Fixtures.text("llm/question_answer.txt")
        #expect(answer.contains("\"The coefficient in Table 2 is 0.91\""))
        #expect(!answer.contains("@@"))

        let report = try Fixtures.text("llm/report_sample.txt")
        let headings = report.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        #expect(headings == ["## Summary assessment", "## Recommendation", "## Publication probability", "## Major concerns",
                             "## Minor concerns", "## Questions for the authors"])
        for hit in ["\u{2014}", "serves as", "robust"] { #expect(report.contains(hit)) }       // the three deliberate style-check hits
    }

    // ---- the sample session ----

    private func sampleSession() throws -> ReviewSession {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/sample.json")))
    }

    @Test func theSampleSessionHasSevenCommentsInTheStatesTheScenesNeed() throws {
        let session = try sampleSession()
        let comments = session.comments
        #expect(session.schemaVersion == 1)
        #expect(session.document.pageCount == 4)
        #expect(session.document.lastKnownPath == nil)
        #expect(comments.count == 7)
        #expect(Set(comments.map(\.id)).count == 7)
        #expect(comments.map(\.createdAt) == comments.map(\.createdAt).sorted())                // stored in creation order

        #expect(comments.filter { $0.status == .pending }.count == 4)
        #expect(comments.filter { $0.status == .approved }.count == 2)
        #expect(comments.filter { $0.status == .rejected }.count == 1)
        #expect(comments.filter { $0.origin == .user }.count == 1)
        #expect(Set(comments.map(\.kind)) == Set(CommentKind.allCases))

        // One comment is "similar": it points at an earlier comment of the same kind on the same quote that is not rejected.
        let similar = comments.filter { $0.similarTo != nil }
        #expect(similar.count == 1)
        let twin = try #require(similar.first)
        let original = try #require(comments.first { $0.id == twin.similarTo })
        #expect(twin.status == .pending)
        #expect(original.kind == twin.kind)
        #expect(original.anchor.quote == twin.anchor.quote)
        #expect(original.status != .rejected)
        #expect(original.createdAt < twin.createdAt)
        #expect(original.title != twin.title)

        // One comment has a discussion of two messages and a proposed revision.
        let discussed = comments.filter { !$0.thread.isEmpty }
        #expect(discussed.count == 1)
        #expect(discussed.first?.thread.map(\.role) == [.user, .assistant])
        #expect(discussed.first?.proposedRevision?.withdraw == false)

        // Every AI comment belongs to a run that is recorded.
        let runIDs = Set(session.runs.map(\.id))
        for comment in comments {
            if case .ai(let runID) = comment.origin { #expect(runIDs.contains(runID)) }
        }
        #expect(session.runs.allSatisfy { $0.status == .completed && $0.provider.providerID == "mock" })
    }

    @Test func theSampleSessionLeavesAnchoringToTheModel() throws {
        let session = try sampleSession()
        // No anchor carries spans or rectangles: offsets differ between the fixtures, so the model re-anchors on load.
        #expect(session.comments.allSatisfy { $0.anchor.spans.isEmpty && $0.anchor.rects.isEmpty && !$0.anchor.quote.isEmpty })

        // Five comments wait on a page for their quote to be located; one is unanchored for good; one names a page only.
        let unanchored = session.comments.filter { $0.anchor.confidence == AnchorConfidence.none }
        #expect(unanchored.count == 1)
        #expect(unanchored.first?.anchor.pageIndex == nil)
        #expect(unanchored.first?.anchor.locationLabel == "")
        let onPages = session.comments.filter { $0.anchor.confidence == .pageOnly }
        #expect(onPages.count == 6)
        #expect(onPages.allSatisfy { $0.anchor.locationLabel == "p. \(($0.anchor.pageIndex ?? -1) + 1)" })

        // Which quotes are in the paper, checked on the clean fixtures: four word for word, one only approximately
        // (it anchors as "fuzzy"), and two not at all (they stay page-only and unanchored).
        let found: [String: Bool] = [
            "The interval includes one, yet the effect is called robust": true,
            "The estimate cannot be told apart from no effect": true,
            "The main result is stated clearly": true,
            "The threshold is named but never defined": true,
            "Nothing shows that rollout timing is unrelated to outcomes": false,
            "How are the standard errors computed?": false,
            "There is no discussion of related work": false,
        ]
        #expect(Set(session.comments.map(\.title)) == Set(found.keys))
        for name in ["ay_round_nolinks", "ay_links"] {
            let raw = try Fixtures.rawDocument(name)
            let whole = (1...raw.pages.count).map { foldedPage(raw, $0) }.joined()
            for comment in session.comments {
                #expect(whole.contains(fold(comment.anchor.quote)) == found[comment.title], "\(name): \(comment.title)")
            }
        }
        let fuzzy = try #require(session.comments.first { $0.title == "Nothing shows that rollout timing is unrelated to outcomes" })
        #expect(fuzzy.anchor.quote == "Our identification strategy uses the staggered rollout of a disclosure rule.")
        #expect(fuzzy.status == .approved)
    }

    // ---- papers made from the fixtures ----

    @Test func identityPaperTextCopiesEveryLineAsBody() throws {
        let raw = try Fixtures.rawDocument("ay_nolinks")
        let text = identityPaperText(from: raw)
        #expect(text.pages.count == raw.pages.count)
        #expect(text.hasTextLayer)
        #expect(!text.hasMarginLineNumbers)
        #expect(text.titleGuess == nil)
        for (page, rawPage) in zip(text.pages, raw.pages) {
            #expect(page.index == rawPage.index)
            #expect(page.label == rawPage.label)
            #expect(page.size == rawPage.size)
            #expect(page.string == rawPage.string)
            #expect(page.lines.count == rawPage.lines.count)
            #expect(page.lines.allSatisfy { $0.kind == .body && $0.contentRange == $0.range && $0.marginNumber == nil && $0.pageIndex == page.index })
            #expect(page.lines.map(\.text) == rawPage.lines.map(\.text))
            #expect(page.lines.map(\.bounds) == rawPage.lines.map(\.bounds))
        }
        #expect(!identityPaperText(from: try Fixtures.rawDocument("scanned")).hasTextLayer)
        #expect(identityPaperText(from: RawDocument()).pages.isEmpty)
    }

    /// The 200-letter rule of section 7.2: a document with fewer than 200 letters, counted over all its pages, has no
    /// text layer. Digits, spaces and punctuation are not letters.
    @Test func identityPaperTextHasATextLayerFrom200Letters() {
        let size = PageSize(width: 612, height: 792)
        func document(_ pages: [String]) -> RawDocument {
            RawDocument(pages: pages.enumerated().map { RawPage(index: $0.offset, size: size, string: $0.element) })
        }
        #expect(!identityPaperText(from: document([String(repeating: "a", count: 199) + " 1234567890 -- ()"])).hasTextLayer)
        #expect(identityPaperText(from: document([String(repeating: "a", count: 200)])).hasTextLayer)
        #expect(identityPaperText(from: document([String(repeating: "b", count: 100), String(repeating: "é", count: 100)])).hasTextLayer)
        #expect(!identityPaperText(from: document(["", String(repeating: "9", count: 500)])).hasTextLayer)
    }

    @Test func theSamplePaperIsTheFixtureWithoutPDFKit() throws {
        let paper = try makeSamplePaper()
        let bytes = try Data(contentsOf: Fixtures.url("pdf/ay_round_nolinks.pdf"))
        #expect(paper.data == bytes)
        #expect(paper.ref.fileName == "ay_round_nolinks.pdf")
        #expect(paper.ref.byteCount == bytes.count)
        #expect(paper.ref.pageCount == 4)
        #expect(paper.ref.lastKnownPath == nil)
        #expect(paper.ref.sha256.count == 64)
        #expect(paper.ref.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!paper.isEncrypted)
        #expect(paper.text == identityPaperText(from: try Fixtures.rawDocument("ay_round_nolinks")))
        #expect(paper.links.isEmpty)

        let linked = try makeSamplePaper(fixture: "ay_links")
        #expect(linked.links.count == 36)
        #expect(linked.outline.count == 3)
        #expect(linked.ref.sha256 != paper.ref.sha256)
        #expect(throws: (any Error).self) { try makeSamplePaper(fixture: "no_such_fixture") }
    }
}
