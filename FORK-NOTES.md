# Fork notes

This is a private fork of [AudioBooth/AudioBooth](https://github.com/AudioBooth/AudioBooth) that adds
karaoke-style, position-synced transcript playback backed by services on the TrueNAS box (the
`abs-session` daemon on `:8788` and the `abs-caption-worker` on `:8790`, both tailnet-only; server
code lives in `you@your-nas:/path/to/abs-session`).

## Remotes

| remote | URL | purpose |
|---|---|---|
| `origin` | `github.com/jakeschaeffer/audiobooth-fork` (private) | our work |
| `upstream` | `github.com/AudioBooth/AudioBooth` (public) | pull-only; push URL is set to `DISABLED` so nothing can land there by accident |

The fork is a mirror-push, not a GitHub fork: GitHub forks of public repos are always public, and this
repo needed to be private.

## The diff surface, and why it's shaped this way

Everything new is **additive** where possible — `Transcription/` (SPM package),
`Screens/BookPlayer/Karaoke/`, `Services/DebugLaunchOptions.swift` (DEBUG-only), `scripts/`, this
file. The "only four upstream files modified" era ended with the speaker mirroring and menu work:
as of 2026-07-30 the fork modifies **44 upstream files** (measured against merge-base `233f81c`),
of which ~24 are mechanical identity (branding rename, app-group indirection one-liners) and ~20
are functional. The principle stands in weakened form: keep existing-file diffs *small and
anchored*, and keep every subsystem's bulk in additive files. Small existing-file diffs are what
make upstream rebases cheap and the eventual upstream PR reviewable (MPL-2.0 is file-level
copyleft — modified files stay MPL, and the self-contained package keeps the license surface
obvious). Deliberately **not** done: stripping RevenueCat/KSCrash/Readium/RichText. Removing them
would fight the PR goal and buy nothing — they're inert on our feature path.

**Engine seams (2026-07-30, the upstream-decoupling refactor):** the transcription engine no
longer knows the daemon exists. `DeviceTranscriptionSession` consumes a `TranscriptionAudioProvider`
(tracks + audio, with an `isTemporary` flag so a downloaded book's files are never deleted) and an
optional `RemoteTranscriptService` (JIT chunk source, `bestProvenance`, provenance-labeled upload);
`CleanupSession` takes the same optional remote; `TranscriptStore` takes the app-group id instead of
hardcoding upstream's; `TrackInfo` is a top-level engine type; the pure planning half (resume,
silence backfill) lives in `TranscriptionPlan` where `swift test` finally reaches it. **All daemon
glue is one file** — `DaemonRemoteService.swift` (plus the clients it wraps): an upstream
distribution of the package is this tree minus that file and the daemon clients. App-side, audio
comes from `CompositeAudioProvider` (downloaded books' own files first — no network — falling back
to the daemon's authenticated proxy), and the server-job UI in `KaraokeSheetModel` sits in
`FORK-BEGIN(server-jobs)` fences keyed off `remote as? RemoteTranscriptionJobService`. A server-less
build is `remote = nil` + `BookAudioProvider()` and every surface degrades by design.

## Tracking upstream over time

Upstream is active (multiple commits a week) and its README warns explicitly: **main may be rebased
and force-pushed.** That dictates the workflow:

- **Rebase, never merge.** A merge-based update against a rewritten upstream/main produces duplicate
  commits and a permanently confusing history. Our commits replay cleanly on top of whatever
  upstream/main currently is:

  ```sh
  git fetch upstream
  git rebase upstream/main        # replays our small commit stack
  ./scripts/dev-build-run.sh      # build + launch in the simulator
  (cd Transcription && swift test)
  git push --force-with-lease origin main
  ```

  `--force-with-lease` is required after a rebase and safe on a single-user private repo.

- **Use `scripts/sync-upstream.sh`.** It previews the incoming commits and — the important part —
  the overlap set (files changed on *both* sides since merge-base) before asking to rebase, runs
  the verification gauntlet after, and prints the force-push command instead of running it.
  Cadence: sync when upstream ships something wanted or after ~4 weeks of drift, whichever first —
  upstream churns exactly the surfaces we integrate with (player chrome, context menus,
  localization), and long gaps compound.

- **What will conflict, in practice** (measured 2026-07-30: upstream commit counts over its last
  ~200 against the files we modify):
  - `Localizable.xcstrings` (93 upstream commits — highest churn): **never hand-merge.** Take
    upstream's wholesale, re-run the brand rename over *values* (AudioBooth → AudioBook Karaoke,
    never keys), then re-add the fork's feature keys.
  - `project.pbxproj` (39) — the most fragile file; any upstream target/package change can collide.
    If a conflict is unreadable, don't fight it: take upstream's version wholesale and re-apply our
    wiring by hand. It is six insertions, each mirroring the adjacent `Models` entry: a
    `PBXBuildFile`, a `PBXFileReference` (`path = ../Transcription`), the packages group entry, an
    `XCSwiftPackageProductDependency` (productName only — local packages carry no `package =` ref),
    the app target's `packageProductDependencies`, and its Frameworks build phase.
  - `BookPlayerModel.swift` (122 upstream commits, we add +4 lines) / `AppDelegate.swift` (15) /
    `AudioBoothApp.swift` (30, actively churning) — near-certain textual collisions, trivial
    re-apply.
  - `BookPlayer.swift` (55) and `BookPlayerControls.swift` (quiet historically, but we added +99
    lines of speaker mirroring and upstream is heading toward transport work — repeat, keyboard
    shortcuts): **the real merge work lives here; budget rebase time accordingly.** Same for
    `BookCard*`/context menus (upstream reworked them in #323) and `PlayerControl.swift` (our
    `.transcript` case sits exactly where upstream adds new cases).
  - The 13 one-line `AppGroup.identifier` substitutions: paper-cut conflicts, mechanical.
- **Post-sync checklist** (after the gauntlet, before pushing): `./scripts/smoke-play.sh` (press play
  on a streamed book, twice, and check it keeps playing); karaoke smoke — open Goblet's
  transcript and cover mode; speaker smoke — pill appears against a live/paused daemon session;
  device build if an install is planned. Then `git push --force-with-lease origin main`.
- **Watch for on each rebase:** upstream adding its own transcription work (there was none at fork
  time — that seam being empty is why the package drops in cleanly); `SWIFT_VERSION` bumps (pbxproj
  says 5.0 while the packages use 6.2 tools — concurrency friction is expected someday);
  `IPHONEOS_DEPLOYMENT_TARGET = 26.0` creep (some targets already sit above the README's "iOS 17+";
  `Transcription` targets iOS 17 to match `Models`).
- **Drift reducer:** every feature that lands upstream (see the upstream-contribution plan) returns
  its files to "unmodified" here after the next rebase — upstreaming is the long-term fix for the
  conflict surface.
- **2026-09-26: selective cherry-pick sync, not a rebase.** Upstream shipped Read Along, Page Match
  and Catch Up (on-device ASR re-deriving what the karaoke engine already stores; local-player-only
  playheads that fight the speaker model), so they were deliberately *skipped*. A plain
  `git rebase upstream/main` would now drag them in — until that's resolved, syncs are
  `git cherry-pick -x <upstream sha>` of wanted fixes on a branch (the `-x` trailer is the record of
  what's been taken; `git log --grep 'cherry picked from'`). Taken: the fixes through upstream
  849eac0 — playback/session fixes, iOS 27, audio session + interruption, CarPlay, the downloads
  rewrite (9c99581 and its cover follow-ups). Skipped: Read Along / Page Match / Catch Up and their
  follow-ups, onboarding, lock mode, filter revamp, sleep-timer options, iOS 17 fixes (below our
  deployment target), the progress-service refactor, and all localization commits (kept the fork's
  `Localizable.xcstrings`; new upstream keys fall back to their English key).
- **2026-11-06: full merge of upstream/main (81c83a6, v1.14), back on the merge/rebase track.** 158
  outstanding commits; the post-1.13 fixes sit on upstream's refactors (progress service, filters,
  player controls), so cherry-picking had stopped scaling. Jake chose to take *everything*, including
  Read Along / Page Match / Catch Up, onboarding and lock mode — they coexist with karaoke because
  none of them touch the speaker path; the earlier skip was product overlap, not breakage. A merge
  commit (not a rebase) because the fork's history is PR-merge based now and upstream had not
  rewritten its history (merge-base intact, `git cherry` matched the 22 earlier picks). 40 files
  conflicted; the predicted shape held: `AppGroup.identifier` one-liners, brand strings
  (`clientName`, the watch's "open … on your iPhone" error), our `#if SPEAKER_STACK` hooks next to
  upstream edits, and `PlayerControl`'s `.snip` beside upstream's new `.lock`/`.pageMatch`.
  `BookPlayerControls` was rewritten on upstream's new design (22pt chapter buttons, 48pt borderless
  play glyph, `isLocked` dimming) with the speaker mirroring layered back on. `Localizable.xcstrings`
  went the documented way: upstream's file, the fork's 75 keys re-added by script, "AudioBooth" →
  "AudioBook Karaoke" over *values* in every locale, and a source-language override for the 11 new
  upstream keys whose *key* carries the brand (onboarding, Page Match copy, Focus-filter hint) so the
  code stays untouched. Dropped from the fork: nothing functional — the fork-side copies of the
  auto-download helpers, `smartContinuePlayback` toggle and resume-on-volume-restore were stale
  cherry-pick remnants that upstream has since superseded (Up Next preferences, `pauseAtZeroVolume`).
- **KSCrash ≥ 2.6.0 needs upstream's `CrashReporter` config** (ee7f1a6: no watchdog monitor, no
  memory introspection, `enableSwapCxaThrow = false` on simulator). With 2.6.0's defaults the app
  SIGBUSes at launch inside ImageIO's lazy OpenEXR `dlopen` on the first cover decode — take the
  dependency bump and that commit together, never the bump alone.

