import Foundation
import RefereeCore

/// Why a report could not be exported (plan.md Appendix A.9; section 6.10).
public enum ExportError: RefereeError, Equatable {
    case couldNotCreate(String)              // the Word or PDF data could not be produced
    case couldNotWrite(String)               // the file could not be written where the user chose
    public var userMessage: String {
        switch self {
        case .couldNotCreate(let why): return "The report could not be exported (\(why))."
        case .couldNotWrite(let why): return "The exported report could not be saved (\(why))."
        }
    }
    public var recoverySuggestion: String? { "Try another format or another folder." }
    public var isRetryable: Bool { false }
}
