import AppKit
import Foundation

public struct WordAnalysis: Equatable, Sendable {
    public let originalRaw: String
    public let leadingTrivia: String
    public let coreWord: String
    public let trailingTrivia: String
    public let isMisspelled: Bool
    public let suggestions: [String]

    public init(
        originalRaw: String,
        leadingTrivia: String,
        coreWord: String,
        trailingTrivia: String,
        isMisspelled: Bool,
        suggestions: [String]
    ) {
        self.originalRaw = originalRaw
        self.leadingTrivia = leadingTrivia
        self.coreWord = coreWord
        self.trailingTrivia = trailingTrivia
        self.isMisspelled = isMisspelled
        self.suggestions = suggestions
    }

    /// Reconstructs the full string with leading/trailing whitespace or punctuation preserved.
    public func formattedReplacement(using suggestion: String) -> String {
        return leadingTrivia + suggestion + trailingTrivia
    }
}

public final class SpellEngine {
    public static let shared = SpellEngine()

    private let commonTypos: [String: String] = [
        "teh": "the",
        "hte": "the",
        "adn": "and",
        "nad": "and",
        "taht": "that",
        "tath": "that",
        "wiht": "with",
        "wtih": "with",
        "recieve": "receive",
        "recieved": "received",
        "recieving": "receiving",
        "seperate": "separate",
        "seperated": "separated",
        "definately": "definitely",
        "definatly": "definitely",
        "occured": "occurred",
        "occuring": "occurring",
        "occurence": "occurrence",
        "untill": "until",
        "whil": "while",
        "wich": "which",
        "wierd": "weird",
        "accomodate": "accommodate",
        "enviroment": "environment",
        "mispell": "misspell",
        "mispelled": "misspelled",
        "mispelling": "misspelling",
        "calender": "calendar",
        "tommorow": "tomorrow",
        "tomorow": "tomorrow",
        "adress": "address",
        "neccessary": "necessary",
        "necesary": "necessary",
        "priviledge": "privilege",
        "occassion": "occasion",
        "acheive": "achieve",
        "beleive": "believe",
        "collegue": "colleague",
        "concious": "conscious",
        "disapoint": "disappoint",
        "embarass": "embarrass",
        "existance": "existence",
        "foriegn": "foreign",
        "freind": "friend",
        "goverment": "government",
        "immediatly": "immediately",
        "independant": "independent",
        "knowlege": "knowledge",
        "maintainance": "maintenance",
        "noticable": "noticeable",
        "persistant": "persistent",
        "posession": "possession",
        "prefered": "preferred",
        "recomend": "recommend",
        "recomended": "recommended",
        "refered": "referred",
        "religous": "religious",
        "resistence": "resistance",
        "succesful": "successful",
        "successfull": "successful",
        "suprise": "surprise",
        "suprised": "surprised",
        "tendancy": "tendency",
        "therefor": "therefore",
        "threshhold": "threshold",
        "truely": "truly",
        "unforseen": "unforeseen",
        "unfortunatly": "unfortunately",
        "coudl": "could",
        "shoudl": "should",
        "woudl": "would",
        "becuase": "because",
        "beacuse": "because",
        "thta": "that",
        "waht": "what",
        "ahve": "have",
        "jsut": "just",
        "knwo": "know",
        "firts": "first",
        "abotu": "about",
        "speling": "spelling",
        "pakage": "package",
        "damged": "damaged",
        "mesage": "message",
        "sentance": "sentence",
        "problme": "problem",
        "importnat": "important",
        "diferent": "different",
        "exmaple": "example",
        "langauge": "language",
        "thier": "their",
        "verison": "version",
        "fucntion": "function",
        "retunr": "return",
        "chagne": "change",
        "udpate": "update",
        "delte": "delete",
        "creaet": "create",
        "reponse": "response",
        "requset": "request",
        "paragrapsh": "paragraphs"
    ]

    public init() {}

