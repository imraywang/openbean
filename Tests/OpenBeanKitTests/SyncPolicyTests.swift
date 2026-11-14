// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

final class SyncPolicyTests: XCTestCase {
    // MARK: SeqRanges

    func testSeqRangesAppendMergeAndMissing() {
        var r = SeqRanges()
        for q in UInt32(0)...99 { XCTAssertTrue(r.insert(q)) }
        XCTAssertFalse(r.insert(50))
        XCTAssertEqual(r.ranges, [0...99])
        r.insert(200)
        r.insert(150)
        r.insert(range: 101...149)
        XCTAssertEqual(r.ranges, [0...99, 101...150, 200...200])
        r.insert(100)
        XCTAssertEqual(r.ranges, [0...150, 200...200])
        XCTAssertEqual(r.count, 152)
        XCTAssertTrue(r.contains(200))
        XCTAssertFalse(r.contains(151))
        XCTAssertEqual(r.contiguousCount(from: 0), 151)
        XCTAssertEqual(r.contiguousCount(from: 160), 0)
        XCTAssertEqual(r.missing(from: 0, count: 205), [151...199, 201...204])
        XCTAssertEqual(SeqRanges([5...9, 0...3]).ranges, [0...3, 5...9])
        XCTAssertEqual(SeqRanges([5...9, 0...4]).ranges, [0...9])
    }

    // MARK: Ogg 流式写

    func testOggWriterMatchesMux() throws {
        for n in [0, 1, 49, 50, 51, 100, 137] {
            let frames = (0..<n).map { i in [UInt8(0x78)] + [UInt8](repeating: UInt8(i & 0xFF), count: i % 7) }
            var out: [UInt8] = []
            let w = try OggOpusWriter { out += $0 }
            for f in frames { try w.add(f) }
            try w.finish()
            XCTAssertEqual(out, OggOpus.mux(frames: frames), "n=\(n)")
        }
    }

    // MARK: 完整性

    private func head(id: UInt32 = 9, frames: Int, err: UInt8 = 0) -> FileHead {
        FileHead(frame: FakeDevice.frame(id: 0x07, payload: u32le(id) + u32le(UInt32(frames * 166)) + [UInt8](repeating: 0, count: 78) + [err, 0]).raw)!
    }

    private func check(_ r: SeqRanges, frames: Int = 1000, list: Int = 1000, done: Bool = true, head h: FileHead? = nil,
                       toc: Double = 1) -> DownloadCheck.Result {
        DownloadCheck.evaluate(requestedId: 9, head: h ?? head(frames: frames), decrypted: true, received: r,
                               gotDone: done, listFrames: list, tocConsistency: toc)
    }

    func testCheckVerdicts() {
        XCTAssertEqual(check(SeqRanges([0...999])).verdict, .complete)
        // 没结束包，但收够了
        XCTAssertEqual(check(SeqRanges([0...999]), done: false).verdict, .complete)
        // 中间缺 3 片，有结束包：能用，缺的补静音
        XCTAssertEqual(check(SeqRanges([0...499, 503...999])).verdict, .completeWithGaps(missing: 3))
        // 中间缺 3 片，没结束包：不完整
        guard case .incomplete = check(SeqRanges([0...499, 503...999]), done: false).verdict else { return XCTFail() }
        // 末尾少了一半：不完整
        let half = check(SeqRanges([0...499]))
        guard case .incomplete = half.verdict else { return XCTFail() }
        XCTAssertEqual(half.missing, 500)
        // 文件头和列表口径不一致时，取和收到的最接近的（任一口径对上就行）
        XCTAssertEqual(check(SeqRanges([0...999]), frames: 1003, list: 1000).verdict, .complete)
        XCTAssertEqual(check(SeqRanges([0...999]), frames: 1000, list: 990).verdict, .complete)
        // 别的文件的头、设备报错、解出来不像 Opus
        guard case .rejected = check(SeqRanges([0...999]), head: head(id: 8, frames: 1000)).verdict,
              case .rejected = check(SeqRanges([0...999]), head: head(frames: 1000, err: 1)).verdict,
              case .rejected = check(SeqRanges([0...999]), toc: 0.3).verdict else { return XCTFail() }
        // 没收到东西
        guard case .incomplete = check(SeqRanges()).verdict else { return XCTFail() }
        // 容差：8 小时 144 万片，0.1% = 1440 片
        XCTAssertEqual(DownloadCheck.tolerance(expected: 1_440_000), 1440)
        XCTAssertEqual(DownloadCheck.tolerance(expected: 3000), 50)
    }

    // MARK: 语音输入 vs 同步

