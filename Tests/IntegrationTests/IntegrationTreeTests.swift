import Foundation
import Testing
import TestSupport

/// Gate 1 (plan.md section 11.4), row "no secrets in the tree" (section 12.1), and the rule of section 11.1 that no
/// tracked file holds an absolute path under a home directory.
@Suite struct IntegrationTreeTests {
    /// The files `git ls-files` lists, as data.
    static func trackedFiles() async throws -> [(path: String, data: Data)] {
        let git = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/git"), ["ls-files", "-z"], directory: Fixtures.root,
                                           environment: ProcessInfo.processInfo.environment, timeout: 30)
        try #require(git.status == 0, "git ls-files failed")
        let paths = git.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        try #require(paths.count > 100, "git ls-files listed only \(paths.count) files")
        return try paths.compactMap { path in
            let url = Fixtures.root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }      // deleted in the working tree
            return (path, try Data(contentsOf: url))
        }
    }

    /// The three patterns of section 12.1: anchored at a word boundary; the OpenAI one needs a digit and a capital, so
    /// that a long hyphenated word does not match.
    static let keyPatterns = [
        #"\bsk-(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Z])[A-Za-z0-9_-]{32,}"#,
        #"\bxai-[A-Za-z0-9]{32,}\b"#,
        #"\bAIza[0-9A-Za-z_-]{35}\b"#,
    ]

    @Test func noTrackedFileHoldsAStringShapedLikeAKey() async throws {
        let expressions = try Self.keyPatterns.map { try NSRegularExpression(pattern: $0) }
        // The patterns themselves are found in made-up keys of the right shape, and not in hyphenated words.
        let fake = "sk-" + "Ab1" + String(repeating: "x", count: 32)
        #expect(expressions[0].firstMatch(in: fake, range: NSRange(location: 0, length: (fake as NSString).length)) != nil)
        let word = "sk-task-specific-identification-threshold-of-the-model"
        #expect(expressions[0].firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) == nil)

        for (path, data) in try await Self.trackedFiles() {
            let text = String(decoding: data, as: UTF8.self)
            let range = NSRange(location: 0, length: (text as NSString).length)
            for (pattern, expression) in zip(Self.keyPatterns, expressions) {
                #expect(expression.firstMatch(in: text, range: range) == nil, "\(path) matches \(pattern)")
            }
        }
    }

    @Test func noTrackedFileHoldsAPathUnderAHomeDirectory() async throws {
        // Put together at run time, so that this file does not match itself.
        let home = try NSRegularExpression(pattern: "/" + "Users" + #"/[A-Za-z][A-Za-z0-9._-]*"#)
        for (path, data) in try await Self.trackedFiles() where !path.hasSuffix(".pdf") {
            let text = String(decoding: data, as: UTF8.self)
            let match = home.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            #expect(match == nil, "\(path) holds a path under a home directory")
        }
    }
}
