// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 设备给的是裸 Opus 帧串（每帧固定 160 字节，20 ms，48 kHz 单声道，尾部补 0）。
/// 包成 Ogg Opus 才能被播放器和 ffmpeg 识别。
public enum OggOpus {
    public static let frameSize = 160
    public static let samplesPerFrame: UInt64 = 960

    public static func frames(from raw: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: raw.count, by: frameSize).map { start in
            trimmed(Array(raw[start..<min(start + frameSize, raw.count)]))
        }
    }

    /// 去掉补齐用的 0
    public static func trimmed(_ frame: [UInt8]) -> [UInt8] {
        var f = frame
        while f.count > 1, f.last == 0 { f.removeLast() }
        return f
    }

    public static func mux(frames: [[UInt8]], serial: UInt32 = 0x4433_3230) -> [UInt8] {
        var out: [UInt8] = []
        var seq: UInt32 = 0
        func add(_ packets: [[UInt8]], granule: UInt64, flags: UInt8) {
            out += page(packets: packets, serial: serial, sequence: seq, granule: granule, flags: flags)
            seq += 1
        }
        add([opusHead()], granule: 0, flags: 0x02)
        add([opusTags()], granule: 0, flags: 0)
        var granule: UInt64 = 0
        let perPage = 50
        for start in stride(from: 0, to: frames.count, by: perPage) {
            let batch = Array(frames[start..<min(start + perPage, frames.count)])
            granule += samplesPerFrame * UInt64(batch.count)
            add(batch, granule: granule, flags: start + perPage >= frames.count ? 0x04 : 0)
        }
        return out
    }

    static func opusHead() -> [UInt8] {
        Array("OpusHead".utf8) + [1, 1] + u16le(312) + u32le(48000) + u16le(0) + [0]
    }

    static func opusTags() -> [UInt8] {
        let vendor = Array("d3200-spike".utf8)
        return Array("OpusTags".utf8) + u32le(UInt32(vendor.count)) + vendor + u32le(0)
    }

    static func page(packets: [[UInt8]], serial: UInt32, sequence: UInt32, granule: UInt64, flags: UInt8) -> [UInt8] {
        var lacing: [UInt8] = []
        for p in packets {
            var n = p.count
            while n >= 255 { lacing.append(255); n -= 255 }
            lacing.append(UInt8(n))
        }
        var b = Array("OggS".utf8) + [0, flags]
        b += (0..<8).map { UInt8((granule >> (8 * UInt64($0))) & 0xFF) }
        b += u32le(serial) + u32le(sequence) + [0, 0, 0, 0] + [UInt8(lacing.count)] + lacing
        for p in packets { b += p }
        let crc = crc32(b)
        b.replaceSubrange(22..<26, with: u32le(crc))
        return b
    }

    /// Ogg 用的 CRC-32：多项式 0x04C11DB7，不反射，初值 0。
    static let table: [UInt32] = (0..<256).map { i in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) ^ table[Int((($0 >> 24) ^ UInt32($1)) & 0xFF)] }
    }
}

/// 边写边封装的 Ogg Opus：一次给一帧，攒满一页（50 帧）就写出去，内存里最多一页。
/// 输出和 `OggOpus.mux` 逐字节相同（最后一页带结束标志，所以要等 `finish()` 才写最后一页）。
public final class OggOpusWriter {
    private let write: ([UInt8]) throws -> Void
    private let serial: UInt32
    private var sequence: UInt32 = 0
    private var granule: UInt64 = 0
    private var pending: [[UInt8]] = []
    public private(set) var frames = 0
    static let perPage = 50

    public init(serial: UInt32 = 0x4433_3230, write: @escaping ([UInt8]) throws -> Void) throws {
        self.serial = serial
        self.write = write
        try page([OggOpus.opusHead()], granule: 0, flags: 0x02)
        try page([OggOpus.opusTags()], granule: 0, flags: 0)
    }

    private func page(_ packets: [[UInt8]], granule: UInt64, flags: UInt8) throws {
        try write(OggOpus.page(packets: packets, serial: serial, sequence: sequence, granule: granule, flags: flags))
        sequence += 1
    }

    /// 加一帧（已去掉补齐的 0）。攒到第 51 帧时才把前 50 帧写出去：那时才知道它们不是最后一页
    public func add(_ frame: [UInt8]) throws {
        if pending.count == Self.perPage { try flushPage(last: false) }
        pending.append(frame)
        frames += 1
    }

    private func flushPage(last: Bool) throws {
        guard !pending.isEmpty else { return }
        granule += OggOpus.samplesPerFrame * UInt64(pending.count)
        try page(pending, granule: granule, flags: last ? 0x04 : 0)
        pending.removeAll(keepingCapacity: true)
    }

    public func finish() throws { try flushPage(last: true) }
}

