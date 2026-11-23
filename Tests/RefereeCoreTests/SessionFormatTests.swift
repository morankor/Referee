import Foundation
import Testing
import RefereeCore

/// The file format of a review (plan.md section 4.3). The sample is the block printed there, copied by a script and
/// not retyped, so these tests fail when the types of Appendix A and the printed format drift apart.
@Suite struct SessionFormatTests {
    static let sample = #"""
        {
          "comments" : [
            {
              "anchor" : {
                "confidence" : { "exact" : { } },
                "locationLabel" : "p. 1, lines 13–14",
                "pageIndex" : 0,
                "quote" : "The coefficient in Table 2 is 0.91 with a confidence interval that crosses one",
                "rects" : [
                  { "height" : 10.6, "pageIndex" : 0, "width" : 88.6, "x" : 410.2, "y" : 189.2 },
                  { "height" : 10.6, "pageIndex" : 0, "width" : 286.2, "x" : 110.9, "y" : 165.2 }
                ],
                "spans" : [ { "pageIndex" : 0, "range" : { "length" : 18, "location" : 676 } },
                            { "pageIndex" : 0, "range" : { "length" : 59, "location" : 697 } } ]
              },
              "body" : "The text calls the effect robust, but Table 2 reports 0.91 with an interval that crosses one.",
              "category" : "claims",
              "createdAt" : "2026-11-18T11:06:40Z",
              "id" : "22222222-2222-4222-8222-222222222222",
              "includeInReport" : true,
              "kind" : "major",
              "origin" : { "ai" : { "runID" : "11111111-1111-4111-8111-111111111111" } },
              "previousVersions" : [ ],
              "proposedRevision" : { "body" : "…", "kind" : "minor", "title" : "State the interval", "withdraw" : false },
              "status" : "approved",
              "suggestion" : "Report the interval in the abstract and drop 'robust'.",
              "thread" : [
                { "createdAt" : "2026-11-18T11:06:40Z", "id" : "33333333-3333-4333-8333-333333333333", "role" : "user",
                  "text" : "Is the interval in the text or only in the table?" }
              ],
              "title" : "Confidence interval includes one",
              "updatedAt" : "2026-11-18T11:06:40Z"
            }
          ],
          "consents" : [ { "grantedAt" : "2026-11-18T11:06:40Z", "providerID" : "anthropic-api" } ],
          "conversations" : [ ],
          "createdAt" : "2026-11-18T11:06:40Z",
          "document" : { "byteCount" : 183964, "fileName" : "manuscript.pdf", "lastKnownPath" : "/path/to/manuscript.pdf", "pageCount" : 4, "sha256" : "9f2c…" },
          "id" : "55555555-5555-4555-8555-555555555555",
          "meta" : { "reviewerNotes" : "", "title" : "Information Aggregation in Sequential Markets" },
          "runs" : [
            { "destination" : "127.0.0.1:11434", "finishedAt" : "2026-11-18T11:06:40Z", "id" : "11111111-1111-4111-8111-111111111111",
              "kind" : "review", "provider" : { "model" : "gemma4:e4b", "providerID" : "ollama" }, "requestCount" : 1, "sentPDF" : false,
              "startedAt" : "2026-11-18T11:06:40Z", "status" : { "completed" : { } }, "usage" : { "inputTokens" : 21000, "outputTokens" : 1800 } }
          ],
          "schemaVersion" : 1,
          "updatedAt" : "2026-11-18T11:06:40Z"
        }
        """#

    /// The coders of the stores: ISO 8601 dates, pretty-printed, sorted keys, slashes not escaped (section 3.7).
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    private static func decodeSample() throws -> ReviewSession {
        try makeDecoder().decode(ReviewSession.self, from: Data(sample.utf8))
    }

    @Test func theSampleDecodesIntoTheTypesOfAppendixA() throws {
        let session = try Self.decodeSample()
        let moment = try #require(ISO8601DateFormatter().date(from: "2026-11-18T11:06:40Z"))
        #expect(session.schemaVersion == 1)
        #expect(session.id == UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        #expect(session.document == DocumentRef(sha256: "9f2c…", fileName: "manuscript.pdf", lastKnownPath: "/path/to/manuscript.pdf",
                                                byteCount: 183_964, pageCount: 4))
        #expect(session.meta == ManuscriptMeta(title: "Information Aggregation in Sequential Markets", reviewerNotes: ""))
        #expect(session.preferredProvider == nil)
        #expect(session.conversations.isEmpty)
        #expect(session.report == nil)
        #expect(session.paperDigest == nil)
        #expect(session.consents == [ConsentRecord(providerID: "anthropic-api", grantedAt: moment)])
        #expect(session.createdAt == moment)

        let run = try #require(session.runs.first)
        #expect(session.runs.count == 1)
        #expect(run.kind == .review)
        #expect(run.provider == ProviderRef(providerID: "ollama", model: "gemma4:e4b"))
        #expect(run.destination == "127.0.0.1:11434")
        #expect(!run.sentPDF)
        #expect(run.status == .completed)
        #expect(run.usage == Usage(inputTokens: 21_000, outputTokens: 1_800))

        let comment = try #require(session.comments.first)
        #expect(session.comments.count == 1)
        #expect(comment.origin == .ai(runID: run.id))
        #expect(comment.status == .approved)
        #expect(comment.kind == .major)
        #expect(comment.category == "claims")
        #expect(comment.includeInReport)
        #expect(comment.similarTo == nil)
        #expect(comment.previousVersions.isEmpty)
        #expect(comment.proposedRevision == CommentRevision(kind: .minor, title: "State the interval", body: "…", withdraw: false))
        #expect(comment.thread.map(\.role) == [.user])
        #expect(comment.thread.first?.provider == nil)
        #expect(comment.anchor.confidence == .exact)
        #expect(comment.anchor.pageIndex == 0)
        #expect(comment.anchor.locationLabel == "p. 1, lines 13\u{2013}14")      // an en dash
        #expect(comment.anchor.spans == [TextSpan(pageIndex: 0, range: TextRange(location: 676, length: 18)),
                                         TextSpan(pageIndex: 0, range: TextRange(location: 697, length: 59))])
        #expect(comment.anchor.rects.count == 2)
        #expect(comment.anchor.rects.first == PageRect(pageIndex: 0, x: 410.2, y: 189.2, width: 88.6, height: 10.6))
    }

    @Test func theSampleSurvivesARoundTripThroughTheStoreFormat() throws {
        let session = try Self.decodeSample()
        let written = try Self.makeEncoder().encode(session)
        #expect(try Self.makeDecoder().decode(ReviewSession.self, from: written) == session)

        // The same JSON value as the printed sample: no key is added, lost or renamed, and nil optionals are left out.
        let printed = try JSONSerialization.jsonObject(with: Data(Self.sample.utf8)) as? NSDictionary
        let rewritten = try JSONSerialization.jsonObject(with: written) as? NSDictionary
        #expect(printed != nil)
        #expect(printed == rewritten)

        // And in the shape the plan describes: sorted keys, two-space indentation, ISO 8601 dates, plain slashes.
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"comments\" : ["))
        #expect(text.contains("\"createdAt\" : \"2026-11-18T11:06:40Z\""))
        #expect(text.contains("\"lastKnownPath\" : \"/path/to/manuscript.pdf\""))
    }

    @Test func enumsWithValuesUseTheSynthesisedEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        #expect(try json(AnchorConfidence.exact) == #"{"exact":{}}"#)
        #expect(try json(AnchorConfidence.fuzzy(score: 0.5)) == #"{"fuzzy":{"score":0.5}}"#)
        #expect(try json(AnchorConfidence.pageOnly) == #"{"pageOnly":{}}"#)
        #expect(try json(AnchorConfidence.none) == #"{"none":{}}"#)
        #expect(try json(RunStatus.failed("message")) == #"{"failed":{"_0":"message"}}"#)
        #expect(try json(CommentOrigin.user) == #"{"user":{}}"#)
        let run = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(try json(CommentOrigin.ai(runID: run)) == #"{"ai":{"runID":"11111111-1111-4111-8111-111111111111"}}"#)
        #expect(try json(RawLinkTarget.url("https://example.org/a")) == #"{"url":{"_0":"https:\/\/example.org\/a"}}"#)
        #expect(try json(RawLinkTarget.internalDestination(pageIndex: 2, x: 1, y: 2)) == #"{"internalDestination":{"pageIndex":2,"x":1,"y":2}}"#)
    }

    /// Section 4.4: a field may be added without a version bump only if it is optional, because a file written before
    /// the field existed then still decodes.
    @Test func aFileWrittenBeforeAnOptionalFieldExistedStillDecodes() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(Self.sample.utf8)) as? [String: Any])
        var comments = try #require(object["comments"] as? [[String: Any]])
        #expect(comments[0]["similarTo"] == nil)            // an optional that is nil is not written at all
        comments[0]["suggestion"] = nil
        comments[0]["proposedRevision"] = nil
        object["comments"] = comments
        let session = try Self.makeDecoder().decode(ReviewSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(session.comments.first?.suggestion == nil)
        #expect(session.comments.first?.proposedRevision == nil)
    }
}
