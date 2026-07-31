import Foundation

/// Decides when pending ephemeral roots should be swept.
///
/// The defaults are derived from the real-volume measurement rather than chosen
/// heuristically. The Darwin temp root held 158,018 items and could be swept six
/// times per minute at the live refresh's 10-second cadence: 948,108 enumerated
/// items/minute. A 900-second interval reduces that ceiling to 0.0667 sweeps/minute
/// and 10,535 items/minute, a 98.89% reduction. Per-device journal replay at a
/// 1,800-second holdback had a 0.154315-second median (0.152232-0.385664 seconds),
/// with no poison in three repeats. The interval is half that measured safe horizon,
/// leaving one scheduled interval for a guard-delayed retry before horizon age
/// forces a sweep.
///
/// The policy is pure and clock-injected. Its caller owns scheduling, records
/// successful sweep times, and re-evaluates active guards on every opportunity.
public enum EphemeralSweepPolicy {
    public static let defaultInterval: TimeInterval = 900
    public static let defaultMaximumHorizonAge: TimeInterval = 1_800
    public static let intervalEnvironmentKey =
        "DIRWIZ_EPHEMERAL_SWEEP_INTERVAL"

    public static let noPendingReason =
        "No ephemeral changes are waiting to be swept."
    public static let intervalWaitReason =
        "Waiting for the ephemeral sweep interval."

    public enum ActiveGuard: Hashable, Sendable {
        case scan
        case heavyTask
        case temporalDiff

        public var waitReason: String {
            switch self {
            case .scan:
                return "Waiting for the current scan to finish."
            case .heavyTask:
                return "Waiting for the current disk task to finish."
            case .temporalDiff:
                return "Waiting for the temporal comparison to close."
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        case sweep
        case wait(reason: String)
    }

    public struct Input: Sendable {
        /// Completion time of the most recent successful ephemeral sweep.
        /// `nil` means no sweep has completed in this session.
        public var lastSweepAt: TimeInterval?
        public var now: TimeInterval
        public var pendingEphemeralRoots: [String]
        public var activeGuards: Set<ActiveGuard>
        /// Age of the held cache horizon. `nil` is conservatively unknown and
        /// therefore forces a sweep at the next unguarded opportunity.
        public var horizonAge: TimeInterval?
        public var navigationRequested: Bool

        public init(
            lastSweepAt: TimeInterval?,
            now: TimeInterval,
            pendingEphemeralRoots: [String],
            activeGuards: Set<ActiveGuard>,
            horizonAge: TimeInterval?,
            navigationRequested: Bool
        ) {
            self.lastSweepAt = lastSweepAt
            self.now = now
            self.pendingEphemeralRoots = pendingEphemeralRoots
            self.activeGuards = activeGuards
            self.horizonAge = horizonAge
            self.navigationRequested = navigationRequested
        }
    }

    public struct Configuration: Equatable, Sendable {
        public var interval: TimeInterval
        public var maximumHorizonAge: TimeInterval

        public init(
            interval: TimeInterval = EphemeralSweepPolicy.defaultInterval,
            maximumHorizonAge: TimeInterval =
                EphemeralSweepPolicy.defaultMaximumHorizonAge
        ) {
            self.interval = Self.validated(
                interval,
                fallback: EphemeralSweepPolicy.defaultInterval
            )
            self.maximumHorizonAge = Self.validated(
                maximumHorizonAge,
                fallback: EphemeralSweepPolicy.defaultMaximumHorizonAge
            )
        }

        /// Builds configuration from injected environment values. The policy does
        /// not read `ProcessInfo` itself, keeping environment handling deterministic
        /// in tests and leaving process ownership with the caller.
        public init(
            environment: [String: String],
            maximumHorizonAge: TimeInterval =
                EphemeralSweepPolicy.defaultMaximumHorizonAge
        ) {
            let rawValue =
                environment[EphemeralSweepPolicy.intervalEnvironmentKey]
            let parsed = rawValue.flatMap {
                TimeInterval(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            self.init(
                interval: parsed ?? EphemeralSweepPolicy.defaultInterval,
                maximumHorizonAge: maximumHorizonAge
            )
        }

        private static func validated(
            _ value: TimeInterval,
            fallback: TimeInterval
        ) -> TimeInterval {
            value.isFinite && value >= 0 ? value : fallback
        }
    }

    public static func decide(
        _ input: Input,
        configuration: Configuration = Configuration()
    ) -> Decision {
        guard !input.pendingEphemeralRoots.isEmpty else {
            return .wait(reason: noPendingReason)
        }

        // Guard priority is deterministic when several operations overlap.
        for guardKind in [
            ActiveGuard.scan,
            .heavyTask,
            .temporalDiff,
        ] where input.activeGuards.contains(guardKind) {
            return .wait(reason: guardKind.waitReason)
        }

        if input.navigationRequested {
            return .sweep
        }

        guard let horizonAge = input.horizonAge else {
            return .sweep
        }
        if horizonAge >= configuration.maximumHorizonAge {
            return .sweep
        }

        guard let lastSweepAt = input.lastSweepAt else {
            return .sweep
        }
        if input.now - lastSweepAt >= configuration.interval {
            return .sweep
        }

        return .wait(reason: intervalWaitReason)
    }
}
