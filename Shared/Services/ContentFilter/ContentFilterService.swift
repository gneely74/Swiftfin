//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Get
import JellyfinAPI
import Logging

/// Network service responsible for discovering and downloading content filter rules and
/// filtered subtitle tracks from the Jellyfin ContentFilter plugin API.
final class ContentFilterService {

    /// Shared singleton instance of the content filter service.
    static let shared = ContentFilterService()

    /// Diagnostic logger configured for Swiftfin network operations.
    private let logger = Logger.swiftfin()

    /// Private initializer enforcing singleton pattern.
    private init() {}

    /// Formats a raw 32-character hexadecimal string into a standard hyphenated UUID format (`8-4-4-4-12`).
    ///
    /// Jellyfin server endpoints frequently require standard UUID hyphenation to properly match library item keys.
    ///
    /// - Parameter rawID: The input identifier (with or without hyphens).
    /// - Returns: A canonical hyphenated UUID string if the input contains 32 hexadecimal characters;
    ///   otherwise, returns the unmodified `rawID`.
    static func formatGUID(_ rawID: String) -> String {
        let clean = rawID.replacingOccurrences(of: "-", with: "")
        guard clean.count == 32 else { return rawID }
        let p1 = clean.prefix(8)
        let p2 = clean.dropFirst(8).prefix(4)
        let p3 = clean.dropFirst(12).prefix(4)
        let p4 = clean.dropFirst(16).prefix(4)
        let p5 = clean.dropFirst(20)
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }

    /// Fetches the content filter response (cues and metadata) for a given media item from the Jellyfin server.
    ///
    /// Tries multiple endpoint paths (hyphenated GUID and raw ID) and utilizes a two-tier network approach:
    /// 1. **Primary**: Uses `session.client.data(for:)` which preserves Swiftfin authentication, proxy settings, and SSL delegates.
    /// 2. **Fallback**: Directly queries `effectiveServerURL` using `URLSession.shared` with explicit Emby/Jellyfin auth headers.
    ///
    /// - Parameters:
    ///   - itemID: The Jellyfin unique identifier of the media item.
    ///   - session: The active `UserSession` providing base URLs and authentication credentials.
    /// - Returns: A decoded `ContentFilterResponse` containing cues if found and successfully decoded; otherwise `nil`.
    func fetchFilter(for itemID: String, session: UserSession) async -> ContentFilterResponse? {
        let guid = Self.formatGUID(itemID)
        logger.info("ContentFilterService: Fetching filter for itemID=\(itemID), formattedGUID=\(guid)")

        let paths = [
            "ContentFilter/filters/\(guid)",
            "ContentFilter/filters/\(itemID)",
        ]

        for path in paths {
            // Primary: via session.client (preserves proxy delegate, custom SSL certs & auth headers)
            do {
                let request = Request<Data>(path: path, method: "GET")
                let response = try await session.client.data(for: request)
                if response.statusCode == 200 {
                    let decoder = JSONDecoder()
                    let filter = try decoder.decode(ContentFilterResponse.self, from: response.value)
                    logger.info("ContentFilterService: Successfully loaded \(filter.cues.count) cues from \(path)")
                    return filter
                }
            } catch {
                logger.warning("ContentFilterService: Client request to \(path) failed: \(error.localizedDescription)")
            }

            // Fallback: via explicit URLRequest against effectiveServerURL
            let baseURL = session.server.effectiveServerURL
            let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let endpointURL = baseURL.appendingPathComponent(relativePath)

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            let token = session.user.accessToken
            if !token.isEmpty {
                request.setValue("MediaBrowser Client=\"Swiftfin\", Token=\"\(token)\"", forHTTPHeaderField: "X-Emby-Authorization")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, urlResponse) = try await URLSession.shared.data(for: request)
                if let httpResponse = urlResponse as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    let decoder = JSONDecoder()
                    let filter = try decoder.decode(ContentFilterResponse.self, from: data)
                    logger
                        .info(
                            "ContentFilterService: Successfully loaded \(filter.cues.count) cues via URLSession fallback from \(endpointURL.absoluteString)"
                        )
                    return filter
                }
            } catch {
                logger
                    .error("ContentFilterService: Fallback request to \(endpointURL.absoluteString) failed: \(error.localizedDescription)")
            }
        }

        logger.warning("ContentFilterService: No content filter found or failed to decode for itemID=\(itemID)")
        return nil
    }

    /// Fetches and parses clean, profanity-filtered subtitle tracks in SubRip (`.srt`) format from the server.
    ///
    /// When available, filtered subtitles allow Swiftfin to display dialog text during active audio mutes
    /// without showing offensive words on screen.
    ///
    /// - Parameters:
    ///   - itemID: The Jellyfin unique identifier of the media item.
    ///   - session: The active `UserSession` providing base URLs and authentication credentials.
    /// - Returns: An array of sorted `ContentFilterSubtitleItem` structs, or `nil` if no subtitle is available.
    func fetchFilteredSubtitle(for itemID: String, session: UserSession) async -> [ContentFilterSubtitleItem]? {
        let guid = Self.formatGUID(itemID)
        let paths = [
            "ContentFilter/subtitles/\(guid).srt",
            "ContentFilter/subtitles/\(itemID).srt",
        ]

        for path in paths {
            do {
                let request = Request<Data>(path: path, method: "GET")
                let response = try await session.client.data(for: request)
                if response.statusCode == 200,
                   let srtContent = String(data: response.value, encoding: .utf8) ?? String(data: response.value, encoding: .isoLatin1)
                {
                    let items = ContentFilterSRTParser.parse(srt: srtContent)
                    if !items.isEmpty {
                        logger.info("ContentFilterService: Loaded \(items.count) filtered subtitle items from \(path)")
                        return items
                    }
                }
            } catch {
                logger.warning("ContentFilterService: Subtitle client request to \(path) failed: \(error.localizedDescription)")
            }

            let baseURL = session.server.effectiveServerURL
            let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let endpointURL = baseURL.appendingPathComponent(relativePath)

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            let token = session.user.accessToken
            if !token.isEmpty {
                request.setValue("MediaBrowser Client=\"Swiftfin\", Token=\"\(token)\"", forHTTPHeaderField: "X-Emby-Authorization")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, urlResponse) = try await URLSession.shared.data(for: request)
                if let httpResponse = urlResponse as? HTTPURLResponse, httpResponse.statusCode == 200,
                   let srtContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                {
                    let items = ContentFilterSRTParser.parse(srt: srtContent)
                    if !items.isEmpty {
                        logger.info("ContentFilterService: Loaded \(items.count) filtered subtitle items via URLSession fallback")
                        return items
                    }
                }
            } catch {
                logger.error("ContentFilterService: Fallback subtitle fetch failed: \(error.localizedDescription)")
            }
        }

        return nil
    }
}
