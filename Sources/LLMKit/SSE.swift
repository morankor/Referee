import Foundation

/// One line of a server-sent-events body, classified by the rule of plan section 5.3, which holds for all four SSE
/// vendors: each line is processed on its own, and the kind of an event is read from its JSON, never from `event:`.
enum SSELine: Equatable {
    case event(JSONValue)      // "data:" followed by one complete JSON value
    case done                  // "data: [DONE]"
    case ignored               // "event:", "id:", "retry:", ":" comments, empty lines, and data that is not JSON
}

enum SSE {
    static func classify(_ line: String) -> SSELine {
        guard line.hasPrefix("data:") else { return .ignored }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }   // one optional space
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return .done }
        guard let value = JSONValue.parse(payload) else { return .ignored }
        return .event(value)
    }
}
