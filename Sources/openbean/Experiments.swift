// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanKit

// 真机实验用的输出：pull / live --marks（重点标记）、pull --resume-test（断点续传）。
// 只读：不删、不改设备上的任何文件。

private func hex2(_ v: UInt8) -> String { String(format: "%02X", v) }
private func secs(_ v: Double) -> String { String(format: "%.2f", v) }

/// 重点标记排查：1A/12 包、flags 不为 0 的单元、最后一行摘要
func markReport(_ t: Transfer, limit: Int = 50) -> [String] {
    guard let d = t.diagnostics else { return ["（没有排查记录）"] }
    let first = t.firstSeq ?? 0
    func at(_ seq: UInt32) -> String { "第 \(secs(TransferDiagnostics.seconds(seq: seq, firstSeq: first))) 秒" }
    var out: [String] = ["", "重点标记排查（音频时间从这次收到的第一片 seq \(first) 算起，每片 20 ms）"]
    let frames = d.sliceFrames.sorted { $0.key < $1.key }.map { "1A/\(hex2($0.key)) × \($0.value)" }.joined(separator: "，")
    out.append("  分片包      \(frames.isEmpty ? "没有" : frames)；长度不是整数个 166 字节单元的包 \(d.oddFrames) 个")
    let flags = d.flagCounts.sorted { $0.key < $1.key }.map { "\(hex2($0.key)) × \($0.value)" }.joined(separator: "，")
    out.append("  flags 分布  \(flags.isEmpty ? "-" : flags)")

    out.append("  1A/12 包    \(d.markFrames.count) 个\(d.markFrames.count > limit ? "（只列前 \(limit) 个）" : "")")
    for m in d.markFrames.prefix(limit) {
        let seqText = m.seqs.isEmpty ? "按 1A/08 布局解析不出单元"
            : "seq \(m.seqs.first!)…\(m.seqs.last!)（\(m.seqs.count) 个单元）≈ \(at(m.seqs.first!))"
        out.append("    #\(m.packetIndex)  请求后 \(secs(m.elapsed)) 秒  \(seqText)  flags [\(m.flags.map(hex2).joined(separator: " "))]")
        out.append("      长度 \(m.rawLength)，(长度−10) mod 166 = \(m.unitRemainder)（0 或 165 = 和 1A/08 同布局）")
        out.append("      前 64 字节 \(m.rawHead.hex)")
    }

    out.append("  flags≠0 的单元  \(d.flaggedTotal) 个\(d.flaggedTotal > limit ? "（只列前 \(limit) 个）" : "")")
    for u in d.flaggedUnits.prefix(limit) {
        out.append("    #\(u.packetIndex)  1A/\(hex2(u.frameId))  seq \(u.seq)  flags=\(hex2(u.flags))  ≈ \(at(u.seq))")
    }

    let markAt = d.markFrames.compactMap { $0.seqs.first }.map { secs(TransferDiagnostics.seconds(seq: $0, firstSeq: first)) }
    let flagAt = d.flaggedUnits.map { secs(TransferDiagnostics.seconds(seq: $0.seq, firstSeq: first)) }
    out.append("")
    out.append("标记摘要：1A/12 共 \(d.markFrames.count) 个"
               + (markAt.isEmpty ? "" : "，在第 \(markAt.joined(separator: "、")) 秒")
               + "；flags≠0 的单元 \(d.flaggedTotal) 个"
               + (flagAt.isEmpty ? "" : "，在第 \(flagAt.prefix(20).joined(separator: "、"))\(flagAt.count > 20 ? "…" : "") 秒"))
    return out
}

