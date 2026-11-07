import Foundation
import Testing

@testable import Transcription

@Suite("Request planning")
struct RequestRunTests {
  @Test("Contiguous indices chunk into runs of the limit")
  func contiguousRuns() {
    let runs = HostTranscriptSource.requestRuns(for: Array(0..<14), limit: 6)
    #expect(runs == [[0, 1, 2, 3, 4, 5], [6, 7, 8, 9, 10, 11], [12, 13]])
  }

  @Test("Disjoint indices split on the gap instead of spanning it")
  func disjointSplits() {
    // Without the split, [0, 1, 240] becomes one /captions fetch from 0s to 72,300s — the whole book
    // downloaded to keep three chunks. A JIT scheduler produces exactly this shape after a seek.
    let runs = HostTranscriptSource.requestRuns(for: [0, 1, 240, 241], limit: 6)
    #expect(runs == [[0, 1], [240, 241]])
  }

  @Test("Duplicates and empty input are tolerated")
  func degenerateInputs() {
    #expect(HostTranscriptSource.requestRuns(for: [], limit: 6).isEmpty)
    #expect(HostTranscriptSource.requestRuns(for: [3, 3, 4], limit: 6) == [[3, 4]])
  }
}

@Suite("Silence vs absence")
struct BackfillTests {
  private func segment(_ seg: Int, at start: TimeInterval) -> TranscriptSegment {
    TranscriptSegment(seg: seg, track: 1, start: start, end: start + 2, text: "t", words: nil)
  }

  /// A source whose "daemon" has content everywhere except the silent chunks, and nothing past the
  /// coverage end.
  private func stubbedSource(
    silent: Set<Int>,
    coverageEndsAfter lastContent: Int
  ) -> HostTranscriptSource {
    var source = HostTranscriptSource()
    source.fetchOverride = { @Sendable [silent] _, from, to in
      var result: [TranscriptSegment] = []
      var index = TranscriptGrid.index(containing: from)
      while TranscriptGrid.range(of: index).lowerBound < to {
        if !silent.contains(index), index <= lastContent {
          result.append(
            self.segment(index * 1000, at: TranscriptGrid.range(of: index).lowerBound + 1)
          )
        }
        index += 1
      }
      return result
    }
    return source
  }

  @Test("A silent chunk at a request-window seam still gets an empty row")
  func silenceAcrossWindowSeam() async throws {
    // Chunk 5 is silent; the next content (6, 7) arrives in the SECOND window of the request
    // (windows are 6 chunks wide). A window-scoped backfill misses this: within window one, 5 is the
    // trailing gap and looks like absence. Call-scoped, it's interior silence and must be covered —
    // otherwise the scheduler re-imports it on every pass, forever.
    let source = stubbedSource(silent: [5], coverageEndsAfter: 7)
    var byIndex: [Int: TranscriptChunk] = [:]
    for try await chunk in source.chunks(forItem: "i", indices: Array(0...7)) {
      byIndex[chunk.chunkIndex] = chunk
    }

    #expect(Set(byIndex.keys) == Set(0...7))
    #expect(byIndex[5]?.segments.isEmpty == true)
    #expect(byIndex[4]?.segments.isEmpty == false)
  }

  @Test("Chunks past the end of the transcript stay uncovered")
  func absenceStaysUncovered() async throws {
    // Content ends at chunk 3 (a partial transcript from a cancelled job). Chunks 4-7 are absence,
    // not silence: covering them would make the reader claim the book is readable there and stop the
    // job UI from offering to resume.
    let source = stubbedSource(silent: [], coverageEndsAfter: 3)
    var produced = Set<Int>()
    for try await chunk in source.chunks(forItem: "i", indices: Array(0...7)) {
      produced.insert(chunk.chunkIndex)
    }
    #expect(produced == Set(0...3))
  }

