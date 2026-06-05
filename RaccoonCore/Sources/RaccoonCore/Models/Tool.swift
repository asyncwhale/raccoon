/// Represents a terminal AI tool whose sessions Raccoon can archive.
public enum Tool: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case gemini
    case cursor

    /// Human-readable display label shown in the UI.
    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .gemini:     "Gemini"
        case .cursor:     "Cursor"
        }
    }
}
