import Foundation
import RefereeCore

/// Endpoints and `ProviderSettings.baseURL`, which replaces the scheme, host and port of every endpoint of an HTTP
/// provider and keeps its path and query (plan section 5.3).
enum Endpoint {
    /// `defaultURL` (a literal of an adapter) with the scheme, host and port of `override`. An override without a scheme
    /// gets the default's. Throws `.invalidRequest` for an override that is not an http or https address.
    static func resolve(_ defaultURL: String, override: String?) throws -> URL {
        // An adapter's own literal that is no URL is a programming error; it fails the request instead of stopping the
        // app (no `preconditionFailure` in Sources/, plan section 3.7).
        guard var components = URLComponents(string: defaultURL), let defaultScheme = components.scheme else {
            throw LLMError.invalidRequest("the built-in address “\(defaultURL)” is not a URL")
        }
        if let base = try base(override, defaultScheme: defaultScheme) {
            components.scheme = base.scheme
            components.percentEncodedHost = base.percentEncodedHost
            components.port = base.port
        }
        guard let url = components.url else { throw invalid(override) }
        return url
    }

    /// The destination the indicator shows (section 9.7): host, and port when the address names one. An override that
    /// is not valid is shown as typed, since nothing can be sent to it.
    static func destination(_ defaultURL: String, override: String?) -> String {
        guard let url = try? resolve(defaultURL, override: override),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.percentEncodedHost else {
            return override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultURL
        }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// The host alone, for a sentence such as "Sent to 192.168.1.5 on your network."
    static func host(_ defaultURL: String, override: String?) -> String {
        guard let url = try? resolve(defaultURL, override: override),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost else {
            return override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultURL
        }
        return host
    }

    /// True only for 127.0.0.1, localhost and ::1 (section 5.2). An override that is not valid is not local.
    static func isLoopback(_ defaultURL: String, override: String?) -> Bool {
        guard let url = try? resolve(defaultURL, override: override),
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost else { return false }
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "127.0.0.1" || bare == "localhost" || bare == "::1"
    }

    /// `url` with `items` appended to its query.
    static func adding(_ items: [URLQueryItem], to url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw invalid(url.absoluteString) }
        components.queryItems = (components.queryItems ?? []) + items
        guard let result = components.url else { throw invalid(url.absoluteString) }
        return result
    }

    // ---- private ----

    private static func base(_ override: String?, defaultScheme: String) throws -> URLComponents? {
        guard let raw = override?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let text = raw.contains("://") ? raw : "\(defaultScheme)://\(raw)"
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.percentEncodedHost, !host.isEmpty else {
            throw invalid(raw)
        }
        var result = URLComponents()
        result.scheme = scheme
        result.percentEncodedHost = host
        result.port = components.port
        return result
    }

    private static func invalid(_ text: String?) -> LLMError {
        .invalidRequest("the base URL “\(text ?? "")” in Settings is not an http or https address")
    }
}