## Build gotchas (learned the hard way)

1. **Build the scheme, never `-target`.** `xcodebuild -target AudioBooth` skips the prebuild that
   generates Readium's module maps and dies on a bogus `Minizip.modulemap` error. It also litters
   `*/build/` dirs in the tree (not gitignored).
2. **A watchOS simulator runtime is required even for iOS-only builds** — the scheme embeds the Watch
   app (`xcodebuild -downloadPlatform watchOS`, ~4GB; the watchOS *SDK* alone is not enough).
3. **Tests:** `swift test` in `Transcription/`. All `ModelContainer`s in tests must go through
   `TestContainers.makeInMemory()` — parallel suites creating containers directly race SwiftData's
   schema registration and SIGSEGV intermittently. Live-daemon suites are opt-in:
   `TRANSCRIPTION_LIVE=1` (fast) and `TRANSCRIPTION_LIVE_FULL=1` (whole-book import).

## Device builds (paid individual team, as of 2026-07-23)

Device builds run under Jake's **paid** individual team `<TEAM_ID>` (`Local.xcconfig`, gitignored,
carries `DEVELOPMENT_TEAM` and `ORG_IDENTIFIER`). Enrolling as an individual **upgrades the existing
personal team in place — the Team ID does not change**, so `<TEAM_ID>` was the free team ID before
2026-07-23 and is the paid team ID after. Tell them apart by artifact, not by ID: a free team's
profiles have `TimeToLive 7` and it cannot hold an `Apple Distribution` certificate; the paid team's
profiles are `TimeToLive 365` and an `Apple Distribution: <Account Holder> (<TEAM_ID>)` cert exists.

