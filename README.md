# openbean

**Use your soundcore Work (D3200) recorder on your own computer — locally, without the vendor app or any cloud.**

openbean is an open-source local driver for the soundcore Work clip-on recorder. It talks to the device over Bluetooth LE
and Wi‑Fi, decrypts its recordings, and streams live audio to your Mac, so you can build your own things on top:
voice typing, meeting notes, a recording inbox for your notes app, home automation, agents.

> Status: **early**. The device layer and CLI work on macOS (tested with firmware 04.82).
> A voice-typing app and a local API are next. See [Roadmap](#roadmap).

[中文说明](#中文说明)

## What works today

| | |
|---|---|
| Discover and connect | No pairing in system settings needed |
| Device info | Battery, storage, firmware, recording state |
| Recordings | List; download over BLE (~2× real time) or Wi‑Fi (~200× real time); decrypt; save as Ogg Opus |
| Live audio | Start recording and receive decrypted audio in real time, 0.3–0.5 s end-to-end |
| Button events | The recorder's own button tells the host when recording starts and stops |

openbean never binds/unbinds the device, deletes recordings, factory-resets or updates firmware.

## Quick start (macOS 14+)

```bash
git clone <this repo> && cd openbean
bin/openbean scan          # find your recorder
bin/openbean list          # device info + recordings
bin/openbean pull latest   # download, decrypt and save the newest recording as .ogg
bin/openbean live 15       # record 15 s and stream it live
bin/openbean watch 60      # print events the device sends, e.g. when you press its button
```

`bin/openbean` builds the CLI and wraps it in a tiny `.app` the first time: macOS only grants Bluetooth access to apps,
so a bare command-line binary would be terminated. You will be asked to allow Bluetooth once.

`bin/openbean wifi <id>` uses the much faster Wi‑Fi path. It temporarily joins the recorder's own access point,
so **your Mac is offline for about a minute**; it reconnects to your usual network afterwards.

## Use it as a library

`OpenBeanKit` is a Swift package (macOS 14+, iOS 17+):

```swift
let link = Link()
try await link.waitPoweredOn()
let device = await link.scan(seconds: 6).first { $0.serviceMatch }!
try await link.connect(device.peripheral)

let session = D3200Session(link: link)
print(try await session.deviceInfo()!)
try await session.handshake()
for file in try await session.listFiles() { print(file.id, file.durationSeconds) }
```

The wire protocol is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md) so it can be ported to other languages and platforms.

## Roadmap

1. **Device layer** — this repo today. Protocol document good enough to reimplement from scratch.
2. **Voice typing** — menu bar app: press the recorder's button, speak, text appears at your cursor. Fully local:
   Apple on-device speech for live preview, SenseVoice for accurate sentence finals, an optional local LLM for clean-up.
   A working prototype exists and is being moved over.
3. **Local API** — a background service on `localhost` that publishes device state, live PCM audio, transcripts and
   recordings, so other tools (note apps, Home Assistant, agents via MCP) can use the recorder without touching Bluetooth.
4. **Recording sync** — offline recordings land in a folder automatically.

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

openbean 是录音豆的开源本地驱动：通过蓝牙和 Wi‑Fi 连接设备、解密录音、把实时音频送到 Mac。在它之上可以做语音输入、
会议纪要、笔记软件的录音收件箱、智能家居、AI 助手等。

目前能做的：扫描连接、读设备信息、列出和下载录音（蓝牙约 2 倍实时，Wi‑Fi 约 200 倍实时）、解密并保存为 Ogg Opus、
实时拉流（端到端 0.3–0.5 秒）、接收录音豆按键的开始/停止事件。不会做绑定/解绑、删除录音、恢复出厂和固件升级。

下一步是语音输入（按录音豆按键说话，文字实时打进光标处，全程本地离线），然后是本地服务 API 和录音自动同步。

openbean 是独立项目，与 Anker 无关。协议是为了让你使用自己的设备而整理的，固件升级随时可能让它失效。
