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
import JellyfinAPI
import SwiftUI
import VLCUI

#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// Concrete implementation of ``VideoMediaPlayerProxy`` backed by MobileVLCKit / TVVLCKit via VLCUI.
///
/// Provides video decoding for non-native codecs, subtitle styling, audio stream track selection,
/// and robust stream-level audio muting with tvOS dual-attenuation (`isMuted` + zero volume).
class VLCMediaPlayerProxy: VideoMediaPlayerProxy,
    MediaPlayerOffsetConfigurable,
    MediaPlayerSubtitleConfigurable
{

    /// Published box indicating whether the VLC player is currently buffering data.
    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)

    /// Published box indicating whether the media player's audio stream is currently muted.
    let isMuted: PublishedBox<Bool> = .init(initialValue: false)

    /// Published box storing the native dimensions of the video stream.
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)

    /// Published box tracking the count of lost/dropped picture frames reported by VLC statistics.
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)

    /// Published box tracking the count of corrupted demux packets reported by VLC statistics.
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    /// The underlying proxy object coordinating VLCVideoPlayer from VLCUI.
    let vlcUIProxy: VLCVideoPlayer.Proxy = .init()

    /// Reflection-based accessor extracting the internal `VLCMediaPlayer` instance from `VLCVideoPlayer.Proxy`.
    private var vlcPlayer: VLCMediaPlayer? {
        Mirror(reflecting: vlcUIProxy).children.first(where: { $0.label == "mediaPlayer" })?.value as? VLCMediaPlayer
    }

    private var managerItemObserver: AnyCancellable?

    /// Weak reference to the parent ``MediaPlayerManager`` coordinating playback.
    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { [weak self] item in
                        guard let self, item != nil else { return }
                        self.fadeTask?.cancel()
                        self.fadeTask = nil
                        self.isMuted.value = false
                        if let audio = self.vlcPlayer?.audio {
                            audio.isMuted = false
                            audio.volume = 100
                        }
                    }
            } else {
                managerItemObserver?.cancel()
            }
        }
    }

    /// Observers receiving playback lifecycle events (e.g., NowPlayable).
    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    /// Resumes playback on the VLC engine.
    func play() {
        vlcUIProxy.play()
    }

    /// Pauses active playback on the VLC engine.
    func pause() {
        vlcUIProxy.pause()
    }

    /// Halts playback on the VLC engine.
    func stop() {
        vlcUIProxy.stop()
    }

    /// Advances playback position forward by the specified duration, clamping to remaining runtime.
    /// - Parameter seconds: The duration to skip forward.
    func jumpForward(_ seconds: Duration) {
        let target: Duration

        if let runtime = manager?.item.runtime, let current = manager?.seconds {
            let remaining = max(.zero, runtime - current)
            target = min(seconds, remaining)
        } else {
            target = seconds
        }

        guard target > .zero else { return }

        vlcUIProxy.jumpForward(target)
    }

    /// Rewinds playback position backward by the specified duration.
    /// - Parameter seconds: The duration to skip backward.
    func jumpBackward(_ seconds: Duration) {
        vlcUIProxy.jumpBackward(seconds)
    }

    /// Sets the playback speed multiplier on the VLC engine.
    /// - Parameter rate: Playback rate multiplier (e.g., 1.0 for normal speed).
    func setRate(_ rate: Float) {
        vlcUIProxy.setRate(.absolute(rate))
    }

    /// Seeks playback to the specified absolute time offset.
    /// - Parameter seconds: Target playback timestamp.
    func setSeconds(_ seconds: Duration) {
        vlcUIProxy.setSeconds(seconds)
    }

    // MARK: - ContentFilter Audio Stream Muting

    private var fadeTask: Task<Void, Never>?

    /// Mutes the VLC audio stream using default smooth fading (`faded: true`).
    func mute() {
        mute(faded: true)
    }

    /// Mutes the VLC player audio stream without modifying master system volume.
    ///
    /// Sets `audio.isMuted = true` and synchronizes with ``ContentFilterManager``.
    /// On tvOS, additionally zeroes `audio.volume = 0` to ensure complete silence even when
    /// certain audio output routes bypass VLC's boolean mute flag.
    /// On other platforms, executes a rapid 40ms volume fade ramp if `faded` is true.
    /// - Parameter faded: Whether to apply a volume ramp to avoid abrupt audio popping.
    func mute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = true
        manager?.contentFilterManager.isMuted = true
        vlcPlayer?.audio?.isMuted = true

        #if os(tvOS)
        vlcPlayer?.audio?.volume = 0
        #else
        guard faded, let audio = vlcPlayer?.audio else { return }

        let initialVolume = audio.volume > 0 ? audio.volume : 100
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 4
            let stepDelay: UInt64 = 10_000_000 // 10ms * 4 = ~40ms ramp
            for step in 1 ... steps {
                if Task.isCancelled {
                    return
                }
                try? await Task.sleep(nanoseconds: stepDelay)
                let factor = Float(steps - step) / Float(steps)
                self.vlcPlayer?.audio?.volume = Int32(Float(initialVolume) * factor)
            }
            self.vlcPlayer?.audio?.volume = initialVolume
        }
        #endif
    }

    /// Unmutes the VLC audio stream using default smooth fading (`faded: true`).
    func unmute() {
        unmute(faded: true)
    }

    /// Unmutes the VLC player audio stream and restores audio level.
    ///
    /// Sets `audio.isMuted = false` and synchronizes with ``ContentFilterManager``.
    /// On tvOS, explicitly restores `audio.volume = 100`.
    /// On other platforms, executes a smooth 160ms volume ramp-up if `faded` is true.
    /// - Parameter faded: Whether to apply a smooth volume ramp.
    func unmute(faded: Bool) {
        fadeTask?.cancel()
        isMuted.value = false
        manager?.contentFilterManager.isMuted = false

        #if os(tvOS)
        vlcPlayer?.audio?.isMuted = false
        vlcPlayer?.audio?.volume = 100
        #else
        guard faded, let audio = vlcPlayer?.audio else {
            vlcPlayer?.audio?.isMuted = false
            vlcPlayer?.audio?.volume = 100
            return
        }

        audio.volume = 0
        audio.isMuted = false
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = 8
            let stepDelay: UInt64 = 20_000_000 // ~160ms ramp
            for step in 1 ... steps {
                if Task.isCancelled {
                    return
                }
                try? await Task.sleep(nanoseconds: stepDelay)
                let factor = Float(step) / Float(steps)
                self.vlcPlayer?.audio?.volume = Int32(100 * factor)
            }
            self.vlcPlayer?.audio?.volume = 100
        }
        #endif
    }

    /// Toggles the audio stream mute state with smooth fading.
    func toggleMute() {
        toggleMute(faded: true)
    }

    /// Toggles the audio stream mute state.
    /// - Parameter faded: Whether to apply a volume ramp.
    func toggleMute(faded: Bool) {
        if isMuted.value {
            unmute(faded: faded)
        } else {
            mute(faded: faded)
        }
    }

    /// Switches playback to the designated audio stream track index.
    /// - Parameter stream: The audio media stream.
    func setAudioStream(_ stream: MediaStream) {
        vlcUIProxy.setAudioTrack(.absolute(stream.index ?? -1))
    }

    /// Switches display to the designated subtitle stream track index.
    /// - Parameter stream: The subtitle media stream.
    func setSubtitleStream(_ stream: MediaStream) {
        vlcUIProxy.setSubtitleTrack(.absolute(stream.index ?? -1))
    }

    /// Adjusts aspect fill mode on the VLC video surface.
    /// - Parameter aspectFill: `true` to scale video to fill bounds; `false` to fit aspect ratio.
    func setAspectFill(_ aspectFill: Bool) {
        vlcUIProxy.aspectFill(aspectFill ? 1 : 0)
    }

    /// Adjusts the audio synchronization delay.
    /// - Parameter seconds: Time offset to shift audio.
    func setAudioOffset(_ seconds: Duration) {
        vlcUIProxy.setAudioDelay(seconds)
    }

    /// Adjusts the subtitle synchronization delay.
    /// - Parameter seconds: Time offset to shift subtitles.
    func setSubtitleOffset(_ seconds: Duration) {
        vlcUIProxy.setSubtitleDelay(seconds)
    }

    /// Applies custom font, size, and color styling to VLC subtitles.
    /// - Parameter configuration: User-configured subtitle appearance settings.
    func setSubtitleConfiguration(_ configuration: SubtitleConfiguration) {
        vlcUIProxy.setSubtitleColor(.absolute(configuration.color.uiColor))
        vlcUIProxy.setSubtitleFont(configuration.fontName)
        vlcUIProxy.setSubtitleSize(.absolute(25 - configuration.size))
    }

    /// The SwiftUI view embedding the VLC video player canvas.
    @ViewBuilder
    var videoPlayerBody: some View {
        VLCPlayerView()
            .environmentObject(vlcUIProxy)
    }
}

