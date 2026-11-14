// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import XCTest

final class SettingsRouteTests: XCTestCase {
    /// 0.5 以前设置窗口的每个分页名都还能打开（换到新的位置）
    func testOldSettingsTabsStillResolve() {
        XCTAssertEqual(SettingsRoute(link: "heart"), .heart)
        XCTAssertEqual(SettingsRoute(link: "voice"), .voiceTyping(cleanUp: false))
        XCTAssertEqual(SettingsRoute(link: "polish"), .voiceTyping(cleanUp: true))
        XCTAssertEqual(SettingsRoute(link: "library"), .general(.library))
        XCTAssertEqual(SettingsRoute(link: "agent"), .general(.agents))
        XCTAssertEqual(SettingsRoute(link: "about"), .general(.about))
        XCTAssertEqual(SettingsRoute(link: "models"), .general(.about), "0.4 以前的 models 页")
    }

    func testNewNamesAndDefaults() {
        XCTAssertEqual(SettingsRoute(link: ""), .general(.top))
        XCTAssertEqual(SettingsRoute(link: "general"), .general(.top))
        XCTAssertEqual(SettingsRoute(link: "recorder"), .recorder)
        XCTAssertEqual(SettingsRoute(link: "Voice"), .voiceTyping(cleanUp: false))
        XCTAssertNil(SettingsRoute(link: "nonsense"))
    }
}
