import Foundation
import CoreGraphics

public typealias ProviderID = String

/// UTF-16 range into `PageText.string` (== `PDFPage.string`). The only text coordinate system in the app.
public struct TextRange: Codable, Sendable, Hashable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public init(_ r: NSRange) { self.location = r.location; self.length = r.length }
    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct TextSpan: Codable, Sendable, Hashable {
    public var pageIndex: Int          // 0-based PDF page index
    public var range: TextRange
    public init(pageIndex: Int, range: TextRange) { self.pageIndex = pageIndex; self.range = range }
}

/// Rectangle in PDF page space (origin bottom-left, points), as returned by PDFSelection.bounds(for:).
public struct PageRect: Codable, Sendable, Hashable {
    public var pageIndex: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(pageIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex; self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct PageSize: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Every error type in the app conforms to this so the UI can render any failure uniformly.
public protocol RefereeError: Error, Sendable {
    var userMessage: String { get }          // one sentence, no manuscript text, safe to log
    var recoverySuggestion: String? { get }
    var isRetryable: Bool { get }
}
