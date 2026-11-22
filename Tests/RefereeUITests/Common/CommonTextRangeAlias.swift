import RefereeCore

/// `import Foundation` also brings the Apple Events C struct `TextRange` (CoreServices), which makes the bare name
/// ambiguous in type position. A declaration in this module shadows both imports (plan.md section 3.7): one per module.
typealias TextRange = RefereeCore.TextRange
