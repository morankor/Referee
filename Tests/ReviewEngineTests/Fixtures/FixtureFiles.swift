import Foundation
import TestSupport

/// The four model outputs WP6 writes for its parser and engine tests (plan.md Appendix D.9): `review_sloppy.txt`,
/// `review_json.txt`, `review_prose.txt` and `review_dupes.txt`.
///
/// They live in the hidden folder `Fixtures/.llm/` next to this file. A file in a test target's folder that is neither
/// Swift nor declared in the manifest makes SwiftPM warn "found N file(s) which are unhandled" whenever the tests are
/// built, and the frozen manifest has no `exclude:` (and no `resources:`, by rule). SwiftPM skips hidden folders, so
/// the files can stay plain text. Once the manifest excludes `Tests/ReviewEngineTests/Fixtures`, they can move up one
/// level and `folder` below loses its last component.
enum EngineFixtures {
    static var folder: URL {
        Fixtures.root.appendingPathComponent("Tests/ReviewEngineTests/Fixtures/.llm", isDirectory: true)
    }

    /// "review_sloppy.txt" -> the file's text.
    static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
}
