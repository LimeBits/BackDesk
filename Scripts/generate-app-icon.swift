import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xff) / 255.0
    let green = CGFloat((hex >> 8) & 0xff) / 255.0
    let blue = CGFloat(hex & 0xff) / 255.0
    return NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawShadow(path: NSBezierPath, shadowColor: NSColor, blur: CGFloat, offset: CGSize) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = shadowColor
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    color(0x000000, alpha: 0.01).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSColor.clear.setFill()
CGRect(x: 0, y: 0, width: size, height: size).fill()

let iconRect = CGRect(x: 42, y: 42, width: 940, height: 940)
let iconPath = roundedRect(iconRect, radius: 210)

drawShadow(path: iconPath, shadowColor: color(0x000000, alpha: 0.32), blur: 38, offset: CGSize(width: 0, height: -20))

NSGraphicsContext.saveGraphicsState()
iconPath.addClip()

let backgroundGradient = NSGradient(colors: [
    color(0x2E748B),
    color(0x245A71),
    color(0x173B52)
])!
backgroundGradient.draw(in: iconRect, angle: 90)

NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, alpha: 0.15).setStroke()
iconPath.lineWidth = 2
iconPath.stroke()

let monitorStroke = color(0xF8FBFA)
let monitorInnerStroke = color(0xD5EEF2, alpha: 0.72)
let monitorShadow = color(0x062638, alpha: 0.38)

func stroke(_ path: NSBezierPath, with color: NSColor, width: CGFloat, lineCap: NSBezierPath.LineCapStyle = .round, lineJoin: NSBezierPath.LineJoinStyle = .round) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = lineCap
    path.lineJoinStyle = lineJoin
    path.stroke()
}

let screenRect = CGRect(x: 258, y: 436, width: 508, height: 310)
let screenPath = roundedRect(screenRect, radius: 20)

let shadowPath = screenPath.copy() as! NSBezierPath
var shadowTransform = AffineTransform(translationByX: 0, byY: -7)
shadowPath.transform(using: shadowTransform)
stroke(shadowPath, with: monitorShadow, width: 36)
stroke(screenPath, with: monitorStroke, width: 26)
stroke(screenPath, with: monitorInnerStroke, width: 8)

let screenBottom = NSBezierPath()
screenBottom.move(to: CGPoint(x: screenRect.minX + 24, y: screenRect.minY + 1))
screenBottom.line(to: CGPoint(x: screenRect.maxX - 24, y: screenRect.minY + 1))
stroke(screenBottom, with: monitorShadow, width: 42)
stroke(screenBottom, with: monitorStroke, width: 34)
stroke(screenBottom, with: monitorInnerStroke, width: 10)

let stand = NSBezierPath()
stand.move(to: CGPoint(x: 512, y: 410))
stand.line(to: CGPoint(x: 512, y: 356))
stroke(stand, with: monitorShadow, width: 34)
stroke(stand, with: monitorStroke, width: 25)
stroke(stand, with: monitorInnerStroke, width: 7)

let base = NSBezierPath()
base.move(to: CGPoint(x: 430, y: 356))
base.line(to: CGPoint(x: 594, y: 356))
stroke(base, with: monitorShadow, width: 34)
stroke(base, with: monitorStroke, width: 25)
stroke(base, with: monitorInnerStroke, width: 7)

NSGraphicsContext.restoreGraphicsState()

guard
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render AppIcon.png")
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print("Generated \(outputPath)")
