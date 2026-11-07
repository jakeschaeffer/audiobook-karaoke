# Snips everywhere: a cross-repo plan for AudioBooth and the podcast player

> **This file is kept identical in `audiobooth-fork/docs/` and `podcast-player/docs/`.** Edit both copies in the same sitting until the shared `snipkit` repo exists; then it moves to `snipkit/docs/` and these become pointers.

*Written 2026-10-25 from `audiobooth-fork` @ 724fcfd and `podcast-player` @ f905ea7.*

**How this plan was made.**
1. Six readers mapped both repos.
2. A critic resolved contradictions between their maps.
3. Three architects proposed designs: local-first, one shared pipeline, and decoupled/risk-first.
4. Three judges scored the designs. Decoupled/risk-first won narrowly, and the best local-first ideas were grafted in.
5. Three fact-checkers tested about 140 claims against the code and Apple/Cloudflare docs, and their corrections are applied here.

**Where it is still unverified.** Anything about the TrueNAS servers, the live Cloudflare dashboard, or on-device behaviour is marked as a probe (P1–P7).

**Notation.** "A" is `audiobooth-fork`, "B" is `podcast-player`. `A:path:line` points into a repo.

## TL;DR (what to build, in what order, and the decisions needed from you)

- **The shape.** Two apps, two snip pipelines, and one written contract between them. In v1 neither repo calls the other at runtime. Audiobook snips in A are made, edited, titled and clipped on the phone, and they stay private. The native podcast app is a new SwiftUI client in `B:ios/` that talks to B's existing server.
- **What is shared.** A new small repo, `snipkit`, holds the specs, the synthetic test files with known right answers ("golden fixtures"), and one pure Swift package, `SnipCore`, that both iOS apps import. B's TypeScript stays the reference implementation. TS and Swift are checked against the same fixture files.
- **Order of work.**
  1. Fix the docs that are wrong, and run half-day risk probes.
  2. Build `snipkit` v0.1.
  3. Ship A's first snips (fixed 90 s spans) while B's server gets its fixes and the Cloudflare change for native clients.
  4. Port span selection and build A's editor.
  5. Put B's native listening loop on TestFlight.
  6. Add on-device titles to A and snips to the native app.
  7. Add clips and highlights.
  8. Set up evals in both repos.
- **Upstream cost in A.** Four upstream files, about nine lines. No edits to `project.pbxproj`. `Localizable.xcstrings` stays untouched *only if* the new strings name their own `Snips` table (§1.10), because Xcode otherwise auto-extracts them into upstream's catalog. `PlayerManager`, `BookPlayerModel` and `AudioPlayer` are never touched.
- **One prerequisite found during the fact-check.** On device builds the `Models` package still asks for upstream's app group (A:Models/Sources/Models/Track.swift:86). That probably makes every downloaded book look not downloaded to snip preview and clip export (§1.8). Fix the lookup before building clips.
- **Decisions needed from you** (defaults in brackets):
  1. A third repo? [yes: public, MIT]
  2. Cloudflare for native clients? [bypass Access for `/v1` and `/m`; keep `/` behind Google]
  3. Distribution for the podcast app? [TestFlight internal]
  4. Public audiobook snips? [never in v1]
  5. Server summaries for books? [only if the on-device bench passes fewer than 70% of titles or refuses more than 20%]
- **First check of all.** Open the Cloudflare Zero Trust dashboard and look before changing anything. The repo only documents the intended setup.

## Progress (update as work lands; keep both copies identical)

