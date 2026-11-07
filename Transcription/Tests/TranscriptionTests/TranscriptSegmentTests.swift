import Foundation
import Testing

@testable import Transcription

@Suite("Segment decoding and word lookup")
struct TranscriptSegmentTests {
  /// Verbatim from `GET /captions?item_id=<goblet>&from=22756&to=22766`.
  static let wire = """
    {"seg": 7401, "track": 16, "start": 22755.95, "end": 22757.27,
     "text": "He can't avoid us forever.",
     "words": [{"w": " He", "s": 22755.95, "e": 22756.11},
               {"w": " can't", "s": 22756.11, "e": 22756.45},
               {"w": " avoid", "s": 22756.45, "e": 22756.67},
               {"w": " us", "s": 22756.67, "e": 22756.95},
               {"w": " forever.", "s": 22756.95, "e": 22757.27}]}
    """

  @Test("Decodes the daemon's compact wire format")
  func decodesWireFormat() throws {
    let segment = try JSONDecoder().decode(
      TranscriptSegment.self,
      from: Data(Self.wire.utf8)
    )
    #expect(segment.seg == 7401)
    #expect(segment.track == 16)
    #expect(segment.hasWordTimings)
    #expect(segment.words?.count == 5)
    // The leading space in each word is preserved, so concatenating words reproduces the text.
    let joined = (segment.words ?? []).map(\.text).joined()
    #expect(joined.trimmingCharacters(in: .whitespaces) == segment.text)
  }

  @Test("Cleaned paragraphs have no words and fall back to segment highlight")
  func cleanedHasNoWords() throws {
    // The stage-2 cleanup pass emits paragraph-granular rows with no words[]; karaoke must degrade to
    // highlighting the whole segment rather than crashing or showing nothing.
    let json = #"{"seg": 1, "track": 1, "start": 0, "end": 10, "text": "Prose."}"#
    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
    #expect(!segment.hasWordTimings)
    #expect(segment.word(at: 5) == nil)
  }

  @Test("Word lookup stays lit across ASR timing gaps")
  func wordLookupBridgesGaps() throws {
    let segment = try JSONDecoder().decode(
      TranscriptSegment.self,
      from: Data(Self.wire.utf8)
    )
    #expect(segment.word(at: 22755.95)?.text == " He")
    #expect(segment.word(at: 22756.50)?.text == " avoid")
    #expect(segment.word(at: 22757.00)?.text == " forever.")
    // Before the first word starts, nothing is lit.
    #expect(segment.word(at: 22755.0) == nil)
    // Past the last word's end it stays lit rather than blanking — ASR stamps carry ±0.2-0.5s error,
    // so strict containment would flicker.
    #expect(segment.word(at: 22758.0)?.text == " forever.")
  }

  @Test("A zero-width segment does not trap on range construction")
  func zeroWidthSegment() {
    let segment = TranscriptSegment(seg: 1, track: 1, start: 10, end: 9, text: "x", words: nil)
    #expect(segment.timeRange == 10...10)
  }
}

@Suite("Chunk blob codec")
struct ChunkCodecTests {
  @Test("Round-trips segments through the compressed blob")
  func roundTrips() throws {
    let segments = (0..<100).map { i in
      TranscriptSegment(
        seg: i,
        track: 1,
        start: Double(i) * 3,
        end: Double(i) * 3 + 2.5,
        text: "Segment number \(i) of some spoken prose.",
        words: [TranscriptWord(text: " word", start: Double(i) * 3, end: Double(i) * 3 + 0.4)]
      )
    }
    let blob = try ChunkCodec.encode(segments)
    let decoded = try ChunkCodec.decode(blob)
    #expect(decoded == segments)
  }

  @Test("Compression meaningfully shrinks a realistic chunk")
  func compresses() throws {
    // ~97 segments is a real 300s chunk on Goblet.
    let segments: [TranscriptSegment] = (0..<97).map { i in
      let base = Double(i) * 3
      let words: [TranscriptWord] = (0..<11).map { w in
        let wordStart = base + Double(w) * 0.2
        return TranscriptWord(text: " word", start: wordStart, end: wordStart + 0.18)
      }
      return TranscriptSegment(
        seg: i,
        track: 16,
        start: base,
        end: base + 2.8,
        text: "Harry looked around the dark corridor and said nothing at all.",
        words: words
      )
    }
    let raw = try JSONEncoder().encode(segments)
    let blob = try ChunkCodec.encode(segments)
    #expect(blob.count < raw.count / 2)
  }

  @Test("An empty chunk round-trips — silence is coverable")
  func emptyChunk() throws {
    let blob = try ChunkCodec.encode([])
    #expect(try ChunkCodec.decode(blob).isEmpty)
  }
}
