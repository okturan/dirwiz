import Testing
@testable import DirWizCore

@Suite("CLIArguments Tests")
struct CLIArgumentsTests {

    @Test("Value flag before path resolves the path correctly (regression: flag value must not be treated as path)")
    func valueFlagBeforePath() {
        let parsed = CLIArguments(["--min-size", "1000", "/Users/x"])
        #expect(parsed.path == "/Users/x")
        #expect(parsed.uint64("--min-size") == 1000)
    }

    @Test("Path-first order gives identical results")
    func pathFirstOrder() {
        let parsed = CLIArguments(["/Users/x", "--min-size", "1000"])
        #expect(parsed.path == "/Users/x")
        #expect(parsed.uint64("--min-size") == 1000)
    }

    @Test("Trailing value flag with no following token yields a nil value, path still correct")
    func trailingValueFlagNoValue() {
        let parsed = CLIArguments(["/Users/x", "--min-size"])
        #expect(parsed.path == "/Users/x")
        #expect(parsed.uint64("--min-size") == nil)
    }

    @Test("Non-numeric value yields nil, path still correct")
    func nonNumericValue() {
        let parsed = CLIArguments(["--min-size", "abc", "/p"])
        #expect(parsed.uint64("--min-size") == nil)
        #expect(parsed.path == "/p")
    }

    @Test("Boolean flags do not consume the following token as a value")
    func booleanFlagsDoNotConsumeValues() {
        let parsed = CLIArguments(["/Users/x", "--json", "-q"])
        #expect(parsed.path == "/Users/x")
        #expect(parsed.has("--json"))
        #expect(parsed.has("-q"))
        #expect(parsed.positionals == ["/Users/x"])
    }

    @Test("Multiple positionals: first wins as path")
    func multiplePositionalsFirstWins() {
        let parsed = CLIArguments(["/first", "/second"])
        #expect(parsed.path == "/first")
        #expect(parsed.positionals == ["/first", "/second"])
    }

    @Test("int() parses --iterations and --max-depth the same way as uint64() parses --min-size")
    func intFlagParsing() {
        let parsed = CLIArguments(["--iterations", "5", "/path"])
        #expect(parsed.int("--iterations") == 5)
        #expect(parsed.path == "/path")
    }
}

@Suite("sanitizeForTerminal Tests")
struct SanitizeForTerminalTests {

    @Test("Control bytes, DEL, and C1 codes are replaced with U+FFFD")
    func controlBytesReplaced() {
        #expect(sanitizeForTerminal("\u{1B}") == "\u{FFFD}")   // ESC
        #expect(sanitizeForTerminal("\u{07}") == "\u{FFFD}")   // BEL
        #expect(sanitizeForTerminal("\u{7F}") == "\u{FFFD}")   // DEL
        #expect(sanitizeForTerminal("\t") == "\u{FFFD}")       // tab
        #expect(sanitizeForTerminal("\n") == "\u{FFFD}")       // newline
        #expect(sanitizeForTerminal("\u{0085}") == "\u{FFFD}") // NEL, a C1 control code
    }

    @Test("OSC injection sequence has its control bytes neutralized")
    func oscSequenceNeutralized() {
        // ESC ] 0 ; pwned BEL — a terminal title-set OSC sequence.
        let payload = "evil\u{1B}]0;pwned\u{07}name"
        #expect(sanitizeForTerminal(payload) == "evil\u{FFFD}]0;pwned\u{FFFD}name")
    }

    @Test("Normal Unicode filename passes through unchanged")
    func normalUnicodePassesThrough() {
        let name = "résumé.pdf"
        #expect(sanitizeForTerminal(name) == name)
    }
}
