import XCTest
@testable import SpellBarLib

final class SpellBarTests: XCTestCase {
    func testSplitTriviaPreservesLeadingAndTrailingSpaces() {
        let engine = SpellEngine.shared
        let res = engine.splitTrivia("  recieve, ")
        XCTAssertEqual(res.leading, "  ")
        XCTAssertEqual(res.core, "recieve")
        XCTAssertEqual(res.trailing, ", ")
    }

    @MainActor
    func testAnalyzeCommonTyposAndCasing() {
        let engine = SpellEngine.shared

        let lower = engine.analyze("teh")
        XCTAssertTrue(lower.isMisspelled)
        XCTAssertEqual(lower.suggestions.first, "the")

        let title = engine.analyze("Teh ")
        XCTAssertEqual(title.suggestions.first, "The")
        XCTAssertEqual(title.formattedReplacement(using: title.suggestions[0]), "The ")

        let upper = engine.analyze("DEFINATELY")
        XCTAssertEqual(upper.suggestions.first, "DEFINITELY")
    }

    func testEditDistanceAndTranspositionRanking() {
        let engine = SpellEngine.shared
        // "hte" is 1 transposition away from "the"
        XCTAssertEqual(engine.editDistance("hte", "the"), 1)

        let ranked = engine.rankGuesses(["hat", "the", "heated"], original: "hte")
        XCTAssertEqual(ranked.first, "the")
    }

    @MainActor
    func testSpellBarStateCycling() {
        let state = SpellBarState()
        let analysis = WordAnalysis(
            originalRaw: "definately",
            leadingTrivia: "",
            coreWord: "definately",
            trailingTrivia: "",
            isMisspelled: true,
            suggestions: ["definitely", "defiantly", "definite"]
        )
        state.mode = .suggestions(analysis)
        XCTAssertEqual(state.activeIndex, 0)

        state.advanceHighlight(forward: true)
        XCTAssertEqual(state.activeIndex, 1)

        state.advanceHighlight(forward: true)
        XCTAssertEqual(state.activeIndex, 2)

        state.advanceHighlight(forward: true)
        XCTAssertEqual(state.activeIndex, 0)

        state.advanceHighlight(forward: false)
        XCTAssertEqual(state.activeIndex, 2)
    }

    @MainActor
    func testMultiWordSelectionIsolatesMisspelledWord() {
        let engine = SpellEngine.shared
        let analysis = engine.analyze("preceding definately.")
        XCTAssertTrue(analysis.isMisspelled)
        XCTAssertEqual(analysis.leadingTrivia, "preceding ")
        XCTAssertEqual(analysis.coreWord, "definately")
        XCTAssertEqual(analysis.trailingTrivia, ".")
        XCTAssertEqual(analysis.suggestions.first, "definitely")
        XCTAssertEqual(analysis.formattedReplacement(using: "definitely"), "preceding definitely.")
    }
}
