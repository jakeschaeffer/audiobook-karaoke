import Foundation
import Testing

@testable import SnipCore

/// Replays Golden/span_points_v1.json against the Swift port.
struct SpanPointsGoldenTests {
  struct Golden: Decodable {
    let version: String
    let minSpanMs: Int
    let setPoint: [SetPoint]
    let wordInSpan: [WordInSpan]
  }

  struct Span: Decodable, Sendable {
    let startMs: Int
    let endMs: Int
  }

  struct SetPoint: Decodable, Sendable, CustomTestStringConvertible {
    let span: Span
    let point: String
    let ms: Int
    let durationMs: Int
    let expect: Span
    var testDescription: String { "\(point) at \(ms) in \(span.startMs)–\(span.endMs) of \(durationMs)" }
  }

  struct WordInSpan: Decodable, Sendable {
    let word: [Int]
    let span: Span
    let expect: Bool
  }

  static let golden: Golden = GoldenFiles.load("span_points_v1.json")

  @Test func fileIsSpanPointsV1() {
    #expect(Self.golden.version == "span_points_v1")
    #expect(Self.golden.minSpanMs == SpanPoints.minSpanMs)
  }

  @Test(arguments: golden.setPoint)
  func setsPoints(_ c: SetPoint) throws {
    let point = try #require(SpanPoints.Point(rawValue: c.point))
    let got = SpanPoints.set(
      point,
      at: c.ms,
      in: .init(startMs: c.span.startMs, endMs: c.span.endMs),
      durationMs: c.durationMs
    )
    #expect(got == .init(startMs: c.expect.startMs, endMs: c.expect.endMs))
  }

  @Test func wordsInSpan() {
    for c in Self.golden.wordInSpan {
      let span = SpanPoints.Span(startMs: c.span.startMs, endMs: c.span.endMs)
      #expect(SpanPoints.wordInSpan(startMs: c.word[0], endMs: c.word[1], span: span) == c.expect, "\(c.word)")
    }
  }
}
