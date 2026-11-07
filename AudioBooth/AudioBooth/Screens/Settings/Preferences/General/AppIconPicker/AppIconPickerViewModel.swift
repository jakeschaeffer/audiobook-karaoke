import Logging
import SwiftUI

final class AppIconPickerViewModel: AppIconPickerView.Model {
  static let shared = AppIconPickerViewModel()

  override init(currentIcon: AppIcon = .default, isChanging: Bool = false) {
    super.init(currentIcon: currentIcon, isChanging: isChanging)
  }

  override func onAppear() {
    let iconName = UIApplication.shared.alternateIconName
    if iconName == nil {
      currentIcon = .default
    } else if let icon = AppIcon(rawValue: iconName!) {
      currentIcon = icon
    } else {
      currentIcon = .default
    }
  }

  override func setAlternateAppIcon(icon: AppIcon) {
    guard !isChanging else { return }

    let iconName: String? = (icon == .default) ? nil : icon.rawValue
    guard UIApplication.shared.alternateIconName != iconName else { return }

    isChanging = true

    UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
      DispatchQueue.main.async {
        self?.isChanging = false

        if let error {
          AppLogger.viewModel.error("Failed to update the app's icon: \(error)")
        } else {
          AppLogger.viewModel.info("Successfully changed icon to: \(icon)")
          self?.currentIcon = icon
        }
      }
    }
  }
}
