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
        isMuted.value = true
    }

    func unmute() {
        isMuted.value = false
    }

    func toggleMute() {
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
}
