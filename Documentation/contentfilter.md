# ContentFilter Architecture & Modifications

This document details the modifications made to Swiftfin to integrate with the [Jellyfin ContentFilter Plugin](https://github.com/gneely74/jellyfin-plugin-contentfilter).

---

## 1. Feature Summary

- **Stream-Level Audio Muting**: Zero-latency digital stream muting for profanity and dialogue cues using `AVPlayer.isMuted` and `VLCMediaPlayer.audio.isMuted`. Hardware master TV volume remains completely untouched and video playback is uninterrupted.
- **Dual VLC tvOS Attenuation**: Simultaneously zeroes `audio.volume = 0` and sets `audio.isMuted = true` to prevent tvOS audio hardware buffer bleed in VLCKit.
- **High-Frequency Player Clock**: Hooks into `AVPlayer` with a 100ms periodic time observer for millisecond-accurate cue entry/exit.
- **Plosive Lead & Tail Padding**: Applies 250ms lead padding (pre-mute) to suppress explosive consonants ('f', 'p', 'b') and 200ms tail padding (post-mute).
- **Seamless Mute Bridging**: Coalesces consecutive dialogue cues occurring within 1.5 seconds to eliminate rapid audio flutter.
- **Masked Dialogue Subtitle Overlay**: 
  - When subtitles are off: presents clean, masked dialogue subtitles during mute cues.
  - When subtitles are on: renders an opaque, high-contrast black box directly over the active subtitle track during mute cues, obscuring offensive words without overriding or desyncing user preferences.
- **HUD & Visual Badges**: Frosted-glass `MUTED (<Reason>)` popup badge, orange `SKIPPED (<Reason>)` popup badge (auto-dismisses after 2.6s), and color-coded scrubber timeline markers.
- **Supplement Drawer Tab**: Dedicated "Content Filter" tab with category breakdowns, cue counts, and clean non-interactive cue list with profanity masking.
- **Supplement Drawer Auto-Dismiss (tvOS)**: 15-second inactivity timeout when playing that automatically collapses the drawer and fades out the overlay back to full-screen video. Pausing preserves the UI indefinitely.
- **tvOS Playback Stability**: Eliminated 10Hz SwiftUI view re-render churn from sub-second timer state mutations; resolved audio/subtitle picker focus snapping.

---

## 2. Modified Files & Directories

### Core Service & Engine
- `Shared/Services/ContentFilter/ContentFilterModels.swift`: Cue models, severity, and category definitions.
- `Shared/Services/ContentFilter/ContentFilterService.swift`: Network client for `/ContentFilter/filters/{id}` and `/ContentFilter/subtitles/{id}.srt`.
- `Shared/Services/ContentFilter/ContentFilterWordMasker.swift`: Regex word-boundary profanity masking.
- `Shared/Objects/MediaPlayerManager/ContentFilterManager.swift`: Autonomous client-side evaluation engine.

### Player Engines & Remote Commands
- `Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy.swift`: `isMuted`, `mute()`, `unmute()`, `toggleMute()`.
- `Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy+AVPlayer.swift`: AVPlayer stream-level muting implementation.
- `Shared/Objects/MediaPlayerManager/MediaPlayerProxy/MediaPlayerProxy+VLC.swift`: VLCMediaPlayer dual volume/mute attenuation.
- `Shared/Services/ServerSocketManager.swift`: Adds `.mute`, `.unmute`, `.toggleMute` to `supportedCommands`.
- `Shared/Services/UserSession/UserSessionManager+SocketCommands.swift`: Dispatches remote WebSocket commands to player proxy.

### UI, HUD & Supplements
- `Shared/Views/VideoPlayer/Components/ContentFilterMuteBadge.swift`: Frosted-glass mute indicator.
- `Shared/Views/VideoPlayer/Components/ContentFilterSkipBadge.swift`: Frosted-glass skip indicator.
- `Shared/Views/VideoPlayer/Components/ContentFilterSubtitleOverlay.swift`: Masked dialogue subtitle overlay.
- `Shared/Views/VideoPlayer/Components/ContentFilterTrackOverlay.swift`: Scrubber track timeline markers.
- `Shared/Objects/MediaPlayerManager/Supplements/ContentFilterSupplement.swift`: Content Filter supplement drawer tab.

### State Management & Auto-Dismiss
- `Shared/Objects/PokeIntervalTimer.swift`: Mutable default interval for dynamic timeouts.
- `Shared/Objects/VideoPlayerContainerState.swift`: Supplement inactivity auto-dismiss and focus management.
- `Swiftfin tvOS/Views/VideoPlayer/PlaybackControls/PlaybackControls.swift`: Playback status observers and timer poke triggers.

### Build & Deployment
- `Scripts/deploy_to_testflight.sh`: Dual-platform automated archive, export, and upload pipeline.

---

## 3. Unit Tests

Located in `SwiftfinTests/ContentFilterTests.swift`. Run via Xcode (`Cmd + U`) or CLI:
```bash
xcodebuild test -project Swiftfin.xcodeproj -scheme "Swiftfin tvOS" -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" -skipMacroValidation
```
