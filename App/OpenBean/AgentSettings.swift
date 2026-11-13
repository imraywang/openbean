// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// App 包里的只读 MCP 服务（bin/build-app、bin/release 把它放进 Contents/Helpers）
enum MCPHelper {
    static var url: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/openbean-mcp") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: url.path) }
    /// 开发版用另一个名字，免得和正式版的配置重名
    static var serverName: String { Flavor.isDev ? "openbean-dev" : "openbean" }
    /// 从「下载」等处直接打开时系统会把 App 搬到随机的临时路径（App Translocation），那个路径下次就没了
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// 标准的 mcpServers 配置片段（Claude Desktop、Cursor 等通用）
    static var configJSON: String {
        let entry: [String: Any] = ["command": url.path, "args": [String]()]
        let obj: [String: Any] = ["mcpServers": [serverName: entry]]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    /// Claude Code 的一行命令（code.claude.com/docs/en/mcp：选项在名字前，-- 之后是要运行的命令）
    static var claudeCommand: String {
        "claude mcp add --transport stdio --scope user \(serverName) -- \(shellQuoted(url.path))"
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 设置窗口「Agent」页：给 agent 用的说明、服务路径、拷贝配置和 Claude Code 命令：说明、服务路径、拷贝配置和 Claude Code 命令
struct AgentSettingsSection: View {
    @State private var copied: String?

    var body: some View {
        Section {
            Text("Let your own AI agent (Claude Code, Claude Desktop, Cursor…) read your recordings: list them by date, read summaries and transcripts, and search what was said.")
            if MCPHelper.isInstalled {
                LabeledContent("Server") {
                    Text(MCPHelper.url.path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                if MCPHelper.isTranslocated || !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    Label("Move OpenBean to the Applications folder first: the path changes when the app moves.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button("Copy configuration") { copy(MCPHelper.configJSON, as: "config") }
                    Button("Copy Claude Code command") { copy(MCPHelper.claudeCommand, as: "command") }
                    if copied != nil {
                        Text("Copied").foregroundStyle(.secondary).transition(.opacity)
                    }
                }
                Text(MCPHelper.claudeCommand)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Label("This build doesn't include openbean-mcp. Build the app with bin/build-app.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("For agents (MCP)")
        } footer: {
            Text("Paste the configuration into your agent's mcpServers settings (Claude Desktop: Settings → Developer → Edit Config), or run the command in Terminal for Claude Code. Read-only: it can't change, delete or record anything, and can't reach audio or voice typing. It runs only while an agent starts it. The transcripts and summaries it reads go to the agent you connect and the model behind it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, as what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = what }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if copied == what { copied = nil } }
        }
    }
}
