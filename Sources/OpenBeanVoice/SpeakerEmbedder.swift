// SPDX-License-Identifier: Apache-2.0

import CSherpaOnnx
import Foundation

/// 声纹向量：sherpa-onnx 的说话人向量提取（3D-Speaker CAM++ zh_en advanced，192 维）。
/// 输入 16 kHz 单声道 Float 采样，输出归一化（长度 1）的向量，两段声音的相似度就是向量点积（余弦）。
/// 不是线程安全的，调用方保证串行。
public final class SpeakerEmbedder {
    /// 模型在模型文件夹里的位置（Scripts/fetch-deps.sh 和 App 的模型下载放在这里）
    public static let modelPath = "speaker/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
    /// 写进声纹文件的模型名：换了模型，旧声纹就不能再用
    public static let modelName = "3dspeaker-campplus-zh_en-advanced"

    private let extractor: OpaquePointer
    public let dim: Int

    /// - Parameter modelsDir: 模型文件夹（含 `speaker/…onnx`）
    public init(modelsDir: URL, threads: Int32 = 1) throws {
        let path = modelsDir.appendingPathComponent(Self.modelPath).path
        guard FileManager.default.fileExists(atPath: path) else { throw VoiceError.missingModel(path) }
        let e: OpaquePointer? = path.withCString { model in
            "cpu".withCString { provider in
                var c = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                c.model = model
                c.num_threads = threads
                c.debug = 0
                c.provider = provider
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&c)
            }
        }
        guard let e else { throw VoiceError.initFailed("speaker embedding") }
        extractor = e
        dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(e))
    }

    deinit { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }

    /// 一段声音的声纹向量（归一化）；太短算不出来时返回 nil
    public func embed(_ samples: UnsafeBufferPointer<Float>) -> [Float]? {
        guard samples.count > 0, let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples.baseAddress, Int32(samples.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        return SpeakerMath.normalized(Array(UnsafeBufferPointer(start: v, count: dim)))
    }

    public func embed(_ samples: [Float]) -> [Float]? {
        samples.withUnsafeBufferPointer { embed($0) }
    }
}
