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

    @Test func levelIsTheUnroundedValue() {
        let mapper = BrightnessMapper(minimum: 10, maximum: 90)
        #expect(mapper.level(0.5) == 50)
        #expect(mapper.level(0.25) == 30)
        #expect(mapper.level(2) == 90)
    }

    @Test func clampsOutOfRangeInput() {
        let mapper = BrightnessMapper(minimum: 10, maximum: 90)
        #expect(mapper.map(-0.5) == 10)
        #expect(mapper.map(1.7) == 90)
        #expect(mapper.map(.nan) == 10)
    }

    @Test func pictureIsDimmedInProportionBelowTheThreshold() {
        let mapper = BrightnessMapper(dimBelow: 0.2)
        #expect(mapper.pictureLevel(0.5) == 1)
        #expect(mapper.pictureLevel(0.2) == 1)
        #expect(mapper.pictureLevel(0.1) == 0.5)
        #expect(mapper.pictureLevel(0.05) == 0.25)
    }

    @Test func pictureNeverGoesBlack() {
        let mapper = BrightnessMapper(dimBelow: 0.2)
        #expect(mapper.pictureLevel(0) == BrightnessMapper.minimumPicture)
        #expect(mapper.pictureLevel(-1) == BrightnessMapper.minimumPicture)
        #expect(mapper.pictureLevel(.nan) == 1)
    }

    @Test func zeroThresholdTurnsPictureDimmingOff() {
        #expect(BrightnessMapper(dimBelow: 0).pictureLevel(0) == 1)
    }
}
