// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 本小样用到的命令。绑定/解绑、恢复出厂、删文件、OTA 故意不放进来。
public enum Cmd {
    public static func getDeviceInfo() -> [UInt8] { Frame.encode(type: 0x01, id: 0x01) }

    public static func syncTime(_ date: Date = Date(), tz: TimeZone = .current) -> [UInt8] {
        let hours = tz.secondsFromGMT(for: date) / 3600
        return Frame.encode(type: 0x01, id: 0xA6,
                            payload: u32le(UInt32(date.timeIntervalSince1970)) + [UInt8(bitPattern: Int8(hours))])
    }

    public static func startRecord() -> [UInt8] { Frame.encode(type: 0x18, id: 0x82, payload: [0x01]) }
    public static func pauseRecord() -> [UInt8] { Frame.encode(type: 0x18, id: 0x82, payload: [0x02]) }

    /// 带结束时间的文件列表（1B/0E），每页最多 10 条。
    public static func listFiles(page: Int) -> [UInt8] { Frame.encode(type: 0x1B, id: 0x0E, payload: u16le(page)) }

    /// 请求传文件：已传字节数 + fileId + 是否实时。
    public static func transferFile(id: UInt32, offset: UInt32 = 0, realtime: Bool) -> [UInt8] {
        Frame.encode(type: 0x1A, id: 0x07, payload: u32le(offset) + u32le(id) + [realtime ? 1 : 0])
    }

    /// 让设备用这组 SSID/密码开热点：`[ssid_len][ssid][pwd_len][pwd]`。
    public static func openSoftAP(ssid: String, password: String) -> [UInt8] {
        let s = Array(ssid.utf8), p = Array(password.utf8)
        return Frame.encode(type: 0x1A, id: 0x05, payload: [UInt8(s.count)] + s + [UInt8(p.count)] + p)
    }

    public static func closeSoftAP() -> [UInt8] { Frame.encode(type: 0x1A, id: 0x02) }

    /// Wi‑Fi 通道里的文件请求：18 字节、没有校验字节、最后一字节固定 0x1B，以小写 hex 文本发出。
    public static func wifiFileRequestHex(id: UInt32, offset: UInt32 = 0) -> String {
        let b: [UInt8] = [0x08, 0xEE, 0, 0, 0, 0x1A, 0x07, 0x12, 0x00] + u32le(offset) + u32le(id) + [0x1B]
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// Wi‑Fi 通道里的「传输完成」：标准帧（带校验），hex 文本。
    public static func wifiTransferCompleteHex() -> String {
        Frame.encode(type: 0x1A, id: 0x0A, payload: [0x01]).map { String(format: "%02x", $0) }.joined()
    }

    /// ECDH：发 65 字节未压缩 P-256 公钥。
    public static func encryptHandshake(publicKey: [UInt8]) -> [UInt8] {
        Frame.encode(type: 0x2E, id: 0x01, payload: publicKey)
    }
}

public enum Rx {
    public static let deviceInfo: (UInt8, UInt8) = (0x01, 0x01)
    public static let battery: (UInt8, UInt8) = (0x01, 0x03)
    public static let charging: (UInt8, UInt8) = (0x01, 0x04)
    public static let syncTime: (UInt8, UInt8) = (0x01, 0xA6)
    public static let record: (UInt8, UInt8) = (0x18, 0x82)
    public static let encrypt: (UInt8, UInt8) = (0x2E, 0x01)
    // 0x1A / 0x1B 传输类
    public static let recordStatus: UInt8 = 0x06 // 录音中新文件 id
    public static let fileHead: UInt8 = 0x07
    public static let fileSlice: UInt8 = 0x08
    public static let fileDone: UInt8 = 0x0A
    public static let fileList: UInt8 = 0x0E
    public static let fileSliceMark: UInt8 = 0x12

    public static func isTransport(_ p: Packet) -> Bool { p.type == 0x1A || p.type == 0x1B }
}
