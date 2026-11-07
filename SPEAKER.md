# SPEAKER.md — the output switcher, wire by wire

The full story of speaker playback: every component, what every button actually fires, how state
flows back, and the edge cases — covered and known-open. Companion to [FORK-NOTES.md](FORK-NOTES.md);
this file is the one to read before touching anything under `Screens/BookPlayer/Karaoke/Speaker*`
or debugging "playback is on the wrong device / both devices."

## Topology

```
 phone surfaces                    ownership              wire                     the room
┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────┐   ┌──────────────────────┐
│ BookPlayerControls   │   │ SpeakerSessionManager│   │ abs-session  │   │ WiiM (UPnP)          │
│ pill → chooser       │──▶│  .current            │──▶│ daemon :8788 │──▶│ Home Assistant (MQTT)│
│ ellipsis menu        │   │  two predicates      │   │ HTTP + WS    │   │ ABS server (session +│
│ KaraokeSheet bars    │   │ SpeakerSessionModel  │◀──│ /events      │   │  progress sync)      │
│ SpeakerProgressStrip │   │  transport + monitor │   └──────────────┘   └──────────────────────┘
│ ChapterPicker routing│   └──────────────────────┘
└──────────────────────┘
Local playback (PlayerManager / BookPlayerModel / AudioPlayer) is SPEAKER-BLIND by architecture:
no local playback code knows the speaker exists. All routing is view-layer, through the manager.
```

## The daemon contract (everything the phone can say and hear)

The full contract, including discovery, is [docs/COMPANION-API.md](docs/COMPANION-API.md). All of this
exists only when the server's `/capabilities` lists `speaker`; otherwise the app offers none of it.

One state shape everywhere: `RemotePlaybackState` is the body of `GET /status`, of **every**
transport POST's response, and of every WS `/events` frame. Idle states carry nulls and no
`item_id`.

| Endpoint | Semantics | The catch |
|---|---|---|
| `POST /play {item_id, position?}` | Start **or take over** the speaker with this book at position. Replaces a foreign session silently. | Omitting `position` resumes daemon-stored position *with its configured rewind*. |
| `POST /pause`, `POST /resume`, `POST /toggle` | What they say, against the current session. | `toggle` with no session is a 4xx — the model's `togglePlayback()` turns idle into `play`. **Measured 2026-08-05: a bare `/resume` does NOT resume the paused session's position — it re-reads ABS progress** (a session paused at 29856 resumed at 36738 because ABS held newer progress from phone listening). Any resume issued outside this app (HA buttons) can therefore jump to wherever the *other* device last synced. The app never sends bare resumes — every in-app resume path is `/toggle` on a live session or an explicit-position `/seek`/`/play` — so this bites external controls only. |
| `POST /seek {position\|delta}` | Reposition. | **A seek STARTS PLAYBACK, even from paused.** This is the single most load-bearing quirk in the system: it's what makes "Play on Speaker" one call, and what makes any scrub/chapter-jump against a *paused* session start the living room. 409 when idle → callers escalate to `/play`. |
| `POST /stop` | End the session with a final ABS progress sync. | Position survives on ABS; the session is gone (WS goes idle). |
| `POST /volume {level}` | Device volume 0–100. | `volume` only appears in states when the daemon polled the device. |
| `WS /events` | Full state on connect, on every change, and a 1 s position tick **while playing**. | Silence while paused — no heartbeat. Reconnect backoff is a flat 2 s. |

The daemon owns the ABS play session and pushes progress to the ABS server **on its own cadence**
(roughly the sync interval + on pause/stop). That lag is invisible when positions travel with
switch commands and poisonous when anything reads *saved* progress — see "Three copies of the
truth" below.

## Ownership: manager, model, predicates

- **`SpeakerSessionModel`** — one per (session, book). Holds the last daemon state (`remote`),
  extrapolates `currentPosition` between ticks from wall-clock while `advancing`, runs the WS
  monitor, and exposes the transport verbs. Every verb goes through `run()`: apply the HTTP
  response as a state, set `actionFailed` on error (and toast when no sheet is attached to show
  the inline error).
