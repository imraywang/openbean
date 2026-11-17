// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

/// 认佩戴者的规则：全用合成的向量（不是真人声音）。提取声纹的那一个测试要本机模型和系统中文语音，缺了就跳过
final class SpeakerIDTests: XCTestCase {
    /// 固定种子的随机数：每次跑结果一样
    struct LCG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return s
        }
    }

    static let dim = 16

    func unit(_ g: inout LCG) -> [Float] {
        SpeakerMath.normalized((0..<Self.dim).map { _ in Float.random(in: -1...1, using: &g) })
    }

    /// 在 centre 附近：centre + noise 倍的随机方向
    func near(_ centre: [Float], _ noise: Float, _ g: inout LCG) -> [Float] {
        let r = unit(&g)
        return SpeakerMath.normalized(zip(centre, r).map { $0 + noise * $1 })
    }

    /// 两个互相正交的「声音」
    func twoVoices() -> ([Float], [Float]) {
        var a = [Float](repeating: 0, count: Self.dim), b = a
        a[0] = 1; b[1] = 1
        return (a, b)
    }

    // MARK: 窗口

    func testWindows() {
        XCTAssertEqual(SpeakerID.windows(duration: 0).count, 0)
        let short = SpeakerID.windows(duration: 1.0)
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short[0].end, 1.0)
        let exact = SpeakerID.windows(duration: 3.0)
        XCTAssertEqual(exact.map(\.start), [0, 0.75, 1.5])
        // 2 秒：0–1.5 之后差 0.5 秒 > 0.25，补一个贴着句尾的
        let two = SpeakerID.windows(duration: 2.0)
        XCTAssertEqual(two.map(\.start), [0, 0.5])
        // 1.6 秒：差 0.1 秒，不补
        XCTAssertEqual(SpeakerID.windows(duration: 1.6).count, 1)
    }

    // MARK: 聚类和候选

    func testAverageLinkageFindsGroups() {
        var g = LCG(s: 1)
        let centres = (0..<3).map { _ in unit(&g) }
        var flat: [Float] = [], truth: [Int] = []
        for i in 0..<90 {
            flat += near(centres[i % 3], 0.15, &g)
            truth.append(i % 3)
        }
        let labels = SpeakerID.averageLinkage(flat, dim: Self.dim, count: 90, maxDistance: 0.6)
        XCTAssertEqual(Set(labels).count, 3)
        // 同一组的点在同一个簇
        for c in 0..<3 {
            XCTAssertEqual(Set(truth.indices.filter { truth[$0] == c }.map { labels[$0] }).count, 1)
        }
    }

    func testAverageLinkageCutsAtThreshold() {
        let (a, b) = twoVoices()  // 余弦 0，距离 1
        let labels = SpeakerID.averageLinkage(a + b + a, dim: Self.dim, count: 3, maxDistance: 0.6)
        XCTAssertEqual(labels[0], labels[2])
        XCTAssertNotEqual(labels[0], labels[1])
        XCTAssertEqual(SpeakerID.averageLinkage(a + b, dim: Self.dim, count: 2, maxDistance: 1.5), [0, 0])
    }

    /// 响的窗口大多是 A（佩戴者），B 轻：候选是 A
    func testLoudCandidateIsLoudestVoice() throws {
        var g = LCG(s: 2)
        let (a, b) = twoVoices()
        var w = SpeakerWindows(dim: Self.dim)
        for i in 0..<400 {
            let wearer = i % 4 == 0
            w.append(sentence: i / 5, rmsDb: wearer ? -18 + Float(i % 3) : -30 - Float(i % 5),
                     vector: near(wearer ? a : b, 0.2, &g))
        }
        let c = try XCTUnwrap(SpeakerID.loudCandidate(w))
        XCTAssertGreaterThan(SpeakerMath.dot(c.vector, a), 0.95)
        XCTAssertEqual(c.windows, 100)   // 响度并列的都算进最响的 20%
        XCTAssertEqual(c.share, 1, accuracy: 0.01)
    }

    func testNoCandidateWithoutDominantVoice() {
        var g = LCG(s: 3)
        // 窗口太少
        var few = SpeakerWindows(dim: Self.dim)
        for i in 0..<20 { few.append(sentence: i, rmsDb: -20, vector: unit(&g)) }
        XCTAssertNil(SpeakerID.loudCandidate(few))
        // 响的窗口各说各的（全是随机方向）：没有一个簇够大
        var scattered = SpeakerWindows(dim: Self.dim)
        for i in 0..<1000 { scattered.append(sentence: i, rmsDb: -20, vector: unit(&g)) }
        XCTAssertNil(SpeakerID.loudCandidate(scattered))
    }

    // MARK: 每句的判定

    func testSentenceScores() throws {
        let (a, b) = twoVoices()
        var w = SpeakerWindows(dim: Self.dim)
        // 句 0：3 个窗口都是 A；句 1：1 个 A、3 个 B；句 2 没有窗口
        for _ in 0..<3 { w.append(sentence: 0, rmsDb: -20, vector: a) }
        w.append(sentence: 1, rmsDb: -20, vector: a)
        for _ in 0..<3 { w.append(sentence: 1, rmsDb: -20, vector: b) }
        let s = SpeakerID.sentenceScores(w, voiceprint: a, sentences: 3)
        XCTAssertEqual(try XCTUnwrap(s[0]).share, 1)
        XCTAssertEqual(try XCTUnwrap(s[0]).median, 1)
        XCTAssertEqual(try XCTUnwrap(s[1]).share, 0.25)
        XCTAssertEqual(try XCTUnwrap(s[1]).windows, 4)
        XCTAssertNil(s[2])
    }

    func score(_ share: Double) -> SpeakerID.SentenceScore { .init(share: share, median: share, windows: 2) }

    func testLabelsThresholdAndShortSentences() {
        let times: [(start: Double, end: Double)] = [(0, 3), (3.5, 4.0), (4.5, 8), (9, 9.5), (10, 14), (30, 30.6), (31, 33)]
        let scores: [SpeakerID.SentenceScore?] = [score(0.8), score(0.0), score(0.5), score(1), score(0.2), score(1), score(0.9)]
        let l = SpeakerID.labels(times: times, scores: scores, worn: .worn)
        XCTAssertEqual(l[0], true)
        XCTAssertEqual(l[1], true)    // 0.5 秒：前后都是佩戴者 → 跟着，不管自己的得分
        XCTAssertEqual(l[2], true)    // 占比正好 0.5 算佩戴者
        XCTAssertNil(l[3])            // 0.5 秒：前后不一致 → 未知，不默认成别人
        XCTAssertEqual(l[4], false)
        XCTAssertNil(l[5])            // 前一句隔了 16 秒，太远
        XCTAssertEqual(l[6], true)
    }

    func testHalfSplitDecidedByMedian() {
        XCTAssertTrue(SpeakerID.isWearer(.init(share: 0.5, median: 0.55, windows: 4)))
        XCTAssertFalse(SpeakerID.isWearer(.init(share: 0.5, median: 0.47, windows: 4)))
        XCTAssertTrue(SpeakerID.isWearer(.init(share: 0.6, median: 0.3, windows: 5)))
        XCTAssertFalse(SpeakerID.isWearer(.init(share: 0.4, median: 0.6, windows: 5)))
    }

    func testShortSentenceAtEdgesIsUnknown() {
        let l = SpeakerID.labels(times: [(0, 0.5), (1, 3)], scores: [score(1), score(1)], worn: .unknown)
        XCTAssertNil(l[0])
        XCTAssertEqual(l[1], true)
    }

    func testNotWornLabelsNothing() {
        let l = SpeakerID.labels(times: [(0, 3), (4, 8)], scores: [score(1), score(0)], worn: .notWorn)
        XCTAssertEqual(l, [nil, nil])
    }

    func testWorn() {
        let (a, b) = twoVoices()
        XCTAssertEqual(SpeakerID.worn(candidate: nil, voiceprint: a), .unknown)
        XCTAssertEqual(SpeakerID.worn(candidate: .init(vector: a, windows: 100, share: 0.8), voiceprint: a), .worn)
        XCTAssertEqual(SpeakerID.worn(candidate: .init(vector: b, windows: 100, share: 0.8), voiceprint: a), .notWorn)
    }

    // MARK: 登记

    let day1 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var day2: Date { day1.addingTimeInterval(86_400) }

    func testEnrolNeedsTwoDays() {
        var g = LCG(s: 4)
        let (a, _) = twoVoices()
        var v = Voiceprint(dim: Self.dim)
        XCTAssertEqual(v.offer(.init(vector: near(a, 0.1, &g), windows: 100, share: 0.8), recording: 1, day: day1), .stored)
        // 同一天的另一段：还不算
        XCTAssertEqual(v.offer(.init(vector: near(a, 0.1, &g), windows: 100, share: 0.8), recording: 2, day: day1), .stored)
        XCTAssertFalse(v.isReady)
        XCTAssertEqual(v.offer(.init(vector: near(a, 0.1, &g), windows: 200, share: 0.7), recording: 3, day: day2), .confirmed)
        XCTAssertTrue(v.isReady)
        XCTAssertGreaterThan(SpeakerMath.dot(v.vector!, a), 0.97)
        XCTAssertEqual(v.recordings, 3)
        XCTAssertEqual(v.sampleCount, 400)
        XCTAssertTrue(v.pending.isEmpty, "确认后候选清掉")
        XCTAssertNotNil(v.confirmedAt)
    }

    func testEnrolRejectsDifferentVoices() {
        let (a, b) = twoVoices()
        var v = Voiceprint(dim: Self.dim)
        _ = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 1, day: day1)
        XCTAssertEqual(v.offer(.init(vector: b, windows: 100, share: 0.8), recording: 2, day: day2), .stored)
        XCTAssertFalse(v.isReady)
        // 同一段录音再交一次替换掉旧的，不会自己和自己配对
        _ = v.offer(.init(vector: b, windows: 100, share: 0.8), recording: 2, day: day2)
        XCTAssertEqual(v.pending.count, 2)
    }

    func testPendingIsCapped() {
        var g = LCG(s: 5)
        var v = Voiceprint(dim: Self.dim)
        for i in 0..<20 {
            _ = v.offer(.init(vector: unit(&g), windows: 100, share: 0.5), recording: UInt32(i), day: day1)
        }
        XCTAssertEqual(v.pending.count, SpeakerID.maxCandidates)
        XCTAssertEqual(v.pending.last?.recording, 19)
    }

    func testAfterConfirmAgreesOrDiffers() {
        let (a, b) = twoVoices()
        var v = Voiceprint(dim: Self.dim)
        _ = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 1, day: day1)
        _ = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 2, day: day2)
        let before = v
        if case .differs = v.offer(.init(vector: b, windows: 100, share: 0.8), recording: 3, day: day2) {} else { XCTFail() }
        if case .agrees = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 4, day: day2) {} else { XCTFail() }
        XCTAssertEqual(v, before, "已有声纹时交候选不改声纹（更新走 refine）")
    }

    func testRefineIsSlow() {
        let (a, b) = twoVoices()
        var v = Voiceprint(dim: Self.dim)
        _ = v.offer(.init(vector: a, windows: 10, share: 0.8), recording: 1, day: day1)
        _ = v.offer(.init(vector: a, windows: 10, share: 0.8), recording: 2, day: day2)
        // 新窗口很多，也最多挪 5%
        v.refine(with: b, count: 10_000)
        XCTAssertGreaterThan(SpeakerMath.dot(v.vector!, a), 0.99)
        XCTAssertEqual(v.sampleCount, 10_020)
        XCTAssertEqual(v.recordings, 3)
    }

    func testVoiceprintFileRoundTrip() throws {
        var v = Voiceprint(dim: Self.dim)
        _ = v.offer(.init(vector: twoVoices().0, windows: 100, share: 0.8), recording: 1, day: day1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try v.write(url)
        XCTAssertEqual(Voiceprint.read(url), v)
    }

    // MARK: 要不要扫

    func testNeedsScan() {
        var learning = Voiceprint(dim: Self.dim)
        XCTAssertTrue(SpeakerScan.needsScan(nil, current: learning))
        XCTAssertTrue(SpeakerScan.needsScan(nil, current: nil))
        XCTAssertFalse(SpeakerScan.needsScan(SpeakerScan(outcome: .learning), current: learning))
        _ = learning.offer(.init(vector: twoVoices().0, windows: 100, share: 0.8), recording: 1, day: day1)
        _ = learning.offer(.init(vector: twoVoices().0, windows: 100, share: 0.8), recording: 2, day: day2)
        let ready = learning
        // 学习时扫过的，有了声纹要重扫；按这份声纹判过的不用；没音频的算了
        XCTAssertTrue(SpeakerScan.needsScan(SpeakerScan(outcome: .learning), current: ready))
        XCTAssertFalse(SpeakerScan.needsScan(SpeakerScan(outcome: .labelled, voiceprint: ready.id), current: ready))
        XCTAssertFalse(SpeakerScan.needsScan(SpeakerScan(outcome: .notWorn, voiceprint: ready.id), current: ready))
        XCTAssertTrue(SpeakerScan.needsScan(SpeakerScan(outcome: .labelled, voiceprint: "old"), current: ready))
        XCTAssertFalse(SpeakerScan.needsScan(SpeakerScan(outcome: .noAudio), current: ready))
    }

    // MARK: 一整段

    /// 一段长的心力模式录音：A 响、B 轻；前两段（两天）登记，第三段判定并慢更新
    func testPassEnrolsThenLabels() throws {
        var g = LCG(s: 6)
        let (a, b) = twoVoices()
        func recording() -> (SpeakerWindows, [TranscriptSegment]) {
            var w = SpeakerWindows(dim: Self.dim)
            var segs: [TranscriptSegment] = []
            for i in 0..<200 {
                let wearer = i % 3 == 0
                let t = Double(i) * 5
                segs.append(TranscriptSegment(start: t, end: t + 3, text: "x"))
                for _ in 0..<3 { w.append(sentence: i, rmsDb: wearer ? -18 : -30, vector: near(wearer ? a : b, 0.2, &g)) }
            }
            return (w, segs)
        }
        var v = Voiceprint(dim: Self.dim)
        for (k, day) in [day1, day2].enumerated() {
            let rec = recording()
            let w = rec.0
            var segs = rec.1
            let r = SpeakerPass.run(windows: w, candidate: SpeakerID.loudCandidate(w),
                                    recording: .init(id: UInt32(k), day: day, enrols: true), voiceprint: &v, segments: &segs)
            XCTAssertTrue(r.voiceprintChanged)
            if k == 0 {
                XCTAssertEqual(r.scan.outcome, .learning)
                XCTAssertTrue(segs.allSatisfy { $0.isWearer == nil && $0.wearerShare == nil })
            } else {
                XCTAssertEqual(r.event, .confirmed)
                XCTAssertEqual(r.scan.outcome, .labelled)
            }
        }
        let rec = recording()
        let w = rec.0
        var segs = rec.1
        let before = v.sampleCount
        let r = SpeakerPass.run(windows: w, candidate: SpeakerID.loudCandidate(w),
                                recording: .init(id: 9, day: day2, enrols: true), voiceprint: &v, segments: &segs)
        XCTAssertEqual(r.scan.outcome, .labelled)
        XCTAssertEqual(r.scan.voiceprint, v.id)
        XCTAssertEqual(r.scan.wearerLines, 67)
        XCTAssertEqual(segs[0].isWearer, true)
        XCTAssertEqual(segs[1].isWearer, false)
        XCTAssertEqual(segs[0].wearerShare, 1)
        XCTAssertGreaterThan(v.sampleCount, before, "对上了：慢更新")
    }

    /// 最响的是别人：不标、不更新声纹
    func testPassNotWorn() {
        var g = LCG(s: 7)
        let (a, b) = twoVoices()
        var v = Voiceprint(dim: Self.dim)
        _ = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 1, day: day1)
        _ = v.offer(.init(vector: a, windows: 100, share: 0.8), recording: 2, day: day2)
        let before = v
        var w = SpeakerWindows(dim: Self.dim)
        var segs: [TranscriptSegment] = []
        for i in 0..<200 {
            let loudB = i % 2 == 0
            segs.append(TranscriptSegment(start: Double(i) * 5, end: Double(i) * 5 + 3, text: "x", isWearer: true))
            for _ in 0..<3 { w.append(sentence: i, rmsDb: loudB ? -18 : -30, vector: near(loudB ? b : a, 0.2, &g)) }
        }
        let r = SpeakerPass.run(windows: w, candidate: SpeakerID.loudCandidate(w),
                                recording: .init(id: 3, day: day2, enrols: true), voiceprint: &v, segments: &segs)
        XCTAssertEqual(r.scan.outcome, .notWorn)
        XCTAssertEqual(r.worn, .notWorn)
        XCTAssertTrue(segs.allSatisfy { $0.isWearer == nil }, "旧标签也清掉")
        XCTAssertEqual(v, before)
    }

    // MARK: 转写文件

    func testTranscriptCompat() throws {
        let old = #"[{"start":0,"end":1.5,"text":"你好"}]"#
        let segs = try JSONDecoder().decode([TranscriptSegment].self, from: Data(old.utf8))
        XCTAssertNil(segs[0].isWearer)
        let json = String(decoding: try JSONEncoder().encode(segs), as: UTF8.self)
        XCTAssertFalse(json.contains("Wearer") || json.contains("wearer"), "没判定时不写这几个字段")
        var s = segs[0]
        s.isWearer = false
        s.wearerShare = 0.25
        let back = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.isWearer, false)
        XCTAssertEqual(back.wearerShare, 0.25)
    }

    // MARK: 补算时按句切音频

    func testSlicerMatchesWholeAudio() {
        let audio = (0..<48_000).map { Float($0) }
        let times: [(start: Double, end: Double)] = [(0.1, 0.4), (0.5, 1.6), (1.65, 1.7), (2.5, 3.5)]  // 最后一句超出音频
        var got: [Int: [Float]] = [:]
        var slicer = SentenceAudioSlicer(times: times)
        var i = 0
        while i < audio.count {
            let chunk = Array(audio[i..<min(i + 7_000, audio.count)])
            slicer.feed(chunk) { got[$0] = Array($1) }
            i += 7_000
        }
        slicer.finish { got[$0] = Array($1) }
        XCTAssertEqual(got[0], Array(audio[1600..<6400]))
        XCTAssertEqual(got[1], Array(audio[8000..<25600]))
        XCTAssertEqual(got[2], Array(audio[26400..<27200]))
        XCTAssertEqual(got[3], Array(audio[40000..<48000]))
    }

    // MARK: 真模型（本机有模型才跑）

    static let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("openbean/models")

    func say(_ voice: String, _ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "--data-format=LEF32@16000", "-o", url.path, text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("没有语音 \(voice)") }
        return try AudioFile16k.samples(url)
    }

    /// 合成语音（系统 TTS，不是真人）：同一个声音两句话比两个不同声音更像
    func testExtractorOnSyntheticVoices() throws {
        guard FileManager.default.fileExists(atPath: Self.models.appendingPathComponent(SpeakerEmbedder.modelPath).path) else {
            throw XCTSkip("没有声纹模型（Scripts/fetch-deps.sh）")
        }
        let e = try SpeakerEmbedder(modelsDir: Self.models)
        XCTAssertEqual(e.dim, 192)
        let a1 = try XCTUnwrap(e.embed(try say("Tingting", "今天下午我们去公园散步，顺便买点水果回来。")))
        let a2 = try XCTUnwrap(e.embed(try say("Tingting", "这个周末的会议改到星期一上午九点开始。")))
        let b = try XCTUnwrap(e.embed(try say("Samantha", "The weather is lovely today, let's take a long walk in the park.")))
        XCTAssertEqual(SpeakerMath.dot(a1, a1), 1, accuracy: 1e-3)
        XCTAssertGreaterThan(SpeakerMath.dot(a1, a2), SpeakerMath.dot(a1, b))
        XCTAssertNil(e.embed([Float](repeating: 0, count: 10)), "太短算不出来")

        // 扫描器：一句 3 秒切成 3 个窗口
        let s = SpeakerScanner(embedder: e)
        let speech = try say("Tingting", "今天下午我们去公园散步，顺便买点水果回来，晚上一起做饭。")
        s.add(sentence: 0, samples: speech[0..<48_000])
        XCTAssertEqual(s.windows.count, 3)
        XCTAssertTrue(s.windows.sentence.allSatisfy { $0 == 0 })
    }
}
