//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import Foundation
import JellyfinAPI
import UIKit

extension UserSessionManager {

    /// Sets up observation on WebSocket remote control command streams (play, playstate, and general commands)
    /// emitted by the current active session's ``ServerSocketManager``.
    func observeSocketCommands() {
        $currentSession
            .map { session -> AnyPublisher<PlayRequest, Never> in
                session?.serverSocketManager.playCommands ?? Combine.Empty<PlayRequest, Never>().eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] command in
                Task { @MainActor in
                    self?.onReceive(playCommand: command)
                }
            }
            .store(in: &cancellables)

        $currentSession
            .map { session -> AnyPublisher<PlaystateRequest, Never> in
                session?.serverSocketManager.playstateCommands ?? Combine.Empty<PlaystateRequest, Never>().eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] command in
                Task { @MainActor in
                    self?.onReceive(playstateCommand: command)
                }
            }
            .store(in: &cancellables)

        $currentSession
            .map { session -> AnyPublisher<GeneralCommand, Never> in
                session?.serverSocketManager.generalCommands ?? Combine.Empty<GeneralCommand, Never>().eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] command in
                Task { @MainActor in
                    self?.onReceive(generalCommand: command)
                }
            }
            .store(in: &cancellables)
    }

    /// Dispatches remote control play request commands arriving from the server socket.
    /// - Parameter playCommand: The deserialized play request from the Jellyfin server.
    @MainActor
    private func onReceive(playCommand: PlayRequest) {
        guard let currentSession else { return }

        switch playCommand.playCommand {
        case .playNow, .none:
            let itemIDs = playCommand.itemIDs ?? []
            guard let itemID = itemIDs[safe: playCommand.startIndex ?? 0] ?? itemIDs.first else { return }

            playItem(
                id: itemID,
                mediaSourceID: playCommand.mediaSourceID,
                startPositionTicks: playCommand.startPositionTicks,
                userSession: currentSession
            )
        case .playNext:
            onReceive(playstateCommand: .init(command: .nextTrack, controllingUserID: playCommand.controllingUserID))
        case .playLast:
            onReceive(playstateCommand: .init(command: .previousTrack, controllingUserID: playCommand.controllingUserID))
        case .playInstantMix:
            // TODO: Implement instant mix
            return
        case .playShuffle:
            // TODO: Implement shuffle playback
            return
        }
    }

    /// Dispatches remote control playstate requests (e.g. pause, playPause, seek, rewind, fastForward).
    ///
    /// Incorporates ContentFilter intelligence during seek commands:
    /// 1. Prevents unwanted fallback-to-skip seeks that would cut out spoken words when client-side muting is handling the cue.
    /// 2. Dispatches visual skip toast indicators when a legitimate scene skip occurs.
    /// - Parameter playstateCommand: The deserialized playstate command from the Jellyfin server.
    @MainActor
    private func onReceive(playstateCommand: PlaystateRequest) {
        guard let mediaPlayerManager else { return }

        switch playstateCommand.command {
        case .fastForward:
            mediaPlayerManager.proxy?.jumpForward(Defaults[.VideoPlayer.jumpForwardInterval].rawValue)
        case .nextTrack:
            guard let nextItem = mediaPlayerManager.queue?.nextItem else { return }
            mediaPlayerManager.playNewItem(provider: nextItem)
        case .pause:
            mediaPlayerManager.setPlaybackRequestStatus(status: .paused)
        case .playPause:
            mediaPlayerManager.togglePlayPause()
        case .previousTrack:
            guard let previousItem = mediaPlayerManager.queue?.previousItem else { return }
            mediaPlayerManager.playNewItem(provider: previousItem)
        case .rewind:
            mediaPlayerManager.proxy?.jumpBackward(Defaults[.VideoPlayer.jumpBackwardInterval].rawValue)
        case .seek:
            guard let ticks = playstateCommand.seekPositionTicks else { return }
            let currentSec = mediaPlayerManager.seconds.seconds
            let targetSec = Duration.ticks(ticks).seconds

            // Guard against unwanted fallback-to-skip seeks that cut out spoken words when Swiftfin mutes client-side
            if mediaPlayerManager.contentFilterManager.hasCues,
               let _ = mediaPlayerManager.contentFilterManager.cues.first(where: { cue in
                   cue.enabled && cue.isMute &&
                       abs(cue.endSeconds - targetSec) < 1.5 &&
                       currentSec >= (cue.startSeconds - 3.0) && currentSec <= cue.endSeconds
               })
            {
                return
            }

            mediaPlayerManager.proxy?.setSeconds(.ticks(ticks))

            if let currentCue = mediaPlayerManager.contentFilterManager.currentActiveCue, currentCue.isSkip {
                mediaPlayerManager.contentFilterManager.triggerSkip(reason: currentCue.description ?? currentCue.category)
            } else if targetSec > currentSec,
                      let skippedCue = mediaPlayerManager.contentFilterManager.skipCues.first(where: {
                          $0.startSeconds >= (currentSec - 2.0) && $0.startSeconds <= (targetSec + 1.0)
                      })
            {
                mediaPlayerManager.contentFilterManager.triggerSkip(reason: skippedCue.description ?? skippedCue.category)
            }
        case .stop:
            mediaPlayerManager.stop()
        case .unpause:
            mediaPlayerManager.setPlaybackRequestStatus(status: .playing)
        case .none:
            return
        }
    }

    /// Dispatches general commands from the server socket, including track selection and stream-level audio muting.
    ///
    /// Routes `.mute`, `.unmute`, and `.toggleMute` directly to ``MediaPlayerProxy`` to perform stream-level
    /// audio attenuation without modifying master hardware volume.
    /// - Parameter generalCommand: The deserialized general command from the Jellyfin server.
    @MainActor
    private func onReceive(generalCommand: GeneralCommand) {
        guard let currentSession else { return }

        switch generalCommand.name {
        case .setAudioStreamIndex:
            guard let index = generalCommand.arguments?["Index"], let index = Int(index) else { return }
            mediaPlayerManager?.playbackItem?.selectedAudioStreamIndex = index
        case .setMaxStreamingBitrate:
            guard let bitrate = generalCommand.arguments?["Bitrate"], let bitrate = Int(bitrate) else { return }
            mediaPlayerManager?.setBitrate(bitrate: PlaybackBitrate(for: bitrate))
        case .setSubtitleStreamIndex:
            guard let index = generalCommand.arguments?["Index"], let index = Int(index) else { return }
            mediaPlayerManager?.playbackItem?.selectedSubtitleStreamIndex = index
        case .displayContent:
            guard let itemID = generalCommand.arguments?["ItemId"] else { return }
            routePublisher.send(.item(id: itemID))
        case .playMediaSource:
            guard let itemID = generalCommand.arguments?["ItemId"] else { return }
            playItem(
                id: itemID,
                mediaSourceID: generalCommand.arguments?["MediaSourceId"],
                userSession: currentSession
            )
        case .playTrailers:
            guard let itemID = generalCommand.arguments?["ItemId"] else { return }
            playTrailers(itemID: itemID, userSession: currentSession)
        case .displayMessage:
            // TODO: Implement via Toast
            return
        case .setPlaybackOrder, .setRepeatMode, .setShuffleQueue:
            // TODO: Implement when queue shuffling exists
            return
        case .mute:
            mediaPlayerManager?.proxy?.mute()
        case .unmute:
            mediaPlayerManager?.proxy?.unmute()
        case .toggleMute:
            mediaPlayerManager?.proxy?.toggleMute()
        case .setVolume, .volumeDown, .volumeUp:
            // Master volume commands remain ignored on tvOS
            return
        default:
            // Ignore navigation commands
            return
        }
    }

    /// Fetches item metadata and transitions the app into active video playback.
    ///
    /// If playback is already in progress, replaces the current playback item in ``MediaPlayerManager``;
    /// otherwise, pushes a video player route to the navigation stack.
    /// - Parameters:
    ///   - id: The Jellyfin item identifier.
    ///   - mediaSourceID: Optional media source identifier within the item.
    ///   - startPositionTicks: Optional starting playback offset in ticks (10,000 ticks = 1 ms).
    ///   - userSession: The active user session.
    @MainActor
    private func playItem(
        id: String,
        mediaSourceID: String? = nil,
        startPositionTicks: Int? = nil,
        userSession: UserSession
    ) {
        Task { @MainActor in
            do {
                let item = try await BaseItemDto(id: id).getFullItem(userSession: userSession)
                let mediaSource = item.mediaSources?.first {
                    $0.id == mediaSourceID
                }

                guard var provider = item.getPlaybackItemProvider(
                    userSession: userSession,
                    mediaSource: mediaSource
                ) else { return }

                if let startPositionTicks {
                    provider = provider.modifyingItem { item in
                        if item.userData == nil {
                            item.userData = UserItemDataDto(key: "")
                        }
                        item.userData?.playbackPositionTicks = startPositionTicks
                    }
                }

                if hasActivePlayback, let mediaPlayerManager {
                    await mediaPlayerManager.playNewItem(provider: provider)
                } else {
                    routePublisher.send(.videoPlayer(provider: provider))
                }
            } catch {
                logger.error(
                    "Unable to play item from socket command",
                    metadata: ["error": .string(error.localizedDescription)]
                )
            }
        }
    }

    /// Fetches and plays trailers for the specified media item.
    ///
    /// Attempts local trailer playback first; falls back to opening external remote trailers
    /// via YouTube deep links or browser URL.
    /// - Parameters:
    ///   - itemID: The media item identifier whose trailers should be played.
    ///   - userSession: The active user session.
    @MainActor
    private func playTrailers(itemID: String, userSession: UserSession) {
        Task { @MainActor in
            do {
                let request = Paths.getLocalTrailers(itemID: itemID, userID: userSession.user.id)
                let response = try await userSession.client.send(request)

                if let trailerID = response.value.first?.id {
                    playItem(id: trailerID, userSession: userSession)
                    return
                }

                let item = try await BaseItemDto(id: itemID).getFullItem(userSession: userSession)
                guard let urlString = item.remoteTrailers?.first?.url else { return }

                #if os(tvOS)
                guard let externalURL = ExternalTrailerURL(string: urlString),
                      externalURL.canBeOpened
                else { return }

                await UIApplication.shared.open(externalURL.deepLink)
                #else
                guard let url = URL(string: urlString),
                      UIApplication.shared.canOpenURL(url)
                else { return }

                await UIApplication.shared.open(url)
                #endif
            } catch {
                logger.error(
                    "Unable to play trailers from socket command",
                    metadata: ["error": .string(error.localizedDescription)]
                )
            }
        }
    }
}
