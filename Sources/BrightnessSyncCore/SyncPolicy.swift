import Foundation

/// Decides when to send the monitor a new brightness value.
///
/// A value goes out when it differs from the last one written (or a resend was forced), but never
/// sooner than `minimumInterval` after the previous write. That keeps DDC traffic to the monitor's
/// controller and settings memory low. Callers poll, so the latest value goes out as soon as allowed.
public struct SyncPolicy: Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var lastWritten: Int?
    private var lastWriteTime: Date?
    private var forced = true  // the first write after start-up always goes out

    public init(minimumInterval: TimeInterval = 0.4) {
        self.minimumInterval = minimumInterval
    }

    /// Resend the target even if it hasn't changed (display reconnected, built-in display back, …).
    public mutating func forceResend() {
        forced = true
    }

    public func shouldWrite(_ target: Int, at now: Date) -> Bool {
        if let lastWriteTime, now.timeIntervalSince(lastWriteTime) < minimumInterval {
            return false
        }
        return forced || target != lastWritten
    }

    /// Records a successful write. Failed writes are not recorded, so the value is retried.
    public mutating func didWrite(_ value: Int, at now: Date) {
        lastWritten = value
        lastWriteTime = now
        forced = false
    }
}
