import Foundation

enum PlayerControl: String, CaseIterable, Identifiable, Codable {
  case speed
  case timer
  case bookmarks
  case transcript
  case history
  case volume
  case equalizer
  case snip
  case lock
  case pageMatch

  var id: String { rawValue }

  var displayName: LocalizedStringResource {
    switch self {
    case .speed: "Speed"
    case .timer: "Timer"
    case .bookmarks: "Bookmarks"
    case .transcript: "Transcript"
    case .history: "History"
    case .volume: "Volume"
    case .equalizer: "Equalizer"
    case .snip: LocalizedStringResource("Snip", table: "Snips")
    case .lock: "Lock"
    case .pageMatch: "Page Match"
    }
  }

  var systemImage: String {
    switch self {
    case .speed: "speedometer"
    case .timer: "moon.zzz.fill"
    case .bookmarks: "bookmark.fill"
    case .transcript: "text.bubble"
    case .history: "clock.arrow.circlepath"
    case .volume: "speaker.wave.2.fill"
    case .equalizer: "slider.vertical.3"
    case .snip: "scissors"
    case .lock: "lock.fill"
    case .pageMatch: "camera.viewfinder"
    }
  }

  static var `default`: [PlayerControl] {
    [.speed, .timer, .snip, .transcript]
  }
}
