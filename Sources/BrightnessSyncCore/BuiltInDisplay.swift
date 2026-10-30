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
