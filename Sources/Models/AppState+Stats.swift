import Foundation

extension AppState {

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var sizeByExt: [String: UInt64] = [:]
        var countByExt: [String: Int] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let totalSize = snapshot.first?.fileSize ?? 0

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            let name = tree.name(at: UInt32(i))
            let ext = Self.extractExtension(from: name)
            sizeByExt[ext, default: 0] += node.fileSize
            countByExt[ext, default: 0] += 1
        }

        // Per-extension-name stats keyed by string (collision-safe).
        fileTypeStats = sizeByExt.map { ext, size in
            let hash = extensionHash(".\(ext)")  // matches scanner: hash(part after last dot)
            let count = countByExt[ext] ?? 0
            return FileTypeStat(
                extensionName: ext,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: count,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Assign WinDirStat-style palette colors based on extension size ranking.
        extensionPalette.assign(from: fileTypeStats)
        loadSnapshotIfAvailable()
    }

    private static func extractExtension(from name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return "(no ext)" }
        let ext = String(name[name.index(after: dotIndex)...]).lowercased()
        return ext.isEmpty ? "(no ext)" : ext
    }
}
