//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

/// Floating pill badge displayed in the upper-right corner of the video player when audio is actively muted.
///
/// Features frosted-glass ultra-thin material styling, a yellow speaker-slash symbol,
/// and a clean category label (e.g. `MUTED • Language`) without ever displaying the muted word itself.
struct ContentFilterMuteBadge: View {

    /// Whether the mute indicator should be rendered on screen.
    let isMuted: Bool

    /// Optional category name for the active mute cue (e.g. "Language.GeneralProfanity").
    let cueCategory: String?

    /// Formats a raw server category string into a concise, human-readable label (e.g. `"Language"`).
    private var formattedCategory: String? {
        guard let cueCategory, !cueCategory.isEmpty else { return nil }
        let primary = cueCategory.split(separator: ".").first.map(String.init) ?? cueCategory
        return primary.isEmpty ? nil : primary
    }

    var body: some View {
        if isMuted {
            HStack(spacing: 8) {
                Image(systemName: "speaker.slash.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: UIDevice.isTV ? 20 : 14, height: UIDevice.isTV ? 20 : 14)
                    .foregroundColor(.yellow)

                Text(formattedCategory != nil ? "MUTED • \(formattedCategory!)" : "MUTED")
                    .font(UIDevice.isTV ? .caption : .caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, UIDevice.isTV ? 16 : 10)
            .padding(.vertical, UIDevice.isTV ? 10 : 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .opacity
            ))
            .allowsHitTesting(false)
        }
    }
}
