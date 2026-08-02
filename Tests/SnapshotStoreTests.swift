import Testing
import Foundation
@testable import DirWizCore

// MARK: - Pure pieces (no environment mutation, so these live at top level)

/// The LZFSE container. `TreeCache`'s fail-closed discipline applies: any doubt returns
/// nil, because a snapshot that decodes to garbage produces a confidently wrong diff.
@Suite("Snapshot Container Tests")
struct SnapshotContainerTests {

    @Test("A payload round-trips through compression unchanged")
    func roundTrip() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let container = try #require(SnapshotContainer.encode(payload: payload))
        #expect(SnapshotContainer.decode(container) == payload)
    }

    @Test("Repetitive data compresses substantially")
    func compresses() throws {
        // A real dir-map is highly repetitive (shared path prefixes, similar sizes).
        var payload = Data()
        for i in 0..<20_000 {
            payload.append(contentsOf: Array("users/okan/projects/dir\(i % 100)/sub".utf8))
            withUnsafeBytes(of: UInt64(1_000_000 + i).littleEndian) { payload.append(contentsOf: $0) }
        }
        let container = try #require(SnapshotContainer.encode(payload: payload))
        let ratio = Double(container.count) / Double(payload.count)
        print("[snapshot store] \(payload.count) B -> \(container.count) B (\(String(format: "%.1f", ratio * 100))%)")
        #expect(container.count < payload.count / 2, "LZFSE should at least halve a dir map")
    }

    @Test("Truncated, corrupt, and foreign data all decode to nil")
    func failsClosed() throws {
        let payload = Data((0..<5_000).map { UInt8($0 % 97) })
        let container = try #require(SnapshotContainer.encode(payload: payload))

        #expect(SnapshotContainer.decode(container.prefix(container.count / 2)) == nil,
                "a truncated container must not half-decode")
        #expect(SnapshotContainer.decode(Data("not a checkpoint at all".utf8)) == nil)
        #expect(SnapshotContainer.decode(Data()) == nil)

        // Wrong magic.
        var wrongMagic = container
        wrongMagic[0] = 0x00
        #expect(SnapshotContainer.decode(wrongMagic) == nil)

        // An unknown version must be refused outright, never guessed at.
        var futureVersion = container
        futureVersion[SnapshotContainer.magic.count] = 0xFE
        #expect(SnapshotContainer.decode(futureVersion) == nil)

        // As must an unknown storage mode.
        var unknownMode = container
        unknownMode[SnapshotContainer.magic.count + 1] = 0x7F
        #expect(SnapshotContainer.decode(unknownMode) == nil)
    }

    /// A corrupt length field must not be turned into a huge allocation.
    @Test("An absurd declared size is rejected rather than allocated")
    func absurdSizeRejected() throws {
        let payload = Data(repeating: 7, count: 1_000)
        var container = try #require(SnapshotContainer.encode(payload: payload))
        let sizeOffset = SnapshotContainer.magic.count + 2
        withUnsafeBytes(of: UInt64.max.littleEndian) { bytes in
            for (i, b) in bytes.enumerated() { container[sizeOffset + i] = b }
        }
        #expect(SnapshotContainer.decode(container) == nil)
    }

    @Test("An empty payload is not encodable")
    func emptyPayload() {
        #expect(SnapshotContainer.encode(payload: Data()) == nil)
    }

    /// LZFSE expands tiny and already-dense inputs, and the encode buffer then reports
    /// failure. Without a stored-uncompressed mode a small snapshot could never be written
    /// at all - this is the bug the mode byte exists to prevent.
    @Test("Tiny and incompressible payloads still round-trip")
    func incompressiblePayloadsRoundTrip() throws {
        let tiny = Data([1, 2, 3])
        let tinyContainer = try #require(SnapshotContainer.encode(payload: tiny))
        #expect(SnapshotContainer.decode(tinyContainer) == tiny)

        // High-entropy bytes: compression cannot help.
        var random = Data(count: 4_096)
        random.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = UInt8.random(in: 0...255) }
        }
        let randomContainer = try #require(SnapshotContainer.encode(payload: random))
        #expect(SnapshotContainer.decode(randomContainer) == random)
    }
}

