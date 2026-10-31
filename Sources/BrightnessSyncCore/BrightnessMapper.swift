/// Maps the built-in display's brightness (0…1) onto a slice of the monitor's 0…100 range, and below
/// `dimBelow` also onto a dimmed picture, because the monitor's backlight can't get as dark as the MacBook.
public struct BrightnessMapper: Equatable, Sendable {
    /// The dimmest picture used, so the monitor never goes black.
    public static let minimumPicture = 0.03

    public let minimum: Int
    public let maximum: Int
    public let dimBelow: Double

    public init(minimum: Int = 0, maximum: Int = 100, dimBelow: Double = 0.15) {
        precondition(0 <= minimum && minimum < maximum && maximum <= 100, "need 0 ≤ minimum < maximum ≤ 100")
        precondition(0 <= dimBelow && dimBelow < 1, "need 0 ≤ dimBelow < 1")
        self.minimum = minimum
        self.maximum = maximum
        self.dimBelow = dimBelow
    }

    /// The monitor value before rounding, within `minimum…maximum`.
    public func level(_ brightness: Double) -> Double {
        let fraction = brightness.isNaN ? 0 : min(max(brightness, 0), 1)
        return Double(minimum) + Double(maximum - minimum) * fraction
    }

    public func map(_ brightness: Double) -> Int {
        Int(level(brightness).rounded())
    }

    /// How much of the picture to show (0…1): full above `dimBelow`, in proportion below it.
    public func pictureLevel(_ brightness: Double) -> Double {
        guard dimBelow > 0, !brightness.isNaN, brightness < dimBelow else { return 1 }
        return max(Self.minimumPicture, brightness / dimBelow)
    }
}
