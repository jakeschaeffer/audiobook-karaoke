import Foundation
import Testing
import Transcription

@testable import Snips

struct SnipCaptureTests {
  /// Ten one-second words from 100 s: "w100 w101 … w109", with a leading space on all but the first.
  private func segment(from start: TimeInterval, words: Int, timed: Bool = true) -> TranscriptSegment {
    let timedWords = (0..<words).map { i in
      TranscriptWord(
        text: (i == 0 ? "" : " ") + "w\(Int(start) + i)",
        start: start + TimeInterval(i),
        end: start + TimeInterval(i + 1)
      )
    }
    return TranscriptSegment(
      seg: Int(start),
      track: 0,
      start: start,
      end: start + TimeInterval(words),
      text: timedWords.map(\.text).joined(),
      words: timed ? timedWords : nil
    )
  }

  private func context(position: TimeInterval, heardFromMs: Int, length: SnipLength) -> SnipCapture.Context {
    SnipCapture.Context(
      serverID: "s",
      source: .init(title: "Book", author: nil),
      sample: PlaybackSample(itemID: "item", position: position, isPlaying: true, speed: 1, output: .local),
      heardFromMs: heardFromMs,
      length: length
    )
  }

  @Test func spanIsTheChosenLengthEndingAtTheTap() {
    let snip = SnipCapture.make(context(position: 200, heardFromMs: 0, length: .sixty), segments: [])
    #expect(snip.startMs == 140_000)
    #expect(snip.endMs == 200_000)
    #expect(snip.anchorMs == 200_000)
    #expect(snip.excerpt == nil)
  }

  @Test func heardFromCapsTheReachBack() {
    let snip = SnipCapture.make(context(position: 200, heardFromMs: 170_000, length: .ninety), segments: [])
    #expect(snip.startMs == 170_000)
    #expect(snip.lengthMs == 30_000)
  }

  @Test func excerptIsTheWordsWhoseMidpointsLieInside() {
    let segments = [segment(from: 100, words: 10), segment(from: 110, words: 10)]
    let snip = SnipCapture.make(context(position: 115, heardFromMs: 0, length: .fifteen), segments: segments)
    // Raw span [100 s, 115 s]; In already sits on a sentence start, Out finishes the sentence (120 s).
    #expect(snip.startMs == 100_000)
    #expect(snip.endMs == 120_000)
    #expect(snip.excerpt == (100...119).map { "w\($0)" }.joined(separator: " "))
  }

  @Test func inSnapsToTheNearestSentenceStartWithinReach() {
    // Sentences start at 95, 102 and 130 s; a tap at 133 s with 30 s reaches back to 103 s.
    let segments = [segment(from: 95, words: 7), segment(from: 102, words: 28), segment(from: 130, words: 3)]
    let snip = SnipCapture.make(context(position: 133, heardFromMs: 0, length: .thirty), segments: segments)
    #expect(snip.startMs == 102_000)
    #expect(snip.endMs == 133_000)  // the sentence ends at 133 s exactly: nothing to finish
  }

  @Test func snappingNeverReachesBelowHeardFrom() {
    let segments = [segment(from: 95, words: 7), segment(from: 102, words: 40)]
    let snip = SnipCapture.make(context(position: 133, heardFromMs: 104_000, length: .thirty), segments: segments)
    #expect(snip.startMs == 104_000)
    // Out: the sentence runs to 142 s, 9 s past the tap, beyond reach, so Out stays at the tap.
    #expect(snip.endMs == 133_000)
  }

  @Test func interpolatedSegmentsStillGiveAnExcerpt() {
    let segments = [segment(from: 100, words: 10, timed: false)]
    let result = TranscriptExcerpt.excerpt(from: segments, startMs: 104_000, endMs: 107_000)
    #expect(result?.text.hasPrefix("w10") == true)
    #expect(result?.tier == nil)
  }

  @Test func bookmarkImportKeepsTitleAsNote() {
    let snip = SnipCapture.fromBookmark(
      time: 125,
      title: "  Important scene ",
      createdAt: Date(timeIntervalSince1970: 1),
      itemID: "item",
      serverID: "s",
      source: .init(title: "Book", author: nil),
      length: .thirty,
      segments: []
    )
    #expect(snip.note == "Important scene")
    #expect(snip.importedBookmarkTime == 125)
    #expect(snip.startMs == 95_000 && snip.endMs == 125_000)
    #expect(snip.captureOutput == .bookmark)
  }
}

