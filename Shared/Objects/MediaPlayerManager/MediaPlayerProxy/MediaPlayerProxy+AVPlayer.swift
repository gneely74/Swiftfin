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

    /// Boundary time observer token registered on `AVPlayer` for exact millisecond mute/unmute transitions.
    private var boundaryTimeObserver: Any?

    /// Combine cancellable observing changes to ``ContentFilterManager/bridgedMuteIntervals``.
    private var muteIntervalsObserver: AnyCancellable?

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

                muteIntervalsObserver = manager.contentFilterManager.$bridgedMuteIntervals
                    .sink { [weak self] intervals in
                        self?.registerMuteBoundaryObservers(for: intervals)
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
                muteIntervalsObserver?.cancel()
                removeMuteBoundaryObservers()
            }
        }
    }

    /// Observers receiving playback lifecycle events (e.g., NowPlayable).
    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    /// Initializes a new AVPlayer proxy and sets up a 50ms high-precision periodic time observer on the main queue.
    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 1000),
            queue: .main
        ) { newTime in
            let newSeconds = Duration.seconds(newTime.seconds)

            if !self.isScrubbing.wrappedValue {
                self.scrubbedSeconds.wrappedValue = newSeconds
            }

            self.manager?.seconds = newSeconds
        }
    }

    /// Registers exact `CMTime` boundary observers on `AVPlayer` for the start and end of every coalesced mute interval.
    /// - Parameter intervals: The coalesced mute time intervals in seconds.
    private func registerMuteBoundaryObservers(for intervals: [ClosedRange<Double>]) {
        removeMuteBoundaryObservers()
        guard !intervals.isEmpty else { return }

        var boundaryTimes: [NSValue] = []
        boundaryTimes.reserveCapacity(intervals.count * 2)
        for interval in intervals {
            let startTime = CMTime(seconds: max(0, interval.lowerBound), preferredTimescale: 1000)
            let endTime = CMTime(seconds: max(0, interval.upperBound + 0.02), preferredTimescale: 1000)
            boundaryTimes.append(NSValue(time: startTime))
            boundaryTimes.append(NSValue(time: endTime))
        }

        boundaryTimeObserver = player.addBoundaryTimeObserver(
            forTimes: boundaryTimes,
            queue: .main
        ) { [weak self] in
            guard let self else { return }
            let currentSeconds = self.player.currentTime().seconds
            guard currentSeconds.isFinite, currentSeconds >= 0 else { return }
            self.manager?.contentFilterManager.updateCurrentTime(.seconds(currentSeconds))
        }
    }

    /// Removes any previously registered `AVPlayer` boundary time observer.
    private func removeMuteBoundaryObservers() {
        if let boundaryTimeObserver {
            player.removeTimeObserver(boundaryTimeObserver)
            self.boundaryTimeObserver = nil
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

    /// Applies ContentFilter audio attenuation in either full-mute or ambient-duck (`8%`) mode.
    ///
    /// When `mode == .duck`, `player.volume` is attenuated to `0.08` while keeping `player.isMuted = false`
    /// so HDMI eARC/AVR PCM streams stay locked and background score remains faintly audible.
    /// - Parameters:
    ///   - active: `true` to attenuate audio; `false` to restore full volume.
    ///   - mode: The attenuation strategy (`.mute` or `.duck`).
    ///   - faded: Whether to apply a fast volume ramp to eliminate popping.
    func setContentFilterAttenuation(active: Bool, mode: ContentFilterAudioMode, faded: Bool) {
        guard active else {
            unmute(faded: faded)
            return
        }

        if mode == .mute {
            mute(faded: faded)
            return
        }

        fadeTask?.cancel()
        isMuted.value = true
        manager?.contentFilterManager.isMuted = true
        player.isMuted = false

        guard faded else {
            player.volume = 0.08
            return
        }

        player.volume = 0.30
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
            guard !Task.isCancelled else { return }
            self.player.volume = 0.08
        }
    }

    /// Mutes the AVPlayer audio stream using default smooth fading (`faded: true`).
    func mute() {
        mute(faded: true)
    }

    /// Mutes the AVPlayer audio stream without altering system volume.
    ///
    /// Applies an immediate attenuation step (`volume = 0.30`) on the calling frame followed by a 15ms
    /// transition to `player.isMuted = true` so the audio hardware DAC never pops on a non-zero crossing.
    /// - Parameter faded: Whether to apply a fast volume fade ramp to eliminate popping.
    func mute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = true
        manager?.contentFilterManager.isMuted = true

        guard faded else {
            player.isMuted = true
            return
        }

        player.volume = 0.30
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
            guard !Task.isCancelled else { return }
            self.player.volume = 0.0
            self.player.isMuted = true
            self.player.volume = 1.0
        }
    }

    /// Unmutes the AVPlayer audio stream using default smooth fading (`faded: true`).
    func unmute() {
        unmute(faded: true)
    }

    /// Unmutes the AVPlayer audio stream and smoothly restores audio level.
    ///
    /// Releases `player.isMuted = false` at an ambient floor (`volume = 0.15`) and ramps to `1.0`
    /// over 60ms across both iOS and tvOS to prevent abrupt speaker pops.
    /// - Parameter faded: Whether to apply a smooth volume fade ramp.
    func unmute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = false
        manager?.contentFilterManager.isMuted = false

        guard faded else {
            player.isMuted = false
            player.volume = 1.0
            return
        }

        player.volume = 0.15
        player.isMuted = false
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let levels: [Float] = [0.45, 0.75, 1.0]
            for level in levels {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { return }
                self.player.volume = level
            }
        }
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
        removeMuteBoundaryObservers()

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
