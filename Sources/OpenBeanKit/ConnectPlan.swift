// SPDX-License-Identifier: Apache-2.0

import Foundation

/// iOS 版怎么连录音豆（纯值，测试见 ConnectPlanTests）。Mac 版不用这个：照旧 8 秒直连 + 同时扫描，不行再扫 6 秒。
///
/// iOS 上 App 大多时候在后台或被挂起：
/// - 后台扫描必须指定服务 UUID（`withServices: nil` 在后台收不到任何广播）；录音豆广播里带着 `UUIDs.service`（PROTOCOL.md）。
/// - 对认识的设备发一个不超时的 connect：录音豆一进范围、一醒来，系统自己连上（后台也行，App 被挂起也会被叫醒）。
///   超时取消就等于放弃，口袋里的手机不会有人再点「连接」。
/// - 只有在前台、第一次尝试时才给直连限时：系统记住的 identifier 万一失效（设备重置过、换过绑定），
///   限时之后扫一遍（前台扫描不限服务，和 Mac 一样能找到新设备），不至于永远挂着等一个不存在的设备。
public enum ConnectPlan: Equatable, Sendable {
    /// 按系统记住的设备直连。timeout 为 nil：不超时；scanAssist：挂着的同时扫描（只扫录音豆的服务）；
    /// fallbackScan：直连超时后改为扫描
    case direct(timeout: Double?, scanAssist: Bool, fallbackScan: Bool)
    /// 不认识设备：扫描。servicesOnly：只扫录音豆的服务（后台只能这样）
    case scan(seconds: Double, servicesOnly: Bool)

    /// 前台第一次直连等多久
    public static let foregroundDirectTimeout: Double = 15

    public static func iOS(knownDevice: Bool, background: Bool, attempt: Int) -> ConnectPlan {
        if knownDevice {
            if !background && attempt == 0 {
                return .direct(timeout: foregroundDirectTimeout, scanAssist: true, fallbackScan: true)
            }
            return .direct(timeout: nil, scanAssist: true, fallbackScan: false)
        }
        // 第一次配对一般在前台：不限服务扫 6 秒（和 Mac 一样）；后台只能按服务扫，多给点时间
        return background ? .scan(seconds: 30, servicesOnly: true) : .scan(seconds: 6, servicesOnly: false)
    }

    /// CBCentralManager 状态恢复用的标识（iOS）：App 被系统结束后，蓝牙事件来了系统用它把 App 拉起来并交还连接
    public static let restoreIdentifier = "dev.openbean.ios.central"
}
