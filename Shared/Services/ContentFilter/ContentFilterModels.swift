//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Top-level response container returned by the Jellyfin ContentFilter server endpoint
/// (`GET /ContentFilter/filters/{itemId}`).
///
/// Encapsulates metadata about the media item (title, year, IMDb URL) and an array
/// of all parsed filtering cues (`cues`).
///
/// - Note: Supports resilient JSON decoding for both camelCase and PascalCase keys to maintain
///   backward and forward compatibility across varying Jellyfin server plugin versions.
struct ContentFilterResponse: Codable, Equatable {

    /// The display title of the media item associated with this filter.
    let title: String?

    /// The release year of the media item (decoded as a string, tolerating numeric or string JSON values).
    let year: String?

    /// Optional web reference link to the IMDb title page.
    let imdbUrl: String?

    /// The collection of individual audio mute and visual scene skip cues.
    let cues: [ContentFilterCue]

    /// Resilient coding keys accommodating both PascalCase and camelCase property names from the server.
    private enum CodingKeys: String, CodingKey {
        case title
        case Title
        case year
        case Year
        case imdbUrl
        case ImdbUrl
        case imdbURL
        case cues
        case Cues
    }

    /// Initializes a new content filter response container.
    ///
    /// - Parameters:
    ///   - title: Optional title of the media item.
    ///   - year: Optional release year.
    ///   - imdbUrl: Optional IMDb URL.
    ///   - cues: Array of `ContentFilterCue` objects. Defaults to empty.
    init(title: String? = nil, year: String? = nil, imdbUrl: String? = nil, cues: [ContentFilterCue] = []) {
        self.title = title
        self.year = year
        self.imdbUrl = imdbUrl
        self.cues = cues
    }

    /// Decodes a `ContentFilterResponse` with resilient fallback handling for varying key casing and type representations.
    ///
    /// - Parameter decoder: The decoder to read data from.
    /// - Throws: `DecodingError` if the underlying JSON container cannot be parsed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.title = (try? container.decodeIfPresent(String.self, forKey: .title))
            ?? (try? container.decodeIfPresent(String.self, forKey: .Title))

        if let yearStr = (try? container.decodeIfPresent(String.self, forKey: .year)) ?? (try? container.decodeIfPresent(
            String.self,
            forKey: .Year
        )) {
            self.year = yearStr
        } else if let yearInt = (try? container.decodeIfPresent(Int.self, forKey: .year)) ?? (try? container.decodeIfPresent(
            Int.self,
            forKey: .Year
        )) {
            self.year = String(yearInt)
        } else {
            self.year = nil
        }

        self.imdbUrl = (try? container.decodeIfPresent(String.self, forKey: .imdbUrl))
            ?? (try? container.decodeIfPresent(String.self, forKey: .ImdbUrl))
            ?? (try? container.decodeIfPresent(String.self, forKey: .imdbURL))

        self.cues = (try? container.decodeIfPresent([ContentFilterCue].self, forKey: .cues))
            ?? (try? container.decodeIfPresent([ContentFilterCue].self, forKey: .Cues))
            ?? []
    }

    /// Encodes this response container to an external representation using canonical camelCase keys.
    ///
    /// - Parameter encoder: The encoder to write data to.
    /// - Throws: `EncodingError` if encoding fails.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(imdbUrl, forKey: .imdbUrl)
        try container.encode(cues, forKey: .cues)
    }
}

/// Represents an individual content filter cue specifying a time interval, target channel, and action.
///
/// A cue dictates either an **audio mute** (e.g. silencing profanity or crude dialogue) or a **scene skip**
/// (e.g. jumping over graphic violence, gore, or nudity).
struct ContentFilterCue: Codable, Identifiable, Equatable, Hashable {

    /// Unique identifier key for this cue.
    let key: String

    /// Raw start timestamp string as provided by the server (e.g. "00:01:23.450" or "83.45").
    let start: String

    /// Raw end timestamp string as provided by the server.
    let end: String

    /// Human-readable description, dialogue transcript, or profanity text associated with this cue.
    let description: String?

    /// Category classification (e.g. "Language", "Profanity", "Violence", "Nudity", "General").
    let category: String

    /// Media channel targeted by this cue ("audio", "video", or "both").
    let channel: String

    /// Action requested by this cue ("mute", "skip", or custom action).
    let action: String

    /// Whether this cue is actively enabled for filtering evaluation.
    let enabled: Bool

    /// Identifiable protocol conformance returning `key`.
    var id: String {
        key
    }

    /// Determines whether this cue represents an audio mute action.
    ///
    /// - Returns: `true` if the action is explicitly "mute", if it is an audio-channel "skip",
    ///   or if the category is classified as "Language" or "Profanity".
    var isMute: Bool {
        action.caseInsensitiveCompare("mute") == .orderedSame ||
            (action.caseInsensitiveCompare("skip") == .orderedSame && channel.caseInsensitiveCompare("audio") == .orderedSame) ||
            category.localizedCaseInsensitiveContains("Language") ||
            category.localizedCaseInsensitiveContains("Profanity")
    }

    /// Determines whether this cue represents a visual scene skip action.
    ///
    /// - Returns: `true` if the action is "skip", the channel is not strictly audio-only,
    ///   and the category is not language/profanity related.
    var isSkip: Bool {
        (action.caseInsensitiveCompare("skip") == .orderedSame && channel.caseInsensitiveCompare("audio") != .orderedSame) &&
            !category.localizedCaseInsensitiveContains("Language") &&
            !category.localizedCaseInsensitiveContains("Profanity")
    }

