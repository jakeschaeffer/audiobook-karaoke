import Foundation

// A port of the podcast player's web/src/player/heard.ts (heard_v1), checked against its golden file
// contracts/golden/heard/heard_v1.json. Change the TypeScript first, under a new version, never this
// port alone (docs/cross-repo-snips-plan.md, Part 3).

/// What the listener has actually heard of the current recording, so a snip never reaches back into
/// audio that was skipped, and never loses audio that was heard just because the listener jumped
/// around inside it.
///
/// Played stretches are kept as merged intervals. A snip's `heard_from_ms` is the start of the heard
/// stretch that contains the tap: skipping back 15 s inside audio already played keeps the whole
/// stretch; skipping forward past unheard audio starts a new one.
public struct HeardTracker: Sendable {
  /// Stretches closer together than this count as one (timer granularity, tiny seeks).
  public static let mergeGapMs = 2_000
  /// A position jump this much beyond what playback time explains is a seek nobody told us about.
  static let jumpToleranceMs = 3_000

  /// `[start, end]`, matching the golden file's shape.
  public typealias Range = [Int]

  private var ranges: [(Int, Int)] = []
  private var runStart = 0
  private var lastPos = 0
  private var lastWall: Int?

  public init() {}

  /// Start over for a newly loaded recording at `startMs`. `assumeHeardBeforeMs` marks that much
  /// audio before the start as heard: used for a resume point, which is where the listener stopped
  /// listening.
  public mutating func reset(startMs: Int, assumeHeardBeforeMs: Int = 0) {
    ranges = []
    if assumeHeardBeforeMs > 0 && startMs > 0 {
      ranges.append((max(0, startMs - assumeHeardBeforeMs), startMs))
    }
    runStart = startMs
    lastPos = startMs
    lastWall = nil
  }

  /// A deliberate jump: skip buttons, scrubbing, a chapter or transcript tap, lock-screen seek.
  public mutating func jump(fromMs: Int, toMs: Int) {
    closeRun(fromMs)
    runStart = toMs
    lastPos = toMs
    lastWall = nil
  }

  /// A position update. Detects jumps that did not come through `jump`, while ignoring stalls:
  /// buffering advances wall time but not position, which is not a jump.
  public mutating func tick(posMs: Int, playing: Bool, speed: Double, wallMs: Int) {
    let delta = posMs - lastPos
    let jumped: Bool
    if playing, let lastWall {
      let expected = Double(max(0, wallMs - lastWall)) * speed
      jumped = delta < -1_000 || Double(delta) > expected + Double(Self.jumpToleranceMs)
    } else {
      jumped = abs(delta) > Self.jumpToleranceMs
    }
    if jumped {
      closeRun(lastPos)
      runStart = posMs
    }
    lastPos = posMs
    lastWall = playing ? wallMs : nil
  }

  /// Start of the heard stretch containing `posMs`; `posMs` itself when nothing before it was heard.
  public func heardFrom(_ posMs: Int) -> Int {
    for (start, end) in Self.merge(ranges + [(runStart, max(runStart, posMs))]) {
      if start <= posMs && posMs <= end + Self.mergeGapMs { return min(start, posMs) }
    }
    return posMs
  }

  /// For debugging and tests.
  public func heardRanges(_ posMs: Int) -> [Range] {
    Self.merge(ranges + [(runStart, max(runStart, posMs))]).map { [$0.0, $0.1] }
  }

  private mutating func closeRun(_ endMs: Int) {
    if endMs > runStart { ranges = Self.merge(ranges + [(runStart, endMs)]) }
  }

  private static func merge(_ input: [(Int, Int)]) -> [(Int, Int)] {
    // Stable sort by start, like Array.prototype.sort.
    let sorted = input.enumerated()
      .filter { $0.element.1 >= $0.element.0 }
      .sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
      .map(\.element)
    var out: [(Int, Int)] = []
    for (s, e) in sorted {
      if let last = out.last, s <= last.1 + mergeGapMs {
        out[out.count - 1].1 = max(last.1, e)
      } else {
        out.append((s, e))
      }
    }
    return out
  }
}
