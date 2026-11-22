import Foundation
import Testing
import RefereeCore
@testable import CitationKit

/// The parser table (plan.md §8.1 and §8.3): reference entries as printed, line by line, through the entry-text
/// assembly and the parser.
@Suite struct CitationParserTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var style: CitationStyle
        var lines: [String]
        var surname: String?
        var year: Int?
        var doi: String?
        var surnames: [String]? = nil
        var suffix: String? = nil
        var arxiv: String? = nil
        var title: String? = nil
        var truncated = false

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "economics, initials after the surnames", style: .authorYear,
             lines: ["Acemoglu, D., Dahleh, M. A., Lobel, I., and Ozdaglar, A. (2011). Bayesian learning in social networks. Review of Economic Studies, 78(4):1201–1236."],
             surname: "Acemoglu", year: 2011, doi: nil, surnames: ["Acemoglu", "Dahleh", "Lobel", "Ozdaglar"], title: "Bayesian learning in social networks"),
        Case(name: "economics, AER style with given names", style: .authorYear,
             lines: ["Avery, Christopher, and Peter Zemsky. 1998. “Multidimensional Uncertainty and Herd Behavior in Financial Markets.” American Economic Review 88 (4): 724–48."],
             surname: "Avery", year: 1998, doi: nil, surnames: ["Avery", "Zemsky"], title: "Multidimensional Uncertainty and Herd Behavior in Financial Markets"),
        Case(name: "economics, Chicago author-date", style: .authorYear,
             lines: ["Banerjee, Abhijit V. 1992. “A Simple Model of Herd Behavior.” Quarterly Journal of Economics 107 (3): 797–817."],
             surname: "Banerjee", year: 1992, doi: nil, surnames: ["Banerjee"], title: "A Simple Model of Herd Behavior"),
        Case(name: "economics, a generational suffix", style: .authorYear,
             lines: ["Lucas, Robert E., Jr. 1972. “Expectations and the Neutrality of Money.” Journal of Economic Theory 4 (2): 103–24."],
             surname: "Lucas", year: 1972, doi: nil, surnames: ["Lucas"]),
        Case(name: "APA, ampersand and a DOI URL at the end", style: .authorYear,
             lines: ["Smith, J. A., & Jones, B. (2019). Learning from noisy signals. Journal of Economic Theory, 181, 45–67.",
                     "https://doi.org/10.1016/j.jet.2019.01.004"],
             surname: "Smith", year: 2019, doi: "10.1016/j.jet.2019.01.004", surnames: ["Smith", "Jones"], title: "Learning from noisy signals"),
        Case(name: "APA, et al.", style: .authorYear,
             lines: ["Bikhchandani, S., et al. (1992). A theory of fads, fashion, custom, and cultural change as informational cascades.",
                     "Journal of Political Economy, 100(5), 992–1026."],
             surname: "Bikhchandani", year: 1992, doi: nil, surnames: ["Bikhchandani"], truncated: true),
        Case(name: "particles before the surname", style: .authorYear,
             lines: ["van der Berg, J. and Smith, K. (2001). Coalitions in sequential voting. Games and Economic Behavior, 35(1):1–20."],
             surname: "van der Berg", year: 2001, doi: nil, surnames: ["van der Berg", "Smith"]),
        Case(name: "Springer style with spaces", style: .authorYear,
             lines: ["Dekel E, Piccione M (2000) Sequential voting procedures in symmetric binary elections. J Polit Econ 108(1):34–55"],
             surname: "Dekel", year: 2000, doi: nil, surnames: ["Dekel", "Piccione"], title: "Sequential voting procedures in symmetric binary elections"),
        Case(name: "Springer style without spaces", style: .authorYear,
             lines: ["DekelE,PiccioneM(2000)Sequentialvotingproceduresinsymmetricbinary", "elections.", "J Polit Econ 108(1):34–55"],
             surname: "Dekel", year: 2000, doi: nil, surnames: ["Dekel", "Piccione"]),
        Case(name: "a year with a letter suffix", style: .authorYear,
             lines: ["Smith, L. (2000a). Pathological outcomes of observational learning. Econometrica, 68(2):371–398."],
             surname: "Smith", year: 2000, doi: nil, suffix: "a"),
        Case(name: "a DOI at the end with a doi: prefix and a final period", style: .authorYear,
             lines: ["Kogan, D. (2020). Learning from reviews with strategic sellers. Management Science, 66(3):1–20. doi:10.1287/mnsc.2019.3456."],
             surname: "Kogan", year: 2020, doi: "10.1287/mnsc.2019.3456"),
        Case(name: "no year yet", style: .authorYear,
             lines: ["Kogan, D. (forthcoming). Learning from ratings. Review of Economic Studies."],
             surname: "Kogan", year: nil, doi: nil, surnames: ["Kogan"]),
        Case(name: "numeric, given names first", style: .numeric,
             lines: ["[1] Dzmitry Bahdanau, Kyunghyun Cho, and Yoshua Bengio. Neural ma-", "chine translation by jointly learning to align and translate. In ICLR,", "2015."],
             surname: "Bahdanau", year: 2015, doi: nil, surnames: ["Bahdanau", "Cho", "Bengio"],
             title: "Neural machine translation by jointly learning to align and translate"),
        Case(name: "numeric, initials before the surnames", style: .numeric,
             lines: ["[7] J. Smith and K. Lee. Learning in networks. Journal of Economic Theory, 10:1–20, 2005."],
             surname: "Smith", year: 2005, doi: nil, surnames: ["Smith", "Lee"], title: "Learning in networks"),
        Case(name: "numeric, et al.", style: .numeric,
             lines: ["[4] A. Vaswani et al. Attention is all you need. In NeurIPS, 2017."],
             surname: "Vaswani", year: 2017, doi: nil, surnames: ["Vaswani"], title: "Attention is all you need", truncated: true),
        Case(name: "numeric, a particle", style: .numeric,
             lines: ["12. Ludwig von Mises. Human Action: A Treatise on Economics. Yale University Press, 1949."],
             surname: "von Mises", year: 1949, doi: nil, title: "Human Action: A Treatise on Economics"),
        Case(name: "numeric, a label on a line of its own", style: .numeric,
             lines: ["[25]", "Sepp Hochreiter and Jürgen Schmidhuber. Long short-term memory. Neural Computation, 9(8):1735–1780, 1997."],
             surname: "Hochreiter", year: 1997, doi: nil, surnames: ["Hochreiter", "Schmidhuber"], title: "Long short-term memory"),
        Case(name: "numeric, a DOI at the end broken at a slash", style: .numeric,
             lines: ["[2] Kyunghyun Cho, Bart van Merrienboer, Caglar Gulcehre, Dzmitry Bah-", "danau, Fethi Bougares, Holger Schwenk, and Yoshua Bengio. Learn-",
                     "ing phrase representations using RNN encoder-decoder for statistical", "machine translation. In EMNLP, 2014. https://doi.org/10.3115/v1/",
                     "D14-1179"],
             surname: "Cho", year: 2014, doi: "10.3115/v1/d14-1179",
             surnames: ["Cho", "van Merrienboer", "Gulcehre", "Bahdanau", "Bougares", "Schwenk", "Bengio"]),
        Case(name: "numeric, an arXiv id that looks like a year", style: .numeric,
             lines: ["[3] Jacob Devlin, Ming-Wei Chang, Kenton Lee, and Kristina Toutanova. BERT: Pre-training of deep bidirectional",
                     "transformers for language understanding. In NAACL, 2019. arXiv:1810.04805."],
             surname: "Devlin", year: 2019, doi: nil, arxiv: "1810.04805",
             title: "BERT: Pre-training of deep bidirectional transformers for language understanding"),
        Case(name: "numeric, only an arXiv id", style: .numeric,
             lines: ["[8] A. Author. A preprint about herding. arXiv:1905.01234v2."],
             surname: "Author", year: nil, doi: nil, arxiv: "1905.01234"),
        Case(name: "numeric, an arXiv URL", style: .numeric,
             lines: ["[9] B. Writer. Another preprint. 2020. https://arxiv.org/abs/2001.04451v3."],
             surname: "Writer", year: 2020, doi: nil, arxiv: "2001.04451"),
        Case(name: "numeric, a page range that looks like years", style: .numeric,
             lines: ["[6] C. Writer. A long survey. In Proceedings of the Conference 2011, pages 1998–2004."],
             surname: "Writer", year: 2011, doi: nil),
        Case(name: "numeric, a volume that looks like a year", style: .numeric,
             lines: ["[5] C. Romer. What ended the great depression? 2005. Brookings Papers on Economic Activity 2004(2):1–60."],
             surname: "Romer", year: 2005, doi: nil, title: "What ended the great depression?"),
        Case(name: "numeric, IEEE with a quoted title", style: .numeric,
             lines: ["[10] J. Smith and K. Lee, “A study of herding,” in Proc. EC, 2001, pp. 1–10."],
             surname: "Smith", year: 2001, doi: nil, surnames: ["Smith", "Lee"], title: "A study of herding"),
    ]

    @Test(arguments: cases)
    func parse(_ c: Case) {
        let text = EntryText.join(c.lines)
        let parsed = EntryParser.parse(text, style: c.style)
        let reference = parsed.reference
        #expect(reference.authorSurnames.first == c.surname)
        #expect(reference.year == c.year)
        #expect(reference.doi == c.doi)
        if let surnames = c.surnames { #expect(reference.authorSurnames == surnames) }
        #expect(reference.yearSuffix == c.suffix)
        if let arxiv = c.arxiv { #expect(reference.arxivID == arxiv) }
        if let title = c.title { #expect(reference.title == title) }
        #expect(parsed.authorsTruncated == c.truncated)
    }

    @Test func theTableIsLargeEnough() {
        #expect(Self.cases.count >= 15)
        #expect(Set(Self.cases.map(\.name)).count == Self.cases.count)
    }

    // MARK: entry text (§8.1)

    @Test func entryTextJoinsLines() {
        #expect(EntryText.join(["Bikhchan-", "dani, S. (1992)."]) == "Bikhchandani, S. (1992).")
        #expect(EntryText.join(["Bikhchan-", "Dani"]) == "Bikhchan- Dani")                        // the next line starts upper-case
        #expect(EntryText.join(["pages 12-", "34."]) == "pages 12- 34.")                           // no letter before the hyphen
        #expect(EntryText.join(["https://doi.org/10.3115/v1/", "D14-1179"]) == "https://doi.org/10.3115/v1/D14-1179")
        #expect(EntryText.join(["doi:10.1000/abc-", "def"]) == "doi:10.1000/abc-def")               // a hyphen inside a DOI is kept
        #expect(EntryText.join(["see https://example.org/a_", "b=c&", "d"]) == "see https://example.org/a_b=c&d")
        #expect(EntryText.join(["Title.", "  ", " Journal. "]) == "Title. Journal.")
    }

    @Test func linkAnnotationsGiveTheDOIAndTheURL() {
        let parsed = EntryParser.parse("[2] K. Cho. Learning phrase representations. In EMNLP, 2014.", style: .numeric,
                                       linkURLs: ["https://doi.org/10.3115/V1/D14-1179"])
        #expect(parsed.reference.doi == "10.3115/v1/d14-1179")
        #expect(parsed.reference.url == "https://doi.org/10.3115/V1/D14-1179")
        #expect(EntryParser.doi(fromURL: "https://dx.doi.org/10.1000%2Fxyz") == "10.1000/xyz")
        #expect(EntryParser.doi(fromURL: "https://example.org/paper") == nil)
        #expect(EntryParser.firstURL(in: "(see https://example.org/x).") == "https://example.org/x")
    }
}