/// Retention thinning, as a pure function over injected dates.
@Suite("Snapshot Retention Tests")
struct SnapshotRetentionTests {

    private func checkpoint(daysAgo: Double, now: Date, pinned: Bool = false,
                            bytes: UInt64 = 1_000) -> SnapshotCheckpoint {
        SnapshotCheckpoint(
            createdAt: now.addingTimeInterval(-daysAgo * 86_400),
            rootPath: "/r", totalBytes: 1, dirCount: 1,
            filename: "f\(daysAgo).dwcp", storedBytes: bytes, isPinned: pinned
        )
    }

    /// The core promise: a name means "keep this", and nothing overrules it.
    @Test("Pinned checkpoints are never evicted, at any age or budget")
    func pinnedAreNeverEvicted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ancient = checkpoint(daysAgo: 5_000, now: now, pinned: true, bytes: 10_000_000_000)
        let evicted = SnapshotRetention.evictions(from: [ancient], now: now, budgetBytes: 1)
        #expect(evicted.isEmpty,
                "retention must not delete a pin, even to get under budget")
    }

    @Test("Same-day checkpoints thin to one, newest kept")
    func dailyThinning() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = checkpoint(daysAgo: 0.1, now: now)
        let older = checkpoint(daysAgo: 0.4, now: now)
        let evicted = SnapshotRetention.evictions(from: [newer, older], now: now)
        #expect(evicted.map(\.id) == [older.id], "the newest of a bucket survives")
    }

    @Test("Distinct days inside the daily window are all kept")
    func distinctDaysKept() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (1...5).map { checkpoint(daysAgo: Double($0), now: now) }
        #expect(SnapshotRetention.evictions(from: points, now: now).isEmpty)
    }

    @Test("Beyond the last tier, checkpoints fall out entirely")
    func beyondAllTiers() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ancient = checkpoint(daysAgo: 400, now: now)
        #expect(SnapshotRetention.evictions(from: [ancient], now: now).map(\.id) == [ancient.id])
    }

    @Test("The budget evicts oldest-unpinned-first once thinning is done")
    func budgetEvictsOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Distinct days so daily thinning keeps all three; only the budget can cut them.
        let a = checkpoint(daysAgo: 1, now: now, bytes: 100)
        let b = checkpoint(daysAgo: 2, now: now, bytes: 100)
        let c = checkpoint(daysAgo: 3, now: now, bytes: 100)
        let evicted = SnapshotRetention.evictions(from: [a, b, c], now: now, budgetBytes: 250)
        #expect(evicted.map(\.id) == [c.id], "the oldest goes first")
    }

    @Test("An empty store evicts nothing")
    func emptyStore() {
        #expect(SnapshotRetention.evictions(from: [], now: Date()).isEmpty)
    }
}

// MARK: - Store (mutates DIRWIZ_APP_SUPPORT_DIR - must nest, per TestHelpers.swift)

extension AppSupportEnvSuites {

    @Suite("Snapshot Store Tests")
    struct SnapshotStoreTests {

        private func snapshot(rootPath: String = "/TestRoot", createdAt: Date = Date(),
                              byPath: [String: UInt64]) -> TemporalSnapshot {
            let meta = TemporalSnapshotMeta(
                id: UUID(), createdAt: createdAt, rootPath: rootPath,
                totalBytes: byPath.values.reduce(0, +), dirCount: byPath.count
            )
            return TemporalSnapshot(meta: meta, byPath: byPath)
        }

        @Test("A checkpoint round-trips through the store")
        func checkpointRoundTrip() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let original = snapshot(byPath: ["a": 100, "b/c": 250])

                let created = try store.createCheckpoint(from: original)
                #expect(created.storedBytes > 0)
                #expect(store.list().count == 1)

