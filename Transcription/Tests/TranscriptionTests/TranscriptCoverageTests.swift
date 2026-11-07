import Foundation
import Testing

@testable import Transcription

@Suite("Local coverage")
struct TranscriptCoverageTests {
  @Test("Disjoint coverage survives a backward seek — the case a watermark cannot express")
  func disjointCoverage() {
    // The scenario that rules out a watermark: listen at chapter 20 (~18000s), transcribe ahead, then
    // seek back to chapter 3 (~3000s). Coverage is genuinely two islands.
    let coverage = TranscriptCoverage(chunks: [60, 61, 62])  // 18000..<18900

    #expect(coverage.contains(time: 18100))
    #expect(!coverage.contains(time: 3000))

    // A watermark would report ~18900 covered and the scheduler would skip chapter 3 entirely,
    // rendering nothing exactly where the user is now listening. The set gets it right.
    #expect(coverage.nextUncovered(after: 3000, duration: 72830.2) == 10)
    // ...and forward work already done is not re-queued.
    #expect(coverage.nextUncovered(after: 18000, duration: 72830.2) == 63)
  }

  @Test("nextUncovered returns nil when everything ahead is covered")
  func nextUncoveredNilWhenComplete() {
    let all = TranscriptCoverage(chunks: Set(0..<243))
    #expect(all.nextUncovered(after: 0, duration: 72830.2) == nil)
    #expect(all.nextUncovered(after: 72000, duration: 72830.2) == nil)
  }

  @Test("isCovered requires every chunk touching the range")
  func isCoveredNeedsAllChunks() {
    let coverage = TranscriptCoverage(chunks: [0, 2])
    #expect(coverage.isCovered(0...100))
    #expect(!coverage.isCovered(0...700))  // chunk 1 is missing
    #expect(coverage.missingChunks(in: 0...700) == [1])
  }

  @Test("Ebook-only items report zero rather than dividing by zero")
  func ebookOnlyIsZero() {
    // 31 of the library's 48 items have duration == 0.
    let coverage = TranscriptCoverage(chunks: [])
    #expect(coverage.fraction(of: 0) == 0)
    #expect(TranscriptCoverage(chunks: [0]).fraction(of: 0) == 0)
  }

  @Test("Fraction is clamped and complete coverage reads as 1")
  func fractionClamped() {
    let all = TranscriptCoverage(chunks: Set(0..<243))
    #expect(all.fraction(of: 72830.2) == 1)
    #expect(TranscriptCoverage(chunks: []).fraction(of: 72830.2) == 0)
  }
}

@Suite("Remote coverage")
struct RemoteCoverageTests {
  @Test("Goblet reads as complete despite the trailing-silence shortfall")
  func gobletIsComplete() {
    // Live values: covered_secs 72820.42 against duration 72830.2 — a 9.8s shortfall, because trailing
    // silence produces no segment to cover it. A strict >= test would call the one fully-transcribed
    // book in the library incomplete forever, and offer to "resume" a finished job.
    let remote = RemoteCoverage(hasTranscript: true, segments: 23467, coveredSecs: 72820.42)
    #expect(remote.isComplete(duration: 72830.2))
    #expect(remote.fraction(of: 72830.2) > 0.999)
  }

  @Test("A cancelled job's partial transcript is not complete, though has_transcript is true")
  func partialIsNotComplete() {
    // has_transcript goes true at 5% exactly as it does at 100%, so existence is never completeness.
    let remote = RemoteCoverage(hasTranscript: true, segments: 1200, coveredSecs: 3600)
    #expect(!remote.isComplete(duration: 72830.2))
    #expect(remote.hasTranscript)
  }

  @Test("No transcript is never complete")
  func noTranscriptNotComplete() {
    let remote = RemoteCoverage(hasTranscript: false, segments: 0, coveredSecs: 0)
    #expect(!remote.isComplete(duration: 72830.2))
    // An ebook-only item can't be complete either.
    #expect(!RemoteCoverage(hasTranscript: true, segments: 0, coveredSecs: 0).isComplete(duration: 0))
  }
}
