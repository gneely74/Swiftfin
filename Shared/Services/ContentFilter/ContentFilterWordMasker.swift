//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

enum ContentFilterWordMasker {

    private static let profanityPhrases: [String] = [
        "son of a bitch",
        "mother fucker",
        "mother fucking",
        "holy shit",
        "god damn",
        "god dammit",
        "jesus christ"
    ]

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

    /// Masks a word preserving its first character and replacing remaining characters with asterisks.
    /// Example: "fuck" -> "f***", "bastard" -> "b******", "son of a bitch" -> "s** o* a b****"
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

    /// Redacts all profanity and explicit words from the input text leaving the first letter of each word.
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
