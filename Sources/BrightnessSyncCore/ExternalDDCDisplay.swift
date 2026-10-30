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

    /// Writes VCP 0x10. Each packet goes out twice, 10 ms apart, as verified on the LS24A600U;
    /// the write counts as delivered if either attempt was accepted.
    public func setBrightness(_ value: Int) -> Bool {
        guard let service else { return false }
        let packet = DDC.setPacket(code: DDC.brightness, value: UInt16(clamping: value))
        var delivered = false
        for _ in 0..<2 {
            usleep(10_000)
            delivered = write(packet, to: service) || delivered
        }
        return delivered
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
