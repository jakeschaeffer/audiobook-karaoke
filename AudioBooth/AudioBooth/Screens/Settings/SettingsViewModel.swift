import API
import Foundation
import Logging
import SimpleKeychain
import SwiftUI
import UIKit

final class SettingsViewModel: SettingsView.Model {
  init() {
    UserDefaults.standard.set(true, forKey: "pulse-disable-support-prompts")
    UserDefaults.standard.set(true, forKey: "pulse-disable-report-issue-prompts")
    UserDefaults.standard.set(true, forKey: "pulse-disable-settings-prompts")

    super.init(
      tipJar: TipJarViewModel(),
      playbackSessionList: PlaybackSessionListViewModel(),
      storagePreferences: StoragePreferencesViewModel()
    )
  }

}
