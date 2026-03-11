import Foundation

extension AppState {

    private struct ExtensionAccumulator {
        var totalSize: UInt64 = 0
        var fileCount: Int = 0
    }

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var statsByExt: [String: ExtensionAccumulator] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let stringPool = tree.stringPoolSnapshot()
        let totalSize = snapshot.first?.displaySize ?? 0

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            let ext = Self.extractExtension(from: node, stringPool: stringPool)
            var stats = statsByExt[ext, default: ExtensionAccumulator()]
            stats.totalSize += node.displaySize
            stats.fileCount += 1
            statsByExt[ext] = stats
        }

        // Per-extension-name stats keyed by string (collision-safe).
        fileTypeStats = statsByExt.map { ext, stats in
            let hash = ext.isEmpty ? UInt32(0) : extensionHash(".\(ext)")
            return FileTypeStat(
                extensionName: ext,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: stats.totalSize,
                fileCount: stats.fileCount,
                percentage: totalSize > 0 ? Double(stats.totalSize) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Assign WinDirStat-style palette colors based on extension size ranking.
        extensionPalette.assign(from: fileTypeStats)
        loadSnapshotIfAvailable()
    }

    private static func extractExtension(from node: FileNode, stringPool: Data) -> String {
        let start = Int(node.nameOffset)
        let end = start + Int(node.nameLength)
        guard end <= stringPool.count else { return "" }
        let nameBytes = stringPool[start..<end]
        guard let dotIndex = nameBytes.lastIndex(of: UInt8(ascii: ".")) else { return "" }
        let extStart = nameBytes.index(after: dotIndex)
        let extData = Data(nameBytes[extStart..<nameBytes.endIndex])
        return (String(data: extData, encoding: .utf8) ?? "").lowercased()
    }
}
