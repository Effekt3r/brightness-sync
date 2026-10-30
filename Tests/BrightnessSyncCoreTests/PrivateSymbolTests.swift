import Foundation
import Testing
@testable import BrightnessSyncCore

struct PrivateSymbolTests {
    private typealias GetPID = @convention(c) () -> Int32
    private let libSystem = "/usr/lib/libSystem.B.dylib"

    @Test func loadsAFunctionThatExists() throws {
        let getpid = try PrivateSymbol.load("getpid", from: libSystem, as: GetPID.self)
        #expect(getpid() == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func throwsForAMissingSymbol() {
        #expect(throws: MissingSymbol.self) {
            try PrivateSymbol.load("brightnessSyncNoSuchSymbol", from: libSystem, as: GetPID.self)
        }
    }
}
