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
        "son-of-a-bitch",
        "mother fucker",
        "mother-fucker",
        "mother fucking",
        "mother-fucking",
        "holy shit",
        "god damn",
        "god dammit",
        "jesus christ"
    ]

    /// Lexicon of root profanities, vulgarities, slurs, and their grammatical inflections.
    private static let profanityWords: [String] = [
        // General profanity
        "ass", "asses", "asshole", "assholes", "ass-hole", "ass-holes",
        "bastard", "bastards", "bitch", "bitches", "bitchy", "bitching",
        "bloody", "bollocks", "bugger", "buggers",
        "bullshit", "bullshits", "bull-shit", "crap", "craps", "cunt", "cunts",
        "damn", "damns", "damned", "dammit", "dick", "dicks", "dickhead", "dickheads",
        "dipshit", "dipshits", "douche", "douches", "douchebag", "douchebags",
        "fuck", "fucks", "fucking", "fucked", "fucker", "fuckers",
        "hell", "hellish", "horseshit", "jackass", "jackasses",
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

    /// Synchronization lock protecting dynamic updates to ``combinedRegex`` and ``serverWords``.
    private static let lock = NSLock()

    /// Additional filter terms synchronized from the Jellyfin server's global blanket word list.
    private static var serverWords: [String] = []

    /// Single precompiled, case-insensitive alternation regular expression sorted longest-first
    /// with word boundary assertions (`\\b`) for fast single-pass text scanning.
    private static var combinedRegex: NSRegularExpression? = buildCombinedRegex(extraWords: [])

    /// Builds a single alternation `NSRegularExpression` combining phrases, built-in words, and server-synced words.
    ///
    /// - Parameter extraWords: Additional terms fetched from the Jellyfin server.
    /// - Returns: A compiled case-insensitive `NSRegularExpression`, or `nil` if pattern compilation fails.
    private static func buildCombinedRegex(extraWords: [String]) -> NSRegularExpression? {
        let normalizedExtra = extraWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let allTerms = Array(Set(profanityPhrases + profanityWords + normalizedExtra))
            .sorted { $0.count > $1.count }

        guard !allTerms.isEmpty else { return nil }

        let alternation = allTerms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let pattern = "\\b(?:\(alternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    /// Merges server-configured global blanket words into the client-side masking regex.
    ///
    /// Safe to call from any thread; recompiles the alternation regex once when the word list changes.
    /// - Parameter words: Array of profanity/blanket words returned by the Jellyfin ContentFilter plugin.
    static func updateServerWords(_ words: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard words != serverWords else { return }
        serverWords = words
        combinedRegex = buildCombinedRegex(extraWords: words)
    }

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

    /// Scans an input string and redacts all instances of profanities and slurs using a single-pass
    /// word-boundary alternation regular expression.
    ///
    /// Preserves existing spacing, punctuation, and non-offensive text intact.
    ///
    /// - Parameter text: The raw text string to sanitize (or `nil`).
    /// - Returns: Sanitized string with all offensive tokens masked, or an empty string if `text` was `nil`/empty.
    static func mask(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }

        let regex: NSRegularExpression?
        lock.lock()
        regex = combinedRegex
        lock.unlock()

        guard let regex else { return text }

        var result = text
        let range = NSRange(result.startIndex ..< result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: range).reversed()

        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let matchedString = String(result[matchRange])
            let replacement = maskWord(matchedString)
            result.replaceSubrange(matchRange, with: replacement)
        }

        return result
    }
}
