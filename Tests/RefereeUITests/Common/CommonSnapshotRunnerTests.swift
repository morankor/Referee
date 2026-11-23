import AppKit
import CryptoKit
import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import RefereeUI

/// The pure parts of the snapshot runner (plan.md section 10.1): arguments, the manifest line, the blankness rule and
/// the fixture-session copy. The mechanism as a whole is exercised by `scripts/snapshots.sh --scene placeholder`.
@Suite struct CommonSnapshotRunnerTests {
    // ---- arguments ----

    @Test func theArgumentsOfSection101AreUnderstood() throws {
        let plain = try SnapshotOptions(arguments: ["--ui-snapshot", "build/snapshots"])
        #expect(plain.outPath == "build/snapshots")
        #expect(plain.outDirectory.lastPathComponent == "snapshots")
        #expect(plain.sceneNames.isEmpty)
        #expect(!plain.dark)
        #expect(plain.size == nil)

        let full = try SnapshotOptions(arguments: ["--ui-snapshot", "/tmp/out/", "--scene", "welcome", "--dark", "--scene", "reader-find", "--size", "1000x640"])
        #expect(full.sceneNames == ["welcome", "reader-find"])
        #expect(full.dark)
        #expect(full.size == NSSize(width: 1000, height: 640))
        #expect(full.pngPath(for: "welcome") == "/tmp/out/welcome.png")
        #expect(plain.pngPath(for: "reader-find") == "build/snapshots/reader-find.png")

        // The order of the options does not matter, and the program name may come first, as in CommandLine.arguments.
        #expect(try SnapshotOptions(arguments: ["--dark", "--scene", "a", "--ui-snapshot", "out"]).sceneNames == ["a"])
        #expect(try SnapshotOptions(arguments: ["/Applications/Referee.app/Contents/MacOS/Referee", "--ui-snapshot", "out", "--dark"]) == (try SnapshotOptions(arguments: ["--ui-snapshot", "out", "--dark"])))
    }

    @Test(arguments: [
        [], ["--ui-snapshot"], ["--scene", "welcome"], ["--ui-snapshot", ""], ["--ui-snapshot", "out", "--scene"],
        ["--ui-snapshot", "out", "--size"], ["--ui-snapshot", "out", "--size", "1280"], ["--ui-snapshot", "out", "--size", "1280x"],
        ["--ui-snapshot", "out", "--size", "axb"], ["--ui-snapshot", "out", "--size", "1280x800x2"], ["--ui-snapshot", "out", "--size", "10x10"],
        ["--ui-snapshot", "out", "--light"], ["--ui-snapshot", "out", "extra"], ["Referee"], ["Referee", "paper.pdf", "--ui-snapshot", "out"],
    ])
    func wrongArgumentsAreRefused(arguments: [String]) {
        #expect(throws: SnapshotOptions.Problem.self) { try SnapshotOptions(arguments: arguments) }
    }

    // ---- manifest ----

    @Test func theManifestLineIsTheOnePrintedInThePlan() throws {
        let line = SnapshotManifest.line(scene: "review-pending", file: "build/snapshots/review-pending.png", width: 2560, height: 1600,
                                         nonBlank: true, failures: [])
        #expect(line == #"{"scene":"review-pending","file":"build/snapshots/review-pending.png","width":2560,"height":1600,"nonBlank":true,"failures":[]}"#)

        let failed = SnapshotManifest.line(scene: "check", file: "o/check.png", width: 0, height: 0, nonBlank: false,
                                           failures: ["label is \"p. 1\", expected \"p. 1, lines 47–49\"", "second\nline"])
        #expect(!failed.contains("\n"))                 // one object on one line, whatever a failure text contains
        let object = try #require(try JSONSerialization.jsonObject(with: Data(failed.utf8)) as? [String: Any])
        #expect(object["scene"] as? String == "check")
        #expect(object["nonBlank"] as? Bool == false)
        #expect(object["failures"] as? [String] == ["label is \"p. 1\", expected \"p. 1, lines 47–49\"", "second\nline"])
    }

    @Test func manifestLinesAreAppended() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("referee-manifest-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("manifest.jsonl")
        SnapshotManifest.append("{\"scene\":\"a\"}", to: file)
        SnapshotManifest.append("{\"scene\":\"b\"}", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"scene\":\"a\"}\n{\"scene\":\"b\"}\n")
    }

    // ---- blankness ----

