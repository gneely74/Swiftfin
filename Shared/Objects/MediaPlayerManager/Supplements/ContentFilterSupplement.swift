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
                Image(systemName: contentFilterManager.isFilterEnabled ? "shield.lefthalf.filled" : "shield.slash")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIDevice.isTV ? 40 : 28, height: UIDevice.isTV ? 40 : 28)
                    .foregroundColor(contentFilterManager.isFilterEnabled ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(contentFilterManager.activeFilter?.title ?? "Content Filter")
                            .font(UIDevice.isTV ? .title3 : .headline)
                            .fontWeight(.bold)

                        if !contentFilterManager.isFilterEnabled {
                            Text("PAUSED")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.25), in: Capsule())
                                .foregroundColor(.red)
                        }
                    }

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
            .padding(.vertical, 4)
        }

        /// Formatted string representation of the active timing sync offset (e.g. `+0.5s` or `0.0s`).
        private var formattedOffset: String {
            let val = contentFilterManager.timeOffsetSeconds
            if abs(val) < 0.05 {
                return "0.0s"
            }
            return String(format: "%+.1fs", val)
        }

        /// Interactive control bar allowing session filter bypass and live subtitle/cue timing sync nudges.
        @ViewBuilder
        private var interactiveControlsBar: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: UIDevice.isTV ? 16 : 10) {
                    Button {
                        contentFilterManager.toggleFilterEnabled()
                    } label: {
                        Label(
                            contentFilterManager.isFilterEnabled ? "Filter Enabled" : "Filter Disabled",
                            systemImage: contentFilterManager.isFilterEnabled ? "checkmark.shield.fill" : "shield.slash.fill"
                        )
                        .font(UIDevice.isTV ? .callout : .caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            (contentFilterManager.isFilterEnabled ? Color.green : Color.secondary).opacity(0.22),
                            in: Capsule()
                        )
                        .foregroundColor(contentFilterManager.isFilterEnabled ? .green : .secondary)
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                        .buttonStyle(.plain)
                    #endif

                    Button {
                        contentFilterManager.toggleAudioMode()
                    } label: {
                        Label(
                            contentFilterManager.audioMode.displayTitle,
                            systemImage: contentFilterManager.audioMode == .mute ? "speaker.slash.fill" : "speaker.wave.1.fill"
                        )
                        .font(UIDevice.isTV ? .callout : .caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            (contentFilterManager.audioMode == .duck ? Color.blue : Color.secondary).opacity(0.22),
                            in: Capsule()
                        )
                        .foregroundColor(contentFilterManager.audioMode == .duck ? .blue : .primary)
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                        .buttonStyle(.plain)
                    #endif

                    Button {
                        contentFilterManager.adjustTimeOffset(by: -0.5)
                    } label: {
                        Label("-0.5s Earlier", systemImage: "minus.circle.fill")
                            .font(UIDevice.isTV ? .callout : .caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                        .buttonStyle(.plain)
                    #endif

                    Button {
                        contentFilterManager.resetTimeOffset()
                    } label: {
                        Label("Sync: \(formattedOffset)", systemImage: "clock.arrow.2.circlepath")
                            .font(UIDevice.isTV ? .callout : .caption)
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (abs(contentFilterManager.timeOffsetSeconds) > 0.05 ? Color.accentColor : Color.secondary).opacity(0.20),
                                in: Capsule()
                            )
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                        .buttonStyle(.plain)
                    #endif

                    Button {
                        contentFilterManager.adjustTimeOffset(by: 0.5)
                    } label: {
                        Label("+0.5s Later", systemImage: "plus.circle.fill")
                            .font(UIDevice.isTV ? .callout : .caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                        .buttonStyle(.plain)
                    #endif
                }
                .padding(.vertical, 4)
            }
        }

        /// Horizontal bar of category filter pills allowing users to toggle entire categories on or off.
        @ViewBuilder
        private var categoryChipsBar: some View {
            if contentFilterManager.categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: UIDevice.isTV ? 14 : 8) {
                        ForEach(contentFilterManager.categories, id: \.self) { category in
                            let isCatEnabled = contentFilterManager.isCategoryEnabled(category)
                            Button {
                                contentFilterManager.toggleCategory(category)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isCatEnabled ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isCatEnabled ? .yellow : .secondary)
                                    Text(ContentFilterWordMasker.mask(category))
                                        .font(UIDevice.isTV ? .caption : .caption2)
                                        .fontWeight(.semibold)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    (isCatEnabled ? Color.yellow : Color.secondary).opacity(0.18),
                                    in: Capsule()
                                )
                            }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                                .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        /// Scrollable list of cues displaying masked descriptions, timestamps, action pills, and interactive enable/disable toggles.
        @ViewBuilder
        private var cueList: some View {
            ForEach(contentFilterManager.cues) { cue in
                let isEffective = contentFilterManager.isFilterEnabled && cue.enabled
                Button {
                    contentFilterManager.toggleCue(cue.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: cue.enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isEffective ? (cue.isMute ? .yellow : .orange) : .secondary)
                            .frame(width: 22)

                        Image(systemName: cue.isMute ? "speaker.slash.fill" : "forward.fill")
                            .foregroundColor(isEffective ? (cue.isMute ? .yellow : .orange) : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(ContentFilterWordMasker.mask(cue.description ?? cue.category.capitalized))
                                    .font(UIDevice.isTV ? .callout : .subheadline)
                                    .fontWeight(.semibold)
                                    .strikethrough(!cue.enabled, color: .secondary)

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

                                Text(cue.enabled ? cue.action.uppercased() : "BYPASSED")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (isEffective ? (cue.isMute ? Color.yellow : Color.orange) : Color.secondary).opacity(0.2),
                                        in: Capsule()
                                    )
                                    .foregroundColor(isEffective ? (cue.isMute ? .yellow : .orange) : .secondary)
                            }
                        }
                    }
                    .opacity(isEffective ? 1.0 : 0.55)
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
                    interactiveControlsBar
                    categoryChipsBar
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
                VStack(alignment: .leading, spacing: 14) {
                    summaryHeader
                    interactiveControlsBar
                    categoryChipsBar
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
