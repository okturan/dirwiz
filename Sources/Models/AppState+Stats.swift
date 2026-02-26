import Foundation

extension AppState {

    // MARK: - Statistics Computation

    /// Build extension statistics from the file tree.
    public func computeExtensionStats() {
        guard let tree = fileTree else { return }
        var sizeByHash: [UInt16: UInt64] = [:]
        var countByHash: [UInt16: Int] = [:]
        var sizeByExt: [String: UInt64] = [:]
        var countByExt: [String: Int] = [:]
        let colorMap = ExtensionColorMap.shared

        let snapshot = tree.nodesSnapshot()
        let totalSize = snapshot.first?.fileSize ?? 0

        for i in 0..<snapshot.count {
            let node = snapshot[i]
            guard !node.isDirectory else { continue }

            sizeByHash[node.extensionHash, default: 0] += node.fileSize
            countByHash[node.extensionHash, default: 0] += 1

            // Extract extension name for per-type stats.
            let name = tree.name(at: UInt32(i))
            let ext = Self.extractExtension(from: name)
            sizeByExt[ext, default: 0] += node.fileSize
            countByExt[ext, default: 0] += 1
        }

        // Per-hash stats (for categories legend).
        extensionStats = sizeByHash.map { hash, size in
            ExtensionStat(
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: size,
                fileCount: countByHash[hash] ?? 0,
                percentage: totalSize > 0 ? Double(size) / Double(totalSize) : 0
            )
        }
        .sorted { $0.totalSize > $1.totalSize }

        // Per-extension-name stats (for file types list).
        // Key by extensionHash (same value the scanner stores on each node) so that
        // palette lookups in the treemap and the Extensions list use the same hash.
        var sizeByExtHash: [UInt16: (name: String, size: UInt64, count: Int)] = [:]
        for (ext, size) in sizeByExt {
            let hash = extensionHash(".\(ext)")  // matches scanner: hash(part after last dot)
            if var e = sizeByExtHash[hash] {
                e.size += size
                e.count += countByExt[ext] ?? 0
                sizeByExtHash[hash] = e
            } else {
                sizeByExtHash[hash] = (name: ext, size: size, count: countByExt[ext] ?? 0)
            }
        }
        fileTypeStats = sizeByExtHash.map { hash, e in
            FileTypeStat(
                extensionName: e.name,
                extensionHash: hash,
                category: colorMap.category(forHash: hash),
                totalSize: e.size,
                fileCount: e.count,
                percentage: totalSize > 0 ? Double(e.size) / Double(totalSize) : 0
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
