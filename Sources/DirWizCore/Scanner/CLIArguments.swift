import Foundation

/// Parsed CLI arguments for dirwiz-cli subcommands.
/// Pure logic, kept in DirWizCore so the test target can exercise it.
public struct CLIArguments: Sendable {
    public let positionals: [String]
    public let flags: Set<String>
    public let values: [String: String]

    /// Flags that consume the following token as a value.
    public static let valueFlags: Set<String> = ["--min-size", "--max-depth", "--iterations"]

    public init(_ args: [String], valueFlags: Set<String> = CLIArguments.valueFlags) {
        var positionals: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        var i = 0
        while i < args.count {
            let token = args[i]
            if valueFlags.contains(token) {
                if i + 1 < args.count {
                    values[token] = args[i + 1]
                    i += 2
                } else {
                    // Trailing value flag with nothing following: no value, and there is
                    // no next token to misconsume.
                    i += 1
                }
            } else if token.hasPrefix("-") {
                flags.insert(token)
                i += 1
            } else {
                positionals.append(token)
                i += 1
            }
        }

        self.positionals = positionals
        self.flags = flags
        self.values = values
    }

    public var path: String? { positionals.first }
    public func uint64(_ flag: String) -> UInt64? { values[flag].flatMap(UInt64.init) }
    public func int(_ flag: String) -> Int? { values[flag].flatMap(Int.init) }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }
}

/// Replace C0/C1 control bytes and DEL in a filename/path with U+FFFD so
/// hostile names cannot inject terminal escape sequences into stdout.
public func sanitizeForTerminal(_ s: String) -> String {
    let replacement = Unicode.Scalar(0xFFFD)!
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(s.unicodeScalars.count)
    for scalar in s.unicodeScalars {
        let v = scalar.value
        let isControl = v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F)
        scalars.append(isControl ? replacement : scalar)
    }
    return String(scalars)
}
