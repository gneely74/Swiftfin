//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    struct Subtitles: View {

        @ViewContextContains(.isInMenu)
        private var isInMenu

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @State
        private var selectedSubtitleStreamIndex: Int?

        private var systemImage: String {
            if selectedSubtitleStreamIndex == nil || selectedSubtitleStreamIndex == -1 {
                VideoPlayerActionButton.subtitles.secondarySystemImage
            } else {
                VideoPlayerActionButton.subtitles.systemImage
            }
        }

        @ViewBuilder
        private func content(playbackItem: MediaPlayerItem) -> some View {
            ForEach(playbackItem.subtitleStreams.prepending(.none), id: \.index) { stream in
                let streamIndex = stream.index
                let isSelected: Bool = {
                    let current = selectedSubtitleStreamIndex ?? playbackItem.selectedSubtitleStreamIndex ?? -1
                    let target = streamIndex ?? -1
                    return current == target
                }()

                Button {
                    selectedSubtitleStreamIndex = streamIndex
                    playbackItem.selectedSubtitleStreamIndex = streamIndex
                } label: {
                    if isSelected {
                        Label(stream.displayTitle ?? L10n.unknown, systemImage: "checkmark")
                    } else {
                        Text(stream.displayTitle ?? L10n.unknown)
                    }
                }
            }
        }

        var body: some View {
            if let playbackItem = manager.playbackItem {
                Menu {
                    if isInMenu {
                        content(playbackItem: playbackItem)
                    } else {
                        Section(L10n.subtitles) {
                            content(playbackItem: playbackItem)
                        }
                    }
                } label: {
                    Label(L10n.subtitles, systemImage: systemImage)
                }
                .videoPlayerActionButtonTransition()
                .onAppear {
                    selectedSubtitleStreamIndex = playbackItem.selectedSubtitleStreamIndex
                }
                .assign(playbackItem.$selectedSubtitleStreamIndex, to: $selectedSubtitleStreamIndex)
            }
        }
    }
}
