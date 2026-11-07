import Foundation
import SwiftData

@Model
public final class Series {
  public var id: String
  public var name: String
  public var sequence: String

  public init(id: String, name: String, sequence: String) {
    self.id = id
    self.name = name
    self.sequence = sequence
  }
}
