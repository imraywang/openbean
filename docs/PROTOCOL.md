# soundcore Work (D3200) — local protocol notes

This document describes how a host talks to the soundcore Work recorder (product code **D3200**) without the vendor app:
discovery, the control channel, encryption, live audio and file transfer.

Everything marked ✅ was exercised against real hardware with the `openbean` CLI. Items marked ⚠️ are known but untested;
most are deliberately not implemented. openbean is not affiliated with Anker; see the [README](../README.md#disclaimer).

**Tested firmware:** recorder `04.82`, charging case `1.2.1`, Wi‑Fi module `03.06` (November 2026).
A firmware update may change any of this.

## 1. Transports

| Transport | Used for | Status |
|---|---|---|
| BLE GATT | Control, live audio, slow file transfer (~15 KB/s) | ✅ |
| Wi‑Fi soft AP + WebSocket | Fast file transfer (~1.5 MB/s) | ✅ |
| Bluetooth Classic (SPP) | Alternative bulk transfer | not used |

No OS-level pairing is needed. The host connects directly over GATT.

## 2. Discovery ✅

The recorder advertises as `soundcore Work` with the 16-bit-style service UUID **`020CF5DA-0000-1000-8000-00805F9B34FB`**.

Manufacturer data (company ID included), e.g. `AA BB CC DD EE FF 91 00`

| Bytes | Meaning |
|---|---|
| 0–5 | Device MAC address |
| 6 | Flags: bit 7 = bound to an account; bits 4–6 = colour; bits 0–3 = channel |

The recorder keeps advertising while bound and still accepts connections from a new host.
On macOS the CoreBluetooth identifier for the device can change between sessions; reconnecting by identifier
sometimes times out, so fall back to scanning.

## 3. GATT layout ✅

| Service | Characteristic | Properties | Role |
|---|---|---|---|
| `020CF5DA-…` | `00007777-0000-1000-8000-00805F9B34FB` | write, write without response | Commands to the device |
| `020CF5DA-…` | `00008888-0000-1000-8000-00805F9B34FB` | read, notify | Responses and events |
| `66666666-6666-6666-6666-666666666666` | `77777777-…` | write, notify | Firmware update ⚠️ |
| `0x1804` | `0x2A07` | read | TX power |
| `87290102-3C51-43B1-A1A9-11B9DC38478B` | `6AA50001…6AA5000A` | read | Unknown |

Enable notifications on `…8888…`, then write commands to `…7777…`. On macOS the negotiated write size is 509 bytes,
which is larger than any command.

## 4. Framing ✅

### Host → device

```
08 EE 00 00 00 | type | id | length (u16 LE) | payload … | checksum
```

- `length` is the size of the whole frame, including the checksum byte.
- `checksum` is the sum of all preceding bytes, modulo 256.

Example — request device info: `08 EE 00 00 00 01 01 0A 00 02`

### Device → host

```
09 FF 00 00 | status | type | id | length (u16 LE) | payload … | checksum
```

Same length and checksum rules. The low nibble of `status` is `1` on success.
Notifications may split or merge frames; buffer the stream, search for `09 FF 00 00`, and cut frames by `length`.

All multi-byte integers are little-endian unless stated otherwise.

## 5. Commands

| type | id | Payload | Purpose | Status |
|---|---|---|---|---|
| `01` | `01` | — | Device info | ✅ |
| `01` | `A6` | unix time (u32) + UTC offset in hours (i8) | Set clock | ✅ |
| `18` | `82` | `01` start / `02` pause / `00` stop | Recording control | ✅ see §11 |
| `1A` | `11` | `01` | Stop BT transport (name from the vendor SDK) | ⚠️ see §11 |
| `1B` | `0E` | page (u16) | List recordings, 10 per page | ✅ |
| `1A` | `07` | offset (u32) + file id (u32) + realtime flag (u8) | Start a file transfer | ✅ |
| `1A` | `05` | ssid length + ssid + password length + password | Open Wi‑Fi soft AP | ✅ |
| `1A` | `02` | — | Close Wi‑Fi soft AP | ⚠️ see §10 |
| `2E` | `01` | host P-256 public key, 65 bytes uncompressed | Encryption handshake | ✅ |
| `0B` | `87` | `01` bind / `00` unbind | Account binding | ⚠️ not implemented |
| `01` | `B8` | — | Factory reset | ⚠️ not implemented |
| `1A` | `10` | file id (u32) | Delete a recording | ✅ see §12a |

## 6. Device info (`01/01` response) ✅

Fields start at byte 9 of the frame:

| Size | Field |
|---|---|
| 1 | connection status |
| 1 | recorder battery — bucket `0…9`, shown as `(n + 1) × 10 %` |
| 1 | recorder charging (`1` = yes) |
| 5 | recorder firmware, ASCII (e.g. `04.82`) |
| 16 | serial number, ASCII |
| 4 | total storage, KB |
| 4 | free storage, KB |
| 1 | case charging |
| 5 | case firmware, ASCII |
| 1 | case battery bucket |
| 6 | case MAC (all-equal bytes mean "unknown") |
| 5 | colour, auto power-off switch and level, two indicator lights |
| 1 | currently recording (`1` = yes) |
| 5 | Wi‑Fi firmware, ASCII |

The device also pushes `01/03` (battery: recorder, case) and `01/04` (charging: recorder, case) on its own.

## 7. Recording list (`1B/0E` response) ✅

Payload: `count (u16)` then `count` entries of 12 bytes, then 8 trailing bytes.

| Size | Field |
|---|---|
| 4 | file id — also the recording's start time as unix seconds |
| 4 | end time, unix seconds |
| 4 | **duration in milliseconds** |

> The third field is sometimes described as a byte size. Measurements say otherwise: an entry with value `1060`
> transferred as exactly 53 audio frames × 20 ms, and another entry's value `5920820` matches its
> `end − start` of 5921 s.

A page with fewer than 10 entries is the last one.

## 8. Encryption ✅

Recordings are encrypted per file. The host needs a session key first.

**Handshake.** Generate a P-256 key pair and send the 65-byte uncompressed public key (`04 ‖ X ‖ Y`) with `2E/01`.
The response (107 bytes) carries:

| Offset | Size | Field |
|---|---|---|
| 9 | 65 | device public key, uncompressed |
| 74 | 32 | the shared secret as computed by the device |

Compute ECDH yourself (the X coordinate, 32 bytes) and compare it with the device's copy. Then:

```
session_key = HKDF-SHA256(ikm = shared, salt = 01 02 03, info = 01 02 03, length = 32)
```

**File head.** Every transfer starts with a `1A/07` frame from the device (97 bytes):

| Offset | Size | Field |
|---|---|---|
| 9 | 4 | file id |
| 13 | 4 | transfer size in bytes (166 per audio frame; `FFFFFFFF` for a live recording) |
| 17 | 16 | file nonce |
| 33 | 46 | wrapped file key |
| 79 | 16 | session nonce |
| 95 | 1 | error code (`0` = OK) |

Unwrap the file key with **AES-256-CTR** (`key = session_key`, `IV = session nonce`). The plaintext is the ASCII string
`soundcored3200` (14 bytes) followed by the 32-byte file key. If the prefix does not match, the session key is wrong.

**Audio slices.** `1A/08` (and `1A/12`) frames carry units of 166 bytes starting at byte 9:

```
sequence (u32) | flags (u8) | 160 bytes of ciphertext | 1 byte padding
```

Decrypt each 160-byte block with AES-256-CTR, `key = file key`, and

```
IV = file_nonce[0..12) ‖ big-endian u32(sequence × 10)
```

(160 bytes is exactly 10 AES blocks.) In all CTR operations here the whole 16-byte counter increments as one
big-endian integer.

## 9. Audio format ✅

Decrypted audio is a plain concatenation of **Opus** packets: 48 kHz, mono, 20 ms per packet, each zero-padded to
160 bytes (about 64 kbit/s). The TOC byte is `0xBC` (CELT, full band, 20 ms). Strip trailing zero bytes before handing a
packet to a decoder. Wrap the packets in an Ogg container to play them; Apple's AudioToolbox and libopus both decode them.

## 10. File transfer

### Over BLE ✅

Send `1A/07` with `offset = 0`, the file id and `realtime = 0`. The device answers with the file head, then a stream of
slices, then `1A/0A` when done. Measured throughput on macOS: ~15 KB/s of audio, about 1.9× real time.

### Over Wi‑Fi ✅

1. Pick an SSID and an 8+ character password; send them with `1A/05`.
2. The `1A/05` response carries the address: bytes 9–12 are the IPv4 address **in reverse order** (`01 2B A8 C0` = `192.168.43.1`),
   bytes 13–14 the port (observed: 443).
3. Wait about 10 s, then join that network. **The BLE link drops** once the access point is up.
4. Open `wss://<ip>:<port>` (self-signed certificate). Send UDP `soundcore-keep-alive-unicast` to port **32003** every 2 s.
5. Request a file by sending a WebSocket **text** message containing this 18-byte frame as hex (no checksum, final byte `1B`):
   `08 EE 00 00 00 1A 07 12 00 | offset (u32) | file id (u32) | 1B`
6. The device replies with **binary** messages containing ordinary `09 FF` frames: file head, slices, done.
7. Finish with text `FINISH`, then the hex of `1A/0A` with payload `01`.

Measured: a 1 h 57 min recording transferred in 36 s (~1.5 MB/s). Because BLE is gone at step 3, the `1A/02` "close AP"
command cannot be sent afterwards without reconnecting; whether the access point shuts itself down is untested.

## 11. Live audio ✅

1. Send `18/82` with `01` to start recording. The device acknowledges with `18/82`.
2. About 0.8 s later it sends `1A/06`; bytes 9–12 are the new file id.
3. Send `1A/07` with that file id and `realtime = 1`. A file head (size `FFFFFFFF`) and then slices follow in real time.
4. Send `18/82` with `02` to pause. No `1A/0A` was observed afterwards.
5. Send `18/82` with `00` to stop. This closes the file.

**Pause is not stop.** After `02` the file stays open: the recorder's yellow light keeps blinking (paused), the next `01`
continues the same file without a `1A/06` notice, and `1A/10` on that file replies success but the file stays in the list.
Disconnecting Bluetooth also makes the recorder close the file.

Stop, verified on hardware on 2026-11-13 (firmware `04.82`), sent after a pause:

```
host → 08 EE 00 00 00 18 82 0B 00 00 9B
dev  → 09 FF 00 00 01 18 82 0C 00 00 9B 4A                     (18/82, status 01)
dev  → 09 FF 00 00 01 1A 0A 13 00 00 30 1B 00 00 EE C2 F6 6A 9B  (1A/0A, file id at payload bytes 5–8)
```

After this, `1A/10` deleted the file in the same connection (40 → 39 files), and the yellow light stopped blinking within
15 s. The first five bytes of the `1A/0A` payload have not been decoded. Not yet tested: sending `00` while recording
without pausing first.

`1A/11` with `01` (sent after a pause) was also tried: the device replied `1A/11` with status `01`, but the file still could
not be deleted afterwards. openbean does not use it.

Measured end-to-end latency (sound in the room → decrypted audio on the host) is **0.3–0.5 s**. The live stream starts at
the current position, so the first ~0.7 s after the start command is only available by downloading the file later.

## 12. Events from the device ✅

With nothing but notifications enabled, the host receives:

| Frame | When |
|---|---|
| `01/04`, payload `recorder, case` charging flags | Recorder taken out of / put into the case |
| `1A/06`, file id at bytes 9–12 | Recording started, including by pressing the button on the recorder |
| `18/82`, 10-byte payload starting with `00` | Recording stopped by the button |

Both `01/04` directions (taken out, put back) were seen on hardware. On 2026-11-13 a recorder put back into its case
after an 11 s record-only recording sent `01/04` about 5 s later; the app's automatic sync started about 4 s after that
and downloaded the recording.

The button therefore works as a start/stop trigger for the host. A button stop closes the file by itself; only a pause sent
by the host leaves it open (§11). The reply to the host's own stop (`18/82 00`) also starts with `00`, so openbean reads it
as a "stopped" event too; that is harmless.

Indicator light: a blinking yellow light means a recording is paused (file still open); it stops within 15 s of a stop
(`18/82 00`).

## 12a. Deleting a recording ✅

Verified on hardware on 2026-11-13 (recorder firmware `04.82`). Deletion cannot be undone. The request frame comes from the
community notes (see Acknowledgements).

Request — the file id is encoded exactly as in `1A/07`, little-endian:

```
08 EE 00 00 00 | 1A 10 | 0E 00 | file id (u32 LE) | checksum
```

Example for file id `0x6AF57626`: `08 EE 00 00 00 1A 10 0E 00 26 76 F5 6A 29`.

Reply: a `1A/10` frame from the device; the low nibble of `status` is `1` on success. In the hardware test (a 37.73 s
recording) the success reply arrived within about 2 s and the next file listing was one entry shorter; the copy on the Mac
was not touched. The rest of the reply payload has not been recorded. openbean wraps the command in safety checks (`D3200Session.deleteFile`):

1. Read device info; refuse if the recorder is recording or the recording flag is missing.
2. List the files, find the id, and let the caller compare it with the copy on the Mac: the local Ogg file must exist and
   decode to the listed duration within 1 s or 1 %, whichever is larger.
3. Send `1A/10` and wait for the `1A/10` reply (10 s timeout).
4. List the files again: the id must be gone and every other recording must still be there.

Step 2 differs in two places, both in the app only:

- **After voice typing.** When the app ended the dictation, it pauses and then stops the recording (§11), waits for `1A/0A`
  (up to 3 s), then deletes the file it used, without a local copy — but only if the app sent the start command, the
  recorder was not recording before, a `1A/06` notice named this file, and its listed duration is at most the session
  length plus 5 s (`DictationDeletePolicy`). A guessed or continued file is kept. A paused file cannot be deleted
  (see §11), so the stop must come first.
- **Old voice-typing files.** Files from earlier dictations cannot be proven new, so the app deletes them only from a
  manual clean-up that shows their count and total length and asks for confirmation.

## 13. Not covered

Binding, factory reset and firmware updates exist in the protocol but are risky and are left to the vendor app.
The remaining GATT services in §3 and the Bluetooth Classic path are undocumented here.

## Acknowledgements

The community notes in [tacshi/Soundcore](https://github.com/tacshi/Soundcore) were the starting point for this work.
This document is an independent write-up: every ✅ item was re-checked on hardware, and several details were corrected
(for example §7).
