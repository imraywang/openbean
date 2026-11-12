// SPDX-License-Identifier: Apache-2.0
// 批量离线识别（评测用）：sv-batch [选项] <模型目录> <文件列表.txt> <输出.jsonl>
// 列表每行一个音频文件路径；输出每行 {"file","seconds","ms","text","sentences":[{start,end,text}], ...}，已有的条目跳过（可续跑）。
// 选项：
//   --level off|file|stream  VAD 前的电平处理：off 不处理（旧行为）；file 整段先测再定固定增益（录音库转写）；
//                            stream 流式自动增益、按 100 ms 一块喂（实时听写），默认 file
//   --no-fallback            一句也没切出来时不整段识别
//   --stats                  只测音量，不识别
//   --glossary <词表>         每句再按词表纠正（和 App 一样），输出里加 "fixes":[[原文, 改成]]

import Foundation
import OpenBeanVoice

var args = Array(CommandLine.arguments.dropFirst())
var level = "file", fallback = true, statsOnly = false
var glossary = GlossaryCorrector(terms: [])
while let f = args.first, f.hasPrefix("--") {
    args.removeFirst()
    switch f {
    case "--level": level = args.removeFirst()
    case "--no-fallback": fallback = false
    case "--stats": statsOnly = true
    case "--glossary":
        let lines = try String(contentsOfFile: args.removeFirst(), encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        glossary = GlossaryCorrector(terms: lines)
    default: FileHandle.standardError.write(Data("未知选项 \(f)\n".utf8)); exit(2)
    }
}
guard args.count == 3, ["off", "file", "stream"].contains(level) else {
    FileHandle.standardError.write(Data("用法：sv-batch [--level off|file|stream] [--no-fallback] [--stats] [--glossary <词表>] <模型目录> <文件列表> <输出.jsonl>\n".utf8))
    exit(2)
}
let recognizer = try SentenceRecognizer(modelsDir: URL(fileURLWithPath: args[0]), minSilence: 0.6)
recognizer.fallbackWhenEmpty = fallback
let files = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n").map(String.init)
var seen = Set<String>()
if let old = try? String(contentsOfFile: args[2], encoding: .utf8) {
    for l in old.split(separator: "\n") {
        if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let f = o["file"] as? String { seen.insert(f) }
    }
} else { FileManager.default.createFile(atPath: args[2], contents: nil) }
let out = FileHandle(forWritingAtPath: args[2])!
out.seekToEndOfFile()
var n = 0, audio = 0.0
let t0 = Date()
for f in files where !seen.contains(f) {
    var row: [String: Any] = ["file": f, "level": level]
    do {
        let s = try AudioFile16k.samples(URL(fileURLWithPath: f))
        let st = AudioLevel.stats(s)
        row["seconds"] = Double(s.count) / 16000
        row["speech_db"] = Double(st.speech)
        row["noise_db"] = Double(st.noise)
        row["rms_db"] = Double(AudioLevel.db(s))
        row["peak"] = Double(s.map { abs($0) }.max() ?? 0)
        if !statsOnly {
            let t = Date()
            recognizer.reset()
            recognizer.adaptiveGain = nil
            recognizer.vadGainDb = 0
            var sents: [SentenceRecognizer.Sentence] = []
            switch level {
            case "file":
                recognizer.vadGainDb = st.gain
                row["gain_db"] = Double(st.gain)
                sents = recognizer.accept(s)
            case "stream":
                recognizer.adaptiveGain = AdaptiveGain()
                for i in stride(from: 0, to: s.count, by: 1600) { sents += recognizer.accept(Array(s[i..<min(i + 1600, s.count)])) }
            default:
                sents = recognizer.accept(s)
            }
            sents += recognizer.flush()
            row["ms"] = Date().timeIntervalSince(t) * 1000
            var fixes: [[String]] = []
            row["text"] = sents.map { s -> String in
                let r = glossary.correct(s.text)
                fixes += r.replacements.map { [$0.original, $0.replacement] }
                return r.text
            }.joined()
            if !glossary.isEmpty { row["fixes"] = fixes }
            row["fallback"] = recognizer.usedFallback
            row["sentences"] = sents.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        }
        audio += Double(s.count) / 16000
    } catch { row["error"] = "\(error)" }
    out.write(try JSONSerialization.data(withJSONObject: row) + Data("\n".utf8))
    n += 1
    if n % 200 == 0 { FileHandle.standardError.write(Data(String(format: "%d/%d 条，%.1f 分钟音频，用时 %.0f 秒\n", n, files.count, audio / 60, Date().timeIntervalSince(t0)).utf8)) }
}
FileHandle.standardError.write(Data(String(format: "完成 %d 条，%.1f 分钟音频，用时 %.0f 秒\n", n, audio / 60, Date().timeIntervalSince(t0)).utf8))
