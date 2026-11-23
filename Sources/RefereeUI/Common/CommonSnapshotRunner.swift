import SwiftUI
import AppKit
import CryptoKit
import ImageIO
import RefereeCore
import AppCore
import TestSupport

// The snapshot mode (plan.md section 10.1): the app shows its own windows off screen, captures them itself and writes
// PNGs that an agent can open. It needs no Screen Recording permission, starts no process and opens no connection.
//
//     Referee --ui-snapshot <outDir> [--scene <name>]… [--dark] [--size 1280x800]
//
// Where section 10.1 leaves a choice, this file decides (also listed in docs/contract-notes/wp0b-testsupport.md):
// - Every scene gets a data folder and a dependency graph of its own, so no scene sees what another one saved.
// - Window sizes: review 1280 × 800, reference viewer 900 × 700, settings 780 × 560, welcome the size the view asks
//   for (640 × 440 when it asks for none). `--size` applies to review and reference-viewer scenes only.
// - A welcome scene gets two sample summaries of recent reviews. A reference-viewer scene shows the scene's `fixturePDF`.
// - In a review scene `prepare` is called once the reader has loaded the display document (after three seconds at
//   the latest) and the window has been laid out once more, so a scene can use the PDF view at once, a click placed
//   by `hitTest` included (Wave 3).
// - Besides what `verify` returns, these count as failed expectations: a review scene whose `fixturePDF` does not
//   load; a window that did not keep the size it was given (a view whose minimum size is larger makes the window
//   grow, in the app as much as here); a data folder, a capture or a PNG that could not be made.
// - The window is an NSWindow in every respect but one: AppKit may not shrink it to the screen. A scene therefore
//   has the size it was given on any display, also one that is smaller than the window.

