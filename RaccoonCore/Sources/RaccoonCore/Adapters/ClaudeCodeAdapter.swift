import Foundation

/// Adapter that reads Claude Code's on-disk session logs from `~/.claude/projects`.
///
/// **File layout:** `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`
///
/// UUID-named *directories* (which hold `subagents/`) and any path containing
/// `/subagents/` are excluded — those are not main sessions.
public struct ClaudeCodeAdapter: SessionAdapter {

    public let tool: Tool = .claudeCode

    /// `[~/.claude/projects]`
    public var sourceRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects")]
    }

    public init() {}

    // MARK: - SessionAdapter

    /// Returns all depth-1 `*.jsonl` files directly inside each `<cwd-slug>` subdirectory
    /// of `root`, excluding any path that contains `/subagents/`.
    public func sessionFiles(in root: URL, fileManager: FileManager) -> [URL] {
        // Enumerate immediate children of root (the <cwd-slug> dirs).
        guard let slugDirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for slugDir in slugDirs {
            // Skip files at the root level — we only want directories.
            guard (try? slugDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            // Enumerate the direct children of each slug dir.
            guard let children = try? fileManager.contentsOfDirectory(
                at: slugDir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                // Must be a regular .jsonl file (not a uuid-named directory).
                guard child.pathExtension == "jsonl",
                      (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }

                // Exclude anything under a subagents/ path component.
                guard !child.path.contains("/subagents/") else { continue }

                results.append(child)
            }
        }
        return results
    }

    /// Parse one `.jsonl` file's contents into a ``Record``.
    ///
    /// Lines that are blank, malformed, or represent unknown types are skipped silently.
    /// Throws ``AdapterError/emptySession`` for empty input;
    /// ``AdapterError/noMessages`` when parsing yields no conversation messages.
    public func parse(contents: String, fileURL: URL) throws -> Record {
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AdapterError.emptySession
        }

        // ISO-8601 formatters — try fractional seconds first, fall back to whole seconds.
        let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let isoWhole: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parseDate(_ string: String) -> Date? {
            isoFractional.date(from: string) ?? isoWhole.date(from: string)
        }

        // Metadata collected from any line.
        var sessionID: String? = nil
        var project: String? = nil
        var minDate: Date? = nil
        var maxDate: Date? = nil
        var messages: [Message] = []

        let lines = contents.components(separatedBy: "\n")
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Attempt to parse as a JSON object; silently skip malformed lines.
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Harvest top-level metadata fields from every line.
            if sessionID == nil, let sid = obj["sessionId"] as? String {
                sessionID = sid
            }
            if project == nil, let cwd = obj["cwd"] as? String {
                project = URL(fileURLWithPath: cwd).lastPathComponent
                if project?.isEmpty == true { project = nil }
            }

            var lineDate: Date? = nil
            if let tsString = obj["timestamp"] as? String {
                lineDate = parseDate(tsString)
            }
            if let d = lineDate {
                minDate = minDate.map { min($0, d) } ?? d
                maxDate = maxDate.map { max($0, d) } ?? d
            }

            // Only process known conversational types.
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "user":
                if let msg = parseUserLine(obj, timestamp: lineDate) {
                    messages.append(msg)
                }
            case "assistant":
                if let msg = parseAssistantLine(obj, timestamp: lineDate) {
                    messages.append(msg)
                }
            default:
                // permission-mode, attachment, file-history-snapshot, last-prompt,
                // system, and any unknown types are skipped.
                break
            }
        }

        guard !messages.isEmpty else {
            throw AdapterError.noMessages
        }

        let fallbackSessionID = fileURL.deletingPathExtension().lastPathComponent
        let epoch = Date(timeIntervalSince1970: 0)

        return Record(
            tool: .claudeCode,
            sessionID: sessionID ?? fallbackSessionID,
            project: project,
            startedAt: minDate ?? epoch,
            lastActiveAt: maxDate ?? epoch,
            starred: false,
            messages: messages
        )
    }

    // MARK: - Private helpers

    /// Parse a `type == "user"` line.
    ///
    /// - String content → single user message.
    /// - Array content → extract `{type:"text"}` blocks; skip `tool_result` blocks entirely.
    private func parseUserLine(_ obj: [String: Any], timestamp: Date?) -> Message? {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"]
        else { return nil }

        if let text = content as? String {
            let cleaned = CleanEngine.clean(text).cleaned
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Message(speaker: .user, text: cleaned, timestamp: timestamp)
        }

        if let array = content as? [[String: Any]] {
            let texts = array.compactMap { block -> String? in
                guard let blockType = block["type"] as? String,
                      blockType == "text",
                      let text = block["text"] as? String
                else { return nil }
                return text
            }
            guard !texts.isEmpty else { return nil }
            let joined = texts.joined(separator: "\n\n")
            let cleaned = CleanEngine.clean(joined).cleaned
            guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Message(speaker: .user, text: cleaned, timestamp: timestamp)
        }

        return nil
    }

    /// Parse a `type == "assistant"` line.
    ///
    /// Content is an array of blocks. Concatenate `{type:"text"}` blocks (joined by "\n\n").
    /// Skip `thinking` and `tool_use` blocks. Return `nil` if no text blocks exist.
    private func parseAssistantLine(_ obj: [String: Any], timestamp: Date?) -> Message? {
        guard let message = obj["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]]
        else { return nil }

        let texts = contentArray.compactMap { block -> String? in
            guard let blockType = block["type"] as? String,
                  blockType == "text",
                  let text = block["text"] as? String
            else { return nil }
            return text
        }
        guard !texts.isEmpty else { return nil }

        let joined = texts.joined(separator: "\n\n")
        let cleaned = CleanEngine.clean(joined).cleaned
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Message(speaker: .claudeCode, text: cleaned, timestamp: timestamp)
    }
}
