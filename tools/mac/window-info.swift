// window-info — report on-screen windows, so a GUI test can find the
// emulator's window without a human pointing at it.
//
//   window-info [owner-substring]
//
// Prints one line per on-screen window, most recently fronted first:
//   <id> <pid> <x> <y> <w> <h> <owner> :: <title>
//
// The id is what `screencapture -l<id>` wants.
import Foundation
import CoreGraphics

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : ""
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("window-info: cannot list windows\n".data(using: .utf8)!)
    exit(1)
}
for w in windows {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let title = w[kCGWindowName as String] as? String ?? ""
    if !wanted.isEmpty && !owner.lowercased().contains(wanted) && !title.lowercased().contains(wanted) { continue }
    guard let id = w[kCGWindowNumber as String] as? Int,
          let pid = w[kCGWindowOwnerPID as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
    if width < 50 || height < 50 { continue }
    print("\(id) \(pid) \(Int(x)) \(Int(y)) \(Int(width)) \(Int(height)) \(owner) :: \(title)")
}
