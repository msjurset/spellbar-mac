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

    @MainActor
    func testHighConfidenceSuggestionOnCommonTypos() {
        let engine = SpellEngine.shared

        let teh = engine.analyze("teh")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: teh), "the")

        let titleTeh = engine.analyze("Teh")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: titleTeh), "The")

        let def = engine.analyze("definately")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: def), "definitely")

        let sep = engine.analyze("seperate")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: sep), "separate")

        let spel = engine.analyze("speling")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: spel), "spelling")

        let dmg = engine.analyze("damged")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: dmg), "damaged")

        let pkg = engine.analyze("pakage")
        XCTAssertEqual(engine.highConfidenceSuggestion(for: pkg), "package")
    }

    @MainActor
    func testHighConfidenceSuggestionRejectsUnsafeTokens() {
        let engine = SpellEngine.shared

        // Short words (< 3 chars)
        let shortWord = engine.analyze("am")
        XCTAssertNil(engine.highConfidenceSuggestion(for: shortWord))

        // All-caps acronyms
        let acronym = engine.analyze("API")
        XCTAssertNil(engine.highConfidenceSuggestion(for: acronym))

        // camelCase identifiers
        let camel = engine.analyze("myVar")
        XCTAssertNil(engine.highConfidenceSuggestion(for: camel))

        // Flags and symbols
        let flag = engine.analyze("--verbose")
        XCTAssertNil(engine.highConfidenceSuggestion(for: flag))
    }

    func testBatchFixSummaryModel() {
        let item1 = BatchFixSummary(from: "teh", to: "the")
        let item2 = BatchFixSummary(from: "teh", to: "the")
        let item3 = BatchFixSummary(from: "definately", to: "definitely")

        XCTAssertEqual(item1, item2)
        XCTAssertNotEqual(item1, item3)
        XCTAssertEqual(item1.from, "teh")
        XCTAssertEqual(item1.to, "the")
    }
}

