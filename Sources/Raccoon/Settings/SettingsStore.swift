import Foundation
import RaccoonCore

/// JSON persistence for `Settings`, stored at
/// `~/Library/Application Support/Raccoon/settings.json`.
///
/// `load()` is total: on a missing or corrupt file it returns `Settings.default` rather
/// than throwing, so a bad write can never brick app launch. `save(_:)` is best-effort —
/// it ensures the parent directory exists and silently ignores write failures (the next
/// settings change retries; nothing depends on a single write succeeding synchronously).
enum SettingsStore {

    /// Absolute path of the settings file:
    /// `~/Library/Application Support/Raccoon/settings.json`.
    static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Raccoon", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Decode `Settings` from `fileURL`. Falls back to `Settings.default` when the file is
    /// absent or can't be decoded (e.g. truncated by a crash, or a schema change).
    static func load() -> Settings {
        guard
            let data = try? Data(contentsOf: fileURL),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    /// Encode `settings` to `fileURL` (pretty-printed for human inspection). Best-effort:
    /// creates the parent directory if needed and ignores any write error.
    static func save(_ settings: Settings) {
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: url, options: .atomic)
        } catch {
            // Non-fatal: settings persistence is best-effort; the next change retries.
        }
    }
}