@MainActor public enum SnapshotRunner {
    /// Runs ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all (or the named ones) and returns the exit code.
    ///
    /// `arguments` are the arguments of the process ("--ui-snapshot <outDir> [--scene <name>]… [--dark] [--size WxH]"),
    /// with or without the program name in front.
    /// 0: every scene was captured, is not blank and has no failed expectation. 1: otherwise, also when a named scene
    /// does not exist or there is nothing to run. 2: the arguments are wrong.
    public static func run(arguments: [String], makeDependencies: @escaping @Sendable ([String: String]) async -> AppDependencies) async -> Int32 {
        let options: SnapshotOptions
        do {
            options = try SnapshotOptions(arguments: arguments)
        } catch {
            say("Referee: \(error)\n\(SnapshotOptions.usage)")
            return 2
        }

        let all = ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all
        let unknown = options.sceneNames.filter { name in !all.contains { $0.name == name } }
        guard unknown.isEmpty else {
            say("Referee: no scene named \(unknown.joined(separator: ", ")). Scenes: \(all.map(\.name).joined(separator: ", "))")
            return 1
        }
        let scenes = options.sceneNames.isEmpty ? all : all.filter { options.sceneNames.contains($0.name) }
        guard !scenes.isEmpty else {
            say("Referee: there is no scene to capture")
            return 1
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("referee-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)
        } catch {
            say("Referee: the output directory could not be created")
            return 1
        }

        var everySceneIsGood = true
        for scene in scenes {
            let result = await capture(scene, options: options, home: root.appendingPathComponent(scene.name, isDirectory: true),
                                       makeDependencies: makeDependencies)
            let line = SnapshotManifest.line(scene: scene.name, file: options.pngPath(for: scene.name), width: result.width, height: result.height,
                                             nonBlank: result.nonBlank, failures: result.failures)
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
            SnapshotManifest.append(line, to: options.outDirectory.appendingPathComponent("manifest.jsonl"))
            Log.event("snapshot.scene", ["scene": .id(scene.name), "nonBlank": .bool(result.nonBlank), "failures": .int(result.failures.count)])
            if !result.isGood { everySceneIsGood = false }
        }
        return everySceneIsGood ? 0 : 1
    }

    // ---- one scene ----

    private struct SceneResult {
        var width = 0
        var height = 0
        var nonBlank = false
        var captured = false
        var failures: [String] = []
        var isGood: Bool { captured && nonBlank && failures.isEmpty }
    }

    /// The environment a scene's dependency graph is made with: the scene's own (`SnapshotScene.environment`, step 5c),
    /// then REFEREE_HOME, REFEREE_SNAPSHOT and REFEREE_NO_KEYCHAIN, which no scene can change.
    static func overrides(for scene: SnapshotScene, home: URL) -> [String: String] {
        scene.environment.merging(["REFEREE_HOME": home.path, "REFEREE_SNAPSHOT": "1", "REFEREE_NO_KEYCHAIN": "1"]) { _, fixed in fixed }
    }

    private static func capture(_ scene: SnapshotScene, options: SnapshotOptions, home: URL,
                                makeDependencies: @Sendable ([String: String]) async -> AppDependencies) async -> SceneResult {
        var result = SceneResult()
        let fixturePDF = scene.fixturePDF.map { Fixtures.url("pdf/\($0)") }
        let settings = SnapshotSupport.settings()

        // 1. A fresh data folder with the snapshot settings and, when the scene names one, the fixture session.
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try SnapshotFiles.encoder.encode(settings).write(to: home.appendingPathComponent("settings.json"))
            if let session = scene.fixtureSession {
                guard let fixturePDF else { throw SnapshotFiles.Problem("the scene names a fixture session but no fixture PDF") }
                try SnapshotFiles.installSession(Fixtures.url("sessions/\(session)"), for: fixturePDF, home: home)
            }
        } catch {
            result.failures.append("the scene's data folder could not be prepared: \(error)")
            return result
        }

        // The whole graph, the engine included, on mock and static providers and the fake resolver (section 10.1, step 1);
        // the scene's own environment under the three keys of the snapshot mode, which win (step 5c).
        let dependencies = await makeDependencies(overrides(for: scene, home: home))
        try? await dependencies.settings.save(settings)     // also reaches a settings store that does not read the file

        // 2. The window, made as the app makes it, in a fixed size and appearance, shown off screen.
        let window: NSWindow
        let context: SnapshotContext
        var model: ReviewSessionModel?
        var fixedSize: NSSize?                  // the content size the window was given; nil: the view chose it
        switch scene.kind {
        case .review:
            let reviewModel = ReviewSessionModel(dependencies: dependencies, settings: settings)
            let reader = ReaderController(model: reviewModel)
            fixedSize = options.size ?? NSSize(width: 1280, height: 800)
            window = makeWindow(ReviewWindowView(model: reviewModel, reader: reader), title: scene.fixturePDF ?? "Referee",
                                size: fixedSize, isDocumentWindow: true, dark: options.dark)
            reader.attach()
            context = SnapshotContext(window: window, model: reviewModel, reader: reader)
            model = reviewModel
        case .settings:
            let settingsModel = SettingsModel(dependencies: dependencies, settings: settings)
            fixedSize = NSSize(width: 780, height: 560)
            window = makeWindow(SettingsRootView(model: settingsModel), title: "Settings", size: fixedSize,
                                isDocumentWindow: false, dark: options.dark)
            context = SnapshotContext(window: window, settings: settingsModel)
        case .welcome:
            window = makeWindow(WelcomeView(recent: sampleRecentReviews(), open: { _ in }), title: "Referee", size: nil,
                                isDocumentWindow: false, dark: options.dark)
            context = SnapshotContext(window: window)
        case .referenceViewer:
            guard let fixturePDF else {
                result.failures.append("a reference-viewer scene needs a fixture PDF")
                return result
            }
            let title = fixturePDF.deletingPathExtension().lastPathComponent
            fixedSize = options.size ?? NSSize(width: 900, height: 700)
            window = makeWindow(ReferenceViewerView(fileURL: fixturePDF, title: title), title: title,
                                size: fixedSize, isDocumentWindow: true, dark: options.dark)
            context = SnapshotContext(window: window)
        }
        defer { window.close() }

        if let model, let fixturePDF {
            await model.open(url: fixturePDF)
            if case .failed(let message) = model.phase { result.failures.append("the fixture PDF did not open: \(message)") }
            // The reader shows the paper a moment after the model has it. `prepare` may use the PDF view at once
            // (a selection, a scroll position), so it is not called before the display document is there.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(3)
            while model.paper != nil, context.reader?.isDocumentLoaded != true, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            // `open` sets `.ready` last, in the same turn of the run loop in which it returns, and SwiftUI applies a
            // change on the window's next layout pass. Until then the window still shows the document as loading: the
            // Shell's "Opening…" panel lies over the PDF, and `hitTest` finds the panel there instead of the PDF view
            // (Wave 3: this is why `reader-citation` failed in the merged window). One layout pass now, so that
            // `prepare` gets the window as the model is.
            window.contentView?.layoutSubtreeIfNeeded()
        }

        // 3. The scene drives its models; then the main run loop turns while pages render and layout settles.
        await scene.prepare(context)
        try? await Task.sleep(for: .seconds(max(0, scene.settleSeconds)))

        // 4. The app's own window, captured by the window server.
        let image = SnapshotImage.capture(window)
        if let fixedSize {
            let actual = window.contentRect(forFrameRect: window.frame).size
            if abs(actual.width - fixedSize.width) > 0.5 || abs(actual.height - fixedSize.height) > 0.5 {
                result.failures.append("the window is \(Int(actual.width)) x \(Int(actual.height)) points, not the "
                    + "\(Int(fixedSize.width)) x \(Int(fixedSize.height)) it was given: the size limits of its view do not allow that size")
            }
        }

        // 5. Expectations about behaviour.
        if let verify = scene.verify { result.failures += await verify(context) }

        // 6. The picture.
        guard let image else {
            result.failures.append("the window could not be captured")
            return result
        }
        result.width = image.width
        result.height = image.height
        result.nonBlank = SnapshotImage.isNonBlank(image)
        result.captured = SnapshotImage.writePNG(image, to: options.outDirectory.appendingPathComponent("\(scene.name).png"))
        if !result.captured { result.failures.append("the PNG could not be written") }
        return result
    }