    /// Extracts all word token ranges from `raw`.
    public func wordRanges(in raw: String) -> [Range<String.Index>] {
        let wordChars = CharacterSet.letters.union(CharacterSet(charactersIn: "'’"))
        var ranges: [Range<String.Index>] = []
        var idx = raw.startIndex

        while idx < raw.endIndex {
            while idx < raw.endIndex,
                  let scalar = raw[idx].unicodeScalars.first,
                  !wordChars.contains(scalar) {
                idx = raw.index(after: idx)
            }
            guard idx < raw.endIndex else { break }
            let start = idx
            while idx < raw.endIndex,
                  let scalar = raw[idx].unicodeScalars.first,
                  wordChars.contains(scalar) {
                idx = raw.index(after: idx)
            }
            ranges.append(start..<idx)
        }
        return ranges
    }

    /// Splits a raw selection into `(leadingTrivia, coreWord, trailingTrivia)`.
    /// If multiple words are present, selects the last word by default.
    public func splitTrivia(_ raw: String) -> (leading: String, core: String, trailing: String) {
        let ranges = wordRanges(in: raw)
        guard let targetRange = ranges.last else {
            return (raw, "", "")
        }
        let leading = String(raw[..<targetRange.lowerBound])
        let core = String(raw[targetRange])
        let trailing = String(raw[targetRange.upperBound...])
        return (leading, core, trailing)
    }

