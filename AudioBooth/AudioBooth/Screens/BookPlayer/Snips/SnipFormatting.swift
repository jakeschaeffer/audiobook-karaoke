import Foundation
import Snips
import Transcription

/// Shared formatting for snip surfaces.
enum SnipFormatting {
  /// "1:02:10" or "2:10", from book-absolute milliseconds.
  static func clock(_ ms: Int) -> String {
    let total = max(0, ms / 1000)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }

  /// "1:02:10 – 1:03:10 · 60 s"
  static func span(_ snip: Snip) -> String {
    "\(clock(snip.startMs)) – \(clock(snip.endMs)) · \(length(snip.lengthMs))"
  }

  /// "60 s", "2 min", "1 min 30 s"
  static func length(_ ms: Int) -> String {
    let seconds = Int((Double(ms) / 1000).rounded())
    if seconds < 60 { return "\(seconds) s" }
    let minutes = seconds / 60
    let rest = seconds % 60
    return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
  }
}
