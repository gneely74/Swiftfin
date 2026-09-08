<div align="center">
  <img alt="Swiftfin" src="./Resources/primary-wide.svg">

  <h1>Swiftfin</h1>
  <img src="https://img.shields.io/badge/iOS-18+-red"/>
  <img src="https://img.shields.io/badge/tvOS-26+-red"/>
  <img src="https://img.shields.io/badge/Jellyfin-12.0-9962be"/>
  
  <a href="https://translate.jellyfin.org/engage/swiftfin/">
    <img src="https://translate.jellyfin.org/widgets/swiftfin/-/svg-badge.svg"/>
  </a>
  <a href="https://matrix.to/#/#jellyfin:matrix.org">
    <img src="https://img.shields.io/matrix/jellyfin:matrix.org">
  </a>
  <a href="https://discord.gg/zHBxVSXdBV">
    <img src="https://img.shields.io/badge/Talk%20on-Discord-brightgreen">
  </a>
</div>

<p align="center">
  <b>Swiftfin</b> is a modern video client for the <a href="https://github.com/jellyfin/jellyfin">Jellyfin</a> media server. Made using Swift to maximize direct play with the power of <b>VLC</b> and look <b>native</b> on all classes of Apple devices.
</p>

> [!IMPORTANT]
> ### 🛡️ Jellyfin ContentFilter Enhanced Build
> This build of **Swiftfin** is specially engineered to work with the [Jellyfin ContentFilter Plugin](https://github.com/gneely74/jellyfin-plugin-contentfilter):
> - **Stream-Level Dialogue Muting**: Silences profanity and flagged dialogue cues seamlessly at the player stream level (`AVPlayer.isMuted` / `VLCMediaPlayer.audio.isMuted`) with smooth audio fade ramping—leaving hardware TV master volume untouched and video playback uninterrupted.
> - **Automatic Scene Skipping**: Skips past graphic violence, gore, or nudity scenes with precision seek transitions, supporting both pre-fetched client cues and real-time server WebSocket commands.
> - **Player HUD & Indicators**: Features transient frosted-glass popup badges in the top-right corner for active mutes (`MUTED`) and scene skips (`SKIPPED (<Reason>)`), color-coded scrubber timeline markers, and an interactive **Content Filter** tab in the player supplement drawer.
> - **Filtered Subtitles During Mute**: When audio is muted, if no subtitle is selected, Swiftfin automatically presents filtered subtitles for the dialogue. If the viewer has already selected a preferred subtitle track, that selection is strictly respected and preserved.

## ⚡️ Download

<a href="https://apps.apple.com/us/app/swiftfin/id1604098728">
  <img height=75 alt="Download on the Apple App Store" src="./Resources/Download_on_the_App_Store_Badge_US-UK_RGB_blk_092917.svg"/>
</a>

## 🛠️ TestFlight

Use the TestFlight version to test new features and bug fixes before being published to the App Store. We are grateful for your time and resources for reporting new bugs.

<a href="https://testflight.apple.com/join/SqNPfdxq">
  <img height=75 alt="Get the beta on TestFlight" src="./Resources/testflight.svg"/>
</a>

## 📖 Documentation

Swiftfin provides detailed documentation to help you understand key aspects of the app and its development approach:

- [🛡️ ContentFilter Architecture](Documentation/contentfilter.md) — Architectural overview, modified files, and testing details for ContentFilter integration.
- [🎞️ Library Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/libraries.md) — Information on **library compatibility** and supported media types in Swiftin.
- [🎬 Media Playback](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md) — Learn about Swiftfin's **Native** and **Swiftfin** players and how their features vary.
- [🧩 OS Version Support](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/version.md) — Read about how we determine the **minimum supported OS** and which versions of iOS & tvOS are supported.
- [🐞 Common Issues](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/common_issues.md) — If you are experiencing an issue with Swiftfin, this is the best place to start.
- [💜 Supporting Development](https://jellyfin.org/docs/general/contributing/direct-donations) — Learn how you can **support the project developers** and help keep Swiftfin improving.

## ⚙️ Development

Thank you for your interest in Swiftfin! Please check out the [Contribution Guidelines](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/contributing.md) to get started.

## 📚 Translations

**Don't see Swiftfin in your language?**

Check out our [Weblate instance](https://translate.jellyfin.org/projects/swiftfin/) to help translate Swiftfin and other Jellyfin projects.

<a href="https://translate.jellyfin.org/engage/swiftfin/">
<img src="https://translate.jellyfin.org/widgets/swiftfin/-/multi-auto.svg"/>
</a>
