import Foundation

/// How far back from the tap a new highlight reaches. Chosen by the listener in settings; the
/// heard-from point still caps it, so a highlight never reaches into audio that was skipped.
public enum SnipLength: Int, CaseIterable, Codable, Sendable, Identifiable {
  case fifteen = 15
  case thirty = 30
  case fortyFive = 45
  case sixty = 60
  case ninety = 90
  case twoMinutes = 120

  public static let `default`: SnipLength = .thirty

  public var id: Int { rawValue }
  public var seconds: Int { rawValue }
  public var milliseconds: Int { rawValue * 1000 }

  /// "45 s", "2 min": short enough for a segmented control.
  public var shortLabel: String {
    rawValue % 60 == 0 ? "\(rawValue / 60) min" : "\(rawValue) s"
  }
}
