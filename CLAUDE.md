# CLAUDE.md — working on this fork

AudioBooth fork ("AudioBook Karaoke" on the home screen). **[FORK-NOTES.md](FORK-NOTES.md) is the
deep documentation** — architecture decisions, measured numbers, server dependencies, and the
hard-won gotchas in full. This file is the operational quick reference.

## How work flows (read first)

GitHub (`jakeschaeffer/audiobooth-fork`, default branch `main`) is the source of truth for the app. Work happens
in a Claude session on Jake's Mac, the only machine with Xcode, signing, the simulators, and ssh to both servers.

1. **Branch** from `origin/main`, one branch and PR per change (`gh pr create -R jakeschaeffer/audiobooth-fork`).
2. **Test in the simulator** with `./scripts/dev-build-run.sh`. There is no local server for this app: the sim
   talks to the real ABS server as the low-privilege `Test` user (below), so follow the side-effect rules.
3. **Phone**: `./scripts/testflight.sh` (the headless archive, export and upload pipeline in FORK-NOTES.md,
   "TestFlight upload pipeline"), or a device build over Wi-Fi.
4. **Server code** (daemon, caption worker, kosync) is a separate repo, `abs-session`, on TrueNAS at
   `/path/to/abs-session`. That checkout is its source of truth: it has no GitHub remote and its own
   CLAUDE.md, which sessions read before touching it. Edit and commit there (or in the Mac clone at
   `~/Projects/abs-session` and push over `ssh TrueNAS`; that clone's `origin` is the raw tailnet address, which
   the Mac's key doesn't match, so use `TrueNAS:/path/to/abs-session` as the URL). Container
   restarts need `sudo` and are Jake's.

The podcast player (`jakeschaeffer/podcast-player`, on Hetzner) works the same way and has a deploy script
and a local test server; its CLAUDE.md says how. The two share the snip workflow; the plan that ties them is
docs/cross-repo-snips-plan.md in that repo.

## The server is configuration, not code

The app holds one companion address (Settings → Companion Server) and asks that daemon what it offers
(`GET /capabilities`, [docs/COMPANION-API.md](docs/COMPANION-API.md)); [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md)
is the setup from scratch. **No address, hostname, bundle id or team id goes in committed code.** Jake's live in
`AudioBooth/Local.xcconfig` and `scripts/local.env`, both gitignored; a fresh clone needs them copied from their
`.example` files. Anything offering a server feature asks `CompanionStore` (views) or `CompanionSettings.supports`
(everything else) first, because the same binary has to work with no server, or with a server that has no speaker.

## Build & run

- **`./scripts/dev-build-run.sh`** — build, install, launch on the iPhone 17 simulator. Use it
  instead of hand-rolled xcodebuild; it encodes the two traps below.
- **`./scripts/smoke-play.sh`** — presses play on a streamed book (two cold launches) and fails unless it
  keeps playing. Run it after any player change or upstream sync; `testflight.sh` runs it first. Needs the
  speaker daemon idle (an advancing Test session pauses the speaker).
- **Testing is silent.** Launch with `-muted` (DEBUG; the scripts already do), so nothing plays out of the Mac.
  Jake asked for this. Anything on the speaker stays at volume 0.
- Build the **scheme** (`AudioBooth`), never the target — `-target` skips the prebuild that
  generates Readium's module maps and dies on a phantom `Minizip.modulemap` error.
- A **watchOS simulator runtime** must be installed even for iOS-only builds (the scheme embeds
  the Watch app): `xcodebuild -downloadPlatform watchOS`.
- Device build: add `-destination 'platform=iOS,id=<devicectl id>' -allowProvisioningUpdates`;
  install with `xcrun devicectl device install app`. Works over Wi-Fi when the phone is paired.
- Deployment target: the app target is **iOS 17** (upstream parity; widgets are 18). iOS-18 APIs
  such as `ScrollPosition` are `#available`-gated. iOS-26-only surfaces (SpeechTranscriber, FoundationModels) are
  availability-gated; SpeechAnalyzer types don't even link on the simulator (see the
  `#if !targetEnvironment(simulator)` gates in `DeviceTranscriptionSession`).

