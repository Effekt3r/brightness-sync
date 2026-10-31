import Foundation
import Testing
@testable import BrightnessSyncCore

final class FakeSource: BrightnessSource {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    func brightness() -> Double? { value }
}

final class FakeMonitor: MonitorLink {
    var displaysFound = 1
    var acceptsWrites = true
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var writes: [Int] = []

    func connect() -> Int {
        connectCount += 1
        isConnected = displaysFound > 0
        return displaysFound
    }

    func disconnect() { isConnected = false }

    func setBrightness(_ value: Int) -> Bool {
        writes.append(value)
        return acceptsWrites
    }

    var reading: DDC.Reply? = DDC.Reply(current: 100, maximum: 100)
    func readBrightness() -> DDC.Reply? { reading }
}

final class FakeDimmer: PictureDimmer {
    private(set) var levels: [Double] = []
    func setPictureLevel(_ level: Double) -> Bool {
        levels.append(level)
        return true
    }
}

final class LogRecorder {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}

struct SyncerTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let bothDisplays: Set<UInt32> = [1, 4]
    let builtInOnly: Set<UInt32> = [1]

    func makeSyncer(_ source: FakeSource, _ monitor: FakeMonitor, _ log: LogRecorder = LogRecorder(),
                    dimmer: FakeDimmer = FakeDimmer()) -> Syncer {
        Syncer(source: source, monitor: monitor, dimmer: dimmer, mapper: BrightnessMapper(dimBelow: 0.2), log: log.record)
    }

    @Test func picturesAboveTheThresholdAreLeftAlone() {
        let dimmer = FakeDimmer()
        let syncer = makeSyncer(FakeSource(0.5), FakeMonitor(), dimmer: dimmer)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        #expect(dimmer.levels.isEmpty)
    }

    @Test func pictureIsDimmedBelowTheThresholdAndRestoredAboveIt() {
        let source = FakeSource(0.1)
        let dimmer = FakeDimmer()
        let syncer = makeSyncer(source, FakeMonitor(), dimmer: dimmer)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        source.value = 0.5
        syncer.tick(onlineDisplays: bothDisplays, now: start + 0.25)
        #expect(dimmer.levels == [0.5, 1])
    }

    @Test func dimmingIsReappliedPeriodicallyInCaseMacOSResetsIt() {
        let dimmer = FakeDimmer()
        let syncer = makeSyncer(FakeSource(0.1), FakeMonitor(), dimmer: dimmer)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        syncer.tick(onlineDisplays: bothDisplays, now: start + 1)
        syncer.tick(onlineDisplays: bothDisplays, now: start + Syncer.pictureRefreshInterval)
        #expect(dimmer.levels == [0.5, 0.5])
    }

    @Test func pictureIsRestoredWhileTheBuiltInDisplayIsUnavailable() {
        let source = FakeSource(0.1)
        let dimmer = FakeDimmer()
        let syncer = makeSyncer(source, FakeMonitor(), dimmer: dimmer)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        source.value = nil  // lid closed: the monitor's picture must not stay dimmed
        syncer.tick(onlineDisplays: [4], now: start + 1)
        #expect(dimmer.levels == [0.5, 1])
    }

    @Test func firstTickConnectsAndWritesTheMappedValue() {
        let monitor = FakeMonitor()
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        #expect(monitor.writes == [50])
        #expect(log.lines.contains("external display connected (brightness 100/100)"))
    }

    @Test func unchangedBrightnessIsNotRewritten() {
        let monitor = FakeMonitor()
        let syncer = makeSyncer(FakeSource(0.5), monitor)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        syncer.tick(onlineDisplays: bothDisplays, now: start + 1)
        #expect(monitor.writes == [50])
    }

    @Test func followsChangesAtMostEveryMinimumInterval() {
        let source = FakeSource(0.5)
        let monitor = FakeMonitor()
        let syncer = makeSyncer(source, monitor)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        source.value = 0.6
        syncer.tick(onlineDisplays: bothDisplays, now: start + 0.25)
        #expect(monitor.writes == [50])
        source.value = 0.7
        syncer.tick(onlineDisplays: bothDisplays, now: start + 0.5)
        #expect(monitor.writes == [50, 70])
    }

    @Test func brightnessResetAfterWakeIsCorrected() {
        let source = FakeSource(0.06)
        let monitor = FakeMonitor()
        let log = LogRecorder()
        let syncer = makeSyncer(source, monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)       // writes 6
        monitor.reading = DDC.Reply(current: 6, maximum: 100)
        source.value = nil
        syncer.tick(onlineDisplays: bothDisplays, now: start + 10)  // displays asleep
        source.value = 0.06
        syncer.tick(onlineDisplays: bothDisplays, now: start + 20)  // awake: forced resend of 6
        syncer.tick(onlineDisplays: bothDisplays, now: start + 22)  // check: still 6
        monitor.reading = DDC.Reply(current: 100, maximum: 100)     // reset by the monitor or macOS
        syncer.tick(onlineDisplays: bothDisplays, now: start + 25)  // check: 100, so resend
        #expect(monitor.writes == [6, 6, 6])
        #expect(log.lines.contains("external display drifted to 100 (expected 6); resending"))
    }

    @Test func driftCorrectionIsBoundedPerEvent() {
        let monitor = FakeMonitor()  // always reads back 100
        let syncer = makeSyncer(FakeSource(0.06), monitor)
        for halfSecond in 0...240 {
            syncer.tick(onlineDisplays: bothDisplays, now: start + Double(halfSecond) / 2)
        }
        // The first write, then at most one correction per scheduled check.
        #expect(monitor.writes.count == 1 + Syncer.verificationDelays.count)
    }

    @Test func brightnessHoveringAtARoundingBoundaryDoesNotChatter() {
        let source = FakeSource(0.5)
        let monitor = FakeMonitor()
        monitor.reading = DDC.Reply(current: 50, maximum: 100)
        let syncer = makeSyncer(source, monitor)
        syncer.tick(onlineDisplays: bothDisplays, now: start)  // writes 50
        for (index, value) in [0.506, 0.494, 0.506, 0.494].enumerated() {
            source.value = value
            syncer.tick(onlineDisplays: bothDisplays, now: start + Double(index + 1))
        }
        #expect(monitor.writes == [50])
    }

    @Test func replugReconnectsAndResends() {
        let monitor = FakeMonitor()
        let syncer = makeSyncer(FakeSource(0.5), monitor)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        monitor.displaysFound = 0
        syncer.tick(onlineDisplays: builtInOnly, now: start + 1)
        #expect(!monitor.isConnected)
        monitor.displaysFound = 1
        syncer.tick(onlineDisplays: bothDisplays, now: start + 2)
        #expect(monitor.writes == [50, 50])
        #expect(monitor.connectCount == 3)
    }

    @Test func resendsWhenTheBuiltInDisplayComesBack() {
        let source = FakeSource(0.5)
        let monitor = FakeMonitor()
        let log = LogRecorder()
        let syncer = makeSyncer(source, monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        source.value = nil
        syncer.tick(onlineDisplays: bothDisplays, now: start + 1)
        #expect(log.lines.contains("built-in display unavailable (lid closed, asleep, or brightness unreadable); waiting"))
        source.value = 0.5
        syncer.tick(onlineDisplays: bothDisplays, now: start + 2)
        #expect(monitor.writes == [50, 50])
    }

    @Test func failedWriteIsRetriedAfterTheRediscoveryInterval() {
        let monitor = FakeMonitor()
        monitor.acceptsWrites = false
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)      // connect #1, write fails
        syncer.tick(onlineDisplays: bothDisplays, now: start + 1)  // too soon to rediscover
        #expect(monitor.writes == [50])
        #expect(monitor.connectCount == 1)
        monitor.acceptsWrites = true
        syncer.tick(onlineDisplays: bothDisplays, now: start + 5)  // connect #2, write succeeds
        #expect(monitor.writes == [50, 50])
        #expect(monitor.connectCount == 2)
        #expect(log.lines.filter { $0 == "DDC write failed; reconnecting" }.count == 1)
    }

    @Test func valueIsResentAfterAFailedWriteEvenIfTheTargetReturnsToTheLastWrittenValue() {
        let source = FakeSource(0.5)
        let monitor = FakeMonitor()
        let syncer = makeSyncer(source, monitor)
        syncer.tick(onlineDisplays: bothDisplays, now: start)      // writes 50
        source.value = 0.6
        monitor.acceptsWrites = false
        syncer.tick(onlineDisplays: bothDisplays, now: start + 1)  // 60 reported as failed, may be on the panel
        source.value = 0.5
        monitor.acceptsWrites = true
        syncer.tick(onlineDisplays: bothDisplays, now: start + 7)  // after rediscovery, 50 must go out again
        #expect(monitor.writes == [50, 60, 50])
    }

    @Test func clockSteppingBackDoesNotStallRediscovery() {
        let monitor = FakeMonitor()
        monitor.displaysFound = 0
        let syncer = makeSyncer(FakeSource(0.5), monitor)
        syncer.tick(onlineDisplays: builtInOnly, now: start + 3600)  // discovery #1
        syncer.tick(onlineDisplays: builtInOnly, now: start)         // clock stepped back an hour
        #expect(monitor.connectCount == 2)
    }

    @Test func reconnectionAfterADisplayChangeIsLoggedAgain() {
        let monitor = FakeMonitor()
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        syncer.tick(onlineDisplays: [1, 5], now: start + 1)  // monitor replugged under a new display ID
        #expect(log.lines.contains("display configuration changed"))
        #expect(log.lines.filter { $0 == "external display connected (brightness 100/100)" }.count == 2)
        #expect(monitor.writes == [50, 50])
    }

    @Test func warnsWhenSeveralExternalDisplaysAreFound() {
        let monitor = FakeMonitor()
        monitor.displaysFound = 2
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        syncer.tick(onlineDisplays: [1, 4, 5], now: start)
        #expect(log.lines.contains("warning: 2 external displays found; using the first"))
        #expect(monitor.writes == [50])
    }

    @Test func logsWhenTheMonitorsBrightnessCannotBeRead() {
        let monitor = FakeMonitor()
        monitor.reading = nil
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        syncer.tick(onlineDisplays: bothDisplays, now: start)
        #expect(log.lines.contains("external display connected (brightness read failed)"))
        #expect(monitor.writes == [50])
    }

    @Test func missingMonitorIsRetriedEveryFiveSecondsAndLoggedOnce() {
        let monitor = FakeMonitor()
        monitor.displaysFound = 0
        let log = LogRecorder()
        let syncer = makeSyncer(FakeSource(0.5), monitor, log)
        for second in [0.0, 1, 5, 6, 10] {
            syncer.tick(onlineDisplays: builtInOnly, now: start + second)
        }
        #expect(monitor.connectCount == 3)
        #expect(monitor.writes.isEmpty)
        #expect(log.lines.filter { $0 == "no external display found" }.count == 1)
    }
}
