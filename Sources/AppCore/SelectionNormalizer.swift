import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP8b implements the normalisation of section 7.4.

public enum SelectionNormalizer {
    /// Clips every span to the contentRange of the .body lines it touches, drops what lies on other lines, and rebuilds
    /// `text` from the clipped pieces. `rects` come back empty (the model fills them with PaperService.rects). nil when nothing is left.
    /// Placeholder: the selection comes back unchanged.
    public static func normalize(_ selection: SelectionInfo, in text: PaperText) -> SelectionInfo? { selection }
}