                let loaded = try store.load(created)
                #expect(loaded.pathTotals == original.pathTotals)
                #expect(loaded.meta.rootPath == "/TestRoot")
            }
        }

        /// The old store kept ONE file per volume that every save overwrote. This is the
        /// behavior change the whole task exists for.
        @Test("Multiple checkpoints accumulate instead of overwriting")
        func checkpointsAccumulate() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let base = Date(timeIntervalSince1970: 1_700_000_000)
                for day in 0..<3 {
                    _ = try store.createCheckpoint(
                        from: snapshot(createdAt: base.addingTimeInterval(Double(day) * 86_400),
                                       byPath: ["a": UInt64(100 * (day + 1))]),
                        now: base.addingTimeInterval(Double(day) * 86_400)
                    )
                }
                let all = store.list()
                #expect(all.count == 3)
                #expect(all[0].createdAt > all[1].createdAt, "newest first")
            }
        }

        @Test("Naming a checkpoint pins it")
        func namingPins() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let created = try store.createCheckpoint(
                    from: snapshot(byPath: ["a": 1]), name: "Before cleanup"
                )
                #expect(created.isPinned)
                #expect(created.name == "Before cleanup")
                #expect(store.list().first?.isPinned == true)
            }
        }

        /// The index is a cache, not the truth. Losing it must cost names and summaries,
        /// never the checkpoints themselves.
        @Test("A missing index is rebuilt from the checkpoint files")
        func indexRebuild() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                _ = try store.createCheckpoint(from: snapshot(byPath: ["a": 500]))
                #expect(store.list().count == 1)

                try FileManager.default.removeItem(
                    at: store.directory.appendingPathComponent("index.json"))

                let recovered = store.list()
                #expect(recovered.count == 1, "the checkpoint file itself is still authoritative")
                #expect(recovered[0].isPinned,
                        "recovered checkpoints are pinned - the store cannot tell which mattered")
                let reloaded = try store.load(recovered[0])
                #expect(reloaded.pathTotals == ["a": 500])
            }
        }

        @Test("A corrupt index is rebuilt rather than crashing")
        func corruptIndexRebuild() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                _ = try store.createCheckpoint(from: snapshot(byPath: ["a": 500]))

                try Data("{ not json at all".utf8).write(
                    to: store.directory.appendingPathComponent("index.json"))

                #expect(store.list().count == 1)
            }
        }

        /// An index promising a checkpoint that cannot be opened is worse than a short list.
        @Test("Index entries whose files vanished are dropped from the listing")
        func missingFileDropped() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let created = try store.createCheckpoint(from: snapshot(byPath: ["a": 1]))
                try FileManager.default.removeItem(
                    at: store.directory.appendingPathComponent(created.filename))
                #expect(store.list().isEmpty)
            }
        }

        @Test("Change summaries are computed against the predecessor")
        func changeSummary() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let base = Date(timeIntervalSince1970: 1_700_000_000)
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: base, byPath: ["keep": 100, "gone": 50]), now: base)

                let later = base.addingTimeInterval(86_400 * 2)
                let second = try store.createCheckpoint(
                    from: snapshot(createdAt: later, byPath: ["keep": 300, "new": 20]), now: later)

                let summary = try #require(second.summary)
                #expect(summary.deletedCount == 1)
                #expect(summary.deletedBytes == 50)
                #expect(summary.addedCount == 1)
                #expect(summary.topGrown.first?.path == "keep")
                #expect(summary.topGrown.first?.deltaBytes == 200)
                #expect(summary.totalDelta == 170, "150 -> 320")
            }
        }

        @Test("Retention runs on creation and spares pins")
        func retentionOnCreate() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                let base = Date(timeIntervalSince1970: 1_700_000_000)

                // Two on the same day: the older unpinned one should be thinned away.
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: base, byPath: ["a": 1]), now: base)
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: base.addingTimeInterval(60), byPath: ["a": 2]),
                    now: base.addingTimeInterval(60))

                #expect(store.list().count == 1, "same-day unpinned checkpoints thin to one")

                // A pinned one on the same day survives alongside.
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: base.addingTimeInterval(120), byPath: ["a": 3]),
                    name: "Pinned", now: base.addingTimeInterval(120))
                #expect(store.list().count == 2)
            }
        }

        @Test("The legacy single-slot snapshot imports as a pinned checkpoint")
        func legacyImport() async throws {
            try await withTemporaryAppSupportDir {
                let legacyDate = Date(timeIntervalSince1970: 1_600_000_000)
                let legacy = snapshot(createdAt: legacyDate, byPath: ["old": 4_242])
                try legacy.save()
                #expect(FileManager.default.fileExists(
                    atPath: TemporalSnapshot.snapshotURL(for: "/TestRoot").path))

                let store = SnapshotStore(rootPath: "/TestRoot")
                let imported = try #require(store.importLegacySnapshotIfPresent())

                #expect(imported.isPinned, "the user's only baseline must survive retention")
                #expect(imported.name == "Legacy snapshot")
                #expect(try store.load(imported).pathTotals == ["old": 4_242])

                // Renamed rather than deleted, so a bad migration is recoverable.
                #expect(!FileManager.default.fileExists(
                    atPath: TemporalSnapshot.snapshotURL(for: "/TestRoot").path))
                #expect(FileManager.default.fileExists(
                    atPath: TemporalSnapshot.snapshotURL(for: "/TestRoot").path + ".imported"))
            }
        }

        @Test("Import is a no-op when there is nothing to import or a store already exists")
        func legacyImportIsIdempotent() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                #expect(store.importLegacySnapshotIfPresent() == nil, "nothing to import")

                _ = try store.createCheckpoint(from: snapshot(byPath: ["a": 1]))
                try snapshot(byPath: ["old": 1]).save()
                #expect(store.importLegacySnapshotIfPresent() == nil,
                        "must never import over a live store")
            }
        }

        @Test("Stores for different volumes do not collide")
        func perVolumeIsolation() async throws {
            try await withTemporaryAppSupportDir {
                let a = SnapshotStore(rootPath: "/Volumes/A B")
                let b = SnapshotStore(rootPath: "/Volumes/A_B")
                _ = try a.createCheckpoint(from: snapshot(rootPath: "/Volumes/A B", byPath: ["x": 1]))
                #expect(a.list().count == 1)
                #expect(b.list().isEmpty, "paths differing only in separators must not share a store")
            }
        }

        @Test("Individual and combined trees at the same root use separate timelines")
        func perScopeIsolation() async throws {
            try await withTemporaryAppSupportDir {
                let root = "/TestRoot"
                let individual = SnapshotStore(rootPath: root)
                let combined = SnapshotStore(
                    rootPath: root,
                    storageIdentity: MountTraversalScope.combinedVolumes
                        .persistenceIdentity(for: root)
                )

                _ = try individual.createCheckpoint(
                    from: snapshot(rootPath: root, byPath: ["individual": 1])
                )
                _ = try combined.createCheckpoint(
                    from: snapshot(rootPath: root, byPath: ["combined": 2])
                )

                #expect(individual.directory != combined.directory)
                #expect(individual.loadLatest()?.pathTotals == ["individual": 1])
                #expect(combined.loadLatest()?.pathTotals == ["combined": 2])
            }
        }

        @Test("A scope-qualified timeline never adopts an ambiguous legacy snapshot")
        func combinedTimelineRejectsLegacyImport() async throws {
            try await withTemporaryAppSupportDir {
                let root = "/TestRoot"
                try snapshot(rootPath: root, byPath: ["legacy": 3]).save()
                let combined = SnapshotStore(
                    rootPath: root,
                    storageIdentity: MountTraversalScope.combinedVolumes
                        .persistenceIdentity(for: root)
                )

                #expect(combined.importLegacySnapshotIfPresent() == nil)
                #expect(combined.list().isEmpty)
                #expect(FileManager.default.fileExists(
                    atPath: TemporalSnapshot.snapshotURL(for: root).path
                ))
            }
        }

        @Test("Latest checkpoint is the default diff baseline")
        func loadLatest() async throws {
            try await withTemporaryAppSupportDir {
                let store = SnapshotStore(rootPath: "/TestRoot")
                #expect(store.loadLatest() == nil)

                let base = Date(timeIntervalSince1970: 1_700_000_000)
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: base, byPath: ["a": 1]), now: base)
                let newer = base.addingTimeInterval(86_400 * 3)
                _ = try store.createCheckpoint(
                    from: snapshot(createdAt: newer, byPath: ["a": 999]), now: newer)

                #expect(store.loadLatest()?.pathTotals == ["a": 999])
                #expect(store.totalStoredBytes() > 0)
            }
        }
    }
}

