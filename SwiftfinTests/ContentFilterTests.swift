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

    func mute() {
        mute(faded: false)
    }

    func mute(faded: Bool) {
        isMuted.value = true
    }

    func unmute() {
        unmute(faded: false)
    }

    func unmute(faded: Bool) {
        isMuted.value = false
    }

    func toggleMute() {
        toggleMute(faded: false)
    }

    func toggleMute(faded: Bool) {
        isMuted.value.toggle()
    }
}

final class ContentFilterSocketTests: XCTestCase {

    func testMuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should initially be unmuted")

        mockProxy.mute()
        XCTAssertTrue(mockProxy.isMuted.value, "Player proxy should be muted upon calling mute()")
    }

    func testUnmuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        mockProxy.mute()
        XCTAssertTrue(mockProxy.isMuted.value)

        mockProxy.unmute()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should be unmuted upon calling unmute()")
    }

    func testToggleMuteCommandRouting() {
        let mockProxy = MockMediaPlayerProxy()
        XCTAssertFalse(mockProxy.isMuted.value)

        mockProxy.toggleMute()
        XCTAssertTrue(mockProxy.isMuted.value, "Player proxy should toggle to muted")

        mockProxy.toggleMute()
        XCTAssertFalse(mockProxy.isMuted.value, "Player proxy should toggle to unmuted")
    }

    func testTimestampParsing() {
        XCTAssertEqual(ContentFilterCue.parseTimestamp("00:01:23.500"), 83.5, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("01:30.000"), 90.0, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("01:00:00.000"), 3600.0, accuracy: 0.001)
        XCTAssertEqual(ContentFilterCue.parseTimestamp("45.2"), 45.2, accuracy: 0.001)
    }

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

        manager.updateCurrentTime(.seconds(90)) // outside any cue
        XCTAssertNil(manager.currentActiveCue)

        manager.updateCurrentTime(.seconds(130)) // 00:02:10 -> inside cue 2
        XCTAssertEqual(manager.currentActiveCue?.key, "2")
    }

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
}