- **`SpeakerSessionManager.current`** — at most one tracked session ("one speaker, one session").
  Set by `session(for:)` (get-or-create; reuse ignores `startPosition`/`autoStart` — that's what
  makes "return to speaker" not a rewind) and by `discoverExistingSession()` (the HA flow: a
  one-shot `/status`, adopt if the daemon is mid-book, never autoplay). Ownership transitions ride
  `onOwnSessionChanged`, fired from `apply()` on every `hasOwnSession` flip *from any source* —
  our stop, an HA stop, another book claiming the speaker. Losing ownership immediately
  re-triggers discovery (the end of one session is often the start of another).
- **Two predicates, deliberately different:**
  - `speakerSession(for:)` (loose) — "a session exists for this book." Drives the pill and the
    chooser: a paused speaker is still a destination worth showing.
  - `activeSession(for:)` (strict) — "the speaker should drive transports." Live local playback
    always wins; when **both** outputs are paused with the book loaded locally, whichever output
    played **most recently** wins (lazy `Date` stamps refreshed by the predicate's own callers —
    no observer machinery). Fresh launch, no stamps → the phone in hand wins. Every transport,
    scrubber, chapter display, and transcript playhead routes through this one predicate; if a
    surface reads `session.hasOwnSession` directly to pick a transport, that's a bug (it was the
    "Paused on speaker over live local audio" bug).

## What fires when you press things

| Surface / control | Condition | Exact effect | Wire |
|---|---|---|---|
| **Player transport** play/pause/skips/chapter jumps (`BookPlayerControls`) | `activeSession != nil` | Routes to the session: `togglePlayback()` / `skip(±N)` / `speakerChapterJump` (position math over the speaker playhead) | `/toggle`, `/seek {delta}`, `/seek {position}` |
| same | `activeSession == nil` | Stock local behavior; speaker never contacted | — |
| **Pill** (player, loose predicate) | session exists | Opens the **output chooser** — never navigates, never touches playback | — |
| **Chooser: Play on Speaker** | local playing | `transferToSpeaker`: read live local position → `onPauseTapped()` → `session.seek(to:)` (seek-plays) | `/seek {position}` (or `/play` if idle) |
| **Chooser: Continue on iPhone** | local not playing | `session.continueOnPhone()`: `/pause` **must succeed first** (`actionFailed` aborts the handoff — no double audio by construction), then the creation-site callback seeks local + plays | `/pause`, then local |
| **Chooser: Resume on Speaker** | both paused | `togglePlayback()` → resumes at the speaker's own position | `/toggle` |
| **Chooser: Stop Speaker** | always | `stopSpeaker()`; the idle state that comes back fires the ownership transition (same path an HA stop takes) | `/stop` |
| **Ellipsis menu: "Play on Speaker"** | no session | Get-or-create session (`autoStart: false`) → `activate()` (monitor) → `seek(to: live local position)`; pauses local first. No navigation. | `/seek` → `/play` on 409 |
| **Ellipsis menu: "Playing/Paused on Speaker…"** | session exists | Same chooser as the pill | — |
| **Transcript `outputBar`** (shown when `activeSession == nil`) | — | "Pause"/"Play on iPhone" = local toggle (loads the book if needed); "Play on Speaker" = `PlayerManager.pause()` + `session.seek(to: transcript playhead)` | local; `/seek` |
| **Transcript `speakerBar`** (shown when `activeSession != nil`) | — | toggle → `/toggle`; ±30 → `/seek {delta}`; volume slider commit → `/volume`; mini-menu = Continue on iPhone / Stop Speaker | as listed |
| **Transcript line / chapter-header tap** | speaker active | `model.seek(to:)` → routed `onSeek` → `session.seek(to:)` — **starts a paused session playing** (reference-player semantics: tapping text means "play from here") | `/seek` |
| **Scrubber** (`SpeakerProgressStrip`, 500 ms ticker) | speaker active | Drag-end → `session.seek(to:)` — **also starts a paused session** (see warnings) | `/seek` |
| **Chapter picker sheet** | speaker active | Same guarded index-based routing | `/seek` |
| **Lock screen / Control Center / AirPods / CarPlay** | any | **Always local.** `MPRemoteCommandCenter` handlers live in `PlayerManager` (speaker-blind, upstream rule). See the double-audio guard below. | — |
| **Home Assistant / anything else** | any | Commands the same daemon; changes arrive here as WS frames within ~1 s | WS |

