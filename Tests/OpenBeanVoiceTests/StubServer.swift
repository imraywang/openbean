// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// 测试用的 OpenAI 兼容服务：只在 127.0.0.1 上监听，/v1/models 回 200，/v1/chat/completions 回 reply(请求体) 的内容
final class StubServer: @unchecked Sendable {
    private let listener: NWListener
    private let reply: ([String: Any]) -> String
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    let url: URL

    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }

    init(reply: @escaping ([String: Any]) -> String) throws {
        self.reply = reply
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        // 监听前必须先设好连接回调，那时 self 还没初始化完，经一个盒子转一下
        let box = Box()
        listener.newConnectionHandler = { c in box.server?.serve(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        url = URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
        box.server = self
    }

    func stop() { listener.cancel() }

    private final class Box: @unchecked Sendable { weak var server: StubServer? }

    private func serve(_ c: NWConnection) {
        c.start(queue: .global())
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self else { return }
            var buf = buf
            if let d { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[end.upperBound...]
                if body.count >= len {
                    self.respond(c, head: head, body: Data(body.prefix(len)))
                    return
                }
            }
            if done || err != nil { c.cancel(); return }
            self.read(c, buf)
        }
    }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        var out: Data
        if head.hasPrefix("GET") {
            out = Data(#"{"data":[]}"#.utf8)
        } else {
            let req = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            lock.lock(); bodies.append(req); lock.unlock()
            let obj: [String: Any] = ["choices": [["message": ["role": "assistant", "content": reply(req)]]]]
            out = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        }
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(out)
        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
    }
}
