// SPDX-License-Identifier: Apache-2.0

import AVFoundation

/// 用系统自带的 Opus 解码（AudioToolbox），把设备的 160 字节帧解成 48 kHz 单声道 Float32。
public final class OpusDecoder {
    public let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let inFmt = AVAudioFormat(streamDescription: &asbd),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { throw LinkError.missing("系统 Opus 解码器") }
        inputFormat = inFmt
        outputFormat = outFmt
        converter = conv
    }

    /// 解一帧（会去掉尾部补齐的 0）。
    public func decode(_ frame: [UInt8]) throws -> AVAudioPCMBuffer {
        var packet = frame
        while packet.count > 1, packet.last == 0 { packet.removeLast() }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions![0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 960 * 2)!
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? LinkError.missing("Opus 解码") }
        return out
    }
}
