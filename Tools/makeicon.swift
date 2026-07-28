import AppKit
import CoreGraphics

// Builds Resources/AppIcon.icns from a square source PNG of an app icon.
//
// The source is a rendered picture of an icon: the artwork sits inside a
// rounded shape, on a background, usually with a baked-in drop shadow. macOS
// wants the artwork itself, on a transparent canvas, clipped to Apple's own
// squircle with the standard padding. So this finds the shape, crops to it,
// re-clips it to a proper superellipse, and lays it out on the 1024pt grid.

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: makeicon <source.png> <output.icns>\n".utf8))
    exit(2)
}
let sourcePath = arguments[1]
let outputPath = arguments[2]

guard let source = NSImage(contentsOfFile: sourcePath),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("could not read \(sourcePath)\n".utf8))
    exit(1)
}

let width = sourceCG.width
let height = sourceCG.height

// MARK: - Read pixels

var pixels = [UInt8](repeating: 0, count: width * height * 4)
let colorSpace = CGColorSpaceCreateDeviceRGB()
pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(data: buffer.baseAddress,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return
    }
    context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))
}

@inline(__always)
func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let index = (y * width + x) * 4
    return (Int(pixels[index]), Int(pixels[index + 1]),
            Int(pixels[index + 2]), Int(pixels[index + 3]))
}

// MARK: - Find the icon shape

/// Background is sampled from the corners, which the shape never reaches.
let corners = [pixel(2, 2), pixel(width - 3, 2), pixel(2, height - 3), pixel(width - 3, height - 3)]
let background = (r: corners.map(\.r).reduce(0, +) / corners.count,
                  g: corners.map(\.g).reduce(0, +) / corners.count,
                  b: corners.map(\.b).reduce(0, +) / corners.count)

/// Saturation ignores the soft grey drop shadow, which is what makes the
/// coloured shape separable from the neutral background around it.
@inline(__always)
func saturation(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Int {
    max(p.r, max(p.g, p.b)) - min(p.r, min(p.g, p.b))
}

@inline(__always)
func differsFromBackground(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
    abs(p.r - background.r) > 18 || abs(p.g - background.g) > 18 || abs(p.b - background.b) > 18
}

var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let p = pixel(x, y)
        // Coloured, or clearly non-background and not a faint shadow.
        guard saturation(p) > 22 || (differsFromBackground(p) && saturation(p) > 10) else { continue }
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}

guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write(Data("could not locate the icon shape\n".utf8))
    exit(1)
}

// The shape is square; take the larger side and re-centre so rounded corners
// (which lose a few pixels of colour) don't bias the crop.
// Inset slightly: the detected bounds include the source shape's own
// antialiased edge, which would otherwise survive as a pale rim once the
// artwork is re-clipped to our squircle.
let detected = max(maxX - minX, maxY - minY) + 1
let inset = Int((Double(detected) * 0.022).rounded())
let side = detected - inset * 2
let centreX = (minX + maxX) / 2
let centreY = (minY + maxY) / 2
var cropX = centreX - side / 2
var cropY = centreY - side / 2
cropX = max(0, min(cropX, width - side))
cropY = max(0, min(cropY, height - side))
let crop = CGRect(x: cropX, y: cropY, width: side, height: side)

FileHandle.standardError.write(Data("detected shape: \(crop)\n".utf8))

guard let cropped = sourceCG.cropping(to: crop) else {
    FileHandle.standardError.write(Data("crop failed\n".utf8))
    exit(1)
}

// MARK: - Apple squircle

/// Average colour of a small patch, used to rebuild the shape's gradient.
func averageColour(atFractionX fx: Double, y fy: Double) -> CGColor {
    let cx = Int(Double(crop.minX) + Double(crop.width) * fx)
    let cy = Int(Double(crop.minY) + Double(crop.height) * fy)
    var r = 0, g = 0, b = 0, n = 0
    for dy in -6...6 {
        for dx in -6...6 {
            let x = min(max(cx + dx, 0), width - 1)
            let y = min(max(cy + dy, 0), height - 1)
            let p = pixel(x, y)
            r += p.r; g += p.g; b += p.b; n += 1
        }
    }
    return CGColor(srgbRed: CGFloat(r / n) / 255,
                   green: CGFloat(g / n) / 255,
                   blue: CGFloat(b / n) / 255,
                   alpha: 1)
}

// The pixel buffer is bottom-up relative to the image, so sample accordingly.
let gradientTop = averageColour(atFractionX: 0.5, y: 0.94)
let gradientBottom = averageColour(atFractionX: 0.5, y: 0.06)

/// Superellipse approximating the macOS app-icon shape (continuous corners).
func squirclePath(in rect: CGRect, exponent: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width / 2)
    let b = Double(rect.height / 2)
    let cx = Double(rect.midX)
    let cy = Double(rect.midY)
    let steps = 720

    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * Double.pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = cx + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
        let y = cy + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
        let point = CGPoint(x: x, y: y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Compose one size

/// Renders one full-bleed, opaque icon tile.
///
/// Recent macOS masks and shadows app icons itself, so supplying a pre-shaped
/// squircle on a transparent canvas makes the system inset the whole thing into
/// a grey plate. The artwork therefore has to reach every edge: the shape's own
/// gradient is rebuilt across the full canvas so the corners are filled, and the
/// original artwork is composited on top clipped to its own outline — the seam
/// is invisible because the colours either side of it match.
func renderIcon(points: Int) -> CGImage? {
    let canvas = CGFloat(points)
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    guard let context = CGContext(data: nil,
                                  width: points, height: points,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.interpolationQuality = .high

    // Background: the shape's gradient, extended to the corners.
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [gradientTop, gradientBottom] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: canvas),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }

    // Foreground: the original artwork, clipped to its own squircle.
    context.saveGState()
    context.addPath(squirclePath(in: full))
    context.clip()
    context.draw(cropped, in: full)
    context.restoreGState()

    return context.makeImage()
}

// MARK: - Write the iconset

let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Marker-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, points: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = renderIcon(points: variant.points) else { continue }
    let url = iconsetURL.appendingPathComponent("\(variant.name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

// A 1024 preview, handy for eyeballing the result.
if let preview = renderIcon(points: 1024) {
    let url = URL(fileURLWithPath: outputPath).deletingPathExtension()
        .appendingPathExtension("preview.png")
    if let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, preview, nil)
        CGImageDestinationFinalize(destination)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetURL)

exit(process.terminationStatus)
