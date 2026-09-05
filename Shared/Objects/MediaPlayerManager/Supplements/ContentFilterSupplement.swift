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
class ContentFilterSupplement: ObservableObject, MediaPlayerSupplement {

    let displayTitle: String = "Content Filter"
    let id: String = "ContentFilter"
    let contentFilterManager: ContentFilterManager

    init(contentFilterManager: ContentFilterManager) {
        self.contentFilterManager = contentFilterManager
    }

    var videoPlayerBody: some PlatformView {
        ContentFilterOverlay(contentFilterManager: contentFilterManager)
    }
}

extension ContentFilterSupplement {

    private struct ContentFilterOverlay: PlatformView {

        @Environment(\.safeAreaInsets)
        private var safeAreaInsets: EdgeInsets

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        @ObservedObject
        var contentFilterManager: ContentFilterManager

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

        var tvOSView: some View {
            regularContent
                .focusSection()
        }

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

        @ViewBuilder
        private var cueList: some View {
            ForEach(contentFilterManager.enabledCues) { cue in
                Button {
                    manager.proxy?.setSeconds(cue.startDuration)
                    manager.setPlaybackRequestStatus(status: .playing)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: cue.isMute ? "speaker.slash.fill" : "forward.fill")
                            .foregroundColor(cue.isMute ? .yellow : .orange)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cue.description ?? cue.category.capitalized)
                                    .font(UIDevice.isTV ? .callout : .subheadline)
                                    .fontWeight(.semibold)

                                Spacer()

                                Text("\(cue.start) - \(cue.end)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 8) {
                                Text(cue.category.uppercased())
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
                }
                .buttonStyle(.plain)
            }
        }

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
