// frost.swift — make a "frosted" copy of a wallpaper: aspect-fill to the main
// display, heavy gaussian blur, then a translucent colour wash on top.
//
//   swift libexec/frost.swift <in> <out.png> <#RRGGBB> <wash opacity 0–1> <blur radius> [out width px]
//
// Used for Helium's new tab page, which can't be see-through, so it shows a
// pre-blurred wallpaper instead.

import AppKit
import CoreImage

let a = CommandLine.arguments
guard a.count == 6 || a.count == 7, let opacity = Double(a[4]), let radius = Double(a[5]) else {
  FileHandle.standardError.write("usage: frost.swift <in> <out.png> <#RRGGBB> <opacity> <blur>\n".data(using: .utf8)!)
  exit(2)
}
guard let input = CIImage(contentsOf: URL(fileURLWithPath: a[1])) else {
  FileHandle.standardError.write("can't read \(a[1])\n".data(using: .utf8)!); exit(1)
}

// Target = main display in pixels (fallback 2560x1600).
let screen = NSScreen.main
let scale = screen?.backingScaleFactor ?? 2
let size = CGSize(width: (screen?.frame.width ?? 1280) * scale,
                  height: (screen?.frame.height ?? 800) * scale)

// Aspect-fill + centre crop.
let s = max(size.width / input.extent.width, size.height / input.extent.height)
var img = input.transformed(by: CGAffineTransform(scaleX: s, y: s))
let dx = (img.extent.width - size.width) / 2, dy = (img.extent.height - size.height) / 2
img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX - dx, y: -img.extent.minY - dy))

// Blur (clamp edges so they don't fade to transparent), then crop back.
img = img.clampedToExtent()
  .applyingGaussianBlur(sigma: radius * scale)
  .cropped(to: CGRect(origin: .zero, size: size))

// Colour wash.
let hex = a[3].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
let v = UInt32(hex, radix: 16) ?? 0
let wash = CIImage(color: CIColor(red: CGFloat((v >> 16) & 0xff) / 255,
                                  green: CGFloat((v >> 8) & 0xff) / 255,
                                  blue: CGFloat(v & 0xff) / 255,
                                  alpha: CGFloat(opacity)))
  .cropped(to: img.extent)
img = wash.composited(over: img)

// Optional downscale (blurred images survive it fine; keeps data URIs small).
if a.count == 7, let w = Double(a[6]), w > 0, w < Double(size.width) {
  let k = w / Double(size.width)
  img = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": k, "inputAspectRatio": 1])
}

let ctx = CIContext()
guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }
do {
  try ctx.writePNGRepresentation(of: img, to: URL(fileURLWithPath: a[2]), format: .RGBA8, colorSpace: cs)
} catch {
  FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!); exit(1)
}
