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

    private var effectiveRuntime: Duration {
        if runtime > .zero {
            return runtime
        }
        let maxCue = contentFilterManager.cues.map(\.endSeconds).max() ?? 0
        return .seconds(maxCue)
    }

    var body: some View {
        if contentFilterManager.hasCues, effectiveRuntime > .zero {
            ContentFilterTrackOverlay(cues: contentFilterManager.cues, runtime: effectiveRuntime)
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
            let trackHeight = proxy.size.height > 0 ? proxy.size.height : (UIDevice.isTV ? 14 : 10)

            if totalWidth > 0, totalSeconds > 0 {
                ZStack(alignment: .leading) {
                    // Render Skip cues as orange spans
                    ForEach(cues.filter { $0.enabled && $0.isSkip }) { cue in
                        let startFraction = clamp(cue.startSeconds / totalSeconds, min: 0, max: 1)
                        let endFraction = clamp(cue.endSeconds / totalSeconds, min: 0, max: 1)
                        let xPos = totalWidth * startFraction
                        let spanWidth = max(UIDevice.isTV ? 5 : 4, totalWidth * (endFraction - startFraction))

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: spanWidth, height: trackHeight)
                            .offset(x: xPos)
                    }

                    // Render Mute cues as high-contrast amber/yellow tick marks
                    ForEach(cues.filter { $0.enabled && $0.isMute }) { cue in
                        let startFraction = clamp(cue.startSeconds / totalSeconds, min: 0, max: 1)
                        let xPos = totalWidth * startFraction
                        let tickWidth: CGFloat = UIDevice.isTV ? 4.0 : 2.5

                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.85, blue: 0.0))
                            .frame(width: tickWidth, height: trackHeight)
                            .offset(x: max(0, xPos - (tickWidth / 2)))
                            .shadow(color: Color.black.opacity(0.6), radius: 1.5, x: 0, y: 0)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .allowsHitTesting(false)
    }
}
