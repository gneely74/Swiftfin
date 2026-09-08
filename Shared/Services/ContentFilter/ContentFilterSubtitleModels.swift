//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Represents a parsed dialogue subtitle cue extracted from a clean sidecar `.srt` file.
///
/// Used by `ContentFilterSubtitleOverlay` to render filtered dialogue during audio mutes.
struct ContentFilterSubtitleItem: Identifiable, Equatable, Hashable {

    /// Numerical sequence identifier for the subtitle block.
    let id: Int

    /// Start timestamp of this subtitle line in floating-point seconds.
    let startSeconds: Double

    /// End timestamp of this subtitle line in floating-point seconds.
    let endSeconds: Double

    /// The cleaned dialogue text to display (with HTML and styling tags stripped).
    let text: String

    /// Start time represented as a native Swift `Duration`.
    var startDuration: Duration {
        .seconds(startSeconds)
    }

    /// End time represented as a native Swift `Duration`.
    var endDuration: Duration {
        .seconds(endSeconds)
    }
}

/// Parser utility for converting SubRip (`.srt`) subtitle text into structured `ContentFilterSubtitleItem` models.
enum ContentFilterSRTParser {

    /// Parses the raw string contents of an SRT file into an array of chronologically sorted subtitle items.
    ///
    /// Handles standard SRT blocks:
    /// ```text
    /// 1
    /// 00:01:20,000 --> 00:01:23,500
    /// Dialogue text here.
    /// ```
    /// Also supports formats where the numerical index line is omitted or merged, and normalizes
    /// Windows (`\r\n`), legacy Mac (`\r`), and Unix (`\n`) line endings.
    ///
    /// - Parameter srt: Raw SubRip subtitle file text.
    /// - Returns: An array of `ContentFilterSubtitleItem` instances sorted ascending by `startSeconds`.
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

    /// Strips HTML formatting tags (e.g. `<i>`, `</i>`, `<font color=...>`, `</font>`) and
    /// WebVTT/ASS override curly brace tags (e.g. `{y:i}`, `{\an8}`) from subtitle text.
    ///
    /// - Parameter text: Raw subtitle text containing markup.
    /// - Returns: Clean plain-text dialogue.
    private static func stripFormatting(_ text: String) -> String {
        // Strip HTML/WebVTT styling tags (e.g. <i>, </i>, <font ...>, </font>)
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Strip ASS/SSA curly-brace override tags (e.g. {\an8})
        result = result.replacingOccurrences(of: "\\{[^\\}]+\\}", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