    func testDictationDecision() {
        XCTAssertEqual(SyncPolicy.dictation(remaining: nil, resumable: false), .yield)
        XCTAssertEqual(SyncPolicy.dictation(remaining: 120, resumable: false), .yield)
        XCTAssertEqual(SyncPolicy.dictation(remaining: 600, resumable: false), .yield)
        XCTAssertEqual(SyncPolicy.dictation(remaining: 601, resumable: false), .keepSyncing(secondsLeft: 601))
        // 有了续传：一律让，之后接着下
        XCTAssertEqual(SyncPolicy.dictation(remaining: 5000, resumable: true), .yield)
    }

    func testRetryDelay() {
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 0, kind: .failed, longFile: true), 0)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 1, kind: .interrupted, longFile: true), 0)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 2, kind: .interrupted, longFile: true), 60)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 4, kind: .interrupted, longFile: true), 240)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 1, kind: .failed, longFile: false), 60)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 3, kind: .failed, longFile: false), 240)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 1, kind: .failed, longFile: true), 300)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 2, kind: .failed, longFile: true), 600)
        XCTAssertEqual(SyncPolicy.retryDelay(failures: 9, kind: .failed, longFile: true), 1800)
    }

    func testWifiSuggestion() {
        XCTAssertFalse(SyncPolicy.suggestWifi(bluetoothSeconds: nil))
        XCTAssertFalse(SyncPolicy.suggestWifi(bluetoothSeconds: 19 * 60))
        XCTAssertTrue(SyncPolicy.suggestWifi(bluetoothSeconds: 95 * 60))
        // 8 小时 230 MB：Wi‑Fi 约 4 分钟
        XCTAssertEqual(SyncPolicy.wifiSeconds(bytes: 230_400_000), 90 + 153.6, accuracy: 0.01)
    }

    // MARK: 速度记忆

    func testLearnOnlyFromLargeDownloads() {
        XCTAssertFalse(SyncEstimate.shouldLearn(bytes: 50_000, seconds: 4))
        XCTAssertFalse(SyncEstimate.shouldLearn(bytes: 2_000_000, seconds: 10))
        XCTAssertTrue(SyncEstimate.shouldLearn(bytes: 46_256_000, seconds: 1140))
        // 短文件以开销为主：40 KB 在 40 KB/s 下 1 秒 + 2 秒开销
        XCTAssertEqual(SyncEstimate.fileSeconds(bytes: 40_000, bytesPerSecond: 40_000), 3)
        XCTAssertEqual(SyncEstimate.fileSeconds(bytes: 0, bytesPerSecond: 40_000), 0)
    }

    // MARK: 续传

    func testResumePlan() {
        let r = SeqRanges([0...4999, 6000...6100])
        let off = ResumeSupport(unit: nil, headResent: true)
        // 不支持时：从 0
        XCTAssertEqual(ResumePlan.next(received: r, support: off).offset, 0)
        XCTAssertEqual(ResumePlan.next(received: r, support: off).fromSeq, 0)
        // 现在的默认就是实测的线上字节；中间有洞从洞的位置续
        XCTAssertEqual(ResumeSupport.current.unit, .wireBytes)
        XCTAssertEqual(ResumePlan.next(received: r).offset, 5000 * 166)
        XCTAssertEqual(ResumePlan.next(received: r).fromSeq, 5000)
        XCTAssertEqual(ResumePlan.next(received: r, support: ResumeSupport(unit: .milliseconds, headResent: true)).offset, 100_000)
        XCTAssertEqual(ResumePlan.next(received: r, support: ResumeSupport(unit: .seq, headResent: true)).offset, 5000)
        // 不重发文件头：先不续
        XCTAssertEqual(ResumePlan.next(received: r, support: ResumeSupport(unit: .wireBytes, headResent: false)).offset, 0)
        // 一片都没有：从 0
        XCTAssertEqual(ResumePlan.next(received: SeqRanges()).offset, 0)
        XCTAssertEqual(ResumePlan.next(received: SeqRanges()).fromSeq, 0)
        // 第 0 片就缺（前缀为 0）：从头
        XCTAssertEqual(ResumePlan.next(received: SeqRanges([1...900])).fromSeq, 0)
        // 洞在开头附近
        XCTAssertEqual(ResumePlan.next(received: SeqRanges([0...0, 2...900])).offset, 166)
        // 已经全部收完（只差结束包）：从最后一片再要一次
        let all = ResumePlan.next(received: SeqRanges([0...14026]), total: 14027)
        XCTAssertEqual(all.fromSeq, 14026)
        XCTAssertEqual(all.offset, 14026 * 166)
        // 不知道总片数时按前缀
        XCTAssertEqual(ResumePlan.next(received: SeqRanges([0...14026])).fromSeq, 14027)
        XCTAssertEqual(ResumePlan.label(fromSeq: 840), "续传，从第 840 片")
        XCTAssertEqual(ResumePlan.label(fromSeq: 0), "从头")
    }
}
