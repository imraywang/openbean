// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanMCP
import XCTest

final class ServerTests: XCTestCase {
    private var fx: Fixture!
    private var server: MCPServer!

    override func setUpWithError() throws {
        fx = try Fixture()
        server = fx.server()
    }

    override func tearDown() { fx.remove() }

    /// 发一行，解析回复
    @discardableResult
    private func send(_ line: String, file: StaticString = #filePath, line l: UInt = #line) throws -> JSON {
        let reply = try XCTUnwrap(server.handle(line: line), "no reply", file: file, line: l)
        XCTAssertFalse(reply.contains("\n"), "回复里不能有换行", file: file, line: l)
        return try XCTUnwrap(JSON.parse(reply), file: file, line: l)
    }

    private func request(_ id: Int, _ method: String, _ params: JSON? = nil) throws -> JSON {
        var m: [String: JSON] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if let params { m["params"] = params }
        return try send(JSON.object(m).serialized)
    }

    private func call(_ name: String, _ args: JSON = [:]) throws -> (text: String, structured: JSON, isError: Bool) {
        let r = try request(9, "tools/call", ["name": .string(name), "arguments": args])
        let result = try XCTUnwrap(r["result"], "\(r.serialized)")
        let text = try XCTUnwrap(result["content"]?.array?.first?["text"]?.string)
        return (text, result["structuredContent"] ?? .null, result["isError"]?.bool ?? false)
    }

    // MARK: 协议

