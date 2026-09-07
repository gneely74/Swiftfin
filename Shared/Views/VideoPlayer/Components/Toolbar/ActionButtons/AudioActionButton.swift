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

        var body: some View {
            if let playbackItem = manager.playbackItem {
                AudioMenu(playbackItem: playbackItem, isInMenu: isInMenu)
            }
        }
    }

    private struct AudioMenu: View {

        @ObservedObject
        var playbackItem: MediaPlayerItem

        var isInMenu: Bool

        private var systemImage: String {
            if playbackItem.selectedAudioStreamIndex == nil {
                VideoPlayerActionButton.audio.secondarySystemImage
            } else {
                VideoPlayerActionButton.audio.systemImage
            }
        }

        @ViewBuilder
        private var content: some View {
            ForEach(playbackItem.audioStreams, id: \.index) { stream in
                let streamIndex = stream.index
                let isSelected = playbackItem.selectedAudioStreamIndex == streamIndex

                Button {
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
            Menu {
                Group {
                    if isInMenu {
                        content
                    } else {
                        Section(L10n.audio) {
                            content
                        }
                    }
                }
                .buttonStyle(.automatic)
                .labelStyle(.automatic)
            } label: {
                Label(L10n.audio, systemImage: systemImage)
            }
        }
    }
}
