# brightness-sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A login agent that makes the external Samsung LS24A600U's hardware backlight follow the MacBook's built-in display brightness (keys, Control Center, auto-brightness) over DDC/CI.

**Architecture:** A Swift package. `BrightnessSyncCore` holds pure, unit-tested logic (`DDC` packets, `BrightnessMapper`, `SyncPolicy`, `Options`, and the per-tick `Syncer`, which talks to the hardware only through two small protocols) plus thin system adapters (`BuiltInDisplay` via the private DisplayServices framework, `ExternalDDCDisplay` via the private IOAVService API). The `brightness-sync` executable wires them together and ticks every 250 ms; a per-user LaunchAgent starts it at login.

**Tech Stack:** Swift 6.4 (language mode 6), Swift Package Manager, Swift Testing, CoreGraphics, IOKit, launchd, make.

**Spec:** `docs/superpowers/specs/2026-10-30-brightness-sync-design.md`

**Deviations from the spec (structure only, behaviour unchanged):**
- The data flow ("every 250 ms …") lives in `Syncer.tick` inside the library, not in the executable, so it can be unit-tested with fakes.
- The executable's entry point is `@main struct BrightnessSync` in `BrightnessSync.swift` instead of `main.swift`, which avoids Swift 6 top-level-global isolation rules.

---

## File structure

| Path | Responsibility |
|---|---|
| `Package.swift` | Package manifest: `BrightnessSyncCore` library, `brightness-sync` executable, `BrightnessSyncCoreTests`. |
| `.gitignore` | Ignore `.build/`, `.swiftpm/`, `.DS_Store`. |
| `Sources/BrightnessSyncCore/DDC.swift` | DDC/CI packet encoding/decoding (pure). |
| `Sources/BrightnessSyncCore/BrightnessMapper.swift` | 0…1 → monitor value within min/max (pure). |
| `Sources/BrightnessSyncCore/SyncPolicy.swift` | When to write: change detection, forced resends, 400 ms rate limit (pure). |
| `Sources/BrightnessSyncCore/Options.swift` | CLI parsing and validation (pure). |
| `Sources/BrightnessSyncCore/Syncer.swift` | `BrightnessSource` / `MonitorLink` protocols and the per-tick sync logic (pure). |
| `Sources/BrightnessSyncCore/PrivateSymbol.swift` | `dlopen`/`dlsym` lookup of private C functions. |
| `Sources/BrightnessSyncCore/Displays.swift` | Online display IDs from CoreGraphics. |
| `Sources/BrightnessSyncCore/BuiltInDisplay.swift` | `BrightnessSource` backed by `DisplayServicesGetBrightness`. |
| `Sources/BrightnessSyncCore/ExternalDDCDisplay.swift` | `MonitorLink` backed by `IOAVServiceCreateWithService` / `WriteI2C` / `ReadI2C`. |
| `Sources/brightness-sync/BrightnessSync.swift` | Entry point: parse options, build adapters, loop, log. |
| `Tests/BrightnessSyncCoreTests/*.swift` | Swift Testing suites for the pure units. |
| `launchd/agent.plist.in` | LaunchAgent template rendered by `make install`. |
| `Makefile` | `build`, `test`, `install`, `uninstall`, `logs`. |
| `README.md` | What it is, install, use, how it works. |

All commands run from the repository root, `~/Development/brightness-sync`. Every commit message ends with the
`Claude-Session:` trailer line used in this repository.

---

### Task 1: Package skeleton and DDC packets

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Tests/BrightnessSyncCoreTests/DDCTests.swift`
- Create: `Sources/BrightnessSyncCore/DDC.swift`

- [ ] **Step 1: Create the package manifest and .gitignore**

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "brightness-sync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BrightnessSyncCore"),
        .testTarget(name: "BrightnessSyncCoreTests", dependencies: ["BrightnessSyncCore"]),
    ]
)
```

`.gitignore`:
```
.build/
.swiftpm/
.DS_Store
```

- [ ] **Step 2: Write the failing tests**

