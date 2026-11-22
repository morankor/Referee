import Foundation
import PDFKit
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP2 implements it (section 7.4).

@MainActor public enum SelectionInfoBuilder {
    /// The selection exactly as PDFKit reports it: one span and one rectangle per line. Not normalised (section 7.4).
    /// Placeholder: nil.
    public static func make(from selection: PDFSelection, in document: PDFDocument) -> SelectionInfo? { nil }
}
