// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct DeviceInfo: CustomStringConvertible {
    public var micBattery: Int?
    public var micCharging = false
    public var firmware = ""
    public var serial = ""
    public var totalKB: UInt32 = 0
    public var freeKB: UInt32 = 0
    public var caseCharging = false
    public var caseFirmware = ""
    public var caseBattery: Int?
    public var caseMac = ""
    public var recording: Bool?
    public var wifiFirmware = ""

    /// 电量是 0…9 档，显示为 (档+1)×10%；大于 9 当作百分比。
    static func battery(_ raw: UInt8) -> Int? {
        if raw <= 9 { return (Int(raw) + 1) * 10 }
        return raw <= 100 ? Int(raw) : nil
    }

    /// 从整帧解析，字段从第 9 字节开始。
    public init?(frame raw: [UInt8]) {
        guard raw.count >= 20 else { return nil }
        let end = raw.count - 1 // 校验字节不算
        var o = 9
        func u8() -> UInt8? { guard o < end else { return nil }; defer { o += 1 }; return raw[o] }
        func take(_ n: Int) -> [UInt8] { let e = min(o + n, end); defer { o = e }; return Array(raw[o..<e]) }
        func ascii(_ b: [UInt8]) -> String {
            String(decoding: b.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        _ = u8() // connectStatus
        micBattery = u8().flatMap(Self.battery)
        micCharging = u8() == 1
        firmware = ascii(take(5))
        serial = ascii(take(16)).lowercased()
        guard o + 8 <= end else { return }
        totalKB = readU32(raw, o); o += 4
        freeKB = readU32(raw, o); o += 4
        caseCharging = u8() == 1
        caseFirmware = ascii(take(5))
        caseBattery = u8().flatMap(Self.battery)
        let mac = take(6)
        if mac.count == 6, Set(mac).count > 1 { caseMac = mac.map { String(format: "%02X", $0) }.joined(separator: ":") }
        guard o + 6 <= end else { return }
        o += 5 // 颜色、自动关机开关/档位、两个指示灯
        recording = u8() == 1
        if o + 5 <= end { wifiFirmware = ascii(take(5)) }
    }

    public var description: String {
        func pct(_ v: Int?) -> String { v.map { "\($0)%" } ?? "?" }
        let usedMB = Double(Int(totalKB) - Int(freeKB)) / 1024
        return """
        固件      \(firmware)（盒子 \(caseFirmware)，Wi‑Fi \(wifiFirmware)）
        序列号    \(serial)
        电量      录音豆 \(pct(micBattery))\(micCharging ? " 充电中" : "")，盒子 \(pct(caseBattery))\(caseCharging ? " 充电中" : "")
        存储      已用 \(String(format: "%.1f", usedMB)) MB / 共 \(String(format: "%.1f", Double(totalKB) / 1024)) MB
        盒子 MAC  \(caseMac)
        录音中    \(recording.map { $0 ? "是" : "否" } ?? "?")
        """
    }
}

public struct RecordingFile: Sendable {
    public let id: UInt32
    public let endTime: UInt32?
    /// 文件列表里这个字段 PROTOCOL.md 叫 size，实测是**时长毫秒数**：
    /// 1060 的文件拉下来正好 53 帧 × 20 ms；另一条 5920820 与 endTime−fileId=5921 秒吻合。
    public let durationMs: UInt32

    public var durationSeconds: Double { Double(durationMs) / 1000 }
    /// 线上传输字节：每 20 ms 一片 166 字节（seq 4 + flags 1 + 数据 160 + 填充 1）。
    public var wireBytes: Int { Int(durationMs) / 20 * 166 }
    /// 解密后的裸 Opus 字节（64 kbps）。
    public var audioBytes: Int { Int(durationMs) / 20 * 160 }
    /// fileId 看起来像开始时间的 unix 秒。
    public var startDate: Date? { id > 1_500_000_000 ? Date(timeIntervalSince1970: TimeInterval(id)) : nil }
}

public struct FileListPage {
    public let files: [RecordingFile]
    public let declaredCount: Int

    /// 1B/0E：count u16，每条 fileId u32 + endTime u32 + size u32。
    /// 1A/0E：每条 8 字节（没有 endTime）。
    public init(payload p: [UInt8], withEndTime: Bool) {
        guard p.count >= 2 else { files = []; declaredCount = 0; return }
        declaredCount = readU16(p, 0)
        let stride = withEndTime ? 12 : 8
        var o = 2
        var out: [RecordingFile] = []
        for _ in 0..<declaredCount where o + stride <= p.count {
            let id = readU32(p, o)
            if withEndTime {
                out.append(RecordingFile(id: id, endTime: readU32(p, o + 4), durationMs: readU32(p, o + 8)))
            } else {
                out.append(RecordingFile(id: id, endTime: nil, durationMs: readU32(p, o + 4)))
            }
            o += stride
        }
        files = out
    }
}

/// 1A/07 文件头（加密时 ≥ 97 字节整帧）。
public struct FileHead {
    public let fileId: UInt32
    public let size: UInt32
    public let nonce: [UInt8]           // 16
    public let encryptedFileKey: [UInt8] // 46
    public let sessionNonce: [UInt8]    // 16
    public let errorCode: UInt8

    public init?(frame r: [UInt8]) {
        guard r.count >= 97 else { return nil }
        fileId = readU32(r, 9)
        size = readU32(r, 13)
        nonce = Array(r[17..<33])
        encryptedFileKey = Array(r[33..<79])
        sessionNonce = Array(r[79..<95])
        errorCode = r[95]
    }
}

/// 1A/08、1A/12 切片：从第 9 字节起，每单元 `seq u32 | flags u8 | 160 字节数据 | 1 字节填充`。
public struct Slice { public let seq: UInt32; public let data: [UInt8] }

public func parseSlices(frame r: [UInt8]) -> [Slice] {
    var out: [Slice] = []
    var i = 9
    while r.count - i >= 165 {
        let seq = readU32(r, i)
        i += 5
        out.append(Slice(seq: seq, data: Array(r[i..<(i + 160)])))
        i += 160
        if i < r.count { i += 1 }
    }
    return out
}
