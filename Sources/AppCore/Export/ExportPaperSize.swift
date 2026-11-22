import Foundation

// Written in Wave 0 (plan.md section 11.4, WP0a) from the one-line rule of section 11.3. WP8a owns and tests it.

public enum PaperSize: Sendable {
    case letter, a4
    public static var current: PaperSize {       // letter when the locale's region is US, CA or MX, otherwise A4
        switch Locale.current.region?.identifier {
        case "US", "CA", "MX": return .letter
        default: return .a4
        }
    }
}
