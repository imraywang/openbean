// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class PolisherTests: XCTestCase {
    func testLocalHosts() {
        for s in ["http://127.0.0.1:8092", "http://localhost:11434", "http://studio.local:1234",
                  "http://192.168.1.20:8080", "http://10.0.0.5", "http://172.20.1.1"] {
            XCTAssertTrue(Polisher.isLocal(URL(string: s)!), s)
        }
        for s in ["https://api.deepseek.com", "https://dashscope.aliyuncs.com/compatible-mode/v1",
                  "https://api.openai.com", "http://172.40.1.1"] {
            XCTAssertFalse(Polisher.isLocal(URL(string: s)!), s)
        }
    }

    func testEndpointPaths() {
        func u(_ s: String) -> String { Polisher.url(URL(string: s)!, "chat/completions").absoluteString }
        XCTAssertEqual(u("http://127.0.0.1:8092"), "http://127.0.0.1:8092/v1/chat/completions")
        XCTAssertEqual(u("https://api.deepseek.com/"), "https://api.deepseek.com/v1/chat/completions")
        XCTAssertEqual(u("https://dashscope.aliyuncs.com/compatible-mode/v1"),
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        XCTAssertEqual(u("https://api.moonshot.cn/v1/"), "https://api.moonshot.cn/v1/chat/completions")
    }
}
