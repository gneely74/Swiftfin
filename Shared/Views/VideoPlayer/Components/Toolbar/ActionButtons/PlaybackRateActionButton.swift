//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

// TODO: set through proxy

extension VideoPlayer.PlaybackControls.Toolbar.ActionButtons {

    struct PlaybackRateMenu: View {

        @Default(.VideoPlayer.Playback.rates)
        private var rates: [Float]

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager

        var body: some View {
            Menu {
                Section(L10n.playbackSpeed) {
                    ForEach(rates, id: \.self) { rate in
                        let isSelected = abs(manager.rate - rate) < 0.01
                        Button {
                            manager.rate = rate
                        } label: {
                            if isSelected {
                                Label {
                                    Text(rate, format: .playbackRate)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(rate, format: .playbackRate)
                            }
                        }
                    }

                    if !rates.contains(where: { abs($0 - manager.rate) < 0.01 }) {
                        Divider()

                        Button {} label: {
                            Label {
                                Text(manager.rate, format: .playbackRate)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    L10n.playbackSpeed,
                    systemImage: VideoPlayerActionButton.playbackSpeed.systemImage
                )
            }
        }
    }
}
