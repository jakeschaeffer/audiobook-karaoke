import Foundation

/// Identifies a downloaded track's real container so it can be saved with the extension Core Audio
/// expects.
///
/// `AVAudioFile(forReading:)` treats the path extension as the file-type hint, and a wrong hint is
/// fatal, not advisory: a 392MB `.m4b` saved as `transcribe-….mp3` fails `ExtAudioFileOpenURL` with
/// `kAudioFileInvalidFileError` ('dta?') even though the bytes are a perfectly good AAC book. The
/// daemon's `/audio` proxy passes through whatever container ABS stores — this library alone holds
/// mp3 *and* m4b — so the extension must be derived per download, never assumed.
enum AudioFileType {
  /// Extension inferred from the file's leading bytes — ground truth, preferred over any header.
  ///
  /// Needs the first 12 bytes; returns nil when the signature is unrecognized.
  static func fileExtension(sniffing data: Data) -> String? {
    guard data.count >= 12 else { return nil }
    let bytes = [UInt8](data.prefix(12))

    func ascii(_ range: Range<Int>) -> String {
      String(bytes: bytes[range], encoding: .ascii) ?? ""
    }

    if ascii(4..<8) == "ftyp" { return "m4a" }  // MP4 family: m4a/m4b/mp4 all open as m4a
    if ascii(0..<3) == "ID3" { return "mp3" }
    if ascii(0..<4) == "fLaC" { return "flac" }
    if ascii(0..<4) == "OggS" { return "ogg" }
    if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
    if ascii(0..<4) == "FORM", ["AIFF", "AIFC"].contains(ascii(8..<12)) { return "aiff" }
    if ascii(0..<4) == "caff" { return "caf" }
    // Raw MPEG sync word. ADTS AAC (layer bits 00) before MPEG audio layers I–III.
    if bytes[0] == 0xFF {
      if bytes[1] & 0xF6 == 0xF0 { return "aac" }
      if bytes[1] & 0xE0 == 0xE0 { return "mp3" }
    }
    return nil
  }

  /// Extension for an HTTP `Content-Type`, nil when missing or too generic to trust
  /// (`application/octet-stream` says nothing about the container).
  static func fileExtension(forContentType contentType: String?) -> String? {
    guard let contentType else { return nil }
    let mime = contentType.split(separator: ";")[0]
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
    switch mime {
    case "audio/mpeg", "audio/mp3", "audio/mpeg3": return "mp3"
    case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/x-m4b", "audio/m4b": return "m4a"
    case "audio/aac", "audio/aacp": return "aac"
    case "audio/flac", "audio/x-flac": return "flac"
    case "audio/ogg", "application/ogg", "audio/opus", "audio/vorbis": return "ogg"
    case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
    case "audio/aiff", "audio/x-aiff": return "aiff"
    case "audio/webm": return "webm"
    default: return nil
    }
  }

  /// Whether Core Audio can open this container at all. Ogg/Opus/WebM have no `AudioFile` component
  /// on iOS — for those the honest answer is "transcribe on the host", whose ffmpeg reads anything.
  static func isCoreAudioReadable(_ fileExtension: String) -> Bool {
    !["ogg", "opus", "webm"].contains(fileExtension.lowercased())
  }
}
