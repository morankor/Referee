import Foundation
import Testing
@testable import ReviewEngine
import RefereeCore
import TestSupport

/// Venue-aware prompts, the conference scale and the style check (plan.md Appendix G.9, Appendix B.2, B.4, B.7, B.8).
@Suite struct VenuePromptTests {
    static let defaults = DefaultSettings.make()
    static var jet: VenueProfile { defaults.venue(id: "jet") }
    static var ec: VenueProfile { defaults.venue(id: "ec") }
    static var conference: VenueProfile { defaults.venue(id: VenueProfile.conferenceID) }

    static let jetLines = "Target journal: Journal of Economic Theory (JET)\nWhat a review for this journal should weigh: " + jet.guidance
    static let ecLines = "Target conference: ACM Conference on Economics and Computation (EC)\nWhat a review for this conference should weigh: "
        + ec.guidance
    static let conferenceScaleLine = "Recommendation scale, most favourable first: Accept; Weak accept; Borderline; Weak reject; Reject"

    /// Every request of the golden scenarios for `venue`, by scenario name.
    static func requests(_ venue: VenueProfile) async throws -> [String: LLMRequest] {
        Dictionary(uniqueKeysWithValues: try await VenueGolden.requests { $0.venue = venue }.map { ($0.name, $0.request) })
    }

    static func task(_ request: LLMRequest?) -> String {
        if case .text(let text)? = request?.parts.last { return text }
        return ""
    }

    // ---- a journal ----

