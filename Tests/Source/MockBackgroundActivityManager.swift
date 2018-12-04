//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import UIKit
import WireTransport
import WireTesting

/**
 * A controllable objects that mocks the behavior of UIApplication regarding background tasks.
 */

@objc class MockBackgroundActivityManager: NSObject, BackgroundActivityManager {

    /// Whether the activity is expiring.
    @objc private(set) var isExpiring: Bool = false

    /// A hook to intercept when a task is started.
    @objc var startTaskHandler: ((String?) -> Void)?

    /// A hook to intercept when a task is ended.
    @objc var endTaskHandler: ((String?) -> Void)?

    /// The number of tasks that can be active at the same time. Defaults to 1.
    @objc var limit: Int = 1

    /// The number of active tasks.
    @objc var numberOfTasks: Int {
        return tasks.count
    }

    // MARK: - Data

    private var lastIdentifier: ZMAtomicInteger = ZMAtomicInteger(integer: 1)

    private struct Task {
        let name: String?
        let expirationHandler: (() -> Void)?
    }

    private var tasks: [Int: Task] = [:]

    // MARK: - BackgroundActivityManager

    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> Int {
        assert(numberOfTasks + 1 <= limit, "Creating a new task would exceed the limit.")

        if isExpiring {
            return UIBackgroundTaskIdentifier.invalid.rawValue
        }

        let task = Task(name: name, expirationHandler: expirationHandler)
        let identifier = lastIdentifier.increment()

        tasks[identifier] = task
        startTaskHandler?(name)
        return identifier
    }

    func endBackgroundTask(_ task: Int) {
        assert(task != UIBackgroundTaskIdentifier.invalid.rawValue, "The task is invalid.")

        let name = tasks[task]?.name
        tasks[task] = nil
        endTaskHandler?(name)
    }

    // MARK: - Helpers

    @objc func triggerExpiration() {
        isExpiring = true

        tasks.values.forEach {
            $0.expirationHandler?()
        }
    }

    @objc func reset() {
        triggerExpiration()
        limit = 1
        isExpiring = false
        tasks.removeAll()
    }

}
