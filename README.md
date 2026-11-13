# openbean

**Use your soundcore Work (D3200) recorder on your own computer — locally, without the vendor app or any cloud.**

openbean is an open-source local driver for the soundcore Work clip-on recorder. It talks to the device over Bluetooth LE
and Wi‑Fi, decrypts its recordings and streams live audio to your Mac. On top of that it ships **OpenBean**, a native
macOS app: press the button on the recorder, speak, and the text appears at your cursor; sync recordings and get
searchable transcripts — all transcribed on your Mac, offline.

> Status: **early**. Tested on macOS 26/27, Apple silicon, recorder firmware 04.82. English and Simplified Chinese UI.
> Signed, notarized builds are on the [Releases](https://github.com/imraywang/openbean/releases/latest) page. See [Roadmap](#roadmap).

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

openbean never binds/unbinds the device, factory-resets it or updates firmware. It deletes a recording from the recorder only when you ask and the recording is safely on your Mac, or — in the app, after voice typing — the file the app itself created for that dictation (can be turned off in Settings).

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
- To build it yourself: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- ~250 MB for the speech models; optionally ~18 GB for a local LLM

### Download

Get the signed and notarized `OpenBean-<version>.dmg` from
[Releases](https://github.com/imraywang/openbean/releases/latest), open it and drag OpenBean to Applications.
Apple silicon and macOS 26 or later only.

From 0.3.0 on OpenBean updates itself ([Sparkle](https://sparkle-project.org)): it checks once a day and asks before
installing. *Check for Updates…* is in the menu bar menu; the switch for automatic checks is in
Settings → Models → About. If you have 0.2.0, download the new version once by hand.

### Build and run

```bash
Scripts/fetch-deps.sh          # sherpa-onnx library + SenseVoice and VAD models (once)
Scripts/make-signing-cert.sh   # optional but recommended, see below
bin/build-app                  # XcodeGen + xcodebuild → ".build/OpenBean Dev.app"
open ".build/OpenBean Dev.app"
```

What you build is **OpenBean Dev**, a separate app from the released OpenBean: its own bundle identifier
(`dev.openbean.app.dev`), its own data in `~/Library/Application Support/openbean-dev`, its own permissions, a small
“D” next to the menu bar icon, and no automatic updates. Both can be installed on one Mac. It answers
`openbean-dev://` links and `openbean://` too. Don't run both at once: each would connect to the recorder and react
to its button. `OPENBEAN_FLAVOR=release bin/build-app` builds with the release identity instead.

A setup assistant walks you through connecting the recorder, downloading the speech models (~240 MB) and the
permissions. macOS asks for **Bluetooth**; to type into other apps OpenBean also needs
**System Settings → Privacy & Security → Accessibility** (shown as *Device Control and Data Access* on some versions).

To work on the app in Xcode: `cd App && xcodegen generate && open OpenBean.xcodeproj`.

**Demo build and UI screenshots.** `OPENBEAN_FLAVOR=demo bin/build-app` builds **OpenBean Demo**
(`dev.openbean.app.demo`, data in `~/Library/Application Support/openbean-demo`, only `openbean-demo://` links) with
the `DEMO` compile condition: a fixed set of made-up recordings, transcripts and summaries, and a fake recorder.
It never starts Bluetooth, loads speech models, calls an LLM or touches the keychain, so it can run next to your
everyday copy. Switch its state with links such as `openbean-demo://demo/state/syncing` or
`openbean-demo://demo/hud/listening` (the full list is at the top of `App/OpenBean/Demo.swift`).
`bin/ui-shots [folder]` builds it, steps through every page and state in light and dark, saves window screenshots
(default `.build/ui-shots`) and writes a contact sheet, `index.html`. It needs Screen Recording permission for the
terminal it runs in, and brings the demo windows to the front for a minute or two.
The same made-up data feeds the SwiftUI previews in `App/OpenBean/Previews.swift` (Debug builds only): open the
project in Xcode, open that file and pick a preview in the canvas. Previews keep their data in
`Application Support/openbean-preview` and never start Bluetooth, the shortcut or the updater.

**Releases** are built with `bin/release`: Developer ID signing with the hardened runtime (Sparkle's nested helpers
included), a DMG, notarization and stapling, then an EdDSA signature for Sparkle and a new item in `appcast.xml`
(`bin/release --no-notarize` skips notarization and writes the appcast only to `.build/release/`). It needs the
Developer ID certificate, a `notarytool` keychain profile and the Sparkle private key in the login keychain; the
script says what is missing. To ship a version:

1. In `App/project.yml` set `MARKETING_VERSION` and add 1 to `CURRENT_PROJECT_VERSION` (the build number Sparkle
   compares; the script refuses a build or version already in `appcast.xml`).
2. Write the release notes in Markdown: `docs/release-notes/<version>.en.md`, plus `<version>.zh-Hans.md` for
   Simplified Chinese if you like. They are embedded in `appcast.xml` (`<description sparkle:format="markdown"
   xml:lang="…">`, Sparkle 2.9+) and shown in the update window in the user's language, English otherwise. Without
   them the update window shows no notes.
3. Run `bin/release`. It updates `appcast.xml` at the repo root.
4. Run `bin/publish --dry-run` to see the checks and the steps, then `bin/publish`. It creates the GitHub release
   `v<version>` at the current commit (already pushed to `master`) with the DMG and its `.sha256`, waits until the
   public download URL answers, downloads the DMG and checks its SHA-256, size, notarization ticket and Sparkle
   signature, and only then commits `appcast.xml` and pushes `master` to `origin` and `private`. It stops at the
   first failure. Installed copies read the feed from `master`, so the feed must never go out before the DMG.

**Why the signing certificate:** macOS remembers permissions per code signature. With ad-hoc signing every rebuild
looks like a new app and you have to grant Accessibility again. `make-signing-cert.sh` creates a self-signed
"openbean local signing" certificate in your login keychain; `bin/build-app` uses it automatically, so permissions
survive rebuilds. It is for local development only.

### Use

OpenBean lives in the menu bar. *Open OpenBean* (⌘O) shows the main window. The sidebar has four pages
(⌘1–⌘4; ⌃⌘S hides the sidebar), and the recorder's status and sync progress sit at its bottom:

- **Overview** — the recorder (battery, storage, recordings not yet synced), totals for this week / month / all
  time (recordings, time recorded, characters typed by voice), the last 14 days and your recent recordings.
- **Library** — recording list and the selected recording side by side. *Sync* downloads new recordings over
  Bluetooth (shortest first; it pauses while you dictate and resumes afterwards). With *Sync new recordings
  automatically* (Settings → Library, on by default) this happens by itself when the recorder connects or goes back
  into its case — never while you are recording or dictating, and never over Wi‑Fi. Long recordings can use
  *Download over Wi‑Fi*, ~100× faster but your Mac is offline for about a minute. Downloads are transcribed
  automatically; click a sentence to play from there; search titles and transcripts; export Markdown or audio.
  Clips created by voice typing are hidden by default. *Summarise* (optional, see below) puts a title, summary,
  key points and action items above the transcript.
  To free space on the recorder, right-click a recording → *Delete from recorder…*. This only works once the
  recording is on your Mac and its audio checks out (it plays to the same length as on the recorder); the copy on
  your Mac is kept. Deletion cannot be undone. Under the *Dictation clips* filter, *Delete voice-typing files from
  recorder…* clears files left on the recorder by earlier voice typing; it shows how many there are and how long they
  run in total, and asks first.
- **Voice typing** — everything you dictated, with time, target app and length. Copy or delete entries, or clear
  the history.
- **Recorder** — battery, storage, firmware; *Start recording* records on the recorder without voice typing
  (meetings, notes).

**Settings** (⌘,) is the last item in the sidebar, in four groups — Voice typing, Clean-up, Library, Models: what
the recorder's button does (voice typing or record only), keyboard shortcut (default ⌥ Space), pause thresholds,
the clean-up service, voice typing history, summaries and notes, models. *Delete voice-typing audio from the recorder*
(Voice typing, on by default) deletes the file the recorder made for each dictation once it ends — only a file the app
started itself and can show is new; it cannot be recovered.

**Summaries and notes** (Settings → Library, both off by default):

- *Summarise recordings after transcription* — after a recording is transcribed, the LLM service from Clean-up
  writes a title (used when you haven't named the recording), a 2–4 sentence summary, key points and action items, in
  the language of the recording. If the service isn't running it is skipped quietly (see the log). Long recordings
  are summarised in parts that fit a 4k context, then merged. Voice typing clips are never summarised. *Summarise* /
  *Summarise again* in a recording's toolbar does it by hand.
- *Save a note for each recording to a folder* — pick a folder (for example inside an Obsidian vault) and OpenBean
  writes `<yyyy-MM-dd>-<title>.md` there after each transcription (and summary): YAML frontmatter (`title`,
  `created_at`, `duration`, `source: openbean`, `recording_id`, `tags: [recording]`), the summary, key points, action
  items, an `openbean://open/<id>` link and the transcript with `[mm:ss]` timestamps. Audio is not copied. If the name
  is taken the start time is added (`-HHmm`). Summarising again rewrites the same file — unless you have edited it
  since: then OpenBean leaves your edit alone and writes a new file next to it (*Export → Save note to folder* asks
  instead: replace or save as new). *Save notes for existing recordings* back-fills notes for transcribed recordings
  without re-summarising ones that already have a summary.
- *Edit note template…* opens `~/Library/Application Support/openbean/note-template.md` (delete it to go back to the
  default). Placeholders: `{{title}}`, `{{title_yaml}}` (quoted for YAML), `{{date}}`, `{{time}}`, `{{created_at}}`,
  `{{duration}}`, `{{recording_id}}`, `{{summary}}`, `{{key_points}}`, `{{action_items}}`, `{{link}}`,
  `{{transcript}}`; `{{#name}}…{{/name}}` keeps the text in between only when `name` isn't empty. Unknown
  placeholders are left as they are.

Voice typing:

1. Wait until the bean icon in the menu bar has no slash — the recorder is connected. (The bean turns solid while
   it listens and shows a small arrow while syncing.)
2. Put the cursor where you want to type.
3. **Press the recorder's button**, wait until the bar at the bottom of the screen changes from "Getting ready…" to
   a pulsing microphone, and speak.
   (The first ~1 s after pressing is not captured.)
4. Press the button again to finish. The keyboard shortcut and *Start voice typing* in the menu do the same.

Pauses decide punctuation and layout (all adjustable in Settings):

| Pause between phrases | Result |
|---|---|
| 0.8 s | Phrase is finalised by SenseVoice |
| up to +0.3 s more | joined with a comma |
| longer | full stop |
| over 2.5 s | full stop and a new paragraph (typed as Shift+Return, so chat apps don't send) |

### Optional: LLM clean-up

Run any OpenAI-compatible server, for example llama.cpp:

```bash
llama-server -hf unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M --port 8092 -c 4096 -ngl 99
```

Then turn on *Clean up with an LLM* in the menu. The address and model name are in Settings → Clean-up (Ollama and
LM Studio work too). Smaller models such as Qwen3-4B are faster to download but worse at fixing homophones.

A cloud service works the same way: put its base URL (with or without `/v1`, e.g. `https://api.deepseek.com`), its
model name (e.g. `deepseek-chat`) and an API key in Settings → Clean-up. The key is kept in your keychain. The text of
each sentence is then sent to that service; audio and speech recognition still stay on your Mac.

The same service writes recording summaries when *Summarise recordings after transcription* is on (Settings →
Library). Summaries send the whole transcript, in chunks of about 1,800 tokens, with a longer timeout (5 minutes per
request for a local server) and run in the background; a 4k context (`-c 4096`) is enough. With a cloud service the
transcript text leaves your Mac.

**Personal word list:** Settings → *Edit personal word list…* opens `~/Library/Application Support/openbean/glossary.txt`.
One term per line (names, product names, jargon). Every finalised sentence — voice typing and library transcripts —
is corrected against it without an LLM: Chinese characters that sound the same as a term (toneless pinyin, common
polyphones) are replaced, and English terms get their exact casing and spacing back (`open bean` → `OpenBean`). The
rules are conservative: single characters are never touched, two-character terms only replace one character and only
where it isn't part of another word, and text that already matches stays as it is. Replacements are logged. The
clean-up step, when on, also prefers these terms.

Some words are misheard as something that doesn't sound alike in Chinese — typically English terms inside Mandarin
(`Claude` → `cloud`, `session` → `筛选`). Declare those after an equals sign, separated by commas:

```
Claude Code = cloud code, 克劳德 code
Codex = codeex, code x
session = 筛选
```

Whenever one of the right-hand sides is recognised, the left-hand side is written. English aliases match whole words,
ignoring case, spaces and hyphens (`cloud code`, `cloudcode`, `Cloud-Code`); aliases containing Chinese characters must
match those characters exactly. Lines without `=` work as before, and only the left-hand terms are given to clean-up.
Pick aliases you never say on purpose: a bare `cloud` would turn every real "cloud" into "Claude".

**Automation:** `openbean://dictate/toggle` (also `dictate/start`, `dictate/stop`), `openbean://sync` and
`openbean://open` (or `openbean://open/<recording id>`), `openbean://summarize/<recording id>`, `openbean://notes/backfill`, `openbean://settings` (or `openbean://settings/<voice|polish|library|models>`) — for Shortcuts, Raycast or scripts (`open "openbean://dictate/toggle"`).

**Voice typing history:** what you dictate is kept only on this Mac, in
`~/Library/Application Support/openbean/dictation.json`, for the *Voice typing* page and the Overview totals.
Turn it off in Settings (*Keep voice typing history on this Mac*) or clear it on the *Voice typing* page.

**Logs:** Settings → *Open log*, or `~/Library/Application Support/openbean/openbean.log` — every finalised sentence,
clean-up result and timing, plus connection events.

**Battery log:** the log also records the recorder's battery (`battery event=…` lines: connect / disconnect, every 10%
bucket change of the recorder and the case, going into / out of the charging case, a heartbeat every 10 minutes while
connected, and the length of every voice-typing and record-only session). `python3 -I Scripts/battery-report.py`
turns them into time connected, time off the charger, voice-typing time, drain per hour of standby and per minute of
voice typing, and projected battery life (`--since` / `--until` pick a day; app quits, disconnects, Mac sleep and
charging are left out). The recorder only reports 10% steps, so wear it for a day before trusting the numbers.

## Command-line tool (macOS 14+)

```bash
bin/openbean scan          # find your recorder
bin/openbean list          # device info + recordings
bin/openbean pull latest   # download, decrypt and save the newest recording as .ogg
bin/openbean live 15       # record 15 s and stream it live
bin/openbean watch 60      # print events the device sends, e.g. when you press its button
bin/openbean delete <id> --yes   # delete one recording from the recorder (see below)
```

`delete` refuses unless the recording's audio is on this Mac (`Library/<id>/audio.ogg` of the app, `--dev` for the
OpenBean Dev build's library, or `--local <file.ogg>`)
and decodes to the length the recorder lists, and it re-reads the list afterwards to confirm. Without `--yes` it only
checks the local copy and sends nothing.

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

Done:

1. ✅ **Device layer** — protocol document good enough to reimplement from scratch.
2. ✅ **OpenBean app** — voice typing, recording library with offline transcripts, setup assistant.
3. ✅ **Signed release** — a notarised DMG on the [Releases](https://github.com/imraywang/openbean/releases) page,
   with automatic updates from 0.3.0.
4. ✅ **Recordings into your notes (0.3)** — new recordings sync on their own over Bluetooth, get transcribed and
   summarised (title, summary, key points, to-dos) by the LLM service you configured, and land as one Markdown note
   each in a folder you choose, for example inside an Obsidian vault. Recordings can be deleted from the recorder
   once a complete copy is on the Mac.

Next:

5. **For agents (0.4)** — a read-only MCP server (stdio) over the recording library on your Mac: list recordings by
   date, read transcripts and summaries, search. It does not touch Bluetooth and nothing runs in the background.
6. **Meetings** — telling speakers apart, and a meeting-minutes note template.
7. **Local API** — the rest of the picture: a service on `localhost` that publishes device state and live PCM audio,
   so other tools (note apps, Home Assistant) can use the recorder without touching Bluetooth.

Later, maybe: optional cloud speech recognition for recordings in the library (voice typing stays on-device);
sending notes to third-party services.

Not planned: gestures on the recorder's button. The button only reports start and stop
([protocol, section 12](docs/PROTOCOL.md)), so there is nothing to build on.

Known gaps:

- Ending voice typing or *Stop recording* now pauses and then stops the recorder (`18/82 00`), so the file is closed
  and the next session starts a new one; after voice typing the app then deletes that file (if the setting is on and
  every safety check passes). Verified on hardware as pause → stop (the recorder's blinking yellow light goes out within
  15 s); stopping without a pause is not tested yet. The typed text is not affected either way.
- Voice typing is ready about 0.35 s after the shortcut when you use it back to back, and about 1.1 s after a pause:
  the recorder itself takes about a second to open a new file when it has been idle. What you say in that time is lost.
- Voice typing started with the recorder's button (not the shortcut) leaves its file on the recorder; clear those
  with *Delete voice-typing files from recorder…* in the library.
- While the recorder is recording something voice typing did not start (record only, *Start recording*, or a
  recording made with the button before the Mac connected), the shortcut does not start voice typing: the bar says
  the recorder is recording. Stop that recording with the recorder's button first. OpenBean never pauses or stops a
  recording it did not start for voice typing.
- The word list only fixes other mis-hearings that you declare as aliases.
- Code comments are in Chinese.

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
- **个人词表**：每句定稿后先按个人词表纠正专有名词，不需要大模型：读音相同的错字换成词表里的词，英文恢复词表的大小写和空格（open bean → OpenBean）；单字不改，两字词只在不和别的字成词时才改。录音库转写也一样。
  读音不同的误听（多是中文里夹的英文词，如 Claude 被认成 cloud、session 被认成「筛选」）可以在等号后面声明，逗号分隔：`Claude Code = cloud code, 克劳德 code`，识别出右边任何一个都写成左边。英文别名不分大小写、空格和连字符可有可无、只按整词匹配；含汉字的别名要一字不差。没有等号的行照旧；润色只拿等号左边的词。别把自己真会说的词当别名（单写一个 cloud，所有真的 cloud 都会变成 Claude）。
- **润色（可选）**：接任意 OpenAI 兼容服务，本机的（如 llama.cpp 跑 Qwen3-30B-A3B）或云端的（DeepSeek、通义千问等，填 API Key，Key 存钥匙串），去口头禅、按个人词表纠正同音字，保留你的说法。用云端时每句话的文字会发给该服务，录音和语音识别仍在本机。
- **按停顿排版**：停 0.8 秒定稿一句；稍长用逗号，更长用句号，超过 2.5 秒换段（用 Shift+回车，聊天软件里不会误发送）。均可在设置里调。

**要求**：macOS 26 及以上，Apple 芯片。

**下载**：在 [Releases](https://github.com/imraywang/openbean/releases/latest) 下载已签名、已公证的 `OpenBean-<版本>.dmg`，打开后拖进「应用程序」。
0.3.0 起 App 会自动更新（Sparkle）：每天检查一次，装之前先问你；菜单栏菜单里有「检查更新…」，自动检查的开关在「设置 → 模型 → 关于」。装的是 0.2.0 的话，手动下载一次新版即可。

**自己编译**：需要 Xcode 26+ 和 XcodeGen（`brew install xcodegen`）。

```bash
Scripts/fetch-deps.sh          # 下载 sherpa-onnx 和语音模型（一次）
Scripts/make-signing-cert.sh   # 建议：本机签名证书，重新打包后不用重新授权
bin/build-app && open ".build/OpenBean Dev.app"
```

编出来的是 **OpenBean Dev**，和正式版是两个 App：应用标识、数据目录（`Application Support/openbean-dev`）、系统权限都分开，
菜单栏图标旁有个小 D，不自动更新，可以和正式版装在同一台机器上。两个不要同时开，否则都会连录音豆、都响应按键。

**演示版和界面截图**：`OPENBEAN_FLAVOR=demo bin/build-app` 编出 **OpenBean Demo**（`dev.openbean.app.demo`，数据在
`Application Support/openbean-demo`，只认 `openbean-demo://`），编译条件 `DEMO`：一套虚构的录音、转写和摘要，一个假的录音豆；
不开蓝牙、不加载语音模型、不调用大模型、不碰钥匙串，可以和日常用的那份同时运行。用 `openbean-demo://demo/state/syncing`、
`openbean-demo://demo/hud/listening` 这类链接切状态（完整列表在 `App/OpenBean/Demo.swift` 开头）。
`bin/ui-shots [目录]` 编译演示版，浅色、深色各把每个页面和状态截一遍（默认放 `.build/ui-shots`），并生成联系表 `index.html`。
运行它的终端需要「屏幕与系统录音」权限；截图的一两分钟里演示版窗口会弹到前台。
同一套假数据也用在 SwiftUI 预览里（`App/OpenBean/Previews.swift`，只在 Debug 构建里）：用 Xcode 打开工程、打开这个文件，在画布里选预览。
预览的数据放在 `Application Support/openbean-preview`，不开蓝牙、不注册快捷键、不检查更新。

首次启动有设置向导：连接录音豆、下载语音模型（约 240 MB）、授予权限。打字进其他 App 需要在「系统设置 → 隐私与安全性 → 辅助功能」
（部分版本叫 Device Control and Data Access）里打开 OpenBean。

主窗口（菜单栏 →「打开 OpenBean」）左侧是导航（⌘1–⌘4 切换，⌃⌘S 收起），底部显示录音豆状态和同步进度：
**概览**（设备电量、存储、未同步条数，本周 / 本月 / 全部的录音与语音输入统计，最近 14 天，最近录音）、
**录音库**（列表 + 详情；蓝牙同步、长录音可走 Wi‑Fi 快速下载、自动转写、点句播放、搜索、导出 Markdown）、
**语音输入**（每次说过的内容、时间、输入到哪个 App，可拷贝、删除、清空）、**录音豆**（电量、存储、固件、只录音不听写）。
**设置**在侧栏最下面（⌘,），分语音输入、润色、录音库、模型四组：按键用途、快捷键默认 ⌥ Space、停顿阈值、润色服务、语音输入记录、模型。

自动同步：设置 → 录音库 →「自动同步新录音」（默认打开）。录音豆连上、或放回充电盒时自动经蓝牙下载新录音；
正在录音或语音输入时不会开始，也从不自动走 Wi‑Fi。失败后会隔一段时间（1 分钟起、最多 30 分钟）再试。

从录音豆删除：在录音库里右键一条录音 →「从录音豆删除…」，用来腾出录音豆的空间。只有已经下载到本机、且本机音频解码出来的时长
和录音豆上一致的录音才能删；本机副本保留。删除不能恢复。录音库筛选「听写片段」下的「从录音豆删除语音输入文件…」
清理以前语音输入留在录音豆上的文件，会先列出条数和总时长再确认。

语音输入结束后，App 会从录音豆删掉这次语音输入新建的文件（设置 → 语音输入 →「从录音豆删除语音输入的音频」，默认打开）。
结束时 App 先暂停、再发「结束录音」让录音豆把文件收尾（这样下次会新建文件，不再续写），然后删掉它。只删 App 自己发开始命令、
能证明是新建的文件，删了不能恢复；不满足条件就留在录音豆上，打出的文字不受影响。设备页的「停止录音」同样是暂停再结束。
录音豆正在录一段不是语音输入开始的录音（只录音、设备页开始的、或 Mac 连上之前按键录的会议）时，快捷键不会开始语音输入，
悬浮条提示录音豆正在录音；请先按录音豆按键停止。App 不会暂停或结束不是它为语音输入开始的录音。

语音输入记录只保存在这台 Mac 上（`~/Library/Application Support/openbean/dictation.json`），用于「语音输入」页和概览统计；
可在设置里关闭（「在本机保存语音输入记录」），或在「语音输入」页清空。

**摘要和笔记**（设置 → 录音库，默认都关）：

- **转写后自动生成摘要**：用「润色」里设置的大模型服务，按录音的语言写标题（录音没起名时用它）、2–4 句摘要、要点和待办。
  服务没开就静默跳过（写日志）。长录音按 4k 上下文分块摘要再合并。语音输入片段不做摘要。录音详情工具栏的「摘要 / 重新摘要」可手动触发。
  用云端服务时整篇转写文字会发给该服务。
- **为每条录音在文件夹里保存一份笔记**：选一个文件夹（如 Obsidian 知识库里的），转写（和摘要）完成后写入 `<yyyy-MM-dd>-<标题>.md`：
  YAML frontmatter（`title`、`created_at`、`duration`、`source: openbean`、`recording_id`、`tags: [recording]`）、摘要、要点、待办、
  `openbean://open/<id>` 链接和带 `[mm:ss]` 时间戳的转写，不拷贝音频。重名时加上开始时间（`-HHmm`）。重新摘要会覆盖同一个文件；
  但如果你改过这份笔记，OpenBean 不动它，另写一份新文件（「导出 → 保存笔记到文件夹」会先问：替换还是另存）。
  「为已有录音补写笔记」给已转写的录音补写笔记，已有摘要的不重新摘要。
- **编辑笔记模板…** 打开 `~/Library/Application Support/openbean/note-template.md`（删掉即恢复默认）。占位符见上方英文说明，
  `{{#name}}…{{/name}}` 只在该值非空时保留中间内容，不认识的占位符原样保留。

语音输入：菜单栏的豆子图标不带斜杠表示已连接（正在听时变实心，同步时带小箭头）→ 光标放好 → 按录音豆按键（或快捷键），
等底部悬浮条从「准备中…」变成跳动的麦克风再说话
（按下后约 1 秒内的声音收不到）→ 再按一下结束。个人词表和日志在设置页。
日志里还记了录音豆电量和每次语音输入的时长，戴一天后运行 `python3 -I Scripts/battery-report.py` 可以算出待机和语音输入的耗电与预计续航。

### 其他

命令行工具 `bin/openbean` 可以扫描、读设备信息、下载并解密录音（蓝牙约 2 倍实时，Wi‑Fi 约 200 倍实时）、实时拉流、监听按键事件；
`delete <id> --yes` 删除录音豆上的一条录音（同样要先有完整的本机副本；默认找正式版 App 的录音库，`--dev` 找开发版的，`--local` 指定文件）。
协议文档见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

openbean 不会做绑定/解绑、恢复出厂和固件升级。删除录音豆上的录音只有两种情况：你明确要求、且录音已经完整保存在本机；
或者语音输入结束后，App 删掉它为这次语音输入新建的文件（可在设置里关闭）。

0.3 已完成「录音自动进知识库」：自动同步、转写、摘要、每条录音一份 Markdown 笔记。下一步（0.4）：区分说话人和会议纪要模板；本地服务 API（让笔记软件、智能家居、AI 助手直接使用录音豆）。以后可能做：可选的云端语音识别、同步到第三方服务。不做：按键手势（按键只有开始和停止两种事件）。

openbean 是独立项目，与 Anker 无关。协议是为了让你使用自己的设备而整理的，固件升级随时可能让它失效。
