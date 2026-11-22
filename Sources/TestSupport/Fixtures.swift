import Foundation
import RefereeCore

// Wave 0a placeholder (see Placeholder.swift): the two path functions work; the two readers do not exist yet.

public enum Fixtures {
    /// The file that anchors `root`. Keep `#filePath` in this file: the root is three folders above it.
    private static let thisFile = URL(fileURLWithPath: #filePath)

    public static var root: URL {                                           // repository root, from #filePath of this file; no Bundle.module
        thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    public static func url(_ relativePath: String) -> URL {                 // "pdf/ay_nolinks.pdf" -> <root>/Fixtures/pdf/ay_nolinks.pdf
        root.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
    }
    public static func rawDocument(_ name: String) throws -> RawDocument {  // "ay_nolinks" -> Fixtures/raw/ay_nolinks.raw.json
        throw NotImplementedYet(what: "Fixtures.rawDocument")
    }
    public static func text(_ relativePath: String) throws -> String {      // "llm/review_clean.txt"
        throw NotImplementedYet(what: "Fixtures.text")
    }
}
