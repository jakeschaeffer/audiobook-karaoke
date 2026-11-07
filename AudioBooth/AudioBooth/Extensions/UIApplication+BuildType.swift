import UIKit

extension UIApplication {
  private static let isTestFlight =
    Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"

  static var isDebug: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }

  enum BuildType {
    case debug
    case testFlight
    case appStore
  }

  static var buildType: BuildType {
    if isDebug {
      return .debug
    } else if isTestFlight {
      return .testFlight
    } else {
      return .appStore
    }
  }

  static var appVersion: String {
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    return "\(version) (\(build))"
  }
}
