//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import Defaults
import Foundation
@preconcurrency import JellyfinAPI
import SwiftUI

// TODO: After NativeVideoPlayer is removed, can move bindings and
//       observers to AVPlayerView, like the VLC delegate
//       - wouldn't need to have MediaPlayerProxy: MediaPlayerObserver
// TODO: report playback information, see VLCUI.PlaybackInformation (dropped frames, etc.)
// TODO: report buffering state
// TODO: have set seconds with completion handler

/// Concrete implementation of ``VideoMediaPlayerProxy`` backed by Apple's `AVPlayer` and `AVPlayerLayer`.
///
/// Handles audio/video playback via AVFoundation, providing 100ms high-precision periodic time observation,
/// stream-level muting without altering hardware volume, and integration with ``ContentFilterManager``.
@MainActor
class AVMediaPlayerProxy: VideoMediaPlayerProxy {

    /// Published box indicating whether the media player is currently buffering data.
    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)

    /// Published box indicating whether the media player's audio stream is currently muted.
    let isMuted: PublishedBox<Bool> = .init(initialValue: false)

    /// Binding indicating whether the user is actively scrubbing the timeline.
    var isScrubbing: Binding<Bool> = .constant(false)

    /// Binding storing the target playback timestamp being scrubbed to.
    var scrubbedSeconds: Binding<Duration> = .constant(.zero)

    /// Published box storing the native dimensions of the video stream.
    var videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)

    /// Published box tracking the number of dropped video frames.
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)

    /// Published box tracking the number of corrupted frames.
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    /// The CoreAnimation layer displaying video frames rendered by ``player``.
    let avPlayerLayer: AVPlayerLayer

    /// The underlying AVFoundation playback engine.
    let player: AVPlayer

//    private var rateObserver: NSKeyValueObservation!
    private var statusObserver: NSKeyValueObservation!
    private var timeControlStatusObserver: NSKeyValueObservation!
    private var timeObserver: Any!
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?

    /// Weak reference to the parent ``MediaPlayerManager`` coordinating this proxy.
    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { playbackItem in
                        if let playbackItem {
                            self.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { state in
                        switch state {
                        case .stopped:
                            self.playbackStopped()
                        default: break
                        }
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
            }
        }
    }

    /// Observers receiving playback lifecycle events (e.g., NowPlayable).
    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    /// Initializes a new AVPlayer proxy and sets up a 100ms periodic time observer on the main queue.
    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000),
            queue: .main
        ) { newTime in
            let newSeconds = Duration.seconds(newTime.seconds)

            if !self.isScrubbing.wrappedValue {
                self.scrubbedSeconds.wrappedValue = newSeconds
            }

            self.manager?.seconds = newSeconds
        }
    }

    /// Resumes playback on the AVPlayer instance.
    func play() {
        player.play()
    }

    /// Pauses playback on the AVPlayer instance.
    func pause() {
        player.pause()
    }

    /// Stops playback by pausing the AVPlayer instance.
    func stop() {
        player.pause()
    }

    /// Advances playback position forward by the given duration.
    /// - Parameter seconds: The duration to skip forward.
    func jumpForward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Rewinds playback position backward by the given duration, clamping to zero.
    /// - Parameter seconds: The duration to skip backward.
    func jumpBackward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 1))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Seeks playback to an absolute time offset with zero tolerance.
    /// - Parameter seconds: The target playback timestamp.
    func setSeconds(_ seconds: Duration) {
        let time = CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - ContentFilter Audio Stream Muting

    private var fadeTask: Task<Void, Never>?

    /// Mutes the AVPlayer audio stream using default smooth fading (`faded: true`).
    func mute() {
        mute(faded: true)
    }

    /// Mutes the AVPlayer audio stream without altering system volume.
    ///
    /// Sets `player.isMuted = true` and synchronizes state with ``ContentFilterManager``.
    /// On non-tvOS platforms, applies a rapid 40ms volume fade ramp if `faded` is true.
    /// - Parameter faded: Whether to apply a fast volume fade ramp to eliminate popping.
    func mute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = true
        manager?.contentFilterManager.isMuted = true
        player.isMuted = true

        #if !os(tvOS)
        guard faded else { return }

        let initialVolume = player.volume > 0 ? player.volume : 1.0
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 4
            let stepDelay: UInt64 = 10_000_000 // 10ms * 4 = ~40ms fast ramp
            for step in 1 ... steps {
                if Task.isCancelled {
                    return
                }
                try? await Task.sleep(nanoseconds: stepDelay)
                let factor = Float(steps - step) / Float(steps)
                self.player.volume = initialVolume * factor
            }
            self.player.volume = initialVolume
        }
        #endif
    }

    /// Unmutes the AVPlayer audio stream using default smooth fading (`faded: true`).
    func unmute() {
        unmute(faded: true)
    }

    /// Unmutes the AVPlayer audio stream and restores audio level.
    ///
    /// Sets `player.isMuted = false` and synchronizes state with ``ContentFilterManager``.
    /// On non-tvOS platforms, applies a rapid 40ms volume fade-in ramp if `faded` is true.
    /// - Parameter faded: Whether to apply a fast volume fade ramp.
    func unmute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = false
        manager?.contentFilterManager.isMuted = false

        #if os(tvOS)
        player.isMuted = false
        player.volume = 1.0
        #else
        guard faded else {
            player.isMuted = false
            player.volume = 1.0
            return
        }

        player.volume = 0.0
        player.isMuted = false
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 4
            let stepDelay: UInt64 = 10_000_000 // 10ms * 4 = ~40ms fast ramp
            for step in 1 ... steps {
                if Task.isCancelled {
                    return
                }
                try? await Task.sleep(nanoseconds: stepDelay)
                let factor = Float(step) / Float(steps)
                self.player.volume = factor
            }
            self.player.volume = 1.0
        }
        #endif
    }

    /// Toggles the audio stream mute state with smooth fading.
    func toggleMute() {
        toggleMute(faded: true)
    }

    /// Toggles the audio stream mute state.
    /// - Parameter faded: Whether to apply a fast volume fade ramp.
    func toggleMute(faded: Bool) {
        if isMuted.value {
            unmute(faded: faded)
        } else {
            mute(faded: faded)
        }
    }

    // TODO: complete
    /// Sets playback rate (placeholder for AVPlayer implementation).
    /// - Parameter rate: Playback rate multiplier.
    func setRate(_ rate: Float) {}

    /// Switches audio stream track (placeholder for AVPlayer implementation).
    /// - Parameter stream: Target audio stream descriptor.
    func setAudioStream(_ stream: MediaStream) {}

    /// Switches subtitle stream track (placeholder for AVPlayer implementation).
    /// - Parameter stream: Target subtitle stream descriptor.
    func setSubtitleStream(_ stream: MediaStream) {}

    /// Adjusts whether the video fills or fits the screen via `avPlayerLayer.videoGravity`.
    /// - Parameter aspectFill: `true` to fill bounds; `false` to fit aspect ratio.
    func setAspectFill(_ aspectFill: Bool) {
        avPlayerLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    /// The SwiftUI view hosting the AVPlayer rendering layer.
    var videoPlayerBody: some View {
        AVPlayerView()
            .environmentObject(self)
    }
}

