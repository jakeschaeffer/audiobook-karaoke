import API
import Foundation
import SwiftData

@Model
public final class Chapter {
  public var id: Int
  public var start: TimeInterval
  public var end: TimeInterval
  public var title: String

  public init(from chapter: Book.Media.Chapter) {
    self.id = chapter.id
    self.start = chapter.start
    self.end = chapter.end
    self.title = chapter.title
  }

  public init(id: Int, start: TimeInterval, end: TimeInterval, title: String) {
    self.id = id
    self.start = start
    self.end = end
    self.title = title
  }
}
