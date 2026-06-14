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
    color(0x8198A6),
    color(0x647D8C),
    color(0x506B7A)
])!
backgroundGradient.draw(in: iconRect, angle: 90)

let topGlow = NSGradient(colors: [
    color(0xFFFFFF, alpha: 0.22),
    color(0xFFFFFF, alpha: 0.02),
    color(0xFFFFFF, alpha: 0.0)
])!
topGlow.draw(in: CGRect(x: 42, y: 522, width: 940, height: 460), angle: 90)

let bottomShade = NSGradient(colors: [
    color(0x000000, alpha: 0.0),
    color(0x000000, alpha: 0.14)
])!
bottomShade.draw(in: CGRect(x: 42, y: 42, width: 940, height: 430), angle: 90)

NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, alpha: 0.18).setStroke()
iconPath.lineWidth = 2
iconPath.stroke()

let monitorStroke = color(0xF6F8F7)
let monitorShadow = color(0x1E3440, alpha: 0.28)
let strokeWidth: CGFloat = 25

func stroke(_ path: NSBezierPath, with color: NSColor, width: CGFloat, lineCap: NSBezierPath.LineCapStyle = .round, lineJoin: NSBezierPath.LineJoinStyle = .round) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = lineCap
    path.lineJoinStyle = lineJoin
    path.stroke()
}

let screenRect = CGRect(x: 268, y: 432, width: 488, height: 296)
let screenPath = roundedRect(screenRect, radius: 18)

let shadowPath = screenPath.copy() as! NSBezierPath
var shadowTransform = AffineTransform(translationByX: 0, byY: -7)
shadowPath.transform(using: shadowTransform)
stroke(shadowPath, with: monitorShadow, width: strokeWidth + 5)
stroke(screenPath, with: monitorStroke, width: 20)

let stand = NSBezierPath()
stand.move(to: CGPoint(x: 512, y: 412))
stand.line(to: CGPoint(x: 512, y: 346))
stroke(stand, with: monitorShadow, width: 24)
stroke(stand, with: monitorStroke, width: 18)

let base = NSBezierPath()
base.move(to: CGPoint(x: 446, y: 344))
base.line(to: CGPoint(x: 578, y: 344))
stroke(base, with: monitorShadow, width: 24)
stroke(base, with: monitorStroke, width: 18)

NSGraphicsContext.restoreGraphicsState()

guard
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render AppIcon.png")
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print("Generated \(outputPath)")
