# openbean

**Use your soundcore Work (D3200) recorder on your own computer — locally, without the vendor app or any cloud.**

openbean is an open-source local driver for the soundcore Work clip-on recorder. It talks to the device over Bluetooth LE
and Wi‑Fi, decrypts its recordings and streams live audio to your Mac. On top of that it ships **OpenBean**, a native
macOS app: press the button on the recorder, speak, and the text appears at your cursor; sync recordings and get
searchable transcripts — all transcribed on your Mac, offline.

> Status: **early**. Tested on macOS 26/27, Apple silicon, recorder firmware 04.82. English and Simplified Chinese UI.
> No signed release yet — build it yourself (below). See [Roadmap](#roadmap).

[中文说明](#中文说明)

## What works today

| | |
|---|---|
| **Voice typing** | The recorder's button (or a keyboard shortcut) starts and stops dictation; text is typed into any app |
| **Library** | Sync recordings, play them, offline transcripts with click-to-seek, search, export Markdown |
| Discover and connect | No pairing in system settings needed; reconnects automatically |
| Device info | Battery, storage, firmware, recording state |
| Recordings | List; download over BLE (~2× real time) or Wi‑Fi (~200× real time); decrypt; save as Ogg Opus |
| Live audio | Decrypted audio in real time, 0.3–0.5 s end-to-end |
| Button events | The recorder tells the host when its button starts and stops a recording |

openbean never binds/unbinds the device, deletes recordings, factory-resets or updates firmware.

## The OpenBean app

### How it works

```
recorder button ─► live audio over BLE ─► Opus decode
                                              │
                ┌─────────────────────────────┴────────────────────────────┐
                ▼                                                          ▼
   Apple on-device dictation                               Silero VAD splits sentences
   grey preview text, ~1 s behind                          SenseVoice-Small transcribes each one
                                                           (~0.1 s per sentence, punctuated)
                                                                           │
                                                   optional local LLM clean-up (any
                                                   OpenAI-compatible server, e.g. llama.cpp)
                                                                           │
                                                           typed at your cursor
```

Everything runs on your Mac. The LLM step is off by default; when on, it removes filler words, fixes likely
homophones using your personal word list, and keeps your own wording.

Measured with the recorder on a person, Chinese speech: each sentence is final ~0.1 s after SenseVoice gets it,
LLM clean-up adds 0.1–0.5 s with Qwen3-30B-A3B on an M5 Max.

### Requirements

- macOS 26 or later (Apple's on-device speech API), Apple silicon
- Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- ~250 MB for the speech models; optionally ~18 GB for a local LLM

### Build and run

```bash
Scripts/fetch-deps.sh          # sherpa-onnx library + SenseVoice and VAD models (once)
Scripts/make-signing-cert.sh   # optional but recommended, see below
bin/build-app                  # XcodeGen + xcodebuild → .build/OpenBean.app
open .build/OpenBean.app
```

A setup assistant walks you through connecting the recorder, downloading the speech models (~240 MB) and the
permissions. macOS asks for **Bluetooth**; to type into other apps OpenBean also needs
**System Settings → Privacy & Security → Accessibility** (shown as *Device Control and Data Access* on some versions).

To work on the app in Xcode: `cd App && xcodegen generate && open OpenBean.xcodeproj`.

**Why the signing certificate:** macOS remembers permissions per code signature. With ad-hoc signing every rebuild
looks like a new app and you have to grant Accessibility again. `make-signing-cert.sh` creates a self-signed
"openbean local signing" certificate in your login keychain; `bin/build-app` uses it automatically, so permissions
survive rebuilds. It is for local development only.

### Use

OpenBean lives in the menu bar. *Open OpenBean* (⌘O) shows the main window with three pages:

- **Library** — *Sync* downloads new recordings over Bluetooth (shortest first; it pauses while you dictate and
  resumes afterwards). Long recordings can use *Download over Wi‑Fi*, ~100× faster but your Mac is offline for about
  a minute. Downloads are transcribed automatically; click a sentence to play from there; search titles and
  transcripts; export Markdown or audio. Clips created by voice typing are hidden by default.
- **Recorder** — battery, storage, firmware; *Start recording* records on the recorder without voice typing
  (meetings, notes).
- **Settings** — what the recorder's button does (voice typing or record only), keyboard shortcut (default ⌥ Space),
  pause thresholds, LLM clean-up, models.

Voice typing:

1. Wait until the menu bar icon shows a microphone without a slash — the recorder is connected.
2. Put the cursor where you want to type.
3. **Press the recorder's button**, wait for the bar at the bottom of the screen to say it is listening, and speak.
   (The first ~1 s after pressing is not captured.)
4. Press the button again to finish. The keyboard shortcut and *Start voice typing* in the menu do the same.

Pauses decide punctuation and layout (all adjustable in Settings):

| Pause between phrases | Result |
|---|---|
| 0.8 s | Phrase is finalised by SenseVoice |
| up to +0.3 s more | joined with a comma |
| longer | full stop |
| over 2.5 s | full stop and a new paragraph (typed as Shift+Return, so chat apps don't send) |

### Optional: local LLM clean-up

Run any OpenAI-compatible server, for example llama.cpp:

```bash
llama-server -hf unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M --port 8092 -c 4096 -ngl 99
```

Then turn on *Clean up with local LLM* in the menu. The address and model name are in Settings (Ollama and LM Studio
work too). Smaller models such as Qwen3-4B are faster to download but worse at fixing homophones.

**Personal word list:** Settings → *Edit personal word list…* opens `~/Library/Application Support/openbean/glossary.txt`.
One term per line (names, product names, jargon). The clean-up step prefers these when a word sounds similar.

**Logs:** Settings → *Open log*, or `~/Library/Application Support/openbean/openbean.log` — every finalised sentence,
clean-up result and timing, plus connection events.

## Command-line tool (macOS 14+)

```bash
bin/openbean scan          # find your recorder
bin/openbean list          # device info + recordings
bin/openbean pull latest   # download, decrypt and save the newest recording as .ogg
bin/openbean live 15       # record 15 s and stream it live
bin/openbean watch 60      # print events the device sends, e.g. when you press its button
```

`bin/openbean` wraps the CLI in a tiny `.app`: macOS only grants Bluetooth access to apps.
`bin/openbean wifi <id>` uses the much faster Wi‑Fi path; it temporarily joins the recorder's own access point,
so **your Mac is offline for about a minute**, then reconnects to your usual network.

The CLI and the voice app both connect to the recorder; quit one before using the other.

## Use it as a library

`OpenBeanKit` (macOS 14+, iOS 17+) is the device layer; `OpenBeanVoice` (macOS 26+) is the speech pipeline.

```swift
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
```

The wire protocol is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md) so it can be ported to other languages and platforms.

## Roadmap

1. ✅ **Device layer** — protocol document good enough to reimplement from scratch.
2. ✅ **OpenBean app** — voice typing, recording library with offline transcripts, setup assistant (first version).
3. **Local API** — a background service on `localhost` that publishes device state, live PCM audio, transcripts and
   recordings, so other tools (note apps, Home Assistant, agents via MCP) can use the recorder without touching Bluetooth.
4. **Signed release** — notarised download so people don't have to build it.

Known gaps: the first ~1 s after pressing the button is lost; words recognised very wrongly cannot be rescued by the
clean-up step (recogniser-level hotwords would help); no signed/notarised release yet; code comments are in Chinese.

## Third-party components

Downloaded by `Scripts/fetch-deps.sh`, not included in this repository:

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) and ONNX Runtime (MIT)
- [SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice) — see the [FunASR model license](https://github.com/modelscope/FunASR?tab=readme-ov-file#license)
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT)

## Disclaimer

openbean is an independent project, not affiliated with, endorsed or sponsored by Anker Innovations.
"soundcore" and "Anker" are trademarks of their owners and are used only to say which hardware this works with.
The protocol was worked out for interoperability with hardware you own. Use it with your own device and your own
recordings. A firmware update may break it at any time.

## License

[Apache-2.0](LICENSE)

---

## 中文说明

**让 soundcore Work（D3200）录音豆脱离官方 App 和云端，在你自己的电脑上本地使用。**

openbean 是录音豆的开源本地驱动：通过蓝牙和 Wi‑Fi 连接设备、解密录音、把实时音频送到 Mac。自带原生 macOS App **OpenBean**：
按录音豆的按键说话，文字实时打进当前光标处；同步录音、得到可搜索的文字稿。全程在本机离线识别，界面支持中英文。

### 语音输入

- **识别**：Apple 设备端听写出灰字预览；每句停顿后由 SenseVoice-Small 定稿（每句约 0.1 秒，带标点）。
- **润色（可选）**：接任意 OpenAI 兼容的本地服务（如 llama.cpp 跑 Qwen3-30B-A3B），去口头禅、按个人词表纠正同音字，保留你的说法。
- **按停顿排版**：停 0.8 秒定稿一句；稍长用逗号，更长用句号，超过 2.5 秒换段（用 Shift+回车，聊天软件里不会误发送）。均可在设置里调。

**要求**：macOS 26 及以上，Apple 芯片，Xcode 26+ 和 XcodeGen（`brew install xcodegen`）。目前没有签名发布版，需要自己编译。

```bash
Scripts/fetch-deps.sh          # 下载 sherpa-onnx 和语音模型（一次）
Scripts/make-signing-cert.sh   # 建议：本机签名证书，重新打包后不用重新授权
bin/build-app && open .build/OpenBean.app
```

首次启动有设置向导：连接录音豆、下载语音模型（约 240 MB）、授予权限。打字进其他 App 需要在「系统设置 → 隐私与安全性 → 辅助功能」
（部分版本叫 Device Control and Data Access）里打开 OpenBean。

主窗口（菜单栏 →「打开 OpenBean」）有三页：**录音库**（蓝牙同步、长录音可走 Wi‑Fi 快速下载、自动转写、点句播放、搜索、导出 Markdown）、
**录音豆**（电量、存储、固件、只录音不听写）、**设置**（按键用途、快捷键默认 ⌥ Space、停顿阈值、润色、模型）。

语音输入：菜单栏麦克风图标不带斜杠表示已连接 → 光标放好 → 按录音豆按键（或快捷键），看到底部悬浮条显示「正在听」再说话
（按下后约 1 秒内的声音收不到）→ 再按一下结束。个人词表和日志在设置页。

### 其他

命令行工具 `bin/openbean` 可以扫描、读设备信息、下载并解密录音（蓝牙约 2 倍实时，Wi‑Fi 约 200 倍实时）、实时拉流、监听按键事件。
协议文档见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

openbean 不会做绑定/解绑、删除录音、恢复出厂和固件升级。

下一步：本地服务 API（让笔记软件、智能家居、AI 助手直接使用录音豆）和签名公证的发布版。

openbean 是独立项目，与 Anker 无关。协议是为了让你使用自己的设备而整理的，固件升级随时可能让它失效。
