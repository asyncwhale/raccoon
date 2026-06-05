/// Identifies who produced a message in a recorded session.
public enum Speaker: String, Sendable, Codable, CaseIterable {
    case user
    case claudeCode
    case codex
    case gemini
    case cursor
    case system

    /// Human-readable display label shown in transcripts and the UI.
    public var label: String {
        switch self {
        case .user:       "User"
        case .claudeCode: "Claude Code"
        case .codex:      "Codex"
        case .gemini:     "Gemini"
        case .cursor:     "Cursor"
        case .system:     "System"
        }
    }
}
