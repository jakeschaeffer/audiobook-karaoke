import Foundation

extension TranscriptStore {
  /// Fills the chunks of `range` that this store lacks from `source`, committing each as it
  /// arrives. Returns how many chunks landed. A source with nothing for the range (no transcript
  /// yet) is not an error here: the caller reads whatever the store holds afterwards.
  ///
  /// The karaoke sheet does the same import inline for its own window; this is the reusable
  /// form, used by snip capture so a tap taken while the speaker plays, with no transcript
  /// surface open, still gets its text (docs/cross-repo-snips-plan.md §1.5).
  @discardableResult
  public func importMissing(
    forItem itemID: String,
    in range: ClosedRange<TimeInterval>,
    from source: any TranscriptSource
  ) async -> Int {
    guard let missing = try? coverage(forItem: itemID).missingChunks(in: range), !missing.isEmpty else {
      return 0
    }
    var committed = 0
    do {
      for try await chunk in source.chunks(forItem: itemID, indices: missing) {
        try commit(chunk)
        committed += 1
      }
    } catch {
      // .noTranscript and transport errors alike: nothing importable right now.
    }
    return committed
  }
}
