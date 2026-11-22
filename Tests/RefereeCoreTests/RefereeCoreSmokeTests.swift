import Foundation
import Testing
import RefereeCore

/// Wave 0a smoke tests: the two things this step wrote in RefereeCore beyond Appendix A.
@Suite struct RefereeCoreSmokeTests {
    @Test func defaultSettingsFollowThePlan() {
        let settings = DefaultSettings.make()
        #expect(settings.schemaVersion == 1)

        // Every provider id of plan section 5.2 is present; only the local one is switched on.
        let ids = ["anthropic-api", "openai-api", "gemini-api", "xai-api", "ollama", "claude-cli", "codex-cli", "antigravity-cli", "grok-cli", "mock"]
        #expect(Set(settings.providers.keys) == Set(ids))
        #expect(settings.providers.filter { $0.value.enabled }.map(\.key) == ["ollama"])
        #expect(settings.providers["ollama"]?.extraBodyJSON == #"{"think": false}"#)
        #expect(settings.providers.values.allSatisfy { $0.inputMode == .auto && $0.model == nil && $0.verifiedAt == nil })
        #expect(settings.defaults == TaskDefaults())

        #expect(settings.privacy == PrivacySettings(localOnly: false, confirmFirstSendPerDocument: true, resolveReferencesInBackground: false))
        #expect(settings.references == ReferenceSettings(crossrefMailto: "", pdfCacheLimitMB: 500))
        #expect(settings.ui == UISettings(autoAdvanceAfterTriage: true, showRejectedHighlights: false, sidebarWidth: 380, stripMarginLineNumbers: true))

        #expect(settings.rubric.map(\.id) == ["claims", "assumptions", "generality", "positioning", "literature", "math", "data", "writing", "other"])
        #expect(settings.rubric.allSatisfy { $0.enabled && !$0.name.isEmpty && !$0.guidance.isEmpty })
        #expect(settings.prompts.quickQuestions.count == 5)
    }

    @Test func defaultPromptsAreTheTextsOfAppendixB() {
        let prompts = DefaultSettings.make().prompts
        #expect(prompts.reviewSystem.hasPrefix("You are refereeing a manuscript for a serious academic journal."))
        #expect(prompts.reviewSystem.hasSuffix("say so in the relevant comment and concentrate on logic and method."))
        #expect(prompts.discussionSystem.hasPrefix("You are assisting a referee who is reviewing a manuscript."))
        #expect(prompts.questionSystem.hasPrefix("You are assisting a referee who is reading a manuscript under review."))
        #expect(prompts.reportSystem.hasPrefix("You are drafting a referee report from a referee's approved notes."))
        #expect(prompts.reportSystem.hasSuffix("Output the report in Markdown and nothing else."))
        #expect(prompts.voiceRevisionSystem.hasPrefix("You are editing a referee report"))
        #expect(prompts.reportTemplate.components(separatedBy: "\n").filter { !$0.isEmpty } == [
            "## Summary assessment", "## Recommendation", "## Publication probability",
            "## Major concerns", "## Minor concerns", "## Questions for the authors",
        ])
        let texts = [prompts.reviewSystem, prompts.discussionSystem, prompts.questionSystem, prompts.reportSystem, prompts.reportTemplate,
                     prompts.voiceRevisionSystem]
        #expect(texts.allSatisfy { !$0.hasSuffix("\n") && !$0.hasPrefix("\n") })
    }

    @Test func formatSpecCarriesTheMarkersAndPlaceholdersOfAppendixB2() {
        #expect(FormatSpec.review.hasPrefix("OUTPUT FORMAT."))
        for marker in ["\n@@COMMENT\n", "\n@@END\n", "@@DONE"] { #expect(FormatSpec.review.contains(marker)) }
        #expect(!FormatSpec.review.contains("{"))
        #expect(FormatSpec.revision.contains("\n@@REVISED\n"))
        #expect(FormatSpec.revision.contains("@@WITHDRAW"))
        #expect(!FormatSpec.revision.contains("{"))

        // The optional lines close both review tasks; the paper's place is marked in text mode only.
        let optionalLines = "\n{Reviewer's notes: …}\n{Target journal: …}\n{Comments already made, do not repeat them: title; title; …}"
        #expect(FormatSpec.taskReviewText.hasSuffix(optionalLines))
        #expect(FormatSpec.taskReviewPDF.hasSuffix(optionalLines))
        #expect(FormatSpec.taskReviewText.contains("\n{paper text}\nWrite your referee comments on this manuscript in the required format.\n"))
        #expect(FormatSpec.taskReviewText.contains("Extraction leaves artefacts"))
        #expect(FormatSpec.taskReviewPDF.hasPrefix("The manuscript is the attached PDF."))
        #expect(!FormatSpec.taskReviewPDF.contains("{paper text}"))

        for piece in ["part {i} of {n}: PDF pages {a} to {b}.", "\n{if i > 1:}\nYour notes on the earlier parts:\n{notes}\n\n{text of the part}\n", "@@NOTES", "@@DONE"] {
            #expect(FormatSpec.taskPart.contains(piece))
        }
        #expect(FormatSpec.taskWhole.contains("\n{notes}\n"))
        #expect(FormatSpec.taskWhole.contains("Comments you already made: {titles}\n"))
        #expect(FormatSpec.taskContinue.contains("(do not repeat them): {titles}\n"))

        let all = [FormatSpec.review, FormatSpec.revision, FormatSpec.taskReviewText, FormatSpec.taskReviewPDF, FormatSpec.taskPart,
                   FormatSpec.taskWhole, FormatSpec.taskContinue]
        #expect(all.allSatisfy { !$0.hasSuffix("\n") && !$0.hasPrefix("\n") && !$0.contains("←") })
    }

    @Test func defaultSettingsSurviveTheJSONFormatOfTheStores() throws {
        let settings = DefaultSettings.make()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(AppSettings.self, from: encoder.encode(settings)) == settings)
    }
}
