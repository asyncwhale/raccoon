import Foundation

/// Adapter that reads OpenAI Codex CLI session rollout logs from `~/.codex/sessions`.
///
/// **File layout:** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`
///
/// The rollout format varies across Codex versions. This adapter is deliberately
/// defensive and tolerates three wrapper shapes per line:
///
/// - `{"timestamp":"…", "item": {…rolloutItem…}}`
/// - `{"timestamp":"…", "type":"…", "payload": {…rolloutItem…}}`
/// - Bare `{"type":"…", …}` (item fields at the top level)
///
/// Unknown/skippable item types (`TurnContext`, `event_msg`, `Compacted`, etc.)
/// are silently dropped. Blank or malformed lines are also skipped.
public struct CodexAdapter: SessionAdapter {

    public let tool: Tool = .codex

    /// `[~/.codex/sessions]`
    public var sourceRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".codex/sessions")]
    }

    public init() {}

    // MARK: - SessionAdapter

    /// Returns all `rollout-*.jsonl` files found RECURSIVELY under `root`.
    ///
    /// Codex stores sessions in `YYYY/MM/DD/` subdirectories, so a recursive
    /// enumerator is used rather than a flat directory listing.
    public func sessionFiles(in root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard
                (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                fileURL.pathExtension == "jsonl",
                fileURL.lastPathComponent.hasPrefix("rollout-")
            else { continue }
            results.append(fileURL)
        }
        return results
    }

    /// Parse one rollout `.jsonl` file's contents into a ``Record``.
    ///
    /// Lines that are blank, malformed, or represent skip-worthy types are silently
    /// dropped. Throws ``AdapterError/emptySession`` for empty/whitespace input;
    /// ``AdapterError/noMessages`` when parsing yields no conversation messages.
    public func parse(contents: String, fileURL: URL) throws -> Record {
        guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AdapterError.emptySession
        }

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

        var sessionID: String? = nil
        var project: String? = nil
        var minDate: Date? = nil
        var maxDate: Date? = nil
        var messages: [Message] = []

        let lines = contents.components(separatedBy: "\n")
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard
                let data = trimmed.data(using: .utf8),
                let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Harvest the outer timestamp (present in all shapes).
            var lineDate: Date? = nil
            if let tsString = top["timestamp"] as? String {
                lineDate = parseDate(tsString)
            }
            if let d = lineDate {
                minDate = minDate.map { min($0, d) } ?? d
                maxDate = maxDate.map { max($0, d) } ?? d
            }

            // Unwrap the actual rollout-item dict + its type discriminator.
            // Shape 1: {"timestamp":…, "item": {…}}
            // Shape 2: {"timestamp":…, "type":"…", "payload": {…}}
            // Shape 3: bare {"type":"…", …} (item fields at the top level)
            let (itemDict, itemType) = unwrapItem(top)
            guard let itemDict, let itemType else { continue }

            // Normalise to lowercase for case-insensitive matching.
            let typeLC = itemType.lowercased()

            switch typeLC {

            case "session_meta", "sessionmeta":
                if sessionID == nil, let sid = itemDict["id"] as? String {
                    sessionID = sid
                }
                if project == nil, let cwd = itemDict["cwd"] as? String {
                    let last = URL(fileURLWithPath: cwd).lastPathComponent
                    if !last.isEmpty { project = last }
                }

            case "message", "responseitem", "response_item":
                if let msg = parseMessage(itemDict, timestamp: lineDate) {
                    messages.append(msg)
                }

            default:
                // TurnContext, event_msg, Compacted, EventMsg, and any unknown types → skip.
                break
            }
        }

        guard !messages.isEmpty else {
            throw AdapterError.noMessages
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let fallbackSessionID = stem.hasPrefix("rollout-")
            ? String(stem.dropFirst("rollout-".count))
            : stem

        let epoch = Date(timeIntervalSince1970: 0)

        return Record(
            tool: .codex,
            sessionID: sessionID ?? fallbackSessionID,
            project: project,
            startedAt: minDate ?? epoch,
            lastActiveAt: maxDate ?? epoch,
            starred: false,
            messages: messages
        )
    }

    // MARK: - Private helpers

    /// Unwrap the rollout-item dict and its type discriminator from a top-level JSON object.
    ///
    /// Handles three wrapper shapes:
    /// - `"item"` key → item is `top["item"]`; type comes from `item["type"]`.
    /// - `"payload"` key + top-level `"type"` → item is `top["payload"]`;
    ///   type is `top["type"]`.
    /// - Bare dict → item IS `top`; type is `top["type"]`.
    ///
    /// Returns `(nil, nil)` when no recognisable type discriminator can be found.
    private func unwrapItem(_ top: [String: Any]) -> (itemDict: [String: Any]?, itemType: String?) {
        // Shape 1: {"timestamp":…, "item": {…}}
        if let item = top["item"] as? [String: Any] {
            let type_ = item["type"] as? String
            return (item, type_)
        }

        // Shape 2: {"timestamp":…, "type":"…", "payload": {…}}
        if let payload = top["payload"] as? [String: Any], let type_ = top["type"] as? String {
            return (payload, type_)
        }

        // Shape 3: bare {"type":"…", …field…}
        if let type_ = top["type"] as? String {
            return (top, type_)
        }

        return (nil, nil)
    }

    /// Parse a `message`/`responseItem` rollout item into a ``Message``.
    ///
    /// Follows the OpenAI Responses API shape:
    /// `{ "role": "user"|"assistant", "content": [ {"type":"input_text"|"output_text"|"text", "text":"…"}, … ] }`
    ///
    /// Also tolerates `content` being a plain string.
    /// Non-text blocks (tool calls, etc.) are silently dropped.
    private func parseMessage(_ item: [String: Any], timestamp: Date?) -> Message? {
        guard let role = item["role"] as? String else { return nil }

        let speaker: Speaker
        switch role {
        case "user":      speaker = .user
        case "assistant": speaker = .codex
        default:          return nil
        }

        guard let content = item["content"] else { return nil }

        let rawText: String
        if let plainString = content as? String {
            rawText = plainString
        } else if let array = content as? [[String: Any]] {
            let texts = array.compactMap { block -> String? in
                guard let blockType = block["type"] as? String else { return nil }
                // Accept any of: "input_text", "output_text", "text"
                let btLC = blockType.lowercased()
                guard btLC == "input_text" || btLC == "output_text" || btLC == "text" else {
                    return nil
                }
                return block["text"] as? String
            }
            guard !texts.isEmpty else { return nil }
            rawText = texts.joined(separator: "\n\n")
        } else {
            return nil
        }

        let cleaned = CleanEngine.clean(rawText).cleaned
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return Message(speaker: speaker, text: cleaned, timestamp: timestamp)
    }
}
