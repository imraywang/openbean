// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// iOS 版的播放：整个 App 一个（离开详情页、切到别的标签、锁屏都接着播），包着共用的 PlayerModel，
/// 加上倍速、前后跳 15 秒、锁屏和控制中心的播放控制（MPRemoteCommandCenter / MPNowPlayingInfoCenter）、
/// 来电等打断和拔耳机时暂停。后台继续播靠 Info.plist 的 audio 后台模式和 .playback 音频会话（PlayerModel.play 里设）。
///
/// 演示数据没有真的音频：假装在播，按倍速每 0.1 秒走一格（不出声），界面和锁屏信息照常
@MainActor @Observable
final class Playback {
    static let shared = Playback()
    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
    static let skip: Double = 15
    private static let rateKey = "playbackRate"

    let player = PlayerModel()
    /// 当前载入的录音
    private(set) var id: UInt32?
    private(set) var title = ""
    var rate: Float = Playback.storedRate {
        didSet {
            player.rate = rate
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            updateNowPlaying()
        }
    }

    var playing: Bool { player.playing }
    var time: Double { player.time }
    var duration: Double { player.duration }

    @ObservationIgnored private var fake = false
    @ObservationIgnored private var fakeTimer: Timer?
    @ObservationIgnored private var watch: Timer?
    @ObservationIgnored private var wasPlaying = false
    @ObservationIgnored private var commandsReady = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static var storedRate: Float {
        let r = UserDefaults.standard.float(forKey: rateKey)
        return rates.contains(r) ? r : 1
    }

    private init() { player.rate = rate }

    /// 这条录音有没有能播的本机音频（演示数据：有就算）
    static func hasAudio(_ r: Recording) -> Bool { r.downloaded && !r.audioRemoved }

    /// 打开详情页时：换成这条录音（已经是这条就不动，接着播）
    func open(_ r: Recording, library: LibraryStore) {
        guard id != r.id else { return }
        stop()
        id = r.id
        title = r.displayTitle
        let url = library.audioURL(r.id)
        if FileManager.default.fileExists(atPath: url.path) { player.load(url) }
        fake = false
        if player.duration == 0 {
            // 演示数据的音频是占位文件，读不出来
            player.demoDuration(r.duration)
            fake = Flavor.isFake
        }
        player.rate = rate
        setUpCommands()
        updateNowPlaying()
    }

    /// 改了标题：锁屏上也跟着改
    func retitle(_ r: Recording) {
        guard id == r.id else { return }
        title = r.displayTitle
        updateNowPlaying()
    }

    /// 录音被删了：正在播的是它就停下、清掉锁屏信息
    func forget(_ ids: Set<UInt32>) {
        guard let id, ids.contains(id) else { return }
        stop()
        self.id = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggle() { playing ? pause() : play(from: nil) }

    func play(from t: Double?) {
        if fake {
            if let t { player.time = clamp(t) }
            if player.time >= duration - 0.05 { player.time = 0 }
            player.demoPlaying(at: player.time)
            fakeTimer?.invalidate()
            fakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fakeTick() }
            }
        } else {
            player.play(from: t)
        }
        startWatch()
        updateNowPlaying()
    }

    func pause() {
        fakeTimer?.invalidate()
        player.pause()
        updateNowPlaying()
    }

    func seek(_ t: Double) {
        if fake { player.time = clamp(t) } else { player.seek(t) }
        updateNowPlaying()
    }

    func skip(by d: Double) { seek(time + d) }

    func stop() {
        fakeTimer?.invalidate()
        watch?.invalidate()
        player.stop()
    }

    private func clamp(_ t: Double) -> Double { min(max(t, 0), duration) }

    private func fakeTick() {
        guard player.playing else { fakeTimer?.invalidate(); return }
        let t = player.time + 0.1 * Double(rate)
        if t >= duration { player.time = duration; pause() } else { player.time = t }
    }

    /// 播到头自己停了：锁屏信息跟着改（PlayerModel 没有回调，每秒看一眼）
    private func startWatch() {
        wasPlaying = true
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.wasPlaying != self.playing { self.wasPlaying = self.playing; self.updateNowPlaying() }
                if !self.playing { self.watch?.invalidate() }
            }
        }
    }

    // MARK: 锁屏、控制中心

    private func updateNowPlaying() {
        guard id != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "OpenBean",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    private func setUpCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ act: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { e in
                MainActor.assumeIsolated { act(e) }
                return .success
            }
        }
        on(c.playCommand) { [weak self] _ in self?.play(from: nil) }
        on(c.pauseCommand) { [weak self] _ in self?.pause() }
        on(c.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skip)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skip)]
        on(c.skipForwardCommand) { [weak self] _ in self?.skip(by: Self.skip) }
        on(c.skipBackwardCommand) { [weak self] _ in self?.skip(by: -Self.skip) }
        on(c.changePlaybackPositionCommand) { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        on(c.changePlaybackRateCommand) { [weak self] e in
            if let e = e as? MPChangePlaybackRateCommandEvent { self?.rate = e.playbackRate }
        }
        // 来电、闹钟打断：暂停（系统已经停了引擎），不自动接着播；拔耳机：暂停
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let began = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began
            MainActor.assumeIsolated { if began { Playback.shared.pause() } }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let gone = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
            MainActor.assumeIsolated { if gone, Playback.shared.playing { Playback.shared.pause() } }
        })
    }
}
