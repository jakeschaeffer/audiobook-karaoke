import Foundation

/// The app-group identifier that is actually provisioned for this build.
///
/// Upstream hardcodes `group.me.jgrenier.audioBS` everywhere, which is correct for upstream's team
/// and for simulator builds (this fork's `Local.xcconfig` keeps the simulator on upstream's org id).
/// Device builds under the fork's personal team can't register that group — app-group identifiers
/// are reserved globally — so their entitlements declare `group.<org>.audioBS` with the fork's org
/// instead, and any code that asks for the upstream string gets nil back. Most call sites degrade,
/// but `DownloadManager` fatalErrors: tapping Download, or opening an ebook (whose files live under
/// these directories), crashed the app on device.
///
/// Resolution order: upstream's id if the OS grants it, else the id derived from the bundle
/// identifier's org prefix (`com.example.AudioBS` → `group.com.example.audioBS`), else
/// the upstream string unchanged so callers keep their own fallback behavior.
enum AppGroup {
  static let upstreamIdentifier = "group.me.jgrenier.audioBS"

  static let identifier: String = {
    if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: upstreamIdentifier)
      != nil
    {
      return upstreamIdentifier
    }
    // Bundle ids here are {org}.AudioBS possibly followed by extension suffixes; the org is
    // everything before the AudioBS component.
    if let bundle = Bundle.main.bundleIdentifier {
      let components = bundle.components(separatedBy: ".")
      if let index = components.firstIndex(where: { $0.caseInsensitiveCompare("AudioBS") == .orderedSame }),
        index > 0
      {
        let derived = "group.\(components[..<index].joined(separator: ".")).audioBS"
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: derived) != nil {
          return derived
        }
      }
    }
    return upstreamIdentifier
  }()
}
