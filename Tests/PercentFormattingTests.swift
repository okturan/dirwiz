import Testing
@testable import DirWizUI

@MainActor
@Suite("Percent Formatting Tests")
struct PercentFormattingTests {

    @Test("wholeNumberSharesUseOneDecimal")
    func wholeNumberSharesUseOneDecimal() {
        #expect(TreeRow.formatParentPercentage(1.0) == "100.0%")
        #expect(TreeRow.formatParentPercentage(0.622) == "62.2%")
    }

    @Test("tenPercentBoundaryTakesOneDecimalBranch")
    func tenPercentBoundaryTakesOneDecimalBranch() {
        // v == 10 exactly falls in the ">= 10" branch per the rule, not the
        // two-decimal branch below it.
        #expect(TreeRow.formatParentPercentage(0.10) == "10.0%")
    }

    @Test("justBelowTenPercentTakesTwoDecimalBranch")
    func justBelowTenPercentTakesTwoDecimalBranch() {
        #expect(TreeRow.formatParentPercentage(0.0999) == "9.99%")
    }

    @Test("twoDecimalBranchFormatsMidRangeShares")
    func twoDecimalBranchFormatsMidRangeShares() {
        #expect(TreeRow.formatParentPercentage(0.0442) == "4.42%")
        #expect(TreeRow.formatParentPercentage(0.0004) == "0.04%")
    }

    @Test("oneHundredthPercentBoundaryTakesTwoDecimalBranch")
    func oneHundredthPercentBoundaryTakesTwoDecimalBranch() {
        // v == 0.01 exactly falls in the "0.01 <= v" side of the rule, so it
        // still gets a real digit rather than the "<0.01%" placeholder.
        #expect(TreeRow.formatParentPercentage(0.0001) == "0.01%")
    }

    @Test("roundingBoundaryJustBelowOneHundredth")
    func roundingBoundaryJustBelowOneHundredth() {
        // v = 0.005 sits exactly at the raw midpoint, but 0.00005 * 100 lands
        // on a Double a hair above the true 0.005 (binary floating-point
        // representation), so `%.2f` rounds it up to "0.01" rather than down
        // to "0.00". Per the plan's rule (decide from the formatted string,
        // not the raw comparison), that pins this case to "0.01%".
        #expect(TreeRow.formatParentPercentage(0.00005) == "0.01%")
    }

    @Test("tinyShareBelowDisplayThresholdShowsPlaceholder")
    func tinyShareBelowDisplayThresholdShowsPlaceholder() {
        // e.g. a small file inside a much larger parent (2MB-in-500GB-style):
        // real but not worth a digit at two-decimal precision.
        #expect(TreeRow.formatParentPercentage(2e-6) == "<0.01%")
    }

    @Test("zeroShareShowsBareZeroPercent")
    func zeroShareShowsBareZeroPercent() {
        #expect(TreeRow.formatParentPercentage(0) == "0%")
    }
}
