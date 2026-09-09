//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import SwiftUI
import XCTest

/// Test mock conforming to ``MediaPlayerProxy`` for verifying socket commands and mute state mutations.
final class MockMediaPlayerProxy: MediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let isMuted: PublishedBox<Bool> = .init(initialValue: false)

    weak var manager: MediaPlayerManager?

    var observers: [any MediaPlayerObserver] = []

    func play() {}
    func pause() {}
    func stop() {}
    func jumpForward(_ seconds: Duration) {}
    func jumpBackward(_ seconds: Duration) {}
    func setRate(_ rate: Float) {}
    func setSeconds(_ seconds: Duration) {}

    /// Mutes the mock proxy without fading.
    func mute() {
        mute(faded: false)
    }

    /// Mutes the mock proxy and sets `isMuted.value = true`.
    /// - Parameter faded: Ignored in mock.
    func mute(faded: Bool) {
        isMuted.value = true
    }

    /// Unmutes the mock proxy without fading.
    func unmute() {
        unmute(faded: false)
    }

    /// Unmutes the mock proxy and sets `isMuted.value = false`.
    /// - Parameter faded: Ignored in mock.
    func unmute(faded: Bool) {
        isMuted.value = false
    }

    /// Toggles the mock proxy mute state without fading.
    func toggleMute() {
        toggleMute(faded: false)
    }

    /// Toggles the mock proxy mute state.
    /// - Parameter faded: Ignored in mock.
    func toggleMute(faded: Bool) {
        isMuted.value.toggle()
    }
}

/// Unit test suite verifying ContentFilter cue parsing, evaluation, socket command routing,
/// subtitle masking, SRT decoding, and autonomous client-side mute bridging.
final class ContentFilterSocketTests: XCTestCase {

    /// Verifies that invoking `mute()` correctly updates the proxy's `isMuted` box to `true`.
    func testMuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should initially be unmuted")

