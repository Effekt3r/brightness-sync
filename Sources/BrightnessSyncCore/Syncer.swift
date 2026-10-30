import Foundation

/// Where the built-in display's brightness comes from.
public protocol BrightnessSource {
    /// Brightness 0…1, or nil while the display is unavailable (lid closed, asleep).
    func brightness() -> Double?
}

/// The external monitor being driven.
public protocol MonitorLink: AnyObject {
    var isConnected: Bool { get }
    /// Looks for external displays and connects to the first one. Returns how many were found.
    func connect() -> Int
    func disconnect()
    /// Returns false if the monitor did not accept the write.
    func setBrightness(_ value: Int) -> Bool
    /// The monitor's current brightness, for diagnostics.
    func readBrightness() -> DDC.Reply?
}

/// The sync loop's logic, one step per `tick`: follow the built-in brightness, write it to the monitor
/// when `SyncPolicy` allows, and recover from display changes and failed writes.
public final class Syncer {
    public static let tickInterval: TimeInterval = 0.25
    public static let rediscoveryInterval: TimeInterval = 5

    private let source: any BrightnessSource
    private let monitor: any MonitorLink
    private let mapper: BrightnessMapper
    private let verbose: Bool
    private let log: (String) -> Void

    private var policy = SyncPolicy()
    private var displays: Set<UInt32>?
    private var sourceAvailable = true
    private var lastDiscovery: Date?
    private var lastNotes: [String: String] = [:]

    public init(source: any BrightnessSource, monitor: any MonitorLink, mapper: BrightnessMapper,
                verbose: Bool = false, log: @escaping (String) -> Void) {
        self.source = source
        self.monitor = monitor
        self.mapper = mapper
        self.verbose = verbose
        self.log = log
    }

    public func tick(onlineDisplays: Set<UInt32>, now: Date) {
        if displays != onlineDisplays {
            if displays != nil { log("display configuration changed") }
            displays = onlineDisplays
            monitor.disconnect()
            lastDiscovery = nil
            policy.forceResend()
            for topic in ["monitor", "monitor-count", "write"] { lastNotes[topic] = nil }  // log the reconnection
        }

        guard let brightness = source.brightness() else {
            note("built-in", "built-in display unavailable (lid closed, asleep, or brightness unreadable); waiting")
            sourceAvailable = false
            return
        }
        if !sourceAvailable {
            sourceAvailable = true
            policy.forceResend()
        }
        note("built-in", "built-in display available")

        let target = mapper.map(brightness)
        guard policy.shouldWrite(target, at: now), connectIfNeeded(now: now) else { return }

        if monitor.setBrightness(target) {
            policy.didWrite(target, at: now)
            note("write", "writing brightness to the external display")
            if verbose { log("built-in \(String(format: "%.4f", brightness)) → monitor \(target)") }
        } else {
            note("write", "DDC write failed; reconnecting")
            monitor.disconnect()
            policy.forceResend()  // the failed value may have reached the panel anyway
        }
    }

    private func connectIfNeeded(now: Date) -> Bool {
        if monitor.isConnected { return true }
        if let lastDiscovery, (0..<Self.rediscoveryInterval).contains(now.timeIntervalSince(lastDiscovery)) {
            return false  // as in SyncPolicy, a clock that stepped back doesn't hold rediscovery up
        }
        lastDiscovery = now

        let found = monitor.connect()
        guard found > 0 else {
            note("monitor", "no external display found")
            return false
        }
        if found > 1 { note("monitor-count", "warning: \(found) external displays found; using the first") }
        let reading = monitor.readBrightness().map { "brightness \($0.current)/\($0.maximum)" } ?? "brightness read failed"
        note("monitor", "external display connected (\(reading))")
        return true
    }

    /// Logs `message` unless it repeats the previous message on the same topic.
    private func note(_ topic: String, _ message: String) {
        guard lastNotes[topic] != message else { return }
        lastNotes[topic] = message
        log(message)
    }
}
