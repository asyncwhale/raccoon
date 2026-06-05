import Foundation

/// A lightweight snapshot of a ``Record`` that carries only the fields needed to
/// render a sidebar row: path, tool, sessionID, project, dates, starred, and title.
///
/// Unlike ``Record``, a `RecordSummary` does **not** retain message bodies, so
/// holding a large collection of them in RAM is cheap.
public struct RecordSummary: Sendable, Identifiable, Equatable {
    /// A stable identity derived from the on-disk path. Unique per archived session.
    public var id: String { path.path }

    /// Absolute URL of the `.md` archive file.
    public let path: URL
    public let tool: Tool
    public let sessionID: String
    public let project: String?
    public let startedAt: Date
    public let lastActiveAt: Date
    public let starred: Bool
    public let title: String

    public init(
        path: URL,
        tool: Tool,
        sessionID: String,
        project: String?,
        startedAt: Date,
        lastActiveAt: Date,
        starred: Bool,
        title: String
    ) {
        self.path = path
        self.tool = tool
        self.sessionID = sessionID
        self.project = project
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.starred = starred
        self.title = title
    }
}
