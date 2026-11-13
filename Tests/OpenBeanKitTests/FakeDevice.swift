// SPDX-License-Identifier: Apache-2.0

import CryptoKit
@testable import OpenBeanKit
import XCTest

/// 假的录音豆一侧：做完握手、按真机格式造 1A/07 文件头、加密的 1A/08（或 1A/12）分片和 1A/0A。
/// 每片的明文由 seq 决定（`plain(seq:)`），解密后能逐片核对。
final class FakeDevice {
    let crypto = SessionCrypto()
    private let sessionKey: [UInt8]
    let fileKey: [UInt8]
    let nonce: [UInt8]

    init(seed: UInt8 = 7) throws {
        let dev = P256.KeyAgreement.PrivateKey()
        let shared = try dev.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: crypto.publicKey))
            .withUnsafeBytes { Array($0) }
        try crypto.complete(devicePublicKey: Array(dev.publicKey.x963Representation), deviceShared: shared)
        sessionKey = SessionCrypto.hkdf(shared, salt: [1, 2, 3], info: [1, 2, 3], length: 32)
        fileKey = (0..<32).map { UInt8(($0 * Int(seed)) & 0xFF) }
        nonce = (0..<16).map { UInt8(0xA0 &+ UInt8($0) &+ seed) }
    }

    static func frame(type: UInt8 = 0x1A, id: UInt8, status: UInt8 = 1, payload: [UInt8]) -> Packet {
        let total = 9 + payload.count + 1
        var f: [UInt8] = [0x09, 0xFF, 0, 0, status, type, id, UInt8(total & 0xFF), UInt8(total >> 8)] + payload
        f.append(Frame.checksum(f[...]))
        return Packet(raw: f)
    }

    /// 每片的明文：像真的 Opus 帧一样首字节固定（TOC），其余随 seq 变
    static func plain(seq: UInt32) -> [UInt8] {
        [0x78] + (1..<160).map { UInt8((Int(seq) &* 31 &+ $0) & 0xFF) }
    }

    /// 1A/07：fileId、size（线上字节，每片 166）、nonce、包好的文件密钥、会话 nonce、错误码
    func head(fileId: UInt32, slices: Int, error: UInt8 = 0) throws -> Packet {
        let sessionNonce = (0..<16).map { UInt8(0x10 + $0) }
        let wrapped = try AESCTR.apply(key: sessionKey, iv: sessionNonce, data: Array("soundcored3200".utf8) + fileKey)
        let payload = u32le(fileId) + u32le(UInt32(slices * 166)) + nonce + wrapped + sessionNonce + [error, 0]
        return Self.frame(id: 0x07, payload: payload)
    }

    func cipher(seq: UInt32) throws -> [UInt8] {
        let c = seq &* 10
        let iv = Array(nonce.prefix(12)) + [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        return try AESCTR.apply(key: fileKey, iv: iv, data: Self.plain(seq: seq))
    }

    /// 一个分片包：每单元 seq u32 | flags | 160 字节密文 | 填充
    func slices(_ seqs: [UInt32], id: UInt8 = 0x08, flags: [UInt32: UInt8] = [:]) throws -> Packet {
        var payload: [UInt8] = []
        for q in seqs { payload += u32le(q) + [flags[q] ?? 0] + (try cipher(seq: q)) + [0] }
        return Self.frame(id: id, payload: payload)
    }

    /// 1A/0A：前 5 字节含义未知，后 4 字节文件 id
    static func done(fileId: UInt32) -> Packet { frame(id: 0x0A, payload: [0, 0x30, 0x1B, 0, 0] + u32le(fileId)) }

    /// 按真机的节奏把整个文件切成包：每包 `perPacket` 片
    func packets(fileId: UInt32, slices n: Int, perPacket: Int = 3, done: Bool = true) throws -> [Packet] {
        var out = [try head(fileId: fileId, slices: n)]
        for start in stride(from: 0, to: n, by: perPacket) {
            out.append(try slices((start..<min(start + perPacket, n)).map(UInt32.init)))
        }
        if done { out.append(Self.done(fileId: fileId)) }
        return out
    }
}
