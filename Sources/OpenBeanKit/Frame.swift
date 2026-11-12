// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 设备回给手机的一帧（`09 FF 00 00 | status | type | id | len u16 LE | payload | checksum`）。
public struct Packet: CustomStringConvertible, Sendable {
    public let raw: [UInt8]
    public var status: UInt8 { raw[4] }
    public var type: UInt8 { raw[5] }
    public var id: UInt8 { raw[6] }
    /// 第 9 字节起到校验字节前。
    public var payload: ArraySlice<UInt8> { raw.count > 10 ? raw[9..<(raw.count - 1)] : [] }
    public var isSuccess: Bool { (status & 0x0F) == 1 }

    public init(raw: [UInt8]) { self.raw = raw }

    public var description: String {
        String(format: "RX %02X/%02X st=%02X len=%d", type, id, status, raw.count)
    }
}

public enum Frame {
    public static let txMagic: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]

    /// 手机发给设备：`08 EE 00 00 00 | type | id | len u16 LE | payload | checksum`，
    /// len 是整帧长度（含校验字节），checksum 是前面所有字节的和取低 8 位。
    public static func encode(type: UInt8, id: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let total = txMagic.count + 2 + 2 + payload.count + 1
        var out = txMagic + [type, id, UInt8(total & 0xFF), UInt8(total >> 8)] + payload
        out.append(checksum(out[...]))
        return out
    }

    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 &+ $1 }
    }
}

/// 把 BLE 通知碎片拼成完整帧。
public struct FrameAssembler {
    private var buf: [UInt8] = []
    public private(set) var badChecksum = 0

    public init() {}

    public mutating func feed(_ data: [UInt8]) -> [Packet] {
        buf += data
        var out: [Packet] = []
        var i = 0
        while buf.count - i >= 10 {
            guard let start = findHeader(from: i) else {
                // 没找到头：只留可能是半个头的尾巴
                i = max(i, buf.count - 3)
                break
            }
            i = start
            let total = Int(buf[i + 7]) | Int(buf[i + 8]) << 8
            if total < 10 { i += 1; continue }
            if i + total > buf.count { break } // 不完整，等下一包
            let frame = Array(buf[i..<(i + total)])
            if Frame.checksum(frame[0..<(total - 1)]) == frame[total - 1] {
                out.append(Packet(raw: frame))
                i += total
            } else {
                badChecksum += 1
                i += 1 // 可能是假头，往后再找
            }
        }
        if i > 0 { buf.removeFirst(min(i, buf.count)) }
        return out
    }

    private func findHeader(from: Int) -> Int? {
        var j = from
        while j + 4 <= buf.count {
            if buf[j] == 0x09, buf[j + 1] == 0xFF, buf[j + 2] == 0, buf[j + 3] == 0 { return j }
            j += 1
        }
        return nil
    }
}

// MARK: - 小工具

public func u16le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
public func u32le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

public func readU16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
public func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

extension Sequence where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
