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

// TODO: turned into spaghetti to get out, clean up with a better state system
// TODO: verify timer states
// TODO: for tvOS, some kind of focus token system
//       - help with Menu
//       - may help with alternate overlays

/// Coordinates UI presentation state, gesture locking, focus navigation, supplement sheet
/// presentation, and idle auto-dismiss timers for the video player container view.
@MainActor
class VideoPlayerContainerState: ObservableObject {

    /// Whether the video display is currently scaled to fill the container (cropping edges).
    @Published
    var isAspectFilled: Bool = false

    /// Whether touch and remote interaction gestures are locked to prevent accidental input.
    @Published
    var isGestureLocked: Bool = false {
        didSet {
            if isGestureLocked {
                isPresentingOverlay = false
            }
        }
    }

    // TODO: rename isPresentingPlaybackButtons
    /// Whether playback transport buttons are currently visible.
    @Published
    var isPresentingPlaybackControls: Bool = false

    // TODO: replace with graph dependency package
    /// Recalculates playback controls visibility based on overlay, supplement, and size class states.
    func setPlaybackControlsVisibility() {

        guard isPresentingOverlay else {
            isPresentingPlaybackControls = false
            return
        }

        if isPresentingOverlay && !isPresentingSupplement {
            isPresentingPlaybackControls = true
            return
        }

        if isCompact {
            if isPresentingSupplement {
                if !isPresentingPlaybackControls {
                    isPresentingPlaybackControls = true
                }
            } else {
                isPresentingPlaybackControls = false
            }
        } else {
            isPresentingPlaybackControls = false
        }
    }

