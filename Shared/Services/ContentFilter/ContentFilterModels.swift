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
    let year: Int?
    let imdbUrl: String?
    let cues: [ContentFilterCue]
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