`Tests/BrightnessSyncCoreTests/DDCTests.swift`:
```swift
import Testing
@testable import BrightnessSyncCore

struct DDCTests {
    /// Reply the Samsung LS24A600U sent to "get brightness" on 2026-10-30 (current 100, max 100).
    let capturedReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]

    @Test func setPacketsMatchBytesTheMonitorAccepted() {
        #expect(DDC.setPacket(code: DDC.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.setPacket(code: DDC.brightness, value: 100) == [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
    }

    @Test func setPacketCarriesTheHighByte() {
        #expect(DDC.setPacket(code: DDC.brightness, value: 0x0123) == [0x84, 0x03, 0x10, 0x01, 0x23, 0x8A])
    }

    @Test func getPacketMatchesBytesTheMonitorAnswered() {
        #expect(DDC.getPacket(code: DDC.brightness) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func parsesTheCapturedReply() {
        #expect(DDC.parseReply(capturedReply, code: DDC.brightness) == DDC.Reply(current: 100, maximum: 100))
    }

    @Test func parsesSixteenBitValues() {
        let reply = withReplyChecksum([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x01, 0x2C, 0x00, 0x96])
        #expect(DDC.parseReply(reply, code: DDC.brightness) == DDC.Reply(current: 150, maximum: 300))
    }

    @Test func rejectsABadChecksum() {
        var reply = capturedReply
        reply[10] ^= 0xFF
        #expect(DDC.parseReply(reply, code: DDC.brightness) == nil)
    }

    // (byte index, replacement): not a VCP reply; monitor reports "unsupported"; reply for contrast (0x12)
    @Test(arguments: [(2, UInt8(0x03)), (3, UInt8(0x01)), (4, UInt8(0x12))])
    func rejectsRepliesThatAreNotABrightnessValue(index: Int, value: UInt8) {
        var bytes = Array(capturedReply.prefix(10))
        bytes[index] = value
        #expect(DDC.parseReply(withReplyChecksum(bytes), code: DDC.brightness) == nil)
    }

    @Test func rejectsATruncatedReply() {
        #expect(DDC.parseReply(Array(capturedReply.prefix(10)), code: DDC.brightness) == nil)
    }

    private func withReplyChecksum(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(UInt8(0x50), ^)]
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test`
Expected: FAIL — the build errors out because `BrightnessSyncCore` has no sources / `cannot find 'DDC' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/BrightnessSyncCore/DDC.swift`:
```swift
/// DDC/CI packets for reading and writing monitor settings (VESA "VCP" features).
///
/// A packet is what follows the host address (0x51) on the I²C bus: a length byte, an opcode, the
/// operands and a checksum. The transport sends the chip address (0x37) and the host address itself,
/// but the host address still counts towards the checksum.
public enum DDC {
    /// 7-bit I²C address of a monitor's DDC/CI interface.
    public static let chipAddress: UInt32 = 0x37
    /// Host ("source") address that precedes every packet the host sends.
    public static let hostAddress: UInt32 = 0x51
    /// VCP code for luminance (brightness).
    public static let brightness: UInt8 = 0x10

    /// A decoded "VCP feature reply".
    public struct Reply: Equatable, Sendable {
        public let current: UInt16
        public let maximum: UInt16

        public init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }
    }

    /// "Set VCP feature": length 0x84, opcode 0x03, code, value high byte, value low byte, checksum.
    public static func setPacket(code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// "Get VCP feature": length 0x82, opcode 0x01, code, checksum.
    public static func getPacket(code: UInt8) -> [UInt8] {
        withChecksum([0x82, 0x01, code])
    }

    /// Decodes the 11-byte reply to `getPacket(code:)`. Returns nil if the checksum is wrong, the
    /// monitor reported an error, or the reply is not a VCP reply for `code`.
    public static func parseReply(_ bytes: [UInt8], code: UInt8) -> Reply? {
        guard bytes.count == 11,
              bytes[0..<10].reduce(UInt8(0x50), ^) == bytes[10],  // replies are checksummed against 0x50
              bytes[1] == 0x88,  // length: 8 data bytes follow
              bytes[2] == 0x02,  // opcode: VCP feature reply
              bytes[3] == 0x00,  // result: no error
              bytes[4] == code
        else { return nil }
        return Reply(current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                     maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
    }

    private static func withChecksum(_ payload: [UInt8]) -> [UInt8] {
        // The checksum also covers the monitor's 8-bit write address (0x6E) and the host address (0x51).
        payload + [payload.reduce(UInt8(0x6E ^ 0x51), ^)]
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS — all `DDCTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources/BrightnessSyncCore/DDC.swift Tests/BrightnessSyncCoreTests/DDCTests.swift
git commit -m "Add DDC/CI packet encoding and reply parsing"
```

---

### Task 2: BrightnessMapper

**Files:**
- Create: `Tests/BrightnessSyncCoreTests/BrightnessMapperTests.swift`
- Create: `Sources/BrightnessSyncCore/BrightnessMapper.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BrightnessSyncCoreTests/BrightnessMapperTests.swift`:
```swift
import Testing
@testable import BrightnessSyncCore