    @Test func aNamedJournalKeepsTheJournalWordingAndAddsItsNameAndGuidanceEverywhere() async throws {
        let requests = try await Self.requests(Self.jet)
        let journal = try await VenueGolden.requests()                  // Journal (unspecified), for comparison
        let journalSystem = try #require(journal.first?.request.system)
        for name in requests.keys where name.hasPrefix("review.") { #expect(requests[name]?.system == journalSystem, "\(name)") }
        #expect(journalSystem.hasPrefix("You are refereeing a manuscript for a serious academic journal."))

        #expect(Self.task(requests["review.text.full#1"]) == """
            Write your referee comments on this manuscript in the required format.
            Reviewer's notes: Focus on identification.
            Ignore the typos.
            \(Self.jetLines)
            Comments already made, do not repeat them: First earlier comment; Second earlier comment
            """)
        #expect(Self.task(requests["review.text.bare#1"]) == "Write your referee comments on this manuscript in the required format.\n" + Self.jetLines)
        #expect(Self.task(requests["review.pdf.full#1"]).hasPrefix("The manuscript is the attached PDF."))
        #expect(Self.task(requests["review.pdf.full#1"]).contains("Ignore the typos.\n\(Self.jetLines)\nComments already made"))

        // The parts and the whole-paper pass, which named no venue before.
        for part in 1...3 {
            #expect(Self.task(requests["review.parts#\(part)"]).contains("do not comment on them.\n\(Self.jetLines)\n\n"), "part \(part)")
        }
        #expect(Self.task(requests["review.parts#4"]).contains("Comments you already made: First earlier comment; Second earlier comment; "
                                                                + "On part one; On part two\n\(Self.jetLines)\n\nWrite any further comments"))
        #expect(Self.task(requests["review.continued#2"]).hasPrefix("Your previous answer was cut off."))   // TASK_CONTINUE as it was

        // Discussions and questions open with the venue lines.
        for name in ["discuss.text#1", "ask.selection#1", "ask.general#1", "discuss.excerpt#1", "ask.excerpt#1"] {
            #expect(Self.task(requests[name]).hasPrefix(Self.jetLines + "\n\n"), "\(name)")
        }
        #expect(Self.task(requests["discuss.pdf#1"]).hasPrefix(PromptBuilder.pdfIntroduction + "\n\n" + Self.jetLines + "\n\nThe comment under discussion"))
        #expect(Self.task(requests["ask.selection#1"]).contains(Self.jetLines + "\n\nSelected passage (p. 1, line 9): «"))

        // The report: the journal's prompt and template, the venue lines first.
        let report = try #require(requests["report.text.full#1"])
        #expect(report.system == Self.defaults.prompts.reportSystem)
        #expect(Self.task(report).hasPrefix(Self.jetLines + "\nReviewer's notes: Focus on identification.\nIgnore the typos.\n\nApproved comments:\n[M1]"))
        #expect(Self.task(report).hasSuffix("Template:\n" + Self.defaults.prompts.reportTemplate))
        #expect(!Self.task(report).contains("Recommendation scale"))

        // A named venue is named by its profile: the paper's free text ("Journal of Examples") is not sent.
        for (name, request) in requests { #expect(!EngineTest.text(of: request).contains(VenueGolden.freeTextVenue), "\(name)") }
        // The voice revision sends the report and the findings only.
        #expect(requests["revise#1"].map { VenueGolden.sha256(VenueGolden.serialize($0)) } == VenueJournalTests.golden["revise#1"])
    }

    // ---- a conference ----

    @Test func aConferenceSpeaksToTheProgramCommitteeAndAsksForItsScale() async throws {
        let requests = try await Self.requests(Self.ec)
        let system = try #require(requests["review.text.full#1"]?.system)
        #expect(system.hasPrefix("You are refereeing a manuscript for the program committee of a selective academic conference. "))
        #expect(system.contains("Your job is to evaluate the paper, to help the program committee decide and to help the authors improve it."))
        #expect(!system.contains("serious academic journal") && !system.contains("help the editor decide"))
        let reviewSystem = Self.defaults.prompts.reviewSystem
            .replacingOccurrences(of: "for a serious academic journal", with: "for the program committee of a selective academic conference")
            .replacingOccurrences(of: "to help the editor decide", with: "to help the program committee decide")
        #expect(system.hasPrefix(reviewSystem + "\n\nCategories (use the id"))
        for name in requests.keys where name.hasPrefix("review.") { #expect(requests[name]?.system == system, "\(name)") }

        #expect(Self.task(requests["review.text.bare#1"]) == "Write your referee comments on this manuscript in the required format.\n" + Self.ecLines)
        #expect(Self.task(requests["review.parts#1"]).contains("do not comment on them.\n\(Self.ecLines)\n\n"))
        #expect(Self.task(requests["review.parts#4"]).contains("\n\(Self.ecLines)\n\nWrite any further comments"))
        #expect(Self.task(requests["discuss.text#1"]).hasPrefix(Self.ecLines + "\n\nThe comment under discussion"))
        #expect(Self.task(requests["ask.general#1"]).hasPrefix(Self.ecLines + "\n\nConversation so far:"))

        let report = try #require(requests["report.text.full#1"])
        #expect(report.system == Self.defaults.prompts.reportSystem(for: .conference))
        let text = Self.task(report)
        #expect(text.hasPrefix(Self.ecLines + "\n" + Self.conferenceScaleLine + "\nReviewer's notes: Focus on identification.\nIgnore the typos.\n\nApproved comments:"))
        #expect(text.hasSuffix("Template:\n" + Self.defaults.prompts.reportTemplate(for: .conference)))
        #expect(text.contains("## Chance of acceptance") && !text.contains("Publication probability"))
        // No revision round: the report asks for no revision plan.
        #expect(report.system.contains("Do not write a revision plan.") && report.system.contains("there is no revision round"))
        #expect(!report.system.contains("a path to resolution"))
    }

    @Test func anUnspecifiedConferenceNamesThePapersTypedVenueOrNone() async throws {
        let requests = try await Self.requests(Self.conference)
        let guidance = "What a review for this conference should weigh: " + Self.conference.guidance
        #expect(Self.task(requests["review.text.full#1"]).contains("Ignore the typos.\nTarget conference: Journal of Examples\n" + guidance + "\nComments already"))
        #expect(Self.task(requests["review.text.bare#1"]).hasSuffix("format.\nTarget conference: not specified\n" + guidance))
        #expect(Self.task(requests["review.parts#2"]).contains("them.\nTarget conference: Journal of Examples\n" + guidance + "\n\n"))
        #expect(Self.task(requests["report.text.bare#1"]).hasPrefix("Target conference: not specified\n" + guidance + "\n" + Self.conferenceScaleLine
                                                                   + "\nReviewer's notes: none\n"))
        #expect(requests["review.pdf.bare#1"]?.system.contains("for the program committee of a selective academic conference") == true)
    }

    // ---- what the referee edits ----

    @Test func aJournalUnspecifiedGivenGuidanceAddsTheGuidanceOnly() async throws {
        var journal = VenueProfile.unspecifiedJournal
        journal.guidance = "Weigh the welfare analysis."
        let requests = try await Self.requests(journal)
        let line = "What a review for this journal should weigh: Weigh the welfare analysis."
        #expect(Self.task(requests["review.text.full#1"]).contains("Ignore the typos.\nTarget journal: Journal of Examples\n\(line)\nComments"))
        #expect(Self.task(requests["review.text.bare#1"]) == "Write your referee comments on this manuscript in the required format.\n" + line)
        #expect(Self.task(requests["review.parts#1"]).contains("do not comment on them.\n\(line)\n\n"))
        #expect(Self.task(requests["discuss.text#1"]).hasPrefix(line + "\n\nThe comment under discussion"))
        #expect(Self.task(requests["report.text.bare#1"]).hasPrefix("Target journal: not specified\n\(line)\nReviewer's notes: none\n"))
        #expect(requests["review.text.full#1"]?.system.hasPrefix("You are refereeing a manuscript for a serious academic journal.") == true)
    }

    @Test func reportInstructionsGoToTheReportAloneAndGuidanceIsSentAsWritten() async throws {
        var venue = Self.ec
        venue.reportInstructions = "Write a separate paragraph for the committee."
        venue.guidance = "Weigh {notes} and {titles} as written."            // braces in a referee's text are never filled in
        let requests = try await Self.requests(venue)
        #expect(Self.task(requests["report.text.full#1"]).contains(Self.conferenceScaleLine
                                                                   + "\nInstructions for this report: Write a separate paragraph for the committee.\nReviewer's notes:"))
        for (name, request) in requests where !name.hasPrefix("report.") {
            #expect(!EngineTest.text(of: request).contains("Instructions for this report"), "\(name)")
        }
        #expect(Self.task(requests["review.parts#2"]).contains("weigh: Weigh {notes} and {titles} as written.\n\nYour notes on the earlier parts:\n"))
        #expect(Self.task(requests["review.parts#4"]).contains("weigh: Weigh {notes} and {titles} as written.\n\nWrite any further"))
    }

    @Test func aPhraseTheRefereeEditedAwayIsLeftAlone() {
        let edited = "You are refereeing a manuscript for a workshop. Help the organisers decide."
        #expect(PromptBuilder.venueWording(edited, kind: .conference) == edited)
        let twice = "for a serious academic journal, and for a serious academic journal"
        #expect(PromptBuilder.venueWording(twice, kind: .conference)
                == "for the program committee of a selective academic conference, and for a serious academic journal")
        #expect(PromptBuilder.venueWording(Self.defaults.prompts.reviewSystem, kind: .journal) == Self.defaults.prompts.reviewSystem)
    }

    // ---- the conference's recommendation ----

    @Test(arguments: [
        ("## Recommendation\n\nWeak accept. The model is new.\n", "Weak accept"),
        ("## Recommendation: weak reject\n", "Weak reject"),
        ("**Recommendation**\n\n**Borderline.** The proof of Lemma 2 decides it.\n", "Borderline"),
        ("## Recommendation\n\nReject. I cannot accept the main claim.\n", "Reject"),
        ("## Recommendation\n\nI lean towards it. Accept, if the proof of Lemma 2 holds.\n", "Accept"),
        ("## Recommendation\n\nMajor revision. The model needs work.\n", nil),
        ("## Recommendation\n\nIt depends on the committee.\n", nil),
        ("## Summary assessment\n\nWeak accept.\n", nil),
    ] as [(String, String?)])
    func theConferenceScaleIsParsedFromTheRecommendationSection(_ markdown: String, _ expected: String?) {
        #expect(ReportStructure.recommendationLabel(in: markdown, venue: Self.ec) == expected)
    }

    static func conferenceReport(recommendation: String, major: [String]) -> String {
        LintTests.report(recommendation: recommendation, major: major).replacingOccurrences(of: "## Publication probability", with: "## Chance of acceptance")
    }

    @Test func aConferenceReportGetsALabelOfTheScaleAndNoRecommendation() async throws {
        let paper = EngineTest.paper(pages: [["Line one of page one."]])
        let approved = ReviewComment(id: UUID(), origin: .user, status: .approved, kind: .major, category: "claims", title: "T", body: "B",
                                     anchor: Anchor(quote: "", confidence: .none, locationLabel: ""), includeInReport: true, createdAt: Date(), updatedAt: Date())
        let session = ReviewSession(schemaVersion: 1, id: UUID(), document: paper.ref, meta: VenueGolden.bareMeta, comments: [approved],
                                    createdAt: Date(), updatedAt: Date())
        var context = EngineTest.context()
        context.venue = Self.ec
        func generate(_ answer: String) async throws -> ReportDraft? {
            let mock = MockLLMProvider(script: EngineTest.script(.report, [MockResponse(text: answer)]))
            return try await EngineTest.collect(EngineTest.engine([mock], paper: paper).generateReport(paper: paper, session: session, context: context)).finished?.draft
        }
        let weakReject = try #require(try await generate(Self.conferenceReport(recommendation: "Weak reject. The result is known.", major: ["One."])))
        #expect(weakReject.recommendationLabel == "Weak reject")
        #expect(weakReject.recommendation == nil)
        let offScale = try #require(try await generate(Self.conferenceReport(recommendation: "Major revision. Rewrite it.", major: ["One."])))
        #expect(offScale.recommendationLabel == nil)                          // not a label of the scale: no recommendation
        #expect(offScale.recommendation == nil)

        // A voice revision keeps the label when the new text names none, and never sets a journal's recommendation.
        let mock = MockLLMProvider(script: EngineTest.script(.revise, [MockResponse(text: "## Summary assessment\n\nShorter.")]))
        let earlier = ReportDraft(markdown: "## Summary assessment\n\nLonger.", recommendation: .reject, recommendationLabel: "Borderline", userEdited: true)
        let revised = try #require(try await EngineTest.collect(EngineTest.engine([mock], paper: paper)
            .reviseVoice(draft: earlier, findings: [], context: context)).finished?.draft)
        #expect(revised.recommendationLabel == "Borderline")
        #expect(revised.recommendation == nil)
    }

    // ---- the style check ----

    @Test func theStyleCheckOfAConferenceReportUsesItsHeadingsAndItsScale() {
        let engine: any ReviewEngineProtocol = EngineTest.engine([], paper: EngineTest.paper(pages: [["x"]]))   // through the protocol
        func rules(_ markdown: String, _ venue: VenueProfile = Self.ec) -> [String] { engine.lint(reportMarkdown: markdown, venue: venue).map(\.rule) }

        #expect(rules(Self.conferenceReport(recommendation: "Weak reject. The result is known.", major: ["One."])).isEmpty)
        #expect(rules(Self.conferenceReport(recommendation: "Borderline. It could go either way.", major: ["One."])).isEmpty)
        #expect(rules(Self.conferenceReport(recommendation: "Borderline. It could go either way.", major: [])).isEmpty)
        #expect(rules(Self.conferenceReport(recommendation: "Weak accept. The result is new.", major: ["One."])) == ["recommendation-mismatch"])
        #expect(rules(Self.conferenceReport(recommendation: "Reject. Not for this venue.", major: [])) == ["recommendation-mismatch"])
        #expect(rules(Self.conferenceReport(recommendation: "Accept with minor revisions.", major: ["One."])) == ["recommendation-mismatch"])
        #expect(rules(Self.conferenceReport(recommendation: "Major revision. Rewrite it.", major: [])).isEmpty)   // no label, no mismatch

        // A journal's report checked for a conference lacks "Chance of acceptance", and the other way round.
        let journalReport = LintTests.report()
        let missing = engine.lint(reportMarkdown: journalReport, venue: Self.ec).filter { $0.rule == "missing-section" }.map(\.message)
        #expect(missing == ["Section 'Chance of acceptance' is missing."])
        let conferenceReport = Self.conferenceReport(recommendation: "Weak reject. Known.", major: ["One."])
        #expect(engine.lint(reportMarkdown: conferenceReport, venue: Self.jet).map(\.message) == ["Section 'Publication probability' is missing."])
        #expect(engine.lint(reportMarkdown: conferenceReport).map(\.message) == ["Section 'Publication probability' is missing."])

        // A bold line naming "Chance of acceptance" is a heading of a conference's report only.
        let bold = "**Summary assessment**\n\nFine.\n\n**Recommendation**\n\nWeak accept.\n\n**Chance of acceptance**\n\n30%.\n"
        #expect(engine.lint(reportMarkdown: bold, venue: Self.ec).map(\.message)
                == ["Section 'Major concerns' is missing.", "Section 'Minor concerns' is missing.", "Section 'Questions for the authors' is missing."])
    }
}
