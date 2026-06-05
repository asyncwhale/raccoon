import Foundation

/// Errors that adapters may throw during session parsing.
public enum AdapterError: Error, Sendable, Equatable {
    /// The file was unreadable or contained no data.
    case emptySession
    /// The file parsed successfully but yielded zero conversation messages.
    case noMessages
}

/// A source-specific strategy for locating and parsing session files into ``Record``s.
///
/// Conform to this protocol once per terminal AI tool. Implementations must be `Sendable`
/// so they can safely be used across actor boundaries.
public protocol SessionAdapter: Sendable {
    /// The tool this adapter handles.
    var tool: Tool { get }

    /// Root directories this adapter scans for session files (e.g. `~/.claude/projects`).
    var sourceRoots: [URL] { get }

    /// All session files for this tool found directly under `root`.
    ///
    /// - Parameters:
    ///   - root: One of the directories returned by ``sourceRoots``.
    ///   - fileManager: A `FileManager` instance — injected for testability.
    /// - Returns: URLs of parseable session files; empty if none found.
    func sessionFiles(in root: URL, fileManager: FileManager) -> [URL]

    /// Parse one session file's full text content into a ``Record``.
    ///
    /// - Parameters:
    ///   - contents: The full UTF-8 string contents of the session file.
    ///   - fileURL: The URL of the file, used for fallback metadata.
    /// - Throws: ``AdapterError/emptySession`` if `contents` is empty or unreadable;
    ///   ``AdapterError/noMessages`` if parsing succeeds but no messages are produced.
    func parse(contents: String, fileURL: URL) throws -> Record
}
