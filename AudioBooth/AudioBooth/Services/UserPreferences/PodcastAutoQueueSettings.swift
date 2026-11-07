import Foundation

struct PodcastAutoQueueSettings: Codable, Equatable {
  enum Position: String, Codable, CaseIterable, Identifiable {
    case off
    case top
    case bottom

    var id: String { rawValue }

    var title: LocalizedStringResource {
      switch self {
      case .off: "Off"
      case .top: "Top of Queue"
      case .bottom: "Bottom of Queue"
      }
    }

    var isEnabled: Bool { self != .off }
  }

  var position: Position
  var limit: PodcastAutoQueueLimit
  var baselinePublishedAt: Int64?

  init(
    position: Position = .off,
    limit: PodcastAutoQueueLimit = .all,
    baselinePublishedAt: Int64? = nil
  ) {
    self.position = position
    self.limit = limit
    self.baselinePublishedAt = baselinePublishedAt
  }
}

struct PodcastAutoQueueStore: RawRepresentable, Equatable {
  var settings: [String: PodcastAutoQueueSettings]

  init(settings: [String: PodcastAutoQueueSettings] = [:]) {
    self.settings = settings
  }

  init?(rawValue: String) {
    guard let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: PodcastAutoQueueSettings].self, from: data)
    else {
      return nil
    }
    self.settings = decoded
  }

  var rawValue: String {
    guard let data = try? JSONEncoder().encode(settings),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

enum PodcastAutoQueueLimit: String, Codable, CaseIterable, Identifiable {
  case one
  case two
  case three
  case five
  case ten
  case last24Hours
  case last7Days
  case last14Days
  case last30Days
  case all

  var id: String { rawValue }

  var maxCount: Int? {
    switch self {
    case .one: 1
    case .two: 2
    case .three: 3
    case .five: 5
    case .ten: 10
    default: nil
    }
  }

  var timeWindow: TimeInterval? {
    switch self {
    case .last24Hours: 24 * 3600
    case .last7Days: 7 * 86400
    case .last14Days: 14 * 86400
    case .last30Days: 30 * 86400
    default: nil
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .one: "Latest Episode"
    case .two: "2 Latest Episodes"
    case .three: "3 Latest Episodes"
    case .five: "5 Latest Episodes"
    case .ten: "10 Latest Episodes"
    case .last24Hours: "Last 24 Hours"
    case .last7Days: "Last 7 Days"
    case .last14Days: "Last 14 Days"
    case .last30Days: "Last 30 Days"
    case .all: "All New Episodes"
    }
  }
}