    /// `NSWindow(contentViewController: NSHostingController(rootView:))`, as every window of the app is made (section 9.1).
    /// `size` nil: the size the view asks for.
    ///
    /// The window is shown almost entirely off screen, so that a snapshot run does not put windows over the user's
    /// work: only its top right corner, 40 by 74 points, lies inside the bottom left of the main screen. That is
    /// where AppKit itself puts a window that is sent to (-6000, -6000), and AppKit and the window server draw a
    /// window in that position completely.
    private static func makeWindow(_ root: some View, title: String, size: NSSize?, isDocumentWindow: Bool, dark: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        let window = SnapshotWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.styleMask = isDocumentWindow
            ? [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable]
        window.title = title
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let asked = hosting.view.fittingSize
        window.setContentSize(size ?? (asked.width >= 300 && asked.height >= 200 ? asked : NSSize(width: 640, height: 440)))
        window.orderFrontRegardless()
        window.moveOffScreen()
        return window
    }

    /// What a welcome scene lists under "recent reviews": two fixtures, with dates and counts that never change.
    /// The paths are relative to the repository root, where snapshots run: an absolute one would put the checkout's
    /// location, and with it the user's home folder, into any picture that shows a path.
    private static func sampleRecentReviews() -> [SessionSummary] {
        [
            SessionSummary(id: String(repeating: "a1", count: 32), fileName: "ay_round_nolinks.pdf",
                           title: "Information Aggregation in Sequential Markets: A Fixture",
                           lastKnownPath: "Fixtures/pdf/ay_round_nolinks.pdf", updatedAt: Date(timeIntervalSince1970: 1_795_000_000),
                           commentCount: 12, pendingCount: 3, hasReport: false),
            SessionSummary(id: String(repeating: "b2", count: 32), fileName: "num_links.pdf",
                           title: "A Single-Column Numeric Fixture With Links",
                           lastKnownPath: "Fixtures/pdf/num_links.pdf", updatedAt: Date(timeIntervalSince1970: 1_794_400_000),
                           commentCount: 7, pendingCount: 0, hasReport: true),
        ]
    }

    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// The window of a scene. It differs from a plain NSWindow in one thing: AppKit does not get to move or shrink it.
/// A plain window is cut down to the visible part of the screen when it is shown, so that a scene of 1280 × 800
/// points would come out lower on a display with a large Dock, or with fewer points.
private final class SnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Leaves only the top right corner on the main screen (see `makeWindow`). Without a screen the window goes far away.
    func moveOffScreen() {
        guard let screen = NSScreen.screens.first else {
            setFrameOrigin(NSPoint(x: -6000, y: -6000))
            return
        }
        setFrameOrigin(NSPoint(x: screen.frame.minX + 40 - frame.width, y: screen.frame.minY + 74 - frame.height))
    }
}

// ---- arguments ----

/// The arguments of the snapshot mode.
struct SnapshotOptions: Equatable {
    var outDirectory: URL
    var outPath: String                     // as typed, so that the manifest names files the way the caller did
    var sceneNames: [String] = []           // empty: every scene
    var dark = false
    var size: NSSize?                       // review and reference-viewer windows; nil: their default sizes

    static let usage = "usage: Referee --ui-snapshot <outDir> [--scene <name>]… [--dark] [--size 1280x800]"

