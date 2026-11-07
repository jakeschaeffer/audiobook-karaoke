import Logging

enum AppLogger {
  static let network = Logger(label: "api.network")
  static let authentication = Logger(label: "api.authentication")
  static let libraries = Logger(label: "api.libraries")
}
