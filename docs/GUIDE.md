# OpenBean user guide

Reference for the parts of OpenBean that the [README](../README.md) only mentions.

## Voice typing

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

## LLM service (clean-up, summaries, diary)

Run any OpenAI-compatible server, for example llama.cpp:

```bash
llama-server -hf unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M --port 8092 -c 4096 -ngl 99
```

Then turn on *Clean up with an LLM* in Voice typing → settings → Clean-up. The address and model name are in Voice typing → settings → Clean-up (Ollama and
LM Studio work too). Smaller models such as Qwen3-4B are faster to download but worse at fixing homophones.

A cloud service works the same way: put its base URL (with or without `/v1`, e.g. `https://api.deepseek.com`), its
model name (e.g. `deepseek-chat`) and an API key in Voice typing → settings → Clean-up. The key is kept in your keychain. The text of
each sentence is then sent to that service; audio and speech recognition still stay on your Mac.

The same service writes recording summaries when *Summarise recordings after transcription* is on (Settings →
Library). Summaries send the whole transcript in chunks sized to the server's context length when OpenBean can read it
(llama.cpp's `/props`, or the context length in the server's model list), leaving room for the prompt and the reply,
and in chunks of about 1,800 tokens otherwise; requests have a longer timeout (5 minutes for a local server) and run
in the background. A 4k context (`-c 4096`) is enough; with 8k (`-c 8192`) long recordings need about half as many
requests. With a cloud service the
transcript text leaves your Mac.

## Personal word list

Settings → *Edit personal word list…* opens `~/Library/Application Support/openbean/glossary.txt`.
One term per line (names, product names, jargon). Every finalised sentence — voice typing and library transcripts —
is corrected against it without an LLM: Chinese characters that sound the same as a term (toneless pinyin, common
polyphones) are replaced, and English terms get their exact casing and spacing back (`open bean` → `OpenBean`). The
rules are conservative: single characters are never touched, two-character terms only replace one character and only
where it isn't part of another word, and text that already matches stays as it is. Library transcripts are long, so
there same-sound fixes apply only to terms of three or more characters with one character off; write two-character
names as aliases. Replacements are logged. The clean-up step, when on, also prefers these terms.

Transcripts keep the recognizer's original wording of every sentence the word list changed (`raw` in
`transcript.json`), so the list can be re-applied safely: when you save a changed word list (or start OpenBean after
changing it), every existing transcript is recomputed from the original in the background, and notes OpenBean wrote
and you haven't edited are refreshed. Removing a term restores the original wording. `openbean://glossary/apply`
re-applies it by hand. Voice typing history is not changed.

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

## Summaries and notes

- *Summarise recordings after transcription* — after a recording is transcribed, the LLM service from Clean-up
  writes a title (used when you haven't named the recording), a 2–4 sentence summary, key points and action items, in
  the language of the recording. If the service isn't running it is skipped quietly (see the log). Long recordings
  are summarised in parts sized to the server's context (4k when it can't be read), then merged. Voice typing clips are never summarised. *Summarise* /
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
  `{{transcript}}`, `{{segments}}` (the transcript with one heading per conversation, see below; the same as
  `{{transcript}}` for a recording with one conversation, and what the default template uses);
  `{{#name}}…{{/name}}` keeps the text in between only when `name` isn't empty. Unknown placeholders are left as
  they are.

## Conversations and the daily diary

**Conversations:** after transcription every recording is split into conversations at pauses of two minutes or more
(a conversation longer than 45 minutes is split again, into roughly equal parts at its longest pauses). A recording
with several conversations shows one section per conversation in its transcript and in its note, and on the Heart mode page each
conversation is listed on its own, on the day it started — so a recording left running past 4 AM shows up on both
days. This needs no LLM and is always on. The split is kept next to the recording as `segments.json`.

**Daily diary** (part of Heart mode): each conversation gets a short
summary — a heading, two or three sentences, what was decided, to-dos, the people and things mentioned — and each
day a diary built from them: an overview, decisions, to-dos and the people mentioned, every item pointing to the
conversation it came from. Items whose source can't be found are dropped; so are names that don't appear in the
transcript, pronouns and roles ("I", "the manager", "店长"), and an owner of a to-do unless a real name is given. The
same thing is never listed both as a decision and as a to-do. Lists are kept short (at most 3 decisions and 2 to-dos
per conversation, 5 and 6 per day; conversations of a few sentences get no to-dos), and people are listed as spelled,
never merged, the ones in most conversations first. A day with too little said gets no overview, only the list of
conversations. The diary appears at the top of the Heart mode page and, with a notes folder, as `<notes folder>/Diary/<yyyy-MM-dd>.md`
with headings in the app's language (the Chinese app uses `日记`), linking to each recording's note. The folder can be
any path relative to the notes folder, as long as it stays inside it or inside the folder one level up (`Diary`,
`../Journal`). Edited diary notes are left alone, as with recording notes.

