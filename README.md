# OpenBean

**Use your soundcore Work (D3200) recorder on your own Mac — locally, without the vendor app or any cloud.**

OpenBean is an open-source macOS app and local driver for the soundcore Work clip-on recorder. It talks to the
recorder over Bluetooth LE and Wi‑Fi, decrypts its recordings and transcribes everything on your Mac, offline.

[中文说明](README.zh-CN.md) · [Download](https://github.com/imraywang/openbean/releases/latest) · [User guide](docs/GUIDE.md) · [Protocol](docs/PROTOCOL.md)

> Tested on macOS 26/27, Apple silicon, recorder firmware 04.82. English and Simplified Chinese UI.

## What it does

| | |
|---|---|
| **Heart mode** | Wear the recorder all day. Put it back in its case and OpenBean syncs the day, transcribes it, splits it into conversations and writes that day's diary and to-dos |
| **Voice typing** | Press the recorder's button (or a keyboard shortcut) and speak; the text is typed at your cursor in any app. Works while the recorder is recording, too |
| **Recordings** | Automatic sync over Bluetooth (resumable) or Wi‑Fi, offline transcripts with click-to-seek, search, highlight marks, summaries, Markdown notes into a folder such as an Obsidian vault |
| **For agents** | A read-only MCP server lets your own agent (Claude Code, Claude Desktop, Cursor…) list, read and search your recordings |
| **Device layer** | A Swift library and a command-line tool: scan, device info, list, download, decrypt, live audio, button events |

OpenBean never binds or unbinds the recorder, factory-resets it or updates its firmware. It deletes a recording from
the recorder only when a complete, checked copy is on your Mac, and only when you ask, when Heart mode is set to clean
up after syncing, or for the file a voice-typing session created itself.

## Install

Requirements: macOS 26 or later, Apple silicon. About 250 MB for the speech models.

Download the signed and notarized `OpenBean-<version>.dmg` from
[Releases](https://github.com/imraywang/openbean/releases/latest), open it and drag OpenBean to Applications. A setup
assistant connects the recorder, downloads the speech models and asks for the permissions it needs: **Bluetooth**,
and **Accessibility** to type into other apps. OpenBean updates itself and asks before installing.

## Use

OpenBean lives in the menu bar. Click the bean to open the main window; right-click it for the menu.

- **Heart mode** — off until you finish a short introduction. When on, the page shows today: sync progress, the
  diary, to-dos and the day's conversations. Synced recordings are removed from the recorder and local audio is kept
  for 7 days by default; both are your choice, and transcripts are always kept.
- **Recordings** — the list and the selected recording side by side: play, click a sentence to jump there, search,
  summarise, export.
- **Voice typing** — everything you dictated, plus its settings: shortcut (default ⌥ Space), pauses, clean-up and the
  personal word list.
- **Recorder** — battery, storage, firmware, sync options, and *Start recording* for meetings and notes.
- **Settings** — library folder, notes, agents (MCP), speech models, updates.

Speech recognition always runs on your Mac (Apple on-device dictation for the live preview, SenseVoice-Small for the
final text). Summaries, the diary and voice-typing clean-up are optional and use an OpenAI-compatible LLM service you
choose — a local one such as llama.cpp, Ollama or LM Studio, or a cloud service. **With a cloud service, transcript
text is sent to it; audio never leaves your Mac.**

Details — notes and templates, the word list, the diary, automation links, the MCP tools — are in the
[user guide](docs/GUIDE.md).

## For agents (MCP)

`openbean-mcp` ships inside the app. *Settings → For agents (MCP)* shows its path and a ready-to-copy configuration:

```bash
claude mcp add --transport stdio --scope user openbean -- /Applications/OpenBean.app/Contents/Helpers/openbean-mcp
```

It is read-only, never goes online and runs only while an agent has started it. What it reads goes to the agent you
connect and the model behind it. Heart mode transcripts are hidden from agents unless you allow them.

## Build from source

Needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
Scripts/fetch-deps.sh          # sherpa-onnx + SenseVoice and VAD models (once)
Scripts/make-signing-cert.sh   # recommended: permissions survive rebuilds
bin/build-app && open ".build/OpenBean Dev.app"
```

This builds **OpenBean Dev**, a separate app with its own data and permissions; don't run it next to the released
app, both would connect to the recorder. The command-line tool, the Swift library, the demo build and the release
process are described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md); the wire protocol in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Known limits

- Voice typing misses about the first second after you press the button when the recorder has been idle.
- After voice typing during a recording, OpenBean reconnects Bluetooth (about 5 s) to stop the live stream.
- Bluetooth sync runs at roughly twice real time; for long recordings OpenBean offers Wi‑Fi, which takes your Mac
  offline for about a minute.
- No speaker separation yet.

## Third-party components

Downloaded by `Scripts/fetch-deps.sh`, not included in this repository:
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) and ONNX Runtime (MIT),
[SenseVoice-Small](https://github.com/FunAudioLLM/SenseVoice) ([FunASR model license](https://github.com/modelscope/FunASR?tab=readme-ov-file#license)),
[Silero VAD](https://github.com/snakers4/silero-vad) (MIT). Updates use [Sparkle](https://sparkle-project.org).

## Disclaimer

OpenBean is an independent project, not affiliated with, endorsed or sponsored by Anker Innovations. "soundcore" and
"Anker" are trademarks of their owners and are used only to say which hardware this works with. The protocol was
worked out for interoperability with hardware you own. A firmware update may break it at any time.

## License

[Apache-2.0](LICENSE)
