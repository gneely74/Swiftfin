//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import SwiftUI

// swiftlint:disable hard_coded_display_string

/// Represents the dedicated \"Content Filter\" supplement panel presented in the media player's top drawer.
///
/// Conforms to `MediaPlayerSupplement` to integrate seamlessly alongside the Info and Chapters tabs,
/// displaying category breakdowns, cue statistics, and a sanitized, profanity-masked list of timestamps.
class ContentFilterSupplement: ObservableObject, MediaPlayerSupplement {

    /// Display title rendered on the drawer navigation tab button.
    let displayTitle: String = "Content Filter"

    /// Unique identifier for this supplement tab.
    let id: String = "ContentFilter"

    /// The active content filter manager providing cues and statistics.
    let contentFilterManager: ContentFilterManager

    /// Initializes a new Content Filter supplement tab.
    ///
    /// - Parameter contentFilterManager: The content filter manager instance driving playback filtering.
    init(contentFilterManager: ContentFilterManager) {
        self.contentFilterManager = contentFilterManager
    }

    /// The SwiftUI view body rendered inside the drawer container when this supplement is selected.
    var videoPlayerBody: some PlatformView {
        ContentFilterOverlay(contentFilterManager: contentFilterManager)
    }
}

extension ContentFilterSupplement {

    /// Internal platform view that renders the supplement drawer content across tvOS and iOS.
    private struct ContentFilterOverlay: PlatformView {

        @Environment(\.safeAreaInsets)
        private var safeAreaInsets: EdgeInsets

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @ObservedObject
        var contentFilterManager: ContentFilterManager

        /// iOS-specific layout responding to compact (iPhone portrait) and regular (iPad/landscape) modes.
        var iOSView: some View {
            CompactOrRegularView(
                isCompact: containerState.isCompact
            ) {
                compactContent
            } regularView: {
                regularContent
            }
            .padding(.leading, safeAreaInsets.leading)
            .padding(.trailing, safeAreaInsets.trailing)
        }

        /// tvOS-specific layout with focus section wrapping for Apple TV remote navigation.
        var tvOSView: some View {
            regularContent
                .focusSection()
        }

        /// Header banner displaying total cue counts, category breakdown, and shield icon.
        @ViewBuilder
        private var summaryHeader: some View {
            HStack(spacing: 16) {
                Image(systemName: "shield.lefthalf.filled")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIDevice.isTV ? 40 : 28, height: UIDevice.isTV ? 40 : 28)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(contentFilterManager.activeFilter?.title ?? "Content Filter")
                        .font(UIDevice.isTV ? .title3 : .headline)
                        .fontWeight(.bold)

                    HStack(spacing: 12) {
                        Label("\(contentFilterManager.muteCount) Mutes", systemImage: "speaker.slash.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Label("\(contentFilterManager.skipCount) Skips", systemImage: "forward.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let total = contentFilterManager.activeFilter?.cues.count {
                            Text("• \(total) Total Cues")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
        }

        /// Scrollable list of enabled cues displaying masked descriptions, timestamps, and action pills.
        @ViewBuilder
        private var cueList: some View {
            ForEach(contentFilterManager.enabledCues) { cue in
                Button(action: {}) {
                    HStack(spacing: 12) {
                        Image(systemName: cue.isMute ? "speaker.slash.fill" : "forward.fill")
                            .foregroundColor(cue.isMute ? .yellow : .orange)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ContentFilterWordMasker.mask(cue.description ?? cue.category.capitalized))
                                    .font(UIDevice.isTV ? .callout : .subheadline)
                                    .fontWeight(.semibold)

                                Spacer()

                                Text("\(cue.start) - \(cue.end)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 8) {
                                Text(ContentFilterWordMasker.mask(cue.category.uppercased()))
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2), in: Capsule())

                                Text(cue.action.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (cue.isMute ? Color.yellow : Color.orange).opacity(0.2),
                                        in: Capsule()
                                    )
                                    .foregroundColor(cue.isMute ? .yellow : .orange)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    #if os(tvOS)
                    .padding(.horizontal, 12)
                    #endif
                }
                #if os(tvOS)
                .buttonStyle(.card)
                #else
                    .buttonStyle(.plain)
                #endif
            }
        }

        /// Compact vertical layout for iPhone screens.
        @ViewBuilder
        private var compactContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    Divider()
                    cueList
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .edgePadding()
        }

        /// Regular layout for Apple TV and iPad displays.
        @ViewBuilder
        private var regularContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader
                    Divider()
                    cueList
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .edgePadding()
        }
    }
}
