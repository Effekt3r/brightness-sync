import CoreGraphics

/// The MacBook's own panel. Reports its light output relative to full slider, read through the private
/// DisplayServices framework.
///
/// The brightness slider is perceptual: in the bottom half each step changes the light output about
/// 1.8×, so a monitor driven from the slider position stays far too bright as the panel dims. Driving the
/// monitor from the linear light output keeps the two screens' levels in step.
public final class BuiltInDisplay: BrightnessSource {
    /// `DisplayServicesGetLinearBrightness` at full slider on this MacBook Pro (M3 Max), measured
    /// 2026-10-31. The panel can go brighter than the slider, so its linear scale tops out at about 2/3.
    public static let fullSliderLinear = 2.0 / 3.0

    private typealias GetLinearBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let getLinearBrightness: GetLinearBrightness

    public init() throws(MissingSymbol) {
        getLinearBrightness = try PrivateSymbol.load(
            "DisplayServicesGetLinearBrightness",
            from: "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            as: GetLinearBrightness.self)
    }

    public func brightness() -> Double? {
        guard let id = Displays.online().first(where: { CGDisplayIsBuiltin($0) != 0 }),
              CGDisplayIsAsleep(id) == 0
        else { return nil }
        var linear: Float = 0
        guard getLinearBrightness(id, &linear) == 0 else { return nil }
        return Self.relativeOutput(linear: Double(linear))
    }

    /// Light output as a fraction of the output at full slider, 0…1.
    public static func relativeOutput(linear: Double) -> Double {
        min(max(linear / fullSliderLinear, 0), 1)
    }
}
