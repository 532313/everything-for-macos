import CoreGraphics
import Foundation
for opt in [(CGWindowListOption.optionOnScreenOnly, "on-screen"), (.optionAll, "all")] {
    guard let list = CGWindowListCopyWindowInfo(opt.0, kCGNullWindowID) as? [[String: Any]] else { continue }
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner == "Everything" else { continue }
        let name = w[kCGWindowName as String] as? String ?? "(no title)"
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        print("[\(opt.1)] title='\(name)' layer=\(layer) size=\(b["Width"] ?? "?")x\(b["Height"] ?? "?") pos=(\(b["X"] ?? "?"),\(b["Y"] ?? "?"))")
    }
}
