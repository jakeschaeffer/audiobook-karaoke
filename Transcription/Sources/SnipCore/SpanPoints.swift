// A port of the podcast player's web/src/lib/spanPoints.ts (span_points_v1), checked against
// contracts/golden/span-points/. Change the TypeScript first, under a new version.

/// The snip editor's rules for In and Out.
public enum SpanPoints {
  public enum Point: String, Sendable, CaseIterable { case `in`, out }

  public struct Span: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public init(startMs: Int, endMs: Int) {
      self.startMs = startMs
      self.endMs = endMs
    }
    public var lengthMs: Int { endMs - startMs }
  }

  /// The shortest span the editor allows.
  public static let minSpanMs = 1_000

  /// Whether a word belongs to the span: its midpoint lies inside it, both ends included. The
  /// midpoint is fractional, as in JavaScript.
  public static func wordInSpan(startMs: Int, endMs: Int, span: Span) -> Bool {
    let mid = (Double(startMs) + Double(endMs)) / 2
    return mid >= Double(span.startMs) && mid <= Double(span.endMs)
  }

  /// Put `point` at `ms`. Moving In past Out (or Out before In) carries the other point along,
  /// keeping the snip's length, so a tap far from the current span starts a new span there instead
  /// of collapsing to one second.
  public static func set(_ point: Point, at ms: Int, in span: Span, durationMs: Int) -> Span {
    let len = max(minSpanMs, span.endMs - span.startMs)
    switch point {
    case .in:
      let start = max(0, min(ms, durationMs - minSpanMs))
      return Span(
        startMs: start,
        endMs: start > span.endMs - minSpanMs ? min(durationMs, start + len) : span.endMs
      )
    case .out:
      let end = min(durationMs, max(ms, minSpanMs))
      return Span(
        startMs: end < span.startMs + minSpanMs ? max(0, end - len) : span.startMs,
        endMs: end
      )
    }
  }
}
