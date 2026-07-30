/// Decides whether a warm patch may persist the FSEvents horizon it just replayed.
///
/// A `nil` result means "do not write the cache yet". The existing on-disk cache then
/// remains an atomic, self-consistent checkpoint whose event id is no newer than its
/// tree. Once no deferred targets remain, the replay horizon is safe to persist.
public enum WarmPatchCacheHorizon {
    public static func eventIdForPersistence(
        replayedThrough eventId: UInt64,
        deferredTargetCount: Int
    ) -> UInt64? {
        guard deferredTargetCount == 0 else { return nil }
        return eventId
    }
}