extension AppSupportEnvSuites {

    /// The auto-checkpoint throttle, and the GUI/CLI sharing that makes one timeline out of
    /// two front ends.
    @Suite("Auto Checkpoint Tests")
    struct AutoCheckpointTests {

        private func checkpoint(at date: Date, totalBytes: UInt64) -> SnapshotCheckpoint {
            SnapshotCheckpoint(createdAt: date, rootPath: "/r", totalBytes: totalBytes,
                               dirCount: 1, filename: "f.dwcp", storedBytes: 10)
        }

        @Test("The first scan always records a checkpoint")
        func firstScanCheckpoints() {
            #expect(AutoCheckpointPolicy.shouldCheckpoint(
                latest: nil, now: Date(), currentTotalBytes: 1_000))
        }

        @Test("Inside the interval, only a significant change records")
        func throttleInsideInterval() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let recent = checkpoint(at: now.addingTimeInterval(-3_600), totalBytes: 1_000_000)

            #expect(!AutoCheckpointPolicy.shouldCheckpoint(
                latest: recent, now: now, currentTotalBytes: 1_001_000),
                "a 0.1% change an hour later is not worth a checkpoint")

            #expect(AutoCheckpointPolicy.shouldCheckpoint(
                latest: recent, now: now, currentTotalBytes: 1_100_000),
                "a 10% change is exactly what you would want recorded")

            // Shrinking counts too - deleting 10% is as notable as adding it.
            #expect(AutoCheckpointPolicy.shouldCheckpoint(
                latest: recent, now: now, currentTotalBytes: 900_000))
        }

        @Test("Past the interval, any scan records")
        func throttleAfterInterval() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let old = checkpoint(
                at: now.addingTimeInterval(-AutoCheckpointPolicy.minimumIntervalSeconds - 1),
                totalBytes: 1_000_000)
            #expect(AutoCheckpointPolicy.shouldCheckpoint(
                latest: old, now: now, currentTotalBytes: 1_000_000))
        }

        /// A zero-byte baseline would divide by zero in the growth check.
        @Test("A zero-byte predecessor does not break the growth comparison")
        func zeroByteBaseline() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let empty = checkpoint(at: now.addingTimeInterval(-60), totalBytes: 0)
            #expect(AutoCheckpointPolicy.shouldCheckpoint(
                latest: empty, now: now, currentTotalBytes: 500))
        }

        /// GUI and CLI address the store by root path alone, so they must land on the same
        /// directory - otherwise a CLI checkpoint would be invisible in the app.
        @Test("GUI and CLI share one store per volume")
        func guiAndCliShareStore() async throws {
            try await withTemporaryAppSupportDir {
                let meta = TemporalSnapshotMeta(
                    id: UUID(), createdAt: Date(), rootPath: "/Shared",
                    totalBytes: 42, dirCount: 1
                )
                let snapshot = TemporalSnapshot(meta: meta, byPath: ["x": 42])

                let writer = SnapshotStore(rootPath: "/Shared")
                _ = try writer.createCheckpoint(from: snapshot, name: "from CLI")

                // A separately constructed store - as the other process would build it.
                let reader = SnapshotStore(rootPath: "/Shared")
                #expect(reader.directory == writer.directory)
                #expect(reader.list().count == 1)
                #expect(reader.list().first?.name == "from CLI")
                #expect(reader.loadLatest()?.pathTotals == ["x": 42])
            }
        }
    }
}

