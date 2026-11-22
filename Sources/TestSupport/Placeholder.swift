import Foundation

// Wave 0a (plan.md section 11.4, WP0a): every type of this target exists with the public surface of section 11.3 and
// a trivial body. None of the documented behaviour is implemented yet. WP0b writes it (sections 5.9, 10.3 and the
// comments of section 11.3), adds a test for each fake to RefereeCoreTests, and deletes this file.

/// Thrown by the placeholder bodies of this target where a function has to throw.
struct NotImplementedYet: Error, CustomStringConvertible {
    let what: String
    var description: String { "TestSupport.\(what) is not implemented yet (plan.md section 11.4, WP0b)" }
}
