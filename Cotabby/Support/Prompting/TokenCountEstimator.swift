import Foundation

/// File overview:
/// A pure, cheap estimate of how many model tokens a string occupies, used to budget the base-model
/// prompt more faithfully than a flat character count without paying for a real tokenizer on the
/// main-actor prompt path.
///
/// It is intentionally an approximation: Latin-like runs use roughly four characters per token,
/// while characters from scripts whose model tokenizers are commonly much denser (CJK, Hangul,
/// Thai, and neighboring space-less scripts) count individually. This is closer to the models Cotabby
/// ships than a global chars-per-token ratio while staying deterministic and tokenizer-free. It is not
/// exact, so it is used only for relative budgeting decisions, never to assert a hard token limit.
nonisolated enum TokenCountEstimator {
    static func estimate(_ text: String) -> Int {
        // Split on punctuation as well as whitespace: real subword tokenizers break "can't", "end.",
        // and "func()" into multiple tokens, so gluing punctuation to a word would systematically
        // undercount code and punctuation-heavy prose.
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard !words.isEmpty else {
            return 0
        }
        return words.reduce(0) { total, word in
            total + estimateWord(word)
        }
    }

    private static func estimateWord(_ word: Substring) -> Int {
        var denseScriptCharacters = 0
        var otherCharacters = 0
        for character in word {
            if character.isDenseTokenizerScript {
                denseScriptCharacters += 1
            } else {
                otherCharacters += 1
            }
        }

        let otherTokens = otherCharacters == 0
            ? 0
            : max(1, Int((Double(otherCharacters) / 4.0).rounded()))
        return denseScriptCharacters + otherTokens
    }
}

nonisolated private extension Character {
    /// Scripts where common llama/endpoint tokenizers are much closer to one token per character
    /// than the four-Latin-characters heuristic. Counting them individually is deliberately
    /// conservative so optional OCR/clipboard context cannot crowd the caret prefix out of KV.
    var isDenseTokenizerScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF,   // Hiragana + Katakana
                 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xF900...0xFAFF,   // CJK Compatibility Ideographs
                 0xAC00...0xD7A3,   // Hangul syllables
                 0x1100...0x11FF,   // Hangul Jamo
                 0x0E00...0x0E7F,   // Thai
                 0x0E80...0x0EFF,   // Lao
                 0x1780...0x17FF,   // Khmer
                 0x1000...0x109F,   // Myanmar
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
}
