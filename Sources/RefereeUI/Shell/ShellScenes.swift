import SwiftUI
import PDFKit
import RefereeCore
import AppCore

// Wave 0 (plan.md section 11.4, WP0b): one scene, "placeholder", which shows that the snapshot mode works from end
// to end: three columns and a PDF page. WP11 adds its seven scenes of section 10.1 and keeps this one as it is: it is
// in the scene table of section 10.1, and a test in Tests/RefereeUITests/Common, which WP11 does not own, checks it.

@MainActor public enum ShellScenes {
    public static var all: [SnapshotScene] {
        [
            SnapshotScene(name: "placeholder", kind: .review, fixturePDF: "ay_round_nolinks.pdf", verify: { context in
                guard let document = context.reader?.pdfView.document else { return ["the display document is not loaded"] }
                return document.pageCount == 4 ? [] : ["the display document has \(document.pageCount) pages, expected 4"]
            }),
        ]
    }
}