/// `--name` has to consume its value, or `snapshot /path --name foo` silently scans "foo".
@Suite("Snapshot CLI Argument Tests")
struct SnapshotCLIArgumentTests {

    @Test("--name takes a value instead of stealing the path")
    func nameConsumesItsValue() {
        let args = CLIArguments(["/Users/me/Projects", "--name", "Before cleanup"])
        #expect(args.path == "/Users/me/Projects",
                "the label must not be parsed as a second positional")
        #expect(args.string("--name") == "Before cleanup")
    }

    @Test("A missing --name is nil, not an empty string")
    func nameAbsent() {
        let args = CLIArguments(["/tmp"])
        #expect(args.string("--name") == nil)
    }

    @Test("A trailing --name with no value consumes nothing")
    func trailingName() {
        let args = CLIArguments(["/tmp", "--name"])
        #expect(args.path == "/tmp")
        #expect(args.string("--name") == nil)
    }
}

/// Sizing gate for the store: the point of compressing is that a timeline of checkpoints
/// fits in a sane budget. This measures a realistically shaped dir map.
extension AppSupportEnvSuites {
    @Suite("Snapshot Store Sizing Tests",
           .enabled(if: runHeavyBenchmarks,
                    "Heavy benchmarks run locally; CI is correctness-only"))
    struct SnapshotStoreSizingTests {

