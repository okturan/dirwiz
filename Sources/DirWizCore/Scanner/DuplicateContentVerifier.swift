import Darwin
import Foundation

public struct DuplicateTrashSafetyResult: Sendable {
    public let safePaths: Set<String>
    public let unsafePaths: Set<String>

    public var isFullySafe: Bool {
        unsafePaths.isEmpty
    }

    public init(safePaths: Set<String>, unsafePaths: Set<String>) {
        self.safePaths = safePaths
        self.unsafePaths = unsafePaths
    }
}

/// Final byte-level duplicate safety checks used before exposing cleanup actions.
public enum DuplicateContentVerifier {
    private static let bufferCapacity = 128 * 1024

    /// Split paths into byte-identical groups, ignoring paths that no longer match
    /// the expected scan-time size.
    public static func exactGroups(paths: [String], expectedSize: UInt64) -> [[String]] {
        var groups: [[String]] = []

        for path in paths.sorted() {
            guard fileSizeMatches(path, expectedSize: expectedSize) else { continue }

            var didPlace = false
            for index in groups.indices {
                guard let representative = groups[index].first else { continue }
                if areByteIdentical(path, representative, expectedSize: expectedSize) {
                    groups[index].append(path)
                    didPlace = true
                    break
                }
            }

            if !didPlace {
                groups.append([path])
            }
        }

        return groups.filter { $0.count >= 2 }
    }

    /// Return which selected paths still have at least one unselected,
    /// byte-identical copy in the current filesystem state.
    public static func trashSafety(
        for group: DuplicateGroup,
        selectedPaths: Set<String>
    ) -> DuplicateTrashSafetyResult {
        let selectedInGroup = Set(group.paths.filter { selectedPaths.contains($0) })
        guard !selectedInGroup.isEmpty else {
            return DuplicateTrashSafetyResult(safePaths: [], unsafePaths: [])
        }

        let currentExactGroups = exactGroups(paths: group.paths, expectedSize: group.fileSize)
        var safePaths: Set<String> = []

        for exactGroup in currentExactGroups {
            let exactSet = Set(exactGroup)
            let selectedExactPaths = exactSet.intersection(selectedInGroup)
            guard !selectedExactPaths.isEmpty else { continue }

            let unselectedExactPaths = exactSet.subtracting(selectedInGroup)
            if !unselectedExactPaths.isEmpty {
                safePaths.formUnion(selectedExactPaths)
            }
        }

        return DuplicateTrashSafetyResult(
            safePaths: safePaths,
            unsafePaths: selectedInGroup.subtracting(safePaths)
        )
    }

    public static func areByteIdentical(
        _ lhsPath: String,
        _ rhsPath: String,
        expectedSize: UInt64
    ) -> Bool {
        guard fileSizeMatches(lhsPath, expectedSize: expectedSize),
              fileSizeMatches(rhsPath, expectedSize: expectedSize) else {
            return false
        }
        if lhsPath == rhsPath { return true }
        if expectedSize == 0 { return true }

        let lhsFD = lhsPath.withCString { open($0, O_RDONLY) }
        guard lhsFD >= 0 else { return false }
        defer { close(lhsFD) }

        let rhsFD = rhsPath.withCString { open($0, O_RDONLY) }
        guard rhsFD >= 0 else { return false }
        defer { close(rhsFD) }

        let lhsBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferCapacity, alignment: 8)
        let rhsBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferCapacity, alignment: 8)
        defer {
            lhsBuffer.deallocate()
            rhsBuffer.deallocate()
        }

        var remaining = expectedSize
        while remaining > 0 {
            let toRead = Int(min(UInt64(bufferCapacity), remaining))
            guard readExact(lhsFD, lhsBuffer, toRead),
                  readExact(rhsFD, rhsBuffer, toRead) else {
                return false
            }
            guard memcmp(lhsBuffer, rhsBuffer, toRead) == 0 else {
                return false
            }
            remaining -= UInt64(toRead)
        }

        return true
    }

    private static func fileSizeMatches(_ path: String, expectedSize: UInt64) -> Bool {
        let fd = path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else { return false }
        return UInt64(bitPattern: Int64(fileInfo.st_size)) == expectedSize
    }

    private static func readExact(_ fd: Int32, _ dst: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var ptr = dst
        var remaining = count
        while remaining > 0 {
            let n = read(fd, ptr, remaining)
            if n == -1 && errno == EINTR { continue }
            guard n > 0 else { return false }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
        return true
    }
}
