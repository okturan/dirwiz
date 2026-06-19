import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// Build a temporary directory tree for testing. Returns (rootPath, cleanup).
/// Example: createTempTree(["docs/readme.txt": 100, "images/photo.jpg": 500, "empty_dir/": 0])
/// Keys ending with "/" create empty directories. Other keys create files of the given byte size.
func createTempTree(_ layout: [String: UInt64]) throws -> (path: String, cleanup: () -> Void) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DirWizTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    for (relativePath, size) in layout {
        let fullURL = tempDir.appendingPathComponent(relativePath)
        if relativePath.hasSuffix("/") {
            try FileManager.default.createDirectory(at: fullURL, withIntermediateDirectories: true)
        } else {
            let parentDir = fullURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let data = Data(count: Int(size))
            try data.write(to: fullURL)
        }
    }

    return (tempDir.path, { try? FileManager.default.removeItem(at: tempDir) })
}
