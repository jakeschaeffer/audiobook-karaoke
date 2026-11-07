# The companion server contract

Everything this app asks of a server beyond Audiobookshelf. `abs-session` implements all of it, but
the app doesn't care what is on the other end: anything that answers these routes works, including
something that implements only part of them.

The app holds **one address**: the daemon's. Everything else comes from `GET /capabilities`.

## Authentication

Every request carries the user's Audiobookshelf session token:

```
Authorization: Bearer <ABS token>
```

There is no second credential. A server validates the token by calling ABS `GET /api/me` with it, and
answers 401 if ABS refuses. A server on a private network may ignore the header.

## Discovery

### `GET /capabilities`

```json
{
  "service": "abs-session",
  "api": 1,
  "features": ["captions", "audio", "speaker", "jobs"],
  "worker_url": "https://jobs.example.com",
  "speaker": { "name": "Kitchen", "kind": "wiim" }
}
```

| field | meaning |
|---|---|
| `api` | Contract version. Required. The app refuses a version above the one it knows (1 today). |
| `features` | Required. Unknown values are ignored, so a server can add features without breaking older apps. |
| `worker_url` | Where the worker is, as this client should reach it. Null when there isn't one. |
| `speaker` | `name` is shown in Settings. Null when there is no speaker. |
| `service` | Free text, for humans. |

| feature | what the app then offers | routes it relies on |
|---|---|---|
| `captions` | Follow-along transcripts from the server | `/captions`, `/tracks` |
| `audio` | iPhone transcription of books that aren't downloaded | `/tracks`, `/audio` |
| `speaker` | "Play on Speaker", the output chooser, speaker transport | `/status`, `/events`, transport POSTs |
| `jobs` | "Transcribe on Server", uploading transcripts made on the phone | the worker's routes |

The app calls this when the address is saved, each time it comes to the foreground, and when the
settings screen opens. A failed refresh keeps the last answer: a phone off its network is not a server
that lost its speaker.

**Older servers.** On a 404 the app probes instead: `/healthz` must answer `{"ok": true}`, `/status`
returning a `state` means a speaker, and a worker is assumed at the daemon's host on port 8790 if it
answers there. A new server should implement `/capabilities`; the probe exists for upgrades.

## Daemon routes

### Transcripts (`captions`)

| route | returns |
|---|---|
| `GET /captions?item_id&from&to&words=1` | `{"segments": [...]}`, book-absolute seconds. 404 means no transcript at all; a partial transcript is a 200 with what exists. |
| `GET /tracks?item_id` | `{"tracks": [{"i": 0, "start": 0.0, "dur": 123.4}]}` |

A segment is the shape `TranscriptSegment` decodes (`Transcription/Sources/Transcription`).

### Audio (`audio`)

| route | returns |
|---|---|
| `GET /audio?item_id&track=N` | One track's bytes, with a correct `Content-Type`. |

### Speaker (`speaker`)

One state shape everywhere: the body of `GET /status`, of every transport POST's response, and of
every `/events` frame.

```json
{ "state": "playing", "item_id": "…", "title": "…", "position": 123.4, "duration": 3600.0,
  "percent": 3.4, "track": "1/12", "volume": 20 }
```

`state` is `idle`, `playing`, `paused`, or a daemon-specific value the app treats as not playing. Idle
states carry nulls and no `item_id`.

| route | semantics |
|---|---|
| `GET /status` | Current state. |
| `GET /events` | WebSocket. Full state on connect, on every change, and each second while playing. |
| `POST /play {item_id, position?}` | Start or take over the speaker. |
| `POST /pause`, `/resume`, `/toggle` | Against the current session. |
| `POST /seek {position \| delta}` | Reposition. **Starts playback, even from paused.** 409 when idle; the app then calls `/play`. |
| `POST /stop` | End the session with a final progress sync. |
| `POST /volume {level}` | 0–100. |

A daemon with no speaker answers these POSTs with 501. [SPEAKER.md](../SPEAKER.md) explains what each
control in the app sends and why.

## Worker routes (`jobs`)

Relative to `worker_url`. The worker can live anywhere; only the daemon needs to know where.

| route | semantics |
|---|---|
| `GET /status?item_id` | Coverage and the item's newest job. |
| `POST /jobs {item_id}` | Start transcribing. Hours of CPU; the app only sends this when someone taps the button. |
| `DELETE /jobs/{id}` | Cancel. |
| `PUT /transcripts/{item_id}` | Upload JSONL, with `X-Transcript-Provenance`. Keeps the better tier. |
| `GET /healthz` | `{"ok": true}` |

## Writing another backend

The likeliest reason is a different speaker. Keep `/capabilities`, the state shape and the transport
routes, and put your device behind them; `speaker.kind` is free text. Two behaviours the app depends
on: `/seek` starts playback, and `/events` sends full state on connect.
