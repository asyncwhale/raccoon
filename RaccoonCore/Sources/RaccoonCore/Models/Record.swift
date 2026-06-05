import Foundation

/// An archived session from a terminal AI tool.
public struct Record: Sendable, Equatable, Codable {
    public var tool: Tool
    public var sessionID: String
    public var project: String?
    public var startedAt: Date
    public var lastActiveAt: Date
    public var starred: Bool
    public var messages: [Message]

    public init(
        tool: Tool,
        sessionID: String,
        project: String?,
        startedAt: Date,
        lastActiveAt: Date,
        starred: Bool,
        messages: [Message]
    ) {
        self.tool = tool
        self.sessionID = sessionID
        self.project = project
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.starred = starred
        self.messages = messages
    }

    /// A short display title derived from the first user message.
    ///
    /// Rules:
    /// - Scans lines of the first `.user` message in order.
    /// - Skips lines that are empty or match Claude Code slash-command wrapper/caveat
    ///   patterns (e.g. `<local-command-caveat>`, `<command-name>`, `Caveat:`, …).
    ///   Only the specific known patterns are skipped — generic `<tag>` lines are kept.
    /// - Takes the first non-boilerplate, non-empty line; trims whitespace; truncates to 80 chars.
    /// - Falls back: if every line is boilerplate/empty, uses the first non-empty line.
    /// - Falls back to `"(untitled)"` when there are no user messages.
    public var title: String {
        guard let firstUser = messages.first(where: { $0.speaker == .user }) else {
            return "(untitled)"
        }
        let lines = firstUser.text.components(separatedBy: "\n")
        let candidate = lines.first(where: { !Self.isBoilerplateLine($0) && !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(80))
    }

    /// Returns `true` when a line (after trimming) should be skipped as boilerplate.
    ///
    /// Only the specific Claude Code slash-command wrapper / caveat patterns are matched.
    /// Generic `<tag>` lines (e.g. `<analysis>`) are NOT skipped.
    private static func isBoilerplateLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        // Specific wrapper/caveat tag families
        let skipPrefixes = [
            "<local-command-",
            "</local-command-",
            "<command-name>", "<command-name/>",
            "<command-message>", "<command-message/>",
            "<command-args>", "<command-args/>",
            "</command-",
            "<command-",
            "<system-reminder>",
            "</system-reminder>",
        ]
        for prefix in skipPrefixes where t.hasPrefix(prefix) {
            return true
        }
        if t.hasPrefix("Caveat:") { return true }
        if t.hasPrefix("DO NOT respond") { return true }
        return false
    }
}
