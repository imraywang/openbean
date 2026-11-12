// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

public struct SoftAPEndpoint: CustomStringConvertible {
    public let ip: String
    public let port: Int
    public var description: String { "\(ip):\(port)" }

    /// BLE 回包 1A/05：IP 在第 9–12 字节（倒序），端口在 13–14（小端）。
    public init?(frame r: [UInt8]) {
        guard r.count >= 15, (r[4] & 0x0F) == 1 else { return nil }
        ip = "\(r[12]).\(r[11]).\(r[10]).\(r[9])"
        port = Int(r[13]) | Int(r[14]) << 8
        guard port > 0 else { return nil }
    }
}

/// 加入设备热点之后的 WebSocket 通道：
/// 文本发 hex 命令，二进制收 `09 FF` 帧（和 BLE 同格式），另开 UDP 往 :32003 发保活。
public final class WifiExport: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let q = DispatchQueue(label: "d3200.wifi")
    private let crypto: SessionCrypto
    private let endpoint: SoftAPEndpoint
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var opened: CheckedContinuation<Void, Error>?
    private var assembler = FrameAssembler()
    private var state: TransferState?
    private var udp: NWConnection?
    private var udpTimer: DispatchSourceTimer?
    public private(set) var rxBytes = 0
    public var log: (String) -> Void = { _ in }

    public init(endpoint: SoftAPEndpoint, crypto: SessionCrypto) {
        self.endpoint = endpoint
        self.crypto = crypto
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        // 系统代理（Surge 等）不要碰设备热点
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
        ]
        cfg.timeoutIntervalForRequest = 12
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: 连接

    public func connect(attempts: Int = 3) async throws {
        let scheme = endpoint.port == 80 ? "ws" : "wss"
        let url = URL(string: "\(scheme)://\(endpoint.ip):\(endpoint.port)")!
        var lastError: Error?
        for i in 1...attempts {
            log("WebSocket \(url.absoluteString)（第 \(i)/\(attempts) 次）")
            var req = URLRequest(url: url)
            req.setValue("okhttp/3.12.13.18", forHTTPHeaderField: "User-Agent")
            req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
            let t = session.webSocketTask(with: req)
            t.maximumMessageSize = 4 << 20
            do {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    q.async {
                        self.opened = c
                        self.task = t
                        t.resume()
                        self.q.asyncAfter(deadline: .now() + 8) {
                            guard let c = self.opened else { return }
                            self.opened = nil
                            t.cancel()
                            c.resume(throwing: LinkError.timeout("WebSocket 握手"))
                        }
                    }
                }
                receive(t)
                startKeepAlive()
                return
            } catch {
                lastError = error
                log("  失败：\(error.localizedDescription)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError ?? LinkError.timeout("WebSocket")
    }

    public func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        q.async {
            guard let c = self.opened else { return }
            self.opened = nil
            c.resume()
        }
    }

    public func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        let code = (t.response as? HTTPURLResponse)?.statusCode
        log("WebSocket 结束：\(error?.localizedDescription ?? "正常")\(code.map { " HTTP \($0)" } ?? "")")
        q.async {
            guard let c = self.opened else { return }
            self.opened = nil
            c.resume(throwing: error ?? LinkError.disconnected)
        }
    }

    public func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask,
                           didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        log("WebSocket 被关闭 code=\(code.rawValue)")
    }

    /// 设备是自签证书，信任它。
    public func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = ch.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: 收

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(msg):
                self.q.async {
                    switch msg {
                    case let .data(d): self.ingest(Array(d))
                    case let .string(s):
                        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if clean.count >= 20, let bytes = Self.unhex(clean) { self.ingest(bytes) }
                        else { self.log("WS 文本：\(clean)") }
                    @unknown default: break
                    }
                }
                self.receive(t)
            case let .failure(e):
                self.log("WS 接收结束：\(e.localizedDescription)")
            }
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        rxBytes += bytes.count
        for p in assembler.feed(bytes) {
            if let st = state { D3200Session.handle(p, st, crypto) }
            else { log("（无传输时收到）\(p)") }
        }
    }

    static func unhex(_ s: String) -> [UInt8]? {
        let chars = Array(s.filter(\.isHexDigit))
        guard chars.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: chars.count, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }
    }

    // MARK: 保活

    private func startKeepAlive() {
        let conn = NWConnection(host: NWEndpoint.Host(endpoint.ip), port: 32003, using: .udp)
        conn.start(queue: q)
        udp = conn
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { conn.send(content: Data("soundcore-keep-alive-unicast".utf8), completion: .idempotent) }
        timer.resume()
        udpTimer = timer
    }

    // MARK: 拉文件

    public func pull(_ file: RecordingFile, maxSeconds: Double? = nil, idle: Double = 20,
                     progress: (Int, Int, Double) async -> Void) async throws -> Transfer {
        let st = TransferState(fileId: file.id)
        q.sync { state = st }
        let started = Date()
        try await task?.send(.string(Cmd.wifiFileRequestHex(id: file.id)))
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            let (bytes, done, quiet, expected) = q.sync {
                (st.bytes, st.done, Date().timeIntervalSince(st.lastActivity),
                 st.head.map { Int($0.size) / 166 * 160 } ?? file.audioBytes)
            }
            await progress(bytes, expected, Date().timeIntervalSince(started))
            if done || (expected > 0 && bytes >= expected) { break }
            if quiet > idle { break }
            if let maxSeconds, Date().timeIntervalSince(started) >= maxSeconds { break }
        }
        return q.sync {
            state = nil
            return D3200Session.makeTransfer(st, started: started)
        }
    }

    /// 和飞书一样收尾：文本 FINISH，再发 1A0A。
    public func close() async {
        try? await task?.send(.string("FINISH"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        try? await task?.send(.string(Cmd.wifiTransferCompleteHex()))
        try? await Task.sleep(nanoseconds: 300_000_000)
        task?.cancel(with: .normalClosure, reason: nil)
        q.sync {
            udpTimer?.cancel()
            udp?.cancel()
        }
        session.invalidateAndCancel()
    }
}
