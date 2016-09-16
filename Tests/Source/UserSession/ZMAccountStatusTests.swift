// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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


@testable import zmessaging


class MockCookieStorage : NSObject, ZMCookieProvider {
    
    var shouldReturnCookie : Bool = false
    
    var authenticationCookieData : Data! {
        if shouldReturnCookie {
            return Data()
        }
        return nil
    }
}


class ZMAccountStatusTests : MessagingTest {

    var sut : ZMAccountStatus!
    
    override func tearDown() {
        sut = nil
        super.tearDown()
        
    }
    
    func testThatIfItLaunchesWithoutCookieButWithHistoryItSetsAccountStateToDeactivatedAccount(){
        // given
        ZMConversation.insertNewObject(in: self.uiMOC)
        ZMConversation.insertNewObject(in: self.uiMOC)

        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        
        // when
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceDeactivatedAccount)
        
    }
    
    func testThatIfItLaunchesWithoutCookieNorHistorytItSetsAccountStateToNewAccount(){
        // given
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        
        // when
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)
    }
    
    func testThatIfItLaunchesWithCookieAndHistoryItSetsAccountStateToExistingAccount(){
        // given
        ZMConversation.insertNewObject(in: self.uiMOC)
        ZMConversation.insertNewObject(in: self.uiMOC)
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = true
        
        // when
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }

    
    func testThatWhenInitialSyncCompletesItSetsAccountStateToExistingAcccount(){
        // given
        ZMConversation.insertNewObject(in: self.uiMOC)
        ZMConversation.insertNewObject(in: self.uiMOC)
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = true
        
        // when
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }
    
    func testThatWhenLoginSucceedsWithoutRegistrationItSwitchesToNewDeviceExistingAccount() {
        // given
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)
        
        // when
        ZMUserSessionAuthenticationNotification.notifyAuthenticationDidSucceed()
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceExistingAccount)
    }
    
    func testThatWhenAuthenticationSucceedsOnOldAccountItDoesNotSwitchToNewDeviceExistingAccount() {
        // given
        ZMConversation.insertNewObject(in: self.uiMOC)
        ZMConversation.insertNewObject(in: self.uiMOC)
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = true
        
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
        
        // when
        ZMUserSessionAuthenticationNotification.notifyAuthenticationDidSucceed()
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }
    
    func testThatWhenLoginSucceedsWithRegistrationItDoesNotSwitchToNewDeviceExistingAccount() {
        // given
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)
        
        // when
        ZMUserSessionRegistrationNotification.notifyEmailVerificationDidSucceed()
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        ZMUserSessionAuthenticationNotification.notifyAuthenticationDidSucceed()
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)
    }
    
    
    func testThatItAppendsANewDeviceMessageWhenSyncCompletes_NewDevice() {
        // given
        createSelfClient()
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)

        ZMUserSessionAuthenticationNotification.notifyAuthenticationDidSucceed()
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        let oneOnOne = ZMConversation.insertNewObject(in: self.uiMOC)
        oneOnOne.conversationType = .oneOnOne
        let group = ZMConversation.insertNewObject(in: self.uiMOC)
        group.conversationType = .group
        let connection = ZMConversation.insertNewObject(in: self.uiMOC)
        connection.conversationType = .Connection
        let selfConv = ZMConversation.insertNewObject(in: self.uiMOC)
        selfConv.conversationType = .Self
        
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceExistingAccount)

        // when
        NotificationCenter.default.post(name: "ZMInitialSyncCompletedNotification", object: nil)
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))

        // then
        XCTAssertEqual(oneOnOne.messages.count, 1)
        XCTAssertEqual(group.messages.count, 1)
        XCTAssertEqual(connection.messages.count, 0)
        if let oneOnOneMsg = oneOnOne.messages.lastObject as? ZMSystemMessage, let groupMsg = oneOnOne.messages.lastObject as? ZMSystemMessage {
            XCTAssertEqual(oneOnOneMsg.systemMessageType, ZMSystemMessageType.UsingNewDevice)
            XCTAssertEqual(groupMsg.systemMessageType, ZMSystemMessageType.UsingNewDevice)
        } else {
            XCTFail()
        }
        
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }
    
    func testThatItAppendsAReactivedDeviceMessageWhenSyncCompletes_ReactivatedDevice() {
        // given
        createSelfClient()
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        
        let oneOnOne = ZMConversation.insertNewObject(in: self.uiMOC)
        oneOnOne.conversationType = .oneOnOne
        let group = ZMConversation.insertNewObject(in: self.uiMOC)
        group.conversationType = .group
        let connection = ZMConversation.insertNewObject(in: self.uiMOC)
        connection.conversationType = .Connection
        let selfConv = ZMConversation.insertNewObject(in: self.uiMOC)
        selfConv.conversationType = .Self
        
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceDeactivatedAccount)
        
        // when
        NotificationCenter.default.post(name: "ZMInitialSyncCompletedNotification", object: nil)
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(oneOnOne.messages.count, 1)
        XCTAssertEqual(group.messages.count, 1)
        XCTAssertEqual(connection.messages.count, 0)
        if let oneOnOneMsg = oneOnOne.messages.lastObject as? ZMSystemMessage, let groupMsg = oneOnOne.messages.lastObject as? ZMSystemMessage {
            XCTAssertEqual(oneOnOneMsg.systemMessageType, ZMSystemMessageType.ReactivatedDevice)
            XCTAssertEqual(groupMsg.systemMessageType, ZMSystemMessageType.ReactivatedDevice)
        } else {
            XCTFail()
        }
        
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }
    
    func testThatWhenSyncCompletesItSwitchesToOldDeviceActiveAccount_NewAccountNewDevice(){
        // given
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = false
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.NewDeviceNewAccount)
        
        // when
        NotificationCenter.default.post(name: "ZMInitialSyncCompletedNotification", object: nil)
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    }
    
    func testThatItSwitchesToOldDeviceDeactivatedAccountWhneAuthenticationFails() {
    
        // given
        ZMConversation.insertNewObject(in: self.uiMOC)
        ZMConversation.insertNewObject(in: self.uiMOC)
        
        let cookieStorage = MockCookieStorage()
        cookieStorage.shouldReturnCookie = true
        
        self.sut = ZMAccountStatus(managedObjectContext: self.uiMOC, cookieStorage: cookieStorage)
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
        
        // when
        ZMUserSessionAuthenticationNotification.notifyAuthenticationDidFail(Error(domain:"UserSession", code:0, userInfo: nil))
        XCTAssert(waitForAllGroupsToBeEmptyWithTimeout(0.5))
        
        // then
        XCTAssertEqual(self.sut.currentAccountState, AccountState.OldDeviceActiveAccount)
    
    }
    
}

