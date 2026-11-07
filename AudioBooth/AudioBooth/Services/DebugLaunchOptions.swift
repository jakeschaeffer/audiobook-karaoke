#if DEBUG
import API
import BackgroundTasks
import Foundation
import Transcription

/// Launch-argument hooks for driving the app from the command line during development.
///
/// `simctl` has no tap primitive and driving the Simulator's UI through AppleScript needs macOS
/// Accessibility permission, so without this there is no way to script the app into a given screen for
/// a screenshot or a smoke check. Feeding the app's own deep-link handler also avoids SpringBoard's
/// "Open in AudioBook Karaoke?" confirmation, which `simctl openurl` always triggers.
///
/// DEBUG-only by construction: the whole file compiles out of release builds.
///
///     xcrun simctl launch <udid> me.jgrenier.AudioBS \
///       -deeplink "audiobooth://play/<bookID>" -autoOpenTranscript
enum DebugLaunchOptions {
  /// A deep link to run shortly after launch, e.g. `audiobooth://play/<bookID>`.
  static var deepLink: URL? {
    guard let raw = value(for: "-deeplink") else { return nil }
    return URL(string: raw)
  }

  /// Present the transcript sheet as soon as the player appears.
  static var autoOpenTranscript: Bool {
    ProcessInfo.processInfo.arguments.contains("-autoOpenTranscript")
  }

  /// Force the transcript's landscape legibility view regardless of geometry — the only way to
  /// script that surface, since `simctl` cannot rotate a device.
  static var legibilityPreview: Bool {
    ProcessInfo.processInfo.arguments.contains("-legibilityPreview")
  }

  /// Present the speaker sheet as soon as the player appears. Pair with `-speakerIdle` for scripted
  /// verification — see below.
  static var autoOpenSpeaker: Bool {
    ProcessInfo.processInfo.arguments.contains("-autoOpenSpeaker")
  }

  /// Raise the full player and take a snip this many seconds after the deep link (`-autoSnipAfter 5`),
  /// the scripted equivalent of tapping Snip. Writes a real snip file.
  static var autoSnipAfter: TimeInterval? {
    value(for: "-autoSnipAfter").flatMap(TimeInterval.init)
  }

  /// `-smokePlay 15`: once a book is in the player (restored at launch, or from `-deeplink`), give it
  /// a few seconds to settle, press play through the same call the play button makes if it isn't
  /// playing yet, then print one `SMOKE-PLAY` line with how far the playhead moved over that many
  /// seconds. `scripts/smoke-play.sh` reads it; a stall that pauses the player shows as no movement.
  static var smokePlaySeconds: TimeInterval? {
    value(for: "-smokePlay").flatMap(TimeInterval.init)
  }

  /// Open the book's snip list once the deep link has raised the player (`-autoOpenSnips`).
  static var autoOpenSnips: Bool {
    ProcessInfo.processInfo.arguments.contains("-autoOpenSnips")
  }

  /// Open the book's newest snip in the editor: `-autoEditSnip note` focuses the note,
  /// `-autoEditSnip span` doesn't. Pair with `-autoOpenSnips` to open it over the list.
  static var autoEditSnip: String? {
    value(for: "-autoEditSnip")
  }

  /// Present the playback-history sheet as soon as the player appears.
  static var autoOpenHistory: Bool {
    ProcessInfo.processInfo.arguments.contains("-autoOpenHistory")
  }

  /// Start on-device transcription once the transcript sheet settles on missing-transcript. Pair
  /// with `-autoOpenTranscript`. Scripted-run equivalent of tapping "Transcribe on iPhone" — real
  /// work, real store writes, and a real upload to the worker on completion.
  static var autoDeviceTranscribe: Bool {
    ProcessInfo.processInfo.arguments.contains("-autoDeviceTranscribe")
  }

  /// Open the speaker sheet WITHOUT starting playback. Load-bearing for scripted runs: the sheet
  /// normally auto-plays because the menu tap was the user's explicit intent, but a screenshot run
  /// must never make the real bedroom speaker start talking. Idle mode still connects the events
  /// socket (read-only) and renders the full transport UI.
  static var speakerIdle: Bool {
    ProcessInfo.processInfo.arguments.contains("-speakerIdle")
  }

