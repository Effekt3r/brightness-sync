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
