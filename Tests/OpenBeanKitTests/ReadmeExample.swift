// SPDX-License-Identifier: Apache-2.0

import OpenBeanKit

/// README 里的示例：只编译不运行，保证文档里的 API 一直可用。
func readmeExample() async throws {
    let link = Link()
    try await link.waitPoweredOn()
    let device = await link.scan(seconds: 6).first { $0.serviceMatch }!
    try await link.connect(device.peripheral)

    let session = D3200Session(link: link)
    print(try await session.deviceInfo()!)
    try await session.handshake()
    for file in try await session.listFiles() { print(file.id, file.durationSeconds) }

    // React to the recorder's button and stream live audio
    session.observeEvents { event in
        if case let .recordingStarted(fileId) = event {
            _ = try? session.startRealtime(fileId: fileId) { seq, opusFrame in /* 20 ms of Opus */ }
        }
    }
}
