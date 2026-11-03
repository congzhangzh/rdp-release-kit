// The main display's modes, and a switch to the largest one up to a width (test/mac-host.sh:
// the runner's screen is 1024 x 768, small in the web demo's 1920 x 1080 page; the Windows
// test sets 1600 x 900 the same way).
//   swift display-mode.swift [max width]      prints the modes, then the one in use
import CoreGraphics
import Foundation

let maxWidth = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1600 : 1600
let display = CGMainDisplayID()
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
for m in modes { print("mode \(m.width)x\(m.height) pixels \(m.pixelWidth)x\(m.pixelHeight) usable \(m.isUsableForDesktopGUI())") }
let best = modes.filter { $0.isUsableForDesktopGUI() && $0.width <= maxWidth && $0.pixelWidth == $0.width }
    .max { ($0.width * $0.height) < ($1.width * $1.height) }
if let best, let cur = CGDisplayCopyDisplayMode(display), best.width > cur.width {
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, display, best, nil)
    let err = CGCompleteDisplayConfiguration(config, .permanently)
    print("switch to \(best.width)x\(best.height): \(err == .success ? "done" : "error \(err.rawValue)")")
}
if let now = CGDisplayCopyDisplayMode(display) { print("now \(now.width)x\(now.height)") }
