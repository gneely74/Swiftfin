# Agent Instructions & Guidelines (AGENTS.md)

Welcome, Agent! This repository is the active Swiftfin client repository modified with native **ContentFilter** stream-level audio muting, dialogue masking, scene skipping, HUD indicators, and tvOS playback stability.

---

## 🎯 Primary Missions

1. **Maintain & Extend ContentFilter Capabilities**:
   - Stream-level muting in `AVPlayer` and `VLCMediaPlayer`.
   - Autonomous client-side cue evaluation in `ContentFilterManager`.
   - Subtitle masking overlays and non-overriding subtitle preservation.
   - HUD badges, timeline scrubber markers, and supplement drawer tabs.
   - Remote WebSocket command handling via `ServerSocketManager` and `UserSessionManager+SocketCommands`.
2. **Preserve tvOS Focus & Playback Stability**:
   - Guarantee zero micro-stutters or view re-render thrashing.
   - Maintain 15-second supplement drawer inactivity auto-dismiss on Apple TV during playback.
   - Prevent focus snapping or menu jitter in audio/subtitle selection sheets.
3. **Multi-Platform Verification**:
   - Always verify and build for both iOS and tvOS targets.

---

## 📱 Mandatory Multi-Platform Policy: Always Build for Both iOS and tvOS
- **Always build both targets**: Whenever compiling, testing, archiving, or deploying Swiftfin changes, you **MUST build and verify for both iOS (`Swiftfin`) and tvOS (`Swiftfin tvOS`)**.
- **Synchronized Versioning**: Always keep `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION` synchronized across both `Swiftfin tvOS` and `Swiftfin iOS` targets in `Swiftfin.xcodeproj/project.pbxproj`.
- **TestFlight Deployment**: The deployment script `Scripts/deploy_to_testflight.sh` defaults to deploying `both` platforms (`tvos` and `ios`) sequentially. Never ship a build to TestFlight for only one platform unless explicitly instructed by the user.
- **Build Flag**: Always build with `-skipMacroValidation` to avoid macro validation failures on `swift-case-paths` and `StatefulMacros`.

---

## 📝 Mandatory Code Documentation Policy for All Future Agents
Whenever any agent adds, modifies, refactors, or fixes source code in this repository, the agent **MUST** strictly adhere to the following documentation rules:
1. **Document Every Code Element**:
   - Every class, struct, enum, protocol, property, initializer, method, and function modified or created **MUST** have comprehensive Swift Doc comments (`///`).
   - Doc comments must detail:
     - **Purpose & Rationale**: Why this element exists and how it fits into the broader architecture.
     - **Parameters (`- Parameter` / `- Parameters:`)**: Clear descriptions for each parameter, including valid ranges and unit types (e.g. seconds vs ticks).
     - **Return Value (`- Returns:`)**: What the method returns and conditions under which `nil` or special values are returned.
     - **Concurrency & Threading**: Explicitly document actor isolation (`@MainActor`), thread safety, and async behaviors.
     - **Side Effects**: Document mutations, timer restarts, UI transitions, or audio engine side effects.
2. **Synchronize Repository Documentation**:
   - Whenever code changes modify behavior, constants, or UX flows, the agent **MUST** immediately update the corresponding documentation:
     - [`Documentation/contentfilter.md`](Documentation/contentfilter.md)
     - Sibling repository specifications at `/Users/gneely/git/swiftfin-contentfilter/`.
3. **Maintain Code Comments Integrity**:
   - Never strip existing comments or docstrings.
   - Ensure newly written doc comments conform to Xcode / Swift doc standards so Quick Help (`Option + Click`) works perfectly.

---

## ⚠️ Critical Domain Knowledge
- **Do NOT attempt to control master hardware volume on tvOS**: Apple forbids apps from setting system volume levels.
- **Always use stream-level attenuation**: `AVPlayer.isMuted` and `VLCMediaPlayer.audio.isMuted` silence the app's audio stream without touching TV master volume or dropping video frames.
- **tvOS VLC Attenuation**: Always set both `audio.volume = 0` and `audio.isMuted = true` to overcome driver buffer bleed.
- **WebSocket Capabilities**: Swiftfin must include `.mute`, `.unmute`, and `.toggleMute` in `ServerSocketManager.swift`'s `supportedCommands` array for the Jellyfin server to acknowledge the client's ability to mute.
