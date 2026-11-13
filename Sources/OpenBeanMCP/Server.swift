// SPDX-License-Identifier: Apache-2.0

import Foundation

/// MCP 服务的协议层：一行一条 JSON-RPC 2.0 消息进，一行回复出（通知不回复）。只有工具，没有资源和提示词。
///
/// 两代协议都支持（规范的「dual-era」）：
/// - 现行版本 2026-07-28 是无状态的：每个请求在 params._meta 里带协议版本和客户端能力，没有 initialize 握手，
///   结果里带 resultType 和 serverInfo；必须实现 server/discover。
/// - 2025-11-25 及更早用 initialize 握手协商版本，目前的客户端（Claude Code、Claude Desktop、Cursor）大多还是这种。
/// 见 https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning
public final class MCPServer {
    /// 无状态的新版本（请求里带 _meta 协议版本）
    public static let modernVersions = ["2026-07-28"]
    /// 用 initialize 握手的旧版本，新的在前
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    /// 工具清单不随运行变化，客户端可以缓存一小时
    static let cacheTTL = 3_600_000

    public let tools: LibraryTools
    let version: String
    /// initialize 协商出的旧版本；没握手过是 nil
    public private(set) var negotiatedVersion: String?

    public init(tools: LibraryTools, version: String) {
        self.tools = tools
        self.version = version
    }

    public static let instructions = """
        Read-only access to the user's own recordings from their soundcore Work recorder, synced and transcribed on this Mac by OpenBean. \
        Use day_overview or list_recordings to find recordings by date, search_recordings to find where something was said, \
        get_recording for a recording's summary, key points and action items, and get_transcript for the words with timestamps. \
        Transcripts are automatic speech recognition and can contain mis-heard words, especially names; summaries were written by an LLM. \
        Dates are the user's local dates (YYYY-MM-DD, or "today" / "yesterday"); a day starts at 4 AM by default, as in the OpenBean app, \
        so a recording made after midnight belongs to the day before. Every result says the time zone, today's date and when a day starts. \
        Nothing here can change, delete or record anything.
        """

    var serverInfo: JSON {
        ["name": "openbean", "title": "OpenBean", "version": .string(version),
         "websiteUrl": "https://github.com/imraywang/openbean"]
    }

    var capabilities: JSON { ["tools": ["listChanged": false]] }

    // MARK: - 收发

