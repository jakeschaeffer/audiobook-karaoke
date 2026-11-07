# NITPICKS.md — small things noticed in passing

Things seen while working that are real but didn't belong to the change being made. Each entry
says where, what, and why it can wait. Delete entries as they get fixed.

## Speaker / daemon

- **Daemon: no seek-without-play.** Every `/seek` starts playback, so scrubbing or
  chapter-jumping a *paused* speaker session starts the living room. The app works around it
  everywhere it can; the clean fix is a daemon-side `seek {autoplay: false}` (and then dropping
  the app's pause→seek→pause restore dance). Needs box access.
- **Daemon: `GET /status` never carries `volume`.** The handler calls `public_state()` without a
  device poll, so only WS frames and MQTT publishes include the level; a one-shot status read
  (snip refresh, discovery) can't seed the volume slider. Cheap daemon fix: pass the last polled
  `dev` into the status handler.
- **Daemon: a new ABS session from the phone app takes over at once** (see SPEAKER.md, "Snips
  while the speaker plays"): loading a streamed book pauses the room. Route the app's sessions
  through the advancing guard.
- **Daemon: no event ordering.** WS frames and transport-response states interleave with no
  sequence number, so a late "playing" tick can flap state for a beat after a pause response
  (transient UI flicker, duplicate progress write, potential double ownership transition).
  Daemon-side monotonic `seq` + client-side "ignore older than last applied" would close it.
- **`SpeakerSessionModel.volume` defaults to 20** until the daemon happens to poll the device —
  the sheet's volume slider can show a made-up value on first present.
- **`DaemonEndpoint.current` is launch-time fixed** (tunnel vs tailnet); no runtime failover
  when the network flips mid-session — actions just fail until relaunch.
- **Session model logs nothing.** Fine day-to-day, but bug reports like "it was on both devices"
  would be answerable from a small transition-only log (state changes + verbs sent, never ticks).
- **Chooser buttons capture the session at dialog-open**; a dialog left open across an external
  stop acts on a dead session (harmless — actions fail/no-op — but the labels lie).

## Player / progress

- **`BookPlaybackSheet.seek` (book not loaded)** writes `MediaProgress` then `player.play(bookID)`
  and trusts the load to read it; there's no explicit post-load seek, so a concurrent
  `syncFromAPI` with a newer-stale server copy could still win the race. An explicit
  `onSeekToTime` after load would make it deterministic.
- **`Marquee` uses `.id(chapter.title)`** (`BookPlayer.swift`) — two chapters with identical
  titles won't reset the marquee scroll on transition. Cosmetic.
- **`KaraokeSheet.Model` construction is quintuplicated** (player transcript sheet, player speaker
  sheet, BookPlaybackSheet ×2, cover) with three byte-identical positionProvider/onSeek closure
  pairs — the planned `forBook(...)` factory (Plan A P1-10) still makes sense.

## Build / tooling

- **The store build still embeds the daemon clients and personal hostname defaults** (dead code —
  `DaemonEndpoint`, `HostTranscriptSource`, `WorkerClient` live in the Transcription package,
  which doesn't see `SPEAKER_STACK`). Nothing constructs them, but the strings are in the binary.
  The proper fix is the planned package split (fork-only daemon files out of the upstream-bound
  package).

- **"Set Build Number" script phase runs on every build** ("based on dependency analysis"
  unchecked) — harmless but adds a note to every build log and defeats incremental no-op builds.
- **`ExportOptions.plist` still carries `manageAppVersionAndBuildNumber`** — ignored under manual
  signing; remove next time the pipeline is touched.
- **`xcrun altool` is deprecated in favor of `notarytool`/Transporter for some flows** — uploads
  still work; if Apple retires it, `xcrun iTMSTransporter` or the ASC API upload flow are the
  successors.

## Transcript

- **Cleanup "whole book only" upload gate** means a book cleaned window-by-window never reaches
  the server (Goblet: server still `hostRaw`). Either a partial-upload tier merge server-side or
  an explicit "clean entire book" action would make cleanups durable across installs.
- **`normalizeTitles`' "Chapter N" literal is unlocalized** (model-side string interpolation) —
  only matters if the app ever localizes chapter synthesis.
