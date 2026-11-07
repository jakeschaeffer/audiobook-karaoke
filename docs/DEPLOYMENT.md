# One working deployment

The setup this app was built against, as a worked example of [SELF-HOSTING.md](SELF-HOSTING.md). The
software is what matters here; addresses on the LAN and the tailnet live in gitignored files, not in
this repo.

## Machines

| machine | role | reached by |
|---|---|---|
| **Home NAS** (TrueNAS, host networking) | Everything audiobook | LAN, Tailscale, Cloudflare Tunnel |
| **WiiM Mini** | The speaker | LAN only |
| **Mac** | Builds and signs the app; holds the simulators and the App Store Connect key | – |
| **iPhone** | The app, from TestFlight | Anywhere, through the tunnel |

The podcast player is a separate app on a separate VPS. It shares the snip design with this one, and
nothing at runtime.

## What runs on the NAS

| service | how it runs | port | public hostname | config |
|---|---|---|---|---|
| Audiobookshelf | `arr` compose stack | 13378 | `abs.example.com` | upstream |
| abs-session daemon | `abs-session` compose | 8788 | `captions.example.com` | `abs-session/.env` |
| caption worker | `abs-session` compose | 8790 | `jobs.example.com` | `abs-session/.env` |
| kosync | `abs-session` compose, `kindle` profile | 5758 (localhost) | `kosync.example.com` | `COMPOSE_PROFILES=kindle` |
| abs-opds | its own checkout | 3010 | `opds.example.com` | upstream |
| Home Assistant + mosquitto + zigbee2mqtt | own stacks | 8123, 1883 | – | Buttons, sleep timer, dashboard |
| cloudflared | own stack | – | – | Hostnames above → ports above |
| ingest | cron, every 5 min | – | – | `tools/ingest.py`: downloads → library → scan → transcript |

## How this deployment fills in the fields

| field | where | value here |
|---|---|---|
| `COMPANION_DAEMON_URL` | `AudioBooth/Local.xcconfig` | `captions.example.com` |
| `COMPANION_WORKER_URL` | `AudioBooth/Local.xcconfig` | `jobs.example.com` |
| `WORKER_URL` | `abs-session/.env` | `https://jobs.example.com` |
| `SPEAKER_NAME` | `abs-session/.env` | `WiiM` |
| `AUDIOBOOKS_DIR` and the secrets paths | `abs-session/.env` | The NAS's datasets |
| `WIIM_HOST`, `WIIM_MAC`, `TAKEOVER_USERS` | `abs-session/.env` | The living-room speaker; `<you>,Test` |
| `TEAM_ID`, `APP_BUNDLE_ID`, `ASC_*`, `SMOKE_*` | `scripts/local.env` | The account and a test book |
| ABS API token | NAS, outside the repo; `~/.config/audiobooth/devauth.json` on the Mac for the simulator's `Test` user | – |

## Traffic

- **Phone, anywhere:** `https://books…` for ABS, `https://captions…` and `https://jobs…` for the rest, all
  through one tunnel, all carrying the ABS token.
- **Speaker:** the daemon sends the WiiM LAN URLs for stream windows it cuts with ffmpeg
  (`/cut/…`), for ABS files, and for spoken clips. It reports position by being polled.
- **Progress:** the daemon pushes to ABS while the speaker plays; the app pushes while the phone plays.
  ABS is the only record both agree on. [SPEAKER.md](../SPEAKER.md) covers the handoffs.
- **Transcripts:** the worker writes `transcripts/<item>.jsonl`, the daemon reads the same directory, and
  the app imports it chunk by chunk as you listen. A better tier uploaded from the phone replaces it.
