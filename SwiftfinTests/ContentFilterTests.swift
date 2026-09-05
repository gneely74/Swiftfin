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
}
