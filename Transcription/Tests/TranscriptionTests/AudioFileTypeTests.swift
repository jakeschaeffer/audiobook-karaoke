import Foundation
import Testing

@testable import Transcription

@Suite("Audio container detection")
struct AudioFileTypeTests {
  /// The bug that motivated this file: Greenlights is one 392MB m4b; saved as `.mp3` it fails
  /// `ExtAudioFileOpenURL` with 'dta?'. The sniffer must call it m4a from bytes alone.
  @Test("m4b/m4a (ftyp at offset 4) sniffs as m4a")
  func sniffsMP4Family() {
    // Real m4b preamble: 4-byte box length, "ftypM4B ".
    let m4b = Data([0x00, 0x00, 0x00, 0x20] + Array("ftypM4B ".utf8))
    #expect(AudioFileType.fileExtension(sniffing: m4b) == "m4a")
  }

  @Test("ID3-tagged and bare-sync MP3s sniff as mp3")
  func sniffsMP3() {
    let id3 = Data(Array("ID3".utf8) + [0x04, 0x00, 0x00, 0, 0, 0, 0, 0, 0])
    #expect(AudioFileType.fileExtension(sniffing: id3) == "mp3")
    // MPEG-1 Layer III sync: 0xFF 0xFB.
    let sync = Data([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 8))
    #expect(AudioFileType.fileExtension(sniffing: sync) == "mp3")
  }

  @Test("ADTS AAC (0xFFF, layer 00) sniffs as aac, not mp3")
  func sniffsADTS() {
    let adts = Data([0xFF, 0xF1, 0x50, 0x80] + [UInt8](repeating: 0, count: 8))
    #expect(AudioFileType.fileExtension(sniffing: adts) == "aac")
  }

  @Test("flac, ogg, wav signatures")
  func sniffsOthers() {
    #expect(
      AudioFileType.fileExtension(sniffing: Data(Array("fLaC".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]))
        == "flac"
    )
    #expect(
      AudioFileType.fileExtension(sniffing: Data(Array("OggS".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]))
        == "ogg"
    )
    #expect(
      AudioFileType.fileExtension(sniffing: Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)))
        == "wav"
    )
  }

  @Test("unknown bytes and short reads return nil")
  func sniffUnknown() {
    #expect(AudioFileType.fileExtension(sniffing: Data(Array("hello world!".utf8))) == nil)
    #expect(AudioFileType.fileExtension(sniffing: Data([0x00, 0x01])) == nil)
    #expect(AudioFileType.fileExtension(sniffing: Data()) == nil)
  }

  @Test("Content-Type mapping covers the containers ABS actually serves")
  func contentTypes() {
    #expect(AudioFileType.fileExtension(forContentType: "audio/mpeg") == "mp3")
    #expect(AudioFileType.fileExtension(forContentType: "audio/mp4") == "m4a")
    #expect(AudioFileType.fileExtension(forContentType: "audio/mp4; charset=binary") == "m4a")
    #expect(AudioFileType.fileExtension(forContentType: "Audio/FLAC") == "flac")
    #expect(AudioFileType.fileExtension(forContentType: "audio/ogg") == "ogg")
    #expect(AudioFileType.fileExtension(forContentType: "application/octet-stream") == nil)
    #expect(AudioFileType.fileExtension(forContentType: nil) == nil)
  }

  @Test("Core Audio readability: ogg family is host-only")
  func readability() {
    #expect(AudioFileType.isCoreAudioReadable("m4a"))
    #expect(AudioFileType.isCoreAudioReadable("mp3"))
    #expect(AudioFileType.isCoreAudioReadable("flac"))
    #expect(!AudioFileType.isCoreAudioReadable("ogg"))
    #expect(!AudioFileType.isCoreAudioReadable("opus"))
    #expect(!AudioFileType.isCoreAudioReadable("webm"))
  }
}