    /// Whether the player container is running in a compact horizontal size class.
    @Published
    var isCompact: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
        }
    }

    /// Whether the active supplement is presented as a temporary guest overlay.
    @Published
    var isGuestSupplement: Bool = false

    // TODO: rename isPresentingPlaybackControls
    /// Whether the playback heads-up display (HUD), progress bar, and controls overlay is presented.
    ///
    /// Changing this resets or pauses the idle dismissal timer.
    @Published
    var isPresentingOverlay: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
            presentationControllerShouldDismiss = isPresentingOverlay && !isPresentingSupplement

            if isPresentingOverlay {
                if !isPresentingSupplement || UIDevice.isTV {
                    timer.poke()
                }
            } else {
                timer.stop()
            }
        }
    }

    /// Whether a supplement drawer (e.g., ContentFilter, Chapters, Episodes) is actively presented.
    ///
    /// On tvOS, activates a 15-second idle auto-dismiss timer so that menus close automatically
    /// if left unattended while playback continues.
    @Published
    private(set) var isPresentingSupplement: Bool = false {
        didSet {
            setPlaybackControlsVisibility()
            presentationControllerShouldDismiss = isPresentingOverlay && !isPresentingSupplement

            if isPresentingSupplement {
                if UIDevice.isTV {
                    timer.defaultInterval = 15
                    timer.poke()
                } else {
                    timer.stop()
                }
            } else {
                isGuestSupplement = false
                timer.defaultInterval = UIDevice.isTV ? 10 : 5
                timer.poke()
            }
        }
    }

    /// Whether the user is actively scrubbing along the playback timeline.
    @Published
    var isScrubbing: Bool = false {
        didSet {
            if isScrubbing {
                timer.stop()
            } else {
                timer.poke()
            }
        }
    }

    /// Whether the presentation controller should allow interactive dismissal.
    @Published
    var presentationControllerShouldDismiss: Bool = false

    /// The currently active media player supplement, or `nil` if none is displayed.
    @Published
    var selectedSupplement: (any MediaPlayerSupplement)? = nil {
        didSet {
            isPresentingSupplement = selectedSupplement != nil
        }
    }

    /// Published flag indicating whether tvOS focus should snap back to the playback progress bar.
    @Published
    var isProgressBarFocused: Bool = false

    /// Whether an action menu is currently being presented to the user.
    var isPresentingMenu: Bool = false {
        didSet {
            if isPresentingMenu {
                timer.stop()
            } else {
                timer.poke()
            }
        }
    }

    /// Cached playback rate preserved during scrubbing or speed boost operations.
    var originalPlaybackRate: Float?

    /// Center offset tracking for interactive drag and pan gestures.
    let centerOffsetBox: PublishedBox<CGFloat> = .init(initialValue: 0)

    /// Tracks rapid jump forward/backward tap sequences.
    let jumpProgressObserver: JumpProgressObserver = .init()

    /// Target timestamp currently being scrubbed to on the timeline.
    let scrubbedSeconds: PublishedBox<Duration> = .init(initialValue: .zero)

    /// Timer managing idle timeout and auto-dismissal of HUD and supplement views.
    let timer: PokeIntervalTimer = .init(defaultInterval: UIDevice.isTV ? 10 : 5)

    /// Proxy dispatching on-screen toast notifications (e.g. skip badges).
    let toastProxy: ToastProxy = .init()

    /// Reference to the parent container view controller hosting SwiftUI subviews.
    weak var containerView: VideoPlayer.UIVideoPlayerContainerViewController?

    /// Reference to the coordinating media player manager.
    weak var manager: MediaPlayerManager?

    #if os(iOS)
    var panHandlingAction: (any _PanHandlingAction)?
    var didSwipe: Bool = false
    var lastTapLocation: CGPoint?
    #endif

    #if os(tvOS)
    @Published
    private(set) var presentedSupplementStyle: MediaPlayerSupplementPresentationStyle?

    /// Whether the modal confirmation dialog for closing the player is presented.
    @Published
    var isPresentingCloseConfirmation: Bool = false

    /// The playback timestamp before the user initiated scrubbing, used for cancellation.
    var scrubOriginSeconds: Duration?

    /// Commits the active timeline scrub by seeking the player to `scrubbedSeconds` and resuming playback.
    func commitScrub() {
        guard isScrubbing else { return }

        manager?.proxy?.setSeconds(scrubbedSeconds.value)
        manager?.setPlaybackRequestStatus(status: .playing)
        isScrubbing = false
        scrubOriginSeconds = nil
    }

    /// Cancels active timeline scrubbing and reverts playback position to the pre-scrub timestamp.
    func cancelScrub() {
        guard isScrubbing else { return }

        if let manager {
            scrubbedSeconds.value = manager.seconds
        }

        isScrubbing = false
        scrubOriginSeconds = nil
    }

    /// Updates the current supplement presentation style on tvOS.
    /// - Parameter style: The target presentation style (e.g. side drawer, bottom sheet).
    func setPresentedSupplementStyle(_ style: MediaPlayerSupplementPresentationStyle?) {
        presentedSupplementStyle = style
    }
    #endif

    private var jumpProgressCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?

    /// Initializes container state and wires up the idle timer callback.
    ///
    /// On tvOS, automatically dismisses active supplements and hides the HUD overlay after 10–15 seconds
    /// of idle playback, restoring focus to the progress bar.
    init() {
        timerCancellable = timer.sink { [weak self] in
            guard let self else { return }

            if containerView?.presentedViewController != nil {
                timer.poke()
                return
            }

            guard !isScrubbing,
                  !isPresentingMenu,
                  manager?.playbackRequestStatus != .paused else { return }

            if isPresentingSupplement {
                guard UIDevice.isTV else { return }

                select(supplement: nil)
                #if os(tvOS)
                isProgressBarFocused = true
                #endif
            }

            withAnimation(.linear(duration: 0.25)) {
                self.isPresentingOverlay = false
            }
        }

        #if os(iOS)
        jumpProgressCancellable = jumpProgressObserver
            .timer
            .sink { [weak self] in
                self?.lastTapLocation = nil
            }
        #endif
    }

    /// Selects or dismisses a media player supplement (e.g., ContentFilter, Chapters, Episodes).
    ///
    /// Toggling an already-selected supplement dismisses it. Selecting a new supplement presents
    /// its drawer or sheet view and restarts the idle auto-dismiss timer.
    /// - Parameters:
    ///   - supplement: The supplement to present, or `nil` to dismiss any active supplement.
    ///   - isGuest: Whether the supplement is presented temporarily as a guest overlay.
    func select(supplement: (any MediaPlayerSupplement)?, isGuest: Bool = false) {
        isGuestSupplement = isGuest

        if supplement?.id == selectedSupplement?.id {
            selectedSupplement = nil
            containerView?.presentSupplementContainer(false)
        } else {
            selectedSupplement = supplement
            containerView?.presentSupplementContainer(
                supplement != nil,
                presentationStyle: isGuest ? supplement?.presentationStyle : nil
            )
        }
    }
}
