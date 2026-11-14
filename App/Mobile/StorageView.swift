// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
import SwiftUI

/// 存储：本机音频、转写和摘要、语音模型各占多少；按心力模式的音频保留规则清理（共用的 applyAudioRetention）
struct StorageView: View {
    let library: LibraryStore
    @State private var usage: StorageUsage?
    @State private var cleaned: Int?
    @State private var confirmClean = false

    private var settings: Settings { library.settings }

    var body: some View {
        List {
            Section {
                if let u = usage {
                    UsageBar(usage: u)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 12, trailing: 16))
                    row("Audio", detail: String(localized: "\(u.audioCount) recordings"), bytes: u.audio, color: .blue, icon: "waveform")
                    row("Transcripts and summaries", detail: nil, bytes: u.text, color: .green, icon: "doc.text")
                    row("Speech models", detail: u.models == 0 ? String(localized: "Not downloaded") : nil,
                        bytes: u.models, color: .purple, icon: "cpu")
                    LabeledContent("Total") { Text(Self.size(u.total)).monospacedDigit() }.bold()
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("On this iPhone")
            } footer: {
                if let u = usage, u.transcriptOnly > 0 {
                    Text("\(u.transcriptOnly) recordings only have a transcript left: their audio was removed under Heart mode's audio retention.")
                }
            }

            Section {
                LabeledContent("Heart mode recordings", value: retentionText)
                if let u = usage {
                    LabeledContent("Audio that can be removed now") {
                        Text(u.removable == 0 ? String(localized: "None") : String(localized: "\(u.removable) · \(Self.size(u.removableBytes))"))
                            .monospacedDigit()
                    }
                }
                Button("Clean up now", systemImage: "sparkles") { confirmClean = true }
                    .disabled((usage?.removable ?? 0) == 0)
                if let n = cleaned {
                    Label(n == 0 ? String(localized: "Nothing was removed.") : String(localized: "Removed the audio of \(n) recordings."),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio retention")
            } footer: {
                Text("Only Heart mode recordings that are transcribed lose their audio; transcripts, summaries and marks stay. Normal recordings always keep their audio. Change the rule in Heart mode settings. OpenBean also applies it on its own every hour.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .refreshable { await measure() }
        .confirmationDialog("Remove audio now?", isPresented: $confirmClean, titleVisibility: .visible) {
            Button("Remove audio of \(usage?.removable ?? 0) recordings", role: .destructive) { clean() }
        } message: {
            Text("Their transcripts and summaries stay on this iPhone. This cannot be undone.")
        }
    }

    private func row(_ title: LocalizedStringKey, detail: String?, bytes: Int64, color: Color, icon: String) -> some View {
        LabeledContent {
            Text(Self.size(bytes)).monospacedDigit()
        } label: {
            Label {
                Text(title)
                if let detail { Text(detail) }
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
        }
    }

    private var retentionText: String {
        guard settings.heartMode else { return String(localized: "Heart mode is off: keep audio") }
        switch settings.heartAudioRetention {
        case .afterTranscription: return String(localized: "Delete audio after transcription")
        case .sevenDays: return String(localized: "Keep audio for 7 days")
        case .forever: return String(localized: "Keep audio")
        }
    }

    private func clean() {
        let before = library.recordings.filter(\.audioRemoved).count
        library.applyAudioRetention()
        cleaned = library.recordings.filter(\.audioRemoved).count - before
        Task { await measure() }
    }

    private func measure() async {
        let rs = library.recordings.filter { !$0.isDictation }
        let mode = settings.mode
        let now = Date()
        // 现在能删的：和 applyAudioRetention 同一条规则（等着从设备删的那几条它会先留着，这里不细分）
        let removable = Set(rs.filter { r in
            r.downloaded && !r.audioRemoved && r.transcribed
                && AudioRetentionPolicy.check(source: r.recordingSource, retention: mode.audioRetention, audioExists: true,
                                              transcriptLines: library.transcript(r.id).count, syncedAt: r.syncedAt ?? r.start,
                                              now: now, awaitingRecorderDelete: false) == nil
        }.map(\.id))
        let transcriptOnly = rs.filter(\.audioRemoved).count
        let fake = Flavor.isFake
        usage = await Task.detached(priority: .userInitiated) {
            StorageUsage.measure(library: AppPaths.library, models: AppPaths.models, removable: removable,
                                 transcriptOnly: transcriptOnly, fakeModels: fake)
        }.value
    }

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

struct StorageUsage: Sendable {
    var audio: Int64 = 0
    var audioCount = 0
    var text: Int64 = 0
    var models: Int64 = 0
    var removable = 0
    var removableBytes: Int64 = 0
    var transcriptOnly = 0
    var total: Int64 { audio + text + models }

    /// 录音文件夹里 audio.ogg 和没下完的 download.part 算音频，其余（转写、摘要、对话段、日记、波形）算文字
    static func measure(library: URL, models: URL, removable: Set<UInt32>, transcriptOnly: Int, fakeModels: Bool) -> StorageUsage {
        var u = StorageUsage()
        u.transcriptOnly = transcriptOnly
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let e = fm.enumerator(at: library, includingPropertiesForKeys: keys) {
            var withAudio = Set<String>()
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let n = Int64(v.fileSize ?? 0)
                let name = url.lastPathComponent
                if name == "audio.ogg" || name == "download.part" {
                    u.audio += n
                    let folder = url.deletingLastPathComponent().lastPathComponent
                    if name == "audio.ogg" { withAudio.insert(folder) }
                    if let id = UInt32(folder), removable.contains(id), name == "audio.ogg" {
                        u.removable += 1
                        u.removableBytes += n
                    }
                } else {
                    u.text += n
                }
            }
            u.audioCount = withAudio.count
        }
        u.models = size(of: models)
        // 演示数据不下载模型：按真模型的大小摆出来
        if fakeModels, u.models == 0 { u.models = 240_193_589 }
        return u
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let url as URL in e { n += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return n
    }
}

/// 一条横条：音频、文字、模型各占多少
struct UsageBar: View {
    let usage: StorageUsage
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StorageView.size(usage.total)).font(.title2.bold().monospacedDigit())
            GeometryReader { g in
                let total = max(Double(usage.total), 1)
                HStack(spacing: 2) {
                    Rectangle().fill(.blue).frame(width: g.size.width * Double(usage.audio) / total)
                    Rectangle().fill(.green).frame(width: max(g.size.width * Double(usage.text) / total, usage.text > 0 ? 2 : 0))
                    Rectangle().fill(.purple).frame(width: g.size.width * Double(usage.models) / total)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .clipShape(.capsule)
            .background(.quaternary, in: .capsule)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Total \(StorageView.size(usage.total))"))
    }
}
