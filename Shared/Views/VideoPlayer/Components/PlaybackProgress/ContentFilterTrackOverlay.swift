//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct ContentFilterTrackOverlayContainer: View {

    @ObservedObject
    var contentFilterManager: ContentFilterManager
    let runtime: Duration

    var body: some View {
        if contentFilterManager.hasCues, runtime > .zero {
            ContentFilterTrackOverlay(cues: contentFilterManager.cues, runtime: runtime)
        }
    }
}

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
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: spanWidth, height: proxy.size.height)
                            .offset(x: xPos)
                    }

                    // Render Mute cues as high-contrast amber/yellow tick marks
                    ForEach(cues.filter { $0.enabled && $0.isMute }) { cue in
                        let startFraction = clamp(cue.startSeconds / totalSeconds, min: 0, max: 1)
                        let xPos = totalWidth * startFraction
                        let tickWidth: CGFloat = UIDevice.isTV ? 3.5 : 2.0

                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.85, blue: 0.0).opacity(0.95))
                            .frame(width: tickWidth, height: proxy.size.height)
                            .offset(x: max(0, xPos - (tickWidth / 2)))
                            .shadow(color: Color.black.opacity(0.4), radius: 1, x: 0, y: 0)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .allowsHitTesting(false)
    }
}
