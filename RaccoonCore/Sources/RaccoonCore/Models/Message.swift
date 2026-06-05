import Foundation

/// A single turn within a recorded session transcript.
public struct Message: Sendable, Equatable, Codable {
    public var speaker: Speaker
    public var text: String
    public var timestamp: Date?

    public init(speaker: Speaker, text: String, timestamp: Date?) {
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}
