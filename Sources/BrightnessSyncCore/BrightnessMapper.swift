/// Maps the built-in display's brightness (0…1) onto a slice of the monitor's 0…100 range.
public struct BrightnessMapper: Equatable, Sendable {
    public let minimum: Int
    public let maximum: Int

    public init(minimum: Int = 0, maximum: Int = 100) {
        precondition(0 <= minimum && minimum < maximum && maximum <= 100, "need 0 ≤ minimum < maximum ≤ 100")
        self.minimum = minimum
        self.maximum = maximum
    }

    /// The monitor value before rounding, within `minimum…maximum`.
    public func level(_ brightness: Double) -> Double {
        let fraction = brightness.isNaN ? 0 : min(max(brightness, 0), 1)
        return Double(minimum) + Double(maximum - minimum) * fraction
    }

    public func map(_ brightness: Double) -> Int {
        Int(level(brightness).rounded())
    }
}
