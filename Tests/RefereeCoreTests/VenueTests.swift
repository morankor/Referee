import Foundation
import Testing
import RefereeCore

/// Venues (plan.md Appendix G.9, Appendix B.8): the built-ins, the settings list, files written before venues, and the
/// recommendation scale.
@Suite struct VenueTests {
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var jet: VenueProfile { DefaultSettings.venues[2] }
    private static var ec: VenueProfile { DefaultSettings.venues[3] }

    // ---- the built-ins ----

    @Test func theBuiltInsAreTheFourVenuesOfAppendixB8() {
        let venues = DefaultSettings.venues
        #expect(venues.map(\.id) == ["journal", "conference", "jet", "ec"])
        #expect(venues.map(\.kind) == [.journal, .conference, .journal, .conference])
        #expect(venues.map(\.displayName) == ["Journal (unspecified)", "Conference (unspecified)", "Journal of Economic Theory (JET)",
                                              "ACM Conference on Economics and Computation (EC)"])
        #expect(venues.map(\.isUnspecified) == [true, true, false, false])
        #expect(venues.allSatisfy { $0.isBuiltIn })
        #expect(venues.allSatisfy { $0.reportInstructions == nil })
        #expect(venues[0] == .unspecifiedJournal)
        #expect(venues[0].guidance.isEmpty)                                     // Journal (unspecified) adds nothing
        #expect(DefaultSettings.conferenceScale == ["Accept", "Weak accept", "Borderline", "Weak reject", "Reject"])
        #expect(venues[1].recommendationScale == DefaultSettings.conferenceScale && Self.ec.recommendationScale == DefaultSettings.conferenceScale)
        #expect(Self.jet.recommendationScale.isEmpty)
    }

    /// Only well-established, non-numeric characteristics: no number, percentage, page limit or date in any guidance.
    @Test func theGuidanceSaysWhatEachVenueWeighsWithoutNumbers() {
        for venue in DefaultSettings.venues.dropFirst() {
            #expect(!venue.guidance.isEmpty)
            #expect(venue.guidance.rangeOfCharacter(from: .decimalDigits) == nil, "\(venue.id) has a digit")
            #expect(!venue.guidance.contains("%") && !venue.guidance.contains("\u{2014}") && !venue.guidance.contains("\n"))
        }
        #expect(Self.jet.guidance.hasPrefix("Judge the paper as a contribution to economic theory."))
        for theme in ["important and new", "correctness and rigour", "assumptions should be stated clearly and justified", "as general as",
                      "theory literature", "exposition"] {
            #expect(Self.jet.guidance.contains(theme), "JET: \(theme)")
        }
        for theme in ["novelty and significance", "combining economic and computational insight", "technical soundness as far as a review can",
                      "clear from the main body", "accept or reject, with no revision round"] {
            #expect(Self.ec.guidance.contains(theme), "EC: \(theme)")
        }
    }

    @Test func newSettingsStoreNoVenueListAndStartPapersOnJournalUnspecified() {
        let settings = DefaultSettings.make()
        #expect(settings.venueProfiles == nil)
        #expect(settings.defaultVenueID == nil)
        #expect(settings.venues == DefaultSettings.venues)
        #expect(settings.defaultVenue == .unspecifiedJournal)
        #expect(settings.prompts.reportSystem(for: .journal) == settings.prompts.reportSystem)
        #expect(settings.prompts.reportTemplate(for: .journal) == settings.prompts.reportTemplate)
        let conference = settings.prompts.reportSystem(for: .conference)
        #expect(conference == settings.prompts.conferenceReportSystem)
        #expect(conference.hasPrefix("You are drafting a conference review from a referee's approved notes."))
        #expect(conference.contains("Recommendation: exactly one label of the recommendation scale given below"))
        #expect(conference.contains("Chance of acceptance: a blunt, calibrated percentage range"))
        #expect(conference.contains("Do not write a revision plan."))
        #expect(!conference.contains("Publication probability") && !conference.contains("a path to resolution"))
        #expect(settings.prompts.reportTemplate(for: .conference).components(separatedBy: "\n").filter { !$0.isEmpty } == [
            "## Summary assessment", "## Recommendation", "## Chance of acceptance", "## Major concerns", "## Minor concerns",
            "## Questions for the authors",
        ])
        #expect(!conference.hasSuffix("\n") && !conference.hasPrefix("\n"))
    }

    // ---- files written before venues ----

    /// A settings.json with the keys of the format before venues (commit c1c6ee3): no venue list, no default venue, no
    /// conference report texts.
    static let settingsBeforeVenues = #"""
        {
          "defaults" : { "review" : { "model" : "gemma4:e4b", "providerID" : "ollama" } },
          "privacy" : { "confirmFirstSendPerDocument" : true, "localOnly" : false, "resolveReferencesInBackground" : false },
          "prompts" : {
            "discussionSystem" : "Discuss.", "questionSystem" : "Answer.", "quickQuestions" : [ "Why?" ], "reportSystem" : "My own report rules.",
            "reportTemplate" : "## Summary assessment", "reviewSystem" : "You are refereeing a manuscript for a serious academic journal.",
            "voiceRevisionSystem" : "Revise."
          },
          "providers" : { "ollama" : { "cachedModels" : [ ], "enabled" : true, "extraArguments" : [ ], "inputMode" : "auto" } },
          "references" : { "crossrefMailto" : "", "pdfCacheLimitMB" : 500 },
          "rubric" : [ { "enabled" : true, "guidance" : "Anything.", "id" : "other", "name" : "Other" } ],
          "schemaVersion" : 1,
          "ui" : { "autoAdvanceAfterTriage" : true, "showRejectedHighlights" : false, "sidebarWidth" : 380, "stripMarginLineNumbers" : true }
        }
        """#

    @Test func aSettingsFileWrittenBeforeVenuesLoadsWithTheBuiltIns() throws {
        let settings = try Self.decoder().decode(AppSettings.self, from: Data(Self.settingsBeforeVenues.utf8))
        #expect(settings.venueProfiles == nil)
        #expect(settings.venues == DefaultSettings.venues)
        #expect(settings.defaultVenue == .unspecifiedJournal)
        #expect(settings.prompts.reportSystem == "My own report rules.")                   // the user's journal texts are kept
        #expect(settings.prompts.reportSystem(for: .journal) == "My own report rules.")
        #expect(settings.prompts.conferenceReportSystem == nil)
        #expect(settings.prompts.reportSystem(for: .conference) == DefaultSettings.make().prompts.conferenceReportSystem)
        #expect(settings.prompts.reportTemplate(for: .conference) == DefaultSettings.make().prompts.conferenceReportTemplate)
        // Saved again, it gains no venue key until a venue is edited.
        let written = String(decoding: try Self.encoder().encode(settings), as: UTF8.self)
        #expect(!written.contains("venueProfiles") && !written.contains("defaultVenueID") && !written.contains("conferenceReport"))
    }

    /// A session.json from before venues: free text in `targetVenue`, no venue id, a report with a recommendation and no label.
    static let sessionBeforeVenues = #"""
        {
          "comments" : [ ], "consents" : [ ], "conversations" : [ ], "createdAt" : "2026-11-18T11:06:40Z",
          "document" : { "byteCount" : 10, "fileName" : "manuscript.pdf", "pageCount" : 1, "sha256" : "9f2c" },
          "id" : "55555555-5555-4555-8555-555555555555",
          "meta" : { "reviewerNotes" : "", "targetVenue" : "Journal of Examples", "title" : "A title" },
          "report" : { "basedOnCommentIDs" : [ ], "markdown" : "## Recommendation\n\nMajor revision.", "recommendation" : "majorRevision",
                       "userEdited" : false, "versions" : [ ] },
          "runs" : [ ], "schemaVersion" : 1, "updatedAt" : "2026-11-18T11:06:40Z"
        }
        """#

    @Test func aSessionWrittenBeforeVenuesOpensOnJournalUnspecifiedWithItsText() throws {
        let session = try Self.decoder().decode(ReviewSession.self, from: Data(Self.sessionBeforeVenues.utf8))
        #expect(session.meta.venueID == nil)
        #expect(session.meta.targetVenue == "Journal of Examples")
        #expect(DefaultSettings.make().venue(id: session.meta.venueID) == .unspecifiedJournal)
        #expect(session.report?.recommendation == .majorRevision)
        #expect(session.report?.recommendationLabel == nil)
        // Written again, nothing is added: the new fields are optional and nil.
        let rewritten = try JSONSerialization.jsonObject(with: Self.encoder().encode(session)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(Self.sessionBeforeVenues.utf8)) as? NSDictionary
        #expect(rewritten != nil && rewritten == original)
    }

    @Test func theNewFieldsSurviveTheStoreFormat() throws {
        var settings = DefaultSettings.make()
        settings.venues.append(VenueProfile(id: "wine", shortName: "WINE", fullName: "Web and Internet Economics", kind: .conference,
                                            guidance: "Weigh it.", reportInstructions: "Keep it short.", recommendationScale: ["Accept", "Reject"]))
        settings.defaultVenueID = "wine"
        #expect(try Self.decoder().decode(AppSettings.self, from: Self.encoder().encode(settings)) == settings)

        let meta = ManuscriptMeta(title: "T", targetVenue: "Journal of Economic Theory (JET)", reviewerNotes: "", venueID: "jet")
        let report = ReportDraft(markdown: "x", recommendationLabel: "Weak accept", userEdited: true)
        #expect(try Self.decoder().decode(ManuscriptMeta.self, from: Self.encoder().encode(meta)) == meta)
        #expect(try Self.decoder().decode(ReportDraft.self, from: Self.encoder().encode(report)) == report)
    }

    // ---- the list in the settings ----

    @Test func theListAlwaysHoldsTheBuiltInsOnceEach() {
        var settings = DefaultSettings.make()
        let own = VenueProfile(id: "own", shortName: "", fullName: "My journal", kind: .journal, guidance: "")
        settings.venueProfiles = [Self.ec, own, Self.ec]                       // a list from a hand-edited file
        #expect(settings.venues.map(\.id) == ["journal", "conference", "jet", "ec", "own"])
        settings.venues = settings.venues.filter { $0.id != "jet" }            // a built-in cannot be dropped
        #expect(settings.venues.map(\.id) == ["journal", "conference", "jet", "ec", "own"])
        settings.venues = DefaultSettings.venues                               // the shipped list is stored as nil
        #expect(settings.venueProfiles == nil)

        var edited = Self.jet
        edited.guidance = "Only theory."
        settings.venues[2] = edited
        #expect(settings.venueProfiles?.count == 4)
        #expect(settings.venue(id: "jet").guidance == "Only theory.")
    }

    @Test func anUnknownOrMissingVenueIdIsJournalUnspecifiedAsEdited() {
        var settings = DefaultSettings.make()
        #expect(settings.venue(id: nil) == .unspecifiedJournal)
        #expect(settings.venue(id: "deleted-venue") == .unspecifiedJournal)
        #expect(settings.venue(id: "ec") == Self.ec)
        var journal = VenueProfile.unspecifiedJournal
        journal.guidance = "Be brief."
        settings.venues[0] = journal
        #expect(settings.venue(id: "deleted-venue").guidance == "Be brief.")
        settings.defaultVenueID = "deleted-venue"
        #expect(settings.defaultVenue.id == "journal")
        settings.defaultVenueID = "ec"
        #expect(settings.defaultVenue == Self.ec)
    }

    // ---- names and scales ----

    @Test func theDisplayNameJoinsTheFullAndTheShortName() {
        func venue(_ short: String, _ full: String, id: String = "x") -> VenueProfile {
            VenueProfile(id: id, shortName: short, fullName: full, kind: .journal, guidance: "")
        }
        #expect(venue("JET", "Journal of Economic Theory").displayName == "Journal of Economic Theory (JET)")
        #expect(venue("", "Journal of Economic Theory").displayName == "Journal of Economic Theory")
        #expect(venue("Econometrica", " Econometrica ").displayName == "Econometrica")
        #expect(venue("JET", "").displayName == "JET")
        #expect(venue("Journal", "Journal (unspecified)", id: "journal").displayName == "Journal (unspecified)")
    }

    @Test func aJournalHasTheFourRecommendationsAndAConferenceItsCleanedScale() {
        #expect(Self.jet.scale == ["Accept", "Minor revision", "Major revision", "Reject"])
        #expect(Recommendation.allCases.map(\.label) == Self.jet.scale)
        #expect(Recommendation.allCases.allSatisfy { Recommendation(label: $0.label.uppercased()) == $0 })
        #expect(Recommendation(label: " minor revision ") == .minorRevision)
        #expect(Recommendation(label: "Weak accept") == nil)
        #expect(Self.ec.scale == DefaultSettings.conferenceScale)
        var own = Self.ec
        own.recommendationScale = [" Strong accept", "", "Accept", "accept", "Reject "]
        #expect(own.scale == ["Strong accept", "Accept", "Reject"])
        own.recommendationScale = ["  ", ""]
        #expect(own.scale == DefaultSettings.conferenceScale)
    }

    @Test(arguments: [
        ("Weak accept. The result is new.", "Weak accept"),
        ("Accept.", "Accept"),
        ("**Weak reject.** The model is not new.", "Weak reject"),
        ("weak-accept, if the proof holds", "Weak accept"),
        ("Borderline, leaning to accept.", "Borderline"),
        ("I recommend reject: the main theorem is known.", "Reject"),
        ("The paper is acceptable but narrow; weak accept.", "Weak accept"),
        ("Major revision.", nil),
        ("Minor revision: two derivations need writing out.", nil),
        ("Unacceptable as it stands.", nil),
    ] as [(String, String?)])
    func aTextNamesTheEarliestLabelOfTheScale(_ text: String, _ expected: String?) {
        #expect(Self.ec.scaleLabel(in: text) == expected)
    }

    @Test func aRecommendationDisagreesWithTheConcernsOnEitherScale() {
        // A journal: the rule as it was before venues.
        for (label, positive) in [("Accept", true), ("Minor revision", true), ("Major revision", false), ("Reject", false)] {
            #expect(Self.jet.recommendationMismatch(label: label, majorConcerns: 2) == positive)
            #expect(Self.jet.recommendationMismatch(label: label, majorConcerns: 0) == !positive)
        }
        // The default conference scale: two favourable labels, the middle one neutral, two unfavourable.
        let expected: [(String, withConcerns: Bool, without: Bool)] = [("Accept", true, false), ("Weak accept", true, false), ("Borderline", false, false),
                                                                       ("Weak reject", false, true), ("reject", false, true)]
        for (label, withConcerns, without) in expected {
            #expect(Self.ec.recommendationMismatch(label: label, majorConcerns: 1) == withConcerns, "\(label) with a concern")
            #expect(Self.ec.recommendationMismatch(label: label, majorConcerns: 0) == without, "\(label) without")
        }
        #expect(!Self.ec.recommendationMismatch(label: "Major revision", majorConcerns: 0))  // not on the scale
        var two = Self.ec
        two.recommendationScale = ["Accept", "Reject"]
        #expect(two.recommendationMismatch(label: "Accept", majorConcerns: 1) && two.recommendationMismatch(label: "Reject", majorConcerns: 0))
        two.recommendationScale = ["Undecided"]
        #expect(!two.recommendationMismatch(label: "Undecided", majorConcerns: 0) && !two.recommendationMismatch(label: "Undecided", majorConcerns: 3))
    }
}