        @Test("A large directory map compresses to a workable checkpoint size")
        func realisticMapSize() async throws {
            try await withTemporaryAppSupportDir {
                // Shaped like a real volume: deep, repetitive paths and clustered sizes.
                // 120k rather than 350k: this measures the compression RATIO, which is a
                // property of the data shape and does not need the full size - and a
                // multi-hundred-MB fixture competes for cores with the wall-clock timing
                // gate in `PerformanceSensitiveSuites`. Ratio reported per-directory below.
                var byPath: [String: UInt64] = [:]
                byPath.reserveCapacity(120_000)
                for i in 0..<120_000 {
                    let a = i % 40, b = (i / 40) % 40, c = (i / 1_600) % 40
                    byPath["users/okan/library/caches/group\(a)/bundle\(b)/sub\(c)/item\(i)"] =
                        UInt64(4_096 + (i % 900_000))
                }
                let meta = TemporalSnapshotMeta(
                    id: UUID(), createdAt: Date(), rootPath: "/",
                    totalBytes: byPath.values.reduce(0, +), dirCount: byPath.count
                )
                let snapshot = TemporalSnapshot(meta: meta, byPath: byPath)

                let payload = try snapshot.encodedPayload()
                let store = SnapshotStore(rootPath: "/")
                let t0 = CFAbsoluteTimeGetCurrent()
                let created = try store.createCheckpoint(from: snapshot)
                let writeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1_000

                let ratio = Double(created.storedBytes) / Double(payload.count)
                print("[snapshot store] 120k dirs: raw \(payload.count / 1_048_576) MB -> "
                      + "\(created.storedBytes / 1_048_576) MB "
                      + "(\(String(format: "%.0f", ratio * 100))%), write \(String(format: "%.0f", writeMs))ms")

                #expect(created.storedBytes < UInt64(payload.count) / 2,
                        "compression must at least halve the map")
                // Must leave room for a real timeline inside the 500 MB default budget.
                #expect(created.storedBytes < 20 * 1_048_576)

                // And it must still decode to exactly what went in.
                let reloaded = try store.load(created)
                #expect(reloaded.pathTotals.count == byPath.count)
            }
        }
    }
}