    func testInitializeNegotiatesLegacyVersion() throws {
        let r = try request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                              "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertEqual(r["id"], 1)
        let result = try XCTUnwrap(r["result"])
        XCTAssertEqual(result["protocolVersion"], "2025-06-18")
        XCTAssertEqual(result["capabilities"], ["tools": ["listChanged": false]])
        XCTAssertEqual(result["serverInfo"]?["name"], "openbean")
        XCTAssertEqual(result["serverInfo"]?["version"], "0.0-test")
        XCTAssertNotNil(result["instructions"]?.string)
        XCTAssertNil(result["resultType"], "旧版本的结果不带 resultType")
        XCTAssertEqual(server.negotiatedVersion, "2025-06-18")

        // 不认识的版本：回我们最新的旧版本
        let r2 = try request(2, "initialize", ["protocolVersion": "2099-01-01", "capabilities": [:]])
        XCTAssertEqual(r2["result"]?["protocolVersion"], .string(MCPServer.legacyVersions[0]))
        // 缺版本
        XCTAssertEqual(try request(3, "initialize", [:])["error"]?["code"], -32602)
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"something/unknown"}"#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","id":5,"result":{}}"#), "客户端的回复不回")
        XCTAssertNil(server.handle(line: "   "))
    }

    func testPingAndUnknownMethod() throws {
        let p = try send(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        XCTAssertEqual(p["id"], "abc")
        XCTAssertEqual(p["result"], [:])
        let u = try request(7, "resources/list")
        XCTAssertEqual(u["error"]?["code"], -32601)
        XCTAssertEqual(u["id"], 7)
    }

    func testMalformedInputDoesNotCrash() throws {
        XCTAssertEqual(try send("{not json")["error"]?["code"], -32700)
        XCTAssertEqual(try send("{not json")["id"], .null)
        XCTAssertEqual(try send("[]")["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)["error"]?["code"], -32600)
        XCTAssertEqual(try send("42")["error"]?["code"], -32600)
        XCTAssertEqual(try send(#""hello""#)["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1}"#)["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)["error"]?["code"], -32600)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[1,2]}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#)["error"]?["code"], -32602)
        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_recording","arguments":"x"}}"#)["error"]?["code"], -32602)
        // 控制字符、超长行
        XCTAssertNotNil(server.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\u{0}\"}"))
        let long = String(repeating: "关键词", count: 100_000)
        let r = try call("search_recordings", ["query": .string(long)])
        XCTAssertFalse(r.isError)
    }

    func testToolsList() throws {
        let r = try request(1, "tools/list")
        let tools = try XCTUnwrap(r["result"]?["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, LibraryTools.names)
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"], "object")
            XCTAssertFalse(t["description"]?.string?.isEmpty ?? true)
            XCTAssertEqual(t["annotations"]?["readOnlyHint"], true)
            XCTAssertEqual(t["annotations"]?["openWorldHint"], false)
        }
        XCTAssertNil(r["result"]?["ttlMs"], "旧版本的 tools/list 不带缓存字段")
    }

    func testModernRequestsCarryMeta() throws {
        let meta: JSON = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                          "io.modelcontextprotocol/clientCapabilities": [:],
                          "io.modelcontextprotocol/clientInfo": ["name": "t", "version": "1"]]
        let d = try request(1, "server/discover", ["_meta": meta])
        let dr = try XCTUnwrap(d["result"], d.serialized)
        XCTAssertEqual(dr["resultType"], "complete")
        XCTAssertEqual(dr["supportedVersions"], ["2026-07-28"])
        XCTAssertEqual(dr["capabilities"]?["tools"], ["listChanged": false])
        XCTAssertEqual(dr["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"], "openbean")
        XCTAssertNotNil(dr["ttlMs"]?.number)
        XCTAssertEqual(dr["cacheScope"], "public")

        let l = try request(2, "tools/list", ["_meta": meta])
        XCTAssertEqual(l["result"]?["resultType"], "complete")
        XCTAssertNotNil(l["result"]?["ttlMs"]?.number)
        XCTAssertEqual(l["result"]?["cacheScope"], "public")

        let c = try request(3, "tools/call", ["_meta": meta, "name": "get_recording", "arguments": ["id": 1001]])
        XCTAssertEqual(c["result"]?["resultType"], "complete")
        XCTAssertEqual(c["result"]?["isError"], false)

        // 不支持的版本
        let bad = try request(4, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01",
                                                          "io.modelcontextprotocol/clientCapabilities": [:]]])
        XCTAssertEqual(bad["error"]?["code"], -32022)
        XCTAssertEqual(bad["error"]?["data"]?["requested"], "1900-01-01")
        XCTAssertEqual(bad["error"]?["data"]?["supported"], ["2026-07-28"])
        // 缺客户端能力
        let noCaps = try request(5, "tools/list", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        XCTAssertEqual(noCaps["error"]?["code"], -32602)
        // 不带 _meta 的 discover
        XCTAssertEqual(try request(6, "server/discover")["error"]?["code"], -32602)
    }

    func testUnknownToolIsProtocolError() throws {
        let r = try request(1, "tools/call", ["name": "delete_recording", "arguments": ["id": 1001]])
        XCTAssertEqual(r["error"]?["code"], -32602)
        XCTAssertEqual(r["error"]?["message"], "Unknown tool: delete_recording")
    }

    // MARK: 工具

    func testListRecordings() throws {
        let r = try call("list_recordings")
        XCTAssertFalse(r.isError)
        let items = try XCTUnwrap(r.structured["recordings"]?.array)
        XCTAssertEqual(items.compactMap { $0["id"]?.number }, [1003, 1001, 1002], "新的在前，语音输入片段不算")
        XCTAssertEqual(r.structured["total"], 3)
        XCTAssertEqual(r.structured["time_zone"], "Asia/Shanghai")
        XCTAssertEqual(r.structured["today"], "2026-11-13")
        let meeting = items[1]
        XCTAssertEqual(meeting["start"], "2026-11-12T15:11:33+08:00")
        XCTAssertEqual(meeting["title"], "周会")
        XCTAssertEqual(meeting["duration_seconds"], 754)
        XCTAssertEqual(meeting["has_summary"], true)
        XCTAssertEqual(meeting["gist"], "讨论 0.4 发布时间。")
        XCTAssertEqual(meeting["open_url"], "openbean://open/1001")
        XCTAssertEqual(items[0]["status"], "not_on_mac")
        XCTAssertEqual(items[0]["has_transcript"], false)
        XCTAssertEqual(items[2]["gist"], "Remember to buy milk.", "没有摘要用转写开头")
        XCTAssertTrue(r.text.contains("id 1001 — 2026-11-12 15:11, 12:34 — 周会 [transcript, summary]"), r.text)
        XCTAssertFalse(r.text.contains("秘密"))

        // 日期范围（本地日期，两端都含）、关键词、条数
        XCTAssertEqual(try call("list_recordings", ["from": "2026-11-12", "to": "2026-11-12"]).structured["total"], 2)
        XCTAssertEqual(try call("list_recordings", ["from": "yesterday"]).structured["total"], 2)
        XCTAssertEqual(try call("list_recordings", ["to": "2026-11-11"]).structured["recordings"]?.array?.first?["id"], 1002)
        XCTAssertEqual(try call("list_recordings", ["from": "today"]).structured["total"], 0)
        XCTAssertEqual(try call("list_recordings", ["query": "MILK"]).structured["recordings"]?.array?.count, 1)
        XCTAssertEqual(try call("list_recordings", ["query": "秘密"]).structured["total"], 0)
        let limited = try call("list_recordings", ["limit": 1])
        XCTAssertEqual(limited.structured["recordings"]?.array?.count, 1)
        XCTAssertTrue(limited.text.contains("2 more not shown"), limited.text)
        XCTAssertEqual(try call("list_recordings", ["limit": "2"]).structured["recordings"]?.array?.count, 2)

        // 参数错误是工具错误
        XCTAssertTrue(try call("list_recordings", ["from": "12/11/2026"]).isError)
        XCTAssertTrue(try call("list_recordings", ["from": "2026-02-30"]).isError)
        XCTAssertTrue(try call("list_recordings", ["from": "2026-11-13", "to": "2026-11-12"]).isError)
        XCTAssertTrue(try call("list_recordings", ["query": 5]).isError)
    }

    func testDevLibraryLinks() throws {
        server = fx.server(flavor: .dev)
        XCTAssertEqual(try call("get_recording", ["id": 1001]).structured["open_url"], "openbean-dev://open/1001")
    }

    func testGetRecording() throws {
        let r = try call("get_recording", ["id": 1001])
        XCTAssertFalse(r.isError)
        let s = r.structured
        XCTAssertEqual(s["summary"]?["key_points"], ["下周五发布"])
        XCTAssertEqual(s["summary"]?["action_items"], ["小王写文档"])
        XCTAssertEqual(s["summary"]?["model"], "qwen3")
        XCTAssertEqual(s["note_path"], "/Users/me/Notes/2026-11-12-周会.md")
        XCTAssertEqual(s["transcript"]?["sentences"], 3)
        XCTAssertEqual(s["end"], "2026-11-12T15:24:07+08:00")
        for part in ["Recording 1001: 周会", "Key points:", "- 小王写文档", "openbean://open/1001", "Note file: /Users/me/Notes"] {
            XCTAssertTrue(r.text.contains(part), "\(part) not in \(r.text)")
        }

        let noSummary = try call("get_recording", ["id": "1002"])
        XCTAssertFalse(noSummary.isError)
        XCTAssertEqual(noSummary.structured["summary"], .null)
        XCTAssertEqual(noSummary.structured["note_path"], .null)

        let notSynced = try call("get_recording", ["id": 1003])
        XCTAssertTrue(notSynced.text.contains("only on the recorder"), notSynced.text)

        let missing = try call("get_recording", ["id": 42])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("No recording with id 42"))
        XCTAssertTrue(try call("get_recording", ["id": 1004]).isError, "语音输入片段不给读")
        XCTAssertTrue(try call("get_recording").isError)
        XCTAssertTrue(try call("get_recording", ["id": -1]).isError)
        XCTAssertTrue(try call("get_recording", ["id": 1.5]).isError)
        XCTAssertTrue(try call("get_recording", ["id": "abc"]).isError)
    }

    func testGetTranscriptPagesAndRanges() throws {
        let full = try call("get_transcript", ["id": 1001])
        XCTAssertFalse(full.isError)
        XCTAssertTrue(full.text.contains("[00:00] 大家好"), full.text)
        XCTAssertTrue(full.text.contains("[01:05] 小王负责写文档。"), full.text)
        XCTAssertEqual(full.structured["truncated"], false)
        XCTAssertEqual(full.structured["segments"]?.array?.count, 3)

        let middle = try call("get_transcript", ["id": 1001, "start_seconds": 4, "end_seconds": 60])
        XCTAssertEqual(middle.structured["segments"]?.array?.compactMap { $0["text"]?.string }, ["下周五发布，预算不变。"])
        let after = try call("get_transcript", ["id": 1001, "start_seconds": 8.2])
        XCTAssertEqual(after.structured["segments"]?.array?.count, 1)
        let empty = try call("get_transcript", ["id": 1001, "start_seconds": 500])
        XCTAssertFalse(empty.isError)
        XCTAssertTrue(empty.text.contains("nothing in this range"), empty.text)

        XCTAssertTrue(try call("get_transcript", ["id": 1001, "start_seconds": 10, "end_seconds": 5]).isError)
        XCTAssertTrue(try call("get_transcript", ["id": 1001, "start_seconds": -3]).isError)
        let notSynced = try call("get_transcript", ["id": 1003])
        XCTAssertTrue(notSynced.isError)
        XCTAssertTrue(notSynced.text.contains("only on the recorder"))
        XCTAssertTrue(try call("get_transcript", ["id": 99]).isError)
    }

    func testTranscriptTruncation() throws {
        let segs: [[String: Any]] = (0..<100).map { (i: Int) -> [String: Any] in
            let text: String = String(repeating: "字", count: 50) + "第\(i)句"
            return ["start": Double(i * 10), "end": Double(i * 10 + 9), "text": text]
        }
        try fx.writeJSON("transcript.json", segs, id: 1002)
        let page = try call("get_transcript", ["id": 1002, "max_chars": 1000])
        XCTAssertEqual(page.structured["truncated"], true)
        let n = try XCTUnwrap(page.structured["segments"]?.array?.count)
        XCTAssertTrue((15...18).contains(n), "\(n)")
        XCTAssertEqual(page.structured["next_start_seconds"]?.number, Double(n * 10))
        XCTAssertTrue(page.text.contains("start_seconds=\(n * 10) to read on"), page.text)
        XCTAssertLessThan(page.text.count, 1300)
        // 读完全部：不重复不遗漏
        var all: [String] = []
        var start = 0.0
        while true {
            let p = try call("get_transcript", ["id": 1002, "max_chars": 1000, "start_seconds": .double(start)])
            all += p.structured["segments"]?.array?.compactMap { $0["text"]?.string } ?? []
            guard let next = p.structured["next_start_seconds"]?.number else { break }
            start = next
        }
        XCTAssertEqual(all.count, 100)
        XCTAssertEqual(Set(all).count, 100)
        // 默认上限 6000 字
        XCTAssertEqual(try call("get_transcript", ["id": 1002]).structured["truncated"], true)
    }

    func testSearch() throws {
        let r = try call("search_recordings", ["query": "发布"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.structured["total"], 1)
        let hit = try XCTUnwrap(r.structured["results"]?.array?.first)
        XCTAssertEqual(hit["id"], 1001)
        let matches = try XCTUnwrap(hit["matches"]?.array)
        XCTAssertEqual(matches.compactMap { $0["field"]?.string }, ["summary", "key_point", "transcript", "transcript"])
        XCTAssertEqual(matches[3]["timestamp"], "[00:03]")
        XCTAssertEqual(matches[3]["at"], "2026-11-12T15:11:36+08:00")
        XCTAssertTrue(r.text.contains("[00:03] "), r.text)

        XCTAssertEqual(try call("search_recordings", ["query": "openbean"]).structured["total"], 1)
        XCTAssertEqual(try call("search_recordings", ["query": "milk", "from": "2026-11-12"]).structured["total"], 0)
        XCTAssertEqual(try call("search_recordings", ["query": "milk", "to": "2026-11-11"]).structured["total"], 1)
        let none = try call("search_recordings", ["query": "秘密"])
        XCTAssertFalse(none.isError)
        XCTAssertEqual(none.structured["total"], 0)
        XCTAssertTrue(none.text.contains("No recordings mention"))
        XCTAssertTrue(try call("search_recordings").isError)
        XCTAssertTrue(try call("search_recordings", ["query": "  "]).isError)
    }

    func testDayOverview() throws {
        let r = try call("day_overview", ["date": "2026-11-12"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.structured["date"], "2026-11-12")
        XCTAssertEqual(r.structured["recordings"]?.array?.compactMap { $0["id"]?.number }, [1001, 1003], "当天按时间顺序")
        XCTAssertEqual(r.structured["action_items"], [["recording_id": 1001, "text": "小王写文档"]])
        XCTAssertEqual(r.structured["total_duration_seconds"], 844)
        XCTAssertTrue(r.text.hasPrefix("2026-11-12 (Thursday): 2 recordings, 14:04 in total."), r.text)
        XCTAssertTrue(r.text.contains("15:11 · 12:34 · 周会 (id 1001)"), r.text)

        let yesterday = try call("day_overview", ["date": "yesterday"])
        XCTAssertEqual(yesterday.structured["date"], "2026-11-12")
        let today = try call("day_overview")
        XCTAssertEqual(today.structured["date"], "2026-11-13")
        XCTAssertTrue(today.text.contains("no recordings"))
        XCTAssertTrue(try call("day_overview", ["date": "tomorrow-ish"]).isError)
    }

    func testMissingOrBrokenLibraryIsToolError() throws {
        let empty = try Fixture(index: false)
        defer { empty.remove() }
        server = empty.server()
        let r = try call("list_recordings")
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("No OpenBean recording library"), r.text)
        XCTAssertTrue(try call("search_recordings", ["query": "x"]).isError)
        // 协议本身照常工作
        XCTAssertNotNil(try request(1, "tools/list")["result"])

        try empty.write("index.json", "[{\"id\":")
        let broken = try call("day_overview")
        XCTAssertTrue(broken.isError)
        XCTAssertTrue(broken.text.contains("could not be read right now"), broken.text)

        // 转写文件损坏：get_recording 照常，get_transcript 报暂时不可用
        try fx.write("transcript.json", "[{\"start\":", id: 1001)
        server = fx.server()
        XCTAssertFalse(try call("get_recording", ["id": 1001]).isError)
        let t = try call("get_transcript", ["id": 1001])
        XCTAssertTrue(t.isError)
        XCTAssertTrue(t.text.contains("can't be read right now"))
    }

    func testJSONSerializationEscapes() {
        let j: JSON = ["text": "第一行\n第二行\t\"引号\" \\ \u{1}", "n": 3.5, "i": 7, "b": true, "z": nil]
        XCTAssertEqual(j.serialized, #"{"b":true,"i":7,"n":3.5,"text":"第一行\n第二行\t\"引号\" \\ \u0001","z":null}"#)
        XCTAssertEqual(JSON.parse(j.serialized), j)
    }
}