    /// Parsed start time of the cue converted to floating-point seconds.
    var startSeconds: Double {
        Self.parseTimestamp(start)
    }

    /// Parsed end time of the cue converted to floating-point seconds.
    var endSeconds: Double {
        Self.parseTimestamp(end)
    }

    /// Start time represented as a native Swift `Duration`.
    var startDuration: Duration {
        .seconds(startSeconds)
    }

    /// End time represented as a native Swift `Duration`.
    var endDuration: Duration {
        .seconds(endSeconds)
    }

    /// Total span of the cue as a native Swift `Duration`.
    var duration: Duration {
        .seconds(max(0, endSeconds - startSeconds))
    }

    /// Case-resilient coding keys supporting various JSON naming conventions.
    private enum CodingKeys: String, CodingKey {
        case key
        case Key
        case id
        case Id
        case ID
        case start
        case Start
        case end
        case End
        case description
        case Description
        case category
        case Category
        case channel
        case Channel
        case action
        case Action
        case enabled
        case Enabled
    }

    /// Initializes a new content filter cue.
    ///
    /// - Parameters:
    ///   - key: Unique cue identifier string.
    ///   - start: Start timestamp string.
    ///   - end: End timestamp string.
    ///   - description: Optional descriptive text or dialogue snippet.
    ///   - category: Category classification. Defaults to "General".
    ///   - channel: Target channel ("both", "audio", "video"). Defaults to "both".
    ///   - action: Action to perform ("mute", "skip"). Defaults to "mute".
    ///   - enabled: Whether the cue is active. Defaults to `true`.
    init(
        key: String,
        start: String,
        end: String,
        description: String? = nil,
        category: String = "General",
        channel: String = "both",
        action: String = "mute",
        enabled: Bool = true
    ) {
        self.key = key
        self.start = start
        self.end = end
        self.description = description
        self.category = category
        self.channel = channel
        self.action = action
        self.enabled = enabled
    }

    /// Decodes a `ContentFilterCue` with fallback strategies for multiple timestamp formats and key variations.
    ///
    /// - Parameter decoder: The decoder to read data from.
    /// - Throws: `DecodingError` if decoding cannot proceed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedStart: String = if let s = try? container.decode(String.self, forKey: .start) {
            s
        } else if let s = try? container.decode(String.self, forKey: .Start) {
            s
        } else if let d = try? container.decode(Double.self, forKey: .start) {
            String(d)
        } else if let d = try? container.decode(Double.self, forKey: .Start) {
            String(d)
        } else {
            "0"
        }
        self.start = decodedStart

        let decodedEnd: String = if let e = try? container.decode(String.self, forKey: .end) {
            e
        } else if let e = try? container.decode(String.self, forKey: .End) {
            e
        } else if let d = try? container.decode(Double.self, forKey: .end) {
            String(d)
        } else if let d = try? container.decode(Double.self, forKey: .End) {
            String(d)
        } else {
            "0"
        }
        self.end = decodedEnd

        self.category = (try? container.decode(String.self, forKey: .category))
            ?? (try? container.decode(String.self, forKey: .Category))
            ?? "General"

        self.key = (try? container.decode(String.self, forKey: .key))
            ?? (try? container.decode(String.self, forKey: .Key))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? "\(decodedStart)-\(decodedEnd)-\(self.category)"

        self.description = (try? container.decodeIfPresent(String.self, forKey: .description))
            ?? (try? container.decodeIfPresent(String.self, forKey: .Description))

        self.channel = (try? container.decode(String.self, forKey: .channel))
            ?? (try? container.decode(String.self, forKey: .Channel))
            ?? "both"

        self.action = (try? container.decode(String.self, forKey: .action))
            ?? (try? container.decode(String.self, forKey: .Action))
            ?? "mute"

        self.enabled = (try? container.decode(Bool.self, forKey: .enabled))
            ?? (try? container.decode(Bool.self, forKey: .Enabled))
            ?? true
    }

    /// Encodes this cue using canonical camelCase keys.
    ///
    /// - Parameter encoder: The encoder to write data to.
    /// - Throws: `EncodingError` if encoding fails.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(category, forKey: .category)
        try container.encode(channel, forKey: .channel)
        try container.encode(action, forKey: .action)
        try container.encode(enabled, forKey: .enabled)
    }

    /// Parses a timestamp string into total seconds as a `Double`.
    ///
    /// Supports the following formats:
    /// - Pure decimal seconds: `"123.456"` -> `123.456`
    /// - Full standard timecode: `"01:23:45,678"` or `"01:23:45.678"` -> `5025.678`
    /// - Minute:second timecode: `"23:45.678"` -> `1425.678`
    ///
    /// - Parameter timestamp: The raw string representation of the timestamp.
    /// - Returns: Total elapsed time in seconds, or `0` if parsing fails.
    static func parseTimestamp(_ timestamp: String) -> Double {
        let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pureSeconds = Double(trimmed) {
            return pureSeconds
        }
        let parts = trimmed.split(separator: ":")
        if parts.count == 3 {
            let h = Double(parts[0]) ?? 0
            let m = Double(parts[1]) ?? 0
            let sStr = parts[2].replacingOccurrences(of: ",", with: ".")
            let s = Double(sStr) ?? 0
            return (h * 3600) + (m * 60) + s
        } else if parts.count == 2 {
            let m = Double(parts[0]) ?? 0
            let sStr = parts[1].replacingOccurrences(of: ",", with: ".")
            let s = Double(sStr) ?? 0
            return (m * 60) + s
        } else if parts.count == 1 {
            let sStr = parts[0].replacingOccurrences(of: ",", with: ".")
            return Double(sStr) ?? 0
        }
        return 0
    }
}
