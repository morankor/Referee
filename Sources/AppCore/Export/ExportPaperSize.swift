import Foundation

/// The paper of an exported PDF or Word document (plan.md section 6.10).
public enum PaperSize: Sendable {
    case letter, a4
    public static var current: PaperSize {       // letter when the locale's region is US, CA or MX, otherwise A4
        forRegion(Locale.current.region?.identifier)
    }

    /// The rule of `current` for a given region code (testable without changing the process's locale).
    static func forRegion(_ identifier: String?) -> PaperSize {
        switch identifier?.uppercased() {
        case "US", "CA", "MX": return .letter
        default: return .a4
        }
    }
}
