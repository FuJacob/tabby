import Foundation

/// File overview:
/// Sanitizes auxiliary prompt context that Cotabby did not get from the focused text field itself.
///
/// Clipboard text and OCR text can contain terminal separators, Markdown fences, shell prompts,
/// ANSI color escapes, and other prompt-shaped symbols. Those tokens are not useful semantic
/// context for autocomplete, and small local models can copy them back as output. Keeping this as
/// a pure `Support/` helper makes the policy deterministic, shared, and easy to test.
nonisolated enum PromptContextSanitizer {
    private static let ansiEscapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(.whitespacesAndNewlines)
        .union(CharacterSet(charactersIn: "@."))
    private static let replacementScalar = UnicodeScalar(" ")

    /// Returns prompt-safe context containing only letters, numbers, whitespace, `@`, and `.`.
    ///
    /// Disallowed scalars become spaces instead of being deleted. That preserves word boundaries:
    /// `raw-output` becomes `raw output`, not `rawoutput`. The final line pass collapses repeated
    /// whitespace so stripped punctuation cannot still dominate the prompt through spacing noise.
    static func sanitize(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let withoutANSIEscapes = rawText.replacingOccurrences(
            of: ansiEscapePattern,
            with: " ",
            options: .regularExpression
        )

        let sanitizedScalars = withoutANSIEscapes.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : replacementScalar
        }

        let sanitizedText = String(String.UnicodeScalarView(sanitizedScalars))
        let normalizedLines = sanitizedText
            .components(separatedBy: .newlines)
            .map { collapseInlineWhitespace(in: $0) }
            .filter { !$0.isEmpty }

        let normalizedText = normalizedLines.joined(separator: "\n")
        let boundedText = maxCharacters.map {
            String(normalizedText.prefix($0))
        } ?? normalizedText

        return boundedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stricter sanitization for OCR text headed to the prompt excerpt.
    ///
    /// OCR adds a second failure mode beyond ordinary prompt injection: Vision can hallucinate
    /// short mixed-case blobs, random alphanumeric IDs, repeated glyphs, and numeric UI chrome.
    /// Those fragments are especially harmful for autocomplete because the model may copy them as
    /// the next token. The line pass below keeps real prose and technical terms, but drops a line
    /// when most of its original tokens score as OCR noise.
    static func sanitizeOCR(_ rawText: String, maxCharacters: Int? = nil) -> String {
        let baseSanitized = sanitize(rawText, maxCharacters: nil)
        let filteredLines = baseSanitized
            .components(separatedBy: .newlines)
            .compactMap { filterOCRNoiseLine($0) }

        let joined = filteredLines.joined(separator: "\n")
        let bounded = maxCharacters.map { String(joined.prefix($0)) } ?? joined
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts normalized terms for clipboard and OCR relevance checks.
    ///
    /// Whitespace-delimited words work for Latin and Korean text, while Chinese/Japanese content does
    /// not reliably expose the same boundaries. Alongside general words and complete Hangul runs, we
    /// therefore emit overlapping two-character terms for Han and Katakana content. Hiragana-only
    /// grammar is deliberately excluded; relevance policy also requires multiple shared bigrams.
    static func significantTokens(from text: String, minimumLength: Int = 3) -> Set<String> {
        let normalized = normalizedForRelevance(text)
        var tokens = wordTokens(in: normalized, minimumLength: minimumLength)
        tokens.formUnion(cjkBigrams(in: normalized))
        return tokens
    }

    /// Precomputed terms let a selector compare many candidate lines without repeatedly tokenizing
    /// the same caret prefix on the main-actor request path.
    struct RelevanceTerms: Equatable, Sendable {
        let words: Set<String>
        let cjkBigrams: Set<String>
    }

    static func relevanceTerms(from text: String, minimumWordLength: Int = 3) -> RelevanceTerms {
        let normalized = normalizedForRelevance(text)
        return RelevanceTerms(
            words: wordTokens(in: normalized, minimumLength: minimumWordLength),
            cjkBigrams: cjkBigrams(in: normalized)
        )
    }

    /// Separates word and CJK evidence so source selectors can demand a stronger signal than one
    /// ubiquitous two-character fragment. Two shared CJK bigrams imply at least a shared three-
    /// character run (or two distinct terms), while one meaningful Latin/technical word is enough.
    struct RelevanceEvidence: Equatable, Sendable {
        let wordOverlapCount: Int
        let cjkBigramOverlapCount: Int

        var isMeaningful: Bool {
            wordOverlapCount > 0 || cjkBigramOverlapCount >= 2
        }

        var score: Int {
            wordOverlapCount * 3 + cjkBigramOverlapCount
        }
    }

    static func relevanceEvidence(
        between lhs: String,
        and rhs: String,
        minimumWordLength: Int = 3
    ) -> RelevanceEvidence {
        relevanceEvidence(
            between: relevanceTerms(from: lhs, minimumWordLength: minimumWordLength),
            and: relevanceTerms(from: rhs, minimumWordLength: minimumWordLength)
        )
    }

    static func relevanceEvidence(
        between lhs: RelevanceTerms,
        and rhs: RelevanceTerms
    ) -> RelevanceEvidence {
        RelevanceEvidence(
            wordOverlapCount: overlapCount(lhs.words, rhs.words),
            cjkBigramOverlapCount: overlapCount(lhs.cjkBigrams, rhs.cjkBigrams)
        )
    }

    private static func overlapCount(_ lhs: Set<String>, _ rhs: Set<String>) -> Int {
        let (smaller, larger) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        return smaller.reduce(into: 0) { count, term in
            if larger.contains(term) {
                count += 1
            }
        }
    }

    static func hasMeaningfulRelevance(between lhs: String, and rhs: String) -> Bool {
        relevanceEvidence(between: lhs, and: rhs).isMeaningful
    }

    private static func normalizedForRelevance(_ text: String) -> String {
        // Compatibility normalization folds full-width Latin/digits and visually-equivalent forms
        // before matching. This is especially useful for OCR and mixed CJK/ASCII clipboard text.
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    private static func wordTokens(in normalizedText: String, minimumLength: Int) -> Set<String> {
        enum RunKind: Equatable {
            case general
            case hangul
        }

        var words = Set<String>()
        var run = ""
        var runKind: RunKind?

        func commitRun() {
            let term = runKind == .hangul ? normalizedHangulWord(run) : run
            let requiredLength = runKind == .hangul ? 2 : minimumLength
            if term.count >= requiredLength, !relevanceStopWords.contains(term) {
                words.insert(term)
            }
            run = ""
            runKind = nil
        }

        for character in normalizedText {
            let nextKind: RunKind?
            if isHangul(character) {
                // Korean uses spaces between lexical words. Matching the complete run avoids treating
                // shared grammatical endings such as `합니다` as independent relevance evidence.
                nextKind = .hangul
            } else {
                let isAlphanumeric = character.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0)
                }
                nextKind = isAlphanumeric && !isCJK(character) ? .general : nil
            }

            guard let nextKind else {
                commitRun()
                continue
            }
            if let runKind, runKind != nextKind {
                commitRun()
            }
            runKind = nextKind
            run.append(character)
        }
        commitRun()
        return words
    }

    /// Reduces common Korean inflection/particle forms to the content-bearing stem before matching.
    /// This avoids privacy-sensitive false positives where unrelated sentences share only polite
    /// grammar such as `것입니다` or attached `합니다`, while retaining `배포`, `계획`, and `공유`.
    private static func normalizedHangulWord(_ word: String) -> String {
        var result = word
        for suffix in hangulVerbEndings where result.count >= suffix.count && result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
            break
        }
        for particle in hangulParticles where result.count >= particle.count && result.hasSuffix(particle) {
            result.removeLast(particle.count)
            break
        }
        return result
    }

    private static let hangulVerbEndings = [
        "겠습니다", "었습니다", "았습니다", "였습니다", "입니다", "습니다", "합니다", "됩니다"
    ]
    private static let hangulParticles = [
        "으로", "에서", "에게", "부터", "까지", "처럼", "보다",
        "은", "는", "이", "가", "을", "를", "에", "로", "와", "과", "도", "만"
    ]

    /// High-frequency connective words are poor evidence that two contexts describe the same task.
    /// Keeping this list intentionally small avoids turning relevance selection into a language model
    /// while preventing matches such as two unrelated English lines that merely share "the".
    private static let relevanceStopWords: Set<String> = [
        "and", "are", "for", "from", "has", "have", "into", "not", "that", "the",
        "then", "this", "was", "when", "will", "with", "you", "your"
    ]

    private static func cjkBigrams(in text: String) -> Set<String> {
        var terms = Set<String>()
        var run: [Character] = []

        func addTerms(for run: [Character]) {
            // One-character overlap is far too common to establish relevance in CJK prose. Requiring
            // a bigram still catches meaningful shared terms such as `发布` without matching every
            // unrelated sentence that happens to contain `的` or `会`.
            guard run.count >= 2 else { return }
            for index in 0..<(run.count - 1) {
                terms.insert(String([run[index], run[index + 1]]))
            }
        }

        for character in text {
            if isBigramContentCharacter(character) {
                run.append(character)
            } else {
                // Hiragana grammar and Hangul word endings are handled conservatively elsewhere;
                // neither participates in free-form sliding bigrams.
                addTerms(for: run)
                run.removeAll(keepingCapacity: true)
            }
        }
        addTerms(for: run)
        return terms
    }

    private static func isBigramContentCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30A0...0x30FF,   // Katakana
                 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
                 0x2A700...0x2EE5F, // CJK Unified Ideographs Extensions C-F and I
                 0x30000...0x3134F, // CJK Unified Ideographs Extension G
                 0x31350...0x323AF: // CJK Unified Ideographs Extension H
                return true
            default:
                return false
            }
        }
    }

    private static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0xAC00...0xD7AF).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0x3040...0x309F,   // Hiragana
                 0x30A0...0x30FF,   // Katakana
                 0xAC00...0xD7AF,   // Hangul syllables
                 0x1100...0x11FF,   // Hangul Jamo
                 0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
                 0x2A700...0x2EE5F, // CJK Unified Ideographs Extensions C-F and I
                 0x30000...0x3134F, // CJK Unified Ideographs Extension G
                 0x31350...0x323AF: // CJK Unified Ideographs Extension H
                return true
            default:
                return false
            }
        }
    }

    static func containsAlphanumericSignal(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Common 1-2 character English words that should survive OCR noise filtering.
    private static let preservedShortWords: Set<String> = [
        "a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he",
        "if", "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
        "to", "up", "us", "we"
    ]

    /// Short technical words and acronyms that are semantically valuable even though generic OCR
    /// filters would treat them as too short or vowel-free.
    private static let preservedTechnicalTokens: Set<String> = [
        "ai", "api", "app", "apps", "ax", "bug", "bugs", "ci", "cmd", "css",
        "dom", "git", "gpu", "html", "http", "id", "ids", "io", "json", "llm",
        "ocr", "pdf", "pr", "prs", "qa", "sql", "ui", "url", "ux", "xpc"
    ]

    private static let commonAcronyms: Set<String> = [
        "AI", "API", "AX", "CI", "CPU", "CSS", "DOM", "GPU", "HTML", "HTTP",
        "ID", "IO", "JSON", "LLM", "OCR", "PDF", "PR", "QA", "SQL", "UI",
        "URL", "UX", "XPC"
    ]

    private static let knownWordSignals = [
        "accept", "app", "autocomplete", "button", "chat", "chrome", "class",
        "code", "context", "cotabby", "document", "email", "error", "field",
        "file", "fix", "function", "github", "google", "issue", "jira", "linear",
        "message", "model", "notion", "pane", "prompt", "pull", "request",
        "safari", "screen", "setting", "slack", "summary", "swift", "task",
        "test", "token", "user", "view", "xcode"
    ]

    private struct OCRTokenAssessment {
        let shouldKeep: Bool
        let isStrongSignal: Bool
    }

    /// Filters a single OCR line with deterministic token scoring, then drops the entire line if
    /// fewer than half its original tokens survived.
    private static func filterOCRNoiseLine(_ line: String) -> String? {
        let tokens = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        let assessedTokens = tokens.map { token in
            (token: token, assessment: assessOCRToken(token))
        }
        let kept = assessedTokens
            .filter(\.assessment.shouldKeep)
            .map(\.token)

        // If more than half the tokens were noise, the whole line is probably UI chrome.
        guard kept.count * 2 >= tokens.count else { return nil }
        guard assessedTokens.contains(where: { $0.assessment.shouldKeep && $0.assessment.isStrongSignal }) else {
            return nil
        }

        let result = kept.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private static func assessOCRToken(_ token: String) -> OCRTokenAssessment {
        let lowercasedToken = token.lowercased()

        if token.allSatisfy(\.isNumber) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        if isEmailLikeToken(token) || isFileOrDomainLikeToken(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        if preservedTechnicalTokens.contains(lowercasedToken) || commonAcronyms.contains(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        if isRepeatedGlyphJunk(token) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        // Non-Latin scripts (CJK, Cyrillic, Greek, Arabic, Hebrew, Thai, ...) and accented Latin
        // (café, Zürich, naïve) carry real context but have no ASCII vowel and never match the
        // English word lists, so the Latin-tuned heuristics below would strip them to nothing and
        // leave non-English users with no visual context at all. Numbers and repeated-glyph junk
        // are already rejected above, so a token carrying genuine non-ASCII letters is real OCR
        // text: keep it as strong signal. (Splitting the Latin tail into its own helper also keeps
        // this function under the cyclomatic-complexity limit.)
        if containsNonASCIILetter(token) {
            return OCRTokenAssessment(shouldKeep: true, isStrongSignal: true)
        }

        return assessLatinToken(token, lowercased: lowercasedToken)
    }

    /// Scores an ASCII-only token. Reached only after `assessOCRToken` has handled numbers, emails,
    /// file/domain tokens, acronyms, repeated-glyph junk, and any token carrying non-ASCII letters.
    private static func assessLatinToken(_ token: String, lowercased lowercasedToken: String) -> OCRTokenAssessment {
        // A token this short can never be repeated-glyph junk (that needs >= 4 scalars), so the
        // earlier ordering relative to that check does not change the outcome.
        if token.count <= 2 {
            let shouldKeep = preservedShortWords.contains(lowercasedToken)
            return OCRTokenAssessment(shouldKeep: shouldKeep, isStrongSignal: false)
        }

        if containsLettersAndNumbers(token) {
            let hasKnownWord = containsKnownWordSignal(token)
            return OCRTokenAssessment(shouldKeep: hasKnownWord, isStrongSignal: hasKnownWord)
        }

        if isLikelyShortMixedCaseNoise(token) {
            return OCRTokenAssessment(shouldKeep: false, isStrongSignal: false)
        }

        let shouldKeep = hasWordSignal(token)
        return OCRTokenAssessment(shouldKeep: shouldKeep, isStrongSignal: shouldKeep)
    }

    /// True when the token carries a letter outside ASCII: CJK, Cyrillic, Greek, Arabic, Hebrew,
    /// Thai, Devanagari, accented Latin, and so on. ASCII letters stay on the Latin-tuned path.
    private static func containsNonASCIILetter(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            scalar.value > 127 && CharacterSet.letters.contains(scalar)
        }
    }

    private static func isEmailLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return containsLetter(String(parts[0])) && isFileOrDomainLikeToken(String(parts[1]))
    }

    private static func isFileOrDomainLikeToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.contains { containsLetter(String($0)) }
    }

    private static func containsLettersAndNumbers(_ token: String) -> Bool {
        containsLetter(token) && token.contains(where: \.isNumber)
    }

    private static func containsLetter(_ token: String) -> Bool {
        token.contains(where: \.isLetter)
    }

    private static func containsKnownWordSignal(_ token: String) -> Bool {
        let lowercasedToken = token.lowercased()
        return knownWordSignals.contains { lowercasedToken.contains($0) }
    }

    private static func hasWordSignal(_ token: String) -> Bool {
        guard containsLetter(token) else { return false }
        let lowercasedToken = token.lowercased()
        if containsKnownWordSignal(lowercasedToken) {
            return true
        }

        return lowercasedToken.unicodeScalars.contains { scalar in
            CharacterSet(charactersIn: "aeiouy").contains(scalar)
        }
    }

    private static func isRepeatedGlyphJunk(_ token: String) -> Bool {
        let scalars = token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard scalars.count >= 4 else { return false }

        var frequencies: [UnicodeScalar: Int] = [:]
        for scalar in scalars {
            frequencies[scalar, default: 0] += 1
        }

        let mostCommonCount = frequencies.values.max() ?? 0
        return mostCommonCount * 2 >= scalars.count
    }

    private static func isLikelyShortMixedCaseNoise(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter)
        guard token.count <= 12, letters.count >= 4 else { return false }

        let uppercaseCount = letters.filter(\.isUppercase).count
        let lowercaseCount = letters.filter(\.isLowercase).count
        guard uppercaseCount > 0, lowercaseCount > 0 else { return false }

        if containsKnownWordSignal(token) {
            return false
        }

        // A single leading capital is normal prose ("Safari", "Cotabby"). Multiple capitals in
        // a short token without a known technical word is usually OCR garbage ("gLVWrt", "bDokE").
        let firstCharacterIsUppercase = letters.first?.isUppercase == true
        if firstCharacterIsUppercase && uppercaseCount == 1 {
            return false
        }

        return uppercaseCount >= 2 || !firstCharacterIsUppercase
    }

    private static func collapseInlineWhitespace(in line: String) -> String {
        let normalized = line.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