- **`ORG_IDENTIFIER` still must differ from upstream's**, paid or not. App-group identifiers are
  reserved globally: Apple rejects `group.me.jgrenier.audioBS` under this team. With a different
  identifier the provisioned group no longer matches the group string hardcoded in code
  (`ModelContextProvider`, the widget's `UserDefaults(suiteName:)`, `TranscriptStore`), so
  `containerURL(...)` returns nil and everything falls back to Application Support — the app works,
  widgets just don't share data on device until that hardcoding follows `ORG_IDENTIFIER`. Unfinished.
  - The transcript-store half of this bit for real (2026-07-31): the decoupling refactor started
    passing the fork's provisioned `AppGroup.identifier`, the device store moved out of Application
    Support, and a phone's LLM-cleaned Goblet "reverted" to raw re-imports (the server only holds
    `hostRaw`; cleaned tiers had never uploaded because uploads require whole-book coverage).
    `TranscriptStore.shared` now adopts the legacy Application-Support store on first open
    (higher-quality-wins merge, legacy family renamed `*.migrated`) — see its adoption test.
- **Entitlements restored for the paid team (2026-07-23):** NFC (`TAG`) and iCloud KVS
  (`ubiquity-kvstore-identifier`) on the app, Wi-Fi info on the Watch app — verified present in the
  signed binaries via `codesign -d --entitlements`. **CarPlay audio is still stripped**: it needs a
  separate Apple entitlement request (developer.apple.com → Contact Us → CarPlay) and provisioning
  fails if `com.apple.developer.carplay-audio` is present before Apple grants it. Add it only after
  approval.
- **The explicit `StoreKit.framework` link stays removed.** It made Xcode request the In-App Purchase
  capability; RevenueCat pulls StoreKit transitively so the link was redundant. Harmless removed on
  paid accounts too.
- Build: `xcodebuild -scheme AudioBooth -destination 'platform=iOS,id=<devicectl id>'
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration`; install and launch via
  `xcrun devicectl device install app` / `… process launch --console` (`--console` captures
  `print()` output — how the Track A probes report).
- First launch requires trusting the developer profile on the phone (Settings → General → VPN &
  Device Management). Paid-team profiles now last **365 days**, not the free team's 7 — no more weekly
  rebuild-to-refresh, and no 3-app sideload cap.

## TestFlight (not yet wired — the path, 2026-07-23)

Distribution is a separate pipeline from the development signing above. The `Apple Distribution`
cert (created 2026-07-23) is the first piece; still needed: (1) an App Store Connect app record for
`com.example.AudioBS` (app *names* are globally unique — "AudioBooth" may be taken); (2) an
**archive** (`xcodebuild archive`, not `build`) signed with the distribution cert + an App Store
provisioning profile, entitlements matching the App ID exactly (why the restore above matters); (3)
upload via `xcrun notarytool`/Organizer, which needs an App Store Connect API key (Jake's to create);
(4) export-compliance answers + Apple processing (~5–30 min); (5) testers — internal (≤100, no
review, near-instant) or external (≤10k, first build needs Beta App Review, ~1–2 days). Updates =
bump build number (the `Set Build Number` phase already enforces monotonicity) → archive → upload.
Widgets won't share data in the TestFlight build until the app-group hardcoding is fixed.

## Measured numbers (2026-07-17, the facts the engine design hangs on)

| what | result |
|---|---|
| iPhone 17 Pro Max, SpeechTranscriber, WWDC-277 **concurrent** drain | **85.4x realtime** (46min audio in 32.4s; 88.5x/81.0x per track), thermal nominal, `audioTimeRange` word timings present |
| Same phone, background compute | **none** — `BGTaskScheduler.supportedResources` is the empty set (no `.gpu`) |
| Host (i3-N305), faster-whisper `small`, full 10.7h Dog Stars run | **4.47x realtime** (2.39h wall), 9,812 segments, covered to within 3.7s of duration |
| Same phone, full 6.86h Greenlights (single `.m4b`), device transcribe → ebook align | 6,082 ASR segments in **~5.7min**, then epub aligned in-process to **5,321 book sentences at 90% match / 51,420 anchors**, uploaded to host (2026-07-17) |

The one published iPhone 17 Pro Max figure (4.6–6.2x) is off by ~14x — its serial results drain was
the flaw, exactly as IOS-SPEC suspected. Consequences: JIT lookahead is ~free (15min ahead ≈ 10s of
compute), whole-book **foreground** on-device is viable (~7.5min per 10h book; background remains
dead), and the host's role is quality (better WER) + zero-phone-battery, not speed. Unmeasured:
sustained thermal (a full 20h book ≈ 14min of continuous ANE) and BGContinuedProcessingTask's
penalty (Track A exp 3). Benchmark harness: `-transcribeBench <minutes>` DEBUG launch arg; results
tee to `Documents/experiment2.log` in the app container.

## The ebook *is* the transcript, where one exists (2026-07-17)

When an item has an epub, the printed book is a strictly better transcript than any ASR — real
punctuation, real paragraphing, and proper nouns spelled the way the author spelled them (Apple's
`SpeechTranscriber` has no custom vocabulary and this library is full of invented names). So the
on-device flow now treats **ASR as the timing scaffold and the epub as the text**:

1. `DeviceTranscriptionSession` transcribes to ASR as before (`.onDeviceApple` chunks).
2. When coverage is complete — or immediately, if the book was already fully transcribed — it pulls
   the item's epub (a downloaded copy via `LocalBook.ebookLocalPath`, else fetched from ABS with the
   session token), strips each spine document to prose (`EbookHTML`), and aligns it to the ASR
   (`EbookAlignment`): unique 4-gram anchors → LIS to keep the chain monotonic (a repeated phrase
   can't cross-wire two chapters) → bounded Needleman–Wunsch inside the gaps → book sentences carrying
   ASR-derived times. Output commits as `.ebookAligned`.
3. `.ebookAligned` is the **top** `TranscriptProvenance.quality` rank, so the upsert rule makes the
   book text supersede ASR (and host output) with no caller coordinating, and the completed transcript
   uploads to the host so `/captions` serves it to every client.

Alignment **refuses** rather than guesses — insufficient anchors or <50% matched fraction (wrong
edition, abridgement, unrelated book) keeps the ASR transcript instead. Front matter and appendices
the narration never speaks are dropped, not given invented timestamps. All of this is in the
`Transcription` package (pure, tested — `EbookAlignmentTests`/`EbookHTMLTests`) except the Readium
extraction, which is app-side in `Screens/BookPlayer/Karaoke/EbookTranscriptText.swift` because epub
access means Readium. `KaraokeSheetModel` injects the extractor as a `@Sendable () async -> String?`;
the package only ever sees a `String`. Only Greenlights has both audio and an epub in this library
today, but the path is general.

## On-device LLM transcript cleanup (designed 2026-07-24, built same day — see below)

The gap this fills: **items with audio but no epub.** Where an epub exists, `EbookAlignment` already
produces perfect text (real names, punctuation, paragraphing) — no LLM can beat the printed book, so
cleanup must never outrank `.ebookAligned`. Where there's no epub (e.g. Goblet: no ebook file on the
item), the transcript is raw ASR, and today's Goblet pass showed exactly what that means: "Bagamon
and Crouch" (Bagman), "Abored the Hogwarts Express", "Bobaton and Durmstrang" (Beauxbatons), "Priory
Incantatum" (Priori Incantatem), "Weasleys wizard weasels" (Wheezes) — all fixable by a small model
that knows the book's title.