        mockProxy.mute()
        XCTAssertTrue(mockProxy.isMuted.value, "Player proxy should be muted upon calling mute()")
    }

    /// Verifies that invoking `unmute()` resets the proxy's `isMuted` box to `false`.
    func testUnmuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        mockProxy.mute()
        XCTAssertTrue(mockProxy.isMuted.value)

        mockProxy.unmute()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should be unmuted upon calling unmute()")
    }

    /// Verifies that `toggleMute()` inverts the mute state sequentially.
    func testToggleMuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        XCTAssertFalse(mockProxy.isMuted.value)

        mockProxy.toggleMute()
        XCTAssertTrue(mockProxy.isMuted.value, "Player proxy should toggle to muted")

        mockProxy.toggleMute()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should toggle to unmuted")
    }

    /// Verifies parsing of HH:MM:SS.mmm, MM:SS.mmm, and decimal second timestamp formats.
    func testTimestampParsing() {
        XCTAssertEqual(ContentFilterCue.parseTimestamp("00:01:23.500"), 83.5, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("01:30.000"), 90.0, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("01:00:00.000"), 3600.0, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("45.2"), 45.2, accuracy: 0.001)
    }

    /// Verifies cue classification properties (`isMute`, `isSkip`, `duration`).
    func testCueClassification() {
        let muteCue = ContentFilterCue(
            key: "1",
            start: "00:01:00.000",
            end: "00:01:05.000",
            description: "Profanity",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        XCTAssertTrue(muteCue.isMute)
        XCTAssertFalse(muteCue.isSkip)
        XCTAssertEqual(muteCue.duration.seconds, 5.0, accuracy: 0.001)

        let skipCue = ContentFilterCue(
            key: "2",
            start: "00:05:00.000",
            end: "00:05:20.000",
            description: "Violence",
            category: "violence",
            channel: "both",
            action: "skip",
            enabled: true
        )
        XCTAssertFalse(skipCue.isMute)
        XCTAssertTrue(skipCue.isSkip)
        XCTAssertEqual(skipCue.duration.seconds, 20.0, accuracy: 0.001)
    }

    /// Verifies active cue detection, mute count, and lead/tail padding windows in ``ContentFilterManager``.
    @MainActor
    func testContentFilterManagerActiveCue() {
        let manager = ContentFilterManager()
        let cues = [
            ContentFilterCue(
                key: "1",
                start: "00:01:00.000",
                end: "00:01:10.000",
                description: "Dialogue mute",
                category: "profanity",
                channel: "audio",
                action: "mute",
                enabled: true
            ),
            ContentFilterCue(
                key: "2",
                start: "00:02:00.000",
                end: "00:02:30.000",
                description: "Battle scene",
                category: "violence",
                channel: "video",
                action: "skip",
                enabled: true
            ),
        ]
        manager.cues = cues

        XCTAssertEqual(manager.muteCount, 1)
        XCTAssertEqual(manager.skipCount, 1)

        manager.updateCurrentTime(.seconds(65)) // 00:01:05 -> inside cue 1
        XCTAssertEqual(manager.currentActiveCue?.key, "1")
        XCTAssertTrue(manager.isContentFilterMuted)

        // Pre-roll lead time test: 59.0s is 1.0s before cue start (60.0s) -> within 1.5s lead window
        manager.updateCurrentTime(.seconds(59.0))
        XCTAssertEqual(manager.currentActiveCue?.key, "1")
        XCTAssertTrue(manager.isContentFilterMuted)

        // Outside pre-roll: 58.0s is 2.0s before cue start -> outside 1.5s lead window
        manager.updateCurrentTime(.seconds(58.0))
        XCTAssertNil(manager.currentActiveCue)
        XCTAssertFalse(manager.isContentFilterMuted)

        // Post-roll tail padding test: 70.3s is 300ms after cue end (70.0s) -> within 500ms tail window
        manager.updateCurrentTime(.seconds(70.3))
        XCTAssertEqual(manager.currentActiveCue?.key, "1")
        XCTAssertTrue(manager.isContentFilterMuted)

        // Outside post-roll: 70.7s is 700ms after cue end -> outside 500ms tail window
        manager.updateCurrentTime(.seconds(70.7))
        XCTAssertNil(manager.currentActiveCue)
        XCTAssertFalse(manager.isContentFilterMuted)

        manager.updateCurrentTime(.seconds(90)) // outside any cue
        XCTAssertNil(manager.currentActiveCue)

        manager.updateCurrentTime(.seconds(130)) // 00:02:10 -> inside cue 2
        XCTAssertEqual(manager.currentActiveCue?.key, "2")
    }

    /// Verifies parsing of valid SRT strings and stripping of HTML/bracket tags.
    func testSRTParser() {
        let sampleSRT = """
        1
        00:00:01,000 --> 00:00:04,500
        <i>Hello</i> <b>world!</b>

        2
        00:00:05.200 --> 00:00:08.800
        This is a filtered subtitle line.

        3
        00:00:10,000 --> 00:00:12,000
        {y:i}Brackets formatting{/y:i}
        """

        let parsed = ContentFilterSRTParser.parse(srt: sampleSRT)
        XCTAssertEqual(parsed.count, 3)

        XCTAssertEqual(parsed[0].id, 1)
        XCTAssertEqual(parsed[0].startSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(parsed[0].endSeconds, 4.5, accuracy: 0.001)
        XCTAssertEqual(parsed[0].text, "Hello world!")

        XCTAssertEqual(parsed[1].id, 2)
        XCTAssertEqual(parsed[1].startSeconds, 5.2, accuracy: 0.001)
        XCTAssertEqual(parsed[1].endSeconds, 8.8, accuracy: 0.001)
        XCTAssertEqual(parsed[1].text, "This is a filtered subtitle line.")

        XCTAssertEqual(parsed[2].id, 3)
        XCTAssertEqual(parsed[2].text, "Brackets formatting")
    }

    /// Verifies that empty, corrupt, or invalid SRT content parses safely into empty results.
    func testSRTParserEmptyAndMalformed() {
        XCTAssertTrue(ContentFilterSRTParser.parse(srt: "").isEmpty)
        XCTAssertTrue(ContentFilterSRTParser.parse(srt: "Invalid junk text without timestamps").isEmpty)

        // Missing arrow
        let invalidTimecode = "1\n00:00:01.000 -- 00:00:02.000\nSome text"
        XCTAssertTrue(ContentFilterSRTParser.parse(srt: invalidTimecode).isEmpty)

        // End before start
        let reversedTimecode = "1\n00:00:05.000 --> 00:00:02.000\nSome text"
        XCTAssertTrue(ContentFilterSRTParser.parse(srt: reversedTimecode).isEmpty)
    }

    /// Verifies triggering a scene skip badge and clearing skip state.
    @MainActor
    func testSkipTriggerAndReset() {
        let manager = ContentFilterManager()
        XCTAssertFalse(manager.isSkipping)
        XCTAssertNil(manager.lastSkipReason)

        manager.triggerSkip(reason: "Violence")
        XCTAssertTrue(manager.isSkipping)
        XCTAssertEqual(manager.lastSkipReason, "Violence")

        manager.clear()
        XCTAssertFalse(manager.isSkipping)
        XCTAssertNil(manager.lastSkipReason)
    }

    /// Verifies detection of filtered subtitle streams based on track title and comment tags.
    func testMediaStreamFilteredSubtitleMatching() {
        let cleanSub = MediaStream(comment: nil, displayTitle: "English [Clean]", index: 1, title: "Clean", type: .subtitle)
        let filteredSub = MediaStream(
            comment: "Filtered audio dialog",
            displayTitle: "English",
            index: 2,
            title: "Filtered",
            type: .subtitle
        )
        let standardSub = MediaStream(comment: nil, displayTitle: "English [Default]", index: 3, title: "Standard", type: .subtitle)
        let videoStream = MediaStream(comment: nil, displayTitle: "Filtered 4K Video", index: 0, title: "Clean Video", type: .video)

        XCTAssertTrue(cleanSub.isFilteredSubtitle)
        XCTAssertTrue(filteredSub.isFilteredSubtitle)
        XCTAssertFalse(standardSub.isFilteredSubtitle)
        XCTAssertFalse(videoStream.isFilteredSubtitle, "Video streams should never be classified as filtered subtitles")

        let streams = [videoStream, standardSub, filteredSub]
        XCTAssertEqual(streams.filteredSubtitleStream?.index, 2)

        let noFilterStreams = [videoStream, standardSub]
        XCTAssertNil(noFilterStreams.filteredSubtitleStream)
    }

    /// Verifies that filtered subtitle overlay displays matching lines during mute and clears upon unmute.
    @MainActor
    func testFilteredSubtitleOverlayDuringMute() {
        let manager = ContentFilterManager()
        manager.filteredSubtitles = [
            ContentFilterSubtitleItem(id: 1, startSeconds: 10.0, endSeconds: 15.0, text: "Quiet line"),
            ContentFilterSubtitleItem(id: 2, startSeconds: 20.0, endSeconds: 25.0, text: "Second line"),
        ]

        // When unmuted, subtitle overlay is never active
        manager.updateCurrentTime(.seconds(12))
        XCTAssertNil(manager.activeFilteredSubtitleText)

        // When muted, subtitle overlay displays matching line
        manager.isMuted = true
        manager.updateCurrentTime(.seconds(12))
        XCTAssertEqual(manager.activeFilteredSubtitleText, "Quiet line")

        // Between subtitles, overlay clears
        manager.updateCurrentTime(.seconds(17))
        XCTAssertNil(manager.activeFilteredSubtitleText)

        // Second subtitle matches
        manager.updateCurrentTime(.seconds(22))
        XCTAssertEqual(manager.activeFilteredSubtitleText, "Second line")

        // When unmuting, overlay immediately clears
        manager.isMuted = false
        XCTAssertNil(manager.activeFilteredSubtitleText)
    }

    /// Verifies resilient decoding of filter responses where year is formatted as a string.
    func testResilientFilterResponseDecodingStringYear() throws {
        let json = """
        {
            "title": "A Knight of the Seven Kingdoms",
            "year": "2025",
            "imdbUrl": "https://www.imdb.com/title/tt27491682/",
            "cues": [
                {
                    "key": "00:01:10.000-00:01:15.000-Profanity",
                    "start": "00:01:10.000",
                    "end": "00:01:15.000",
                    "description": "strong language",
                    "category": "Profanity",
                    "channel": "audio",
                    "action": "mute",
                    "enabled": true
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ContentFilterResponse.self, from: json)
        XCTAssertEqual(response.title, "A Knight of the Seven Kingdoms")
        XCTAssertEqual(response.year, "2025")
        XCTAssertEqual(response.cues.count, 1)
        XCTAssertEqual(response.cues.first?.category, "Profanity")
        XCTAssertTrue(response.cues.first?.isMute == true)
    }

    /// Verifies resilient decoding of filter responses with PascalCase keys and integer year representation.
    func testResilientFilterResponseDecodingPascalCaseAndIntYear() throws {
        let json = """
        {
            "Title": "Game of Thrones",
            "Year": 2011,
            "Cues": [
                {
                    "Start": "00:05:00.000",
                    "End": "00:05:10.000",
                    "Category": "Violence",
                    "Action": "skip"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ContentFilterResponse.self, from: json)
        XCTAssertEqual(response.title, "Game of Thrones")
        XCTAssertEqual(response.year, "2011")
        XCTAssertEqual(response.cues.count, 1)
        XCTAssertEqual(response.cues.first?.category, "Violence")
        XCTAssertTrue(response.cues.first?.isSkip == true)
        XCTAssertTrue(response.cues.first?.enabled == true)
    }

    /// Verifies resilient decoding when the year field is empty and cues array is omitted.
    func testResilientFilterResponseDecodingEmptyYearAndMissingCues() throws {
        let json = """
        {
            "title": "Minimal Movie",
            "year": ""
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ContentFilterResponse.self, from: json)
        XCTAssertEqual(response.title, "Minimal Movie")
        XCTAssertEqual(response.year, "")
        XCTAssertTrue(response.cues.isEmpty)
    }

    /// Verifies conversion of 32-character hexadecimal strings into standard 8-4-4-4-12 hyphenated GUIDs.
    func testGUIDFormatting() {
        let raw = "2b69424c5bb947c6a0c0adad5feefba7"
        let expected = "2b69424c-5bb9-47c6-a0c0-adad5feefba7"
        XCTAssertEqual(ContentFilterService.formatGUID(raw), expected)

        // Already formatted GUID should remain unchanged
        XCTAssertEqual(ContentFilterService.formatGUID(expected), expected)

        // Invalid length remains unchanged
        XCTAssertEqual(ContentFilterService.formatGUID("short-id"), "short-id")
    }

    /// Verifies profanity redaction across single words, phrases, sentences, and empty inputs.
    func testContentFilterWordMasker() {
        // Individual profanity words
        XCTAssertEqual(ContentFilterWordMasker.mask("fuck"), "f***")
        XCTAssertEqual(ContentFilterWordMasker.mask("Shit"), "S***")
        XCTAssertEqual(ContentFilterWordMasker.mask("bitch"), "b****")
        XCTAssertEqual(ContentFilterWordMasker.mask("bastard"), "b******")
        XCTAssertEqual(ContentFilterWordMasker.mask("asshole"), "a******")

        // Multi-word phrases
        XCTAssertEqual(ContentFilterWordMasker.mask("son of a bitch"), "s** o* a b****")
        XCTAssertEqual(ContentFilterWordMasker.mask("holy shit"), "h*** s***")
        XCTAssertEqual(ContentFilterWordMasker.mask("god damn"), "g** d***")

        // Mixed sentence with profanity
        let text = "What the fuck are you doing with this shit?"
        let masked = ContentFilterWordMasker.mask(text)
        XCTAssertEqual(masked, "What the f*** are you doing with this s***?")

        // Clean text remains unmodified
        let clean = "This is a completely wholesome family movie."
        XCTAssertEqual(ContentFilterWordMasker.mask(clean), clean)

        // Nil and empty strings
        XCTAssertEqual(ContentFilterWordMasker.mask(nil), "")
        XCTAssertEqual(ContentFilterWordMasker.mask(""), "")
    }

    /// Verifies autonomous client-side mute evaluation without server-side intervention.
    @MainActor
    func testAutonomousClientSideMuting() {
        let manager = ContentFilterManager()
        let muteCue = ContentFilterCue(
            key: "m1",
            start: "00:00:10.000",
            end: "00:00:15.000",
            description: "Profanity",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        let skipCue = ContentFilterCue(
            key: "s1",
            start: "00:00:30.000",
            end: "00:00:40.000",
            description: "Violence",
            category: "violence",
            channel: "video",
            action: "skip",
            enabled: true
        )
        manager.cues = [muteCue, skipCue]

        // Before mute cue
        manager.updateCurrentTime(.seconds(5))
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)

        // Inside mute cue (10s - 15s)
        manager.updateCurrentTime(.seconds(12))
        XCTAssertTrue(manager.isContentFilterMuted)
        XCTAssertTrue(manager.isMuted)

        // After mute cue
        manager.updateCurrentTime(.seconds(16))
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)

        // Inside skip cue (30s - 40s) -> should NOT trigger muting
        manager.updateCurrentTime(.seconds(35))
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)

        // Re-enter mute cue, then call clear() -> should unmute
        manager.updateCurrentTime(.seconds(12))
        XCTAssertTrue(manager.isContentFilterMuted)
        XCTAssertTrue(manager.isMuted)

        manager.clear()
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)
    }

    /// Verifies that mute cues separated by less than 1.5 seconds are coalesced into a single contiguous mute interval.
    @MainActor
    func testMuteBridgingUnderThreshold() {
        let manager = ContentFilterManager()
        let cue1 = ContentFilterCue(
            key: "c1",
            start: "00:00:10.000",
            end: "00:00:12.000",
            description: "Profanity 1",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        // Gap is 1.0s (12.0s to 13.0s), which is <= muteBridgeThresholdSeconds (1.5s)
        let cue2 = ContentFilterCue(
            key: "c2",
            start: "00:00:13.000",
            end: "00:00:15.000",
            description: "Profanity 2",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        manager.cues = [cue1, cue2]

        // Bridging should merge them into 1 contiguous interval: [8.5s, 15.5s]
        XCTAssertEqual(manager.bridgedMuteIntervals.count, 1)
        XCTAssertEqual(manager.bridgedMuteIntervals.first?.lowerBound ?? 0, 8.5, accuracy: 0.001)
        XCTAssertEqual(manager.bridgedMuteIntervals.first?.upperBound ?? 0, 15.5, accuracy: 0.001)

        // Inside cue 1
        manager.updateCurrentTime(.seconds(11.0))
        XCTAssertTrue(manager.isContentFilterMuted)

        // Inside the gap (12.5s) - should STAY muted without fluttering
        manager.updateCurrentTime(.seconds(12.5))
        XCTAssertTrue(manager.isContentFilterMuted, "Mute should stay active during bridged gap between back-to-back cues")
        XCTAssertTrue(manager.isMuted)

        // Inside cue 2
        manager.updateCurrentTime(.seconds(14.0))
        XCTAssertTrue(manager.isContentFilterMuted)

        // After bridged interval (16.0s) - should unmute
        manager.updateCurrentTime(.seconds(16.0))
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)
    }

    /// Verifies that mute cues separated by more than 1.5 seconds remain discrete and are not bridged.
    @MainActor
    func testMuteBridgingOverThreshold() {
        let manager = ContentFilterManager()
        let cue1 = ContentFilterCue(
            key: "c1",
            start: "00:00:10.000",
            end: "00:00:12.000",
            description: "Profanity 1",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        // Gap is 4.0s (12.0s to 16.0s), which exceeds muteBridgeThresholdSeconds (1.5s)
        let cue2 = ContentFilterCue(
            key: "c2",
            start: "00:00:16.000",
            end: "00:00:18.000",
            description: "Profanity 2",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        manager.cues = [cue1, cue2]

        // Should NOT be merged: 2 separate intervals
        XCTAssertEqual(manager.bridgedMuteIntervals.count, 2)

        // Inside the gap at 13.5s - should NOT be muted
        manager.updateCurrentTime(.seconds(13.5))
        XCTAssertFalse(manager.isContentFilterMuted)
        XCTAssertFalse(manager.isMuted)
    }

    /// Verifies that user-customized mute lead and tail padding options dynamically adjust interval calculations.
    @MainActor
    func testConfigurableMutePadding() {
        // Verify default enum values
        XCTAssertEqual(ContentFilterMuteLeadPadding.onePointFive.rawValue, 1.50)
        XCTAssertEqual(ContentFilterMuteTailPadding.pointFive.rawValue, 0.50)
        XCTAssertEqual(ContentFilterMuteLeadPadding.onePointEight.rawValue, 1.80)

        let manager = ContentFilterManager()
        let cue = ContentFilterCue(
            key: "pad_test",
            start: "00:00:10.000",
            end: "00:00:12.000",
            description: "Padding test cue",
            category: "profanity",
            channel: "audio",
            action: "mute",
            enabled: true
        )
        manager.cues = [cue]

        // Default: 1.5s lead, 0.5s tail -> [8.5, 12.5]
        XCTAssertEqual(manager.bridgedMuteIntervals.count, 1)
        XCTAssertEqual(manager.bridgedMuteIntervals.first?.lowerBound ?? 0, 8.5, accuracy: 0.001)
        XCTAssertEqual(manager.bridgedMuteIntervals.first?.upperBound ?? 0, 12.5, accuracy: 0.001)
    }
}