- **2026-10-26, podcast-player branch `claude/native-app-prep`** (server prerequisites for the native app, §2.2):
  - summary jobs read the revision's own transcript, retry model outages, and never strand a revision;
  - every write is safe to replay from an offline outbox (`if_revision` required on boundary edits, word edits
    carry `transcript_id`, idempotent DELETE, content ETag, `observed_at` / `captured_at`, migration 0007);
  - per-IP login lockout, token-only `/v1/openapi.json`, media URLs die with their device;
  - committed `server/openapi.json` plus a staleness test; recorded responses in `contracts/api/` for the native
    client's decode tests;
  - golden cases in `contracts/golden/` for heard tracking, In/Out rules, `select_v2` and summary validation (the
    SnipCore port's acceptance tests); web has vitest.
  - **Not done:** the Cloudflare Access bypass itself (dashboard, owner), CI, `apple-app-site-association`, the
    `snipkit` repo (decision 1), anything in Swift.
  - Measured in passing: on the synthetic narration with punctuation stripped, `select_v2` falls back to the fixed
    span for 44 of 72 taps, against 27 of 72 with punctuation, so probe P3 matters.
- **2026-10-26, podcast-player branch `claude/native-app-scaffold`** (M7 started, §2.3–2.5): `ios/` with the
  app target and `PodcastAPI`, `PlayerKit`, `SyncKit`. All 23 recordings in `contracts/api/` decode; the Swift
  `HeardTracker` passes all 38 `heard_v1` cases (it lives in PlayerKit until SnipCore exists). Login → Today →
  Library → feed → player works in the simulator against a local server with no paid services, and playback
  reports with `observed_at` reach it. Bundle id `com.example.Snip` (the default of decision 10).
  - **Not done:** transcript tab, URL renewal on foreground, reachability and background flushes, TestFlight,
    the device checklist; the Access bypass still blocks `snip.example.com` from the app.
  - Learned: `.iOS(.v26)` in a package manifest needs `swift-tools-version: 6.2`.
  - Learned (2026-10-26, on a phone over cellular): `AVURLAssetPreferPreciseDurationAndTimingKey` (§2.5) makes a
    *streamed* MP3 download in full before the first sample plays, so a 60 MB episode looked like broken playback.
    The native app streams without it; keep it for downloaded files only. Same caution applies to A's streamed books.
  - TestFlight: app "Snip Podcasts" (bundle `com.example.Snip`), internal group "Owner", `ios/scripts/testflight.sh`.
    Release builds reach production over the tailnet (`https://<podcast-tailnet-host>:8443`) until the
    Access bypass exists.

- **2026-10-30, audiobooth-fork branch `claude/snips-capture-v1`** (A capture v1, a lighter take on M3; Part 1 is
  superseded where it differs): Jake's direction is *sticky notes, not titled clips*: a snip is an In/Out span,
  the frozen transcript text, and one note. No titles, summaries, revisions or edit log. Shipped: `SnipCore`
  (HeardTracker and SpanPoints ports, passing copies of `heard_v1` and `span_points_v1`) and `Snips` (JSON
  store, capture at a chosen length 15 s–2 min, default 30 s, then `SentenceSnap`: In to a sentence start
  within 8 s, Out to the end of the sentence being spoken within 6 s; heard tracking by sampling) as targets
  of the existing `Transcription` package, so no `project.pbxproj` edit; app-side position source, capture
  card, list, a word-tap editor (nearer point moves, or the tile you chose; no nudge buttons) and a note,
  `SnipIntent`; ABS bookmarks imported once as snips. Bookmarks are replaced:
  `.snip` takes `.bookmarks`' place in the default controls. Verified in the simulator on Goblet.
  - **Not done:** `snipkit` as a repo (the ports and fixture copies sit in A for now), the full `select_v2`
    port (`SentenceSnap` is a few-second nudge, not a selector), preview with its own player, clips, sharing,
    karaoke tint, evals.
  - Learned: the deep link only raises the mini player, so a scripted capture (`-autoSnipAfter`) must call
    `showFullPlayer()` itself; `Text(_, tableName:)` strings did not get extracted into `Snips.xcstrings` by
    `xcodebuild` (the catalog stays empty; the keys display as written).

## The one mental model (both apps are the same pipeline)

A **snip** is a short audio clip saved from what you were just hearing. The trick is guessing where the idea started, so the user rarely has to fix it. Both apps run the same nine steps. They differ only in where each step runs.

```
 TAP
  │
  ▼
 1 POSITION ──► 2 HEARD-FROM ──► 3 WINDOW ─────► 4 SELECT ──────► 5 RECORD
 "where am I"   "where did my    "timed words    "snap to a       ms are the truth,
                 unbroken         around the      sentence end,    plus a frozen quote
                 listening        tap"            start ~90 s      and a note of which
                 start?"                          back"            transcript it came from
                                                                        │
  ┌─────────────────────────────────────────────────────────────────────┘
  ▼
 6 EDIT IN/OUT ──► 7 TITLE + SUMMARY ─────────► 8 CLIP / SHARE
 tap words,        model → validator → retry    audio file or text
 nudge ±1 s/±5 s   once → fallback title
        │                   │
        └───────┬───────────┘
                ▼
 9 EDIT LOG (auto span vs. your span, model title vs. your title) ──► EVALS
```

An **eval** is a repeatable measurement of how good an automatic step is. Step 9 matters most for compounding. Every time you fix a span or a title, that fix becomes a test case that grades the automatic version.

| Stage | A (audiobook) today | B (podcast) today | This plan |
|---|---|---|---|
| 1 Position | Precise local clock, plus the speaker's `livePosition`, used only by karaoke (A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayer.swift:269-316) | `<audio>` currentTime | A: one app-layer position source. Native B: AVPlayer |
| 2 Heard-from | Nothing | `HeardTracker`, merged intervals (B:web/src/player/heard.ts:17-82) | Swift port in SnipCore, used by both apps |
| 3 Window | `TranscriptStore` 300 s chunks, seconds, ranked tiers, leading-space words | Immutable transcript, integer ms, `[s,e,text]` word tuples (B:server/src/http/schemas.ts:67-71) | A: adapter converts to B's shape |
| 4 Select | Nothing | `select_v2` "snap-90" on the server (B:server/src/core/snip/select.ts:12,32-43) | A: on-device Swift port. Native B: the server |
| 5 Record | ABS bookmarks: a single point in whole seconds | `snip` + `snip_revision` in SQLite. Boundary edits append a revision; selection, summary and title edits update the current one in place (B:server/src/services/snipJobs.ts:40-42, snips.ts:151) | A: one JSON file per snip, with revisions |
| 6 Edit | Nothing (karaoke has no text selection) | Web editor with tap-to-set In/Out (B:web/src/screens/SnipEditor.tsx) | A: new editor. Native B: port of the web editor |
| 7 Title | Precedent: `CleanupSession` on Apple's on-device model | Prompt `snip-summary` v1 + validator + fallback (B:server/src/core/summary/snip.ts:56-124) | A: on-device model + Swift validator. Native B: the server |
| 8 Clip | Nothing | ffmpeg MP3, verified to within 250 ms (B:server/src/core/clip/render.ts:11-12) | A: AVFoundation `.m4a`. Native B: the server's MP3 |
| 9 Edit log | Nothing | `title_edit` table + evals (B:server/src/db/migrations/0005_title_ground_truth.sql:12-28) | A: `snip-edits.jsonl` + `A:evals/` |

The deepest difference is step 5. B's transcript *rows* never change once stored, so B can store word indices, as long as it reads them against the revision's own `transcript_id`. The asset's "current transcript" pointer can move (B:server/src/services/transcripts.ts:61, textPolicy.ts:22-28), and two of B's bugs come from forgetting that (§2.2). A's transcripts get *upgraded* whenever a better tier lands, and `upsert` swaps out the whole 300 s chunk (A:Transcription/Sources/Transcription/TranscriptStore.swift:184-197). A word index saved today points at different text tomorrow. So **an A snip is anchored on integer milliseconds and stores its quote as text**. The word range is worked out again from the current transcript every time the snip is read (`wordRangeByMidpoint`, B:server/src/core/snip/select.ts:253-267).

---

## Part 1 — Snips in the audiobook app

### 1.1 Scope and the four rules

v1 covers **books only**. ABS podcast episodes get no snips: A has no podcast transcripts, karaoke is gated on `podcastID == nil` (A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayer.swift:133,668,740), and podcasts are B's job. Two podcast snip systems would split your data.

1. **Milliseconds are the truth.** Store book-absolute integer ms: `Int((seconds * 1000).rounded())`. Never store word indices or seg ids.
2. **Speaker-blind players.** Only the app layer may know about the WiiM. Capture *reads* positions and never adds hooks to `PlayerManager`, `BookPlayerModel` or `AudioPlayer` (A:CLAUDE.md, A:SPEAKER.md).
3. **User data never vanishes.** A snip file that fails to load is skipped and reported, never deleted.
4. **Private by default.** No public links. Sharing happens only when you choose to share.

### 1.2 Architecture and where files live

```
┌ App target: AudioBooth/AudioBooth ─────────────────────────────────────┐
│ Services/Snips/SnipPositionSource.swift   ◄── speaker-aware (1 of 2)   │
│     #if SPEAKER_STACK: livePosition ?? preciseTime ?? progress         │
│ Services/Snips/SnipPreviewController.swift ◄── speaker-aware (2 of 2)  │
│     pauses local or speaker playback before a preview, offers resume   │
│ Services/Snips/SnipAppBridge.swift        starts the engine (1 line    │
│                                           in AudioBoothApp .task)      │
│ Screens/BookPlayer/Snips/*                button, card, list, editor   │
└───────────────┬────────────────────────────────────────────────────────┘
                │  import Snips   (rides the EXISTING `Transcription` product)
┌ Transcription package (Jake-authored) ─────────────────────────────────┐
│ Snips target   capture · heard service · JSON store · window adapter · │
│                summarizer (FoundationModels) · clip/preview (AVFoundation)
│                `internal import SnipCore`                              │
│ Transcription  TranscriptStore + 2 small new reads                     │
└───────────────┬────────────────────────────────────────────────────────┘
                │  .package(url: …/snipkit.git, exact: "0.x.y")
┌ snipkit / SnipCore (Foundation only, no UI, builds on Linux too) ──────┐
│ HeardTracker · Sentencizer · SpanSelector · WordRange · SpanPoints ·   │
│ SummaryValidator · NameGuard · FallbackTitle · Transcript v1 Codable   │
└────────────────────────────────────────────────────────────────────────┘
PlayerManager / BookPlayerModel / AudioPlayer: unchanged, never import Snips
```

**Why three layers.**
- SnipCore holds the rules, so they can be tested in seconds with `swift test` and checked against B.
- The `Snips` target holds everything that touches Apple frameworks or A's transcript store. It is still testable on macOS, because Transcription already supports macOS 14 for exactly this reason (A:Transcription/Package.swift:10-16).
- The app target holds only views, plus the two small files that know about the speaker.

**Why zero `project.pbxproj` edits.**
- The app already links the `Transcription` product (A:AudioBooth/AudioBooth.xcodeproj/project.pbxproj:23,401). Add `Snips` to that product: `.library(name: "Transcription", targets: ["Transcription", "Snips"])`.
- Adding a separate package would cost the six fragile pbxproj insertions FORK-NOTES warns about (A:FORK-NOTES.md:78-83).
- The trade-off: if Transcription is ever upstreamed (A:NITPICKS.md:39-43), remove `Snips` from that product line first.

**Best practice (SPM, Swift 6 access-level imports).** Write `internal import SnipCore` in *every* Snips file, or turn on `.enableUpcomingFeature("InternalImportsByDefault")` for the target. In Swift 6 a plain `import` is still public, and mixing the two forms in one module produces warnings. The compiler then refuses to let SnipCore types appear in Snips' public API. It does **not** stop the app from writing `import SnipCore`, because the module still sits on the search path. Add a one-line grep check if that matters to you. Do not use `@_exported import`: the underscore marks it as unofficial.

New files (each under about 200 lines):

```
Transcription/Sources/Snips/
  Model/     Snip.swift  SnipRevision.swift  SnipSource.swift  TranscriptSnapshot.swift
  Store/     SnipStore.swift  SnipEditLog.swift  SnipFileCodec.swift
  Capture/   HeardTrackingService.swift  SnipCapture.swift  PlaybackSample.swift
  Pipeline/  SnipPipeline.swift  TranscriptWindow.swift
  Summary/   SnipSummaryModel.swift  AppleSnipSummarizer.swift  BookSummaryPrompt.swift  SummaryRunner.swift
  Audio/     SpanComposition.swift  ClipExporter.swift  SnipPreviewPlayer.swift
  Export/    SnipMarkdownExporter.swift
  Resources/prompts/  registry.json  book-snip-summary/v1.md     (declared with .copy, see below)
  Resources/Snips.xcstrings            strings shown by package code, read with bundle: .module
Transcription/Tests/SnipsTests/         pure pipeline, exporter, summarizer-with-fake (no SwiftData)
Transcription/Tests/TranscriptionTests/ SnipTierUpgradeTests.swift (needs a TranscriptStore, so it lives here)
AudioBooth/AudioBooth/Services/Snips/   SnipPositionSource.swift  SnipPreviewController.swift  SnipAppBridge.swift
AudioBooth/AudioBooth/Screens/BookPlayer/Snips/
  SnipControlButton.swift  SnipMenuItems.swift  SnipSheets.swift  SnipCaptureCard.swift
  SnipListSheet.swift  SnipRow.swift  SnipEditorView.swift  SnipEditorModel.swift
  WordFlowLayout.swift  SnipPointTiles.swift  Snips.xcstrings
AudioBooth/AudioBooth/AppIntents/SnipIntent.swift
docs/snips/  README.md (status table) 01-capture.md 02-selection.md 03-editing.md 04-titles.md 05-clips.md
```

**Three package details that bite if missed:**
- **Prompt files.** Declare the prompt tree with `.copy("Resources/prompts")`, not `.process`. `.process` flattens folders, so `book-snip-summary/v1.md` and a later `cleanup/v1.md` would collide in the bundle.
- **SwiftData tests.** `swift test` runs every test target in one process at the same time. The SIGSEGV race CLAUDE.md warns about is avoided only by the single lock in `TestContainers`, which is internal to `TranscriptionTests` (A:Transcription/Tests/TranscriptionTests/TestSupport.swift:12-23). Any test that needs a real `TranscriptStore` therefore goes in `TranscriptionTests`. `SnipsTests` stays free of SwiftData.
- **watchOS.** The Transcription package also declares watchOS 10. Wrap the `Audio/` and `Summary/` files in `#if os(iOS) || os(macOS)` so a watch build never sees AVAssetExportSession or FoundationModels.

### 1.3 Capture, heard tracking and the speaker rule

**Position.** `SnipPositionSource` returns a `PlaybackSample{itemID, positionSec, isPlaying, speed, output}`. It copies the *full* expression karaoke already uses (A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayer.swift:290-292), including the last two fallbacks. That code already sits inside `#if SPEAKER_STACK` (BookPlayer.swift:269), and the snip version needs the same guard:

```swift
#if SPEAKER_STACK
let pos = SpeakerSessionManager.shared.livePosition(for: id)
  ?? PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
#else
let pos = PlayerManager.shared.preciseTime(for: id) ?? progress?.currentTime ?? 0
#endif
```

- **Why the fallbacks.** `preciseTime(for:)` returns nil unless that exact book is the one `PlayerManager` has loaded (A:AudioBooth/AudioBooth/Services/PlayerManager.swift:36-39).
- **Why the guard.** `SpeakerSessionManager.swift` is compiled out of the store build entirely (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/SpeakerSessionManager.swift:8), so an unguarded reference would not build.
- **Why in the app.** Packages never see `AUDIOBOOTH_FEATURES` (A:AudioBooth/Signing.xcconfig:14-17). The Snips target receives the sample as a closure, an approach called dependency injection.

**Which book is "now"?** Don't rely on `PlayerManager.current`, which `AddBookmarkIntent` uses. If the WiiM plays a book adopted from Home Assistant, the phone may have nothing loaded, or a different book. Ask the speaker session for its item id first, then the local player.

**Best practice.** Keep compile-time flags at the edge (the app target) and pass behaviour inward as closures.

**Best practice (Swift concurrency at the seam).** The app target compiles as Swift 5 with main-actor default isolation, while the package is Swift 6. Type the injected closure `@MainActor @Sendable () -> PlaybackSample?`, and have the sampler hop to the main actor to call it. The compiler then checks the hand-off for you.

The speaker position keeps advancing from its last update by wall-clock time (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/SpeakerSessionModel.swift:69-71). Its speed is 1×, because the daemon has no rate control (A:FORK-NOTES.md:346). A snip records `capture_output: "speaker"` so evals can split the results by output.

**Heard tracking with no seek hooks.** `HeardTrackingService` (Snips) owns one `SnipCore.HeardTracker` per item. It samples every 250 ms while playing and once a second when idle.

- B's tracker spots seeks nobody announced, purely from position jumps: back more than 1 s, or forward more than wall time × speed + 3 s (B:web/src/player/heard.ts:48-63). Upstream player code never has to tell us about a seek.
- After the app has been suspended while the WiiM played, the next sample's jump roughly equals the elapsed wall time, so the heard stretch simply continues. Two conditions make that true:
  - **Measure elapsed time with a clock that keeps running while the phone sleeps.** Use `ContinuousClock` or `Date`, not `SuspendingClock` or uptime.
  - **Ignore samples for about 2 s after returning to the foreground.** While suspended, the speaker model keeps extrapolating its position (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/SpeakerSessionModel.swift:69-71). If someone paused the speaker elsewhere in the meantime, the first samples overshoot and then snap back when the socket reconnects. Without the pause, that reads as a backward seek and wrongly resets `heard_from`.

**Best practice.** When you can't own the code that produces events, derive state from observations rather than adding hooks to it.

**Cold start** follows B's rule exactly: `reset(start, assumeHeardBeforeMs: 180_000)` (B:web/src/player/engine.ts:51,225). State lives in memory only. `PlaybackHistory` is too lossy to seed from, and matching B keeps the fixtures identical.

**Entry points in v1:**
- A `PlayerControl.snip` bar button.
- An overflow-menu item, "Snip" / "Snips (N)".
- A "Snip" button in the karaoke sheet's always-visible toolbar. Not in the banner next to "Clean Up Text": that banner shows only while cleanup is on offer, which means iOS 26, raw ASR present and no cleanup running (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/KaraokeSheet.swift:195, KaraokeSheetModel.swift:98-100).
- `SnipIntent`, a phrase-less App Intent for Shortcuts. On the Action Button it needs one manual step (below).

Two reasons for the extra entries:
- `.snip` is **not** in `PlayerControl.default` (A:AudioBooth/AudioBooth/Models/PlayerControl.swift:38-40), so existing users would find it only among the disabled controls. The overflow and karaoke entries keep the feature findable.
- `AudioBoothShortcuts.swift` is untouched because it already registers 10 shortcuts, Apple's cap.

**Best practice.** An `AppIntent` with no `AppShortcut` phrase still appears as an action in the Shortcuts app. The Action Button lists only App Shortcuts, though, so you make a one-action shortcut around "Snip" and assign that. On iOS 18 and later, a Control Center control (`ControlWidget`) could go on the button directly, behind an availability check.

**What a tap does:**
1. Mint a `UUID` and write the record *immediately*: revision 1 is `fixed` over `[max(heard_from, T−90 s), T]` with status `waiting`, so a crash cannot lose the tap.
   - This mirrors B's `fixedSpan` *fallback* (90 s, B:server/src/core/snip/select.ts:245), not B's 60 s provisional row (B:server/src/services/snips.ts:33). B always replaces its provisional row; A keeps revision 1 as the answer when no transcript exists. So a fixed-span A snip is comparable with B's no-transcript result.
2. Build the window and run selection.
3. Replace revision 1 in place with the `snap` result, as B's `select_snip` does (B:server/src/services/snipJobs.ts:40-42).
4. Play a haptic and show a new fork-owned `SnipCaptureCard` overlay with title, Edit and Undo. The existing `ToastManager` holds only a message and a type, and dismisses on a timer (A:AudioBooth/AudioBooth/Services/ToastManager.swift:5-30). Extending it would add a fifth upstream file.

A UUID is enough: B accepts any 8–64-character `client_request_id` (B:server/src/http/schemas.ts:88-93), so a later sync needs no new id.

**Later:**
- A lock-screen snip via `MPRemoteCommandCenter.shared().bookmarkCommand`.
  - The command center is shared by the whole app process, so the app-level service could register it without touching `PlayerManager`, and nothing registers it today.
  - Headphones and AirPods never send a bookmark event: they only send play/pause, next/previous and skip.
  - There is no evidence that today's Lock Screen shows this command at all, so run a probe first.
  - SPEAKER.md:87 says remote-command handlers live in `PlayerManager`. Registering one elsewhere is a deliberate exception, so write it down there.
- CarPlay, once the entitlement exists.

**Free fix.** `AddBookmarkIntent` reads the local player in whole seconds (A:AudioBooth/AudioBooth/AppIntents/AddBookmarkIntent.swift:30, BookPlayerModel.swift:356-359). That reading freezes while the WiiM plays, and it gets the wrong book when the speaker plays one the phone hasn't loaded. Point it at `SnipPositionSource`: a small edit to an upstream file, which you can skip.

### 1.4 Storage: one JSON file per snip

`SnipStore` is an `actor` that writes `Application Support/Snips/<serverID>/<itemID>/<snipID>.json` with `Data.write(options: .atomic)`. It keeps an in-memory index built on first open. A file looks like this:

```json
{ "schema": "snip/1", "id": "8c1e…", "item_id": "f4f72906-…", "server_id": "…",
  "source": { "kind": "abs-book", "title": "…", "author": "…", "narrator": "…" },
  "anchor_ms": 4512345, "heard_from_ms": 4401000, "captured_at": "2026-11-02T20:11:05Z",
  "capture_output": "local", "audio_fingerprint": "sha256 of [(index,start,duration)]",
  "revisions": [ { "rev": 1, "method": "snap", "start_ms": 4423180, "end_ms": 4512100,
    "excerpt": "…", "snapshot": [ { "chunk": 15, "tier": "hostRaw", "engine": "…", "timing": "word" } ],
    "selection": { "version": "select_v2", "…": "…" }, "status": "ready",
    "title": "…", "title_source": "model", "generated_title": "…", "summary": "…",
    "summary_status": "ready", "summary_model": "afm", "summary_prompt_version": "book-snip-summary/v1" } ],
  "note": null, "deleted_at": null }
```

**Decision note: the judges split on SwiftData versus files. I chose files.**
- `AudiobookshelfSchema` deletes the whole database when it fails to open (A:Models/Sources/Models/ModelContextProvider.swift:74-85).
- TranscriptStore's safer approach moves a broken database aside ("quarantines" it) and rethrows; the next open then creates a fresh, empty store (A:Transcription/Sources/Transcription/TranscriptStore.swift:132-148). That is right for transcripts, which can be fetched again. It is wrong for snips you wrote: they would silently disappear from the UI.
- Hundreds of small documents don't need a database.
- Files keep the snip store itself out of the SwiftData schema-registration race in tests (A:Transcription/Tests/TranscriptionTests/TestSupport.swift:6-11). Tests that also need a `TranscriptStore` still live in `TranscriptionTests` (§1.2).
- The file *is* the export format, `snip-record-v1`.
- `SnipStore` sits behind a protocol, so a SwiftData container later is one new file.

**Best practice (Codable versioning).** `JSONDecoder` ignores keys it doesn't know. So: new fields are always optional, which needs no migration. A breaking change bumps `schema` to `snip/2`, with one converter function. A file that fails to decode stays where it is, is logged, and appears as a "1 snip couldn't be read: Export file" row.

**Text upgrades are explicit.** The editor shows "Better text available" when a revision's snapshot tier is lower than what the store now holds for that span. Tapping **Update quote** appends a revision with `method: "reanchor"`: the same ms and a fresh excerpt. Any edit also creates a new revision. A quote you shared never changes behind your back, and the revisions map one-to-one onto B's `snip_revision` if you ever sync.

**Edit log.** `Snips/snip-edits.jsonl` gets one line per edit, so ground truth starts with the first build. There are two kinds of line:
- **Title edits** use B's `title_edit` field names exactly: `snip_id, revision_id, previous_title, previous_source, new_title, generated_title, summary_model, summary_prompt_version, start_ms, end_ms, excerpt, created_at` (B:server/src/db/migrations/0005_title_ground_truth.sql:12-26).
- **Boundary edits** are A's own record: `{kind: "boundary", snip_id, rev, auto_span, final_span, selection_version, created_at}`. B logs no boundary edits.

B's eval runners don't read files. The title eval pulls edits from SQLite (`listTitleEdits`, B:server/src/evals/snip-titles/appEdits.ts:7-10), and the selection eval has its own case format. So M12 adds a small converter, `A:evals/scripts/to-b-cases.ts`, that turns the JSONL into B's `TitleCase` and selection-case files.

Two small reads are added to Jake-owned files:
- `TranscriptStore.chunkInfo(forItem:in:) -> [ChunkInfo{index, provenance, engineID}]`. Today only tiers are exposed (A:Transcription/Sources/Transcription/TranscriptStore.swift:256).
- `displayTokens()`, made public as `timedTokens()` (A:Transcription/Sources/Transcription/TranscriptSegment+DisplayPieces.swift:79).

### 1.5 Selection

- **Algorithm.** `sentencizer_v1` + `select_v2` "snap-90", deterministic path only, with B's constants: min 30 s, target 90 s, max 180 s, 200/250 ms padding (B:server/src/core/snip/select.ts:32-43). The model start-picker is not ported. On B's 510 labelled cases it turned 35% no-edit into 27% (B:evals/snip-selection/README.md:80-90). Those labels measure agreement with Snipd's ~90 s habit, so they are a baseline, not a verdict.
- **Where it runs.** On the phone, synchronously. It is a pure function, and the store build has no server.
- **The transcript is not always on the phone yet.** The local `TranscriptStore` fills in on demand, and today only while a karaoke surface is open. `KaraokeSheetModel` imports the missing chunks for its window (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/KaraokeSheetModel.swift:662-675).
  - Snipping a passage you never opened in karaoke would find no local text.
  - **Personal build:** `SnipPipeline` imports the missing chunks for `[T−360 s, T+120 s]` itself through `RemoteTranscriptService.source` before selecting. Move the import code from `KaraokeSheetModel` into a shared helper in Transcription so both callers use it.
  - **Store build:** there is no server, so a snip uses whatever on-device transcription already exists and otherwise stays `fixed`.
- **Window: `[max(0, T−360 s), T+120 s]`.** This corrects all three proposals.
  - The selector sentencizes from `lo − 60 s` (B:server/src/core/snip/select.ts:98,116).
  - The sentencizer then reads a further 120 s margin on *both* sides (B:server/src/core/snip/sentencize.ts:32,47-50).
  - Stop the window at T and the sentence playing at the tap gets cut short. It then looks finished and eligible, so the span would end mid-sentence. The server, with the whole transcript, would reject it.
  - Including words after T is not "unheard" text. They only decide where sentences end.
- **The adapter (`TranscriptWindow`)** builds a temporary transcript in B's shape:
  - integer ms;
  - A's leading space trimmed;
  - `spk = nil` (one narrator, so the speaker rules never fire);
  - word indices local to the window, thrown away afterwards.

  Segments without word timings get `timedTokens()` and a `timing: "interpolated"` flag. That covers hostCleaned, onDeviceLLMCleaned, and ebook sentences below the 70% exact-match bar (A:Transcription/Sources/Transcription/EbookAlignment.swift:156-159). Ebook words that didn't match are zero-length points (start == end) and are flagged `approx` one by one.
- **No transcript under the tap.** Revision 1 stays `fixed`/`waiting`. The title is "Chapter · h:mm:ss". When the card or list appears, or the app returns to the foreground, `SnipPipeline.refreshWaiting(itemID:)` fetches any missing chunks (personal build) and re-runs selection, but only for revisions still `fixed` and unedited.
- **Known risk.** It is unverified whether Apple's on-device transcriber (SpeechTranscriber) puts punctuation inside its timed runs. If it doesn't, sentences split only on pauses of 700 ms or more (B:server/src/core/snip/sentencize.ts:63-65). Probe P3 settles this. Any fix becomes a *new version* (say `sentencizer_v1a`) with its own fixtures, never a silent change.

### 1.6 Highlighting and in/out editing

**A separate full-screen editor, not a mode inside karaoke.**
- `KaraokeSheet.swift` is a 1,160-line teleprompter with tap-to-seek, follow mode and scroll parking (A:FORK-NOTES.md:349-395). A selection mode would fight all of that.
- Each line is one `Text(AttributedString)` (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/KaraokeSheet.swift:1134). Words *could* be made tappable by giving each word a `.link` and catching taps with `OpenURLAction`. But that gives no long-press, no drag, no word positions on screen, and link styling you would have to undo.
- A separate editor with one view per word avoids all of these limits.

**Layout** (B's web editor):
- In / Out / Length tiles, with Out selected first;
- −5 / −1 / +1 / +5 s nudges;
- Preview;
- a title field;
- the summary with a Regenerate button;
- the transcript from start−5 min to end+5 min, with "Earlier"/"Later" buttons that add 5 minutes each. The window widens by 60 s when a nudge pushes a point past its edge (B:web/src/screens/SnipEditor.tsx:17-18,65,111).
  - In A, the window must also respect transcript availability (§1.5): fetch missing chunks before showing "Earlier".

**Words.** Each word is its own `Text` inside a custom `WordFlowLayout`, one row per sentence, in a `LazyVStack`.

**Best practice (SwiftUI).** The `Layout` protocol (iOS 16+, fine on the iOS 17 floor) is the supported way to build flowing layouts. `SnipEditorModel` (`@Observable`) holds every rule and calls `SnipCore.SpanPoints` and `WordRange`. The view only draws and forwards taps, so the rules are unit-tested without any UI.

**Best practice (scroll position).** "Earlier" inserts rows *above* what you are looking at, which makes the list jump. Keep the reading position with `scrollPosition(id:anchor:)`, which works on iOS 17. iOS 18's `ScrollPosition` type and `onScrollPhaseChange` need `#available` checks, as KaraokeSheet already does.

**Rules (from B).**
- A word is in the span when its midpoint is.
- Moving one point past the other carries the other along.
- Minimum span 1,000 ms (B:web/src/screens/SnipEditor.tsx:19).

**Granularity.**
- Word-accurate on hostRaw, onDeviceApple and ebookAligned sentences that kept their word timings.
- On `interpolated` or `approx` words, a tap snaps the point to the nearest sentence edge, and a one-line hint explains why. Interpolated times are guesses from character position and can be seconds off. Nudges still allow fine-tuning.

**Accessibility.** `accessibilityAdjustableAction` on the In and Out tiles, so a VoiceOver swipe nudges the point.

**Preview never touches the main player or the speaker.** All three judges required this. `SnipPreviewPlayer` (package) uses its **own `AVPlayer`** over a composition of the downloaded track files (the same code as clip export, §1.8), with `addBoundaryTimeObserver` to stop at Out. The app-side `SnipPreviewController` does the speaker-aware parts:
- It first pauses whatever is playing, through the app's ordinary pause action, or the speaker session's pause under `#if SPEAKER_STACK`.
- It resumes local playback afterwards, as B's clipPlayer does.
- If the WiiM was playing, it shows a "Resume on speaker" button instead of sending more commands.

Why so strict:
- Seeking the main player writes ABS progress and `PlaybackHistory`.
- It feeds a fake jump into the heard tracker.
- On the speaker, a seek starts playback in your living room even from paused (A:FORK-NOTES.md:342-345).

Streamed books show "Download to preview" in v1.

**Persistent highlights (milestone M11).** Saved snip ranges become a background tint through a new parameter on `TranscriptText.styled` (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/KaraokeSheet.swift:1134). The tint is colour only, the characters never change, so a line can't rewrap. Long-press "Snip this line" comes later, after a prototype check.

### 1.7 Titles and AI summaries (on-device)

- **`AppleSnipSummarizer`** sits behind `#if canImport(FoundationModels) && os(iOS)` plus `@available(iOS 26, *)`. That is the same gate `CleanupSession` uses (A:Transcription/Sources/Transcription/CleanupSession.swift:1).
  - The `os(iOS)` part matters. On a Mac with the Xcode 26 SDK, `canImport(FoundationModels)` is true, but the package's macOS 14 floor would make the code fail to compile, and `swift test` would stop building.
  - The app floor is iOS 17 (A:AudioBooth/AudioBooth.xcodeproj/project.pbxproj:930,973).
  - The model fills a guided-generation struct (`@Generable SnipSummaryDraft{title, summary, claims:[{text, sentenceIDs}]}`) and emits sentence ids, never times.
- **One fresh `LanguageModelSession` per snip.** `CleanupSession` reuses one session for every batch (A:Transcription/Sources/Transcription/CleanupSession.swift:161), and a session's memory grows until it overflows.
  - A 180 s excerpt is about 650–750 tokens, well inside the small on-device window. With a fresh session, an overflow would come from the instructions, the output schema and the context lines, not the excerpt.
  - Budget up front: read the model's `contextSize` and call `tokenCount(for:)` (iOS 26.4+; on older versions, estimate about 3–4 characters per token). Shrink the context lines first, never the excerpt.
- **Prompt.** A new prompt *name*, `book-snip-summary/v1.md`, in `Snips/Resources/prompts/`. It uses B's `registry.json` format (sha256 per version) and a test that checks the hash. The wording is B's v1 rules with "the narrator / the author" in place of host/guest. Context lines are Book / Author / Chapter, with up to two earlier sentences given as context that may not be cited.
  - *Why a new name rather than v2:* B's registry has one active version per name (B:server/src/core/summary/prompts.ts:10). A separate name keeps the podcast scores comparable, and the model and domain differ anyway.
- **Validation.** Ported in SnipCore:
  - title ≤60, summary ≤320, at most 3 sentences (B:server/src/core/summary/snip.ts:18);
  - every claim cites a real sentence id, and there are at least as many claims as summary sentences (snip.ts:73);
  - neither the title nor the summary says "in this clip / excerpt / snip / segment" (snip.ts:66);
  - the name guard (B:server/src/core/summary/names.ts). Its allowed names are a parameter: the excerpt, book title, author, narrator, series and chapter title, plus the role words "narrator author". B hardcodes "host guest" here (snip.ts:75-81).
- **Sentence ids must match B's.** The input mapping lives in a B *service* file, not in core. `sentencesForRange` clips sentences at the span edges and renumbers them from 0, and `precedingSentences` picks the context lines (B:server/src/services/snipJobs.ts:129-151). Port both into SnipCore's summary family, or the ids the model cites won't line up with B's fixtures.

  On failure: retry once with the problems listed, then fall back to `fallbackTitle`, the first 8 words (B:server/src/core/summary/snip.ts:90-94).
  - **Decision note on the title cap:** keep 60 for v1, so the first scorecard compares directly with B's 3.61/5 (B:evals/snip-titles/README.md:54). Your titles run a median of 85 characters (same table), so M12 scores both 60 and 80.
- **Status meanings.** This fixes a lesson from B's own bug (§2.2).

| Status | When | What happens |
|---|---|---|
| `pending` | Transient: `availability == .unavailable(.modelNotReady)`, app in background, thermal state `.serious` or worse | `SummaryRunner` retries on the next foreground |
| `ready` | Validated output | Model title shown, unless you wrote one |
| `failed` + reason | Two failed validations, or `guardrailViolation` (expected on fiction) | Fallback title |
| `unavailable` | No iOS 26, `.deviceNotEligible`, or Apple Intelligence off (re-checked on foreground) | Fallback title; store-build users still get usable snips |
| `skipped` | No excerpt (fixed span with no transcript) | "Chapter · time" title |

- **Refusals on fiction, and the one mitigation.**
  - Apple's on-device model has safety guardrails, and books with violence will trip them.
  - Apple offers a looser mode, `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, meant for exactly this kind of summarizing. But it applies **only to plain-String output**; guided `@Generable` output always runs the default guardrails.
  - So probe P2 benches both paths: guided output, and String output with permissive guardrails, parsed as JSON and then run through the same validator.
- **The on-device model changes with OS updates.** The platform check found Apple documenting model updates at iOS 26.4 and in iOS 27. Every summary records `os_version` and `summary_model`, and the P2 bench and M12 scorecards are rerun after OS updates. Otherwise the pass/refusal thresholds in decision 6 aren't reproducible.
- **Your titles always win.** The model's title is still kept in `generated_title` for evals (B:server/src/services/snipJobs.ts:95-104).
- **Tests.** A `SnipSummaryModel` protocol with a `FakeSummaryModel` (B's FixedTitleModel pattern) means `swift test` on the Mac covers retry and fallback without FoundationModels.
- **Server fallback** (personal build only, decision 6). Used only if probe P2 shows fewer than ~70% of titles passing validation or more than ~20% refused.
  - It would be a stateless `POST /v1/tools/summarize-snip` on B, built around `summarizeSnip`. It is not plain reuse.
  - `summarizeSnip` hardwires the podcast prompt and its Show/Episode context (B:server/src/core/summary/snip.ts:40-45). So the book version needs a new name in the closed `PROMPT_NAMES` list (B:server/src/core/summary/prompts.ts:6) and in `registry.json`, the allowed-names parameter above, and a new routes file registered in `app.ts`.
  - A second candidate the platform check surfaced: iOS 27 adds a Private Cloud Compute model to the same Foundation Models API, with a much larger context window. It needs an Apple entitlement and has eligibility rules that may require App Store distribution. Probe whether a TestFlight-only personal build qualifies before choosing Codex.

### 1.8 Clips and sharing

- **`ClipExporter`** builds an `AVMutableComposition` that inserts the overlapping time range of every track the span crosses. In-track time = book time − `TrackInfo.start` (A:Transcription/Sources/Transcription/TrackInfo.swift:11-14). An `AVMutableAudioMix` adds 30 ms fades in and out. `AVAssetExportSession` with `AVAssetExportPresetAppleM4A` writes AAC `.m4a`, because AVFoundation has no MP3 encoder. The output must be within 250 ms of the requested length (B's rule). Files go to `Caches/SnipClips/<snipID>-r<rev>.m4a`.
  - **Best practice (AVFoundation and the file system):** files you can re-create go in Caches, which iOS may purge. Your data goes in Application Support, which is backed up.
- **Rendering is on demand**, at share time. A has no public page waiting for a clip, so rendering early only costs battery.
- **Audio source: downloaded books only, in both builds, in v1.** The audio comes in through the existing `TranscriptionAudioProvider` protocol (A:Transcription/Sources/Transcription/TranscriptionAudioProvider.swift:25-30), and the app injects `BookAudioProvider`.
  - The daemon's `/audio?item_id&track=N` proxy downloads *whole tracks* (A:Transcription/Sources/Transcription/HostTranscriptSource.swift:246-268). For a single-file `.m4b` that means hundreds of MB for a 90 s clip (Greenlights is one 392 MB file, A:FORK-NOTES.md:405).
  - Streamed books show "Download to share audio". A Range-capable daemon endpoint is a later option.
- **Prerequisite: the app-group lookup in `Models`.** `BookAudioProvider` counts a book as downloaded only when every `Track.localPath` is non-nil (A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/BookAudioProvider.swift:31-35).
  - `Track.localPath` asks for upstream's app group `group.me.jgrenier.audioBS` (A:Models/Sources/Models/Track.swift:84-90). On the fork's device builds the OS refuses that group and returns nil, as the app target's own `AppGroup.swift:3-11` explains. The same hardcode is in `LocalBook.swift:51,67`, `LocalEpisode.swift:36` and `ModelContextProvider.swift:104`.
  - So preview and clips would likely pass on the simulator and fail on the phone.
  - Fix: give the Models package the provisioned id. The `Models` package can't see the app's `AppGroup` enum, so either set it once at launch (a static the app sets) or copy the resolution logic.
  - Confirm on device first. FORK-NOTES:140-151 records the same trap biting the transcript store. This also fixes widget sharing (FORK-NOTES.md:180).
- **Sharing.** `ShareLink` with text (title, quote, "— Book by Author, ch. N, h:mm:ss") in both builds. The `.m4a` is added when you choose to share it. "Export snips" writes Markdown (Readwise-friendly) and `snip-record-v1` JSON.

### 1.9 Store build versus personal build

| Capability | Store build | Personal build |
|---|---|---|
| Capture, heard tracking, selection, editor, JSON store, export | yes | yes |
| On-device titles and summaries | iOS 26 + Apple Intelligence, otherwise fallback titles | same |
| Speaker-aware capture | compiled out | yes |
| Preview and clips | downloaded books | downloaded books |
| Public links or server sync | never | not in v1 (decisions 4, 5) |

`PlayerControl.snip` compiles into **both** builds. Saved layouts are decoded as a whole (A:AudioBooth/AudioBooth/Services/UserPreferences/UserPreferences.swift:329-337): one unknown case turns the whole saved list back into the default. So a build without `.snip` would reset the layout of anyone who had turned Snip on. `.snip` is not a default control, and only enabled controls are saved.

### 1.10 The upstream footprint

| Upstream file | Edit |
|---|---|
| `A:AudioBooth/AudioBooth/Models/PlayerControl.swift:3-36` | `case snip`, plus `displayName` and `systemImage` arms (3 lines). Write the name as `LocalizedStringResource("Snip", table: "Snips")`. A bare `"Snip"` literal would be auto-extracted into upstream's `Localizable.xcstrings` at build time (`SWIFT_EMIT_LOC_STRINGS = YES`), the way `"Transcript"` was |
| `A:…/ControlsLayout/ControlsLayoutPreferencesView.swift:113-124` | `tint` arm. This is the fourth exhaustive switch; two of the proposals missed it (1 line) |
| `A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayer.swift:612-613` + overflow menu + body | `case .snip: SnipControlButton(model:)`, `SnipMenuItems(model:)`, `.snipSheets(model)` (3 lines) |
| `A:AudioBooth/AudioBooth/AudioBoothApp.swift:30-39` | `SnipAppBridge.start()` inside `.task` (1 line) |
| *(optional)* `AddBookmarkIntent.swift:30` | Speaker-correct position (2 lines) |

Edits to Jake-owned files (no upstream conflict): `Transcription/Package.swift`, `TranscriptStore.swift`, `TranscriptSegment+DisplayPieces.swift`, `KaraokeSheet.swift` (banner action, later the tint), `DebugLaunchOptions.swift` (`-autoSnipAfter <s>` for scripted simulator runs).

**Best practice (string catalogs).** Every user-visible string the fork adds names its table:
- `Text("Snip", tableName: "Snips")`, `String(localized:table:)`, and `LocalizedStringResource(_:table:)` in enum arms and App Intent titles. These strings land in the app's `Snips.xcstrings`.
- Strings shown by package code use `bundle: .module` and the package's own catalog.

Upstream's `Localizable.xcstrings` is one of its highest-churn files: 93 commits, against 122 for `BookPlayerModel.swift` (A:FORK-NOTES.md:74-83).

---

## Part 2 — The podcast app goes native

### 2.1 Why a new app, not AudioBooth pointed at B

A's API layer is a concrete `Audiobookshelf.shared`, referenced 197 times across 85 files, built around ABS's play-session semantics. Making it neutral would rewrite the most-changed upstream files. B's server was designed for a native client: bearer tokens, signed media URLs, idempotent writes (B:docs/core/architecture.md:52-66). So a thin new client costs less. The two apps share SnipCore and lessons, not code paths.

### 2.2 Server and edge changes first, ranked

1. **Cloudflare Access is the blocker.**
   - Access covers the whole host except `/s` and `/e` (B:deploy/README.md:72-80). URLSession and AVPlayer cannot complete a Google login.
   - **Step 1 is read-only (probe P1):** open the Zero Trust dashboard, team `schxyz`, and record what is actually configured. The repo only says the app "is meant to sit behind" Access (:74).
   - **Step 2:** add the paths `v1` and `m` to the existing "Podcast player public pages" Bypass application (:78). `/` stays behind Google.
   - **Why bypass rather than a service token:**
     - `/m`'s HMAC signature is already its authentication (B:server/src/services/media.ts:12-23).
     - A service token would mean custom headers on AVPlayer requests. The only way to add them, `AVURLAssetHTTPHeaderFieldsKey`, is undocumented private API. A ships it today (A:AudioBooth/AudioBooth/Screens/BookPlayer/AudioPlayer.swift:711), but a new app shouldn't copy that without deciding to.
     - The public alternative is carrying Access's `CF_Authorization` cookie with `AVURLAssetHTTPCookiesKey`. That adds moving parts, and whether AirPlay receivers would follow it is unverified.
     - `/v1` already requires a live device token on every request except three (B:server/src/http/auth.ts:42-66; exceptions below).
     - It is the origin-side bearer model A's daemon already runs behind the same kind of tunnel (A:FORK-NOTES.md:422-433).
     - It also fixes the web app's "No connection until reload" (B:deploy/README.md:80).
   - **Best practice (Cloudflare Access):** more specific path applications win over the host-wide one. A Bypass app hands authentication to your origin, so the origin must enforce it. Access does not log bypassed traffic, so the origin logs its own auth failures.
   - **What becomes public with the bypass.** Three `/v1` routes skip auth today (B:server/src/http/auth.ts:62-65):
     - `POST /v1/devices` (login);
     - `/v1/openapi.json`, the full API description;
     - `/v1/health`, which reports job-queue counts (B:server/src/http/app.ts:58-59).

     Put the last two behind the device token, or accept them as public knowingly.
   - **Compensating controls:**
     - **A failed-login lockout** in `routes/devices.ts:15`. Today only nginx rate-limits login (6 a minute, burst 5, keyed by `CF-Connecting-IP`; B:deploy/nginx/podcast-player.conf:6-10,28-32).
       - Make it per IP (`CF-Connecting-IP`), in memory, for example 10 failures an hour → 429 for an hour, and log every failure.
       - A *global* lockout would let any stranger lock you out of your own app.
       - It needs no table: a restart clearing it is acceptable for one owner.
     - an `OWNER_PASSWORD` of 20 or more random characters;
     - `verifyMediaSignature` also rejects revoked devices (B:server/src/services/media.ts:18-23 checks only the HMAC and expiry).
2. **Correctness bugs a second client will hit.**
   - `summarizeSnipJob` slices the *revision's* word indices out of the asset's *current* transcript (B:server/src/services/snipJobs.ts:81). The pointer can move when the text policy changes (B:server/src/services/textPolicy.ts:9-19). Fix: load `rev.transcript_id`.
   - **Transport failures are final.** A transport failure in `summarizeSnip` breaks out with the comment "for the job's retry policy" (B:server/src/core/summary/snip.ts:117-121), but the job then writes `failed` permanently (snipJobs.ts:106-114).
     - Fix: rethrow, so the queue's 5 attempts (B:server/src/jobs/queue.ts:38) apply.
     - There is no "retries exhausted" hook to fall back on: `jobs/worker.ts:56-67` has no per-kind failure callback. Without one, a rethrown summary failure would leave the revision `preparing` forever.
     - So add a small `onExhausted` handler per job kind in `worker.ts`. For `summarize_snip`, it writes the fallback title, sets `summary_status = 'failed'`, and still lets the revision become `ready`; a valid clip shouldn't be hidden because Codex was down.
     - For `render_clip`, it sets revision `status = 'failed'`. Today nothing ever writes that value, which `rows.ts:43` declares, so a clip that keeps failing to render leaves its revision `preparing` forever.
   - **Word-index edits.** `editSnip` correctly reads the current transcript for millisecond edits, because the new revision is stamped with that transcript's id (B:server/src/services/snips.ts:160,201-202). The defect is the *word-index* path:
     - a partial word PATCH mixes the old revision's index with the new transcript's word count (:168-169);
     - even a full word PATCH is wrong if the transcript pointer moved after the client loaded it.

     Fix: an optional `transcript_id` precondition on word edits (409 on mismatch), and the native app sends milliseconds only, like the web editor (B:web/src/screens/SnipEditor.tsx:201).
   - **Edits made before a transcript exists are never summarized.** A manual revision made then is marked `skipped` (snipJobs.ts:77,82-84), and `storeTranscript` wakes only revisions in `waiting` (B:server/src/services/transcripts.ts:65-73). Fix: when a transcript lands, the wake path also finds current revisions that are `skipped` with no words. For each one it:
     - recomputes the word range and excerpt from ms with `wordRangeByMidpoint`;
     - resets `summary_status` to `pending`, and restores the `'Snip'` fallback title so the model can replace it;
     - enqueues with `{rerun: true}`, because the `summarize_snip:<rev>` job is already `done` and a plain enqueue does nothing (B:server/src/jobs/queue.ts:59-67).
3. **Offline-safe contract.**
   - `if_revision` is **required** whenever a boundary field is sent (update B:server/test/integration.test.ts:308,363). Without that, a replayed PATCH creates a duplicate revision.
   - DELETE of an already-deleted snip returns 204. Today `getSnipRow` returns 404 (B:server/src/services/snips.ts:39-42,231-233).
   - The ETag adds `title`, `title_source` and `note` (B:server/src/http/routes/snips.ts:22).
   - **Optional `observed_at` on `PlaybackBody`** (B:server/src/http/schemas.ts:74), with resume ordered by it. Today resume uses the time the server *received* the report (B:server/src/services/playback.ts:37-40), so a replay after a flight overwrites newer progress.
     - `playback_state` has no column for it, so this needs a new migration (`0007`) and changes in `reportPlayback` (:21-26) and `resumeFor` (:37-40).
     - The existing index on `updated_at` (B:server/src/db/migrations/0001_init.sql:110) probably wants a twin.
     - Cap `observed_at` at the receipt time, so a phone with a fast clock can't win every comparison.
   - **Optional `captured_at` on `CreateSnipBody`**, which needs a `snip` column in the same migration and a change in `createSnip`.
   - **`transcript_id` on `RevisionSchema`** (B:server/src/http/schemas.ts:77-82), plus `RevisionView`/`toRevisionView` (B:server/src/services/snips.ts:17-22,62-70).
   - After any schema change, regenerate the web client's types with `pnpm --dir web gen:api`.
   - No `audio_url_expires_at` is needed. The signed URL already carries its expiry as the `e` parameter, which the native `SignedURL.expiry(from:)` reads.
4. **Contract artifacts.**
   - A test writes a committed `server/openapi.json` and fails when it is stale.
   - `server/scripts/export-ios-fixtures.ts` reuses the integration test's fake-adapter app to record one real response per endpoint into `ios/Packages/PodcastAPI/Tests/Fixtures/`.
5. **Later.**
   - **`apple-app-site-association`**, the file that turns `/s` links into universal links that open the app. Apple's requirements:
     - Serve it over HTTPS at `/.well-known/apple-app-site-association` with no redirects, as `application/json` (the file has no extension), at 128 KB or less.
     - Apple fetches it through its own CDN, not from the phone. So `.well-known` needs the Access bypass, and no Cloudflare WAF or bot rule may challenge Apple's fetcher.
     - In nginx, use an exact `location = /.well-known/apple-app-site-association` block. Exact matches win whatever their position. The point is to set the Content-Type and caching headers, not to beat the SPA fallback (B:deploy/nginx/podcast-player.conf:51-52).
     - Test TestFlight builds with the `?mode=developer` associated-domains option. Apple's CDN refetches within about a day, and devices about weekly.
   - `GET /v1/devices/me`, APNs push notifications, OpenAPI operationIds and component schemas.
   - Check whether private-feed `episode.link` values carry tokens, and redact them if so (B:server/src/services/episodes.ts:152). Verify this before acting.

**Best practice (Fastify).** Keep the 1 MiB global `bodyLimit` (B:server/src/http/app.ts:19). If a big upload route is ever needed, give that one route its own `bodyLimit` and a matching nginx `location` (site-wide `client_max_body_size 1m`, :23). A hit exactly this trap with its caption worker.

### 2.3 App structure

```
ios/
  README.md  CLAUDE.md (iOS side effects, build/run)  Config/Signing.xcconfig  Config/Local.xcconfig.example
  Snip.xcodeproj                  app target only; file-system-synchronized groups
  Snip/
    SnipApp.swift  AppModel.swift (wires client, engine, outboxes)
    Screens/  Login/ Today/ Library/ FeedEpisodes/ Player/ Snips/ SnipEditor/ Settings/   (View + Model per screen)
    DesignSystem/  Colors.xcassets  Typography.swift  Metrics.swift  Fonts/ (DM Sans/Mono, OFL)
    Intents/SnipIntent.swift
    Debug/DebugLaunchOptions.swift  (reads ~/.config/podcast-player/devauth.json, A's pattern)
  Packages/
    PodcastAPI/  APIClient · APIError · TokenStore (Keychain) · Endpoints+*.swift · Models/*
                 Tests/ DecodeFixturesTests.swift  Fixtures/*.json (written by the server)
    PlayerKit/   PlayerEngine · EngineState · AudioSessionController · NowPlaying · RemoteCommands
                 ResumeMerge · SignedURL
    SyncKit/     FileQueue · PlaybackReporter · SnipOutbox · RetryPolicy · Reachability
  scripts/dev-build-run.sh  scripts/testflight.sh   (ported from A)
```

Dependencies run one way: `App → PlayerKit, SyncKit, PodcastAPI → SnipCore`. Packages never import the app.
- **Best practice (SPM for apps):** put logic in local packages so `swift test` runs it in seconds, and keep the app target to views and wiring.
- **Best practice (SPM for apps):** commit the app's `Package.resolved` (apps commit it, libraries don't).
- **Best practice (SwiftUI):** use `@Observable` models.
- **Best practice (Keychain):** keep the device token in the Keychain, never in UserDefaults.

Minimum iOS 26. A single-user TestFlight app needs no `#available` checks, and SnipCore supports iOS 17 regardless.

### 2.4 How it talks to the server: a hand-written client

- **Why not `swift-openapi-generator`** (despite B:docs/core/architecture.md:62):
  - **Names and duplicate types.** With no operationIds the generator invents names like `get_sol_v1_sol_feeds`, and with no component schemas every operation gets its own nested copy of `Snip`, `Episode` and so on. It works, but it is hard to read.
  - **Word tuples.** Transcript words are tuples (B:server/src/http/schemas.ts:67). TypeBox 0.34 writes these as the old draft-07 `items: [...]` form. That is not valid OpenAPI 3.1, and the generator's supported-features list has no `prefixItems`.
  - **Scope.** v1 needs about 19 of roughly 44 routes.
  - **Readability.** Generated code is hard for a novice to read.
- The word tuple gets a ten-line custom `init(from:)` using an unkeyed container, written once in `SnipCore.Transcript`.
- **Best practice (OpenAPI):** operationIds and named `components.schemas` are optional, but without them generated names are unreadable and change whenever a path changes. Add both, and switch tuples to objects in a v2 transcript shape, before adopting a generator at roughly 40 endpoints.
- **Auth.** A `Bearer` header, which is checked before the cookie (B:server/src/http/auth.ts:30-39). Login uses `platform: "ios"` (schemas.ts:12). One `APIError` type matches the `{error:{code,message}}` envelope (B:server/src/http/app.ts:46-54). Any 401 signs you out.
- **Drift guard.** `DecodeFixturesTests` decodes every recorded server response, so a server shape change fails the iOS tests in the same commit. This is called a consumer contract test.

### 2.5 Player engine port

The source of truth is the *code*, B:web/src/player/engine.ts and heard.ts, not the stale B:docs/core/01-playback.md:68.

| Web | Native |
|---|---|
| status idle/loading/preparing/ready/error; `open()` POSTs `/audio` and polls every 2 s | The same enum in `@Observable @MainActor PlayerEngine`; async `open()` with cancellation |
| `HeardTracker` + 180 s resume assumption | `SnipCore.HeardTracker`; explicit `jump()` on skip, scrub or transcript tap; ticks from the periodic observer |
| `timeupdate` (about 4 Hz) | `addPeriodicTimeObserver` at 1/30 s while the transcript is visible, reading the player's own clock. That is A's measured fix: its highlight trailed by 248 ms because it read a 0.5 s progress value instead of AVPlayer's clock. A small 50 ms lead then cancels tick and render latency (A:FORK-NOTES.md:371-381) |
| `#t=` fragment, `pendingSeek`, `prime()` | Dropped. Wait for `.readyToPlay`, then `seek(to:toleranceBefore:.zero,toleranceAfter:.zero)`. Use `AVURLAssetPreferPreciseDurationAndTimingKey` for VBR MP3 (A:AudioBooth/AudioBooth/Screens/BookPlayer/AudioPlayer.swift:709) |
| Reporter every 15 s and on events; one per-device `seq`; outbox keeps the latest report per asset (B:web/src/player/reporter.ts:14-46) | `PlaybackReporter` with the same rules, persisted by `FileQueue`, flushed on `NWPathMonitor` and on scene `.background` inside `beginBackgroundTask`; sends `observed_at` |
| URL renewal on error or when under 10 min from expiry | `SignedURL.expiry(from:)`; on `.failed` or foreground, swap in a new `AVPlayerItem` at the same time |
| Media Session API | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (play, pause, toggle, skip 15/30, change position) |
| — | **Best practice (AVAudioSession):** category `.playback`, mode `.spokenAudio`, route-sharing policy `.longFormAudio`; handle interruptions; pause on `oldDeviceUnavailable`; `UIBackgroundModes: audio` |
| — | **Media auth decision:** signed URLs only. Do *not* copy A's `AVURLAssetHTTPHeaderFieldsKey` header injection, which is undocumented private API. If a header is ever unavoidable, prefer the public `AVURLAssetHTTPCookiesKey` or an `AVAssetResourceLoaderDelegate` |

**Snip in the native app.**
1. Append `{client_request_id: UUID, asset_id, anchor_ms, heard_from_ms, captured_at}` to `SnipOutbox` and flush.
2. Poll `GET /v1/snips/{id}` every 2 s with `If-None-Match` until the status leaves waiting/selecting/preparing (B:web/src/snips/useSnip.ts:11,50).
3. `RetryPolicy`: drop on any 4xx except 401; keep on 401, 5xx or offline (B:web/src/snips/outbox.ts:61).

`RetryPolicy` is about ten lines. It stays in SyncKit with a comment pointing at `outbox.ts`, so it is not a fixture-checked family.

### 2.6 Screens: v1 versus later

| v1: the listening loop plus snips | Later |
|---|---|
| Login (password → Keychain token) | Wide/foldable two-column layout |
| Today (continue listening, new episodes) | Offline downloads (storage budget) |
| Library → FeedEpisodes (paged) | Universal links rendering `/s` and `/e` from their `.json` twins |
| Player (artwork, chapter scrubber, speed, skip, Snip button, Chapters / Transcript tab with follow and tap-to-seek, using B's simple paragraph view; A's teleprompter is not ported) | APNs "snip ready"; headphone snip; CarPlay; widgets |
| Snip card (waiting/preparing/ready; play clip; edit; copy link) and EpisodeSnips sheet | |
| Snip editor via `SnipCore.SpanPoints`/`WordRange`. It sends boundaries only when they changed, so title-only saves stay in place (B:server/src/services/snips.ts:147-157), unlike the web editor, which always sends them (B:web/src/screens/SnipEditor.tsx:201). It always sends `if_revision` | Prompts and eval admin **stay on the web**: they commit to git on the deploy checkout (B:deploy/README.md:31) |
| Snips list (search, revoke/restore, delete); Settings (sign out) | Add-feed UI |

### 2.7 Distribution and reuse from A

- **TestFlight internal.** Internal testing needs no App Review. A single-owner server with no `owner_id` cannot pass review without handing Apple a demo login.
  - **TestFlight builds expire after 90 days.** A daily-use app needs a re-upload at least every couple of months, which `scripts/testflight.sh` makes a one-liner. Put a recurring reminder somewhere.
  - TestFlight builds use the *production* push environment, which matters later for "snip ready" notifications.
- Team <TEAM_ID>, bundle id `com.example.Snip`, app group `group.com.example.Snip`, all fixed on day one. A still hardcodes upstream's group (A:Models/Sources/Models/Track.swift:86).
- Reuse A's headless pipeline: archive, manual-signing export, `altool` with ASC key `8T35BVZTRK`, and the Set Build Number phase (A:FORK-NOTES.md:520-538).
- **Copy freely (Jake-authored):** `scripts/dev-build-run.sh`, the `DebugLaunchOptions` devauth pattern, `AudioFileType` sniffing, and the `AUDIOBOOTH_FEATURES` lines of the xcconfig.
- **Rewrite rather than copy (upstream's, even though they look like boilerplate):**
  - the Signing/Local xcconfig split (`Signing.xcconfig` still names upstream's team `7MM2M9KD2W` and org `me.jgrenier`);
  - the `.swift-format` / `.pre-commit-config.yaml` setup (upstream's README tells contributors to install it).

  These are small; write fresh ones for B.
- **Read, but rewrite from Apple's docs:** upstream-authored `PlayerManager`, `AudioPlayer`, `NowPlayingManager`, `DownloadManager`. MPL-2.0 is copyleft per file. A new file containing copied MPL code becomes MPL-covered. Whoever receives the app (testers, or App Store users) must then be able to get that file's source, at no more than the cost of distribution. That is not a duty to publish it to the world, but it is a real obligation for a closed app.
- **Verify authorship first.** A's clone in this session is shallow (`git rev-parse --is-shallow-repository` → `true`, 50 commits) and has no `upstream` remote, though CLAUDE.md and A:FORK-NOTES.md:13 describe one. On your Mac:
  1. Run `git remote add upstream https://github.com/AudioBooth/AudioBooth.git` if it is missing, then set its push URL back to `DISABLED`.
  2. Run `git fetch --unshallow`.
  3. Run `git log --follow` on every file before copying or relicensing anything.
- **CarPlay** for the new bundle id needs its own entitlement request to Apple, with lead time. Ask early if you want it in M13.

---

## Part 3 — The shared layer

### 3.1 What is shared, and the rule for adding to it

| Shared | Form | Not shared (each repo owns it) |
|---|---|---|
| Heard tracking, sentencizer, span selection, midpoint word range, span-point rules, summary validator, name guard, fallback title, transcript v1 Codable | Swift `SnipCore` + TS reference | Players, persistence (A: JSON files; B: SQLite), servers |
| Specs, JSON Schemas (`transcript-v1`, `snip-record-v1`, `selection-record-v1`, `summary-output-v1`), porting traps | `contracts/` | Prompt *text* (domain and model differ); only the registry *format* is shared |
| Golden fixtures (synthetic or public-domain only) | JSON in versioned folders | Model adapters (FoundationModels vs Codex), ffmpeg vs AVFoundation |

**Rule of two (clarified, because C stated it and then broke it).** Code enters SnipCore when either:
- (a) both iOS apps use it: HeardTracker, WordRange, SpanPoints, Transcript; or
- (b) it ports a TypeScript reference that must agree with it, in which case the fixtures make the TS code its second consumer: Sentencizer, SpanSelector, SummaryValidator, NameGuard, FallbackTitle, and the summary input mapping (`sentencesForRange`, `precedingSentences`).

**Two references must be extracted in B first.** Each needs a small refactor before `golden:export` can produce fixtures for it:
- **SpanPoints.** The carry-along and minimum-span rules are an inline React closure today (B:web/src/screens/SnipEditor.tsx:151-162). Move them to `web/src/lib/spanPoints.ts`.
- **The summary input mapping.** It lives in a service file (B:server/src/services/snipJobs.ts:129-151). Move it to `server/src/core/summary/input.ts`.

Both moves also serve B's own "no business rules in React" rule (B:docs/core/architecture.md).

Anything else stays in its app: prompt assembly for the book prompt, file stores, outbox queues and retry policy, ULIDs (UUIDs are enough).

### 3.2 Where it lives, and why

```
snipkit/                         github.com/jakeschaeffer/snipkit
  Package.swift                  AT THE ROOT. Products: SnipCore, Contracts
  LICENSE (MIT) · README.md (version table, how to bump) · CHANGELOG.md
  CLAUDE.md                      fixtures synthetic or public-domain only; behaviour change ⇒ new version + new folder
  contracts/                     resources-only target (path: "contracts") exposing Bundle.module
    Contracts.swift  MANIFEST.sha256
    specs/      heard.md selection.md word-range.md span-points.md summary-validation.md
                transcript.md snip-record.md tokens.md porting-traps.md future-sync.md
    schemas/    *.schema.json
    fixtures/<family>/<version>/case-NNN.json   + SOURCE.json (generator repo + commit SHA)
  Sources/SnipCore/  Common/ Transcript/ Heard/ Selection/ Editing/ Summary/  Versions.swift
  Tests/SnipCoreTests/            one file per family; each loops over its fixture folder
  scripts/check-frozen.sh         fails if a released fixture folder changed
```

- **Why a third repo.**
  - Swift Package Manager clones a remote dependency and expects `Package.swift` at the repository root.
  - A's root has none, and putting it in A would make it MPL by convention.
  - Putting it in B would make A depend on B's private, unlicensed repo, and every A build would clone B's server and web code.
  - Fallback if you say no: a root `Package.swift` in B whose targets use `path: "swift/…"`.
- **Why Foundation-only.** `swift test` then runs on Linux too, including cloud sessions like this one when a Swift toolchain is installed. So no CryptoKit in SnipCore: manifest hashing happens in `scripts/` with `shasum -a 256 -c`.
- **Platforms.** `iOS 17, watchOS 10, macOS 14`, no higher than its consumer Transcription (A:Transcription/Package.swift:10-16).
  - **Best practice (SPM):** a dependency must not require a newer OS than the package that uses it, or the build fails.

### 3.3 License

**MIT, and every line in it is yours.**
- The B code is yours and unlicensed.
- Ported A code comes only from Jake-authored `Transcription/*`, verified on unshallowed history. You can relicense your own contributions.
- MIT files can sit inside A's MPL "Larger Work" and inside closed B without changing either.
- No upstream-authored A code may enter `snipkit`.
- *Decision note:* proposal A suggested MPL so snips could go upstream. MIT keeps that option, since MIT code can be contributed under MPL, and carries no source-publishing duty for the closed B app.

### 3.4 How each repo consumes it

- **A:** `.package(url: "https://github.com/jakeschaeffer/snipkit.git", exact: "0.x.y")` in `Transcription/Package.swift`, next to swift-log's existing exact pin (:24).
  - Only `Snips` depends on `SnipCore`. `TranscriptionTests`/`SnipsTests` also depend on `Contracts`, so fixtures never ship in the app.
  - A's `.gitignore:11` ignores `Package.resolved`, which makes the `exact:` pin the only pin. Hence "exact".
- **B iOS:** `ios/Packages/*/Package.swift` pin the same tag. B's TypeScript reads a vendored copy: `scripts/sync-contracts.sh v0.x.y` copies `contracts/` into a committed `B:contracts/` with a `VERSION` file. The path sits outside the gitignored `evals/**/fixtures/` (B:.gitignore).
- **Changing SnipCore:** work in `snipkit` against its own fixture tests. Tag a prerelease (`0.3.0-beta.1`) to try it in an app, then tag the final version. `scripts/bump-snipkit.sh 0.3.0` in each app edits the one line.
- **Best practice (SPM):** exact pins plus semantic version tags give reproducible builds, and upgrades become deliberate one-line changes.
- **Decision note: sibling path versus remote pin.** Proposal A's `../../snip-core` path dependency is simpler day to day, and two judges liked it. I chose a remote pin anyway:
  - every fresh clone, cloud session and headless TestFlight archive builds with no three-repo checkout;
  - the exact version is recorded with no extra build-stamping;
  - SnipCore changes rarely once ported, because every behaviour change is a version bump anyway.
- **Public, not private, by default.** It holds only synthetic data. A private SwiftPM dependency needs git credentials in headless `xcodebuild` and in cloud sessions (probe P5 checks this, only if you choose private).

### 3.5 Keeping TypeScript and Swift identical

1. **One reference implementation per family, named in its spec.**
   - B's TS for heard, sentencize, select, word range, span points, summary validation, name guard and fallback title.
   - A's Swift `EbookAlignment` for `align` and `tokens`, when the TS aligner lands (Part 4).
2. **Generators produce the fixtures; humans review them; then they are frozen.**
   - `pnpm --filter @podcast-player/server golden:export --out ../snipkit/contracts/fixtures` runs the TS reference over synthetic inputs and writes `SOURCE.json` with B's commit SHA. The Swift test prints that SHA on failure.
   - For A-born families, an env-gated Swift test in A writes the fixtures.
3. **Released version folders never change.** `check-frozen.sh` (snipkit CI) and B's `contracts.test.ts` both verify `MANIFEST.sha256`.
   - A behaviour change therefore means: new version string (`select_v3`), new folder (old one kept, so old eval numbers stay reproducible), the TS change passes, the Swift change passes, tag, bump both pins.
   - A TS change without a new version fails B's plain `pnpm test`.
4. **Version strings travel in every output** (`selection.version`, `summary_prompt_version`), so A's results stay comparable with B's evals.
5. **Fixture inputs.**
   - Pseudo-random synthetic prose from a fixed seed, the same "LCG" technique as A's alignment tests (A:Transcription/Tests/TranscriptionTests/EbookAlignmentTests.swift:9-50), plus hand-written edge cases.
   - Public-domain realism: Gutenberg text with LibriVox narration, committing only the derived word JSON.
   - Never real books or private feeds.
6. **Porting traps** (`porting-traps.md`, each covered by at least one fixture):
   - JS `.length` counts UTF-16 units; Swift `count` counts characters. Use `.utf16.count` for the 60/320 limits.
   - The word midpoint `(s + e) / 2` is a float in JS (B:server/src/core/snip/select.ts:259). In Swift, integer division truncates, so convert to `Double`.
   - `Math.round` and Swift `.rounded()` differ only for negative halves. Inputs are always ≥ 0, so the spec says so.
   - Regex classes: names.ts uses `\p{L}`, `\p{Lu}`, `\p{Ll}` (B:server/src/core/summary/names.ts:10,27). `split(/\s+/)` treats non-breaking spaces as whitespace, so include an NBSP fixture.
   - `normalizeToken` keeps ASCII `[a-z0-9']` only and drops accented letters (B:server/src/core/transcript/tokens.ts:2-8). Swift must not use `isLetter`.
   - Sentence ids are positions in the returned list, not stored ids.
   - Sorting: both languages' sorts are stable (Swift documents `sorted(by:)` as stable; JS since ES2019). The trap is the comparator. JS returns a number, Swift returns a strict "a comes before b" Bool, so `a <= b` in Swift is a bug. Keep an explicit tie-breaker (the original index) anyway, so the spec doesn't depend on stability.
   - The sentencizer reads 120 s beyond the requested range, so windows must include it (§1.5).
   - Heard ticks sampled at 250 ms and at 1 s must give the same `heard_from_ms` on the fixture sequences.

### 3.6 The documented future path (not v1)

If you ever want audiobook snips on B's server (decisions 4, 5), `future-sync.md` records the route, so nothing in v1 blocks it:
- **Each snip carries its own immutable transcript window,** about 25 KB, uploaded with the snip. This avoids whole-book ingestion, the 1 MiB body limits, ElevenLabs' 10 h per-request cap and about 1.1 GB of disk per book.
- **A `'private'` `share_state`** that public routes answer with 404, plus an explicit `POST /v1/snips/{id}/publish`. Today `'active'` is a literal in the INSERT (B:server/src/services/snips.ts:123).
- **`reanchor` revisions** map onto `snip_revision` one to one, and the UUID becomes `client_request_id`.
- **Migration runner caveat.** Generalizing `audio_asset` means rebuilding a parent table.
  - SQLite's documented rebuild procedure needs `foreign_keys=OFF` set *outside* a transaction.
  - B's runner turns foreign keys on and wraps every migration file in `db.transaction` (B:server/src/db/index.ts:18,32-35). So that migration needs a runner escape hatch and a `PRAGMA foreign_key_check` gate, rehearsed on a copy of the production database.
  - `storeTranscript` would also need a new `source` value. It allows only `asr|email|rss` today (B:server/src/services/transcripts.ts:43-44).

---

## Part 4 — Compounding learnings

### A → B (operational habits and algorithms)

- **`B:CLAUDE.md`** listing real side effects, the way A's does:
  - ElevenLabs bills about 22–23¢ per audio hour;
  - playing an untranscribed episode of an `auto_process` feed queues *paid* transcription (B:server/src/services/playback.ts:27-31);
  - a snip on an untranscribed asset does too (B:server/src/services/snipJobs.ts:32-35);
  - each summary spends Codex quota;
  - the Prompts screen and eval runs commit to `master` on the deploy checkout (B:deploy/README.md:31);
  - stop the systemd unit before `pnpm dev`;
  - private fixtures are gitignored;
  - the verified Cloudflare state.
- **`B:NITPICKS.md`** seeded from the drift list below, and **`B:docs/LESSONS.md`** as a dated log in FORK-NOTES style.
- **A pre-commit hook in B** using the same framework as A: `pnpm -r typecheck && pnpm -r test`, plus `check-contracts`. Add a `test` script and vitest to `web` (B:web/package.json:7-13 has none), starting with `heard.test.ts` from the shared fixtures.
- **The precise clock.** Drive the web transcript highlight from a `requestAnimationFrame` loop reading `audio.currentTime` with a 50 ms lead. A measured 248 ms mean lag from coarse ticks (A:FORK-NOTES.md:371-381).
- **Free publisher-text alignment (M12).** Port A's unique n-gram anchors + longest increasing subsequence + bounded Needleman–Wunsch, with its refusal gates (A:Transcription/Sources/Transcription/EbookAlignment.swift), to `B:server/src/core/align/alignTextToAsr.ts`. It times publisher text against the Scribe words B already paid for. Keep ElevenLabs forced alignment (about 22¢/h) only as the fallback. Accept it if `compare.ts` on B's 58 episodes shows word-start p90 within 30–40 ms of forced alignment.
- **Ranked text tiers.** Turn `textPolicy`'s two-way choice (B:server/src/services/textPolicy.ts:9-19) into an explicit ranked provenance, like A's `TranscriptProvenance`.

### B → A (evaluation discipline)

- **An `A:evals/` tree**, each folder with a README, dated `results/*.md` scorecards and gitignored private cases:
  - `snip-selection/`: cases from `snip-edits.jsonl`, plus Kindle highlights located in ebook-aligned text. Kindle highlights carry book locations, not times, so match them by text.
  - `snip-titles/`: on-device titles against your titles, scored by B's judge.
  - `transcription/`: WER and word-start agreement per tier on Greenlights, via B's `compare.ts` on exported JSONL.
- **A prompt registry in A.** Move `CleanupSession`'s inline prompt to `Resources/prompts/cleanup/v1.md` (declared with `.copy`) under the hash test, and derive `afm/cleanup-v1` (CleanupSession.swift:262) from the registry.
  - **Re-cleaning after a version bump needs a source of raw text.** Today the queue skips anything above `hostRaw` (CleanupSession.swift:146-149), so a bump never re-cleans. Simply widening the filter would be wrong: `upsert` keeps one blob per chunk (A:Transcription/Sources/Transcription/TranscriptStore.swift:184-197), so once a chunk is cleaned, its raw ASR and word timings are gone from the phone.
  - A re-clean must re-fetch raw text from the server, which keeps `.superseded-{tier}.jsonl` (A:FORK-NOTES.md:280-286), or re-transcribe on device.
- **Model seams.** `SummaryModel`/`CleanupModel` protocols with fakes. Use a fresh session per batch.
  - Move the pure `acceptable()` guard (CleanupSession.swift:269-278) into its own plain file, so `swift test` covers it.
  - The whole of `CleanupSession.swift` sits under `#if canImport(FoundationModels) && os(iOS)` (line 1) and imports UIKit. The `os(iOS)` part is why none of it compiles on the Mac.
- **Per-function specs with a status table** in `A:docs/snips/`, mirroring B:docs/core.
- **B's "ignore an older `seq`" rule** (B:server/src/services/playback.ts:19) applied to daemon WebSocket frames, which closes A:NITPICKS.md:12-15.

### Duplicated subsystems

- **Unify through the contract:**
  - HeardTracker (three copies become one reference plus one port);
  - span selection;
  - summary validation;
  - the transcript JSON;
  - token normalizers (three) into one `tokens_v1`;
  - aligners (four) into one spec with two implementations.
- **Deliberately not unified:** players, persistence, servers, the summarizer runtime, the karaoke renderer.
- **Don't build B's local-Whisper fallback.** If you ever need one, call A's existing faster-whisper caption worker rather than adding another transcription path.

### Process, so future sessions inherit this

- **A "Cross-repo" section in all three CLAUDE.md files:** what lives in `snipkit`, the change-a-family loop (§3.5 step 3), and "never put a `Snip*` import in PlayerManager/BookPlayerModel/AudioPlayer".
- **Each probe ends in a dated note:** A results in FORK-NOTES, B results in `B:docs/LESSONS.md`.
- **`snipkit/README.md`'s version table** says which app runs which tag.

---

## Roadmap

Sizes for a novice working with Claude: **S** ≤ 1 day, **M** 2–5 days, **L** 1–3 weeks. Tracks: **A**, **B**, **K** (snipkit). Recommended order: M0 → M1a → M2 → M3 alongside M4 → M1b → M5 → M6 → M7 → M8 → M9 → M10 → M11 → M12.

| # | Milestone | Size | Acceptance check | Unblocks |
|---|---|---|---|---|
| M0 | **Docs truth pass** (A+B): fix A:CLAUDE.md:17 (iOS 17) and A:FORK-NOTES.md:309-310; add `B:CLAUDE.md` and `NITPICKS.md`; fix B's 01-playback heard section and README status | S | `grep "heard_from = to"` finds nothing in B docs; B:CLAUDE.md names the paid side effects | Safe agent work in B |
| M1a | **Quick probes**, a dated note each. **P1** Cloudflare dashboard, read only. **P3** punctuation inside SpeechTranscriber timed runs (one on-device chunk). **P4** `.m4a` export across two tracks (macOS test with generated tones + one device run). **P6** your book-highlight lengths vs 90 s. **P7** on the phone, does `BookAudioProvider` see a downloaded book? (the app-group check, §1.8) | S | P3/P4/P6 recorded with numbers; P1 records the live Access apps and paths; P7 yes/no | M4, M5 variant choice, M11 |
| M1b | **P2 on-device model bench** (A): DEBUG `-snipSummaryBench`, 30 local excerpts, two paths (`@Generable` default guardrails; String output with `.permissiveContentTransformations`) → JSONL → B's validator and title judge | M | Recorded per path, with OS and model version: % passing validation, % refusals, p50 latency, mean judge score | Decision 6, M9 |
| M2 | **snipkit v0.1** (K+B): repo, MIT, CLAUDE.md, CI (Ubuntu `swift test` + `check-frozen`); `transcript-v1`; HeardTracker, WordRange, SpanPoints, FallbackTitle; B's `golden:export` + `contracts.test.ts`; first web vitest | M | The same fixture folder passes in TS and Swift; changing `MERGE_GAP_MS` on one side alone fails | M3, M7 |
| M3 | **A capture v1**: position source, heard service, `PlayerControl.snip` + overflow + karaoke entries, `SnipIntent`, JSON store, fixed-span revision with excerpt and fallback title, card, list, edit log, `-autoSnipAfter` | M | Sim: open Goblet via `audiobooth://open/f4f72906-…` (local playback only; terminate after); play 60 s, skip +30 s, play 20 s, snip → `heard_from_ms` = post-skip position ±250 ms; survives relaunch; a corrupt file shows the "couldn't be read" row and the rest load; The Dog Stars gives "Chapter · time"; `AUDIOBOOTH_FEATURES=""` builds; switching builds keeps the saved layout; `grep -E "Speaker|Snip"` on PlayerManager/BookPlayerModel/AudioPlayer shows no new hits; `git diff <pre-snips commit>..HEAD --stat` changes at most 4 files outside `Transcription/`, `Screens/BookPlayer/Snips/`, `Services/Snips/`, `Karaoke/` and `docs/`; `git diff` shows no new keys in `Localizable.xcstrings` | M6, eval data |
| M4 | **B server for native** (alongside M3): P1 bypass change; lockout; signature revocation; §2.2 items 2–4 | M | From a phone with no Access cookie, `GET /v1/feeds` with a bearer token → JSON, and without one → a 401 JSON envelope, not Access HTML; a Range request on a signed `/m` URL → 206; `/` still redirects to Google; an `app.inject` integration test shows the 11th failed login from one IP → 429 while another IP still logs in (nginx's own limit would also give a 429, so a live test proves nothing); replayed boundary PATCH → 409, not a duplicate; title edit changes the ETag; summary test with a moved transcript pointer cites the original; a summary job that exhausts its retries ends `ready` with the fallback title | M7, M10 |
| M5 | **snipkit v0.2**: `sentencizer_v1` + `select_v2` (deterministic), ≥ 30 fixtures (short exception, `min_relaxed`, fixed fallback, no-punctuation, window-margin) | M | Swift `Selection` equals TS field for field (start/end ms, word range, method, chosen ids, version) | M6 |
| M6 | **A selection + editor**: Models app-group fix (if P7 failed), shared chunk-import helper, `TranscriptWindow` (T−360 s…T+120 s), `timedTokens`, `chunkInfo`, waiting→ready, editor, own-AVPlayer preview, revisions, reanchor | L | A test commits an ebookAligned chunk over hostRaw → ms unchanged, quote frozen, "Better text available" shown, Update quote → rev 2 `reanchor`; a word tap sets In on measured text and snaps on interpolated; preview leaves main-player position and ABS progress untouched; smooth scrolling on the oldest supported phone | M9, M11 |
| M7 | **B native v0.1, listening**: ios/ scaffold, PodcastAPI + recorded fixtures, PlayerKit, reporter, screens Login → Player, TestFlight internal | L | B:docs/core/01-playback.md:96 device checklist (first audio < 10 s; resume within 2 s from web and back; 30 min locked with AirPods, a call, a route change); paused 25 h then play renews the URL; 10 min in airplane mode → resume equals the newest *observed* position | M10, daily use |
| M8 | **snipkit v0.3**: SummaryValidator, NameGuard, countSentences, UTF-16 traps | S | Both sides pass, including the misfire cases behind B's 59a9550 fix | M9 |
| M9 | **A on-device titles and summaries** (or server fallback, per P2) | M | macOS tests pass with the fake model; refusal → fallback + reason; model unavailable → stays `pending` and finishes on foreground; pre-iOS-26 → `unavailable` | M12 |
| M10 | **B native v0.2, snips**: button, outbox, ETag polling, EpisodeSnips, list, editor | M | 3 snips in airplane mode → exactly 3 on the server (a replayed POST returns HTTP 200 instead of 201, with the same snip id); stale edit → 409 message; title-only save creates no new revision | Parity with the PWA |
| M11 | **A clips, share, export, karaoke tint** | M | 90 s span across a track boundary → `.m4a` within 250 ms, no clicks; streamed book shows "Download to share audio"; before/after screenshots show no rewrapped lines | M12 |
| M12 | **Evals both ways + B `alignTextToAsr`** | M | Dated scorecards committed: A selection no-edit rate, titles at caps 60 vs 80 vs B's 3.61, Greenlights tiers; a written decision on B's forced-alignment spend | Tuning, prompt v2s |
| M13 | **Later**: universal links (AASA + `.well-known` bypass), APNs, downloads, wide layout, lock-screen bookmarkCommand snip (probe first), CarPlay (request the entitlement early), optional sync via §3.6 | L | Per feature | — |

---

## Decisions for you

| # | Decision | Recommended default | If you choose otherwise |
|---|---|---|---|
| 1 | Third repo? | Yes: `snipkit`, **public**, MIT | Private: run P5 and set up git credentials for headless archives and cloud sessions. No third repo: a root `Package.swift` in B, and A builds clone all of B |
| 2 | Cloudflare for native | Bypass `v1` and `m` (later `.well-known`); keep `/` behind Google; per-IP lockout, strong password, auth on `/v1/openapi.json` and `/v1/health` | Service token for `/v1`: one or two custom headers per request (A's `customHeaders` pattern). After the first two-header request, Access hands back a `CF_Authorization` cookie that AVPlayer could carry via `AVURLAssetHTTPCookiesKey`. Single-header mode and Cloudflare's new strict service-token mode issue no cookie, so `/m` would still need the bypass |
| 3 | Podcast app distribution | TestFlight internal | App Store: `owner_id` across every table, a demo account, App Review |
| 4 | Public audiobook snips? | Never in v1; private text or file share only | Build §3.6 (private state, publish route, runner work) and write down the rights decision first |
| 5 | Where audiobook snips live | Local JSON + export | Sync to B: windows, a new transcript source, migration runner work (L) |
| 6 | On-device or server summaries | On-device; server only if P2 shows < 70% pass or > 20% refusals on both paths | Server always: Codex quota per book snip, personal build only. Or Apple's iOS 27 Private Cloud Compute model, if a TestFlight personal build is eligible (probe) |
| 7 | Title cap | 60 in v1; eval 60 vs 80 at M12 | Starting at 80 loses direct comparison with 3.61 |
| 8 | Span length for books | `select_v2` defaults (30/90/180 s) | Changing needs P6 data and a new version string |
| 9 | Native app minimum iOS | 26 | 17/18: availability gates throughout |
| 10 | Bundle id and app group | `com.example.Snip`, `group.com.example.Snip` | Choose now; changing later breaks the Keychain and groups |
| 11 | API client | Hand-written + recorded fixtures | Generator: add operationIds and components first |
| 12 | Snips for ABS podcasts in A | No | Needs podcast transcripts in A; splits your data |
| 13 | Persist heard state across launches | No (180 s assumption, both apps) | A new `heard_v2` in both TS and Swift |
| 14 | Raise A's floor to iOS 18 | No; keep 17 for upstream parity | Fewer gates, more upstream divergence |

---

## Bugs and doc drift found along the way

**A (audiobooth-fork)**
- [ ] A:CLAUDE.md:17 says deployment target iOS 18. The app target is 17.0 (A:AudioBooth/AudioBooth.xcodeproj/project.pbxproj:930,973).
- [ ] A:FORK-NOTES.md:309-310 says ebook-aligned tiers have no word timings. They keep them at ≥70% exact match (A:Transcription/Sources/Transcription/EbookAlignment.swift:156-159).
- [ ] A:FORK-NOTES.md:169 heading "TestFlight (not yet wired)" contradicts :520 "established 2026-07-31".
- [ ] A:AudioBooth/AudioBooth/AppIntents/AddBookmarkIntent.swift:30 captures a frozen local position while the WiiM plays, rounded up to whole seconds (A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayerModel.swift:356-359).
- [ ] A:Transcription/Sources/Transcription/CleanupSession.swift:161 reuses one `LanguageModelSession` across all batches.
- [ ] A:Transcription/Sources/Transcription/CleanupSession.swift:146-148 means a prompt-version bump never re-cleans already-cleaned chunks.
- [ ] A:Transcription/Sources/Transcription/CleanupSession.swift:269-278: the pure drift guard sits inside the FoundationModels gate and is untested.
- [ ] A:Models/Sources/Models/Track.swift:86 hardcodes upstream's app group. So do `LocalBook.swift:51,67`, `LocalEpisode.swift:36`, `ModelContextProvider.swift:104` and five widget files. On device builds `Track.localPath` therefore returns nil, which very likely makes `BookAudioProvider` treat every downloaded book as not downloaded. Confirm on the phone (probe P7).
- [ ] A:FORK-NOTES.md:13 and CLAUDE.md describe an `upstream` remote. A fresh clone (like this session's) has only `origin`, so add a one-line "re-add upstream" recipe.
- [ ] A:NITPICKS.md:12-15: daemon frames have no sequence number (apply B's `seq` rule).

**B (podcast-player)**
- [x] B:server/src/services/snipJobs.ts:81: summary reads the asset's current transcript instead of `rev.transcript_id`. *(fixed on podcast-player branch `claude/native-app-prep`, bff796a)*
- [x] B:server/src/core/summary/snip.ts:117-121 with B:server/src/services/snipJobs.ts:106-114: transport failures fail summaries permanently instead of retrying. The fix also needs a retries-exhausted hook in B:server/src/jobs/worker.ts:56-67 (§2.2). *(fixed on podcast-player branch `claude/native-app-prep`, bff796a)*
- [x] B:server/src/services/snips.ts:168-169: a partial word PATCH mixes the old revision's indices with the current transcript's word count. A full word PATCH has no `transcript_id` precondition. Latent today, since the web editor only sends ms. *(fixed on podcast-player branch `claude/native-app-prep`, ef6e574)*
- [x] B:server/src/services/snipJobs.ts:77,82-84 with B:server/src/services/transcripts.ts:65-73: manual revisions made before a transcript exists are never summarized. The wake needs `{rerun: true}` (B:server/src/jobs/queue.ts:59-67). *(fixed on podcast-player branch `claude/native-app-prep`, bff796a)*
- [x] B:server/src/jobs/worker.ts:56-67: no per-kind handler when retries run out, so nothing ever writes revision `status = 'failed'` (declared at B:server/src/db/rows.ts:43). A `render_clip` that keeps failing leaves its revision `preparing` forever. *(fixed on podcast-player branch `claude/native-app-prep`, bff796a)*
- [x] B:server/src/http/auth.ts:62-65: `/v1/openapi.json` and `/v1/health` skip auth. That is harmless behind Access, but public once `/v1` is bypassed. *(fixed on podcast-player branch `claude/native-app-prep`, 63104cf)*
- [x] B:server/src/http/routes/snips.ts:22: ETag ignores title, title_source and note. *(fixed on podcast-player branch `claude/native-app-prep`, ef6e574)*
- [x] B:server/src/services/snips.ts:231-233: a replayed DELETE returns 404. *(fixed on podcast-player branch `claude/native-app-prep`, ef6e574)*
- [x] B:server/src/services/playback.ts:37-40: resume is ordered by server receipt time. *(fixed on podcast-player branch `claude/native-app-prep`, ef6e574)*
- [x] B:server/src/services/media.ts:18-23: signed media URLs ignore device revocation. *(fixed on podcast-player branch `claude/native-app-prep`, 63104cf)*
- [x] B:server/test/integration.test.ts:308,363: boundary PATCHes without `if_revision` (update when the requirement lands). *(fixed on podcast-player branch `claude/native-app-prep`, ef6e574)*
- [ ] B:web/public/sw.js:16-18: navigations to `/e/` overwrite the cached app shell.
- [x] B:web/package.json:7-13: no test script; the web client has zero tests. *(fixed on podcast-player branch `claude/native-app-prep`, e7455ac)*
- [x] B:docs/core/01-playback.md:68 says `seek(to) → heard_from = to`. The code keeps merged intervals (B:web/src/player/heard.ts:5-7); B:web/README.md:53-54 has the same drift. *(fixed on podcast-player branch `claude/native-app-prep`, e7455ac)*
- [ ] B:README.md:3: status says no web client or deployment.
- [ ] B:docs/core/architecture.md:13 lists adapters that don't exist (`whisper-local.ts`, `llm-api.ts`, `ffmpeg.ts`); :19 and :62 promise a generated client.
- [ ] B:evals/transcription/README.md:7: "about 12 cents per hour" should be about 23¢ ($7.44 / 32.4 h).
- [ ] B has no CI, no hooks, no LICENSE. *(CLAUDE.md added on `claude/native-app-prep`.)*
- [ ] Policy note, not a bug: B:server/src/services/snips.ts:123 auto-publishes every snip (`'active'` literal).

---

## Appendix: evidence (open these first)

**A, snip-critical**
- A:Transcription/Sources/Transcription/TranscriptStore.swift:120-149 (quarantine), :184-197 (whole-blob upsert), :220 (`segments`), :256 (`chunkProvenances`)
- A:Transcription/Sources/Transcription/TranscriptSegment+DisplayPieces.swift:76-92 (`displayTokens`)
- A:Transcription/Sources/Transcription/EbookAlignment.swift:153-160 (70% rule)
- A:Transcription/Sources/Transcription/CleanupSession.swift:143-166, :262, :269-278 (on-device model precedent)
- A:Transcription/Sources/Transcription/TranscriptionAudioProvider.swift:25-30; TrackInfo.swift:11-14; HostTranscriptSource.swift:246-262
- A:Transcription/Package.swift:17-24; A:AudioBooth/AudioBooth.xcodeproj/project.pbxproj:23,401,930,973
- A:AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayer.swift:269-316 (position expression), :612-613 (`controlButton`)
- A:AudioBooth/AudioBooth/Models/PlayerControl.swift:3-40; ControlsLayoutPreferencesView.swift:113-124; UserPreferences.swift:329-337
- A:AudioBooth/AudioBooth/Screens/BookPlayer/Karaoke/SpeakerSessionManager.swift:8,180; SpeakerSessionModel.swift:69-71; KaraokeSheet.swift:199,1134; KaraokeSheetModel.swift:148-168
- A:AudioBooth/AudioBooth/AudioBoothApp.swift:30-39; A:AudioBooth/Signing.xcconfig:14-17; A:Models/Sources/Models/ModelContextProvider.swift:74-85
- A:FORK-NOTES.md:72-107 (upstream policy), :339-347 (speaker position, seek-is-play), :371-381 (clock lag), :418-433 (tunnel auth), :520-538 (TestFlight)

**B, snip-critical**
- B:server/src/core/snip/select.ts:12,32-43,98,104-120,244-267; sentencize.ts:32,40-65
- B:server/src/core/summary/snip.ts:18,56-124; names.ts:9-56; prompts.ts:6,10; B:server/prompts/registry.json
- B:server/src/core/clip/render.ts:11-12; B:server/src/core/transcript/tokens.ts:2-8
- B:server/src/services/snips.ts:39-42,115-130,140-200,231-233; snipJobs.ts:30-45,75-117; transcripts.ts:43-73; textPolicy.ts:9-19; playback.ts:14-43; media.ts:12-23
- B:server/src/http/schemas.ts:8-16,67-93; routes/snips.ts:20-35; auth.ts:30-66; app.ts:19,46-59; B:server/src/db/index.ts:14-39; B:server/src/jobs/queue.ts:38,59-67; worker.ts:56-67
- B:web/src/player/heard.ts:1-93; engine.ts:47,51,225; reporter.ts:6-46; B:web/src/snips/outbox.ts:55-66; useSnip.ts:11-50; B:web/src/screens/SnipEditor.tsx:18-19,201
- B:deploy/README.md:31,72-80; B:deploy/nginx/podcast-player.conf:6-35,51-52
- B:evals/snip-selection/README.md:76-90; B:evals/snip-titles/README.md:52-54; B:docs/core/01-playback.md:68,96; B:docs/core/architecture.md:13,19,52-66