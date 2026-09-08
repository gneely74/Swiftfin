//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// High-contrast dialogue subtitle overlay displayed near the bottom of the video player during audio mutes.
///
/// Features an opaque solid black background that occludes underlying burned-in or native subtitles,
/// ensuring offensive words are masked on screen without altering or desyncing the user's active subtitle track.
struct ContentFilterSubtitleOverlay: View {

    /// The sanitized dialogue text to render, or `nil` if no dialogue is currently spoken.
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            VStack {
                Spacer()

                Text(ContentFilterWordMasker.mask(text))
                    .font(UIDevice.isTV ? .title3 : .body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                    )
                    .padding(.bottom, UIDevice.isTV ? 90 : 60)
                    .padding(.horizontal, 40)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
