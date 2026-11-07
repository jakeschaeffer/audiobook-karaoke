import Foundation

/// The pure planning half of a transcription run, extracted so it runs under `swift test` — the
/// engine file is excluded from the simulator *and* macOS builds (SpeechAnalyzer linking), which
/// meant its resume and silence-backfill decisions were never covered by a test until this split.
public enum TranscriptionPlan {
  /// Resume logic: a track whose every grid chunk is already present needs no work.
  public static func tracksNeedingWork(
    _ tracks: [TrackInfo],
    coverage: TranscriptCoverage
  ) -> [TrackInfo] {
    tracks.filter { track in
      !coverage.isCovered(track.start...max(track.start, track.start + track.duration - 1))
    }
  }

  /// Silence vs absence (the host importer learned this first): segments only exist where speech
  /// was found, so a quiet stretch — or a book's silent tail — leaves grid chunks with no row, and
  /// coverage reports a hole forever. A finished run transcribed every second of its listed
  /// tracks, so any still-uncovered chunk lying inside their spans *is* silence and should get an
  /// empty row. Computed once at end-of-run rather than per track because tracks share boundary
  /// chunks: a per-track pass could write an empty row over a neighbor's content.
  public static func silentBackfillChunks(
    transcribed tracks: [TrackInfo],
    coverage: TranscriptCoverage,
    duration: TimeInterval
  ) -> [Int] {
    let total = TranscriptGrid.chunkCount(forDuration: duration)
    var empties: [Int] = []
    for index in 0..<total where !coverage.chunks.contains(index) {
      let span = TranscriptGrid.range(of: index)
      let upper = min(span.upperBound, duration)
      let insideTranscribed = tracks.contains { track in
        span.lowerBound >= track.start - 1 && upper <= track.start + track.duration + 1
      }
      if insideTranscribed {
        empties.append(index)
      }
    }
    return empties
  }
}