It uses the same LLM service as summaries and makes **several more requests**: one per conversation (more for long
ones) and one or two per day. On our M5 Max with a local Qwen3-30B-A3B a day with a 99-minute meeting took about 25
requests and a minute; with a cloud service the conversation summaries are sent there. With the diary on, a
recording's own summary is put together from its conversation summaries instead of being written separately. Past
days are not rewritten unless something in them changes (a new recording, a new transcription, a changed word
list); the Heart mode page has *Write the diary for this day* for older days. If the service isn't running nothing half-done is
kept and it is tried again later. Data: `<library>/<recording id>/segments.json` and
`<library>/days/<yyyy-MM-dd>/day.json`.

## Automation, history and logs

**Automation:** `openbean://dictate/toggle` (also `dictate/start`, `dictate/stop`), `openbean://sync` and
`openbean://open` (or `openbean://open/<recording id>`), `openbean://summarize/<recording id>`, `openbean://notes/backfill`, `openbean://settings` (or `openbean://settings/<heart|voice|polish|recorder|library|agent|about>`) — for Shortcuts, Raycast or scripts (`open "openbean://dictate/toggle"`).

**Voice typing history:** what you dictate is kept only on this Mac, in
`~/Library/Application Support/openbean/dictation.json`, for the *Voice typing* page and the voice typing line on the Heart mode page.
Turn it off in Settings (*Keep voice typing history on this Mac*) or clear it on the *Voice typing* page.

**Logs:** Settings → *Open log*, or `~/Library/Application Support/openbean/openbean.log` — every finalised sentence,
clean-up result and timing, plus connection events.

**Battery log:** the log also records the recorder's battery (`battery event=…` lines: connect / disconnect, every 10%
bucket change of the recorder and the case, going into / out of the charging case, a heartbeat every 10 minutes while
connected, and the length of every voice-typing and record-only session). `python3 -I Scripts/battery-report.py`
turns them into time connected, time off the charger, voice-typing time, drain per hour of standby and per minute of
voice typing, and projected battery life (`--since` / `--until` pick a day; app quits, disconnects, Mac sleep and
charging are left out). The recorder only reports 10% steps, so wear it for a day before trusting the numbers.

## MCP tools

Claude Desktop (Settings → Developer → Edit Config, then quit and reopen it), Cursor (`~/.cursor/mcp.json`) and
other clients take the same `mcpServers` entry:

```json
{
  "mcpServers": {
    "openbean": { "command": "/Applications/OpenBean.app/Contents/Helpers/openbean-mcp", "args": [] }
  }
}
```

**Tools:**

| Tool | Arguments | Returns |
|---|---|---|
| `list_recordings` | `from`, `to` (local dates `YYYY-MM-DD`, or `today` / `yesterday`), `query`, `limit` (default 20) | Newest first: id, start time, duration, title, whether it has a transcript and a summary, a one-line gist |
| `get_recording` | `id` | Times, summary, key points, action items, path of its Markdown note, `openbean://open/<id>` link |
| `get_transcript` | `id`, `start_seconds`, `end_seconds`, `conversation`, `max_chars` (default 6000) | Timestamped sentences; a long transcript is cut and the result says where to continue. `conversation` reads one conversation of a long recording |
| `search_recordings` | `query`, `from`, `to`, `limit` (default 10) | Matching recordings with snippets and timestamps. Case-insensitive substring match, so it works for Chinese |
| `day_overview` | `date` (default today) | Every recording of that day with its summary and action items, the conversations of long recordings, and the day's diary first when there is one |

Each result is text for the model plus `structuredContent`; times carry the UTC offset, and every result names the
time zone and today's date. A day runs from 4 AM to 4 AM, as on the app's Heart mode page (Settings → "A day
starts at"; or set `OPENBEAN_DAY_START_HOUR`), so a recording made at 1:30 AM belongs to the day before. Recordings still only on the recorder are listed but have no transcript; voice typing
clips are left out.

**Privacy.** It is read-only: it can't change, delete or record anything, has no access to audio, the voice typing
history or the recorder, and never goes online. It runs only while an agent has started it. But what it reads —
transcripts and summaries — goes to the agent you connect and to the model behind it (often a cloud service), so
connect only agents you would trust with your recordings.

`--dev` reads the OpenBean Dev library (the copy inside OpenBean Dev.app does so by default); `--library <path>` or
`OPENBEAN_LIBRARY=<path>` reads any data folder, e.g. a test copy. From source:
`swift build -c release --product openbean-mcp`. It speaks MCP 2026-07-28 (stateless, `server/discover`) and the
`initialize` handshake of 2025-11-25 back to 2024-11-05.
