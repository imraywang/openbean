// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Observation

/// 播放：AVAudioEngine + 按帧定位。
/// 不用 AVAudioPlayer：它对 Ogg Opus 设 `currentTime` 后报的时间是对的，实际播出的却是别处的声音
/// （实测：跳到 20、60 秒仍从头播，跳到 1200 秒播的是 1087 秒处）。AVAudioFile 按帧读是准的。
@MainActor @Observable
final class PlayerModel {
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var timer: Timer?
    /// 这次排进去的那段从第几秒开始；播放位置 = base + 节点已播的时长
    @ObservationIgnored private var base: Double = 0
    /// 每次重新排段加一：旧段的结束回调据此认出自己已经过期
    @ObservationIgnored private var generation = 0
    private(set) var playing = false
    private(set) var duration: Double = 0
    var time: Double = 0
    #if os(iOS)
    /// 倍速（iOS 版）：节点后面接一个变速不变调的单元。节点按源文件的帧计时，播放位置的算法不用改
    @ObservationIgnored private let pitch = AVAudioUnitTimePitch()
    var rate: Float = 1 { didSet { pitch.rate = rate } }
    #endif

    init() {
        engine.attach(node)
        #if os(iOS)
        engine.attach(pitch)
        #endif
    }

    func load(_ url: URL) {
        stop()
        file = try? AVAudioFile(forReading: url)
        time = 0
        guard let f = file else { duration = 0; return }
        duration = Double(f.length) / f.processingFormat.sampleRate
        #if os(iOS)
        engine.connect(node, to: pitch, format: f.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: f.processingFormat)
        #else
        engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
        #endif
    }

    #if DEMO || DEBUG || os(iOS)
    func demoDuration(_ d: Double) { if file == nil { duration = d } }
    /// 假装正在播放到 t 秒（没有音频，不会走动）
    func demoPlaying(at t: Double) { time = t; playing = true }
    #endif

    func toggle() { playing ? pause() : play(from: nil) }

    func play(from t: Double?) {
        guard file != nil else { return }
        var start = min(max(t ?? time, 0), duration)
        if t == nil, start >= duration - 0.05 { start = 0 } // 播完了再按播放：从头
        guard schedule(from: start) else { return }
        #if os(iOS)
        // iOS 要先声明是播放：不然静音键打开时没有声音；spokenAudio：别的 App 的语音提示来了会暂停而不是压低音量
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { engine.prepare(); guard (try? engine.start()) != nil else { return } }
        node.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        tick()
        generation += 1
        node.stop()
        playing = false
        timer?.invalidate()
    }

    func seek(_ t: Double) {
        let to = min(max(t, 0), duration)
        if playing { if schedule(from: to) { node.play() } } else { time = to }
    }

    func stop() {
        generation += 1
        node.stop()
        engine.stop()
        playing = false
        timer?.invalidate()
    }

    /// 从 start 秒起把文件剩下的部分排进节点（先清掉之前排的）
    private func schedule(from start: Double) -> Bool {
        guard let f = file else { return false }
        generation += 1
        let gen = generation
        node.stop()
        let sr = f.processingFormat.sampleRate
        let frame = min(AVAudioFramePosition(start * sr), f.length)
        base = Double(frame) / sr
        time = base
        let left = f.length - frame
        guard left > 0 else { return false }
        node.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(left), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.playing = false
                self.time = self.duration
                self.timer?.invalidate()
            }
        }
        return true
    }

    private func tick() {
        guard playing, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return }
        time = min(base + Double(pt.sampleTime) / pt.sampleRate, duration)
    }
}
