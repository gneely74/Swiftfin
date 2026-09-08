//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

extension VideoPlayer {

    /// The tvOS video player playback controls overlay.
    ///
    /// Manages the bottom toolbar, timeline progress bar, focus transitions, Siri Remote press event routing,
    /// and auto-dismiss timer poking when playback resumes.
    struct PlaybackControls: View {

        /// The configured interval for skipping backward.
        @Default(.VideoPlayer.jumpBackwardInterval)
        var jumpBackwardInterval

        /// The configured interval for skipping forward.
        @Default(.VideoPlayer.jumpForwardInterval)
        var jumpForwardInterval

        /// Shared player container state managing HUD visibility and timers.
        @EnvironmentObject
        var containerState: VideoPlayerContainerState

        /// Active media player manager instance coordinating playback.
        @EnvironmentObject
        var manager: MediaPlayerManager

        /// Toast proxy for displaying transient status alerts.
        @Toaster
        var toaster: ToastProxy

        /// Focus state binding indicating whether focus is currently on the progress bar.
        @FocusState
        private var isPlaybackProgressFocused: Bool

        /// Timer driving accelerated scrubbing during long click-and-hold gestures.
        @State
        var speedBoostTimer: Timer?

        /// Whether accelerated speed-boosted scrubbing is active.
        @State
        var isSpeedBoosting: Bool = false

        /// Queued work item for debounced jump/seek commands.
        @State
        var pendingJumpWork: DispatchWorkItem?

        var body: some View {
            VStack(spacing: 30) {

                Toolbar()
                    .isVisible(
                        containerState.isPresentingOverlay &&
                            !containerState.isScrubbing &&
                            !containerState.isPresentingSupplement
                    )
                    .disabled(containerState.isPresentingSupplement)

                PlaybackProgress()
                    .focused($isPlaybackProgressFocused)
                    .fixedSize(horizontal: false, vertical: true)
                    .isVisible(
                        (containerState.isPresentingOverlay || containerState.isScrubbing) &&
                            !containerState.isPresentingSupplement
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .edgePadding(.horizontal)
            .focusSection()
            .animation(.easeInOut(duration: 0.25), value: containerState.isPresentingSupplement)
            .animation(.easeInOut(duration: 0.25), value: containerState.isPresentingOverlay)
            .animation(.linear(duration: 0.1), value: containerState.isScrubbing)
            .alert(L10n.closePlayer, isPresented: $containerState.isPresentingCloseConfirmation) {
                Button(L10n.cancel, role: .cancel) {}

                Button(L10n.ok, role: .destructive) {
                    manager.stop()
                }
            } message: {
                Text(L10n.closePlayerWarning)
            }
            .onChange(of: containerState.isPresentingOverlay) { _, isPresenting in
                if isPresenting {
                    isPlaybackProgressFocused = true
                }
            }
            .onChange(of: manager.playbackRequestStatus) {
                if manager.playbackRequestStatus == .paused, !containerState.isPresentingOverlay {
                    containerState.isPresentingOverlay = true
                } else if manager.playbackRequestStatus == .playing, containerState.isPresentingOverlay {
                    containerState.timer.poke()
                }
            }
            .onReceive(containerState.containerView?.onPressEvent ?? .init()) { press in
                handlePressEvent(press)
            }
            .onChange(of: containerState.isProgressBarFocused) {
                if !containerState.isProgressBarFocused {
                    containerState.cancelScrub()

                    if isSpeedBoosting {
                        stopSpeedBoost()
                    }
                }
            }
        }
    }
}
