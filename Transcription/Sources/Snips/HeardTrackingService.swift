import Foundation
import SnipCore

/// Keeps one `HeardTracker` per book by sampling the playhead, with no hooks in the players: seeks
/// are inferred from position jumps, exactly as the podcast player does (heard_v1).
///
/// Sampling runs on the main actor because the sampler reads main-actor player state. 250 ms while
/// playing, once a second idle. Wall time comes from `Date`, which keeps running while the phone
/// sleeps, so a long suspension reads as the heard stretch simply continuing.
@MainActor
public final class HeardTrackingService {
  public typealias Sampler = @MainActor () -> PlaybackSample?

  /// A cold start assumes this much before the resume point was heard (the podcast player's rule).
  public static let assumeHeardBeforeMs = 180_000
  /// Samples this soon after returning to the foreground are ignored: the speaker model extrapolates
  /// its position while suspended and snaps back once the socket reconnects, which would read as a
  /// backward seek (docs/cross-repo-snips-plan.md §1.3).
  public static let foregroundQuietPeriod: TimeInterval = 2

  private let sampler: Sampler
  private var trackers: [String: HeardTracker] = [:]
  private var lastSample: PlaybackSample?
  private var loop: Task<Void, Never>?
  private var quietUntil: Date = .distantPast

  public init(sampler: @escaping Sampler) {
    self.sampler = sampler
  }

  public func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let playing = self.sampleOnce()
        try? await Task.sleep(for: playing ? .milliseconds(250) : .seconds(1))
      }
    }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
  }

  /// Call when the app returns to the foreground.
  public func didBecomeActive() {
    quietUntil = Date().addingTimeInterval(Self.foregroundQuietPeriod)
  }

  /// Start of the heard stretch containing `positionMs` for `itemID`; `positionMs` itself when the
  /// book was never sampled.
  public func heardFrom(itemID: String, positionMs: Int) -> Int {
    trackers[itemID]?.heardFrom(positionMs) ?? positionMs
  }

  /// Feed one sample; exposed for tests. Returns whether playback was in progress.
  @discardableResult
  public func sampleOnce(now: Date = Date()) -> Bool {
    guard let sample = sampler() else {
      lastSample = nil
      return false
    }
    guard now >= quietUntil else { return sample.isPlaying }
    let wallMs = Int((now.timeIntervalSince1970 * 1000).rounded())
    // A new book, or the same book now read from the other output (the speaker adopted after
    // the phone had it loaded at a stale position, or a handoff), starts from the resume rule:
    // the position change is a change of source, not a seek, and must not shrink the first
    // snip's reach to the moment of the switch.
    let switchedOutput = lastSample?.itemID == sample.itemID && lastSample?.output != sample.output
    if trackers[sample.itemID] == nil || switchedOutput {
      var tracker = HeardTracker()
      tracker.reset(startMs: sample.positionMs, assumeHeardBeforeMs: Self.assumeHeardBeforeMs)
      trackers[sample.itemID] = tracker
    }
    trackers[sample.itemID]?.tick(
      posMs: sample.positionMs,
      playing: sample.isPlaying,
      speed: sample.speed,
      wallMs: wallMs
    )
    lastSample = sample
    return sample.isPlaying
  }
}
