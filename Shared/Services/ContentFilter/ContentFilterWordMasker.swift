//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Utility engine that redacts profanity, vulgarity, and offensive terms from text strings,
/// replacing all but the initial letter with asterisks (e.g. `"fuck"` -> `"f***"`).
///
/// Operates on cue descriptions in the supplement drawer and on subtitle overlays to ensure
/// no unmasked profanity is ever displayed to viewers.
enum ContentFilterWordMasker {

    /// Multi-word phrases that must be evaluated first to ensure longer compound matches
    /// take precedence over individual word tokens.
    private static let profanityPhrases: [String] = [
        "son of a bitch",
        "mother fucker",
        "mother fucking",
        "holy shit",
        "god damn",
        "god dammit",
        "jesus christ"
    ]

    /// Lexicon of root profanities, vulgarities, slurs, and their grammatical inflections.
    private static let profanityWords: [String] = [
        // General profanity
        "ass", "asses", "asshole", "assholes", "bastard", "bastards",
        "bitch", "bitches", "bitchy", "bloody", "bollocks", "bugger", "buggers",
        "bullshit", "bullshits", "crap", "craps", "cunt", "cunts",
        "damn", "damns", "dammit", "dick", "dicks", "dickhead", "dickheads",
        "dipshit", "dipshits", "douche", "douches", "douchebag", "douchebags",
        "fuck", "fucks", "fucking", "fucked", "fucker", "fuckers",
        "hell", "horseshit", "jackass", "jackasses",
        "motherfucker", "motherfuckers", "motherfucking",
        "piss", "pisses", "pissed", "pissing", "prick", "pricks",
        "shit", "shits", "shitty", "shitting", "shitted",
        "wank", "wanks", "wanker", "wankers",
        "cock", "cocks", "cocksucker", "cocksuckers",
        // Slurs & explicit
        "chink", "chinks", "cracker", "crackers",
        "fag", "fags", "faggot", "faggots",
        "kike", "kikes", "nigger", "niggers", "nigga", "niggas",
        "pussy", "pussies", "slut", "sluts", "whore", "whores",
        "tits", "titties", "vagina", "penis", "dildo"
    ]

    /// Precompiled, case-insensitive regular expressions with word boundary assertions (`\\b`)
    /// for fast text scanning. Multi-word phrases are ordered ahead of single words.
    private static let compiledRegexes: [NSRegularExpression] = {
        var expressions: [NSRegularExpression] = []

        // Multi-word phrases first (longer matches)
        for phrase in profanityPhrases {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                expressions.append(regex)
            }
        }

        // Single words
        for word in profanityWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                expressions.append(regex)
            }
        }

        return expressions
    }()

    /// Masks an individual word by preserving its initial character and replacing all remaining characters with asterisks.
    ///
    /// Examples:
    /// - `"fuck"` -> `"f***"`
    /// - `"bastard"` -> `"b******"`
    /// - `"son of a bitch"` -> `"s** o* a b****"`
    ///
    /// - Parameter word: The target string token to mask.
    /// - Returns: The masked string with identical length and preserved initial letter.
    static func maskWord(_ word: String) -> String {
        guard word.count > 1 else { return word }
        let words = word.components(separatedBy: " ")
        if words.count > 1 {
            return words.map { maskWord($0) }.joined(separator: " ")
        }
        let first = word.prefix(1)
        let asterisks = String(repeating: "*", count: word.count - 1)
        return "\(first)\(asterisks)"
    }

    /// Scans an input string and redacts all instances of profanities and slurs using word boundary regular expressions.
    ///
    /// Preserves existing spacing, punctuation, and non-offensive text intact.
    ///
    /// - Parameter text: The raw text string to sanitize (or `nil`).
    /// - Returns: Sanitized string with all offensive tokens masked, or an empty string if `text` was `nil`/empty.
    static func mask(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var result = text

        for regex in compiledRegexes {
            let range = NSRange(result.startIndex ..< result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()

            for match in matches {
                guard let matchRange = Range(match.range, in: result) else { continue }
                let matchedString = String(result[matchRange])
                let replacement = maskWord(matchedString)
                result.replaceSubrange(matchRange, with: replacement)
            }
        }

        return result
    }
}
