import Testing
@testable import BrightnessSyncCore

struct OptionsTests {
    @Test func defaults() throws {
        let options = try Options(arguments: [])
        #expect(options.minimum == 0)
        #expect(options.maximum == 100)
        #expect(!options.verbose)
        #expect(!options.showHelp)
    }

    @Test func parsesEveryFlag() throws {
        let options = try Options(arguments: ["--min", "10", "--max", "90", "--verbose"])
        #expect(options.minimum == 10)
        #expect(options.maximum == 90)
        #expect(options.verbose)
    }

    @Test func help() throws {
        #expect(try Options(arguments: ["--help"]).showHelp)
        #expect(try Options(arguments: ["-h"]).showHelp)
    }

    @Test(arguments: [
        ["--min"],
        ["--max", "abc"],
        ["--min", "-1"],
        ["--max", "101"],
        ["--min", "50", "--max", "50"],
        ["--brightness", "5"],
    ])
    func rejectsInvalidArguments(arguments: [String]) {
        #expect(throws: OptionsError.self) { try Options(arguments: arguments) }
    }
}
