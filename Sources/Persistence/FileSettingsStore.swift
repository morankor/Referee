import Foundation
import RefereeCore

// Wave 0 placeholder (plan.md section 11.4, WP0a). WP8a replaces it with the file store of section 4.4.

/// Placeholder: settings are kept in memory for the life of this object. Nothing is read from or written to
/// `fileURL`: `load` returns the defaults until something has been saved.
public actor FileSettingsStore: SettingsStoring {     // <dataDirectory>/settings.json
    private let fileURL: URL
    private var saved: AppSettings?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async -> AppSettings {
        saved ?? DefaultSettings.make()
    }

    public func save(_ settings: AppSettings) async throws {
        saved = settings
    }
}
