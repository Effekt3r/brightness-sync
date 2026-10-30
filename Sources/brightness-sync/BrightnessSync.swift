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
            autoreleasepool {
                syncer.tick(onlineDisplays: Set(Displays.online()), now: .now)
            }
            Thread.sleep(forTimeInterval: Syncer.tickInterval)
        }
    }

    static func log(_ message: String) {
        let timestamp = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
        // The throwing variant: the legacy write(_:) raises an exception (and crashes) when the disk is full.
        try? FileHandle.standardError.write(contentsOf: Data("\(timestamp) \(message)\n".utf8))
    }
}