struct CuratedBookmarkSpansTests {
  static let json = """
    {"schema":"bookmark-spans/1","spans":[
      {"item_id":"book","bookmark_time":1410,"start_ms":1357860,"end_ms":1410000},
      {"item_id":"book","bookmark_time":9,"start_ms":20000,"end_ms":9000}
    ]}
    """

  @Test func looksUpByBookAndSecond() throws {
    let spans = try CuratedBookmarkSpans(data: Data(Self.json.utf8))
    let found = try #require(spans.span(itemID: "book", bookmarkTime: 1410))
    #expect(found.startMs == 1_357_860 && found.endMs == 1_410_000)
    #expect(spans.span(itemID: "book", bookmarkTime: 1411) == nil)
    #expect(spans.span(itemID: "other", bookmarkTime: 1410) == nil)
    // In after Out is nonsense and is ignored, so the import falls back to the fixed length.
    #expect(spans.span(itemID: "book", bookmarkTime: 9) == nil)
  }

  @Test func reviewedSpanWinsOverTheFixedLength() {
    let snip = SnipCapture.fromBookmark(
      time: 1410,
      title: "x",
      createdAt: Date(),
      itemID: "book",
      serverID: "s",
      source: .init(title: "Book", author: nil),
      length: .thirty,
      reviewedSpan: (1_357_860, 1_410_000),
      segments: []
    )
    #expect(snip.startMs == 1_357_860 && snip.endMs == 1_410_000)
    #expect(snip.importedBookmarkTime == 1410)
  }
}

struct HeardTrackingServiceTests {
  @MainActor
  @Test func inferredSkipMovesHeardFrom() {
    var current = PlaybackSample(itemID: "item", position: 100, isPlaying: true, speed: 1, output: .local)
    let box = SampleBox(current)
    let service = HeardTrackingService(sampler: { box.sample })
    var now = Date(timeIntervalSince1970: 1_000)
    // Play 100 → 110 in 250 ms steps.
    for step in 0..<40 {
      current = PlaybackSample(
        itemID: "item",
        position: 100 + Double(step) * 0.25,
        isPlaying: true,
        speed: 1,
        output: .local
      )
      box.sample = current
      now = now.addingTimeInterval(0.25)
      service.sampleOnce(now: now)
    }
    // Resume assumption: 180 s before the first sample counts as heard.
    #expect(service.heardFrom(itemID: "item", positionMs: 110_000) == 0)
    // Skip forward 60 s past unheard audio: a new stretch starts there.
    box.sample = PlaybackSample(itemID: "item", position: 170, isPlaying: true, speed: 1, output: .local)
    now = now.addingTimeInterval(0.25)
    service.sampleOnce(now: now)
    box.sample = PlaybackSample(itemID: "item", position: 172, isPlaying: true, speed: 1, output: .local)
    now = now.addingTimeInterval(2)
    service.sampleOnce(now: now)
    #expect(service.heardFrom(itemID: "item", positionMs: 172_000) == 170_000)
  }

  @MainActor
  @Test func switchingOutputRestartsFromTheResumeRule() {
    let box = SampleBox(PlaybackSample(itemID: "item", position: 38_000, isPlaying: false, speed: 1, output: .local))
    let service = HeardTrackingService(sampler: { box.sample })
    var now = Date(timeIntervalSince1970: 1_000)
    service.sampleOnce(now: now)
    // The speaker turns out to be playing the same book somewhere else entirely.
    box.sample = PlaybackSample(itemID: "item", position: 20, isPlaying: true, speed: 1, output: .speaker)
    now = now.addingTimeInterval(1)
    service.sampleOnce(now: now)
    box.sample = PlaybackSample(itemID: "item", position: 30, isPlaying: true, speed: 1, output: .speaker)
    now = now.addingTimeInterval(10)
    service.sampleOnce(now: now)
    // Not 20 s (the moment of the switch): the resume rule reaches back to the start of the book.
    #expect(service.heardFrom(itemID: "item", positionMs: 30_000) == 0)
  }

  @MainActor
  final class SampleBox {
    var sample: PlaybackSample?
    init(_ sample: PlaybackSample?) { self.sample = sample }
  }
}
