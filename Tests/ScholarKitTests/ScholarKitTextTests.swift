import Foundation
import Testing
import RefereeCore
@testable import ScholarKit

/// The pure pieces under the acceptance rows: folding (plan.md section 6.7), identifiers (section 8.3), the
/// parsers of the two services' answers (total on any input, section 2.5), the contact address and User-Agent.
@Suite struct ScholarKitTextTests {
    @Test func foldingKeepsLettersAndDigitsInLowerCase() {
        #expect(ReferenceText.fold("Long Short-Term Memory.") == "longshorttermmemory")
        #expect(ReferenceText.fold("Jürgen") == ReferenceText.fold("Ju\u{308}rgen"))
        #expect(ReferenceText.fold("Jürgen") == "jurgen")
        #expect(ReferenceText.fold("ﬁnite “quoted” 9(8):1735–1780") == "finitequoted9817351780")
        #expect(ReferenceText.fold("office-specific") == ReferenceText.fold("office specific"))
        #expect(ReferenceText.fold("") == "")
    }

    @Test func theCacheKeyIsTheHashOfTheFoldedText() {
        let entry = BibEntry(id: 0, rawText: "Hochreiter, S. (1997). Long short-term memory.", parsed: ParsedReference())
        var reflowed = entry
        reflowed.rawText = "Hochreiter,  S. (1997).\nLong short- term memory"
        #expect(LookupCacheStore.key(for: entry) == LookupCacheStore.key(for: reflowed))
        #expect(LookupCacheStore.key(for: entry) == ReferenceText.sha256Hex("hochreiters1997longshorttermmemory"))
        #expect(ReferenceText.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func titleWordsAreSplitAtSpacesPunctuationAndSymbols() {
        #expect(ReferenceText.titleWords("Long Short-Term Memory") == ["long", "short", "term", "memory"])
        #expect(ReferenceText.titleWords("<i>In vivo</i> imaging &amp; Müller's “test”") == ["in", "vivo", "imaging", "muller", "s", "test"])
        #expect(ReferenceText.titleWords("") == [])
        #expect(ReferenceText.titleWords("— … —") == [])
    }

    @Test func markupAndEntitiesAreRemovedFromServiceTitles() {
        #expect(ReferenceText.plainText("Effects of <scp>CO</scp><sub>2</sub> on   growth &amp; yield") == "Effects of CO 2 on growth & yield")
        #expect(ReferenceText.plainText("a < b and c > d") == "a < b and c > d")
        #expect(ReferenceText.nonEmpty("  <i></i> ") == nil)
    }

    @Test(arguments: [
        ("10.1162/neco.1997.9.8.1735", "10.1162/neco.1997.9.8.1735"),
        ("10.3115/v1/D14-1179", "10.3115/v1/d14-1179"),
        ("https://doi.org/10.3115/v1/D14-1179.", "10.3115/v1/d14-1179"),
        ("doi:10.1000/xyz123;", "10.1000/xyz123"),
        ("DOI: 10.1000/xyz123", "10.1000/xyz123"),
        ("10.1016/0004-3702(95)00041-0", "10.1016/0004-3702(95)00041-0"),
        ("10.1000/abc)", "10.1000/abc"),
    ])
    func aDOIIsNormalised(_ raw: String, _ expected: String) {
        #expect(ReferenceText.doi(raw) == expected)
    }

    @Test(arguments: ["", "10.1/abc", "10.12345/", "11.1000/abc", "10.1000/has space", "10.abcd/xyz", "https://example.org/10.1000/x"])
    func somethingThatIsNotADOIIsIgnored(_ raw: String) {
        #expect(ReferenceText.doi(raw) == nil)
    }

    @Test(arguments: [
        ("1810.04805", "1810.04805"), ("arXiv:1810.04805v2", "1810.04805v2"), ("arXiv: 1810.04805.", "1810.04805"),
        ("https://arxiv.org/abs/2101.00001", "2101.00001"), ("arxiv.org/pdf/2101.00001v3.pdf", "2101.00001v3"),
        ("hep-th/9901001", "hep-th/9901001"), ("math.GT/0309136", "math.GT/0309136"), ("arxiv.org/abs/cond-mat/0102536v1", "cond-mat/0102536v1"),
    ])
    func anArxivIDIsNormalised(_ raw: String, _ expected: String) {
        #expect(ReferenceText.arxivID(raw) == expected)
    }

