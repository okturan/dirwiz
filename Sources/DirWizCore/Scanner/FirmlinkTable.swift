import Foundation

/// macOS firmlinks make the Data volume's directories appear at the system root:
/// `/Applications` and `/System/Volumes/Data/Applications` are the same bytes.
///
/// `FileScanner`'s `(dev, inode)` visited-set cannot deduplicate them, because the two
/// sides report DIFFERENT identities. `stat /Applications` resolves to the real inode
/// (e.g. `283981561`), but the directory entry `getattrlistbulk` returns while enumerating
/// `/` carries a synthetic firmlink id (e.g. `1152921500311879701`, `0x0FFFFFFF00000015`).
/// They never compare equal, so both subtrees get enumerated - measured on a real 4.45M-item
/// scan as `/Applications` 48.4 GB *and* `/System/Volumes/Data/Applications` 47.4 GB both
/// counted, while `/Library` came back empty with its real 92.6 GB stranded under the Data
/// path. Which side "wins" depends on which worker claims the inode first, so it varies
/// between runs of the same scan. `dev` is identical on both sides, so a `du -x`-style
/// mount-crossing rule can't distinguish them either.
///
/// macOS publishes the mapping in `/usr/share/firmlinks`, so this needs no inode-range
/// heuristic: parse the table and skip the Data-side copy, keeping the `/`-side path users
/// recognise.
///
/// FAILS OPEN: a missing, unreadable, or malformed table yields an empty skip set and
/// exactly the previous traversal behavior. Losing data is never an acceptable outcome of
/// a deduplication optimisation.
public enum FirmlinkTable {
    public static let defaultTablePath = "/usr/share/firmlinks"
    public static let defaultDataVolumeRoot = "/System/Volumes/Data"

    /// Set to `1` to restore pre-deduplication traversal without a rebuild.
    public static let killSwitchEnv = "DIRWIZ_NO_FIRMLINK_DEDUP"

    /// Absolute Data-volume paths whose content is already reachable through a firmlink,
    /// and can therefore be skipped when both sides fall inside the same scan.
    ///
    /// `systemSideExists` gates each entry: a target is only skipped when its `/`-side path
    /// is actually present. Otherwise skipping the Data copy would drop the content from
    /// both sides and under-report - worse than the double count being fixed.
    public static func duplicateDataPaths(
        contents: String?,
        dataVolumeRoot: String = defaultDataVolumeRoot,
        systemSideExists: (String) -> Bool
    ) -> Set<String> {
        guard let contents else { return [] }
        var result: Set<String> = []
        // `split(separator: "\n")` is WRONG here: Swift treats CRLF as a single grapheme
        // cluster, so a "\r\n"-terminated file never splits at those line ends and the
        // second field silently swallows the following line. `isNewline` matches the CRLF
        // grapheme itself, so it splits correctly regardless of line ending.
        for rawLine in contents.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }  // malformed row: ignore, don't guess
            let systemSide = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let dataRelative = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard systemSide.hasPrefix("/"), !dataRelative.isEmpty else { continue }
            guard systemSideExists(systemSide) else { continue }
            result.insert(normalizedJoin(dataVolumeRoot, dataRelative))
        }
        return result
    }

    /// Reads the live table from disk. Any failure returns nil, which callers treat as
    /// "no deduplication" rather than an error.
    public static func loadSystemTable(
        tablePath: String = defaultTablePath,
        dataVolumeRoot: String = defaultDataVolumeRoot,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        guard environment[killSwitchEnv] != "1" else { return [] }
        let contents = try? String(contentsOfFile: tablePath, encoding: .utf8)
        return duplicateDataPaths(
            contents: contents,
            dataVolumeRoot: dataVolumeRoot,
            systemSideExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Deduplication only applies when the scan actually covers both sides. A scan rooted
    /// AT the Data volume (or anywhere below it) must enumerate everything - skipping there
    /// would hide content the user explicitly asked to see.
    public static func isActive(forScanRoot scanRoot: String, dataVolumeRoot: String = defaultDataVolumeRoot) -> Bool {
        guard let components = FileScanner.relativeComponents(of: dataVolumeRoot, rootPath: scanRoot) else {
            return false          // Data volume is outside this scan entirely
        }
        return !components.isEmpty // empty == scan root IS the Data volume: never skip
    }

    private static func normalizedJoin(_ root: String, _ relative: String) -> String {
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let trimmedRelative = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return trimmedRoot + "/" + trimmedRelative
    }
}
