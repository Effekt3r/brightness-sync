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
