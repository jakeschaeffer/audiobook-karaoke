import AppIntents
import Foundation
import Snips

/// Snip from Shortcuts, the Action Button (through a one-action shortcut), or Siri: saves the last
/// stretch heard of the playing audiobook, phone or speaker, with its text.
struct SnipIntent: AppIntent {
  static let title = LocalizedStringResource("Snip", table: "Snips")
  static let description = IntentDescription(
    LocalizedStringResource("Saves the last stretch you heard of the playing audiobook, with its text.", table: "Snips")
  )
  static let openAppWhenRun = false

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let snip = await SnipAppBridge.shared.capture()
    guard let snip else {
      throw AppIntentError.noAudiobookPlaying
    }
    let text = snip.excerpt.map { String($0.prefix(140)) }
    return .result(
      dialog: text.map { IntentDialog(stringLiteral: $0) }
        ?? IntentDialog(LocalizedStringResource("Snipped at \(SnipFormatting.clock(snip.endMs))", table: "Snips"))
    )
  }
}
