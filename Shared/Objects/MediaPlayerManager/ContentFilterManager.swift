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

/// Central coordinator for client-side ContentFilter execution.
///
/// Running strictly on `@MainActor`, `ContentFilterManager` handles:
/// - Pre-fetching and caching filter cues and clean subtitles from the Jellyfin server.
/// - Evaluating high-frequency player clock ticks (100ms interval) to trigger stream-level audio mutes and video skips.
/// - Applying pre-roll lead padding (400ms) and post-roll tail padding (300ms) to ensure plosive sounds are silenced.
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

    /// Session-level master toggle indicating whether ContentFilter evaluation is active for the current playback session.
    /// Toggling this to `false` immediately unmutes any active ContentFilter mute and suspends cue evaluation.
    @Published
    var isFilterEnabled: Bool = true {
        didSet {
            guard isFilterEnabled != oldValue else { return }
            if !isFilterEnabled, isContentFilterMuted {
                isContentFilterMuted = false
                manager?.proxy?.unmute(faded: true)
                isMuted = false
            }
            recalculateBridgedMuteIntervals()
        }
    }

    /// User-adjustable timing offset (in seconds) applied to all cue start and end timestamps.
    /// Positive values delay mutes/skips; negative values trigger mutes/skips earlier.
    /// Automatically persisted per media item in `UserDefaults`.
    @Published
    var timeOffsetSeconds: Double = 0.0 {
        didSet {
            guard timeOffsetSeconds != oldValue else { return }
            if let currentItemID {
                UserDefaults.standard.set(timeOffsetSeconds, forKey: Self.timeOffsetDefaultsKey(for: currentItemID))
            }
            recalculateBridgedMuteIntervals()
        }
    }

    /// Active audio attenuation strategy (`.mute` for full silence or `.duck` for 8% ambient floor).
    /// Persisted globally in `UserDefaults`.
    @Published
    var audioMode: ContentFilterAudioMode = {
        if let raw = UserDefaults.standard.string(forKey: "ContentFilter.audioMode"),
           let mode = ContentFilterAudioMode(rawValue: raw)
        {
            return mode
        }
        return .mute
    }() {
        didSet {
            guard audioMode != oldValue else { return }
            UserDefaults.standard.set(audioMode.rawValue, forKey: "ContentFilter.audioMode")
            if isContentFilterMuted {
                manager?.proxy?.setContentFilterAttenuation(active: true, mode: audioMode, faded: true)
            }
        }
    }

    /// The specific cue that is currently active and driving player behavior at the current playback timestamp.
    @Published
    var currentActiveCue: ContentFilterCue?

    // MARK: - Skip Badge State

    /// Published flag driving the visibility of `ContentFilterSkipBadge`.
    @Published
    var isSkipping: Bool = false

    /// Published flag driving a brief black-frame fade overlay during scene skip seeks
    /// so keyframe seek latency does not flash objectionable frames.
    @Published
    var isSkipTransitioning: Bool = false

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

    /// Identifier of the currently loaded Jellyfin media item, used for per-item offset persistence.
    private var currentItemID: String?

    /// Set of skip cue identifiers that have already been jumped during the current pass,
    /// preventing infinite seek re-trigger loops while allowing re-skipping if the user rewinds before the cue.
    private var recentlySkippedCueIDs: Set<String> = []

    /// Asynchronous task managing the 2.6-second auto-dismiss timeout for the scene skip badge.
    private var skipDismissTask: Task<Void, Never>?

    /// Asynchronous task managing the brief black-frame fade overlay during scene skip seeks.
    private var skipTransitionTask: Task<Void, Never>?

    /// Asynchronous task keeping the filtered subtitle popup visible for a minimum readable linger
    /// duration after brief word-level mute intervals end.
    private var subtitleLingerTask: Task<Void, Never>?

    /// Timestamp when the filtered subtitle popup was most recently shown for the current mute event.
    private var subtitleShownAt: Date?

    /// Minimum total display duration (in seconds) for the filtered subtitle popup so brief word-level
    /// mutes (`~0.3s–0.6s`) remain legible on screen.
    private let minimumSubtitleDisplaySeconds: TimeInterval = 2.5

    /// Tracks whether the subtitle overlay is currently active due to an audio mute event.
    private var isTemporarilyDisplayingFilteredSubtitle: Bool = false

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

    // MARK: - Interactive Drawer Controls

    /// Toggles the master session filter enabled state on or off.
    func toggleFilterEnabled() {
        isFilterEnabled.toggle()
    }

    /// Adjusts the cue synchronization timing offset by the specified delta (in seconds), clamped to `[-15.0, 15.0]`.
    /// - Parameter delta: The number of seconds to shift cue evaluation (e.g., `-0.5` or `+0.5`).
    func adjustTimeOffset(by delta: Double) {
        let updated = (timeOffsetSeconds + delta) * 10
        timeOffsetSeconds = min(15.0, max(-15.0, updated.rounded() / 10.0))
    }

    /// Resets the cue synchronization timing offset back to `0.0` seconds.
    func resetTimeOffset() {
        timeOffsetSeconds = 0.0
    }

    /// Toggles the audio attenuation strategy between full mute (`.mute`) and ambient ducking (`.duck`).
    func toggleAudioMode() {
        audioMode = (audioMode == .mute) ? .duck : .mute
    }

    /// Returns the `UserDefaults` key used to persist `timeOffsetSeconds` for a specific Jellyfin media item.
    /// - Parameter itemID: The Jellyfin media item identifier.
    /// - Returns: A namespaced `UserDefaults` key string.
    private static func timeOffsetDefaultsKey(for itemID: String) -> String {
        "ContentFilter.timeOffset.\(itemID)"
    }

    /// Returns whether at least one cue belonging to the specified category is currently enabled.
    /// - Parameter category: The category name to query.
    /// - Returns: `true` if any cue in the category is enabled; otherwise `false`.
    func isCategoryEnabled(_ category: String) -> Bool {
        cues.contains { $0.category.caseInsensitiveCompare(category) == .orderedSame && $0.enabled }
    }

    /// Toggles all cues matching the specified category on or off.
    /// - Parameter category: The category name to toggle.
    func toggleCategory(_ category: String) {
        let targetState = !isCategoryEnabled(category)
        var updated = cues
        for index in updated.indices where updated[index].category.caseInsensitiveCompare(category) == .orderedSame {
            updated[index].enabled = targetState
        }
        cues = updated
    }

    /// Toggles the `enabled` state of an individual filter cue by its identifier.
    /// - Parameter cueID: The unique `id` (`key`) of the cue to toggle.
    func toggleCue(_ cueID: String) {
        guard let index = cues.firstIndex(where: { $0.id == cueID }) else { return }
        var updated = cues
        updated[index].enabled.toggle()
        cues = updated
    }

    /// Seeks the active media player to 2 seconds prior to the specified cue's start timestamp.
    /// - Parameter cue: The target cue to preview or jump to.
    func seekToCue(_ cue: ContentFilterCue) {
        let targetSeconds = max(0, cue.startSeconds + timeOffsetSeconds - 2.0)
        manager?.proxy?.setSeconds(.seconds(targetSeconds))
    }

    // MARK: - Network Loading

    /// Asynchronously fetches filter rules, clean sidecar subtitles, and server global blanket words
    /// for a given media item upon playback start.
    ///
    /// Restores any previously persisted per-item `timeOffsetSeconds` and immediately evaluates the
    /// current playback position so resuming inside a mute or skip interval takes effect without delay.
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
        async let wordsTask = ContentFilterService.shared.fetchGlobalBlanketWords(session: session)

        let (filter, subs, serverWords) = await (filterTask, subTask, wordsTask)
        if let serverWords, !serverWords.isEmpty {
            ContentFilterWordMasker.updateServerWords(serverWords)
        }

        self.currentItemID = itemID
        self.recentlySkippedCueIDs.removeAll()
        self.isFilterEnabled = true
        self.timeOffsetSeconds = UserDefaults.standard.double(forKey: Self.timeOffsetDefaultsKey(for: itemID))
        self.activeFilter = filter
        self.cues = filter?.cues ?? []
        self.filteredSubtitles = subs ?? []

        if let currentSeconds = manager?.seconds {
            updateCurrentTime(currentSeconds)
        }
    }

    // MARK: - Timing & Padding Constants

    /// Pre-roll lead time (in seconds) applied before a standard subtitle/clause mute cue starts (~250ms).
    ///
    /// Suppresses explosive consonants and initial phonemes (e.g. \"f\", \"p\", \"b\")
    /// without swallowing preceding clean dialogue.
    static let muteLeadSeconds: Double = 0.25

    /// Post-roll tail padding (in seconds) applied after a standard subtitle/clause mute cue ends (~150ms).
    ///
    /// Prevents audible trailing consonant clicks while avoiding muting subsequent clean words.
    static let muteTailSeconds: Double = 0.15

    /// Tighter pre-roll lead time (in seconds) applied when a cue has word-level acoustic timestamps (~120ms).
    static let wordMuteLeadSeconds: Double = 0.12

    /// Tighter post-roll tail padding (in seconds) applied when a cue has word-level acoustic timestamps (~100ms).
    static let wordMuteTailSeconds: Double = 0.10

    /// Maximum time gap (in seconds) between two consecutive mute cues to bridge as a single contiguous mute span (~1.5s).
    ///
    /// Prevents rapid audio toggling, popping, and jarring stutter during fast back-to-back dialogue.
    static let muteBridgeThresholdSeconds: Double = 1.50

    /// Returns the appropriate pre-roll lead and post-roll tail padding for a given cue based on its precision.
    /// - Parameter cue: The cue being evaluated.
    /// - Returns: A tuple of `(lead, tail)` in seconds.
    static func padding(for cue: ContentFilterCue) -> (lead: Double, tail: Double) {
        if cue.isWordPrecision {
            (wordMuteLeadSeconds, wordMuteTailSeconds)
        } else {
            (muteLeadSeconds, muteTailSeconds)
        }
    }

    /// Coalesced mute time ranges incorporating lead padding, tail padding, timing offset, and bridging.
    @Published
    private(set) var bridgedMuteIntervals: [ClosedRange<Double>] = []

    /// Recomputes the continuous mute spans by sorting mute cues, applying timing offset and adaptive lead/tail padding,
    /// and merging any intervals separated by less than `muteBridgeThresholdSeconds`.
    func recalculateBridgedMuteIntervals() {
        guard isFilterEnabled else {
            bridgedMuteIntervals = []
            return
        }

        let offset = timeOffsetSeconds
        let sortedMuteCues = cues
            .filter { $0.enabled && $0.isMute }
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !sortedMuteCues.isEmpty else {
            bridgedMuteIntervals = []
            return
        }

        var intervals: [ClosedRange<Double>] = []
        let engineBufferLead = manager?.proxy?.audioBufferLeadSeconds ?? 0.0

        for cue in sortedMuteCues {
            let pad = Self.padding(for: cue)
            let start = max(0, cue.startSeconds + offset - (pad.lead + engineBufferLead))
            let end = max(start, cue.endSeconds + offset + pad.tail - engineBufferLead)

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

    // MARK: - Binary Search Helpers

    /// Performs an $O(\log n)$ binary search on sorted, non-overlapping `ClosedRange<Double>` intervals
    /// to determine whether `time` falls within any active mute span.
    ///
    /// - Parameters:
    ///   - time: The current playback timestamp in seconds.
    ///   - sortedIntervals: Sorted, coalesced mute intervals.
    /// - Returns: `true` if `time` is contained in any interval; otherwise `false`.
    static func contains(_ time: Double, in sortedIntervals: [ClosedRange<Double>]) -> Bool {
        var low = 0
        var high = sortedIntervals.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let interval = sortedIntervals[mid]
            if time < interval.lowerBound {
                high = mid - 1
            } else if time > interval.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    /// Performs an $O(\log n)$ binary search on sorted `ContentFilterSubtitleItem` entries
    /// to locate the active masked subtitle item at the given playback timestamp.
    ///
    /// - Parameters:
    ///   - time: Current playback timestamp in seconds.
    ///   - offset: User-configured timing offset in seconds.
    ///   - sortedSubtitles: Sorted array of filtered subtitle items.
    /// - Returns: The matching `ContentFilterSubtitleItem`, or `nil` if none is active.
    static func subtitleItem(
        at time: Double,
        offset: Double,
        in sortedSubtitles: [ContentFilterSubtitleItem]
    ) -> ContentFilterSubtitleItem? {
        guard !sortedSubtitles.isEmpty else { return nil }

        var low = 0
        var high = sortedSubtitles.count - 1
        var candidateIndex: Int?

        while low <= high {
            let mid = (low + high) / 2
            let sStart = max(0, sortedSubtitles[mid].startSeconds + offset - muteLeadSeconds)
            if sStart <= time {
                candidateIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let idx = candidateIndex else { return nil }
        // Walk backward through any overlapping subtitle items that started <= time
        for i in stride(from: idx, through: max(0, idx - 3), by: -1) {
            let item = sortedSubtitles[i]
            let sStart = max(0, item.startSeconds + offset - muteLeadSeconds)
            let sEnd = item.endSeconds + offset + muteTailSeconds
            if time >= sStart, time <= sEnd {
                return item
            }
        }
        return nil
    }

    // MARK: - Periodic Time Evaluation

    /// Evaluates the current media playback position against active filter cues.
    ///
    /// Called at high frequency (50ms interval from `AVPlayer` / `VLCMediaPlayerProxy` clock interpolation).
    /// - Checks if the player is inside any coalesced mute interval and asserts/de-asserts stream muting.
    /// - Evaluates scene skip cues and invokes timeline seeking past objectionable scenes.
    /// - Updates active subtitle text during mute intervals.
    ///
    /// - Parameter seconds: Current playback position represented as a native Swift `Duration`.
    func updateCurrentTime(_ seconds: Duration) {
        guard isFilterEnabled else {
            if isContentFilterMuted {
                isContentFilterMuted = false
                manager?.proxy?.unmute(faded: true)
                self.isMuted = false
            }
            if currentActiveCue != nil {
                currentActiveCue = nil
            }
            return
        }

        let sec = seconds.seconds
        let offset = timeOffsetSeconds
        let engineBufferLead = manager?.proxy?.audioBufferLeadSeconds ?? 0.0
        let isInsideMuteInterval = Self.contains(sec, in: bridgedMuteIntervals)

        let newActiveCue = cues.first(where: { cue in
            let cStart = cue.startSeconds + offset
            let cEnd = cue.endSeconds + offset
            if cue.isMute {
                let pad = Self.padding(for: cue)
                return cue.enabled
                    && sec >= max(0, cStart - (pad.lead + engineBufferLead))
                    && sec <= max(0, cEnd + pad.tail - engineBufferLead)
            } else {
                return cue.enabled && sec >= cStart && sec <= cEnd
            }
        }) ?? (isInsideMuteInterval ? cues.first(where: { cue in
            let cStart = cue.startSeconds + offset
            let cEnd = cue.endSeconds + offset
            let pad = Self.padding(for: cue)
            return cue.enabled && cue.isMute
                && (cEnd + pad.tail - engineBufferLead + Self.muteBridgeThresholdSeconds >= sec && cStart - engineBufferLead <= sec)
        }) : nil)

        if currentActiveCue?.id != newActiveCue?.id {
            currentActiveCue = newActiveCue
        }

        // Allow re-skipping if the user explicitly scrubbed back before a previously skipped cue's start
        if !recentlySkippedCueIDs.isEmpty {
            recentlySkippedCueIDs = recentlySkippedCueIDs.filter { skippedID in
                guard let cue = cues.first(where: { $0.id == skippedID }) else { return false }
                return sec >= (cue.startSeconds + offset - 0.5)
            }
        }

        // Check for skip cues during playback
        if let currentActiveCue, currentActiveCue.isSkip, !recentlySkippedCueIDs.contains(currentActiveCue.id) {
            recentlySkippedCueIDs.insert(currentActiveCue.id)
            let targetEnd = max(0, currentActiveCue.endSeconds + offset)
            triggerSkipTransition()
            manager?.proxy?.setSeconds(.seconds(targetEnd))
            triggerSkip(reason: currentActiveCue.description ?? currentActiveCue.category)
        }

        // Check for mute cues during playback with adaptive padding and bridge coalescing
        if isInsideMuteInterval {
            if !isContentFilterMuted {
                isContentFilterMuted = true
                manager?.proxy?.setContentFilterAttenuation(active: true, mode: audioMode, faded: true)
                self.isMuted = true
            }
        } else if isContentFilterMuted {
            isContentFilterMuted = false
            manager?.proxy?.setContentFilterAttenuation(active: false, mode: audioMode, faded: true)
            self.isMuted = false
        }

        // Update active filtered subtitle text during mute
        if isMuted && isTemporarilyDisplayingFilteredSubtitle {
            let matchingSubtitle = Self.subtitleItem(at: sec, offset: offset, in: filteredSubtitles)
            if activeFilteredSubtitleText != matchingSubtitle?.text {
                activeFilteredSubtitleText = matchingSubtitle?.text
            }
        }
    }

    /// Briefly fades the video frame to black (`~250ms`) during a scene skip seek so keyframe seek latency
    /// does not flash objectionable frames.
    private func triggerSkipTransition() {
        skipTransitionTask?.cancel()
        withAnimation(.easeOut(duration: 0.06)) {
            self.isSkipTransitioning = true
        }
        skipTransitionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                self.isSkipTransitioning = false
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

        subtitleLingerTask?.cancel()
        subtitleLingerTask = nil

        // Display overlay subtitle if available from API
        isTemporarilyDisplayingFilteredSubtitle = true
        subtitleShownAt = Date()
        let seconds = manager?.seconds.seconds ?? 0
        let match = Self.subtitleItem(at: seconds, offset: timeOffsetSeconds, in: filteredSubtitles)
        activeFilteredSubtitleText = match?.text
    }

    /// Deactivates and hides the filtered subtitle overlay when the mute period ends,
    /// lingering briefly if the mute was shorter than `minimumSubtitleDisplaySeconds`
    /// so word-level mutes remain legible.
    private func disableFilteredSubtitleIfApplicable() {
        guard isTemporarilyDisplayingFilteredSubtitle else { return }

        subtitleLingerTask?.cancel()
        let elapsed = subtitleShownAt.map { Date().timeIntervalSince($0) } ?? minimumSubtitleDisplaySeconds
        let remaining = minimumSubtitleDisplaySeconds - elapsed

        if remaining > 0.05, activeFilteredSubtitleText != nil {
            subtitleLingerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.isMuted else { return }
                self.isTemporarilyDisplayingFilteredSubtitle = false
                self.activeFilteredSubtitleText = nil
                self.subtitleShownAt = nil
            }
        } else {
            isTemporarilyDisplayingFilteredSubtitle = false
            activeFilteredSubtitleText = nil
            subtitleShownAt = nil
        }
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
        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        subtitleLingerTask?.cancel()
        subtitleLingerTask = nil
        subtitleShownAt = nil
        isTemporarilyDisplayingFilteredSubtitle = false
        currentItemID = nil
        activeFilter = nil
        cues = []
        filteredSubtitles = []
        isMuted = false
        isSkipping = false
        isSkipTransitioning = false
        lastSkipReason = nil
        recentlySkippedCueIDs.removeAll()
        currentActiveCue = nil
        activeFilteredSubtitleText = nil
    }
}
