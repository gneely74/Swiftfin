//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

struct ContentFilterSubtitleItem: Identifiable, Equatable, Hashable {
    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    var startDuration: Duration {
        .seconds(startSeconds)
    }

    var endDuration: Duration {
        .seconds(endSeconds)
    }
}

enum ContentFilterSRTParser {

    static func parse(srt: String) -> [ContentFilterSubtitleItem] {
        let normalized = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        var items: [ContentFilterSubtitleItem] = []

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard lines.count >= 2 else { continue }

            let timecodeLine: String
            let textLines: [String]
            let idValue: Int

            if lines[0].contains("-->") {
                timecodeLine = lines[0]
                textLines = Array(lines.dropFirst())
                idValue = items.count + 1
            } else {
                timecodeLine = lines[1]
                textLines = Array(lines.dropFirst(2))
                idValue = Int(lines[0]) ?? (items.count + 1)
            }

            guard timecodeLine.contains("-->") else { continue }

            let arrowParts = timecodeLine.components(separatedBy: "-->")
            guard arrowParts.count == 2 else { continue }

            let startStr = arrowParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let endStr = arrowParts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            let startSeconds = ContentFilterCue.parseTimestamp(startStr)
            let endSeconds = ContentFilterCue.parseTimestamp(endStr)

            guard endSeconds > startSeconds else { continue }

            let rawText = textLines.joined(separator: "\n")
            let cleanText = stripFormatting(rawText)

            guard !cleanText.isEmpty else { continue }

            items.append(
                ContentFilterSubtitleItem(
                    id: idValue,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds,
                    text: cleanText
                )
            )
        }

        return items.sorted(by: { $0.startSeconds < $1.startSeconds })
    }

    private static func stripFormatting(_ text: String) -> String {
        // Strip HTML/WebVTT styling tags (e.g. <i>, </i>, <font ...>, </font>, {y:i})
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\{[^\\}]+\\}", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
