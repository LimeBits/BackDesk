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

color(0x3E444D).setFill()
iconPath.fill()

NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, alpha: 0.11).setStroke()
iconPath.lineWidth = 2
iconPath.stroke()

let displayWhiteTop = color(0xFFFFFF)
let displayWhiteBottom = color(0xE5E7E6)
let displayEdge = color(0xC8CECF)
let displayShadow = color(0x111A20, alpha: 0.36)
let screenFill = color(0x2C3841)
let monitorYOffset: CGFloat = -36

func stroke(_ path: NSBezierPath, with color: NSColor, width: CGFloat, lineCap: NSBezierPath.LineCapStyle = .round, lineJoin: NSBezierPath.LineJoinStyle = .round) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = lineCap
    path.lineJoinStyle = lineJoin
    path.stroke()
}

let displayRect = CGRect(x: 244, y: 438 + monitorYOffset, width: 536, height: 306)
let displayPath = roundedRect(displayRect, radius: 31)

drawShadow(path: displayPath, shadowColor: displayShadow, blur: 16, offset: CGSize(width: 0, height: -8))

let displayGradient = NSGradient(colors: [
    displayWhiteTop,
    color(0xF6F7F7),
    displayWhiteBottom
])!
displayGradient.draw(in: displayPath, angle: 90)

displayEdge.setStroke()
displayPath.lineWidth = 5
displayPath.stroke()

let screenRect = CGRect(x: 284, y: 500 + monitorYOffset, width: 456, height: 202)
let screenPath = roundedRect(screenRect, radius: 9)
screenFill.setFill()
screenPath.fill()
color(0x111820, alpha: 0.18).setStroke()
screenPath.lineWidth = 4
screenPath.stroke()

let lowerChin = NSBezierPath(roundedRect: CGRect(x: 282, y: 456 + monitorYOffset, width: 460, height: 48), xRadius: 13, yRadius: 13)
color(0xFFFFFF, alpha: 0.34).setFill()
lowerChin.fill()

let stand = NSBezierPath()
stand.move(to: CGPoint(x: 484, y: 438 + monitorYOffset))
stand.line(to: CGPoint(x: 540, y: 438 + monitorYOffset))
stand.line(to: CGPoint(x: 552, y: 372 + monitorYOffset))
stand.line(to: CGPoint(x: 472, y: 372 + monitorYOffset))
stand.close()
drawShadow(path: stand, shadowColor: displayShadow, blur: 8, offset: CGSize(width: 0, height: -4))
let standGradient = NSGradient(colors: [
    color(0xFAFBFA),
    color(0xD9DDDC)
])!
standGradient.draw(in: stand, angle: 90)
displayEdge.setStroke()
stand.lineWidth = 4
stand.stroke()

let basePath = roundedRect(CGRect(x: 394, y: 352 + monitorYOffset, width: 236, height: 31), radius: 15)
drawShadow(path: basePath, shadowColor: displayShadow, blur: 8, offset: CGSize(width: 0, height: -4))
displayGradient.draw(in: basePath, angle: 90)
displayEdge.setStroke()
basePath.lineWidth = 4
basePath.stroke()

NSGraphicsContext.restoreGraphicsState()

guard
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render AppIcon.png")
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print("Generated \(outputPath)")
