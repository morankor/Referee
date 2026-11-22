import AppKit
import PDFKit

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP9 adds the two overrides.

public final class RefereePDFView: PDFView {}             // overrides mouseDown(with:) and areaOfInterest(for:) (section 7.4)