struct BrightnessMapperTests {
    @Test func defaultRangeIsTheWholeMonitorRange() {
        let mapper = BrightnessMapper()
        #expect(mapper.map(0) == 0)
        #expect(mapper.map(0.5) == 50)
        #expect(mapper.map(1) == 100)
    }

    @Test func roundsToTheNearestStep() {
        let mapper = BrightnessMapper()
        #expect(mapper.map(0.0029) == 0)
        #expect(mapper.map(0.0625) == 6)
        #expect(mapper.map(0.554) == 55)
        #expect(mapper.map(0.556) == 56)
    }

    @Test func customRange() {
        let mapper = BrightnessMapper(minimum: 20, maximum: 80)
        #expect(mapper.map(0) == 20)
        #expect(mapper.map(0.5) == 50)
        #expect(mapper.map(1) == 80)
    }

    @Test func clampsOutOfRangeInput() {
        let mapper = BrightnessMapper(minimum: 10, maximum: 90)
        #expect(mapper.map(-0.5) == 10)
        #expect(mapper.map(1.7) == 90)
        #expect(mapper.map(.nan) == 10)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BrightnessMapperTests`
Expected: FAIL — `cannot find 'BrightnessMapper' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/BrightnessSyncCore/BrightnessMapper.swift`:
```swift
/// Maps the built-in display's brightness (0…1) onto a slice of the monitor's 0…100 range.
public struct BrightnessMapper: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int = 0, maximum: Int = 100) {
        precondition(0 <= minimum && minimum < maximum && maximum <= 100, "need 0 ≤ minimum < maximum ≤ 100")
        self.minimum = minimum
        self.maximum = maximum
    }

    public func map(_ brightness: Double) -> Int {
        let fraction = brightness.isNaN ? 0 : min(max(brightness, 0), 1)
        return Int((Double(minimum) + Double(maximum - minimum) * fraction).rounded())
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BrightnessMapperTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BrightnessSyncCore/BrightnessMapper.swift Tests/BrightnessSyncCoreTests/BrightnessMapperTests.swift
git commit -m "Add BrightnessMapper"
```

---

### Task 3: SyncPolicy

**Files:**
- Create: `Tests/BrightnessSyncCoreTests/SyncPolicyTests.swift`
- Create: `Sources/BrightnessSyncCore/SyncPolicy.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BrightnessSyncCoreTests/SyncPolicyTests.swift`:
```swift
import Foundation
import Testing
@testable import BrightnessSyncCore

struct SyncPolicyTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func firstValueIsWritten() {
        #expect(SyncPolicy().shouldWrite(50, at: start))
    }

    @Test func unchangedTargetIsNotRewritten() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(50, at: start + 1))
    }

    @Test func changedTargetIsWritten() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(policy.shouldWrite(60, at: start + 1))
    }

    @Test func changesWaitForTheMinimumInterval() {
        var policy = SyncPolicy(minimumInterval: 0.4)
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(60, at: start + 0.2))
        #expect(policy.shouldWrite(70, at: start + 0.4))
    }

    @Test func forcedResendWritesAnUnchangedTargetOnceTheIntervalAllows() {
        var policy = SyncPolicy(minimumInterval: 0.4)
        policy.didWrite(50, at: start)
        policy.forceResend()
        #expect(!policy.shouldWrite(50, at: start + 0.1))
        #expect(policy.shouldWrite(50, at: start + 0.5))
    }

    @Test func successfulWriteClearsAForcedResend() {
        var policy = SyncPolicy()
        policy.forceResend()
        policy.didWrite(50, at: start)
        #expect(!policy.shouldWrite(50, at: start + 1))
    }

    @Test func failedWriteKeepsAskingForTheValue() {
        var policy = SyncPolicy()
        policy.didWrite(50, at: start)
        #expect(policy.shouldWrite(60, at: start + 1))
        // The write failed, so didWrite was not called.
        #expect(policy.shouldWrite(60, at: start + 1.25))
        #expect(policy.lastWritten == 50)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncPolicyTests`
Expected: FAIL — `cannot find 'SyncPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/BrightnessSyncCore/SyncPolicy.swift`:
```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SyncPolicyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BrightnessSyncCore/SyncPolicy.swift Tests/BrightnessSyncCoreTests/SyncPolicyTests.swift
git commit -m "Add SyncPolicy"
```

---

### Task 4: Options

**Files:**
- Create: `Tests/BrightnessSyncCoreTests/OptionsTests.swift`
- Create: `Sources/BrightnessSyncCore/Options.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BrightnessSyncCoreTests/OptionsTests.swift`:
```swift
import Testing
@testable import BrightnessSyncCore

struct OptionsTests {
    @Test func defaults() throws {
        let options = try Options(arguments: [])
        #expect(options.minimum == 0)
        #expect(options.maximum == 100)
        #expect(!options.verbose)
        #expect(!options.showHelp)
    }

    @Test func parsesEveryFlag() throws {
        let options = try Options(arguments: ["--min", "10", "--max", "90", "--verbose"])
        #expect(options.minimum == 10)
        #expect(options.maximum == 90)
        #expect(options.verbose)
    }

    @Test func help() throws {
        #expect(try Options(arguments: ["--help"]).showHelp)
        #expect(try Options(arguments: ["-h"]).showHelp)
    }

    @Test(arguments: [
        ["--min"],
        ["--max", "abc"],
        ["--min", "-1"],
        ["--max", "101"],
        ["--min", "50", "--max", "50"],
        ["--brightness", "5"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: OptionsError.self) { try Options(arguments: arguments) }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OptionsTests`
Expected: FAIL — `cannot find 'Options' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/BrightnessSyncCore/Options.swift`:
```swift
/// Command-line options: `brightness-sync [--min N] [--max N] [--verbose]`.
public struct Options: Equatable, Sendable {
    public static let usage = "usage: brightness-sync [--min N] [--max N] [--verbose]  (0 ≤ min < max ≤ 100)"

    public var minimum = 0
    public var maximum = 100
    public var verbose = false
    public var showHelp = false

    /// Parses the arguments that follow the program name.
    public init(arguments: [String]) throws(OptionsError) {
        var remaining = arguments.makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--min": minimum = try Self.number(for: argument, remaining.next())
            case "--max": maximum = try Self.number(for: argument, remaining.next())
            case "--verbose": verbose = true
            case "-h", "--help": showHelp = true
            default: throw OptionsError("unknown argument \(argument)")
            }
        }
        guard 0 <= minimum, minimum < maximum, maximum <= 100 else {
            throw OptionsError("need 0 ≤ min < max ≤ 100, got min \(minimum) and max \(maximum)")
        }
    }

    private static func number(for flag: String, _ value: String?) throws(OptionsError) -> Int {
        guard let value, let number = Int(value) else { throw OptionsError("\(flag) needs a whole number") }
        return number
    }
}

public struct OptionsError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OptionsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BrightnessSyncCore/Options.swift Tests/BrightnessSyncCoreTests/OptionsTests.swift
git commit -m "Add command-line options"
```

---

### Task 5: Syncer (the sync loop's logic)

**Files:**
- Create: `Tests/BrightnessSyncCoreTests/SyncerTests.swift`
- Create: `Sources/BrightnessSyncCore/Syncer.swift`

Behaviour (spec, *Data flow* and *Error handling*), one call to `tick` per 250 ms:
1. If the set of online display IDs changed: log it (except on the first tick), disconnect, allow immediate rediscovery, force a resend.
2. If the built-in brightness is unavailable: note it and return. When it comes back: force a resend.
3. Map to a target; ask `SyncPolicy`; connect if needed (rediscover at most every 5 s unless a display change reset the timer); write.
4. Success: record it. Failure: note it and disconnect; the value is retried after rediscovery.
Status messages go through `note(topic:message)`, which drops a message identical to the previous one on the same topic, so failure loops don't flood the log.

- [ ] **Step 1: Write the failing tests**

`Tests/BrightnessSyncCoreTests/SyncerTests.swift`:
```swift
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

    func readBrightness() -> DDC.Reply? { DDC.Reply(current: 100, maximum: 100) }
}

final class LogRecorder {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}

struct SyncerTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let bothDisplays: Set<UInt32> = [1, 4]
    let builtInOnly: Set<UInt32> = [1]

    func makeSyncer(_ source: FakeSource, _ monitor: FakeMonitor, _ log: LogRecorder = LogRecorder()) -> Syncer {
        Syncer(source: source, monitor: monitor, mapper: BrightnessMapper(), log: log.record)
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
        #expect(log.lines.contains("built-in display unavailable (lid closed or asleep); waiting"))
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SyncerTests`
Expected: FAIL — `cannot find type 'BrightnessSource' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/BrightnessSyncCore/Syncer.swift`:
```swift
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
        }

        guard let brightness = source.brightness() else {
            note("built-in", "built-in display unavailable (lid closed or asleep); waiting")
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
        }
    }

    private func connectIfNeeded(now: Date) -> Bool {
        if monitor.isConnected { return true }
        if let lastDiscovery, now.timeIntervalSince(lastDiscovery) < Self.rediscoveryInterval { return false }
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
```

- [ ] **Step 4: Run all tests to verify they pass**

Run: `swift test`
Expected: PASS — every suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/BrightnessSyncCore/Syncer.swift Tests/BrightnessSyncCoreTests/SyncerTests.swift
git commit -m "Add Syncer: per-tick sync logic with reconnect and retry"
```

---

### Task 6: System adapters and the executable

**Files:**
- Create: `Sources/BrightnessSyncCore/PrivateSymbol.swift`
- Create: `Sources/BrightnessSyncCore/Displays.swift`
- Create: `Sources/BrightnessSyncCore/BuiltInDisplay.swift`
- Create: `Sources/BrightnessSyncCore/ExternalDDCDisplay.swift`
- Create: `Sources/brightness-sync/BrightnessSync.swift`
- Modify: `Package.swift` (add the executable target)

These wrap private APIs and real hardware, so they are verified by running them (Step 8), not by unit tests.
Facts they rely on are in the spec's *Verified facts* section.

- [ ] **Step 1: Private symbol lookup**

`Sources/BrightnessSyncCore/PrivateSymbol.swift`:
```swift
import Foundation

/// A C function from a system framework that ships without public headers, looked up at run time.
enum PrivateSymbol {
    static func load<Function>(_ name: String, from framework: String, as type: Function.Type) throws(MissingSymbol) -> Function {
        guard let handle = dlopen(framework, RTLD_NOW), let symbol = dlsym(handle, name) else {
            throw MissingSymbol(name: name)
        }
        return unsafeBitCast(symbol, to: type)
    }
}

public struct MissingSymbol: Error, CustomStringConvertible {
    public let name: String
    public var description: String { "missing private symbol \(name); this macOS version may have changed it" }
}
```

- [ ] **Step 2: Online displays**

`Sources/BrightnessSyncCore/Displays.swift`:
```swift
import CoreGraphics

public enum Displays {
    /// IDs of all connected displays, including asleep and mirrored ones.
    public static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
```

- [ ] **Step 3: Built-in display**

`Sources/BrightnessSyncCore/BuiltInDisplay.swift`:
```swift
import CoreGraphics

/// The MacBook's own panel. Its brightness — the value behind the brightness slider — comes from the
/// private DisplayServices framework.
public final class BuiltInDisplay: BrightnessSource {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let getBrightness: GetBrightness

    public init() throws(MissingSymbol) {
        getBrightness = try PrivateSymbol.load(
            "DisplayServicesGetBrightness",
            from: "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            as: GetBrightness.self)
    }

    public func brightness() -> Double? {
        guard let id = Displays.online().first(where: { CGDisplayIsBuiltin($0) != 0 }),
              CGDisplayIsAsleep(id) == 0
        else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }
}
```

- [ ] **Step 4: External display over DDC**

`Sources/BrightnessSyncCore/ExternalDDCDisplay.swift`:
```swift
import Foundation
import IOKit

/// The external monitor's DDC/CI channel on Apple silicon, reached through the private IOAVService API
/// on the `DCPAVServiceProxy` whose Location is "External".
public final class ExternalDDCDisplay: MonitorLink {
    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let createService: CreateService
    private let writeI2C: TransferI2C
    private let readI2C: TransferI2C
    private var service: CFTypeRef?

    public init() throws(MissingSymbol) {
        let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"
        createService = try PrivateSymbol.load("IOAVServiceCreateWithService", from: iokit, as: CreateService.self)
        writeI2C = try PrivateSymbol.load("IOAVServiceWriteI2C", from: iokit, as: TransferI2C.self)
        readI2C = try PrivateSymbol.load("IOAVServiceReadI2C", from: iokit, as: TransferI2C.self)
    }

    public var isConnected: Bool { service != nil }

    public func connect() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var services: [CFTypeRef] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External", let avService = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                services.append(avService)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        service = services.first
        return services.count
    }

    public func disconnect() {
        service = nil
    }

    /// Writes VCP 0x10. Each packet goes out twice, 10 ms apart, as verified on the LS24A600U.
    public func setBrightness(_ value: Int) -> Bool {
        guard let service else { return false }
        let packet = DDC.setPacket(code: DDC.brightness, value: UInt16(clamping: value))
        for _ in 0..<2 {
            usleep(10_000)
            guard write(packet, to: service) else { return false }
        }
        return true
    }

    public func readBrightness() -> DDC.Reply? {
        guard let service else { return nil }
        let request = DDC.getPacket(code: DDC.brightness)
        for _ in 0..<3 {
            for _ in 0..<2 {
                usleep(10_000)
                _ = write(request, to: service)
            }
            usleep(50_000)  // DDC/CI: give the monitor at least 40 ms to prepare its reply
            var reply = [UInt8](repeating: 0, count: 11)
            let status = reply.withUnsafeMutableBytes {
                readI2C(service, DDC.chipAddress, DDC.hostAddress, $0.baseAddress!, UInt32($0.count))
            }
            if status == kIOReturnSuccess, let parsed = DDC.parseReply(reply, code: DDC.brightness) {
                return parsed
            }
            usleep(20_000)
        }
        return nil
    }

    private func write(_ packet: [UInt8], to service: CFTypeRef) -> Bool {
        var bytes = packet
        let status = bytes.withUnsafeMutableBytes {
            writeI2C(service, DDC.chipAddress, DDC.hostAddress, $0.baseAddress!, UInt32($0.count))
        }
        return status == kIOReturnSuccess
    }
}
```

- [ ] **Step 5: Entry point**

`Sources/brightness-sync/BrightnessSync.swift`:
```swift
import BrightnessSyncCore
import Foundation

@main
struct BrightnessSync {
    static func main() {
        let options: Options
        do {
            options = try Options(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))
        } catch {
            log("\(error)\n\(Options.usage)")
            exit(64)
        }
        if options.showHelp {
            print(Options.usage)
            return
        }

        let builtIn: BuiltInDisplay
        let monitor: ExternalDDCDisplay
        do {
            builtIn = try BuiltInDisplay()
            monitor = try ExternalDDCDisplay()
        } catch {
            log("\(error)")
            exit(1)
        }

        log("started (min \(options.minimum), max \(options.maximum)\(options.verbose ? ", verbose" : ""))")
        let syncer = Syncer(
            source: builtIn,
            monitor: monitor,
            mapper: BrightnessMapper(minimum: options.minimum, maximum: options.maximum),
            verbose: options.verbose,
            log: log)
        while true {
            syncer.tick(onlineDisplays: Set(Displays.online()), now: .now)
            Thread.sleep(forTimeInterval: Syncer.tickInterval)
        }
    }

    static func log(_ message: String) {
        let timestamp = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
        FileHandle.standardError.write(Data("\(timestamp) \(message)\n".utf8))
    }
}
```

- [ ] **Step 6: Add the executable target**

`Package.swift`, replace the `targets` array with:
```swift
    targets: [
        .target(name: "BrightnessSyncCore"),
        .executableTarget(name: "brightness-sync", dependencies: ["BrightnessSyncCore"]),
        .testTarget(name: "BrightnessSyncCoreTests", dependencies: ["BrightnessSyncCore"]),
    ]
```

- [ ] **Step 7: Build and check the CLI contract**

Run:
```bash
swift build -c release 2>&1 | tail -3
.build/release/brightness-sync --help; echo "exit=$?"
.build/release/brightness-sync --min 50 --max 50; echo "exit=$?"
swift test 2>&1 | tail -3
```
Expected: build succeeds; `--help` prints the usage line and `exit=0`; the invalid range logs
`need 0 ≤ min < max ≤ 100, got min 50 and max 50` plus usage and `exit=64`; all tests pass.

- [ ] **Step 8: Smoke-run on the hardware**

This sets the Samsung's brightness to match the MacBook's.

Run:
```bash
.build/release/brightness-sync --verbose & PID=$!; sleep 3; kill $PID
```
Expected (timestamps omitted):
```
started (min 0, max 100, verbose)
built-in display available
external display connected (brightness N/100)
writing brightness to the external display
built-in 0.xxxx → monitor M
```
where `M = round(100 × built-in brightness)`.

- [ ] **Step 9: Commit**

```bash
git add Package.swift Sources/BrightnessSyncCore/PrivateSymbol.swift Sources/BrightnessSyncCore/Displays.swift \
  Sources/BrightnessSyncCore/BuiltInDisplay.swift Sources/BrightnessSyncCore/ExternalDDCDisplay.swift \
  Sources/brightness-sync/BrightnessSync.swift
git commit -m "Add DisplayServices and IOAVService adapters and the brightness-sync executable"
```

---

### Task 7: LaunchAgent, Makefile, README, live verification

**Files:**
- Create: `launchd/agent.plist.in`
- Create: `Makefile` (recipe lines are indented with a **tab**)
- Create: `README.md`

- [ ] **Step 1: LaunchAgent template**

`launchd/agent.plist.in`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>@LABEL@</string>
	<key>ProgramArguments</key>
	<array>
		<string>@BINARY@</string>
		<string>--min</string>
		<string>@MIN@</string>
		<string>--max</string>
		<string>@MAX@</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>@LOG@</string>
	<key>StandardErrorPath</key>
	<string>@LOG@</string>
</dict>
</plist>
```

- [ ] **Step 2: Makefile**

`Makefile`:
```make
LABEL  := io.github.effekt3r.brightness-sync
BINARY := $(HOME)/.local/bin/brightness-sync
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG    := $(HOME)/Library/Logs/brightness-sync.log
DOMAIN := gui/$(shell id -u)
MIN    ?= 0
MAX    ?= 100

.PHONY: build test install uninstall logs

build:
	swift build -c release

test:
	swift test

install: build
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	mkdir -p $(dir $(BINARY)) $(dir $(PLIST)) $(dir $(LOG))
	install -m 755 .build/release/brightness-sync $(BINARY)
	$(BINARY) --min $(MIN) --max $(MAX) --help > /dev/null
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BINARY@|$(BINARY)|' -e 's|@LOG@|$(LOG)|' \
		-e 's|@MIN@|$(MIN)|' -e 's|@MAX@|$(MAX)|' launchd/agent.plist.in > $(PLIST)
	plutil -lint $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST) || { sleep 1; launchctl bootstrap $(DOMAIN) $(PLIST); }
	@echo "brightness-sync is running and starts at login. Follow it with: make logs"

uninstall:
	-launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null
	rm -f $(PLIST) $(BINARY)

logs:
	tail -f $(LOG)
```
(The `--help` line validates `MIN`/`MAX` before anything is loaded: invalid values exit 64 and stop `make`.)

- [ ] **Step 3: README**

`README.md`:
````markdown
# brightness-sync

Makes an external monitor follow your MacBook's screen brightness — brightness keys, Control Center
and auto-brightness — by setting the monitor's real backlight over DDC/CI.

Built and tested on a MacBook Pro (M3 Max, macOS 27) driving a Samsung LS24A600U over USB-C. It should
work with other DDC/CI monitors on Apple silicon, one external monitor at a time.

## Install

```sh
make install                 # build, copy to ~/.local/bin, start now and at every login
make install MIN=10 MAX=90   # use only part of the monitor's range
```

macOS shows a "Background Items Added" notice the first time; that's this agent.

## Use

Change the MacBook's brightness; the monitor follows within about half a second.

Keep the monitor's own Brightness slider in System Settings → Displays at maximum. It is separate
from the backlight that brightness-sync drives.

```sh
make logs        # follow ~/Library/Logs/brightness-sync.log
make uninstall   # stop and remove
```

To watch every write, run `make uninstall`, then `.build/release/brightness-sync --verbose`.

## How it works

- Every 250 ms it reads the built-in display's brightness (`DisplayServicesGetBrightness`).
- It maps 0…1 onto `MIN…MAX` and, when the whole-number value changes, writes VCP `0x10` (luminance)
  to the monitor with `IOAVServiceWriteI2C`, at most once every 0.4 s.
- It re-sends after display changes, after the built-in display wakes or the lid opens, and after a
  failed write.

Both APIs are private and may change in a future macOS release.
Design: [docs/superpowers/specs/2026-10-30-brightness-sync-design.md](docs/superpowers/specs/2026-10-30-brightness-sync-design.md).

## Development

```sh
make test
```
````

- [ ] **Step 4: Install and check the agent is running**

Run:
```bash
make install
sleep 2
launchctl print gui/$(id -u)/io.github.effekt3r.brightness-sync | grep -E '^\s*(state|pid|last exit code) ='
cat ~/Library/Logs/brightness-sync.log
```
Expected: `plutil` reports OK; `state = running` with a pid; the log shows `started (min 0, max 100)`,
`built-in display available`, `external display connected (brightness N/100)`,
`writing brightness to the external display`.

- [ ] **Step 5: Live checklist (spec)**

1. Press the brightness keys on the MacBook (pointer on the MacBook's screen): the Samsung follows within ~0.5 s.
2. Auto-brightness: change the room lighting or cover the sensor next to the camera: the Samsung follows.
3. Sleep/wake the displays, power-cycle the Samsung, unplug/replug it: the log shows
   `display configuration changed` / `external display connected …` and the value is re-sent.
4. Close the lid with the Samsung attached: the log shows `built-in display unavailable …; waiting`, no errors.
5. The Samsung's System Settings slider stays at max and the image is not dimmed twice.

- [ ] **Step 6: Commit and push**

```bash
git add launchd/agent.plist.in Makefile README.md
git commit -m "Add LaunchAgent install, Makefile and README"
git push
```