    /// 处理一行输入，返回要写出的一行；通知和空行返回 nil
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = JSON.parse(trimmed) else {
            return Self.error(id: .null, code: -32700, message: "Parse error").serialized
        }
        return handle(message: message)?.serialized
    }

    public func handle(message: JSON) -> JSON? {
        guard case let .object(o) = message else {
            // 2025-06-18 起不再支持 JSON-RPC 批量请求
            return Self.error(id: .null, code: -32600, message: message.array != nil ? "Batch requests are not supported" : "Invalid Request")
        }
        let id = o["id"]
        guard let method = o["method"]?.string else {
            // 客户端发来的回复（服务端从不发请求）或缺 method 的通知：不回
            if id == nil || o["result"] != nil || o["error"] != nil { return nil }
            return Self.error(id: Self.echo(id), code: -32600, message: "Invalid Request: missing method")
        }
        guard let id else {
            // 通知：initialized、cancelled 等都不需要回复。请求都是依次同步处理的，cancelled 到的时候早已答完
            return nil
        }
        guard id.string != nil || id.number != nil else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request: id must be a string or a number")
        }

        let params: [String: JSON]
        switch o["params"] {
        case nil, .null?: params = [:]
        case let .object(p)?: params = p
        default: return Self.error(id: id, code: -32602, message: "Invalid params: params must be an object")
        }

        // 新版本：请求自带协议版本和客户端能力
        let meta = params["_meta"]?.object ?? [:]
        var modern = false
        if let requested = meta[Self.versionKey], method != "initialize" {
            guard let v = requested.string, Self.modernVersions.contains(v) else {
                return Self.error(id: id, code: -32022, message: "Unsupported protocol version",
                                  data: ["supported": .array(Self.modernVersions.map { .string($0) }), "requested": requested])
            }
            guard meta[Self.capabilitiesKey]?.object != nil else {
                return Self.error(id: id, code: -32602, message: "Invalid params: _meta is missing \(Self.capabilitiesKey)")
            }
            modern = true
        }

        let result: Result<[String: JSON], RPCError>
        switch method {
        case "initialize": result = initialize(params)
        case "server/discover":
            guard modern else {
                return Self.error(id: id, code: -32602,
                                  message: "Invalid params: server/discover needs _meta with \(Self.versionKey) and \(Self.capabilitiesKey)")
            }
            result = .success(["supportedVersions": .array(Self.modernVersions.map { .string($0) }),
                               "capabilities": capabilities, "instructions": .string(Self.instructions),
                               "ttlMs": .int(Self.cacheTTL), "cacheScope": "public"])
        case "ping": result = .success([:])
        case "tools/list":
            var r: [String: JSON] = ["tools": .array(tools.definitions)]
            if modern { r["ttlMs"] = .int(Self.cacheTTL); r["cacheScope"] = "public" }
            result = .success(r)
        case "tools/call": result = callTool(params)
        default: result = .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }

        switch result {
        case var .success(r):
            if modern {
                r["resultType"] = "complete"
                var m = r["_meta"]?.object ?? [:]
                m[Self.serverInfoKey] = serverInfo
                r["_meta"] = .object(m)
            }
            return ["jsonrpc": "2.0", "id": id, "result": .object(r)]
        case let .failure(e):
            return Self.error(id: id, code: e.code, message: e.message, data: e.data)
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
        var data: JSON?
    }

    // MARK: - 方法

    /// 旧版本握手：客户端要的版本我们支持就用它，否则回我们最新的旧版本，由客户端决定要不要断开
    func initialize(_ params: [String: JSON]) -> Result<[String: JSON], RPCError> {
        guard let requested = params["protocolVersion"]?.string else {
            return .failure(RPCError(code: -32602, message: "Invalid params: protocolVersion is required"))
        }
        let v = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
        negotiatedVersion = v
        return .success(["protocolVersion": .string(v), "capabilities": capabilities, "serverInfo": serverInfo,
                         "instructions": .string(Self.instructions)])
    }

    /// 不认识的工具、缺 name 是协议错误；参数值不对、录音不存在是工具错误（isError），让模型自己改了重试
    func callTool(_ params: [String: JSON]) -> Result<[String: JSON], RPCError> {
        guard let name = params["name"]?.string else {
            return .failure(RPCError(code: -32602, message: "Invalid params: name is required"))
        }
        let args: [String: JSON]
        switch params["arguments"] {
        case nil, .null?: args = [:]
        case let .object(a)?: args = a
        default: return .failure(RPCError(code: -32602, message: "Invalid params: arguments must be an object"))
        }
        guard let r = tools.call(name, arguments: args) else {
            return .failure(RPCError(code: -32602, message: "Unknown tool: \(name)"))
        }
        // content 给模型读的文字（和结构化内容信息相同，只是排成了文字）；structuredContent 给程序用
        var out: [String: JSON] = ["content": [["type": "text", "text": .string(r.text)]], "isError": .bool(r.isError)]
        if let s = r.structured { out["structuredContent"] = s }
        return .success(out)
    }

    // MARK: - 工具函数

    static func echo(_ id: JSON?) -> JSON {
        guard let id, id.string != nil || id.number != nil else { return .null }
        return id
    }

    static func error(id: JSON, code: Int, message: String, data: JSON? = nil) -> JSON {
        var e: [String: JSON] = ["code": .int(code), "message": .string(message)]
        if let data { e["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(e)]
    }
}