## Three copies of the truth (positions)

1. **Local `MediaProgress`** — ticks live during local playback; what local playback starts from.
2. **ABS server** — pushed by whichever side is playing, *on a lagging cadence*; pulled by
   `syncFromAPI` on home refresh/foreground with **newer-timestamp-wins**.
3. **The daemon's session** — live truth while the speaker plays (WS ticks + extrapolation).

Rules that keep them from fighting:
- **Positions always travel WITH switch commands** — no switch path reads saved progress, so no
  switch waits on a network push/pull. (Phone→speaker: live local read → explicit seek.
  Speaker→phone: live WS tick → explicit local seek.)
- **Every speaker playing→stopped transition folds the live position into local `MediaProgress`**
  (freshly timestamped, in `apply()`), because the daemon's ABS copy is newest-but-late and
  newer-wins can't reject it. This is what killed the ~30 s jumps on plain local plays (lock
  screen, big play button) after a speaker session. Skipped while the phone is mid-playback of
  the same book (the live player owns its position).

## Edge cases — covered

| Case | Guard |
|---|---|
| Both devices audibly playing the same book | `apply()` pauses **local** whenever a state says the speaker is playing while local plays. Rationale: every deliberate in-app local start pauses/transfers the speaker first, so both-playing means an out-of-band local start (AirPods, lock screen) or an external resume — either way the room wins. Heals within one 1 s tick in foreground; on unlock via the reconnect snapshot. |
| "Switch to speaker" while phone plays | Transfer, not resume: pause local, seek speaker to the phone's position. ("Resume on Speaker" appearing here was the double-audio bug of 2026-07-31.) |
| Handoff to phone with the daemon unreachable | `continueOnPhone` aborts unless `/pause` succeeded; error surfaces inline (sheets) or as a toast. |
| Stale paused session hijacking the phone | Strict predicate: local playing → local wins; both-paused → most-recently-playing wins; no stamps → phone wins. |
| External stop (HA) while a sheet is open | Ownership transition clears tracking; the sheet keeps a live monitor to offer restart; dismissal reaps the orphan. |
| Session ends, another begins externally | Ownership loss triggers immediate re-discovery (not just next foreground). |
| App backgrounded | Monitor suspended (sockets die in suspension anyway); `appDidBecomeActive` reconnects, and the connect snapshot re-syncs everything including ends we slept through. |
| Same-book re-open ("Return to Speaker") | `session(for:)` reuse ignores seed position — never a rewind. |
| Foreign session (speaker playing another book) | Sheets show an explicit "replaces it" warning; `seek`/`play` replace by design (Connect semantics). |
| Reused sheet dismissal | `attachedSheets` counting; live sessions outlive their sheets, dead ones are reaped. |

## Edge cases — KNOWN OPEN (the warnings)

1. **A locked phone can play over the speaker and nothing can stop it until unlock.** With the
   app suspended, the WS monitor is down (iOS gives no runtime), so an AirPods/lock-screen play
   during a speaker session double-plays until the phone is unlocked — at which point the
   reconnect snapshot triggers the yield-local guard. Client-side this is a hard iOS boundary;
   the real fix would be daemon-side (pause the room when the ABS session reports another player
   went active), which needs box access.
