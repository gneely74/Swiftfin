//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation

/// A pokeable inactivity timer that publishes a signal after a specified duration of silence.
///
/// Every call to `poke()` resets the countdown deadline. If no further calls occur before the deadline,
/// a `Void` event is emitted through the publisher.
///
/// Used by `VideoPlayerContainerState` to auto-hide the playback controls bar and supplement drawer
/// after user interaction ceases.
class PokeIntervalTimer: ObservableObject, Publisher {

    typealias Output = Void
    typealias Failure = Never

    /// The default timeout interval in seconds used when `poke()` is invoked without arguments.
    /// Can be adjusted dynamically (e.g. 10s for transport controls vs 15s for supplement drawers).
    var defaultInterval: TimeInterval

    /// Internal passthrough subject emitting timer expiration events.
    private var delaySubject: PassthroughSubject<Void, Never> = .init()

    /// The active scheduled dispatch work item, or `nil` if stopped.
    private var delayedWorkItem: DispatchWorkItem?

    /// Initializes a new poke timer with a default timeout interval.
    ///
    /// - Parameter defaultInterval: Timeout in seconds. Defaults to 5.
    init(defaultInterval: TimeInterval = 5) {
        self.defaultInterval = defaultInterval
    }

    /// Attaches a Combine subscriber to timer expiration events.
    func receive<S: Subscriber>(subscriber: S) where S.Failure == Never, S.Input == Void {
        delaySubject.receive(subscriber: subscriber)
    }

    /// Resets the inactivity timer deadline.
    ///
    /// Cancels any currently pending expiration and schedules a new one on the main queue.
    ///
    /// - Parameter interval: Optional custom timeout in seconds. If `nil`, `defaultInterval` is used.
    func poke(interval: TimeInterval? = nil) {

        let interval = interval ?? defaultInterval

        delayedWorkItem?.cancel()

        let newPollItem = DispatchWorkItem {
            self.delaySubject.send(())
        }

        delayedWorkItem = newPollItem

        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: newPollItem)
    }

    /// Immediately cancels any active countdown deadline without emitting an event.
    func stop() {
        delayedWorkItem?.cancel()
    }
}
