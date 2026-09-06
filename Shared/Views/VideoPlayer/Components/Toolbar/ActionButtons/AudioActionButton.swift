//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    struct Audio: View {

        @ViewContextContains(.isInMenu)
        private var isInMenu

        @EnvironmentObject
        private var manager: MediaPlayerManager

        @State
        private var selectedAudioStreamIndex: Int?

        private var systemImage: String {
            if selectedAudioStreamIndex == nil {
                VideoPlayerActionButton.audio.secondarySystemImage
            } else {
                VideoPlayerActionButton.audio.systemImage
            }
        }

        @ViewBuilder
        private func content(playbackItem: MediaPlayerItem) -> some View {
            ForEach(playbackItem.audioStreams, id: \.index) { stream in
                let streamIndex = stream.index
                let isSelected = (selectedAudioStreamIndex ?? playbackItem.selectedAudioStreamIndex) == streamIndex

                Button {
                    selectedAudioStreamIndex = streamIndex
                    playbackItem.selectedAudioStreamIndex = streamIndex
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
                        Section(L10n.audio) {
                            content(playbackItem: playbackItem)
                        }
                    }
                } label: {
                    Label(L10n.audio, systemImage: systemImage)
                }
                .videoPlayerActionButtonTransition()
                .onAppear {
                    selectedAudioStreamIndex = playbackItem.selectedAudioStreamIndex
                }
                .assign(playbackItem.$selectedAudioStreamIndex, to: $selectedAudioStreamIndex)
            }
        }
    }
}
