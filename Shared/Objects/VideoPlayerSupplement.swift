//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// swiftlint:disable hard_coded_display_string
/// Identifies the supplementary content drawers and sheets available in the video player.
enum VideoPlayerSupplement: String, CaseIterable, Displayable, Equatable, Identifiable, Storable, SystemImageable, SupportedCaseIterable {

    /// Item details, synopsis, and metadata view.
    case info

    /// Scene chapters navigation list.
    case chapters

    /// Up Next episode playlist and queue.
    case queue

    /// Playback stream statistics and session metrics.
    case playbackInformation

    /// Cast and crew actor listing.
    case people

    /// ContentFilter cue listing, category controls, and filter toggles.
    case contentFilter

    /// Localized or user-facing display label for the supplement.
    var displayTitle: String {
        switch self {
        case .info:
            L10n.info
        case .chapters:
            L10n.chapters
        case .queue:
            L10n.episodes
        case .people:
            L10n.people
        case .playbackInformation:
            L10n.session
        case .contentFilter:
            // swiftlint:disable:next hard_coded_display_string
            "Content Filter"
        }
    }

    /// Unique string identifier matching the raw value.
    var id: String {
        rawValue
    }

    /// SF Symbol icon name representing the supplement in the toolbar.
    var systemImage: String {
        switch self {
        case .info:
            "info.circle.fill"
        case .chapters:
            "list.bullet.rectangle.fill"
        case .queue:
            "list.triangle"
        case .people:
            "person.2.fill"
        case .playbackInformation:
            "waveform.circle.fill"
        case .contentFilter:
            "shield.lefthalf.filled"
        }
    }

    /// The list of supplements enabled by default in user preferences.
    static let supportedCases: [VideoPlayerSupplement] = [.info, .chapters, .queue, .contentFilter]
}
