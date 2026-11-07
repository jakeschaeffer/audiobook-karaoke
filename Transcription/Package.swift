// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Transcription",
  // The package owns a small set of user-visible strings (status lines, error descriptions);
  // its string catalog rides in the module bundle.
  defaultLocalization: "en",
  platforms: [
    .iOS(.v17),
    .watchOS(.v10),
    // iOS/watchOS mirror `Models` and `API`. macOS is additive and only so this package's logic tests
    // run with `swift test` on the host instead of needing a simulator round trip.
    .macOS(.v14),
  ],
  products: [
    // `Snips` rides the product the app already links, so adding snips costs no project.pbxproj
    // edits (docs/cross-repo-snips-plan.md §1.2). Remove it from this line before upstreaming
    // `Transcription` on its own.
    .library(
      name: "Transcription",
      targets: ["Transcription", "Snips"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1")
  ],
  targets: [
    .target(
      name: "Transcription",
      dependencies: [
        .product(name: "Logging", package: "swift-log")
      ],
      resources: [
        .process("Resources")
      ]
    ),
    // The shared snip algorithms: Swift ports of the podcast player's TypeScript, checked against
    // its golden fixtures. Foundation only, no UI, no Apple media frameworks. Destined for the
    // shared `snipkit` package (plan Part 3); kept here until that repo exists.
    .target(
      name: "SnipCore",
      dependencies: []
    ),
    // Everything snip-related that touches Apple frameworks or the transcript store: the record
    // model, the JSON store, capture, heard tracking. The app target holds only views on top.
    .target(
      name: "Snips",
      dependencies: ["SnipCore", "Transcription"]
    ),
    .testTarget(
      name: "TranscriptionTests",
      dependencies: ["Transcription"]
    ),
    .testTarget(
      name: "SnipCoreTests",
      dependencies: ["SnipCore"],
      resources: [.copy("Golden")]
    ),
    .testTarget(
      name: "SnipsTests",
      dependencies: ["Snips", "Transcription"]
    ),
  ]
)