    /// An image of one colour with a block of another colour that covers `fraction` of it, away from the top-left corner.
    private func image(width: Int = 200, height: Int = 100, background: (UInt8, UInt8, UInt8), block: (UInt8, UInt8, UInt8), fraction: Double) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let blockPixels = Int((Double(width * height) * fraction).rounded())
        for index in 0..<(width * height) {
            let colour = index >= width * height - blockPixels ? block : background      // the block fills the end of the buffer: the bottom rows
            pixels[index * 4] = colour.0
            pixels[index * 4 + 1] = colour.1
            pixels[index * 4 + 2] = colour.2
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func anImageIsBlankUnlessTwoPercentOfItsPixelsDifferFromTheTopLeftOne() throws {
        let white: (UInt8, UInt8, UInt8) = (255, 255, 255)
        let black: (UInt8, UInt8, UInt8) = (0, 0, 0)
        #expect(!SnapshotImage.isNonBlank(try image(background: white, block: black, fraction: 0)))
        #expect(!SnapshotImage.isNonBlank(try image(background: white, block: black, fraction: 0.01)))
        #expect(SnapshotImage.isNonBlank(try image(background: white, block: black, fraction: 0.03)))
        #expect(SnapshotImage.isNonBlank(try image(background: white, block: black, fraction: 0.5)))
        #expect(!SnapshotImage.isNonBlank(try image(background: black, block: black, fraction: 1)))       // one colour, even if not white
        #expect(SnapshotImage.isNonBlank(try image(background: black, block: white, fraction: 0.03)))

        // A difference of a few levels is not content: more than 8 of 255 in some channel is needed.
        #expect(!SnapshotImage.isNonBlank(try image(background: white, block: (250, 250, 250), fraction: 0.5)))
        #expect(SnapshotImage.isNonBlank(try image(background: white, block: (255, 255, 230), fraction: 0.5)))
    }

    @Test func aCapturedImageIsWrittenAsPNG() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("referee-png-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("scene.png")
        #expect(SnapshotImage.writePNG(try image(background: (255, 255, 255), block: (0, 0, 0), fraction: 0.5), to: file))
        #expect(try Data(contentsOf: file).prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(!SnapshotImage.writePNG(try image(background: (0, 0, 0), block: (0, 0, 0), fraction: 0), to: folder.appendingPathComponent("no/such/folder.png")))
    }

    // ---- fixture sessions ----

    @Test func aFixtureSessionIsCopiedUnderTheHashOfThePDFAsItIsOnDisk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-session-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(ReviewSession.self, from: Data(contentsOf: Fixtures.url("sessions/sample.json")))

        for name in ["ay_nolinks.pdf", "s1_ruler.pdf"] {
            let pdf = try Data(contentsOf: Fixtures.url("pdf/\(name)"))
            let expectedHash = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
            let hash = try SnapshotFiles.installSession(Fixtures.url("sessions/sample.json"), for: Fixtures.url("pdf/\(name)"), home: home)
            #expect(hash == expectedHash)

            let copy = home.appendingPathComponent("sessions/\(expectedHash)/session.json")
            let installed = try decoder.decode(ReviewSession.self, from: Data(contentsOf: copy))
            #expect(installed.document.sha256 == expectedHash)
            #expect(installed.document.byteCount == pdf.count)
            // Nothing else is touched.
            var restored = installed
            restored.document.sha256 = fixture.document.sha256
            restored.document.byteCount = fixture.document.byteCount
            #expect(restored == fixture)
            // The copy is in the format of the stores: sorted keys, two-space indentation, ISO 8601 dates.
            #expect(try String(contentsOf: copy, encoding: .utf8).hasPrefix("{\n  \"comments\" : ["))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("sessions").path).count == 2)
    }

    @Test func aFixtureSessionThatCannotBeUsedIsAnError() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("referee-session-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: SnapshotFiles.Problem.self) {
            try SnapshotFiles.installSession(Fixtures.url("sessions/no_such_session.json"), for: Fixtures.url("pdf/ay_nolinks.pdf"), home: home)
        }
        #expect(throws: SnapshotFiles.Problem.self) {
            try SnapshotFiles.installSession(Fixtures.url("sessions/sample.json"), for: Fixtures.url("pdf/no_such.pdf"), home: home)
        }
        #expect(throws: SnapshotFiles.Problem.self) {       // a file that is not a session
            try SnapshotFiles.installSession(Fixtures.url("llm/review_clean.txt"), for: Fixtures.url("pdf/ay_nolinks.pdf"), home: home)
        }
    }

    // ---- scenes ----

    /// Step 5c: a scene's own environment reaches its dependency graph, under the three keys of the snapshot mode,
    /// which it cannot change.
    @Test @MainActor func aScenesEnvironmentReachesItsGraphButNotTheThreeKeysOfTheMode() {
        let home = URL(fileURLWithPath: "/tmp/scene-home")
        let scene = SnapshotScene(name: "example", kind: .review,
                                  environment: ["REFEREE_SNAPSHOT_LOOKUPS": "notFound=Press", "REFEREE_HOME": "/elsewhere", "REFEREE_SNAPSHOT": "0"])
        #expect(SnapshotRunner.overrides(for: scene, home: home)
                == ["REFEREE_SNAPSHOT_LOOKUPS": "notFound=Press", "REFEREE_HOME": "/tmp/scene-home", "REFEREE_SNAPSHOT": "1", "REFEREE_NO_KEYCHAIN": "1"])
        #expect(SnapshotRunner.overrides(for: SnapshotScene(name: "plain", kind: .welcome), home: home)
                == ["REFEREE_HOME": "/tmp/scene-home", "REFEREE_SNAPSHOT": "1", "REFEREE_NO_KEYCHAIN": "1"])
        #expect(SnapshotScene(name: "plain", kind: .welcome).environment.isEmpty)
    }

    @Test @MainActor func thePlaceholderSceneExists() {
        let scene = ShellScenes.all.first { $0.name == "placeholder" }
        #expect(scene?.kind == .review)
        #expect(scene?.fixturePDF == "ay_round_nolinks.pdf")
        #expect(scene?.fixtureSession == nil)
        #expect(scene?.verify != nil)
    }

    /// Wave 3: the three scenes of section 10.1 that check behaviour, each with a `verify`, on the fixtures the table names.
    @Test @MainActor func theIntegrationScenesOfSection101() {
        let scenes = IntegrationScenes.all
        #expect(scenes.map(\.name) == ["check-document-loaded", "check-citation-click", "check-triage-keys"])
        #expect(scenes.allSatisfy { $0.kind == .review && $0.verify != nil })
        #expect(scenes.map(\.fixturePDF) == ["ay_round_nolinks.pdf", "ay_links.pdf", "ay_nolinks.pdf"])
        #expect(scenes.map(\.fixtureSession) == [nil, nil, "sample.json"])
    }
}
