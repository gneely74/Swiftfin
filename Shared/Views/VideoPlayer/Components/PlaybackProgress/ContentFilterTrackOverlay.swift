//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct ContentFilterTrackOverlay: View {

    let cues: [ContentFilterCue]
    let runtime: Duration

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let totalSeconds = runtime.seconds

            if totalWidth > 0, totalSeconds > 0 {
                ZStack(alignment: .leading) {
                    // Render Skip cues as orange spans
                    ForEach(cues.filter { $0.enabled && $0.isSkip }) { cue in
                        let startFraction = clamp(cue.startSeconds / totalSeconds, min: 0, max: 1)
                        let endFraction = clamp(cue.endSeconds / totalSeconds, min: 0, max: 1)
                        let xPos = totalWidth * startFraction
                        let spanWidth = max(UIDevice.isTV ? 4 : 3, totalWidth * (endFraction - startFraction))

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange.opacity(0.85))
                            .frame(width: spanWidth, height: proxy.size.height)
                            .offset(x: xPos)
                    }

                    // Render Mute cues as yellow tick marks
                    ForEach(cues.filter { $0.enabled && $0.isMute }) { cue in
                        let startFraction = clamp(cue.startSeconds / totalSeconds, min: 0, max: 1)
                        let xPos = totalWidth * startFraction
                        let tickWidth: CGFloat = UIDevice.isTV ? 3.0 : 1.5

                        Rectangle()
                            .fill(Color.yellow.opacity(0.95))
                            .frame(width: tickWidth, height: proxy.size.height)
                            .offset(x: max(0, xPos - (tickWidth / 2)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
