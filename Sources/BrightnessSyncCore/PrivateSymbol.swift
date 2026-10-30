import Foundation

/// A C function from a system framework that ships without public headers, looked up at run time.
enum PrivateSymbol {
    static func load<Function>(_ name: String, from framework: String, as type: Function.Type) throws(MissingSymbol) -> Function {
        guard let handle = dlopen(framework, RTLD_NOW), let symbol = dlsym(handle, name) else {
            throw MissingSymbol(name: name)
        }
        return unsafeBitCast(symbol, to: type)
    }
}

public struct MissingSymbol: Error, CustomStringConvertible {
    public let name: String
    public var description: String { "missing private symbol \(name); this macOS version may have changed it" }
}
