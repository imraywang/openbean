// SPDX-License-Identifier: Apache-2.0

import CryptoKit
@testable import OpenBeanKit
import XCTest

final class ProtocolTests: XCTestCase {
    func testEncodeGetDeviceInfo() {
        // 08+EE+01+01+0A = 0x102 → 校验 0x02
        XCTAssertEqual(Cmd.getDeviceInfo(), [0x08, 0xEE, 0, 0, 0, 0x01, 0x01, 0x0A, 0x00, 0x02])
    }

    func testEncodeStartRecordAndTransfer() {
        let f = Cmd.startRecord()
        XCTAssertEqual(f.count, 11)
        XCTAssertEqual(Array(f[5...9]), [0x18, 0x82, 0x0B, 0x00, 0x01])
        let t = Cmd.transferFile(id: 0x6543_2100, offset: 0, realtime: true)
        XCTAssertEqual(t.count, 19)
        XCTAssertEqual(Array(t[9..<18]), [0, 0, 0, 0, 0x00, 0x21, 0x43, 0x65, 1])
        XCTAssertEqual(t.last, Frame.checksum(t[0..<18]))
    }

    private func rx(type: UInt8, id: UInt8, status: UInt8 = 1, payload: [UInt8]) -> [UInt8] {
        let total = 9 + payload.count + 1
        var f: [UInt8] = [0x09, 0xFF, 0, 0, status, type, id, UInt8(total & 0xFF), UInt8(total >> 8)] + payload
        f.append(Frame.checksum(f[...]))
        return f
    }

    func testAssemblerSplitsAndRejectsBadChecksum() {
        let a = rx(type: 0x01, id: 0x03, payload: [5, 7])
        var bad = rx(type: 0x01, id: 0x04, payload: [1, 0]); bad[bad.count - 1] &+= 1
        let b = rx(type: 0x1A, id: 0x0A, payload: [1])
        let stream = [0xAA, 0xBB] + a + bad + b
        var asm = FrameAssembler()
        var got: [Packet] = []
        for chunk in stride(from: 0, to: stream.count, by: 7) {
            got += asm.feed(Array(stream[chunk..<min(chunk + 7, stream.count)]))
        }
        XCTAssertEqual(got.map(\.id), [0x03, 0x0A])
        XCTAssertEqual(Array(got[0].payload), [5, 7])
        XCTAssertEqual(asm.badChecksum, 1)
    }

    func testFileListWithEndTime() {
        let payload = u16le(2) + u32le(1_760_000_000) + u32le(1_760_000_060) + u32le(48000)
            + u32le(1_760_000_100) + u32le(1_760_000_200) + u32le(160) + u32le(0) + u32le(0)
        let page = FileListPage(payload: payload, withEndTime: true)
        XCTAssertEqual(page.declaredCount, 2)
        XCTAssertEqual(page.files.map(\.durationMs), [48000, 160])
        XCTAssertEqual(page.files[0].durationSeconds, 48, accuracy: 0.001)
        XCTAssertEqual(page.files[0].audioBytes, 2400 * 160)
    }

    func testSlices() {
        var payload: [UInt8] = []
        for seq in [UInt32(3), 4] { payload += u32le(seq) + [0] + [UInt8](repeating: UInt8(seq), count: 160) + [0] }
        let f = rx(type: 0x1A, id: 0x08, payload: payload)
        let s = parseSlices(frame: f)
        XCTAssertEqual(s.map(\.seq), [3, 4])
        XCTAssertEqual(s[1].data, [UInt8](repeating: 4, count: 160))
    }

    /// NIST SP 800-38A F.5.5 CTR-AES256 加密，第 1、2 块。
    func testAESCTRVector() throws {
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let pt = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let ct = try AESCTR.apply(key: key, iv: iv, data: pt)
        XCTAssertEqual(ct, hex("601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5"))
    }