    @Test(arguments: ["", "1810", "1810.048", "1810.048051", "181.04805", "1810.04805vx", "Hep-th/9901001", "hep-th/990100", "x/../y"])
    func somethingThatIsNotAnArxivIDIsIgnored(_ raw: String) {
        #expect(ReferenceText.arxivID(raw) == nil)
    }

    @Test func theRecordedCrossrefAnswerGivesTwoCandidatesInOrder() throws {
        let candidates = try #require(CrossrefCandidate.candidates(from: Data(Bodies.crossrefHochreiter.utf8)))
        #expect(candidates.map(\.doi) == ["10.1162/neco.1997.9.8.1735", "10.1162/neco.1997.9.1.1"])
        let first = try #require(candidates.first)
        #expect(first.title == "Long Short-Term Memory")
        #expect(first.year == 1997)
        #expect(first.venue == "Neural Computation")
        #expect(first.firstAuthor?.surname == "Hochreiter")
        #expect(first.authors.compactMap(\.displayName) == ["Sepp Hochreiter", "Jürgen Schmidhuber"])
    }

    @Test func odditiesInACrossrefItemReadAsAbsent() throws {
        let body = #"""
        {"message":{"items":[{"DOI":"not a doi"},{"DOI":"10.1000/a","title":"Plain string title","author":[{"name":"World Bank","sequence":"first"},
        {"given":"No family"},7],"issued":{"date-parts":[[null]]},"container-title":[]},{"DOI":"10.1000/b","issued":{"date-parts":[["1997"]]},
        "author":"nobody","title":[42]},"junk"]}}
        """#
        let candidates = try #require(CrossrefCandidate.candidates(from: Data(body.utf8)))
        #expect(candidates.map(\.doi) == ["10.1000/a", "10.1000/b"])
        #expect(candidates[0].title == "Plain string title")
        #expect(candidates[0].authors.map(\.surname) == ["World Bank"])
        #expect(candidates[0].year == nil)
        #expect(candidates[0].venue == nil)
        #expect(candidates[1].title == nil)
        #expect(candidates[1].authors.isEmpty)
        #expect(candidates[1].year == nil)
    }

    @Test func theRecordedOpenAlexAnswerGivesTheCardsFields() throws {
        let work = try #require(OpenAlexWork.work(from: Data(Bodies.openAlexHochreiter.utf8)))
        #expect(work == OpenAlexWork(doi: "10.1162/neco.1997.9.8.1735", title: "Long Short-Term Memory", authors: ["Sepp Hochreiter", "Jürgen Schmidhuber"],
                                     year: 1997, venue: "Neural Computation", pdfURL: nil))
    }

    @Test func garbageNeverCrashesAParser() {
        var generator = SplitMix(seed: 7)
        let pieces = ["{", "}", "[", "]", "\"", ":", ",", "null", "true", "1997", "\"items\"", "\"message\"", "\"DOI\"", "\"10.1000/x\"", "\\u00e9", " "]
        for _ in 0..<2_000 {
            let count = Int(generator.next() % 40)
            let text = (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            let data = Data(text.utf8)
            _ = CrossrefCandidate.candidates(from: data)
            _ = OpenAlexWork.work(from: data)
        }
        var bytes = [UInt8](repeating: 0, count: 512)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: generator.next()) }
        #expect(CrossrefCandidate.candidates(from: Data(bytes)) == nil)
        #expect(OpenAlexWork.work(from: Data(bytes)) == nil)
    }

    @Test func theContactAddressMustBeAPlainAddress() {
        // Addresses are put together here from their parts, so that the tree holds no email address (plan.md section 11.1).
        let address = ["referee-test", "example.org"].joined(separator: "@")
        #expect(ServiceRequests.contactAddress(" \(address)\n") == address)
        let unusable: [[String]] = [[""], ["   "], ["no-at-sign"], ["", "example.org"], ["name", ""], ["name", "example"], ["name", ".org"],
                                    ["a", "b", "c.org"], ["name", "exa mple.org"], ["name", "example.org)"], ["na\"me", "example.org"],
                                    ["näme", "example.org"], ["name", "example.org\r\nX-Header: 1"]]
        for parts in unusable {
            let setting = parts.joined(separator: "@")
            #expect(ServiceRequests.contactAddress(setting) == nil, "\(parts)")
        }
        #expect(ServiceRequests.userAgent(contact: nil) == "Referee/0.1.0")
        #expect(ServiceRequests.userAgent(contact: address) == "Referee/0.1.0 (mailto:\(address))")
    }
}

/// A small deterministic generator for the robustness test.
struct SplitMix {
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
