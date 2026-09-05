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

final class ContentFilterService {

    static let shared = ContentFilterService()
    private let logger = Logger.swiftfin()

    private init() {}

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
