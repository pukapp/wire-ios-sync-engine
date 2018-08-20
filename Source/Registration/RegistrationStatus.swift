//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

import Foundation

/// Used to signal changes to the registration state.
public protocol RegistrationStatusDelegate: class {
    /// The team was successfully created.
    func teamRegistered()

    /// The user was successfully registered.
    func userRegistered()

    /// The user could not be created because of an error.
    func userRegistrationFailed(with error: Error)

    /// The team could not be created because of an error.
    func teamRegistrationFailed(with error: Error)

    /// A message was sent with the activation code.
    func activationCodeSent()

    /// The activation code could not be sent because of an error.
    func activationCodeSendingFailed(with error: Error)

    /// The registered credential was activated sucessfully.
    func activationCodeValidated()

    /// The registered credential could not be created because of an error.
    func activationCodeValidationFailed(with error: Error)
}

/**
 * A protocol for objects that handle registration of users and teams.
 */

protocol RegistrationStatusProtocol: class {
    /// The current registration phase.
    var phase: RegistrationPhase { get }

    /// An error occured during the current registration phase.
    func handleError(_ error: Error)

    /// The current registration phase succeeded.
    func success()
}

// MARK: - Registration Status

/**
 * Handles regisitration of users and teams.
 */

public class RegistrationStatus: RegistrationStatusProtocol {

    /// The current phase of registration.
    public var phase : Phase = .none

    /// Whether registration completed.
    public internal(set) var completedRegistration: Bool = false

    /// The object to send notifications when the status changes.
    public weak var delegate: RegistrationStatusDelegate?

    // MARK: - Actions

    /**
     * Sends the activation code to validate the given credential.
     * - parameter credential: The credential (phone or email) to activate.
     */

    public func sendActivationCode(to credential: UnverifiedCredential) {
        phase = .sendActivationCode(credential: credential)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }

    /**
     * Verifies the activation code for the specified credential witht he backend.
     * - parameter credential: The credential (phone or email) to activate.
     * - parameter code: The activation code sent by the backend that needs to be verified.
     */

    public func checkActivationCode(credential: UnverifiedCredential, code: String) {
        phase = .checkActivationCode(credential: credential, code: code)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }

    /**
     * Creates the user with the backend.
     * - parameter user: The object containing all information needed to register the user.
     */

    public func create(user: UnregisteredUser) {
        phase = .createUser(user: user)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }

    /**
     * Creates the team with the backend.
     * - parameter team: The object containing all information needed to register the team.
     */

    public func create(team: UnregisteredTeam) {
        phase = .createTeam(team: team)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }

    // MARK: - Event Handling

    func handleError(_ error: Error) {
        switch self.phase {
        case .sendActivationCode:
            self.delegate?.activationCodeSendingFailed(with: error)
        case .checkActivationCode:
            self.delegate?.activationCodeValidationFailed(with: error)
        case .createTeam:
            delegate?.teamRegistrationFailed(with: error)
        case .createUser:
            delegate?.userRegistrationFailed(with: error)
        case .none:
            break
        }
        self.phase = .none
    }

    func success() {
        switch self.phase {
        case .sendActivationCode:
            self.delegate?.activationCodeSent()
        case .checkActivationCode:
            self.delegate?.activationCodeValidated()
        case .createTeam:
            self.completedRegistration = true
            delegate?.teamRegistered()
        case .createUser:
            self.completedRegistration = true
            delegate?.userRegistered()
        case .none:
            break
        }
        self.phase = .none
    }

}
