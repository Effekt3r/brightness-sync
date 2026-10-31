/// Command-line options: `brightness-sync [--min N] [--max N] [--dim-below F] [--verbose]`.
public struct Options: Equatable, Sendable {
    public static let usage =
        "usage: brightness-sync [--min N] [--max N] [--dim-below F] [--verbose]  (0 ≤ min < max ≤ 100, 0 ≤ F < 1)"

    public var minimum = 0
    public var maximum = 100
    public var dimBelow = 0.15
    public var verbose = false
    public var showHelp = false

    /// Parses the arguments that follow the program name.
    public init(arguments: [String]) throws(OptionsError) {
        var remaining = arguments.makeIterator()
        while let argument = remaining.next() {
            switch argument {
            case "--min": minimum = try Self.number(for: argument, remaining.next())
            case "--max": maximum = try Self.number(for: argument, remaining.next())
            case "--dim-below": dimBelow = try Self.fraction(for: argument, remaining.next())
            case "--verbose": verbose = true
            case "-h", "--help": showHelp = true
            default: throw OptionsError("unknown argument \(argument)")
            }
        }
        guard 0 <= minimum, minimum < maximum, maximum <= 100 else {
            throw OptionsError("need 0 ≤ min < max ≤ 100, got min \(minimum) and max \(maximum)")
        }
        guard 0 <= dimBelow, dimBelow < 1 else {
            throw OptionsError("need 0 ≤ dim-below < 1, got \(dimBelow)")
        }
    }

    private static func number(for flag: String, _ value: String?) throws(OptionsError) -> Int {
        guard let value, let number = Int(value) else { throw OptionsError("\(flag) needs a whole number") }
        return number
    }

    private static func fraction(for flag: String, _ value: String?) throws(OptionsError) -> Double {
        guard let value, let number = Double(value), number.isFinite else { throw OptionsError("\(flag) needs a number") }
        return number
    }
}

public struct OptionsError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}
