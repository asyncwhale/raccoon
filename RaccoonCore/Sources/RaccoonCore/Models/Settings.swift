import Foundation

/// User-facing configuration for the Raccoon app.
public struct Settings: Sendable, Codable, Equatable {
    /// Number of days to retain records before auto-cleanup. `nil` means keep forever.
    public var retentionDays: Int?

    /// Directory where archived session records are stored.
    public var recordsDir: URL

    /// Directory where user-written notes are stored.
    public var notesDir: URL

    /// When `true`, Raccoon cleans pasted text automatically via CleanEngine.
    public var autoCleanOnPaste: Bool

    /// When `true` (and `autoCleanOnPaste` is on), pasted PROSE is also tidied:
    /// leading paragraph indentation is stripped and excess blank lines are
    /// collapsed. Never affects code/table structure. Opt-in; default `false`.
    public var autoTidyProseOnPaste: Bool

    /// The set of tools whose sessions are actively ingested.
    public var enabledTools: Set<Tool>

    /// When `true`, the app runs as a menu-bar/agent app (`.accessory` activation
    /// policy): no Dock icon, summoned from the menu-bar icon or the global hotkey.
    /// This makes the pinned window float reliably above other apps' full-screen
    /// spaces. Default `false` (regular app with a Dock icon). Opt-in.
    public var menuBarMode: Bool

    public init(
        retentionDays: Int?,
        recordsDir: URL,
        notesDir: URL,
        autoCleanOnPaste: Bool,
        autoTidyProseOnPaste: Bool = false,
        enabledTools: Set<Tool>,
        menuBarMode: Bool = false
    ) {
        self.retentionDays = retentionDays
        self.recordsDir = recordsDir
        self.notesDir = notesDir
        self.autoCleanOnPaste = autoCleanOnPaste
        self.autoTidyProseOnPaste = autoTidyProseOnPaste
        self.enabledTools = enabledTools
        self.menuBarMode = menuBarMode
    }

    /// Factory method that produces sensible out-of-the-box defaults.
    ///
    /// - `recordsDir`: `~/Library/Application Support/Raccoon/records`
    /// - `notesDir`:   `~/Library/Application Support/Raccoon/notes`
    /// - `retentionDays`: 30
    /// - `autoCleanOnPaste`: true
    /// - `enabledTools`: `.claudeCode` and `.codex`
    public static var `default`: Settings {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let raccoon = appSupport.appendingPathComponent("Raccoon", isDirectory: true)
        return Settings(
            retentionDays: 30,
            recordsDir: raccoon.appendingPathComponent("records", isDirectory: true),
            notesDir: raccoon.appendingPathComponent("notes", isDirectory: true),
            autoCleanOnPaste: true,
            autoTidyProseOnPaste: false,
            enabledTools: [.claudeCode, .codex],
            menuBarMode: false
        )
    }

    // Custom decoding so settings archived BEFORE `autoTidyProseOnPaste` /
    // `menuBarMode` existed still load (the missing key defaults to `false`
    // — both are opt-in).
    private enum CodingKeys: String, CodingKey {
        case retentionDays, recordsDir, notesDir
        case autoCleanOnPaste, autoTidyProseOnPaste, enabledTools, menuBarMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays)
        self.recordsDir = try c.decode(URL.self, forKey: .recordsDir)
        self.notesDir = try c.decode(URL.self, forKey: .notesDir)
        self.autoCleanOnPaste = try c.decode(Bool.self, forKey: .autoCleanOnPaste)
        self.autoTidyProseOnPaste =
            try c.decodeIfPresent(Bool.self, forKey: .autoTidyProseOnPaste) ?? false
        self.enabledTools = try c.decode(Set<Tool>.self, forKey: .enabledTools)
        self.menuBarMode =
            try c.decodeIfPresent(Bool.self, forKey: .menuBarMode) ?? false
    }
}