  @Test("Interior silence right before the coverage end is still covered")
  func silenceBeforeCoverageEnd() async throws {
    let source = stubbedSource(silent: [2], coverageEndsAfter: 3)
    var byIndex: [Int: TranscriptChunk] = [:]
    for try await chunk in source.chunks(forItem: "i", indices: Array(0...7)) {
      byIndex[chunk.chunkIndex] = chunk
    }
    #expect(Set(byIndex.keys) == Set(0...3))
    #expect(byIndex[2]?.segments.isEmpty == true)
  }
}

@Suite("Worker API decoding")
struct WorkerDecodeTests {
  @Test("Status with no transcript decodes nulls as zeros")
  func statusWithNulls() throws {
    // Verbatim shape from a live probe of an untranscribed item: segments and covered_secs are
    // null, not 0 — a non-optional decode would throw and the UI would show an error instead of the
    // transcribe button.
    let json = """
      {"item_id": "7b2616bb", "has_transcript": false, "segments": null,
       "covered_secs": null, "job": null}
      """
    let status = try WorkerClient.decodeStatus(Data(json.utf8))
    #expect(!status.coverage.hasTranscript)
    #expect(status.coverage.coveredSecs == 0)
    #expect(status.coverage.segments == 0)
    #expect(status.job == nil)
  }

  @Test("Status with a running job decodes the fields the progress UI needs")
  func statusWithRunningJob() throws {
    // Field set from caption_worker.py Job.public(); extra fields we don't model must be ignored.
    let json = """
      {"item_id": "f4f72906", "has_transcript": true, "segments": 5210,
       "covered_secs": 16150.5,
       "job": {"id": "a3f2b8c19d04", "item_id": "f4f72906", "title": "Goblet",
               "model": "small", "state": "running", "tracks_total": 39, "tracks_done": 8,
               "audio_total": 72830.2, "audio_done": 16150.5, "pct": 22.2, "rtf": 4.6,
               "eta_secs": 12321.0, "error": null, "queued_at": 1789.0,
               "started_at": 1790.0, "finished_at": null}}
      """
    let status = try WorkerClient.decodeStatus(Data(json.utf8))
    let job = try #require(status.job)
    #expect(job.state == .running)
    #expect(job.isActive)
    #expect(job.pct == 22.2)
    #expect(job.etaSecs == 12321.0)
    #expect(job.id == "a3f2b8c19d04")
  }

  @Test("A finished or cancelled job is not active")
  func inactiveStates() throws {
    for state in ["done", "error", "cancelled"] {
      let json = """
        {"id": "x", "item_id": "y", "state": "\(state)", "pct": 100.0,
         "rtf": null, "eta_secs": null, "error": null}
        """
      let job = try JSONDecoder().decode(TranscriptionJob.self, from: Data(json.utf8))
      #expect(!job.isActive)
    }
  }
}

@Suite("Transcript export")
struct TranscriptExportTests {
  @Test("JSONL matches the worker's wire shape row for row")
  func wireShape() throws {
    let segments = [
      TranscriptSegment(
        seg: 1500,
        track: 2,
        start: 63.016,
        end: 65.5,
        text: "Hello there.",
        words: [TranscriptWord(text: " Hello", start: 63.02, end: 63.9)]
      ),
      TranscriptSegment(seg: 100, track: 1, start: 1.0, end: 2.0, text: "First.", words: nil),
    ]
    let lines = String(data: try TranscriptExport.jsonl(segments), encoding: .utf8)!
      .split(separator: "\n").map(String.init)
    #expect(lines.count == 2)

    // Sorted by start regardless of input order.
    let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
    #expect(first["seg"] as? Int == 100)
    #expect(first["words"] as? [[String: Any]] != nil)
    #expect((first["words"] as! [Any]).isEmpty)

    let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as! [String: Any]
    #expect(second["track"] as? Int == 2)
    #expect(second["start"] as? Double == 63.02)
    let word = (second["words"] as! [[String: Any]])[0]
    #expect(word["w"] as? String == " Hello")
    #expect(word["s"] as? Double == 63.02)
  }
}
