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
    var cues: [ContentFilterCue] = [] {
        didSet {
            recalculateBridgedMuteIntervals()
        }
    }
    @Published
    var isMuted: Bool = false {
        didSet {
            guard isMuted != oldValue else { return }
            handleMuteStateChanged(isMuted: isMuted)
        }
    }

    @Published
    var isContentFilterMuted: Bool = false

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

    // Lead time before mute cue starts to prevent initial phoneme leakage (~400ms)
    static let muteLeadSeconds: Double = 0.40
    // Tail padding after mute cue ends to prevent trailing consonant clicks (~300ms)
    static let muteTailSeconds: Double = 0.30
    // Maximum gap between consecutive mute cues to bridge as a single continuous mute interval (~1.5s)
    static let muteBridgeThresholdSeconds: Double = 1.50

    @Published
    private(set) var bridgedMuteIntervals: [ClosedRange<Double>] = []

    func recalculateBridgedMuteIntervals() {
        let sortedMuteCues = cues
            .filter { $0.enabled && $0.isMute }
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !sortedMuteCues.isEmpty else {
            bridgedMuteIntervals = []
            return
        }

        var intervals: [ClosedRange<Double>] = []

        for cue in sortedMuteCues {
            let start = max(0, cue.startSeconds - Self.muteLeadSeconds)
            let end = cue.endSeconds + Self.muteTailSeconds

            if let last = intervals.last {
                if start <= last.upperBound + Self.muteBridgeThresholdSeconds {
                    // Merge with the previous interval
                    intervals[intervals.count - 1] = last.lowerBound ... max(last.upperBound, end)
                } else {
                    intervals.append(start ... end)
                }
            } else {
                intervals.append(start ... end)
            }
        }

        bridgedMuteIntervals = intervals
    }

    func updateCurrentTime(_ seconds: Duration) {
        let sec = seconds.seconds
        let isInsideMuteInterval = bridgedMuteIntervals.contains(where: { $0.contains(sec) })

        currentActiveCue = cues.first(where: { cue in
            if cue.isMute {
                return cue.enabled && sec >= max(0, cue.startSeconds - Self.muteLeadSeconds) && sec <= (cue.endSeconds + Self.muteTailSeconds)
            } else {
                return cue.enabled && sec >= cue.startSeconds && sec <= cue.endSeconds
            }
        }) ?? (isInsideMuteInterval ? cues.first(where: { cue in
            cue.enabled && cue.isMute && (cue.endSeconds + Self.muteTailSeconds + Self.muteBridgeThresholdSeconds >= sec && cue.startSeconds <= sec)
        }) : nil)

        // Check for skip cues during playback
        if let currentActiveCue, currentActiveCue.isSkip, currentActiveCue.id != lastSkippedCueID {
            lastSkippedCueID = currentActiveCue.id
            manager?.proxy?.setSeconds(currentActiveCue.endDuration)
            triggerSkip(reason: currentActiveCue.description ?? currentActiveCue.category)
        }

        // Check for mute cues during playback with pre-roll lead, post-roll tail, and bridge coalescing
        if isInsideMuteInterval {
            if !isContentFilterMuted {
                isContentFilterMuted = true
                manager?.proxy?.mute(faded: true)
                self.isMuted = true
            }
        } else if isContentFilterMuted {
            isContentFilterMuted = false
            manager?.proxy?.unmute(faded: true)
            self.isMuted = false
        }

        // Update active filtered subtitle text during mute
        if isMuted && isTemporarilyDisplayingFilteredSubtitle {
            let matchingSubtitle = filteredSubtitles.first(where: {
                sec >= max(0, $0.startSeconds - Self.muteLeadSeconds) && sec <= ($0.endSeconds + Self.muteTailSeconds)
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
        }

        guard !filteredSubtitles.isEmpty else { return }

        // Display overlay subtitle if available from API
        isTemporarilyDisplayingFilteredSubtitle = true
        let seconds = manager?.seconds.seconds ?? 0
        let match = filteredSubtitles.first(where: {
            seconds >= max(0, $0.startSeconds - Self.muteLeadSeconds) && seconds <= ($0.endSeconds + Self.muteTailSeconds)
        })
        activeFilteredSubtitleText = match?.text
    }

    private func disableFilteredSubtitleIfApplicable() {
        guard isTemporarilyDisplayingFilteredSubtitle else { return }

        isTemporarilyDisplayingFilteredSubtitle = false
        activeFilteredSubtitleText = nil
    }

    func clear() {
        if isContentFilterMuted {
            isContentFilterMuted = false
            manager?.proxy?.unmute(faded: false)
        }
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