  /// Set the companion server for this and future launches, as if typed into Settings but with no
  /// check; the app's next refresh asks the server what it offers.
  ///
  ///     -companionURL https://captions.example.com [-workerURL https://jobs.example.com]
  ///     -companionURL none      # the fresh-install state: no server at all
  ///
  /// Runs before anything reads the configuration (`AudioBoothApp.init`).
  static func applyCompanionOverrides() {
    guard let address = value(for: "-companionURL") else { return }
    CompanionSettings.clear()
    guard address != "none", let daemon = CompanionSettings.normalizedURL(address) else { return }
    CompanionSettings.save(daemon: daemon, capabilities: nil)
    CompanionSettings.setWorkerOverride(value(for: "-workerURL").flatMap(CompanionSettings.normalizedURL))
  }

  /// Silence the app's own player for scripted runs (`-muted`), so testing never plays out of the
  /// Mac's speakers. Position still advances, which is all the checks read.
  static var muted: Bool {
    ProcessInfo.processInfo.arguments.contains("-muted")
  }

  /// Restores an Audiobookshelf connection from an API token kept **outside** the repository, so a
  /// fresh — or erased — simulator lands authenticated instead of on the "Servers" sheet.
  ///
  /// Why a file on the host rather than a launch argument or a baked-in constant: this has to work
  /// however the app starts (the dev script, Xcode's Run button, or just tapping the icon in the
  /// Simulator), a launch argument only covers the first of those. The file lives at
  /// `~/.config/audiobooth/devauth.json` on the *host*, which is outside the working tree, so the
  /// token cannot be committed even by accident:
  ///
  ///     { "serverURL": "https://books.example", "apiToken": "<abs api token>", "alias": "dev" }
  ///
  /// Use an Audiobookshelf **API token** (Settings → Users → API token), never an account password —
  /// nothing here ever handles a password, and a token can be revoked server-side on its own.
  ///
  /// Must run before `AppDelegate` reads `authentication.server` to pick the SwiftData store,
  /// otherwise the first launch after a restore opens the wrong database.
  static func restoreDevServerIfNeeded() {
    guard let url = devAuthFileURL, let data = try? Data(contentsOf: url) else { return }

    struct DevAuth: Decodable {
      let serverURL: URL
      let apiToken: String
      let alias: String?
    }

    guard let auth = try? JSONDecoder().decode(DevAuth.self, from: data) else {
      print("DEV-AUTH \(url.path) is not valid JSON — ignoring")
      return
    }

    // A deterministic id keeps one per-server database across launches. `Connection`'s default is a
    // fresh UUID, which would strand a new empty store on every cold start.
    let host = auth.serverURL.host ?? "unknown"
    let connectionID = "devauth-\(host)"

    // Never clobber a real login — this is a fallback for an empty keychain, not an override.
    if !Audiobookshelf.shared.authentication.isAuthenticated {
      Audiobookshelf.shared.authentication.restoreConnection(
        Connection(
          id: connectionID,
          serverURL: auth.serverURL,
          token: .apiKey(key: auth.apiToken),
          alias: auth.alias ?? host
        )
      )
      print("DEV-AUTH restored connection to \(auth.serverURL.absoluteString) from \(url.path)")
    }

    // Deliberately outside the branch above. The connection persists in the keychain but the library
    // choice lives in per-server storage, so the second launch is authenticated with no library
    // selected — gating this on "just restored" leaves the app stuck on the Servers sheet forever.
    guard Audiobookshelf.shared.authentication.server?.id == connectionID else { return }
    selectDevLibrary(connectionID: connectionID)
  }

  /// Picks a library for a restored connection.
  ///
  /// `restoreConnection` re-establishes the *session* but skips the login screen, which is also where
  /// a library gets chosen — and `LibrariesService.fetch` only populates the list, it never sets
  /// `current`. Without this the app is genuinely authenticated but Home renders "No Content
  /// Available", which reads like a broken token. Mirrors `ServerViewModel.fetchLibraries`: prefer the
  /// server's default library, else the first one.
  private static func selectDevLibrary(connectionID: String) {
    Task { @MainActor in
      let libraries = Audiobookshelf.shared.libraries
      guard libraries.current == nil else { return }

      guard let fetched = try? await libraries.fetch(serverID: connectionID), !fetched.isEmpty else {
        print("DEV-AUTH restored the connection but no libraries came back")
        return
      }

      let defaultID = Audiobookshelf.shared.authentication.servers[connectionID]?.defaultLibraryID
      let chosen = fetched.first { $0.id == defaultID } ?? fetched[0]
      libraries.current = chosen
      print("DEV-AUTH selected library \(chosen.name)")
    }
  }

