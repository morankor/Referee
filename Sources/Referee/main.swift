import Foundation
import RefereeUI
import Composition
AppMain.run { overrides in
    await LiveDependencies.make(environment: ProcessInfo.processInfo.environment.merging(overrides) { _, new in new })
}
