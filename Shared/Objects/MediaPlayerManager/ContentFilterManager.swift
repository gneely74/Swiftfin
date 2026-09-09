//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import SwiftUI

/// Central coordinator for client-side ContentFilter execution.
///
/// Running strictly on `@MainActor`, `ContentFilterManager` handles:
/// - Pre-fetching and caching filter cues and clean subtitles from the Jellyfin server.
/// - Evaluating high-frequency player clock ticks (100ms interval) to trigger stream-level audio mutes and video skips.
/// - Applying pre-roll lead padding (default 1.5s) and post-roll tail padding (default 500ms) to ensure plosive sounds are silenced.
/// - Coalescing adjacent mute cues within 1.5 seconds into seamless, continuous mute intervals to eliminate audio flutter.
/// - Managing HUD badge display states for active mutes and scene skips.
/// - Driving the masked subtitle overlay during mute events without destructively altering user subtitle preferences.
@MainActor
final class ContentFilterManager: ObservableObject {

    /// Weak reference to the parent `MediaPlayerManager` controlling playback.
    weak var manager: MediaPlayerManager?

    /// The active content filter response object loaded from the server for the current media item.
    @Published
    var activeFilter: ContentFilterResponse?

    /// The collection of all content filter cues for the current media item.
    /// Updating this array triggers an automatic recalculation of bridged mute intervals.
    @Published
    var cues: [ContentFilterCue] = [] {
        didSet {
            recalculateBridgedMuteIntervals()
        }
    }

    /// Published flag indicating whether an audio mute is currently enforced by ContentFilter.
    @Published
    var isMuted: Bool = false {
        didSet {
            guard isMuted != oldValue else { return }
            handleMuteStateChanged(isMuted: isMuted)
        }
    }

    /// Internal tracking flag for whether the media player proxy is currently muted by ContentFilter.
    @Published
    var isContentFilterMuted: Bool = false

    /// The specific cue that is currently active and driving player behavior at the current playback timestamp.
    @Published
    var currentActiveCue: ContentFilterCue?

    // MARK: - Skip Badge State

    /// Published flag driving the visibility of `ContentFilterSkipBadge`.
    @Published
    var isSkipping: Bool = false

    /// The category or descriptive reason displayed on the skip badge (e.g. "Violence", "Nudity").
    @Published
    var lastSkipReason: String? = nil

    // MARK: - Filtered Subtitle State

    /// Collection of parsed dialogue subtitle items from the clean sidecar `.srt` file.
    @Published
    var filteredSubtitles: [ContentFilterSubtitleItem] = []

    /// The sanitized dialogue text currently rendered inside `ContentFilterSubtitleOverlay`.
    @Published
    var activeFilteredSubtitleText: String? = nil

    /// Identifier of the cue most recently skipped to prevent infinite seek re-trigger loops.
    private var lastSkippedCueID: String?

    /// Asynchronous task managing the 2.6-second auto-dismiss timeout for the scene skip badge.
    private var skipDismissTask: Task<Void, Never>?

    /// Tracks whether the subtitle overlay is currently active due to an audio mute event.
    private var isTemporarilyDisplayingFilteredSubtitle: Bool = false

    /// Cancellables set retaining active publisher subscriptions.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initializer

    /// Initializes a new content filter manager instance and sets up reactive observers for user preference changes.
    init() {
        Defaults.publisher(.ContentFilter.muteLeadPadding)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recalculateBridgedMuteIntervals()
            }
            .store(in: &cancellables)

        Defaults.publisher(.ContentFilter.muteTailPadding)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recalculateBridgedMuteIntervals()
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    /// Returns `true` if any content filter cues exist for the current media item.
    var hasCues: Bool {
        !cues.isEmpty
    }

    /// All cues that are currently enabled by user or server policy.
    var enabledCues: [ContentFilterCue] {
        cues.filter(\.enabled)
    }

    /// All enabled cues that represent audio muting actions.
    var muteCues: [ContentFilterCue] {
        cues.filter { $0.enabled && $0.isMute }
    }

    /// All enabled cues that represent visual scene skip actions.
    var skipCues: [ContentFilterCue] {
        cues.filter { $0.enabled && $0.isSkip }
    }

    /// Total count of active audio mute cues.
    var muteCount: Int {
        muteCues.count
    }

    /// Total count of active visual scene skip cues.
    var skipCount: Int {
        skipCues.count
    }

    /// Sorted list of unique category strings across all loaded cues.
    var categories: [String] {
        Array(Set(cues.map(\.category))).sorted()
    }

    // MARK: - Network Loading

    /// Asynchronously fetches filter rules and clean sidecar subtitles for a given media item upon playback start.
    ///
    /// - Parameters:
    ///   - itemID: The Jellyfin item identifier.
    ///   - session: The active `UserSession` providing credentials and endpoint configurations.
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

    // MARK: - Timing & Padding Constants