  /// Resolution order: explicit flag, then environment, then the conventional host location.
  /// `SIMULATOR_HOST_HOME` is what makes the last one work — inside the simulator `HOME` is the app's
  /// own sandboxed container, not the developer's home directory.
  private static var devAuthFileURL: URL? {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [
      value(for: "-devAuthFile"),
      environment["AUDIOBOOTH_DEV_AUTH_FILE"],
      environment["SIMULATOR_HOST_HOME"].map { "\($0)/.config/audiobooth/devauth.json" },
      environment["HOME"].map { "\($0)/.config/audiobooth/devauth.json" },
    ]
    return
      candidates
      .compactMap { $0 }
      .map { URL(fileURLWithPath: $0) }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Runs the requested deep link through the normal handler.
  ///
  /// Delayed because the handler needs the server connection and library restored first; on a cold
  /// launch the deep link would otherwise resolve against an empty library.
  static func applyIfNeeded() {
    logExperimentProbes()
    if #available(iOS 26.0, *) {
      TranscriptionBenchmark.runIfRequested()
    }
    if let smokePlaySeconds {
      Task { @MainActor in await smokePlay(over: smokePlaySeconds) }
    }
    guard let deepLink else { return }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      DeepLinkManager.shared.handleDeepLink(deepLink)

      // `audiobooth://play/<id>` starts playback but only raises the mini player, so the full player
      // — and with it the transcript sheet — never appears. Raise it explicitly.
      if autoOpenTranscript {
        try? await Task.sleep(for: .seconds(3))
        PlayerManager.shared.showFullPlayer()
      }
      if let autoSnipAfter {
        try? await Task.sleep(for: .seconds(autoSnipAfter))
        PlayerManager.shared.showFullPlayer()
        try? await Task.sleep(for: .seconds(1))
        await SnipAppBridge.shared.capture()
      }
      if autoOpenSnips || autoEditSnip != nil, let itemID = PlayerManager.shared.current?.id {
        let bridge = SnipAppBridge.shared
        try? await Task.sleep(for: .seconds(2))
        PlayerManager.shared.showFullPlayer()
        if autoOpenSnips {
          try? await Task.sleep(for: .seconds(1))
          bridge.listItemID = itemID
        }
        if let mode = autoEditSnip, let newest = await bridge.snips(forItem: itemID).first {
          try? await Task.sleep(for: .seconds(2))
          bridge.edit(newest, focusingNote: mode == "note")
        }
      }
    }
  }

  /// The run behind `-smokePlay`. Its one action is the play button's own call; the rest only reads.
  @MainActor
  private static func smokePlay(over seconds: TimeInterval) async {
    var waited: TimeInterval = 0
    while PlayerManager.shared.current == nil, waited < 30 {
      try? await Task.sleep(for: .milliseconds(250))
      waited += 0.25
    }
    // Pressed after the book has loaded, as a person would: the failure of 2026-10-31 only showed
    // when play followed a finished load (the session-start rewind seek races the first play).
    try? await Task.sleep(for: .seconds(6))
    let pressed = PlayerManager.shared.current?.isPlaying == false
    if pressed {
      PlayerManager.shared.current?.onTogglePlaybackTapped()
    }
    waited = 0
    while PlayerManager.shared.current?.isPlaying != true, waited < 30 {
      try? await Task.sleep(for: .milliseconds(250))
      waited += 0.25
    }
    let from = PlayerManager.shared.current?.preciseCurrentTime
    try? await Task.sleep(for: .seconds(seconds))
    let to = PlayerManager.shared.current?.preciseCurrentTime
    let moved: TimeInterval = if let from, let to { to - from } else { -1 }
    let playing = PlayerManager.shared.current?.isPlaying == true
    print(
      String(
        format: "SMOKE-PLAY pressed=%@ waited=%.1f moved=%.1f over=%.0f playing=%@",
        pressed ? "true" : "false",
        waited,
        moved,
        seconds,
        playing ? "true" : "false"
      )
    )
  }

  /// Track A, experiment 1 (IOS-SPEC §Measure before building): does this device offer `.gpu` to
  /// background tasks? Expected absent on iPhone per Apple DTS — this settles it for *our* hardware
  /// instead of inheriting a forum post's answer. Plain `print` so `devicectl … launch --console`
  /// captures it.
  private static func logExperimentProbes() {
    if #available(iOS 26.0, *) {
      print("EXPERIMENT-1 BGTaskScheduler.supportedResources = \(BGTaskScheduler.supportedResources)")
    } else {
      print("EXPERIMENT-1 unavailable: requires iOS 26")
    }
  }

  private static func value(for flag: String) -> String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
#endif
