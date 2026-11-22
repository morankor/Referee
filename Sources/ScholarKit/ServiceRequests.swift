import Foundation

/// The requests of plan.md section 8.7 and the headers they carry. A request carries the reference text or the
/// identifier, `User-Agent: Referee/<version>`, and nothing else; the user's contact address goes to Crossref only,
/// and only when the user set one.
enum ServiceRequests {
    static let crossrefSelect = "DOI,title,author,issued,container-title,score,type"
    static let crossrefRows = 3
    static let openAlexSelect = "id,doi,title,publication_year,authorships,primary_location,open_access,best_oa_location"
    /// Characters of the entry text sent to Crossref.
    static let queryLength = 300
    /// A lookup is a small JSON answer; the shared session tolerates ten minutes of silence, a lookup does not.
    static let lookupTimeout: TimeInterval = 30

    /// `GET https://api.crossref.org/works?query.bibliographic=…&rows=3&select=…[&mailto=…]`. nil when the entry
    /// has no text to send.
    static func crossref(rawText: String, contact: String?) -> URLRequest? {
        let query = String(ReferenceText.collapsingWhitespace(rawText).prefix(queryLength))
        guard !query.isEmpty else { return nil }
        var parameters = "query.bibliographic=\(queryEncoded(query))&rows=\(crossrefRows)&select=\(crossrefSelect)"
        if let contact { parameters += "&mailto=\(queryEncoded(contact))" }
        guard let url = URL(string: "https://\(ServiceHost.crossref.rawValue)/works?\(parameters)") else { return nil }
        return lookupRequest(url, contact: contact)
    }

    /// `GET https://api.openalex.org/works/doi:<doi>?select=…`. Never carries a contact address.
    static func openAlex(doi: String) -> URLRequest? {
        guard let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(ServiceHost.openAlex.rawValue)/works/doi:\(path)?select=\(openAlexSelect)") else { return nil }
        return lookupRequest(url, contact: nil)
    }

    private static func lookupRequest(_ url: URL, contact: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: lookupTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent(contact: contact), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `Referee/<version>`, plus ` (mailto:<address>)` for Crossref when the user set an address.
    static func userAgent(contact: String?) -> String {
        "Referee/\(appVersion)" + (contact.map { " (mailto:\($0))" } ?? "")
    }

    /// The version of the bundled app (`CFBundleShortVersionString`, set by `scripts/bundle.sh`); outside the app
    /// bundle (tests, `referee-cli`, `scripts/run.sh`) the default version of `bundle.sh`, 0.1.0.
    static let appVersion: String = {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "local.referee.app",
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty, version.count <= 32,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return "0.1.0" }
        return version
    }()

    /// The Crossref contact address from the settings, or nil for the public pool: empty, or not usable as a plain
    /// address (it must not be able to break out of the query or of the User-Agent comment).
    static func contactAddress(_ setting: String) -> String? {
        let address = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.count <= 254 else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        let forbidden = Set("()<>[]\\\",;:")
        guard address.allSatisfy({ $0.isASCII && !$0.isWhitespace && !forbidden.contains($0) }),
              address.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return address
    }

    /// Percent-encodes everything but the unreserved characters of RFC 3986, so that `&`, `=`, `+`, `#` and
    /// quotation marks in a reference cannot change the query. Spaces become `%20`.
    static func queryEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