    /// RFC 5869 A.1
    func testHKDF() {
        let okm = SessionCrypto.hkdf(hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
                                     salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"), length: 42)
        XCTAssertEqual(okm, hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }

    /// 模拟设备一侧，走完 握手 → 包文件密钥 → 加密分片 → 我们解密。
    func testEndToEndDecrypt() throws {
        let app = SessionCrypto()
        let dev = P256.KeyAgreement.PrivateKey()
        let shared = try dev.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: app.publicKey))
            .withUnsafeBytes { Array($0) }
        try app.complete(devicePublicKey: Array(dev.publicKey.x963Representation), deviceShared: shared)
        let session = SessionCrypto.hkdf(shared, salt: [1, 2, 3], info: [1, 2, 3], length: 32)
        XCTAssertEqual(app.sessionKey, session)

        let fileKey = (0..<32).map { UInt8($0 * 7 & 0xFF) }
        let nonce = (0..<16).map { UInt8(0xA0 + $0) }
        let sessionNonce = (0..<16).map { UInt8(0x10 + $0) }
        let wrapped = try AESCTR.apply(key: session, iv: sessionNonce, data: Array("soundcored3200".utf8) + fileKey)
        let head = u32le(42) + u32le(320) + nonce + wrapped + sessionNonce + [0, 0]
        let frame = rx(type: 0x1A, id: 0x07, payload: head)
        let parsed = try XCTUnwrap(FileHead(frame: frame))
        XCTAssertEqual(parsed.fileId, 42)

        let audio = [UInt8](repeating: 0x5C, count: 160)
        let seq: UInt32 = 7
        let iv = Array(nonce.prefix(12)) + [0, 0, 0, 70]
        let enc = try AESCTR.apply(key: fileKey, iv: iv, data: audio)
        let dec = try app.fileDecryptor(for: parsed).decrypt(seq: seq, data: enc)
        XCTAssertEqual(dec, audio)
    }

    func testSharedMismatchIsReported() {
        let app = SessionCrypto()
        let dev = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try app.complete(devicePublicKey: Array(dev.publicKey.x963Representation),
                                              deviceShared: [UInt8](repeating: 0, count: 32)))
    }

    /// 封装出来的 Ogg 要能被 ffmpeg 解析（不要求能解出声音，只检查容器）。
    func testOggCRCKnownValue() {
        // "OggS" 后跟全零的空页，CRC 用 Ogg 多项式算出的值固定
        XCTAssertEqual(OggOpus.crc32(Array("123456789".utf8)), 0x89A1_897F)
    }

    func testSoftAPEndpointAndWifiHex() throws {
        // IP 字节倒序：data[12].data[11].data[10].data[9]
        let f = rx(type: 0x1A, id: 0x05, payload: [0x01, 0x04, 0xA8, 0xC0, 0xBB, 0x01])
        let ep = try XCTUnwrap(SoftAPEndpoint(frame: f))
        XCTAssertEqual(ep.description, "192.168.4.1:443")
        XCTAssertEqual(Cmd.wifiFileRequestHex(id: 0x6A2F_C451), "08ee0000001a0712000000000051c42f6a1b")
        XCTAssertEqual(Cmd.openSoftAP(ssid: "ab", password: "c")[9...13].map { $0 }, [2, 0x61, 0x62, 1, 0x63])
    }

    /// 真机 watch 抓到的帧（固件 04.82）
    func testDeviceEventsFromRealFrames() {
        func ev(_ h: String) -> DeviceEvent? {
            var f = FrameAssembler()
            return f.feed(hex(h.replacingOccurrences(of: " ", with: ""))).first.flatMap { DeviceEvent(packet: $0) }
        }
        if case let .charging(r, c)? = ev("09 FF 00 00 01 01 04 0C 00 00 01 1B") { XCTAssertFalse(r); XCTAssertTrue(c) } else { XCTFail("充电") }
        if case let .recordingStarted(id)? = ev("09 FF 00 00 01 1A 06 13 00 26 76 F5 6A 00 00 00 00 00 37") {
            XCTAssertEqual(id, 0x6AF5_7626)
        } else { XCTFail("开始") }
        if case .recordingStopped? = ev("09 FF 00 00 01 18 82 14 00 00 01 05 00 00 00 00 00 00 00 BD") {} else { XCTFail("按键停止") }
        // 我们自己发「开始录音」的回包不算事件（随后会有 1A/06）
        XCTAssertNil(ev("09 FF 00 00 01 18 82 0C 00 01 9C 4C"))
    }

    func testOggPageLayout() {
        let ogg = OggOpus.mux(frames: [[0xFC, 1, 2], [0xFC, 3]])
        XCTAssertEqual(Array(ogg.prefix(4)), Array("OggS".utf8))
        XCTAssertEqual(ogg[5], 0x02) // BOS
    }
}

func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
