import Foundation
import RefereeCore

/// The settings file (plan.md sections 4.2 and 4.4). No secrets are in it (section 12.1).
///
/// `load()` never fails: it returns `DefaultSettings.make()` when the file is missing, unreadable, damaged or of a
/// newer format. A damaged file is first renamed settings.corrupt-<UTC time>.json, so that the next save does not
/// destroy what the user may want to recover by hand; a file of a newer format stays as it is, and `save` refuses to
/// replace it (`StoreError.newerSchema`). A file that decodes gets the default entry of every known provider it lacks;
/// keys this version does not know are ignored.
public actor FileSettingsStore: SettingsStoring {     // <dataDirectory>/settings.json
    /// The newest settings format this version reads and writes (plan section 4.4).
    static let currentSchemaVersion = 1
    static let quarantineStem = "settings.corrupt"

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async -> AppSettings {
        let defaults = DefaultSettings.make()
        guard StoreFiles.exists(fileURL) else { return defaults }
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.event("persistence.settings.unreadable")
            return defaults
        }
        switch StoreFiles.probe(AppSettings.self, from: data, supported: Self.currentSchemaVersion) {
        case .value(var settings):
            for (id, provider) in defaults.providers where settings.providers[id] == nil {
                settings.providers[id] = provider
            }
            return settings
        case .newer(let found):
            Log.event("persistence.settings.newerSchema", ["found": .int(found)])
            return defaults
        case .damaged:
            let moved = (try? StoreFiles.quarantine(fileURL, stem: Self.quarantineStem)) != nil
            Log.event("persistence.settings.damaged", ["movedAside": .bool(moved)])
            return defaults
        }
    }

    /// Writes the whole file atomically, creating its folder when needed.
    public func save(_ settings: AppSettings) async throws {
        let data: Data
        do {
            data = try StoreCoding.encoder().encode(settings)
        } catch {
            throw StoreError.io("the settings could not be encoded")
        }
        do {
            try StoreFiles.createDirectory(fileURL.deletingLastPathComponent())
            if StoreFiles.exists(fileURL) {
                switch try StoreFiles.probeBeforeReplacing(fileURL, supported: Self.currentSchemaVersion) {
                case .value: break
                case .newer(let found):
                    Log.event("persistence.settings.saveRefusedNewerSchema", ["found": .int(found)])
                    throw StoreError.newerSchema(found: found, supported: Self.currentSchemaVersion)
                case .damaged:
                    _ = try StoreFiles.quarantine(fileURL, stem: Self.quarantineStem)
                }
            }
            try data.write(to: fileURL, options: .atomic)
        } catch let error as StoreError {
            throw error
        } catch {
            Log.event("persistence.settings.saveFailed")
            throw StoreError.io("the settings could not be saved: \(error.localizedDescription)")
        }
    }
}
