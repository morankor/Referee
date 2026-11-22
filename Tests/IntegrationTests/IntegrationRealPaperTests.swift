import Foundation
import Testing
import RefereeCore
import TestSupport

/// Gate 1 (plan.md section 11.4), row "real papers": every PDF in Fixtures/private (the public arXiv papers of
/// scripts/fetch-optional-fixtures.sh) and in Fixtures/private/journal (journal-system PDFs the user adds) goes
/// through the pipeline within 10 s, and where its links point into the reference list, the entries found from the
/// text are the entries the links name, in the same order. Skipped when the folder holds no PDF. Files are named by
/// their position only, so that no file name reaches the test output.
@Suite struct IntegrationRealPaperTests {
    static let folders = ["private", "private/journal"]

    static var papers: [URL] {
        folders.flatMap { folder -> [URL] in
            let directory = Fixtures.url(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.lowercased().hasSuffix(".pdf") && !$0.hasPrefix(".") }.sorted().map { directory.appendingPathComponent($0) }
        }
    }

    @Test(.enabled(if: !papers.isEmpty, "Fixtures/private holds no PDF; scripts/fetch-optional-fixtures.sh fetches three public ones"))
    func realPapersGoThroughThePipeline() async throws {
        let graph = await LiveGraph.make(mock: false)
        defer { graph.remove() }
        let dependencies = graph.dependencies
        for (position, url) in Self.papers.enumerated() {
            let name = "paper \(position + 1) of \(Self.papers.count)"
            let start = ContinuousClock.now
            let paper = try await dependencies.paperService.load(url: url)
            let matcher = dependencies.matcherFactory(paper.text)
            let index = dependencies.citationIndexer.buildIndex(paper: paper.text, links: paper.links)
            let textOnly = dependencies.citationIndexer.buildIndex(paper: paper.text, links: [])
            _ = matcher.locate(quote: "a sentence that no paper contains, written for this test alone", pageHint: nil)
            let elapsed = ContinuousClock.now - start
            await dependencies.paperService.unload(paper.ref)
            #expect(elapsed < .seconds(10), "\(name): the pipeline took \(elapsed)")
            #expect(paper.text.hasTextLayer, "\(name) has no text layer")

            let fromLinks = index.mentions.filter { $0.source == .linkAnnotation }
            print("\(name): \(paper.ref.pageCount) pages, style \(index.style.rawValue), \(index.entries.count) entries, "
                  + "\(textOnly.mentions.count) text mentions, \(fromLinks.count) link mentions, margin numbers \(paper.text.hasMarginLineNumbers), "
                  + "\(elapsed)")
            guard !fromLinks.isEmpty else { continue }                  // no links into the reference list
            let linked = fromLinks.flatMap(\.entryIDs)
            let found = textOnly.mentions.flatMap(\.entryIDs)
            #expect(found == linked, "\(name): the entries found from the text differ from those the links name")
            if found != linked {
                let firstDifference = Array(zip(found, linked)).firstIndex { $0.0 != $0.1 } ?? min(found.count, linked.count)
                print("\(name): first difference at position \(firstDifference) of \(found.count) text and \(linked.count) link targets")
            }
        }
    }
}
