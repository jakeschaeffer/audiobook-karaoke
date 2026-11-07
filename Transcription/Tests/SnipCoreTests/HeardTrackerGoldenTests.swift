import Foundation
import Testing

@testable import SnipCore

/// Replays every case in Golden/heard_v1.json against the Swift port.
struct HeardTrackerGoldenTests {
  struct Golden: Decodable {
    let family: String
    let version: String
    let cases: [Case]
  }

  struct Case: Decodable, CustomTestStringConvertible, Sendable {
    let name: String
    let steps: [Step]
    var testDescription: String { name }
  }

  struct Step: Decodable, Sendable {
    let op: String
    var startMs: Int?
    var assumeHeardBeforeMs: Int?
    var posMs: Int?
    var playing: Bool?
    var speed: Double?
    var wallMs: Int?
    var fromMs: Int?
    var toMs: Int?
    var expectFrom: Int?
    var expectRanges: [[Int]]?

    enum CodingKeys: String, CodingKey {
      case op, startMs, assumeHeardBeforeMs, posMs, playing, speed, wallMs, fromMs, toMs, expect
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      op = try c.decode(String.self, forKey: .op)
      startMs = try c.decodeIfPresent(Int.self, forKey: .startMs)
      assumeHeardBeforeMs = try c.decodeIfPresent(Int.self, forKey: .assumeHeardBeforeMs)
      posMs = try c.decodeIfPresent(Int.self, forKey: .posMs)
      playing = try c.decodeIfPresent(Bool.self, forKey: .playing)
      speed = try c.decodeIfPresent(Double.self, forKey: .speed)
      wallMs = try c.decodeIfPresent(Int.self, forKey: .wallMs)
      fromMs = try c.decodeIfPresent(Int.self, forKey: .fromMs)
      toMs = try c.decodeIfPresent(Int.self, forKey: .toMs)
      if op == "heard_from" { expectFrom = try c.decode(Int.self, forKey: .expect) }
      if op == "ranges" { expectRanges = try c.decode([[Int]].self, forKey: .expect) }
    }
  }

  static let golden: Golden = GoldenFiles.load("heard_v1.json")

  @Test func fileIsHeardV1() {
    #expect(Self.golden.version == "heard_v1")
    #expect(Self.golden.cases.count > 0)
  }

  @Test(arguments: golden.cases)
  func replays(_ c: Case) throws {
    var tracker = HeardTracker()
    for (i, step) in c.steps.enumerated() {
      switch step.op {
      case "reset":
        tracker.reset(startMs: try #require(step.startMs), assumeHeardBeforeMs: step.assumeHeardBeforeMs ?? 0)
      case "tick":
        tracker.tick(
          posMs: try #require(step.posMs),
          playing: try #require(step.playing),
          speed: try #require(step.speed),
          wallMs: try #require(step.wallMs)
        )
      case "jump":
        tracker.jump(fromMs: try #require(step.fromMs), toMs: try #require(step.toMs))
      case "heard_from":
        #expect(tracker.heardFrom(try #require(step.posMs)) == step.expectFrom, "step \(i)")
      case "ranges":
        #expect(tracker.heardRanges(try #require(step.posMs)) == step.expectRanges, "step \(i)")
      default:
        Issue.record("unknown op \(step.op) at step \(i)")
      }
    }
  }
}

enum GoldenFiles {
  static func load<T: Decodable>(_ name: String) -> T {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Golden")!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(T.self, from: Data(contentsOf: url))
  }
}
