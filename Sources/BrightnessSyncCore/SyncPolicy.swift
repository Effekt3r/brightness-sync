import Foundation

/// Decides when to send the monitor a new brightness value.
///
/// A value goes out when the unrounded level has moved clearly away from the last value written (or a
/// resend was forced), but never sooner than `minimumInterval` after the previous write. That keeps
/// DDC traffic to the monitor's controller and settings memory low. Callers poll, so the latest value
/// goes out as soon as allowed.
public struct SyncPolicy: Sendable {
    public let minimumInterval: TimeInterval
    /// How far past the rounding midpoint the level must move before a new value is written, so a
    /// level hovering at x.5 doesn't flip the monitor back and forth.
    public let deadBand: Double
    public private(set) var lastWritten: Int?
    private var lastWriteTime: Date?
    private var forced = true  // the first write after start-up always goes out

    public init(minimumInterval: TimeInterval = 0.4, deadBand: Double = 0.25) {
        self.minimumInterval = minimumInterval
        self.deadBand = deadBand
    }

    /// Resend the target even if it hasn't changed (display reconnected, built-in display back, …).
    public mutating func forceResend() {
        forced = true
    }

    /// - Parameter level: the unrounded monitor value (`BrightnessMapper.level`).
    public func shouldWrite(_ level: Double, at now: Date) -> Bool {
        if let lastWriteTime, (0..<minimumInterval).contains(now.timeIntervalSince(lastWriteTime)) {
            return false  // a negative interval means the clock stepped back; don't wait for it to catch up
        }
        guard !forced, let lastWritten else { return true }
        return abs(level - Double(lastWritten)) >= 0.5 + deadBand
    }

    /// Records a successful write. Failed writes are not recorded, so the value is retried.
    public mutating func didWrite(_ value: Int, at now: Date) {
        lastWritten = value
        lastWriteTime = now
        forced = false
    }
}