/// 断点续传实验：基准 → 拉到一半停 → 按几种可能的单位续传，逐片和基准比对
func resumeTest(session s: D3200Session, file: RecordingFile, say: (String) -> Void,
                progress: @escaping (Int, Int, Double) async -> Void) async throws -> [String] {
    var log: [String] = []
    func out(_ line: String) { log.append(line); say(line) }
    final class Flag: @unchecked Sendable { var stop = false }

    out("续传实验：文件 \(file.id)，时长 \(secs(file.durationSeconds)) 秒，列表口径约 \(file.wireBytes) 线上字节")
    out("只读：只发 1A/07 请求，不删、不改设备上的任何文件。")

    // 1. 基准：完整拉一遍，记下每片密文
    out("\n[1/3] 完整拉一遍做基准…")
    let base = try await s.pull(file, idle: 15, diagnostics: TransferDiagnostics(keepCipher: true), progress: progress)
    let tail = await s.drain()
    let baseCipher = base.diagnostics?.cipher ?? [:]
    guard let bh = base.head, base.decrypted, let bFirst = base.firstSeq, let bLast = base.lastSeq else {
        out("基准没拉到（文件头 \(base.head == nil ? "没收到" : "有")，解密 \(base.decrypted)），实验停止。")
        return log
    }
    let baseDec = try s.crypto.fileDecryptor(for: bh)
    var basePlain: [UInt32: [UInt8]] = [:]
    for (q, c) in baseCipher { basePlain[q] = try baseDec.decrypt(seq: q, data: c) }
    out("  基准：seq \(bFirst)…\(bLast)，\(baseCipher.count) 片，缺 \(base.missingSeqs) 片，"
        + "结束包 \(base.gotDone ? "有" : "没有")，文件头 \(base.heads.count) 个（fileId=\(bh.fileId) size=\(bh.size) err=\(bh.errorCode)），"
        + "耗时 \(secs(base.seconds)) 秒；之后又收到 \(tail.slices) 片")
    out("  三个口径：文件头 size=\(bh.size)（÷166=\(Int(bh.size) / 166) 片）；列表时长 \(file.durationMs) ms（÷20=\(file.durationMs / 20) 片）；"
        + "解密后 \(basePlain.count * 160) 字节（÷160=\(basePlain.count) 片）")
    if !base.gotDone || base.missingSeqs > 0 {
        out("  ⚠️ 基准不完整（没结束包或有缺片），后面的比对只在基准收到的片上做。")
    }

    // 2. 拉到约一半主动停
    out("\n[2/3] 再拉一遍，到约一半时停止接收…")
    let flag = Flag()
    let half = max(1, basePlain.count * 160 / 2)
    let part = try await s.pull(file, idle: 15, diagnostics: TransferDiagnostics(keepCipher: true),
                                shouldCancel: { flag.stop }) { got, expected, elapsed in
        if got >= half { flag.stop = true }
        await progress(got, expected, elapsed)
    }
    let after = await s.drain(quiet: 3, maxSeconds: max(60, base.seconds * 1.5))
    let partCipher = part.diagnostics?.cipher ?? [:]
    var k: UInt32 = 0
    while partCipher[bFirst &+ k] != nil { k += 1 }
    out("  停在 seq \(bFirst &+ k)（连续收到 \(k) 片，共 \(partCipher.count) 片），耗时 \(secs(part.seconds)) 秒")
    out("  停止接收后设备又发了 \(after.slices) 片、\(secs(after.seconds)) 秒\(after.gotDone ? "，最后有 1A/0A" : "")"
        + "（> 0 说明设备不知道我们停了，会一直发到文件末尾）")
    if let ph = part.head {
        let sameKey = ph.nonce == bh.nonce && ph.encryptedFileKey == bh.encryptedFileKey
        out("  第二次请求的文件头：fileId=\(ph.fileId) size=\(ph.size)；文件密钥和基准\(sameKey ? "相同" : "不同（每次请求换一把）")")
    }
    let overlap = partCipher.keys.filter { baseCipher[$0] != nil }
    let sameCipher = overlap.filter { partCipher[$0] == baseCipher[$0] }.count
    out("  同一片的密文和基准相同：\(sameCipher) / \(overlap.count)")
    guard k > 0 else { out("没收到可用的前半段，实验停止。"); return log }

    // 3. 按几种单位续传
    var candidates: [(String, UInt32)] = [
        ("线上字节（文件头 size 的口径，166/片）", k * 166),
        ("解密后字节（160/片）", k * 160),
        ("毫秒（文件列表时长的口径，20/片）", k * 20),
        ("片数（从 0 数）", k),
    ]
    if bFirst != 0 { candidates.append(("seq 值本身", bFirst &+ k)) }
    var seen = Set<UInt32>()
    candidates = candidates.filter { seen.insert($0.1).inserted }

    out("\n[3/3] 从 seq \(bFirst &+ k) 续传，按 \(candidates.count) 种单位各试一次（期望第一片是 seq \(bFirst &+ k)）")
    var verdicts: [String] = []
    for (name, offset) in candidates {
        out("\n  ▸ offset=\(offset)（\(name)）")
        let r = try await s.pull(file, offset: offset, idle: 10, maxSeconds: base.seconds * 1.5 + 30,
                                 diagnostics: TransferDiagnostics(keepCipher: true), progress: progress)
        let drained = await s.drain()
        let c = r.diagnostics?.cipher ?? [:]
        let seqs = c.keys.sorted()
        if r.heads.isEmpty {
            out("    文件头：没重发 1A/07")
        }
        for (i, h) in r.heads.enumerated() {
            let sameKey = h.nonce == bh.nonce && h.encryptedFileKey == bh.encryptedFileKey
            out("    文件头 \(i + 1)：fileId=\(h.fileId)\(h.fileId == file.id ? "" : "（≠ 请求的 \(file.id)）") size=\(h.size)"
                + "（基准 \(bh.size)，差 \(Int(bh.size) - Int(h.size))） err=\(h.errorCode)，文件密钥和基准\(sameKey ? "相同" : "不同")")
        }
        guard let first = seqs.first, let last = seqs.last else {
            out("    没收到任何片（结束包 \(r.gotDone ? "有" : "没有")）")
            verdicts.append("\(name)：没收到数据")
            continue
        }
        out("    收到 seq \(first)…\(last)，\(seqs.count) 片，缺 \(r.missingSeqs) 片，结束包 \(r.gotDone ? "有" : "没有")，"
            + "耗时 \(secs(r.seconds)) 秒；之后又收到 \(drained.slices) 片")
        let compared = seqs.filter { baseCipher[$0] != nil }
        let cipherSame = compared.filter { c[$0] == baseCipher[$0] }.count
        let withBaseKey = compared.filter { (try? baseDec.decrypt(seq: $0, data: c[$0]!)) == basePlain[$0] }.count
        var withNewKey = "（没有新文件头）"
        if let h = r.head, let d = try? s.crypto.fileDecryptor(for: h) {
            withNewKey = "\(compared.filter { (try? d.decrypt(seq: $0, data: c[$0]!)) == basePlain[$0] }.count) / \(compared.count)"
        }
        out("    逐片比对（和基准都有的 \(compared.count) 片）：密文相同 \(cipherSame)；用基准的文件密钥解密后相同 \(withBaseKey)；用这次的文件头解密后相同 \(withNewKey)")
        out("    覆盖到基准末尾：\(last >= bLast ? "是" : "否（差 \(bLast - last) 片）")")

        let want = bFirst &+ k
        let verdict: String
        if first == want {
            verdict = "✓ 正好从停下的地方续上"
        } else if first == bFirst {
            verdict = "✗ 从头开始发（设备忽略了 offset，或这个单位下被取整到 0）"
        } else if first > bFirst {
            let per = Double(offset) / Double(first - bFirst)
            verdict = "≈ 从 seq \(first) 开始（期望 \(want)），相当于每片 \(String(format: "%.2f", per)) 个单位"
        } else {
            verdict = "? 第一片 seq \(first) 比基准第一片还小"
        }
        out("    结论：\(verdict)")
        verdicts.append("\(name) offset=\(offset)：\(verdict)；基准密钥解密对上 \(withBaseKey)/\(compared.count)")
    }

    out("\n续传实验汇总（停在 seq \(bFirst &+ k)）")
    verdicts.forEach { out("  " + $0) }
    return log
}
