// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import OpenBeanMCP
import XCTest

/// 起真实的 openbean-mcp 进程，指向临时假录音库，经 stdin/stdout 走一遍 initialize → tools/list → tools/call
final class EndToEndTests: XCTestCase {
    private var binary: URL {
        // swift test 把可执行文件和 .xctest 放在同一个构建目录
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("openbean-mcp")
    }

    func testStdioSession() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "没有编出 openbean-mcp：\(binary.path)")
        let fx = try Fixture()
        defer { fx.remove() }

        let p = Process()
        p.executableURL = binary
        p.arguments = ["--library", fx.root.path]
        var env = ProcessInfo.processInfo.environment
        env["TZ"] = "Asia/Shanghai"
        env.removeValue(forKey: "OPENBEAN_LIBRARY")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()

        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_recordings","arguments":{"query":"预算"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_recording","arguments":{"id":999}}}"#,
            "this is not json",
            #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#,
        ]
        stdin.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()  // 关掉 stdin，服务应自己退出

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(log.contains(fx.folder.path), log)

        let replies = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(replies.count, 6, "通知不回复，其余每条一行：\(replies)")
        let msgs = try replies.map { try XCTUnwrap(JSON.parse($0), $0) }
        XCTAssertEqual(msgs.map { $0["id"] }, [1, 2, 3, 4, .null, 5])
        XCTAssertEqual(msgs[0]["result"]?["protocolVersion"], "2025-11-25")
        XCTAssertEqual(msgs[1]["result"]?["tools"]?.array?.count, LibraryTools.names.count)
        let search = try XCTUnwrap(msgs[2]["result"])
        XCTAssertEqual(search["isError"], false)
        XCTAssertEqual(search["structuredContent"]?["results"]?.array?.first?["id"], 1001)
        XCTAssertTrue(search["content"]?.array?.first?["text"]?.string?.contains("[00:03]") ?? false)
        XCTAssertEqual(search["structuredContent"]?["time_zone"], "Asia/Shanghai")
        XCTAssertEqual(msgs[3]["result"]?["isError"], true)
        XCTAssertEqual(msgs[4]["error"]?["code"], -32700)
        XCTAssertEqual(msgs[5]["result"], [:])
    }

    func testHelpAndBadOption() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path))
        func run(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(try run(["--help"]), 0)
        XCTAssertEqual(try run(["--bogus"]), 2)
        XCTAssertEqual(try run(["--library"]), 2)
        // stdin 一开始就是空的：直接退出
        XCTAssertEqual(try run(["--library", "/nonexistent"]), 0)
    }
}
