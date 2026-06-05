import Foundation

/// Persisted metadata for a single source session file, used to detect changes between sync passes.
///
/// Keyed by the source file's standardized absolute path in the `SyncEngine` state dictionary.
/// Both `size` and `mtimeEpoch` must match for a file to be considered unchanged.
/// A `byteOffset` field is reserved for a future incremental-read optimisation but is unused in v1.
public struct FileSyncState: Codable, Sendable, Equatable {
    /// The file size in bytes at the time of the last successful parse.
    public var size: Int

    /// The file's modification time as a Unix epoch `Double`, at the time of the last parse.
    public var mtimeEpoch: Double

    /// Reserved for a future byte-offset incremental read optimisation (unused in v1).
    public var byteOffset: Int

    public init(size: Int, mtimeEpoch: Double, byteOffset: Int = 0) {
        self.size = size
        self.mtimeEpoch = mtimeEpoch
        self.byteOffset = byteOffset
    }
}
