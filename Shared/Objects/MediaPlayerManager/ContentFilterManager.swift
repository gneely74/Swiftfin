//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ContentFilterManager: ObservableObject {

    @Published
    var activeFilter: ContentFilterResponse?
    @Published
    var cues: [ContentFilterCue] = []
    @Published
    var isMuted: Bool = false
    @Published
    var currentActiveCue: ContentFilterCue?

    var hasCues: Bool {
        !cues.isEmpty
    }

    var enabledCues: [ContentFilterCue] {
        cues.filter(\.enabled)
    }

    var muteCues: [ContentFilterCue] {
        cues.filter { $0.enabled && $0.isMute }
    }

    var skipCues: [ContentFilterCue] {
        cues.filter { $0.enabled && $0.isSkip }
    }

    var muteCount: Int {
        muteCues.count
    }

    var skipCount: Int {
        skipCues.count
    }

    var categories: [String] {
        Array(Set(cues.map(\.category))).sorted()
    }

    func loadFilter(for itemID: String, session: UserSession?) async {
        guard let session else {
            clear()
            return
        }

        let filter = await ContentFilterService.shared.fetchFilter(for: itemID, session: session)
        self.activeFilter = filter
        self.cues = filter?.cues ?? []
    }

    func updateCurrentTime(_ seconds: Duration) {
        let sec = seconds.seconds
        currentActiveCue = cues.first(where: { cue in
            cue.enabled && sec >= cue.startSeconds && sec <= cue.endSeconds
        })
    }

    func clear() {
        activeFilter = nil
        cues = []
        isMuted = false
        currentActiveCue = nil
    }
}
