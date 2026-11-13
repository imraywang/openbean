// SPDX-License-Identifier: Apache-2.0

// openbean-mcp：只读的 MCP 服务（stdio），让你自己的 agent 读本机的 OpenBean 录音库。
// 由 agent 启动、经 stdin/stdout 按行收发 JSON-RPC，stdin 关闭就退出；日志只写 stderr。
// 不碰蓝牙、不联网、不写任何文件、不提供音频，也不读语音输入记录（dictation.json）。

import Foundation
import OpenBeanLibrary
import OpenBeanMCP

let usage = """
    openbean-mcp — read-only MCP server (stdio) for the OpenBean recording library

    Usage: openbean-mcp [--dev | --library <path>]

      (no option)       the OpenBean app's library: ~/Library/Application Support/openbean
                        (inside OpenBean Dev.app: …/openbean-dev)
      --dev             the OpenBean Dev build's library: ~/Library/Application Support/openbean-dev
      --library <path>  any data folder or its Library folder (also: OPENBEAN_LIBRARY=<path>)
      --version, --help

    Started by an MCP client (Claude Code, Claude Desktop, Cursor…), e.g.
      claude mcp add --transport stdio --scope user openbean -- "<path to openbean-mcp>"
    """

func log(_ s: String) {
    FileHandle.standardError.write(Data(("openbean-mcp: " + s + "\n").utf8))
}

var args = Array(CommandLine.arguments.dropFirst())
var dev = false
var path: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--dev": dev = true
    case "--library":
        guard !args.isEmpty else { log("--library needs a path"); exit(2) }
        path = args.removeFirst()
    case "--help", "-h": print(usage); exit(0)
    case "--version": print(appVersion()); exit(0)
    default: log("unknown option \(a)\n\n\(usage)"); exit(2)
    }
}

/// 在 App 包里时用 App 的版本号
func appVersion() -> String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
    if let app = LibraryLocation.enclosingBundle(Bundle.main.executableURL ?? exe),
       let v = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
    return "dev"
}

let location = LibraryLocation.resolve(path: path, dev: dev, environment: ProcessInfo.processInfo.environment,
                                       executable: Bundle.main.executableURL)
/// 一天从几点开始：和 App 设置里的一样（App 存在自己的偏好设置里：正式版 dev.openbean.app，开发版 dev.openbean.app.dev）。
/// 环境变量 OPENBEAN_DAY_START_HOUR 优先；读不到就用 4
func dayStartHour() -> Int {
    let env = ProcessInfo.processInfo.environment
    if let v = env["OPENBEAN_DAY_START_HOUR"].flatMap(Int.init), (0...23).contains(v) { return v }
    let domain: String?
    switch location.flavor {
    case .release: domain = "dev.openbean.app"
    case .dev: domain = "dev.openbean.app.dev"
    case .custom: domain = Bundle.main.executableURL.flatMap(LibraryLocation.enclosingBundleIdentifier)
    }
    if let domain, let d = UserDefaults(suiteName: domain), d.object(forKey: "dayStartHour") != nil {
        let v = d.integer(forKey: "dayStartHour")
        if (0...23).contains(v) { return v }
    }
    return 4
}

let tools = LibraryTools(location: location, dayStartHour: dayStartHour())
let server = MCPServer(tools: tools, version: appVersion())
log("\(appVersion()), library \(location.folder.path) (\(location.flavor.rawValue)), day starts at \(dayStartHour()):00"
    + (RecordingLibrary(folder: location.folder).exists ? "" : " — not found yet"))

// 客户端提前关了管道时，写 stdout 不要被 SIGPIPE 直接杀掉，按出错退出
signal(SIGPIPE, SIG_IGN)
let out = FileHandle.standardOutput
while let line = readLine(strippingNewline: true) {
    guard let reply = server.handle(line: line) else { continue }
    do {
        try out.write(contentsOf: Data((reply + "\n").utf8))
    } catch {
        log("stdout closed: \(error)")
        exit(0)
    }
}
