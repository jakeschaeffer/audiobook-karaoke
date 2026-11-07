import API
import Foundation
import Logging
import Models
import Snips
import SwiftUI
import Transcription

/// The app's one handle on snips: starts heard tracking, owns the store, captures on a tap, and
/// holds the small amount of UI state the snip surfaces share (the card after a capture, which list
/// or editor is open). Observable so the player re-renders when a snip lands.
@MainActor
@Observable
final class SnipAppBridge {
  static let shared = SnipAppBridge()

  /// Bumped on every write so lists refetch.
  private(set) var version = 0
  /// The snip just taken, shown in the capture card until it times out or is acted on.
  private(set) var lastCapture: Snip?
  /// The book whose snip list is open, if any.
  var listItemID: String?
  /// The snip open in the editor, if any.
  var editing: Snip?
  /// Whether the editor opened straight into the note (the card's Add note, the list's Note action).
  private(set) var editingFocusesNote = false

  /// Open the editor on a snip; `focusingNote` puts the keyboard in its note field.
  func edit(_ snip: Snip, focusingNote: Bool = false) {
    editingFocusesNote = focusingNote
    editing = snip
  }

  private let heard = HeardTrackingService(sampler: { SnipPositionSource.sample() })
  private let store = SnipStore(root: SnipStore.defaultRoot())
  /// Reviewed In/Out points for Jake's existing bookmarks, shipped as `Snips/bookmark-spans.json`.
  private let reviewedSpans: CuratedBookmarkSpans = {
    guard let url = Bundle.main.url(forResource: "bookmark-spans", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let spans = try? CuratedBookmarkSpans(data: data)
    else { return .empty }
    return spans
  }()

  // FORK-BEGIN(server-jobs): the same remote the karaoke sheet uses, so a snip taken with no
  // transcript surface open can pull the text for its stretch from the daemon. Computed: this
  // bridge outlives any change of server. With no server, and in the store build, there is no
  // remote and snips use whatever the device already transcribed.
  #if SPEAKER_STACK
  private var remote: (any RemoteTranscriptService)? {
    guard CompanionSettings.supports(.captions) else { return nil }
    return DaemonRemoteService(
      endpoint: .current,
      authorization: {
        guard let server = await Audiobookshelf.shared.authentication.server else { return nil }
        return try? await server.freshToken.bearer
      }
    )
  }
  #else
  private let remote: (any RemoteTranscriptService)? = nil
  #endif
  // FORK-END(server-jobs)
  private var cardTimer: Task<Void, Never>?

  private static let lengthKey = "snipLengthSeconds"
  private static let cardDuration: Duration = .seconds(8)

  private init() {}

  /// How far back a new snip reaches; a per-device preference.
  var length: SnipLength {
    get { SnipLength(rawValue: UserDefaults.standard.integer(forKey: Self.lengthKey)) ?? .default }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: Self.lengthKey)
      version += 1
    }
  }

  func start() {
    heard.start()
  }

  func didBecomeActive() {
    heard.didBecomeActive()
  }

  // MARK: - Capture

  /// Take a snip of what is playing now. Returns nil, with a toast, when nothing is.
  @discardableResult
  func capture() async -> Snip? {
    #if SPEAKER_STACK
    // The speaker's position on the phone is an extrapolation from the last tick; after the app
    // slept it can be stale. One /status round trip before reading it keeps a speaker snip
    // honest. Local-only playback skips this entirely.
    if SpeakerSessionManager.shared.current != nil {
      await SpeakerSessionManager.shared.refreshFromDaemon()
    }
    #endif
    guard let sample = SnipPositionSource.sample() else {
      Toast(error: String(localized: "Nothing is playing", table: "Snips")).show()
      return nil
    }
    let context = SnipCapture.Context(
      serverID: serverID,
      source: SnipPositionSource.source(for: sample.itemID),
      sample: sample,
      heardFromMs: heard.heardFrom(itemID: sample.itemID, positionMs: sample.positionMs),
      length: length
    )
    let startMs = max(0, sample.positionMs - length.milliseconds)
    let (segments, tiers) = await transcript(itemID: sample.itemID, startMs: startMs, endMs: sample.positionMs)
    let snip = SnipCapture.make(context, segments: segments, tiers: tiers)
    do {
      try await store.save(snip)
    } catch {
      AppLogger.player.error("Snip could not be saved: \(error)")
      Toast(error: String(localized: "Couldn't save the snip", table: "Snips")).show()
      return nil
    }
    version += 1
    showCard(snip)
    return snip
  }

  private func showCard(_ snip: Snip) {
    lastCapture = snip
    cardTimer?.cancel()
    cardTimer = Task { [weak self] in
      try? await Task.sleep(for: Self.cardDuration)
      guard !Task.isCancelled else { return }
      self?.dismissCard()
    }
  }

  func dismissCard() {
    cardTimer?.cancel()
    lastCapture = nil
  }

  /// The card's Undo: the snip is soft-deleted, so a mistaken undo is itself recoverable.
  func undoLastCapture() async {
    guard let snip = lastCapture else { return }
    dismissCard()
    await delete(snip)
  }

  // MARK: - Reads and writes

  var serverID: String {
    ModelContextProvider.shared.activeServerID ?? "fallback"
  }

  func snips(forItem itemID: String) async -> [Snip] {
    (try? await store.snips(forItem: itemID, serverID: serverID)) ?? []
  }

  func unreadableCount() async -> Int {
    (try? await store.unreadableCount()) ?? 0
  }

  func save(_ snip: Snip) async {
    do {
      try await store.save(snip)
      version += 1
    } catch {
      AppLogger.player.error("Snip could not be saved: \(error)")
      Toast(error: String(localized: "Couldn't save the snip", table: "Snips")).show()
    }
  }

  func delete(_ snip: Snip) async {
    do {
      try await store.delete(id: snip.id)
      version += 1
    } catch {
      AppLogger.player.error("Snip could not be deleted: \(error)")
    }
  }

  /// Re-read the excerpt for a (possibly moved) span. Used by the editor as In/Out change, and by
  /// the list for snips taken before any text was stored.
  func withFreshExcerpt(_ snip: Snip) async -> Snip {
    let (segments, tiers) = await transcript(itemID: snip.itemID, startMs: snip.startMs, endMs: snip.endMs)
    var updated = snip
    if let result = TranscriptExcerpt.excerpt(from: segments, startMs: snip.startMs, endMs: snip.endMs, tiers: tiers) {
      updated.excerpt = result.text
      updated.excerptTier = result.tier?.rawValue
    }
    return updated
  }

  /// Snips saved with no text (the transcript hadn't reached that stretch yet) get one once it has.
  func fillMissingExcerpts(forItem itemID: String) async {
    for snip in await snips(forItem: itemID) where snip.excerpt == nil {
      let fresh = await withFreshExcerpt(snip)
      if fresh.excerpt != nil { await save(fresh) }
    }
  }

  // MARK: - Bookmarks

  /// Audiobookshelf bookmarks (a titled point in whole seconds) become snips: the reviewed span when
  /// `bookmark-spans.json` has one for that bookmark, otherwise the current length ending at that
  /// point. The title is kept as the note. Runs once per bookmark. Returns how many were imported.
  func importBookmarks(forItem itemID: String) async -> Int {
    guard let bookmarks = try? Bookmark.fetch(bookID: itemID), !bookmarks.isEmpty else { return 0 }
    let existing = Set(await snips(forItem: itemID).compactMap(\.importedBookmarkTime))
    let source = SnipPositionSource.source(for: itemID)
    var imported = 0
    for bookmark in bookmarks where !existing.contains(bookmark.time) {
      let anchorMs = bookmark.time * 1000
      let reviewed = reviewedSpans.span(itemID: itemID, bookmarkTime: bookmark.time)
      let (segments, tiers) = await transcript(
        itemID: itemID,
        startMs: reviewed?.startMs ?? anchorMs - length.milliseconds,
        endMs: reviewed?.endMs ?? anchorMs
      )
      let snip = SnipCapture.fromBookmark(
        time: bookmark.time,
        title: bookmark.title,
        createdAt: bookmark.createdAt,
        itemID: itemID,
        serverID: serverID,
        source: source,
        length: length,
        reviewedSpan: reviewed,
        segments: segments,
        tiers: tiers
      )
      await save(snip)
      imported += 1
    }
    return imported
  }

  // MARK: - Transcript

  /// Stored segments overlapping `[fromMs, toMs]`, for the editor's tappable words.
  func segments(itemID: String, fromMs: Int, toMs: Int) async -> [TranscriptSegment] {
    await transcript(itemID: itemID, startMs: fromMs, endMs: toMs).0
  }

  private func transcript(
    itemID: String,
    startMs: Int,
    endMs: Int
  ) async -> ([TranscriptSegment], [Int: TranscriptProvenance]) {
    guard let store = try? TranscriptStore.shared(for: serverID, appGroup: AppGroup.identifier) else {
      return ([], [:])
    }
    let range = max(0, TimeInterval(startMs) / 1000 - 1)...(TimeInterval(endMs) / 1000 + 1)
    if let source = remote?.source {
      await store.importMissing(forItem: itemID, in: range, from: source)
    }
    let segments = (try? await store.segments(forItem: itemID, in: range)) ?? []
    let tiers = (try? await store.chunkProvenances(forItem: itemID)) ?? [:]
    return (segments, tiers)
  }
}