## Tests & hooks

- Package tests: `swift test` in `Transcription/`. Tests must create SwiftData containers via
  `TestContainers.makeInMemory()` — inline containers race schema registration and SIGSEGV.
- Pre-commit runs swift-format (needs the Xcode toolchain's binary on PATH:
  `export PATH="$(dirname $(xcrun -f swift-format)):$PATH"`). When the format hook rewrites files
  it **aborts the commit** — `git add -A` and commit again.
- Live-daemon test suites are opt-in: `TRANSCRIPTION_LIVE=1` / `TRANSCRIPTION_LIVE_FULL=1`, with the server in
  `COMPANION_DAEMON_URL` / `COMPANION_WORKER_URL`.

## Simulator auth & side effects

- The sim auto-authenticates against the real server (abs.example.com) from
  `~/.config/audiobooth/devauth.json` via a DEBUG bootstrap (`DebugLaunchOptions
  .restoreDevServerIfNeeded`) — as the low-privilege **`Test` ABS user**. If the sim lands on the
  "Servers" sheet, check that file and the DEV-AUTH console lines first.
- **Real side effects exist.** Never trigger "Transcribe on Server" (`POST :8790/jobs` = hours of
  real CPU). Prefer `audiobooth://open/<id>` (no autoplay) over `play/`; terminate the app after
  scripted runs. Fixtures: Goblet `f4f72906-0548-45b2-b75a-44d08826e458` (complete transcript),
  Project Hail Mary `d32e4e8a-39c1-4ff0-b039-46301f4fcd63` (no transcript).
- **The speaker is Jake's real living-room WiiM.** The daemon seek endpoint *starts playback* even
  from paused. Testing protocol: record position via `GET /captions.example.com/status` (ABS bearer
  token), keep playback brief, then seek back and `POST /pause`.
- DEBUG launch args for scripted UI states: `-deeplink`, `-autoOpenTranscript`, `-autoOpenSpeaker`,
  `-speakerIdle` (speaker sheet without autoplay), `-devAuthFile`, `-muted`, and `-companionURL <address|none>`
  [`-workerURL <address>`], which sets the server; `none` is the no-server state (see `DebugLaunchOptions.swift`).

## Architecture in one breath

`API/` (ABS client, SwiftPM) · `Models/` (SwiftData) · `Transcription/` (the transcript engine:
store, grid, provenance tiers, device ASR, LLM cleanup, ebook alignment, daemon/worker HTTP) ·
`AudioBooth/` (app; karaoke surfaces live in `Screens/BookPlayer/Karaoke/`). Transcript text is
tiered by `TranscriptProvenance` — higher quality supersedes per chunk in `TranscriptStore`;
`ebookAligned` (the book's own text) outranks everything, `onDeviceLLMCleaned` sits above raw ASR.
The speaker is a Connect-style output owned by `SpeakerSessionManager`: view-layer mirroring only —
**never** teach `BookPlayerModel`/`AudioPlayer` about the speaker (the whole reliability story
rests on local playback code being speaker-blind).

## Git & server

- `origin` = private fork (push here); `upstream` = public repo, **push disabled** — keep it that
  way. `gh` defaults PRs to upstream: always pass `-R jakeschaeffer/audiobooth-fork`.
- The daemon/worker live on the TrueNAS box (`you@your-nas`,
  `/path/to/abs-session`, bind-mounted into containers). scp + git-commit over ssh
  work; **container restarts are Jake's** (`sudo docker restart abs-caption-worker` /
  `abs-session`). Worker uploads are write-once *per provenance tier* (`X-Transcript-Provenance`).
- A fresh clone has only `origin`. Re-add upstream with `git remote add upstream
  https://github.com/AudioBooth/AudioBooth.git && git remote set-url --push upstream DISABLED`.
