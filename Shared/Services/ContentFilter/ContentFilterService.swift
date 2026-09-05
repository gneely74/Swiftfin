//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

final class ContentFilterService {

    static let shared = ContentFilterService()

    private init() {}

    func fetchFilter(for itemID: String, session: UserSession) async -> ContentFilterResponse? {
        let baseURL = session.server.effectiveServerURL

        let endpointURL: URL = if baseURL.absoluteString.hasSuffix("/") {
            baseURL.appendingPathComponent("ContentFilter/filters/\(itemID)")
        } else {
            baseURL.appendingPathComponent("/ContentFilter/filters/\(itemID)")
        }

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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let decoder = JSONDecoder()
            return try decoder.decode(ContentFilterResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchFilteredSubtitle(for itemID: String, session: UserSession) async -> [ContentFilterSubtitleItem]? {
        let baseURL = session.server.effectiveServerURL

        let endpointURL: URL = if baseURL.absoluteString.hasSuffix("/") {
            baseURL.appendingPathComponent("ContentFilter/subtitles/\(itemID).srt")
        } else {
            baseURL.appendingPathComponent("/ContentFilter/subtitles/\(itemID).srt")
        }

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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            guard let srtContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return nil
            }
            let items = ContentFilterSRTParser.parse(srt: srtContent)
            return items.isEmpty ? nil : items
        } catch {
            return nil
        }
    }
}
