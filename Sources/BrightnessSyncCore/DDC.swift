/// DDC/CI packets for reading and writing monitor settings (VESA "VCP" features).
///
/// A packet is what follows the host address (0x51) on the I²C bus: a length byte, an opcode, the
/// operands and a checksum. The transport sends the chip address (0x37) and the host address itself,
/// but the host address still counts towards the checksum.
public enum DDC {
    /// 7-bit I²C address of a monitor's DDC/CI interface.
    public static let chipAddress: UInt32 = 0x37
    /// Host ("source") address that precedes every packet the host sends.
    public static let hostAddress: UInt32 = 0x51
    /// VCP code for luminance (brightness).
    public static let brightness: UInt8 = 0x10

    /// A decoded "VCP feature reply".
    public struct Reply: Equatable, Sendable {
        public let current: UInt16
        public let maximum: UInt16

        public init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }
    }

    /// "Set VCP feature": length 0x84, opcode 0x03, code, value high byte, value low byte, checksum.
    public static func setPacket(code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// "Get VCP feature": length 0x82, opcode 0x01, code, checksum.
    public static func getPacket(code: UInt8) -> [UInt8] {
        withChecksum([0x82, 0x01, code])
    }

    /// Decodes the 11-byte reply to `getPacket(code:)`. Returns nil if the checksum is wrong, the
    /// monitor reported an error, or the reply is not a VCP reply for `code`.
    public static func parseReply(_ bytes: [UInt8], code: UInt8) -> Reply? {
        guard bytes.count == 11,
              bytes[0..<10].reduce(UInt8(0x50), ^) == bytes[10],  // replies are checksummed against 0x50
              bytes[1] == 0x88,  // length: 8 data bytes follow
              bytes[2] == 0x02,  // opcode: VCP feature reply
              bytes[3] == 0x00,  // result: no error
              bytes[4] == code
        else { return nil }
        return Reply(current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
                     maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
    }

    private static func withChecksum(_ payload: [UInt8]) -> [UInt8] {
        // The checksum also covers the monitor's 8-bit write address (0x6E) and the host address (0x51).
        payload + [payload.reduce(UInt8(0x6E ^ 0x51), ^)]
    }
}
