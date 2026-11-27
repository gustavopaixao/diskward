import Foundation

/// Decides when to warn about low disk space without nagging.
public struct LowSpacePolicy: Sendable {
    public var threshold: Int64
    /// Don't repeat the same warning more often than this...
    public var repeatInterval: TimeInterval
    /// ...unless free space dropped by at least this fraction since the last warning.
    public var dropFactor: Double

    public init(threshold: Int64, repeatInterval: TimeInterval = 6 * 3600, dropFactor: Double = 0.25) {
        self.threshold = threshold
        self.repeatInterval = repeatInterval
        self.dropFactor = dropFactor
    }

    public func shouldAlert(free: Int64, lastAlert: Date?, lastAlertFree: Int64?, now: Date = Date()) -> Bool {
        guard free < threshold else { return false }
        guard let lastAlert, let lastAlertFree else { return true }
        if now.timeIntervalSince(lastAlert) >= repeatInterval { return true }
        return Double(free) <= Double(lastAlertFree) * (1 - dropFactor)
    }
}
