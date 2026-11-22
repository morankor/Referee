import Foundation
import PDFKit
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP0b writes the raw extraction of section 7.2 in its simplest
// working form; WP2 completes it.

public enum RawExtractor {
    /// Placeholder: an empty document.
    public static func extract(from document: PDFDocument) -> RawDocument { RawDocument() }
}
