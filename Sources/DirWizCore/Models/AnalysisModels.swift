import Foundation

/// Per-extension-name stat for the file types list.
public struct FileTypeStat: Identifiable, Sendable {
    public let id = UUID()
    public let extensionName: String
    public let extensionHash: UInt32
    public let category: FileCategory
    public let totalSize: UInt64
    public let fileCount: Int
    public let percentage: Double

    public init(
        extensionName: String,
        extensionHash: UInt32,
        category: FileCategory,
        totalSize: UInt64,
        fileCount: Int,
        percentage: Double
    ) {
        self.extensionName = extensionName
        self.extensionHash = extensionHash
        self.category = category
        self.totalSize = totalSize
        self.fileCount = fileCount
        self.percentage = percentage
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id = UUID()
    public let fileSize: UInt64
    public let hash: UInt64
    public let paths: [String]

    public init(fileSize: UInt64, hash: UInt64, paths: [String]) {
        self.fileSize = fileSize
        self.hash = hash
        self.paths = paths
    }

    public var wastedSpace: UInt64 {
        fileSize * UInt64(max(0, paths.count - 1))
    }
}
