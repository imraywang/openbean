// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 下载中的录音落盘：每收到一片解密后的帧就追加一条记录（`seq u32 LE | 160 字节`）到临时文件，
/// 内存里只留收到的 seq 区间（`SeqRanges`）和一个 64 KB 的写缓冲。8 小时的录音（约 230 MB）不在内存里攒。
///
/// 下不完时文件留着：下一次打开（`keepExisting: true`）会扫一遍已有的记录接着用，
/// 已经有的 seq 不再写（先到的为准）。下一次从 `received.contiguousCount(from: 0)` 接着要
/// （offset = 片数 × 166，见 `ResumePlan`、`Downloader.runResuming`）。
/// 不加锁：同一时间只给一个下载用（收包在传输队列上写，进度在同一队列的 `sync` 里读，收尾在下载结束之后）。
public final class FrameSpool: @unchecked Sendable {
    public static let recordSize = 4 + OggOpus.frameSize
    public let url: URL
    public private(set) var received = SeqRanges()
    /// 记录在文件里是不是按 seq 连续递增（是的话收尾时顺序读就行，不用排序）
    public private(set) var inOrder = true
    public private(set) var writeError: Error?
    private var lastSeq: UInt32?
    private var handle: FileHandle?
    private var buffer: [UInt8] = []
    private var tocCounts = [Int](repeating: 0, count: 256)
    private static let flushAt = 64 * 1024

    /// `keepExisting` 为 false 时清空重来
    public init(url: URL, keepExisting: Bool) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if keepExisting, fm.fileExists(atPath: url.path) {
            try scanExisting()
        } else {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        buffer.reserveCapacity(Self.flushAt + Self.recordSize)
    }

    deinit { try? handle?.close() }

    /// 读一遍已有的记录；末尾不完整的一条（写到一半崩了）截掉
    private func scanExisting() throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let size = Int(try h.seekToEnd())
        let whole = size / Self.recordSize * Self.recordSize
        if whole != size { try h.truncate(atOffset: UInt64(whole)) }
        try h.seek(toOffset: 0)
        var offset = 0
        while offset < whole {
            let n = min(whole - offset, Self.recordSize * 4096)
            let d: Data? = try autoreleasepool { try h.read(upToCount: n) }
            guard let d, d.count == n else { break }
            d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                var i = 0
                while i < n {
                    let seq = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
                    noteRecord(seq: seq, toc: b[i + 4])
                    i += Self.recordSize
                }
            }
            offset += n
        }
    }

    private func noteRecord(seq: UInt32, toc: UInt8) {
        if let l = lastSeq, seq != l &+ 1 { inOrder = false }
        lastSeq = seq
        received.insert(seq)
        tocCounts[Int(toc)] += 1
    }

    /// 一共收到了多少片（包括之前几次留下的）
    public var count: Int { received.count }

    /// 存一片（160 字节，已解密）。已经有这个 seq 或写盘出过错时返回 false
    @discardableResult
    public func put(seq: UInt32, frame: [UInt8]) -> Bool {
        guard writeError == nil, frame.count == OggOpus.frameSize, !received.contains(seq) else { return false }
        noteRecord(seq: seq, toc: frame[0])
        buffer += u32le(seq)
        buffer += frame
        if buffer.count >= Self.flushAt { flush() }
        return writeError == nil
    }

    public func flush() {
        guard !buffer.isEmpty, let h = handle, writeError == nil else { return }
        do { try h.write(contentsOf: buffer) } catch { writeError = error }
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() {
        flush()
        try? handle?.close()
        handle = nil
    }

    /// 出现最多的 TOC 字节（Opus 帧首字节）。解密正确时几乎全一样
    public var dominantTOC: UInt8? {
        guard let m = tocCounts.max(), m > 0 else { return nil }
        return UInt8(tocCounts.firstIndex(of: m)!)
    }

    public var tocConsistency: Double {
        let total = tocCounts.reduce(0, +)
        return total > 0 ? Double(tocCounts.max()!) / Double(total) : 0
    }

    /// 写成 Ogg Opus：输出 `first…first+count−1`（和实际收到的范围取并集），缺的片用只有 TOC 字节的空包补上
    /// （解码器按丢包处理、补一段 20 ms 的静音），时间轴不错位。先写到旁边的临时文件，再原子替换 `dest`。
    /// 返回写了多少帧、其中补了多少。
    @discardableResult
    public func writeOgg(to dest: URL, first: UInt32, count: Int) throws -> (frames: Int, filled: Int) {
        flush()
        if let writeError { throw writeError }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        var outBuf: [UInt8] = []
        func emit(_ b: [UInt8]) throws {
            outBuf += b
            if outBuf.count >= 256 * 1024 { try out.write(contentsOf: outBuf); outBuf.removeAll(keepingCapacity: true) }
        }
        do {
            let writer = try OggOpusWriter(write: emit)
            let filler = [dominantTOC ?? 0x78]
            var filled = 0
            let lo = min(first, received.first ?? first)
            var next = UInt64(lo)
            func fill(upTo seq: UInt64) throws {
                while next < seq { try writer.add(filler); filled += 1; next += 1 }
            }
            try forEachRecordSorted { seq, frame in
                try fill(upTo: UInt64(seq))
                try writer.add(OggOpus.trimmed(frame))
                next = UInt64(seq) + 1
            }
            if count > 0 { try fill(upTo: UInt64(first) + UInt64(count)) } // 末尾缺的也补上
            try writer.finish()
            if !outBuf.isEmpty { try out.write(contentsOf: outBuf) }
            try out.close()
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
            return (writer.frames, filled)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// 按 seq 从小到大读出每条记录。顺序写的直接顺序读；乱序的先排一个下标（每片 8 字节）再按下标读
    private func forEachRecordSorted(_ body: (UInt32, [UInt8]) throws -> Void) throws {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let chunk = Self.recordSize * 4096
        func readAll(_ each: (Int, UInt32, [UInt8]) throws -> Void) throws {
            var index = 0
            try h.seek(toOffset: 0)
            while true {
                // FileHandle.read 返回的 Data 是自动释放的：不包一层，整个文件会在内存里攒到循环结束
                let b: [UInt8] = try autoreleasepool { try h.read(upToCount: chunk).map { [UInt8]($0) } ?? [] }
                if b.isEmpty { break }
                var i = 0
                while i + Self.recordSize <= b.count {
                    try each(index, readU32(b, i), Array(b[(i + 4)..<(i + Self.recordSize)]))
                    i += Self.recordSize
                    index += 1
                }
            }
        }
        if inOrder {
            try readAll { _, seq, frame in try body(seq, frame) }
            return
        }
        var order: [UInt64] = []
        order.reserveCapacity(count)
        try readAll { idx, seq, _ in order.append(UInt64(seq) << 32 | UInt64(idx)) }
        order.sort()
        for key in order {
            let idx = Int(key & 0xFFFF_FFFF)
            try h.seek(toOffset: UInt64(idx * Self.recordSize + 4))
            let d: [UInt8] = try autoreleasepool { try h.read(upToCount: OggOpus.frameSize).map { [UInt8]($0) } ?? [] }
            guard d.count == OggOpus.frameSize else { continue }
            try body(UInt32(key >> 32), d)
        }
    }

    /// 删掉临时文件（成功收尾之后）
    public func remove() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}
