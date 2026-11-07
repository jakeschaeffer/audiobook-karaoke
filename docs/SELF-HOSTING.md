# Running your own

This app is [AudioBooth](https://github.com/AudioBooth/AudioBooth) with follow-along transcripts,
snips, and playback on a speaker. It works against any Audiobookshelf. Everything beyond that is
optional, and nothing about any particular server is compiled in: you give the app one address, and
it asks that server what it offers.

## What you can run

Pick the row you want. Each includes the ones above it.

| you get | you need to run |
|---|---|
| Audiobook player, snips, transcripts made on the iPhone (iOS 26, on a device with Apple's speech transcription) | [Audiobookshelf](https://www.audiobookshelf.org/) |
| Server transcripts, followed along on any device | **daemon** + **worker** |
| Playback on a speaker, with phone/speaker handoff | a LinkPlay speaker (WiiM) on the daemon's network |
| Physical buttons, sensors, spoken book announcements | Home Assistant + MQTT |
| Kindle position sync | KOReader on the Kindle + the **kosync** profile |

## What runs where

```
 iPhone (this app)
   │  ├─ your ABS address ──────────────▶ Audiobookshelf        library, users, progress
   │  │
   │  └─ one companion address ─────────▶ daemon (:8788)        GET /capabilities tells the app the rest
   │       (the ABS token is the login)    │  │  │
   │                                       │  │  └─ LinkPlay ──▶ speaker on the LAN
   │                                       │  └──── Socket.IO ─▶ Audiobookshelf
   │                                       └─ reads transcripts/*.jsonl
   └────────────── worker_url ──────────▶ worker (:8790)        whisper jobs; writes transcripts/*.jsonl
```

| software | repo | required? | port | job |
|---|---|---|---|---|
| Audiobookshelf | upstream, unmodified | yes | 13378 | Library, users, progress. The only source of progress truth and the only login. |
| **AudioBook Karaoke** (iOS) | this repo | yes | – | The app. |
| **abs-session daemon** | `abs-session` | for any server feature | 8788 | Serves transcripts and audio to the app; owns the speaker session. |
| **caption worker** | `abs-session` | for server transcription | 8790 | One whisper job at a time; accepts transcripts the phone made. |
| A tunnel or VPN | your choice | to reach it away from home | – | The app only needs to reach two addresses. |
| kosync | `abs-session` | no | 5758 | Kindle sync. |
| Home Assistant, MQTT | upstream | no | 8123, 1883 | Buttons and sensors. |

The daemon and worker run in Docker from `abs-session/compose.yaml`. Host networking is deliberate: the
speaker has to fetch audio from them over the LAN. [DEPLOYMENT.md](DEPLOYMENT.md) is one complete
working setup, to compare yours against.

**Sizing.** The daemon is light. The worker runs faster-whisper `small`: about 1.5 GB of RAM while
running, most of the CPU cores you give it, and hours per book on a NAS. It runs niced, one job at a
time, and only when asked.

## 1. Audiobookshelf

Set it up per its docs, and make sure the phone can reach it. Create an API token (Settings → Users).
You'll also want a low-privilege test user, whose progress you don't mind scripts moving.

## 2. The server

```bash
git clone <your fork of abs-session> && cd abs-session
cp .env.example .env && chmod 600 .env
mkdir -p secrets
printf 'abs_token: %s\n' '<ABS API token>' > secrets/session.yaml
cp secrets/session.yaml secrets/worker.yaml
chmod 600 secrets/*.yaml
```

Then edit `.env`. Only two values are required:

| variable | set it to |
|---|---|
| `ABS_URL` | Your Audiobookshelf, as this machine reaches it. |
| `AUDIOBOOKS_DIR` | Your library root on this machine. |

Add these if they apply:

| variable | when |
|---|---|
| `WIIM_HOST` | You have a speaker: its LAN IP. Empty means none, and the app hides every speaker control. |
| `WIIM_MAC`, `SPEAKER_NAME` | With a speaker: finds the device again if DHCP moves it, and what the app calls it. |
| `WORKER_URL` | You expose the services on separate hostnames (see below). `none` turns off server transcription. |
| `REQUIRE_ABS_AUTH=1` | You expose the daemon through anything other than Cloudflare Tunnel (see below). |
| `TAKEOVER_USERS` | With a speaker: ABS users whose listening elsewhere should pause it. |
| `PUID`, `PGID` | The user that should own transcripts. Must be able to read your library. |

```bash
docker compose up -d --build
curl http://localhost:8788/capabilities
```

The second command should print what you just configured.

## 3. Reaching it

The app needs to reach the daemon, and the worker if you have one. Pick one:

- **Same network, or a VPN like Tailscale.** Use `http://<server>:8788`. The worker is found
  automatically on port 8790. On a private network the services need no login. iOS will ask for Local
  Network permission the first time.
- **Cloudflare Tunnel.** One hostname per service, because the routes are absolute paths:
  `captions.example.com` → `:8788` and `jobs.example.com` → `:8790`. Set
  `WORKER_URL=https://jobs.example.com`, then `docker compose up -d`. The daemon recognises tunnel traffic
  by its `Cf-Ray` header and requires a valid ABS token on it.
- **Any other reverse proxy.** The same, plus `REQUIRE_ABS_AUTH=1` on both services. **Without it the
  daemon treats proxied traffic as trusted LAN traffic, with no login.** Pass WebSockets through for
  `/events`. This setting also locks the browser `/player` page, which can't send a token.

Never forward the raw ports to the internet.

## 4. The app

You need a Mac with Xcode and a paid Apple Developer account for a phone install (the entitlements
need it). The simulator needs neither.

```bash
git clone <your fork of this repo> && cd audiobooth-fork
cp AudioBooth/Local.xcconfig.example AudioBooth/Local.xcconfig   # your team and org id
cp scripts/local.env.example scripts/local.env                   # for the scripts
xcodebuild -downloadPlatform watchOS                             # the scheme embeds the Watch app
./scripts/dev-build-run.sh                                       # build and run in the simulator
```

Sign in to Audiobookshelf, then **Settings → Companion Server**, type the daemon's address, and tap
**Connect**. The screen lists what it found. A bare hostname means https; an IP or `host:port` means
http.

To skip typing it on builds only you install, set it at build time in `Local.xcconfig`. Leave the scheme
off, because an xcconfig reads `//` as a comment:

```
COMPANION_DAEMON_URL = captions.example.com
COMPANION_WORKER_URL = jobs.example.com
```

That is only where a fresh install starts. Settings can change it, and removing the server stays
removed.

### If you distribute a build

Leave those two values empty in anything others install, and let them type their own.
`AUDIOBOOTH_FEATURES=""` builds the app with no companion support at all: no daemon clients in use, and
no Companion Server screen (FORK-NOTES, "The two builds"). `scripts/testflight.sh` reads your team, bundle
id and App Store Connect key from `scripts/local.env`, and expects four App Store profiles named
`AS <bundle id>[.widget|.watchkitapp|.watchkitapp.AudioBoothWatchWidget]`.

## Checking it works

| check | how |
|---|---|
| Server is up, and says the right things | `curl <daemon>/capabilities` |
| Through a tunnel, a login is required | the same curl answers 401; add `-H "Authorization: Bearer <token>"` and it answers |
| No speaker means no speaker | `curl -X POST <daemon>/play` answers 501 |
| Pressing play plays | `SMOKE_BOOK=<id> ./scripts/smoke-play.sh`: muted, in the simulator, a real press |
| App tests | `cd Transcription && swift test` |
| Server tests | `tests/run.sh` in `abs-session` |

## When it doesn't connect

| Settings says | meaning |
|---|---|
| Couldn't reach that address | Wrong host or port, the phone isn't on that network or VPN, or Local Network permission was denied. |
| Something answered, but it isn't a companion server | Usually the Audiobookshelf address. The companion is a different address. |
| The server refused this login | The daemon's `ABS_URL` points at a different Audiobookshelf from the one you're signed in to. |
| Transcribe on Server shows as unavailable | No worker found. Behind hostnames, set `WORKER_URL` on the daemon; or type the address under Advanced. |
| Speaker shows as unavailable | `WIIM_HOST` is empty. `docker restart` keeps old settings; after editing `.env`, use `docker compose up -d`. |

## Known limits

- **One speaker, and it must speak LinkPlay.** Another kind means a backend behind the same routes:
  [COMPANION-API.md](COMPANION-API.md).
- **Household accounts.** The daemon holds one ABS token, so the speaker plays as that account.
- **`tools/` is one person's pipeline.** `tools/ingest.py` and friends assume particular paths. They are
  optional: books added to Audiobookshelf any way at all work.
