# Developing OpenBean

## Build and run

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

**Why the signing certificate:** macOS remembers permissions per code signature. With ad-hoc signing every rebuild
looks like a new app and you have to grant Accessibility again. `make-signing-cert.sh` creates a self-signed
"openbean local signing" certificate in your login keychain; `bin/build-app` uses it automatically, so permissions
survive rebuilds. It is for local development only.

## Releases

Releases are built with `bin/release`: Developer ID signing with the hardened runtime (Sparkle's nested helpers
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

The wire protocol is documented in [docs/PROTOCOL.md](PROTOCOL.md) so it can be ported to other languages and platforms.
