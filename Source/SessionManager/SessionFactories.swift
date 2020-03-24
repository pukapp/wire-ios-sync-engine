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


import avs


open class AuthenticatedSessionFactory {

    let appVersion: String
    let mediaManager: MediaManagerType
    let flowManager : FlowManagerType
    var analytics: AnalyticsType?
    let application : ZMApplication
    var environment: BackendEnvironmentProvider
    let reachability: ReachabilityProvider & TearDownCapable

    public init(
        appVersion: String,
        application: ZMApplication,
        mediaManager: MediaManagerType,
        flowManager: FlowManagerType,
        environment: BackendEnvironmentProvider,
        reachability: ReachabilityProvider & TearDownCapable,
        analytics: AnalyticsType? = nil
        ) {
        self.appVersion = appVersion
        self.mediaManager = mediaManager
        self.flowManager = flowManager
        self.analytics = analytics
        self.application = application
        self.environment = environment
        self.reachability = reachability
    }

    func session(for account: Account, storeProvider: LocalStoreProviderProtocol) -> ZMUserSession? {
        let transportSession = ZMTransportSession(
            environment: environment,
            cookieStorage: environment.cookieStorage(for: account),
            reachability: reachability,
            initialAccessToken: nil,
            applicationGroupIdentifier: nil
        )
        /**
         * 新增需求 - 用户访问的ip地址由服务端进行分配，防止域名被封之后，导致所有用户无法使用
         * 登录和每次应用启动时去请求接口，获取对应ip，并保存在本地。
         * 所以在每个transportSession创建的时候判断一次，
         * 当该用户存在分流URL的时候，对baseURL直接重新赋值
         **/
        if let tributaryURL = environment.tributaryURL(for: account) {
            transportSession.baseURL = tributaryURL
            transportSession.websocketURL = tributaryURL
        }
        
        return ZMUserSession(
            mediaManager: mediaManager,
            flowManager:flowManager,
            analytics: analytics,
            transportSession: transportSession,
            application: application,
            appVersion: appVersion,
            storeProvider: storeProvider
        )
    }
    
}


open class UnauthenticatedSessionFactory {

    var environment: BackendEnvironmentProvider
    let reachability: ReachabilityProvider

    init(environment: BackendEnvironmentProvider, reachability: ReachabilityProvider) {
        self.environment = environment
        self.reachability = reachability
    }

    func session(withDelegate delegate: UnauthenticatedSessionDelegate) -> UnauthenticatedSession {
        let transportSession = UnauthenticatedTransportSession(environment: environment, reachability: reachability)
        return UnauthenticatedSession(transportSession: transportSession, reachability: reachability, delegate: delegate)
    }

}
