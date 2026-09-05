//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

struct ContentFilterResponse: Codable, Equatable {
    let title: String?
    let year: String?
    let imdbUrl: String?
    let cues: [ContentFilterCue]

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

    init(title: String? = nil, year: String? = nil, imdbUrl: String? = nil, cues: [ContentFilterCue] = []) {
        self.title = title
        self.year = year
        self.imdbUrl = imdbUrl
        self.cues = cues
    }

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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(imdbUrl, forKey: .imdbUrl)
        try container.encode(cues, forKey: .cues)
    }
}

struct ContentFilterCue: Codable, Identifiable, Equatable, Hashable {
    let key: String
    let start: String
    let end: String
    let description: String?
    let category: String
    let channel: String
    let action: String
    let enabled: Bool

    var id: String {
        key
    }

    var isMute: Bool {
        action.caseInsensitiveCompare("mute") == .orderedSame ||
            (action.caseInsensitiveCompare("skip") == .orderedSame && channel.caseInsensitiveCompare("audio") == .orderedSame)
    }

    var isSkip: Bool {
        action.caseInsensitiveCompare("skip") == .orderedSame && channel.caseInsensitiveCompare("audio") != .orderedSame
    }

    var startSeconds: Double {
        Self.parseTimestamp(start)
    }

    var endSeconds: Double {
        Self.parseTimestamp(end)
    }

    var startDuration: Duration {
        .seconds(startSeconds)
    }

    var endDuration: Duration {
        .seconds(endSeconds)
    }

    var duration: Duration {
        .seconds(max(0, endSeconds - startSeconds))
    }

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
