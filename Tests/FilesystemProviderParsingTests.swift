import Testing
import Foundation
@testable import DirWizCore

// MARK: - Contract tests for RealFilesystemProvider's raw buffer parsing
//
// RealFilesystemProvider walks getattrlistbulk's packed binary output with hand-rolled
// pointer arithmetic (FilesystemProvider.swift). Two pure, pointer-based helpers do the
// dangerous part — `parseEntryNameBytes` and `parseFileSizes` — with defensive guards
// against truncated entries, bad name offsets, missing NULs, and short buffers. Real scans
// only ever hand these helpers well-formed kernel output, so a wrong offset constant or a
// boundary regression would sail through CI undetected without direct tests.
//
// These tests drive the two helpers directly with crafted byte buffers. They do NOT go
// through `forEachRawDirectoryEntry`/`listDirectory`, because that requires a real, open
// file descriptor and a real getattrlistbulk call — the kernel fills the buffer itself, so
// there's no way to inject a malformed buffer through that path (a real, empty directory
// is used for the one case that doesn't need malformed bytes; see test 6b below).
//
// Byte layout of a single getattrlistbulk entry, as consumed by the two helpers under test
// (offsets mirror the `internal` constants `kOffsetName`/`kOffsetFileData` in
// FilesystemProvider.swift; the other offset constants there stay `private` since neither
// helper under test touches them):
//   [0..<24)   entryLength (UInt32) + other common attrs (returned-attrs bitmap, devID,
//              objType, modTime) — NOT read by either helper (the outer walking loop reads
//              entryLength to bound entries); left zeroed in these fixtures.
//   [24..<28)  attrreference_t.attr_dataoffset ("nameOffset", Int32 LE) — relative to
//              byte 24 (kOffsetName), i.e. absolute name position = 24 + nameOffset.
//   [28..<32)  attrreference_t.attr_length ("nameLength", UInt32 LE) — INCLUDES the
//              trailing NUL byte.
//   [32..<64)  devID/objType/modTime/fileID region — untouched by the helpers under test;
//              left zeroed.
//   [64..<72)  ATTR_FILE_ALLOCSIZE (off_t LE) — kOffsetFileData.
//   [72..<80)  ATTR_FILE_DATALENGTH (off_t LE) — kOffsetFileData + 8.
//   [24+nameOffset ..< 24+nameOffset+nameLength) name bytes, NUL-terminated.

// MARK: - Fixture helpers

/// Write a little-endian fixed-width integer into `buffer` at `offset`, overwriting
/// `MemoryLayout<T>.size` bytes that must already exist in `buffer`.
private func writeLE<T: FixedWidthInteger>(_ value: T, into buffer: inout [UInt8], at offset: Int) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { raw in
        for i in 0..<raw.count {
            buffer[offset + i] = raw[i]
        }
    }
}

/// Build a zero-filled raw entry buffer of `size` bytes with the name attrreference_t
/// (nameOffset/nameLength) written at `kOffsetName`. Everything else is left zeroed.
private func makeEntryBuffer(size: Int, nameOffset: Int32, nameLength: UInt32) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: size)
    writeLE(nameOffset, into: &buffer, at: kOffsetName)
    writeLE(nameLength, into: &buffer, at: kOffsetName + 4)
    return buffer
}

/// Write `nameBytes` at the absolute position the entry's own nameOffset declares
/// (kOffsetName + nameOffset), matching how `parseEntryNameBytes` locates them.
private func writeNameBytes(_ nameBytes: [UInt8], into buffer: inout [UInt8], nameOffset: Int32) {
    let start = kOffsetName + Int(nameOffset)
    for (i, byte) in nameBytes.enumerated() {
        buffer[start + i] = byte
    }
}

/// Call `parseEntryNameBytes` against a crafted buffer and copy the result out as a
/// `String` so callers don't have to manage the returned buffer pointer's lifetime, which
/// is only valid inside the `withUnsafeBytes` closure.
private func parsedName(from bytes: [UInt8], entryLength: Int) -> String? {
    bytes.withUnsafeBytes { raw -> String? in
        guard let base = raw.baseAddress else { return nil }
        guard let nameBuf = parseEntryNameBytes(from: base, entryLength: entryLength) else { return nil }
        return String(decoding: nameBuf, as: UTF8.self)
    }
}

/// Call `parseFileSizes` against a crafted buffer.
private func parsedFileSizes(from bytes: [UInt8]) -> (dataLength: UInt64, allocSize: UInt64) {
    bytes.withUnsafeBytes { raw -> (dataLength: UInt64, allocSize: UInt64) in
        guard let base = raw.baseAddress else { return (0, 0) }
        return parseFileSizes(from: base)
    }
}

// MARK: - Tests

@Suite("FilesystemProviderParsing Tests")
struct FilesystemProviderParsingTests {

    // MARK: 1. Valid entry

    @Test("Valid entry: name and file sizes parsed correctly")
    func validEntryParsesNameAndSizes() {
        // entryLength=89, exact fit: name "file.txt\0" (9 bytes) placed at absolute
        // offset 80 (= kOffsetName(24) + nameOffset(56)), immediately after the
        // allocSize/dataLength pair at kOffsetFileData(64)..<80.
        var buffer = makeEntryBuffer(size: 89, nameOffset: 56, nameLength: 9)
        writeLE(Int64(8192), into: &buffer, at: kOffsetFileData)       // allocSize
        writeLE(Int64(4096), into: &buffer, at: kOffsetFileData + 8)   // dataLength
        writeNameBytes(Array("file.txt".utf8) + [0], into: &buffer, nameOffset: 56)

        #expect(parsedName(from: buffer, entryLength: 89) == "file.txt")

        let sizes = parsedFileSizes(from: buffer)
        #expect(sizes.dataLength == 4096)
        #expect(sizes.allocSize == 8192)
    }

