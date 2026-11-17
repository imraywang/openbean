// SPDX-License-Identifier: Apache-2.0
// 认佩戴者（评测用，只读录音库）：speaker-scan <模型目录> <录音库 Library 文件夹> <输出文件夹> <录音号>...
// 按给的顺序逐条录音：读 audio.ogg 和 transcript.json（不写回），按句切 1.5 秒窗口算声纹，交候选（和 App 一样的
// SpeakerPass，日子按 index.json 的开始时间、凌晨 4 点日界），有了声纹就判定每句。
// 每条录音写 <输出>/<录音号>.speaker.json：候选向量、每个窗口的句号和得分、每句的占比 / 中位数 / 标签、耗时；
// 最后写 voiceprint.json。输出里有声纹向量，只能写到私人的评测文件夹，不能进仓库。标准输出只有统计数字。

import Foundation
import OpenBeanLibrary
import OpenBeanVoice

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("用法：speaker-scan <模型目录> <Library 文件夹> <输出文件夹> <录音号>...\n".utf8))
    exit(2)
}
let models = URL(fileURLWithPath: args[0]), library = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let index = (try JSONSerialization.jsonObject(with: Data(contentsOf: library.appendingPathComponent("index.json"))) as? [[String: Any]]) ?? []
let boundary = DayBoundary()
var voiceprint = Voiceprint()
let embedder = try SpeakerEmbedder(modelsDir: models)

func cpu() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

for rid in args[3...] {
    guard let id = UInt32(rid), let entry = index.first(where: { ($0["id"] as? NSNumber)?.uint32Value == id }),
          let startRef = (entry["start"] as? NSNumber)?.doubleValue else { print("\(rid): 不在 index.json"); continue }
    let start = Date(timeIntervalSinceReferenceDate: startRef)
    let duration = ((entry["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    let heart = (entry["source"] as? String) == "heart"
    let dir = library.appendingPathComponent(rid)
    var segs = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
    let scanner = SpeakerScanner(embedder: embedder)
    let c0 = cpu(), t0 = Date()
    var slicer = SentenceAudioSlicer(times: segs.map { ($0.start, $0.end) })
    var decodeWall = 0.0
    var td = Date()
    try AudioFile16k.read(dir.appendingPathComponent("audio.ogg")) { chunk, _ in
        decodeWall += Date().timeIntervalSince(td)
        slicer.feed(chunk) { scanner.add(sentence: $0, samples: $1) }
        td = Date()
    }
    slicer.finish { scanner.add(sentence: $0, samples: $1) }
    let embedWall = scanner.seconds
    let tc = Date()
    let candidate = SpeakerID.loudCandidate(scanner.windows)
    let clusterWall = Date().timeIntervalSince(tc)
    let r = SpeakerPass.run(windows: scanner.windows, candidate: candidate,
                            recording: .init(id: id, day: boundary.day(of: start), enrols: SpeakerPass.Recording.enrols(heart: heart, duration: duration)),
                            voiceprint: &voiceprint, segments: &segs)
    let cpuSecs = cpu() - c0, wall = Date().timeIntervalSince(t0)
    let w = scanner.windows
    let scores: [Float] = voiceprint.vector.map { v in (0..<w.count).map { w.cosine($0, v) } } ?? []
    let o: [String: Any] = [
        "id": rid, "hours": duration / 3600, "windows": w.count,
        "candidate": candidate.map { ["vector": $0.vector, "windows": $0.windows, "share": $0.share] as [String: Any] } ?? NSNull(),
        "event": "\(r.event.map { "\($0)" } ?? "none")", "worn": r.worn?.rawValue ?? "none", "outcome": r.scan.outcome.rawValue,
        "windowSentence": w.sentence.map { Int($0) }, "windowRmsDb": w.rmsDb, "windowScore": scores,
        "share": segs.map { $0.wearerShare ?? -1 }, "median": segs.map { $0.wearerScore ?? -2 },
        "label": segs.map { $0.isWearer.map { $0 ? 1 : 0 } ?? -1 },
        "cpu": cpuSecs, "wall": wall, "embedWall": embedWall, "clusterWall": clusterWall, "decodeWall": decodeWall,
    ]
    try JSONSerialization.data(withJSONObject: o).write(to: out.appendingPathComponent("\(rid).speaker.json"))
    let labelled = segs.filter { $0.isWearer != nil }.count, wearer = segs.filter { $0.isWearer == true }.count
    print(String(format: "%@: %.2f h, %d 句, %d 窗口, 候选 %@, %@ / %@；判定 %d 句，佩戴者 %d 句；CPU %.1f s（%.1f s/小时），挂钟 %.1f s，其中向量 %.1f s、聚类 %.2f s",
                 rid, duration / 3600, segs.count, w.count, candidate.map { "\($0.windows) 窗口 占 \(Int($0.share * 100))%" } ?? "无",
                 "\(r.event.map { "\($0)" } ?? "none")", r.scan.outcome.rawValue, labelled, wearer, cpuSecs, cpuSecs / max(duration / 3600, 1e-6),
                 wall, embedWall, clusterWall))
}
try voiceprint.write(out.appendingPathComponent("voiceprint.json"))
var ru = rusage()
getrusage(RUSAGE_SELF, &ru)
print(String(format: "声纹：%@，%d 段录音，%d 个窗口；峰值内存 %.0f MB", voiceprint.isReady ? "已确认" : "学习中",
             voiceprint.recordings, voiceprint.sampleCount, Double(ru.ru_maxrss) / 1_048_576))