- **Slot in the existing supersede machinery, don't build new plumbing.** `TranscriptProvenance`
  already encodes tier precedence as `quality` ranks (`onDeviceApple` 0 → `ebookAligned` 4), and
  `TranscriptStore.upsert` enforces higher-quality-wins per chunk. Add `.onDeviceLLMCleaned` above
  `.hostCleaned`, below `.ebookAligned` (quality is derived at runtime from the enum, so renumbering
  is safe; `provenanceRaw` strings persist unchanged). Cleanup then commits through the normal
  `TranscriptStore.commit` and automatically loses to ebook alignment and beats raw ASR — zero caller
  coordination, idempotent, safe to re-run when a better model ships (bump `engineID`).
- **`CleanupSession`, modeled line-for-line on `DeviceTranscriptionSession`:** `@MainActor
  @Observable`, one `Task` runner, per-chunk `Task.checkCancellation()`, thermal etiquette (critical
  = abort, serious = sleep 30s), `isIdleTimerDisabled` while running, and resume-from-store: the
  work queue is "grid chunks where `provenanceCounts` shows raw ASR but no cleaned/aligned row", so
  interruption anywhere costs nothing. The 5-minute `TranscriptGrid` chunk is the natural unit of
  work — ~750 words ≈ 1k tokens, which fits Apple Foundation Models' small context.
- **Model: Apple Foundation Models (iOS 26)** — on-device ~3B, free, ANE-resident, and guided
  generation (`@Generable`) returns structured `[{seg, text}]` so segment boundaries and timings
  survive cleanup verbatim. Cleaned chunks drop `words[]` — already a documented bargain
  (`hostCleaned` does the same; karaoke degrades to line-level highlight). Guard against drift:
  instruct minimal edits, then reject any cleaned segment whose token overlap with the ASR falls
  below a threshold — keep the ASR row on rejection. Availability isn't universal (Apple
  Intelligence opt-in + eligible hardware); on unavailability the tier simply never appears.
