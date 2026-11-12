// SPDX-License-Identifier: Apache-2.0

import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, CustomStringConvertible {
    case badDevicePublicKey
    case sharedMismatch(app: String, device: String)
    case noSession
    case badFileKeyMagic(String)
    case aes(Int32)

    public var description: String {
        switch self {
        case .badDevicePublicKey: return "设备公钥无法解析"
        case let .sharedMismatch(a, d): return "ECDH 共享密钥对不上\n  app=\(a)\n  dev=\(d)"
        case .noSession: return "还没有会话密钥，先做 ECDH 握手"
        case let .badFileKeyMagic(m): return "文件密钥前缀不是 soundcored3200，而是 \(m.debugDescription)"
        case let .aes(s): return "AES 出错 \(s)"
        }
    }
}

/// 握手：app 发 P-256 公钥 → 设备回公钥 + 它算出的共享密钥 → 双方比对 →
/// sessionKey = HKDF-SHA256(shared, salt=010203, info=010203, 32)。
public final class SessionCrypto {
    private let privateKey = P256.KeyAgreement.PrivateKey()
    public private(set) var sessionKey: [UInt8]?

    public init() {}

    public var publicKey: [UInt8] { Array(privateKey.publicKey.x963Representation) } // 0x04‖X‖Y，65 字节

    public func complete(devicePublicKey: [UInt8], deviceShared: [UInt8]) throws {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: devicePublicKey) else {
            throw CryptoError.badDevicePublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let shared = secret.withUnsafeBytes { Array($0) } // X 坐标 32 字节
        guard shared == deviceShared else {
            throw CryptoError.sharedMismatch(app: shared.hex, device: deviceShared.hex)
        }
        sessionKey = Self.hkdf(shared, salt: [1, 2, 3], info: [1, 2, 3], length: 32)
    }

    static func hkdf(_ ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Array($0) }
    }

    /// 用会话密钥解开文件头里的文件密钥，得到这个文件的分片解密器。
    public func fileDecryptor(for head: FileHead) throws -> FileDecryptor {
        guard let sessionKey else { throw CryptoError.noSession }
        let plain = try AESCTR.apply(key: sessionKey, iv: head.sessionNonce, data: head.encryptedFileKey)
        let magic = String(decoding: plain.prefix(14), as: UTF8.self)
        guard magic == "soundcored3200", plain.count >= 46 else { throw CryptoError.badFileKeyMagic(magic) }
        return FileDecryptor(key: Array(plain[14..<46]), nonce: head.nonce)
    }
}

/// 每片 160 字节，IV = nonce[0..<12] ‖ BE_u32(seq × 10)（160 字节正好 10 个 AES 块）。
public struct FileDecryptor {
    let key: [UInt8]
    let nonce: [UInt8]

    public func decrypt(seq: UInt32, data: [UInt8]) throws -> [UInt8] {
        let c = seq &* 10
        let iv = Array(nonce.prefix(12)) + [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
        return try AESCTR.apply(key: key, iv: iv, data: data)
    }
}

/// AES-CTR：16 字节计数器整体按大端 +1（与 Java AES/CTR/NoPadding 一致）。
public enum AESCTR {
    public static func apply(key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        var ref: CCCryptorRef?
        var status = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                     CCOptions(kCCOptionECBMode), key, key.count, nil, &ref)
        guard status == kCCSuccess, let ref else { throw CryptoError.aes(status) }
        defer { CCCryptorRelease(ref) }

        var counter = Array(iv.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - iv.count))
        var out = [UInt8](repeating: 0, count: data.count)
        var stream = [UInt8](repeating: 0, count: 16)
        var moved = 0
        var pos = 0
        while pos < data.count {
            status = CCCryptorUpdate(ref, counter, 16, &stream, 16, &moved)
            guard status == kCCSuccess else { throw CryptoError.aes(status) }
            for k in 0..<min(16, data.count - pos) { out[pos + k] = data[pos + k] ^ stream[k] }
            pos += 16
            var j = 15
            while j >= 0 { counter[j] &+= 1; if counter[j] != 0 { break }; j -= 1 }
        }
        return out
    }
}
