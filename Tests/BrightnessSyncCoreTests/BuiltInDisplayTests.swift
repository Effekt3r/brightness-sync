import Testing
@testable import BrightnessSyncCore

struct BuiltInDisplayTests {
    @Test func linearBrightnessIsScaledToItsValueAtFullSlider() {
        #expect(BuiltInDisplay.relativeOutput(linear: 2.0 / 3.0) == 1)
        #expect(abs(BuiltInDisplay.relativeOutput(linear: 0.23333333) - 0.35) < 0.0001)  // half slider
        #expect(BuiltInDisplay.relativeOutput(linear: 0) == 0)
    }

    @Test func outputAboveFullSliderIsClamped() {
        #expect(BuiltInDisplay.relativeOutput(linear: 0.9) == 1)
    }
}
