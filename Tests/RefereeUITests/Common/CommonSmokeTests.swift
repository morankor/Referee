import Foundation
import Testing
import RefereeUI

/// Wave 0a smoke tests for what RefereeUI/Common declares. They must keep holding in every later wave.
@Suite struct CommonSmokeTests {
    @Test @MainActor func aSceneStartsFromThePrintedDefaults() {
        let scene = SnapshotScene(name: "example", kind: .welcome)
        #expect(scene.name == "example")
        #expect(scene.fixturePDF == nil)
        #expect(scene.fixtureSession == nil)
        #expect(scene.settleSeconds == 2.0)
        #expect(scene.verify == nil)
    }

    /// Each scene is written to <name>.png, so two scenes with one name would overwrite each other.
    @Test @MainActor func sceneNamesAreUnique() {
        let names = (ShellScenes.all + ReaderScenes.all + SidebarScenes.all + IntegrationScenes.all).map(\.name)
        #expect(Set(names).count == names.count)
    }
}