    // MARK: 2. nameLength claiming more than entryLength allows

    @Test("nameLength claiming more bytes than entryLength allows is rejected, no crash")
    func nameLengthExceedingEntryLengthIsRejected() {
        // Real backing buffer is generously sized (300 bytes, well past anything the
        // guard should ever touch) so a hypothetical guard bug would surface as a wrong
        // (non-nil) value, not a crash — the test asserts on the VALUE, not a trap.
        // nameOffset(8) is small/reasonable; nameLength(200) alone is what overshoots
        // the declared entryLength(50): 24 + 8 + 200 = 232 > 50.
        var buffer = makeEntryBuffer(size: 300, nameOffset: 8, nameLength: 200)
        writeNameBytes(Array(repeating: UInt8(ascii: "a"), count: 199) + [0], into: &buffer, nameOffset: 8)

        #expect(parsedName(from: buffer, entryLength: 50) == nil,
            "name claims 200 bytes but entryLength only allows 50 — must reject, not read past the declared entry")
    }

    // MARK: 3. nameOffset pointing outside the entry

    @Test("nameOffset placing the name outside [0, entryLength) is rejected, no crash")
    func nameOffsetOutOfRangeIsRejected() {
        // 3a: nameOffset alone (huge, forward) already exceeds entryLength regardless of
        // a tiny nameLength. Backing buffer (2048 bytes) is generous relative to the
        // computed absolute position (24 + 1500 = 1524) so a guard bug would misread
        // zeroed memory rather than crash.
        let forwardBuffer = makeEntryBuffer(size: 2048, nameOffset: 1500, nameLength: 2)
        #expect(parsedName(from: forwardBuffer, entryLength: 90) == nil,
            "nameOffset=1500 relative to kOffsetName is already past entryLength=90")

        // 3b: nameOffset negative enough that kOffsetName + nameOffset < 0, i.e. the name
        // would start before the entry itself. The guard rejects on this arithmetic alone,
        // before ever computing a pointer, so this is safe regardless of buffer size.
        let backwardBuffer = makeEntryBuffer(size: 300, nameOffset: -50, nameLength: 2)
        #expect(parsedName(from: backwardBuffer, entryLength: 90) == nil,
            "kOffsetName + nameOffset (24 - 50 = -26) is negative — must reject before computing a pointer")
    }

    // MARK: 4. Missing trailing NUL

    @Test("Name bytes without a trailing NUL are rejected")
    func missingTrailingNulIsRejected() {
        // Same shape as the valid-entry fixture (nameOffset=56, nameLength=9,
        // entryLength=89 — all bounds guards pass), but the last of the 9 declared name
        // bytes is 'X' instead of NUL, so only the trailing-NUL check should reject it.
        var buffer = makeEntryBuffer(size: 89, nameOffset: 56, nameLength: 9)
        writeNameBytes(Array("file.txtX".utf8), into: &buffer, nameOffset: 56)

        #expect(parsedName(from: buffer, entryLength: 89) == nil,
            "Last byte of the declared name span must be NUL; a non-NUL byte must reject")
    }

    // MARK: 5. Empty name (nameLength == 1)

    @Test("nameLength == 1 (name is just the NUL terminator) is rejected")
    func emptyNameIsRejected() {
        // nameLength == 1 means zero actual name characters (just the NUL). The
        // `nameLength > 1` guard must reject this before any offset arithmetic runs.
        var buffer = makeEntryBuffer(size: 100, nameOffset: 8, nameLength: 1)
        writeNameBytes([0], into: &buffer, nameOffset: 8)

        #expect(parsedName(from: buffer, entryLength: 90) == nil)
    }

    // MARK: 6. Degenerate / empty buffers

    @Test("All-zero header-only buffer parses no name and no crash")
    func zeroedHeaderOnlyBufferIsRejected() {
        // A real, fully allocated buffer that's entirely zero, as if getattrlistbulk
        // produced a degenerate entry. nameOffset/nameLength both read as 0 from zeroed
        // bytes, so `nameLength > 1` rejects immediately. parseFileSizes has no guards
        // at all (it's the caller's job to bound-check before calling), so it just
        // returns whatever bytes are there — (0, 0) for an all-zero buffer.
        let buffer = [UInt8](repeating: 0, count: 128)
        #expect(parsedName(from: buffer, entryLength: 0) == nil)

        let sizes = parsedFileSizes(from: buffer)
        #expect(sizes.dataLength == 0)
        #expect(sizes.allocSize == 0)
    }

    @Test("A genuinely empty directory yields zero entries via the public API, no crash")
    func emptyDirectoryYieldsNoEntries() throws {
        // Complements the synthetic zeroed-buffer case above with the real, end-to-end
        // contract: an actual empty directory (real fd, real getattrlistbulk call)
        // should never crash and should report zero entries via the public API.
        let (path, cleanup) = try createTempTree([:])
        defer { cleanup() }

        let entries = RealFilesystemProvider().listDirectory(path: path)
        #expect(entries != nil, "An openable, empty directory should return an empty array, not nil")
        #expect(entries?.isEmpty == true)
    }
}