- **Throughput math (why it's an ongoing pass, as suspected):** cleanup is ~1:1 tokens in/out. A 20h
  book ≈ 270k tokens out; at the on-device model's ~30–80 tok/s that's **1–2.5h of generation vs
  ~14min of ASR** — an order of magnitude slower. So it runs like the karaoke maintenance loop:
  prioritize the window ahead of the playhead (a listener needs ~15min of clean text, not the whole
  book), backfill opportunistically while the app is foreground (background compute is dead —
  experiment 1: `BGTaskScheduler.supportedResources` is empty), and let per-chunk commits make
  "whenever the app happens to be open" a fine schedule.
- **Name grounding:** system prompt carries title/author/series/narrator from ABS metadata plus a
  per-book glossary. Glossary sources, best-first: epub of a *sibling* book in the same series
  (canon spellings for the shared cast), the ABS description, and a cheap first pass that mines the
  ASR for recurring near-miss proper nouns. Quote insertion (dialogue quotation marks) is an
  in-segment text edit — same guarded-edit path, no timing impact.
- **Chapter resolution (`ChapterResolver`), the generalized form of today's Goblet fix:** signals
  ranked deterministic-first — (1) the m4b's own marks: for Goblet all 39 were *positionally* exact,
  only the titles were junk; (2) transcript announcement matching near each mark (regex + spelled
  number parsing found 34/37 today; the 3 misses were ASR manglings sitting right at known marks, so
  marks + fuzzy title match resolves them); (3) epub TOC when one exists; (4) LLM only as judge for
  the ambiguous remainder — "given this minute of text and the book title, which chapter starts
  here?". Reasoning is the fallback, not the pipeline. Output is a proposed list the user confirms
  in a sheet, then pushes upstream.
- **Push upstream = `POST /api/items/{id}/chapters` on ABS** (verified live today via curl; needs a
  user with `update` permission — both Jake's and the `Test` account have it). The app has **no
  chapters write wrapper yet** — the API package's only book mutation is ebook progress — so this
  needs a small `ChaptersService.update(itemID:chapters:)`.
- ~~**Open question:** host upload of cleaned text.~~ **Resolved 2026-07-24**: the worker now does
  write-once *per provenance tier* — `PUT /transcripts/{item_id}` with an `X-Transcript-Provenance`
  header replaces the file only when the tier is strictly higher (`PROVENANCE_QUALITY` in
  `caption_worker.py`, mirroring the client ranking); headerless uploads keep pure write-once, tier
  lives in `{item}.meta.json` (absent = `hostRaw`), the replaced file is kept as
  `.superseded-{tier}.jsonl`, and `GET /status` reports `provenance`. Committed on the box
  (`abs-session` @ `5d16fcc`); **needs `sudo docker restart abs-caption-worker` to take effect**.

### What got built (2026-07-24)

- `CleanupSession` (Transcription package): Apple Foundation Models via guided generation
  (`@Generable` — `[{id, text}]` per ≤30-segment batch), playhead-first chunk queue, per-segment
  token-overlap drift guard (reject < 0.5 overlap → keep ASR line), thermal/cancellation etiquette,
  commits `.onDeviceLLMCleaned` (quality 4; `ebookAligned` bumped to 5), uploads whole-book with the
  *weakest* tier label once coverage is complete. Compiled out on macOS; on simulator it exists but
  `CleanupSession.isSupported` is false without Apple Intelligence.
- **Trigger UX** (the judgment call): a **manual "Clean Up Text" button** in the transcript sheet's
  banner strip — visible only when the model is available *and* the stored transcript still has
  raw-ASR chunks — plus a **default-off preference** (Settings → Player → Transcript, "Clean Up
  Transcripts") that auto-starts a session once per sheet presentation. Rationale: a full book is
  1–2h of sustained ANE generation, so continuous-by-default was rejected; but per-window JIT-only
  was also rejected because a half-cleaned book never finishes. Playhead-first ordering gives the
  auto mode the JIT feel (the next 15 minutes clean within the first minute or two) while still
  eventually completing the book. Nothing runs without either the button press or the opt-in
  toggle, matching the house rule that heavy compute is always explicit.
- **Karaoke cover mode**: long-press the album art in the full player → "Karaoke Mode" swaps the
  cover square for the streaming transcript (`KaraokeCoverView`); long-press again → "Show Cover" /
  "Open Full Transcript". Persisted in `playerKaraokeCover`. It's a pure renderer over the same
  `KaraokeSheet.Model` the sheet uses — one transcript pipeline, two surfaces. Line-level emphasis,
  not word karaoke, on purpose: cleaned and ebook-aligned tiers have no word timings, so lines are
  the one grain every tier honors. Books only; podcasts keep the cover.

**Done 2026-07-24, the one-time version:** Goblet's chapters on abs.example.com corrected via the
transcript-announcement method above — 39 marks kept (they were exact), retitled from
"Harry Potter and the Goblet of Fire - NN" to "Opening Credits" / "Chapter N: <real title>" /
"Closing Credits". Backup of the original metadata in the session scratchpad
(`goblet-chapters/backup-original-item.json`); restore = POST the old array back.

## The speaker is a first-class output — Connect-style (built 2026-07-24/25)

The WiiM speaker (driven via the abs-session daemon; see Server dependencies below) behaves like
Spotify Connect: start anywhere, control from anywhere, every surface shows the true playhead.
The pieces, and the invariants that keep them honest:

- **`SpeakerSessionManager` owns the session; sheets only borrow it.** One session per speaker,
  keyed by item, created via `session(for:...)` (get-or-create — reuse is what makes reopening a
  sheet rejoin playback instead of re-seeding and rewinding). It outlives sheet dismissal while
  `hasOwnSession`; `stop` / "Continue on iPhone" end it via the `onEnded` hook. All creation goes
  through the manager — a session built anywhere else won't get keep-alive or cleanup policy.
- **Discovery** (`discoverExistingSession`, called on app activation and player appearance): one
  `GET /status` on the transport; an existing daemon session (the Home Assistant flow) is adopted
  seeded-from-the-reply, monitor attached, never auto-played.
- **Mirroring is view-layer, by policy.** When `activeSession(for:)` is non-nil the player's
  scrubber (`SpeakerProgressStrip`), transport buttons, chapter title/jumps, pill, karaoke cover,
  and transcript sheet all read the session's interpolated position and route actions to it.
  `BookPlayerModel` / `AudioPlayer` / `PlayerManager` know nothing about the speaker; the single
  exception is one guarded, index-based branch in `ChapterPickerSheetViewModel.onChapterTapped`.
  No session ⇒ every path is byte-identical local behavior. Keep it that way: new speaker-aware
  UI belongs in views, keyed off the manager.
- **Position flows one way.** `SpeakerSessionModel.currentPosition` = last WS tick + wall-clock
  interpolation. Transcript surfaces consult `livePosition(for:)` *per tick* (inside
  `positionProvider` closures), so they switch source live when a session starts or ends.
- **Daemon quirk to remember: seek is play.** `POST /seek` on a paused (or idle) session starts
  playback at the target — deliberate reference-player semantics. Anything that seeks while
  "Paused on Speaker" (scrubber drag, transcript line tap, chapter pick) will start the room
  talking. Restore etiquette after testing: seek to the recorded position, then `POST /pause`.
- Not mirrored, deliberately: playback speed (no daemon rate control), phone volume (speaker
  volume lives in the transcript sheet's slider), end-of-book queue advance.

### Karaoke rendering: ScrollViewReader, kept deliberately (2026-07-29)

A `scrollPosition(id:anchor:.center)` + `scrollTargetLayout()` refactor was tried here and
**reverted the same day** — do not re-attempt it without new evidence. On paper it's the better
design (state-driven, identity-pinned across content rebuilds, no one-frame-late correction), and
it looked right in screenshots; in real use Jake found playhead tracking *worse* and the
transcript-sheet ↔ player handoff visibly breaking. Plausible mechanism: `scrollPosition`'s
binding is two-way — the system writes it during user scrolls, sheet-dismiss gestures, and layout
churn, and those writes fight the follow logic in ways scrollTo never did. Lesson recorded for
the next reader: scroll *feel* cannot be verified from screenshots, only from real playback use.

What ships instead, per surface: the **cover** uses a plain `VStack` (LazyVStack's height
estimation made anchors land off) + animated `scrollTo` on active-line change + an *instant*
`scrollTo` re-center when `rows` rebuilds (the maintenance loop slides the window and would
otherwise shift content under the scroll offset). The **sheet** keeps `LazyVStack` (paging can
grow the row list unboundedly) + animated `scrollTo` while `follow`, drag flips `follow` off, and
the "Back to Playhead" pill re-centers. The transcript is also a bottom-bar `PlayerControl`
(`.transcript`, books-only), not just a menu item.

*(Superseded 2026-08-13 for the sheet: follow-mode became a teleprompter — `.offset` on a
scroll-disabled column, see `KaraokeSheet.updateConveyor`.)*

### Karaoke sync + first-touch scrolling (2026-09-26)

**Highlight lag, measured on the sim:** the local playhead came from `MediaProgress.currentTime`,
which `AudioPlayer`'s 0.5s periodic observer writes — it trailed AVPlayer's own clock by **248ms
mean, 497ms max** — and the karaoke ticker sampled that every 200ms (+~100ms mean). Words lit
~0.35s late on average, up to ~0.7s. Now `AudioPlayer.preciseTime` (AVPlayer's continuous clock,
seek-aware) reaches the providers via `PlayerManager.preciseTime(for:)`, the ticker runs at ~30Hz
(banner mirrors stay at 200ms), and only the active line reads the playhead (`TranscriptLine`), so
the faster clock re-renders one row. A 50ms lead cancels tick + commit latency. Faster-whisper's
word starts, checked against energy onsets after pauses (Goblet track 16, 72 words), land **~75ms
*before*** the audible onset (median; p10 −310ms, p90 +48ms) — the ASR stamps aren't the lag.

**The "lock" before scrolling** was the teleprompter's handoff gesture: a 12pt dead zone, then the
conveyor moved 1:1 and stopped dead on release (no momentum) before native scrolling took over.
Now the scroll view stays live while following and is **parked** — after each glide settles, the
conveyor offset folds into the real scroll offset in one no-animation transaction
(`ScrollPosition.scrollTo(y:)`, inset-adjusted coordinates), so the first touch is plain native
scrolling. Parking must happen at rest: an offset written mid-drag is overwritten by UIKit's pan
on its next move (tried; the text snapped to the window top). The `ScrollPosition` binding is
write-only here — nothing reads what the system writes back, which is what bit the 07-29 attempt.

**Centering fixes shaken out by frame-by-frame video checks:** calibration samples now carry the
offset they were measured under (a mismatched pair oscillated), calibration re-centres when the
content origin moves and re-checks after every glide (a reload landing mid-glide used to leave the
line off-centre until the next line change — forever, while paused), and the follow window only
re-slides near its edges (it used to drop a row off the top every 2s maintenance pass, each one a
compensation that sometimes showed as a snap). Verified: 25s of playback, 12 line changes, every
glide monotonic to the same rest band, zero single-frame jumps; drags track the finger 1:1 after
UIKit's own slop. Feel still needs Jake on a device.

## Two bugs this shook out (both real, both fixed)

- **`.m4b`/container detection.** `HostTranscriptSource.downloadAudio` hardcoded a `.mp3` extension for
  every downloaded track. `AVAudioFile` treats the path extension as its file-type hint, so Greenlights
  (one 392MB AAC-in-MP4 `.m4b`) failed `ExtAudioFileOpenURL` with `kAudioFileInvalidFileError` ('dta?')
  — the "Transcription failed" the whole thread started from. Fixed by sniffing the leading bytes
  (`ftyp`/`ID3`/`fLaC`/`OggS`/…, see `AudioFileType`), falling back to the proxied `Content-Type`.
  Genuinely unreadable containers (ogg/opus — no Core Audio reader on iOS) now fail up front with a
  "Transcribe on Server" message instead of an OSStatus. mp3 books were unaffected, which is why Man's
  Search worked earlier and Greenlights didn't.
- **Worker upload 413 (server-side, in `abs-caption-worker`).** `caption_worker.py` created its
  `web.Application()` without `client_max_size`, so aiohttp's **1MB default** rejected every real
  whole-book upload before `put_transcript`'s own 64MB check ever ran. The book stayed local (harmless
  — the phone renders its own aligned transcript) but "saved to server" never actually worked for a
  full book. Fixed on the box: `web.Application(client_max_size=64 * 1024**2)`. This had also silently
  eaten Man's Search's upload that morning.

## Server dependencies and safe testing

- **Configuration (2026-11-01).** Nothing about any server is compiled in. The app stores one daemon address
  and takes the rest from `GET /capabilities` (docs/COMPANION-API.md); docs/SELF-HOSTING.md is the setup, and
  docs/DEPLOYMENT.md this deployment. A fresh install starts from `COMPANION_DAEMON_URL` /
  `COMPANION_WORKER_URL` in `Local.xcconfig`, and Settings can change that. Older installs' UserDefaults
  overrides migrate once. With no server, or none answering yet, `CompanionSettings.supports` decides what
  shows: nothing with no address, everything but the worker with an address that hasn't answered.
- **Tunnel auth (verified 2026-07-15):** the daemon and worker are served through the same CF tunnel as ABS,
  one hostname each, because cloudflared doesn't rewrite paths and the services' routes are absolute. Both
  require a **valid ABS token** on requests carrying `Cf-Ray` (validated against ABS `/api/me`, 60 s cache):
  ABS is the identity provider, so logging into the app is the whole login story; LAN traffic and the `/player`
  page carry no `Cf-Ray` and are unaffected. Behind any other proxy, `REQUIRE_ABS_AUTH=1` is what closes this.
- Fixtures: complete transcript — Goblet `f4f72906-0548-45b2-b75a-44d08826e458` (20.2h, 23,467
  segments); no transcript — Project Hail Mary `d32e4e8a-39c1-4ff0-b039-46301f4fcd63`.
- **The simulator talks to the real ABS server.** Prefer `audiobooth://open/<id>` (no autoplay) over
  `play/` for scripted runs, terminate the app after capturing, and never exercise
  `POST :8790/jobs` against the real worker — it burns hours of server CPU. Scripted entry:
  `xcrun simctl launch <udid> me.jgrenier.AudioBS -deeplink "audiobooth://open/<id>" -autoOpenTranscript`
  (DEBUG builds only; see `Services/DebugLaunchOptions.swift`).
- **Simulator auth survives reinstalls now** (2026-07-23) — `DebugLaunchOptions.restoreDevServerIfNeeded`
  restores a connection from `~/.config/audiobooth/devauth.json` on the *host*:

      { "serverURL": "https://abs.example.com", "apiToken": "<abs api token>", "alias": "abs.example.com (dev)" }

  Notes on the shape, each of which cost a cycle:
  - The file lives outside the working tree, so the token cannot be committed. It holds an **API
    token** (ABS Settings → Users), never a password. Use a dedicated low-privilege ABS user — the
    current one is `Test`, which keeps scripted playback out of the main listening history.
  - Read via `SIMULATOR_HOST_HOME`, not `HOME`: inside the simulator `HOME` is the app's own
    sandboxed container. Reading the host file (rather than taking a launch argument) is what makes
    this work when the app is started from Xcode's Run button or by tapping the icon.
  - The restore must run **before** `AppDelegate` reads `authentication.server` to choose the
    SwiftData store, or the first launch opens the wrong database.
  - `Connection`'s default id is a fresh UUID, which would strand a new empty store on every cold
    start — hence the deterministic `devauth-<host>` id.
  - Restoring the connection is *not* enough on its own. `restoreConnection` re-establishes the
    session but skips the login screen, which is also where a library gets picked, and
    `LibrariesService.fetch` only populates the list — it never sets `current`. Miss that and the app
    is genuinely authenticated but shows "No Content Available", which reads exactly like a bad
    token. The two pieces of state also persist in different places (connection → keychain, library
    choice → per-server storage), so the library selection must not be gated on "just restored".

## Before any upstream PR

- Decide whether `DebugLaunchOptions` ships (it's `#if DEBUG`-gated, so it compiles out of release
  either way).
- Transcription needs a settings surface (engine choice, on-device experiments) once Track A's device
  measurements exist — see `IOS-SPEC.md` in the `abs-session` repo for the sizing experiments that
  gate the on-device engine.

## Going public: the snapshot and the public build (2026-11-06)

There is no public copy of this repo yet, and the private one cannot simply be flipped: the tree and,
more so, its history name this deployment (hostnames, the NAS's tailnet address and ssh target, the
team id and the certificate's legal name, the bundle ids), from before the "configuration, not code"
rule. No token or key was ever committed; the 2026-11-06 scan of the full history found addresses and
identifiers only. Two scripts make sharing safe without rewriting that history:

- **`scripts/public-snapshot.sh [--push owner/repo] [rev]`** exports the tracked tree at one revision,
  replaces every literal in `scripts/public-redactions` (gitignored, since the map *is* the list of
  private details; `public-redactions.example` shows the format) in every text file, verifies that no
  literal, tailnet address or `*.ts.net` host survived, and commits the result as a single-commit
  repository in `$TMPDIR`. On 2026-11-06 the redactions touched only CLAUDE.md, FORK-NOTES.md,
  SPEAKER.md, docs/DEPLOYMENT.md and docs/cross-repo-snips-plan.md; no source file changed. With
  `--push` it force-pushes that commit as the target repo's `main`, so each snapshot replaces the last.
  Creating the public repo (`gh repo create owner/repo --public`) is deliberately left to a person.
  Publishing it also satisfies MPL-2.0 the moment builds go to anyone else: the snapshot is the source
  offer for the modified files.
- **`PUBLIC_BUILD=1 ./scripts/testflight.sh`** archives with `AUDIOBOOTH_FEATURES=`,
  `COMPANION_DAEMON_URL=` and `COMPANION_WORKER_URL=` on the xcodebuild command line, which outranks
  Local.xcconfig: no speaker stack, and a first launch that asks nobody until an address is typed into
  Settings → Companion Server. Verified 2026-11-06 on the v1.14-merged tree: the simulator build
  compiled with the flag off (the `#else` paths are live), both Info.plist companion keys were empty,
  and `strings` on the binary found neither the hostnames nor `SpeakerSessionManager`.

Both builds share one App Store Connect record, so a public build uploaded to TestFlight is also the
newest build the internal "Owner" group sees; upload the personal build again afterwards, or give other
people their own external group and pick builds per group. Still named in the public tree, on purpose:
the GitHub handle (the snapshot lives under it anyway), first names in the docs, "TrueNAS" as a product,
and `Snips/bookmark-spans.json` (one person's reviewed bookmark positions, inert for anyone else's book
ids). `abs-session` has no public remote at all, so nobody can run the server side yet; its README,
tools and CLAUDE.md describe one NAS.

## The two builds: personal vs store (2026-08-12)

One branch, one target, one compile-time flag. `SPEAKER_STACK` is a Swift compilation condition
wired through `AUDIOBOOTH_FEATURES` (declared in `Signing.xcconfig`, referenced by the project's
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`). Two branches would merge every change twice forever;
a flag is two branches that cannot drift.

- **Personal build** (the default — every existing command unchanged): `AUDIOBOOTH_FEATURES =
  SPEAKER_STACK`. Full WiiM/Home Assistant stack: sessions, discovery, pill + output chooser,
  speaker transports, server-transcription job UI.
- **Store build**: same commands with the variable cleared. The speaker/daemon world is *absent
  from the binary* — the `Speaker*` files compile out wholesale, `KaraokeSheetModel` wires
  `remote = nil` + `BookAudioProvider()` (the decoupling seams built for exactly this), menus and
  panels lose their speaker/server entries, and the transcript's bottom bar is a plain local
  transport.

  ```sh
  # store archive (same pipeline as the TestFlight section, one extra variable)
  xcodebuild archive -project AudioBooth.xcodeproj -scheme AudioBooth \
    -destination 'generic/platform=iOS' -archivePath <path> \
    -allowProvisioningUpdates AUDIOBOOTH_FEATURES=""
  # store simulator smoke
  xcodebuild build -scheme AudioBooth -destination 'platform=iOS Simulator,name=iPhone 17' \
    AUDIOBOOTH_FEATURES=""
  ```

  Why a variable and not a direct `SWIFT_ACTIVE_COMPILATION_CONDITIONS=` override: command-line
  overrides of that setting leak into SPM package builds and break RevenueCat's generated
  resource accessor; the custom variable is only referenced by the app project, so packages
  never see it.

Caveats, deliberately accepted:
- **Same bundle id** (`com.example.AudioBS`), same App Store Connect record, same upload
  pipeline. One phone runs either the sideloaded personal build or the store build, not both.
- **The Transcription package is identical in both builds** — the daemon *clients* (and the
  still exist as dead code in the store binary; nothing constructs them, and no address ships in it. Splitting the package (the upstream-PR shape) is the eventual
  proper fix. See NITPICKS.
- **Both builds keep every #if branch compiling**: CI-of-one rule — before pushing changes that
  touch fenced files, build once with `AUDIOBOOTH_FEATURES=""`.
- **Monetization**: upstream's RevenueCat tip-jar key was removed (`Monetization.swift`, single
  constant, empty = Purchases never configures + the Settings section hides, in both builds).
  Shipping a tip jar again = paste your own key there.
- Before an actual store submission: App Review needs a demo ABS login; MPL-2.0 means the
  modified files' source must be available (make the repo public or publish a snapshot); store
  screenshots/branding must carry no upstream identity.

## TestFlight upload pipeline (established 2026-07-31, build 1785520862)

Fully headless; no Xcode GUI. `./scripts/testflight.sh` runs the three steps below (added
2026-10-31; the first run shipped the snips build) after `scripts/smoke-play.sh` passes (skip with
`SKIP_PLAY_SMOKE=1`) and after `scripts/asc.mjs ensure-beta-group`, which keeps
the internal "Owner" TestFlight group (all builds, account holder as tester) in place: on 2026-10-31 the
app had no group at all, so build 1793478579 processed and reached no phone until the group was made. The one-time pieces are in place: ASC API key `8T35BVZTRK`
(App Manager role) at `~/.appstoreconnect/private_keys/`, and four `AS com.jakeschaeffer.*`
App Store profiles installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.

1. `xcodebuild archive -project AudioBooth.xcodeproj -scheme AudioBooth -destination
   'generic/platform=iOS' -archivePath <path> -allowProvisioningUpdates`
2. `xcodebuild -exportArchive` with **manual** signing options (`signingCertificate: Apple
   Distribution` + the four profile names) — automatic signing fails headless: CLI xcodebuild
   sees no Xcode account ("Failed to Use Accounts"/"No Accounts"), and an App-Manager API key
   can upload but **cannot cloud-sign** ("Cloud signing permission error"; that needs Admin).
3. `xcrun altool --upload-app -f <ipa> -t ios --apiKey 8T35BVZTRK --apiIssuer <issuer>`.

Gotchas: profiles were created via the ASC provisioning REST API (the key *does* have
certificates/identifiers/profiles access) against the account's `Apple Distribution` cert —
re-mint through `POST /v1/profiles` if they expire (365d). `ITSAppUsesNonExemptEncryption=NO`
is set, so no export-compliance interrupt. The Set Build Number script stamps app + watch +
both widget extensions (the nested watch widget triggered ITMS-90473 until 2026-07-31).

## Play regression of 2026-10-31, and the smoke test it left behind

TestFlight build 1793478579 (the first phone build since July) didn't play: every streamed book stalled and
paused within a second of play. The 2026-09-26 cherry-pick sync had taken upstream dcc1db1
(`AVURLAssetPreferPreciseDurationAndTimingKey` on every asset); on a remote VBR MP3 that slows the
session-start seek, and with `automaticallyWaitsToMinimizeStalling = false` plus `BookPlayerModel`'s
pause-on-stall the first play stalls and stops. Upstream had reverted it on 2026-10-04 (33fe46c), which PR #7
cherry-picked. Lessons:

- **A cherry-picked upstream player commit needs its follow-ups.** Before taking one, look for later upstream
  commits on the same lines: `git log upstream/main -S'<changed text>'`.
- **Nothing pressed play.** The simulator protocol prefers `open/` over `play/` and the post-sync checklist
  covered karaoke and the speaker. `scripts/smoke-play.sh` now presses play twice (a `play/` deep link, then a
  cold launch pressing play on the restored book through the button's own call, via the DEBUG `-smokePlay`
  flag) and fails unless the playhead moves for 15 s with no stall. It refuses to run unless the speaker daemon
  is idle, since an advancing Test session is a takeover. It caught the bug when reintroduced; the stall is
  timing-dependent, which is why there are two passes.
- **App logs are on stdout and in Pulse, not the unified log**: `xcrun simctl launch --console-pty`. On the
  phone, `log collect --device` needs root; ABS listening sessions (`/api/users/<id>/listening-sessions`) show
  which client and build opened a session.