extension VLCMediaPlayerProxy {

    /// SwiftUI view hosting the VLC video player canvas and bridging playback events to ``MediaPlayerManager``.
    struct VLCPlayerView: View {

        @Default(.VideoPlayer.Subtitle.configuration)
        private var subtitleConfiguration

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager
        @EnvironmentObject
        private var proxy: VLCVideoPlayer.Proxy

        private var isScrubbing: Bool {
            containerState.isScrubbing
        }

        /// Generates a VLC player configuration for the specified media item.
        ///
        /// Configures initial seek offset, stream URLs, audio track indices, subtitle styling, and sidecar subtitles.
        /// - Parameter item: The media player item to configure for playback.
        /// - Returns: A fully initialized VLC player configuration struct.
        private func vlcConfiguration(for item: MediaPlayerItem) -> VLCVideoPlayer.Configuration {
            let baseItem = item.baseItem
            let mediaSource = item.mediaSource

            var configuration = VLCVideoPlayer.Configuration(url: item.url)
            configuration.autoPlay = true

            let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))

            if !baseItem.isLiveStream {
                configuration.startSeconds = startSeconds

                let subtitleIndex = item.indexMap.playerIndex(for: item.selectedSubtitleStreamIndex) ?? -1

                if mediaSource.transcodingURL != nil {
                    configuration.audioIndex = .auto
                } else {
                    let audioIndex = item.indexMap.playerIndex(for: item.selectedAudioStreamIndex) ?? -1
                    configuration.audioIndex = .absolute(audioIndex)
                }

                configuration.subtitleIndex = .absolute(subtitleIndex)
            }

