import Foundation
import TestSupport

/// The four model outputs WP6 writes for its parser and engine tests (plan.md Appendix D.9): `review_sloppy.txt`,
/// `review_json.txt`, `review_prose.txt` and `review_dupes.txt`.
///
/// They live in `Tests/ReviewEngineTests/Fixtures/`, which the manifest excludes from the target (`exclude: ["Fixtures"]`,
/// plan.md section 3.7): a data file in a test target's folder that the manifest neither declares nor excludes makes
/// SwiftPM warn "found N file(s) which are unhandled". The folder holds data only, never a Swift file.
enum EngineFixtures {
    static var folder: URL {
        Fixtures.root.appendingPathComponent("Tests/ReviewEngineTests/Fixtures", isDirectory: true)
    }

    /// "review_sloppy.txt" -> the file's text.
    static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
}