2. **Seek-starts-playback on a paused session.** Scrubbing, chapter jumps, and transcript line
   taps against a *paused* speaker session start the room playing. For line taps that's arguably
   the intent ("play from here"); for a scrub it can surprise. Fix is daemon-side: a
   `seek {autoplay: false}` variant (NITPICKS).
3. **WS frames and HTTP responses interleave without ordering.** A late "playing" tick can apply
   after a pause response, flapping `advancing`/`hasOwnSession` for a beat (transient UI, a
   duplicate progress write, and — worst case — a double ownership transition). Self-corrects on
   the next frame. A daemon-side sequence number would close it properly (NITPICKS).
4. **One speaker.** The whole design assumes the single WiiM; a second output device would need
   the manager to hold sessions per-device and the chooser to become a real device list.
5. **The daemon has one address, with no failover.** A network flip that loses it mid-session shows
   as `actionFailed` until it is reachable again; an address that only works at home stays that way.
6. **External resumes can jump.** HA's resume path (a bare `/resume`) re-reads ABS progress
   instead of the paused session's position (measured: 29856 → 36738). If the phone listened
   past the speaker's pause point, an HA resume skips ahead to the phone's synced progress —
   which is *sometimes* what you want and *sometimes* a jump. Daemon-side policy question;
   the app itself never issues bare resumes.

## Snips while the speaker plays (audited 2026-10-30)

What a tap does when the room is the output. `SnipPositionSource` asks the manager's strict
predicate (`activeSession`) first, so a snip follows the same output every transport follows; the
sample carries `output: speaker` and the daemon's own title. Three things were added in the audit:

- **A `/status` round trip before a speaker snip** (`SpeakerSessionManager.refreshFromDaemon`).
  The phone's speaker position is the last tick plus wall-clock; after the app slept with the
  monitor suspended, an HA pause or jump in between would have put a Action-Button snip where the
  phone *guessed* the room was.
- **Transcript import on demand** (`TranscriptStore.importMissing`). Capture reads the local
  store, which fills only while a karaoke surface is open; listening on the speaker with the
  phone in a pocket meant textless snips. Capture now pulls the span's chunks from the daemon's
  `/captions` first (personal build only).
- **An output switch restarts heard tracking from the resume rule.** Adopting the speaker after
  the phone had the book loaded at a stale position read as a seek and shrank the first snip's
  reach to the moment of the switch.

Verified on the WiiM at volume 0 (Goblet, daemon `/play {volume: 0}` from the box; the snip's
anchor sat within the 1 s tick of the daemon's position; the text at an unseen stretch came
from the daemon as `hostRaw`).

**Known open, found by the same test: loading a *streamed* book in the app pauses the speaker.**
The app opens an ABS play session on load (`ensureSession`), the daemon sees the
`user_stream_update`, and its Connect rule treats a *new* session from a `TAKEOVER_USERS`
account as a takeover at once (`abs_session.py` `Watcher.on_stream`; only *progress reports* get
the 2026-10-26 "advancing at playback speed" guard). Inside `GRACE_SECS` (45 s) of the speaker's
start it is ignored, which is why the first scripted run passed and the second did not. A
downloaded book opens a local session and never reaches ABS, so daily use mostly dodges this.
The daemon-side fix is small and belongs there: in `on_stream`, route sessions whose
`clientName` starts with `"AudioBook Karaoke"` through the same advancing guard instead of
`on_foreign_activity` directly, so opening the player only takes over once the phone actually
plays. Needs `tests/run.sh` and a container restart (Jake's).

## Debugging quickly

- Live daemon state: `GET <daemon>/status` (ABS bearer from
  `~/.config/audiobooth/devauth.json`). The testing protocol in CLAUDE.md applies: record
  position first, keep playback brief, restore with pause → seek → pause (seek plays!).
- The daemon logs on the TrueNAS box (`you@your-nas`, docker `abs-session`) show every
  command with source; unreachable from off-tailnet networks.
- On-device: `AppLogger.player` for local transitions; the session model logs nothing today
  (deliberate — states arrive every second; NITPICKS has a "log transitions only" note).
