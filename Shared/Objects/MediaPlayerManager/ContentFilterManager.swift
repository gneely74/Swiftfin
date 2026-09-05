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

    weak var manager: MediaPlayerManager?

    @Published
    var activeFilter: ContentFilterResponse?
    @Published
    var cues: [ContentFilterCue] = []
    @Published
    var isMuted: Bool = false {
        didSet {
            guard isMuted != oldValue else { return }
            handleMuteStateChanged(isMuted: isMuted)
        }
    }

    @Published
    var currentActiveCue: ContentFilterCue?

    // Skip badge state
    @Published
    var isSkipping: Bool = false
    @Published
    var lastSkipReason: String? = nil

    // Filtered subtitle state
    @Published
    var filteredSubtitles: [ContentFilterSubtitleItem] = []
    @Published
    var activeFilteredSubtitleText: String? = nil

    private var lastSkippedCueID: String?
    private var skipDismissTask: Task<Void, Never>?
    private var originalSubtitleStreamIndex: Int?
    private var isTemporarilyDisplayingFilteredSubtitle: Bool = false

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

        async let filterTask = ContentFilterService.shared.fetchFilter(for: itemID, session: session)
        async let subTask = ContentFilterService.shared.fetchFilteredSubtitle(for: itemID, session: session)

        let (filter, subs) = await (filterTask, subTask)
        self.activeFilter = filter
        self.cues = filter?.cues ?? []
        self.filteredSubtitles = subs ?? []
    }

    func updateCurrentTime(_ seconds: Duration) {
        let sec = seconds.seconds
        currentActiveCue = cues.first(where: { cue in
            cue.enabled && sec >= cue.startSeconds && sec <= cue.endSeconds
        })

        // Check for skip cues during playback
        if let currentActiveCue, currentActiveCue.isSkip, currentActiveCue.id != lastSkippedCueID {
            lastSkippedCueID = currentActiveCue.id
            manager?.proxy?.setSeconds(currentActiveCue.endDuration)
            triggerSkip(reason: currentActiveCue.description ?? currentActiveCue.category)
        }

        // Update active filtered subtitle text during mute
        if isMuted && isTemporarilyDisplayingFilteredSubtitle {
            let matchingSubtitle = filteredSubtitles.first(where: {
                sec >= $0.startSeconds && sec <= $0.endSeconds
            })
            activeFilteredSubtitleText = matchingSubtitle?.text
        }
    }

    func triggerSkip(reason: String? = nil) {
        skipDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) {
            self.lastSkipReason = reason
            self.isSkipping = true
        }

        skipDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.isSkipping = false
                self.lastSkipReason = nil
            }
        }
    }

    private func handleMuteStateChanged(isMuted: Bool) {
        if isMuted {
            enableFilteredSubtitleIfApplicable()
        } else {
            disableFilteredSubtitleIfApplicable()
        }
    }

    private func enableFilteredSubtitleIfApplicable() {
        if let playbackItem = manager?.playbackItem {
            // "unless another subtitle has already been selected"
            let currentSubIndex = playbackItem.selectedSubtitleStreamIndex
            let hasSelectedSubtitle = (currentSubIndex != nil && currentSubIndex != -1)
            guard !hasSelectedSubtitle else { return }

            // Check if item has a filtered subtitle track
            if let filteredStream = playbackItem.subtitleStreams.filteredSubtitleStream {
                originalSubtitleStreamIndex = currentSubIndex
                isTemporarilyDisplayingFilteredSubtitle = true
                playbackItem.selectedSubtitleStreamIndex = filteredStream.index
                return
            }
        }

        if !filteredSubtitles.isEmpty {
            // Display overlay subtitle if available from API
            isTemporarilyDisplayingFilteredSubtitle = true
            let seconds = manager?.seconds.seconds ?? 0
            let match = filteredSubtitles.first(where: {
                seconds >= $0.startSeconds && seconds <= $0.endSeconds
            })
            activeFilteredSubtitleText = match?.text
        }
    }

    private func disableFilteredSubtitleIfApplicable() {
        guard isTemporarilyDisplayingFilteredSubtitle else { return }

        if let original = originalSubtitleStreamIndex {
            manager?.playbackItem?.selectedSubtitleStreamIndex = original
            originalSubtitleStreamIndex = nil
        }

        isTemporarilyDisplayingFilteredSubtitle = false
        activeFilteredSubtitleText = nil
    }

    func clear() {
        skipDismissTask?.cancel()
        skipDismissTask = nil
        disableFilteredSubtitleIfApplicable()
        activeFilter = nil
        cues = []
        filteredSubtitles = []
        isMuted = false
        isSkipping = false
        lastSkipReason = nil
        lastSkippedCueID = nil
        currentActiveCue = nil
        activeFilteredSubtitleText = nil
    }
}