extension AVMediaPlayerProxy {

    /// Cleans up observers and pauses playback when the session has terminated.
    private func playbackStopped() {
        player.pause()

        if let timeObserver {
            DispatchQueue.main.async {
                self.player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        if let statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
        }

        if let timeControlStatusObserver {
            timeControlStatusObserver.invalidate()
            self.timeControlStatusObserver = nil
        }
    }

    /// Loads and begins playback for a new media item.
    ///
    /// Replaces the current AVPlayerItem, cancels ongoing fade tasks, resets volume and muting state,
    /// observes timeControlStatus and item status, and seeks to resume position if applicable.
    /// - Parameter item: The media player item to play.
    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem

        let newAVPlayerItem = AVPlayerItem(url: item.url)
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata

        player.replaceCurrentItem(with: newAVPlayerItem)
        fadeTask?.cancel()
        fadeTask = nil
        player.volume = 1.0
        player.isMuted = false
        isMuted.value = false

        // TODO: protect against paused
//        rateObserver = player.observe(\.rate, options: [.new, .initial]) { _, value in
//            DispatchQueue.main.async {
//                self.manager?.set(rate: value.newValue ?? 1.0)
//            }
//        }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { player, _ in
            let timeControlStatus = player.timeControlStatus

            DispatchQueue.main.async {
                switch timeControlStatus {
                case .paused:
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                case .waitingToPlayAtSpecifiedRate: ()
                // TODO: buffering
                case .playing:
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                @unknown default: ()
                }
            }
        }

        // TODO: proper handling of none/unknown states
        statusObserver = player.observe(\.currentItem?.status, options: [.new, .initial]) { _, value in
            guard let newValue = value.newValue else { return }
            switch newValue {
            case .failed:
                if let error = self.player.error {
                    DispatchQueue.main.async {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
                }
            case .none, .readyToPlay, .unknown:
                let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))

                self.player.seek(
                    to: CMTimeMake(
                        value: startSeconds.components.seconds,
                        timescale: 1
                    ),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in
                        self.play()
                    }
                )
            @unknown default: ()
            }
        }
    }
}

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    /// SwiftUI representable bridge wrapping `UIAVPlayerView` for embedding in SwiftUI view hierarchies.
    struct AVPlayerView: PlatformViewRepresentable {

        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy
        @EnvironmentObject
        private var scrubbedSeconds: PublishedBox<Duration>

        /// Creates the UIKit view hosting the AVPlayer layer.
        func makeUIView(context: Context) -> UIView {
//            proxy.isScrubbing = context.environment.isScrubbing
//            proxy.scrubbedSeconds = $scrubbedSeconds.value
            UIAVPlayerView(proxy: proxy)
        }

        /// Updates the UIKit view during SwiftUI state changes.
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    /// UIKit `UIView` container hosting the AVPlayerLayer and handling layout bounds updates.
    private class UIAVPlayerView: UIView {

        /// The associated proxy instance.
        let proxy: AVMediaPlayerProxy

        /// Creates a view embedding the proxy's `avPlayerLayer`.
        /// - Parameter proxy: The AVMediaPlayerProxy providing the layer.
        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Synchronizes the `avPlayerLayer` frame with the view's layout bounds.
        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }
    }
}