    struct Problem: Error, CustomStringConvertible, Equatable {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// `arguments` are the process arguments, with or without the program name in front. Anything else it does not
    /// know is an error: a mistyped option must not silently change what is captured.
    init(arguments: [String]) throws {
        var outPath: String?
        var index = arguments.first?.hasPrefix("--") == false ? 1 : 0       // a first argument that is no option is the program name
        func value(after option: String) throws -> String {
            guard index + 1 < arguments.count else { throw Problem("\(option) needs a value") }
            index += 1
            return arguments[index]
        }
        var sceneNames: [String] = []
        var dark = false
        var size: NSSize?
        while index < arguments.count {
            switch arguments[index] {
            case "--ui-snapshot": outPath = try value(after: "--ui-snapshot")
            case "--scene": sceneNames.append(try value(after: "--scene"))
            case "--dark": dark = true
            case "--size":
                let text = try value(after: "--size")
                let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, text.lowercased().split(separator: "x").count == 2, parts[0] >= 200, parts[1] >= 200,
                      parts[0] <= 8_000, parts[1] <= 8_000 else {
                    throw Problem("--size needs a width and a height in points, for example 1280x800")
                }
                size = NSSize(width: parts[0], height: parts[1])
            default: throw Problem("unknown argument \(arguments[index])")
            }
            index += 1
        }
        guard let outPath, !outPath.isEmpty else { throw Problem("--ui-snapshot needs an output directory") }
        self.outPath = outPath
        self.outDirectory = URL(fileURLWithPath: outPath, isDirectory: true)
        self.sceneNames = sceneNames
        self.dark = dark
        self.size = size
    }

    /// "<outDir>/<scene>.png", with the directory spelled as it was typed.
    func pngPath(for scene: String) -> String {
        (outPath.hasSuffix("/") ? outPath : outPath + "/") + scene + ".png"
    }
}

// ---- files ----

enum SnapshotFiles {
    struct Problem: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The format of everything the app writes to disk (plan section 3.7).
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Copies a fixture session to <home>/sessions/<sha256>/session.json, with `document.sha256` and
    /// `document.byteCount` rewritten to those of the fixture PDF as it is on disk now. A rebuilt fixture has another
    /// hash, so the fixture session cannot carry it. Returns the hash.
    @discardableResult
    static func installSession(_ fixture: URL, for pdf: URL, home: URL) throws -> String {
        let pdfData: Data
        do { pdfData = try Data(contentsOf: pdf) } catch { throw Problem("the fixture PDF \(pdf.lastPathComponent) could not be read") }
        var session: ReviewSession
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            session = try decoder.decode(ReviewSession.self, from: Data(contentsOf: fixture))
        } catch {
            throw Problem("the fixture session \(fixture.lastPathComponent) could not be read as a ReviewSession")
        }
        let sha256 = SHA256.hash(data: pdfData).map { String(format: "%02x", $0) }.joined()
        session.document.sha256 = sha256
        session.document.byteCount = pdfData.count
        let folder = home.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sha256, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: folder.appendingPathComponent("session.json"))
        return sha256
    }
}

// ---- manifest ----

enum SnapshotManifest {
    /// One JSON object on one line, keys in the order section 10.1 prints them:
    /// {"scene":"review-pending","file":"…","width":2560,"height":1600,"nonBlank":true,"failures":[]}
    static func line(scene: String, file: String, width: Int, height: Int, nonBlank: Bool, failures: [String]) -> String {
        "{\"scene\":\(quoted(scene)),\"file\":\(quoted(file)),\"width\":\(width),\"height\":\(height),\"nonBlank\":\(nonBlank),"
            + "\"failures\":[\(failures.map(quoted).joined(separator: ","))]}"
    }

    /// A JSON string literal.
    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    /// Adds the line to the file, creating it when it does not exist.
    static func append(_ line: String, to file: URL) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

// ---- image ----

enum SnapshotImage {
    private typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// The window as the window server holds it. `CGWindowListCreateImage` is marked unavailable in the Swift SDK
    /// since macOS 15, so it is looked up at run time. It is the only method that works: `NSView.cacheDisplay(in:to:)`
    /// and `CALayer.render(in:)` give empty frames for SwiftUI and PDF content (plan section 10.1).
    @MainActor static func capture(_ window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }   // -2: RTLD_DEFAULT
        let createImage = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        let includingWindow: UInt32 = 8                     // kCGWindowListOptionIncludingWindow
        let ignoreFramingAtBestResolution: UInt32 = 1 | 8   // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return createImage(.null, includingWindow, UInt32(window.windowNumber), ignoreFramingAtBestResolution)?.takeRetainedValue()
    }

    /// True when at least 2% of the pixels differ from the top-left pixel by more than 8/255 in any channel.
    static func isNonBlank(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return false }
        // The buffer starts with the top row, so its first four bytes are the top-left pixel.
        let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        let reference = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
        var different = 0
        var offset = 0
        while offset < bytes.count {
            if abs(Int(bytes[offset]) - reference.0) > 8 || abs(Int(bytes[offset + 1]) - reference.1) > 8
                || abs(Int(bytes[offset + 2]) - reference.2) > 8 || abs(Int(bytes[offset + 3]) - reference.3) > 8 {
                different += 1
            }
            offset += 4
        }
        return different * 50 >= width * height
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