    /// Pre-roll lead time (in seconds) applied before a mute cue starts (~1.5s default).
    ///
    /// Silences audio prior to dialogue timestamps to overcome hardware audio buffer latency,
    /// HDMI eARC transmission delays to soundbars/AVRs, and character-ratio subtitle timing estimation variances.
    static var muteLeadSeconds: Double {
        Defaults[.ContentFilter.muteLeadPadding].rawValue
    }

    /// Post-roll tail padding (in seconds) applied after a mute cue ends (~500ms default).
    ///
    /// Prevents audible trailing consonant clicks or abrupt cutoff before vocal cord vibration decays.
    static var muteTailSeconds: Double {
        Defaults[.ContentFilter.muteTailPadding].rawValue
    }

    /// Maximum time gap (in seconds) between two consecutive mute cues to bridge as a single contiguous mute span (~1.5s).
    ///
    /// Prevents rapid audio toggling, popping, and jarring stutter during fast back-to-back dialogue.
    static var muteBridgeThresholdSeconds: Double {
        Defaults[.ContentFilter.muteBridgeThresholdSeconds]
    }

    /// Coalesced mute time ranges incorporating lead padding, tail padding, and bridging.
    @Published
    private(set) var bridgedMuteIntervals: [ClosedRange<Double>] = []

    /// Recomputes the continuous mute spans by sorting mute cues, applying lead/tail padding,
    /// and merging any intervals separated by less than `muteBridgeThresholdSeconds`.
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

    // MARK: - Periodic Time Evaluation

    /// Evaluates the current media playback position against active filter cues.
    ///
    /// Called at high frequency (100ms interval from `AVPlayer.addPeriodicTimeObserver` or `MediaPlayerManager`).
    /// - Checks if the player is inside any coalesced mute interval and asserts/de-asserts stream muting.
    /// - Evaluates scene skip cues and invokes timeline seeking past objectionable scenes.
    /// - Updates active subtitle text during mute intervals.
    ///
    /// - Parameter seconds: Current playback position represented as a native Swift `Duration`.
    func updateCurrentTime(_ seconds: Duration) {
        let sec = seconds.seconds
        let isInsideMuteInterval = bridgedMuteIntervals.contains(where: { $0.contains(sec) })

        let newActiveCue = cues.first(where: { cue in
            if cue.isMute {
                cue.enabled && sec >= max(0, cue.startSeconds - Self.muteLeadSeconds) && sec <= (cue.endSeconds + Self.muteTailSeconds)
            } else {
                cue.enabled && sec >= cue.startSeconds && sec <= cue.endSeconds
            }
        }) ?? (isInsideMuteInterval ? cues.first(where: { cue in
            cue.enabled && cue
                .isMute && (cue.endSeconds + Self.muteTailSeconds + Self.muteBridgeThresholdSeconds >= sec && cue.startSeconds <= sec)
        }) : nil)

        if currentActiveCue?.id != newActiveCue?.id {
            currentActiveCue = newActiveCue
        }

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
            if activeFilteredSubtitleText != matchingSubtitle?.text {
                activeFilteredSubtitleText = matchingSubtitle?.text
            }
        }
    }

    /// Triggers a visual scene skip badge overlay and schedules its automatic dismissal after 2.6 seconds.
    ///
    /// - Parameter reason: Optional descriptive label (e.g. \"Violence\", \"Nudity\").
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

    // MARK: - Subtitle Handling

    /// Responds to changes in mute state by presenting or dismissing filtered subtitle overlays.
    ///
    /// - Parameter isMuted: The new mute state.
    private func handleMuteStateChanged(isMuted: Bool) {
        if isMuted {
            enableFilteredSubtitleIfApplicable()
        } else {
            disableFilteredSubtitleIfApplicable()
        }
    }

    /// Activates the masked subtitle overlay during an audio mute if the user is not already
    /// viewing an existing clean/filtered native subtitle stream.
    private func enableFilteredSubtitleIfApplicable() {
        if let playbackItem = manager?.playbackItem,
           let currentSubIndex = playbackItem.selectedSubtitleStreamIndex,
           currentSubIndex != -1,
           let currentStream = playbackItem.subtitleStreams.first(where: { $0.index == currentSubIndex }),
           currentStream.isFilteredSubtitle
        {
            // Already using a clean/filtered subtitle stream, no overlay needed
            return
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

    /// Deactivates and hides the filtered subtitle overlay when the mute period ends.
    private func disableFilteredSubtitleIfApplicable() {
        guard isTemporarilyDisplayingFilteredSubtitle else { return }

        isTemporarilyDisplayingFilteredSubtitle = false
        activeFilteredSubtitleText = nil
    }

    // MARK: - Teardown

    /// Resets all state properties, cancels pending animation tasks, unmutes the audio stream,
    /// and flushes cached cues and subtitles upon playback completion.
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
