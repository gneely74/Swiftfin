//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import SwiftUI

// TODO: feature implementations
//       - PiP
// TODO: Chromecast proxy

/// The proxy protocol defining top-down communication from Swiftfin's player
/// management layer to an underlying media player engine (e.g., AVPlayer, VLCMediaPlayer).
protocol MediaPlayerProxy: ObservableObject, MediaPlayerObserver {

    /// Published box indicating whether the media player is currently buffering data.
    var isBuffering: PublishedBox<Bool> { get }

    /// Published box indicating whether the media player's audio stream is currently muted.
    ///
    /// This represents stream-level attenuation and operates independently of system master volume.
    var isMuted: PublishedBox<Bool> { get }

    /// Resumes or initiates playback on the underlying player engine.
    func play()

    /// Pauses active playback on the underlying player engine.
    func pause()

    /// Stops playback and releases active player engine resources.
    func stop()

    /// Jumps forward in the current media stream by the specified duration.
    /// - Parameter seconds: The duration to advance playback.
    func jumpForward(_ seconds: Duration)

    /// Jumps backward in the current media stream by the specified duration.
    /// - Parameter seconds: The duration to rewind playback.
    func jumpBackward(_ seconds: Duration)

    /// Sets the playback speed multiplier.
    /// - Parameter rate: The target playback rate (e.g., 1.0 for normal, 1.25, 2.0).
    func setRate(_ rate: Float)

    /// Seeks playback to the specified absolute time offset from the beginning of the media.
    /// - Parameter seconds: The target playback position.
    func setSeconds(_ seconds: Duration)

    // MARK: - Audio Stream Muting

    /// Mutes the media player's audio stream using a smooth volume fade.
    func mute()

    /// Mutes the media player's audio stream.
    /// - Parameter faded: Whether to apply a fast volume fade ramp to prevent abrupt audio popping.
    func mute(faded: Bool)

    /// Unmutes the media player's audio stream using a smooth volume fade.
    func unmute()

    /// Unmutes the media player's audio stream.
    /// - Parameter faded: Whether to apply a fast volume fade ramp to prevent abrupt audio popping.
    func unmute(faded: Bool)

    /// Toggles the media player's audio mute state using a smooth volume fade.
    func toggleMute()

    /// Toggles the media player's audio mute state.
    /// - Parameter faded: Whether to apply a fast volume fade ramp to prevent abrupt audio popping.
    func toggleMute(faded: Bool)
}

extension MediaPlayerProxy {

    /// Mutes the media player's audio stream using default smooth fading (`faded: true`).
    func mute() {
        mute(faded: true)
    }

    /// Unmutes the media player's audio stream using default smooth fading (`faded: true`).
    func unmute() {
        unmute(faded: true)
    }

    /// Toggles the media player's audio mute state using default smooth fading (`faded: true`).
    func toggleMute() {
        toggleMute(faded: true)
    }
}

/// A specialized media player proxy for video rendering engines.
///
/// Extends ``MediaPlayerProxy`` with video frame metrics, track selection, aspect ratio control,
/// and SwiftUI view rendering.
@MainActor
protocol VideoMediaPlayerProxy: MediaPlayerProxy, MediaPlayerAudioTrackConfigurable, MediaPlayerSubtitleTrackConfigurable {

    /// The SwiftUI view type hosting the underlying video player layer.
    associatedtype VideoPlayerBody: View

    /// The natural pixel dimensions of the current video stream.
    var videoSize: PublishedBox<CGSize> { get }

    /// The count of dropped video frames reported by the decoder/renderer.
    var droppedFrames: PublishedBox<Int> { get }

    /// The count of demux or decode corrupted frames encountered during playback.
    var corruptedFrames: PublishedBox<Int> { get }

    // TODO: remove when container view handles aspect fill
    /// Adjusts whether the video fills the screen (cropping) or fits within bounds (letterboxing).
    /// - Parameter aspectFill: `true` to scale video to fill display bounds; `false` to fit with letterboxing.
    func setAspectFill(_ aspectFill: Bool)

    /// The SwiftUI view displaying video frames from the underlying player engine.
    @ViewBuilder
    @MainActor
    var videoPlayerBody: Self.VideoPlayerBody { get }
}

/// Protocol for media player proxies supporting runtime audio stream track selection.
protocol MediaPlayerAudioTrackConfigurable {

    /// Switches playback to the designated audio track.
    /// - Parameter stream: The media stream descriptor representing the selected audio track.
    func setAudioStream(_ stream: MediaStream)
}

/// Protocol for media player proxies supporting runtime subtitle track selection.
protocol MediaPlayerSubtitleTrackConfigurable {

    /// Switches display to the designated subtitle track.
    /// - Parameter stream: The media stream descriptor representing the selected subtitle track.
    func setSubtitleStream(_ stream: MediaStream)
}

/// Protocol for media player proxies supporting audio and subtitle track synchronization offsets.
protocol MediaPlayerOffsetConfigurable {

    /// Adjusts the audio synchronization delay.
    /// - Parameter seconds: The time offset duration to shift audio playback relative to video.
    func setAudioOffset(_ seconds: Duration)

    /// Adjusts the subtitle synchronization delay.
    /// - Parameter seconds: The time offset duration to shift subtitle cues relative to video.
    func setSubtitleOffset(_ seconds: Duration)
}

/// Protocol for media player proxies supporting visual styling configuration of subtitle text.
protocol MediaPlayerSubtitleConfigurable {

    /// Applies custom font, size, and color styling to rendered subtitles.
    /// - Parameter configuration: The user-selected subtitle appearance configuration.
    func setSubtitleConfiguration(_ configuration: SubtitleConfiguration)
}
