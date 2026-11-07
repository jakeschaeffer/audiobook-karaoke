import Foundation
import SwiftData

@Model
public final class PlaybackHistory {
  public var id: String
  public var itemID: String
  public var actionType: String
  public var title: String?
  public var position: TimeInterval
  public var timestamp: Date

  public init(
    id: String = UUID().uuidString,
    itemID: String,
    actionType: ActionType,
    title: String?,
    position: TimeInterval,
    timestamp: Date = Date()
  ) {
    self.id = id
    self.itemID = itemID
    self.actionType = actionType.rawValue
    self.title = title
    self.position = position
    self.timestamp = timestamp
  }

  public var action: ActionType {
    ActionType(rawValue: actionType) ?? .play
  }
}

extension PlaybackHistory {
  public enum ActionType: String, CaseIterable {
    case play
    case pause
    case seek
    case sync
    case chapter
    case timerStarted
    case timerCompleted
    case timerExtended
  }
}

@MainActor
extension PlaybackHistory {
  public static func fetch(itemID: String) throws -> [PlaybackHistory] {
    let context = ModelContextProvider.shared.context
    let predicate = #Predicate<PlaybackHistory> { history in
      history.itemID == itemID
    }
    let descriptor = FetchDescriptor<PlaybackHistory>(
      predicate: predicate,
      sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
    )
    return try context.fetch(descriptor)
  }

  public static func record(
    itemID: String,
    action: ActionType,
    title: String? = nil,
    position: TimeInterval
  ) {
    let context = ModelContextProvider.shared.context
    let entry = PlaybackHistory(
      itemID: itemID,
      actionType: action,
      title: title,
      position: position
    )
    context.insert(entry)
    try? context.save()
  }

}