            let subtitleConfiguration = Defaults[.VideoPlayer.Subtitle.configuration]
            configuration.subtitleSize = .absolute(25 - subtitleConfiguration.size)
            configuration.subtitleColor = .absolute(subtitleConfiguration.color.uiColor)
            configuration.rate = .absolute(Defaults[.VideoPlayer.Playback.playbackRate])
            if let font = UIFont(name: subtitleConfiguration.fontName, size: 1) {
                configuration.subtitleFont = .absolute(font)
            }

            configuration.playbackChildren = item.subtitleStreams.sidecarSubtitles
                .compactMap(\.asVLCPlaybackChild)

            return configuration
        }

        var body: some View {
            if let playbackItem = manager.playbackItem, manager.state != .stopped {
                VLCVideoPlayer(configuration: vlcConfiguration(for: playbackItem))
                    .proxy(proxy)
                    .onSecondsUpdated { newSeconds, info in
                        if !isScrubbing {
                            containerState.scrubbedSeconds.value = newSeconds
                        }

                        manager.seconds = newSeconds

                        if let proxy = manager.proxy as? any VideoMediaPlayerProxy {
                            proxy.videoSize.value = info.videoSize
                            proxy.droppedFrames.value = info.statistics.lostPictures
                            proxy.corruptedFrames.value = info.statistics.demuxCorrupted
                        }
                    }
                    .onStateUpdated { state, info in
                        manager.logger.trace("VLC state updated: \(state)")

                        switch state {
                        case .buffering,
                             .esAdded,
                             .opening:
                            // TODO: figure out when to properly set to false
                            manager.proxy?.isBuffering.value = true
                        case .ended:
                            // Live streams will send stopped/ended events
                            guard manager.playbackItem?.baseItem.isLiveStream == false else { return }
                            manager.proxy?.isBuffering.value = false
                            manager.ended()
                        case .stopped: ()
                        // Stopped is ignored as the `MediaPlayerManager`
                        // should instead call this to be stopped, rather
                        // than react to the event.
                        case .error:
                            manager.proxy?.isBuffering.value = false
                            manager.error(ErrorMessage("VLC player is unable to perform playback"))
                        case .playing:
                            manager.proxy?.isBuffering.value = false
                            manager.setPlaybackRequestStatus(status: .playing)

                            let tracks = info.subtitleTracks.map { (index: $0.index, title: $0.title) }
                            manager.playbackItem?.getSubtitleIndexes(subtitleTracks: tracks)
                        case .paused:
                            manager.setPlaybackRequestStatus(status: .paused)
                        }

                        if let proxy = manager.proxy as? any VideoMediaPlayerProxy {
                            proxy.videoSize.value = info.videoSize
                        }
                    }
                    .onReceive(manager.$playbackItem) { playbackItem in
                        guard let playbackItem else { return }
                        proxy.playNewMedia(vlcConfiguration(for: playbackItem))
                    }
                    .onChange(of: manager.rate) {
                        proxy.setRate(.absolute(manager.rate))
                    }
                    .onChange(of: subtitleConfiguration) {
                        if let proxy = proxy as? MediaPlayerSubtitleConfigurable {
                            proxy.setSubtitleConfiguration(subtitleConfiguration)
                        }
                    }
            }
        }
    }
}
