import SwiftUI
import AppKit
import RefereeCore
import AppCore

// The scene description of the snapshot mode (plan.md sections 10.1 and 11.3). Declarations only: there is no
// behaviour here. The runner that uses them is in CommonSnapshotRunner.swift.

@MainActor public struct SnapshotContext {
    public let window: NSWindow
    public let model: ReviewSessionModel?         // review scenes
    public let reader: ReaderController?          // review scenes; the runner has already called attach()
    public let settings: SettingsModel?           // settings scenes
    public init(window: NSWindow, model: ReviewSessionModel? = nil, reader: ReaderController? = nil, settings: SettingsModel? = nil) {
        self.window = window; self.model = model; self.reader = reader; self.settings = settings
    }
}

@MainActor public struct SnapshotScene {
    public enum Kind { case review, settings, welcome, referenceViewer }
    public var name: String
    public var kind: Kind
    public var fixturePDF: String?                // under Fixtures/pdf (review and referenceViewer scenes)
    public var fixtureSession: String?            // under Fixtures/sessions; copied into the temporary REFEREE_HOME with document.sha256
                                                  // and byteCount rewritten to those of the fixture PDF as it is on disk
    public var settleSeconds: Double
    public var prepare: @MainActor (SnapshotContext) async -> Void        // drive the models through their public API
    public var verify: (@MainActor (SnapshotContext) async -> [String])?  // after capture: failed expectations; [] = pass
    public init(name: String, kind: Kind, fixturePDF: String? = nil, fixtureSession: String? = nil, settleSeconds: Double = 2.0,
                prepare: @escaping @MainActor (SnapshotContext) async -> Void = { _ in },
                verify: (@MainActor (SnapshotContext) async -> [String])? = nil) {
        self.name = name; self.kind = kind; self.fixturePDF = fixturePDF; self.fixtureSession = fixtureSession
        self.settleSeconds = settleSeconds; self.prepare = prepare; self.verify = verify
    }
}
