import Foundation
import RefereeCore

/// Finds the files under `Fixtures/` by path (plan.md section 3.6). There is no `Bundle.module`: the package has no
/// resources, and the app is assembled by hand.
public enum Fixtures {
    /// The repository root, in this order: the environment variable REFEREE_REPO_ROOT when it is set; in debug builds,
    /// three folders above this source file; in release builds, the current directory.
    ///
    /// `#filePath` is compiled in debug builds only. This target is linked into the app, and in a release build the
    /// literal would put the build machine's home-directory path into the bundled binary (`scripts/bundle.sh` fails
    /// when it finds one). A release binary needs fixtures only in snapshot mode, which is run from the repository root.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["REFEREE_REPO_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #if DEBUG
        // Sources/TestSupport/Fixtures.swift: the root is three folders up. Keep this line in this file.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #else
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #endif
    }

    /// "pdf/ay_nolinks.pdf" -> <root>/Fixtures/pdf/ay_nolinks.pdf
    public static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent("Fixtures", isDirectory: true).appendingPathComponent(relativePath)
    }

    /// "ay_nolinks" -> the decoded Fixtures/raw/ay_nolinks.raw.json
    public static func rawDocument(_ name: String) throws -> RawDocument {
        let relativePath = "raw/\(name).raw.json"
        let data = try read(relativePath)
        do {
            return try JSONDecoder().decode(RawDocument.self, from: data)
        } catch {
            throw FixtureError(relativePath: relativePath, problem: "is not a RawDocument (\(error))")
        }
    }

    /// "llm/review_clean.txt" -> the file's text (UTF-8)
    public static func text(_ relativePath: String) throws -> String {
        let data = try read(relativePath)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FixtureError(relativePath: relativePath, problem: "is not UTF-8 text")
        }
        return text
    }

    /// The bytes of a file under `Fixtures/`.
    static func read(_ relativePath: String) throws -> Data {
        do {
            return try Data(contentsOf: url(relativePath))
        } catch {
            throw FixtureError(relativePath: relativePath, problem: "could not be read")
        }
    }
}

/// A fixture is missing or damaged. The message names the file relative to `Fixtures/`, never by its full path.
struct FixtureError: Error, CustomStringConvertible {
    let relativePath: String
    let problem: String
    var description: String {
        "Fixtures/\(relativePath) \(problem). Fixtures are found from REFEREE_REPO_ROOT, else from the source tree (debug builds), "
            + "else from the current directory."
    }
}