    /// Analyzes a raw word selection and produces ranked spelling suggestions.
    /// If multiple words were accidentally selected, automatically isolates the misspelled word.
    @MainActor
    public func analyze(_ rawText: String, maxSuggestions: Int = 5) -> WordAnalysis {
        let ranges = wordRanges(in: rawText)
        guard !ranges.isEmpty else {
            return WordAnalysis(
                originalRaw: rawText,
                leadingTrivia: rawText,
                coreWord: "",
                trailingTrivia: "",
                isMisspelled: false,
                suggestions: []
            )
        }

        let checker = NSSpellChecker.shared
        let language = checker.language()

        // Scan words from right to left to find the misspelled token
        var chosenRange = ranges.last!
        for r in ranges.reversed() {
            let token = String(rawText[r])
            let lowered = token.lowercased()
            let miss = checker.checkSpelling(of: token, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location != NSNotFound || commonTypos[lowered] != nil {
                chosenRange = r
                break
            }
        }

        let leading = String(rawText[..<chosenRange.lowerBound])
        let word = String(rawText[chosenRange])
        let trailing = String(rawText[chosenRange.upperBound...])

        let nsWord = word as NSString
        let fullRange = NSRange(location: 0, length: nsWord.length)

        let misspelledRange = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let lowered = word.lowercased()
        let knownTypo = commonTypos[lowered]
        let isMisspelled = (misspelledRange.location != NSNotFound) || (knownTypo != nil)

        var candidates: [String] = []

        // 1. High-confidence known typo dictionary
        if let directFix = knownTypo {
            candidates.append(applyCasing(of: word, to: directFix))
        }

        // 2. macOS top autocorrection candidate
        if let autoCorrection = checker.correction(forWordRange: fullRange, in: word, language: language, inSpellDocumentWithTag: 0) {
            candidates.append(applyCasing(of: word, to: autoCorrection))
        }

        // 3. macOS dictionary guesses ranked by transposition / edit similarity
        let rawGuesses = checker.guesses(forWordRange: fullRange, in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        let rankedGuesses = rankGuesses(rawGuesses, original: word)
        for guess in rankedGuesses {
            candidates.append(applyCasing(of: word, to: guess))
        }

        // 4. Fallback to completions only when the word is actually misspelled and guesses came back empty
        if isMisspelled && candidates.isEmpty {
            let completions = checker.completions(forPartialWordRange: fullRange, in: word, language: language, inSpellDocumentWithTag: 0) ?? []
            for comp in completions.prefix(maxSuggestions) {
                candidates.append(applyCasing(of: word, to: comp))
            }
        }

        // Deduplicate while preserving priority order and excluding identical word
        var seen = Set<String>()
        seen.insert(word.lowercased())
        var unique: [String] = []
        for c in candidates {
            let key = c.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(c)
                if unique.count >= maxSuggestions {
                    break
                }
            }
        }

        return WordAnalysis(
            originalRaw: rawText,
            leadingTrivia: leading,
            coreWord: word,
            trailingTrivia: trailing,
            isMisspelled: isMisspelled,
            suggestions: unique
        )
    }

    /// Matches the capitalization pattern of `original` onto `replacement`.
    public func applyCasing(of original: String, to replacement: String) -> String {
        guard !original.isEmpty, !replacement.isEmpty else { return replacement }

        let letters = original.filter { $0.isLetter }
        if letters.count > 1 && letters.allSatisfy({ $0.isUppercase }) {
            return replacement.uppercased()
        }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Ranks `NSSpellChecker` guesses so adjacent transpositions, same-first-letter, and minimal edit distances appear first.
    public func rankGuesses(_ guesses: [String], original: String) -> [String] {
        let origLower = original.lowercased()
        let origSorted = origLower.sorted()

        return guesses.enumerated().sorted { lhs, rhs in
            let a = lhs.element.lowercased()
            let b = rhs.element.lowercased()

            // Anagram / pure transposition match gets top priority
            let aIsAnagram = (a.sorted() == origSorted)
            let bIsAnagram = (b.sorted() == origSorted)
            if aIsAnagram != bIsAnagram {
                return aIsAnagram
            }

            let distA = editDistance(origLower, a)
            let distB = editDistance(origLower, b)
            if distA != distB {
                return distA < distB
            }

            // Same first character bonus
            let sameFirstA = (a.first == origLower.first)
            let sameFirstB = (b.first == origLower.first)
            if sameFirstA != sameFirstB {
                return sameFirstA
            }

            // Preserve NSSpellChecker's native ordering on ties
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Computes optimal string alignment (Damerau-Levenshtein) distance between two strings.
    public func editDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,      // deletion
                    dp[i][j - 1] + 1,      // insertion
                    dp[i - 1][j - 1] + cost // substitution
                )
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1) // transposition
                }
            }
        }
        return dp[m][n]
    }

    /// Determines whether an analyzed word qualifies for unattended batch auto-correction.
    /// Returns the replacement string if safe; nil if it looks like code, an acronym, or an unrecognizable token.
    public func highConfidenceSuggestion(for analysis: WordAnalysis) -> String? {
        guard analysis.isMisspelled else { return nil }
        let word = analysis.coreWord
        guard word.count >= 2 else { return nil }

        // Must only contain letters or apostrophes (skip flags, variables, snake_case, paths, and URLs)
        guard word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }

        // Skip CLI flags, snake_case, paths, and env vars where trivia attaches code symbols directly to the token
        let codeDelimiters = CharacterSet(charactersIn: "-_/$@#\\")
        if let lastLead = analysis.leadingTrivia.unicodeScalars.last, codeDelimiters.contains(lastLead) {
            return nil
        }
        if let firstTrail = analysis.trailingTrivia.unicodeScalars.first, codeDelimiters.contains(firstTrail) {
            return nil
        }

        let lowered = word.lowercased()

        // 1. Direct match in curated common typos dictionary (100% confidence)
        if let directFix = commonTypos[lowered] {
            return applyCasing(of: word, to: directFix)
        }

        guard word.count >= 3 else { return nil }

        // Must not be all-caps (skip acronyms like API, JSON, URL)
        let letters = word.filter { $0.isLetter }
        guard !letters.allSatisfy({ $0.isUppercase }) else { return nil }

        // Must not be camelCase / PascalCase with mid-word uppercase (e.g. "myVar", "iPhone")
        if letters.count > 1 {
            let tail = letters.dropFirst()
            if tail.contains(where: { $0.isUppercase }) && !letters.allSatisfy({ $0.isUppercase }) {
                return nil
            }
        }

        // 2. Check top ranked suggestion from NSSpellChecker + transposition ranker
        guard let bestGuess = analysis.suggestions.first else { return nil }
        let bestLower = bestGuess.lowercased()

        // Pure anagram / letter transposition of the same characters is always a high-confidence typo
        if bestLower.sorted() == lowered.sorted() {
            return bestGuess
        }

        let dist = editDistance(lowered, bestLower)

        let maxAllowedDistance: Int
        if word.count <= 3 {
            maxAllowedDistance = 1
        } else if word.count <= 6 {
            maxAllowedDistance = 2
        } else {
            maxAllowedDistance = 3
        }

        if dist <= maxAllowedDistance {
            return bestGuess
        }

        return nil
    }
}