- **Sharing outside:** `./scripts/public-snapshot.sh` makes a redacted single-commit copy for a public
  repo (the map of private literals is the gitignored `scripts/public-redactions`); `PUBLIC_BUILD=1
  ./scripts/testflight.sh` ships a build with no speaker stack and no companion address. FORK-NOTES
  "Going public" has the details and what stays named on purpose.

## Cross-repo (snips)

This repo and `jakeschaeffer/podcast-player` (the podcast server + web app, soon a native app) share the
snip workflow: tap, find where listening began, cut on sentences, edit in/out, title + summary, clip.
The plan is [docs/cross-repo-snips-plan.md](docs/cross-repo-snips-plan.md), kept identical in both repos.
The rules that matter here:
- Audiobook snips are anchored on **integer ms + a frozen excerpt**, never word indices or seg ids:
  `TranscriptStore.upsert` replaces whole chunks when a better tier lands.
- Snip capture reads positions at the app layer. **Never** add a `Snip*` import or hook to
  `PlayerManager` / `BookPlayerModel` / `AudioPlayer`.
- Snip models never go into `AudiobookshelfSchema`. User strings use a `Snips` table, not upstream's
  `Localizable.xcstrings`.
- The podcast repo's TypeScript is the reference implementation for the shared algorithms. Until the shared
  `snipkit` package exists, the Swift ports live in `Transcription/Sources/SnipCore` and replay copies of the
  podcast repo's golden files (`Transcription/Tests/SnipCoreTests/Golden/`, see its README). Never edit a port
  or a fixture here alone.

## Snips (what shipped, 2026-10-30)

Snips replace ABS bookmarks in this fork: digital sticky notes on the book, deliberately light. A snip is an
In/Out span, the transcript text inside it (frozen when taken, re-read when the span moves), and one optional
note. No titles, no summaries, no AI.

- **Where things live.** `Transcription/Sources/Snips/` (record, JSON store, capture, heard tracking),
  `AudioBooth/AudioBooth/Services/Snips/` (the only speaker-aware files, plus the bridge the views use),
  `AudioBooth/AudioBooth/Screens/BookPlayer/Snips/` (control, capture card, list, editor), `SnipIntent` for
  Shortcuts and the Action Button. User strings use the `Snips` table (`Snips.xcstrings`).
- **Storage.** One JSON file per snip at `Application Support/Snips/<serverID>/<itemID>/<id>.json`;
  deletes are soft; a file that fails to decode is counted, never removed. The file is the export format.
- **Capture.** `[max(heard_from, T − length), T]`, length chosen in the list's ruler menu (15 s to 2 min,
  default 30 s), then `SentenceSnap` moves In to a sentence start within 8 s and Out to the end of the
  sentence being spoken if that is within 6 s. Heard-from comes from the podcast player's `heard_v1`
  tracker fed by sampled positions.
- **Editor.** The words around the snip, each tappable: a tap moves the nearer point (In to the word's
  start, Out to its end), or the point whose tile you tapped first. No nudge buttons by design.
- **Notes.** The note sits in a bar pinned under the editor's words, so it is always on screen. Add note on the
  capture card, the list's leading swipe, and its long-press menu open the editor with the keyboard in the note.
  The field keeps its own state (`SnipNoteField`): binding it to the editor's draft redrew every word per
  keystroke and scrambled fast typing.
- **Bookmarks.** Existing ABS bookmarks are imported once as snips (title kept as the note) when a book's
  snip list opens. `Snips/bookmark-spans.json` holds reviewed In/Out points for Jake's bookmarks (positions
  only, keyed by book and bookmark second; the 2026-10-30 review); a bookmark without an entry gets the
  current length ending at the bookmark. The `.bookmarks` player control still decodes but renders nothing; `BookmarkViewerSheet`
  and `BookmarkSyncQueue` are untouched upstream code.
- **Scripted run.** `-deeplink "audiobooth://open/<id>" -autoSnipAfter 4` raises the player and takes a snip.
  `-autoOpenSnips` opens the book's list; `-autoEditSnip note|span` opens its newest snip in the editor.
