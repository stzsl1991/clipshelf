import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext; context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let bg = NSBezierPath(roundedRect: NSRect(x: 56,y:56,width:912,height:912), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.45, blue: 0.49, alpha: 1), ending: NSColor(srgbRed: 0.025, green: 0.19, blue: 0.28, alpha: 1))!.draw(in: bg, angle: 80)
    NSColor.white.withAlphaComponent(0.24).setFill()
    NSBezierPath(roundedRect: NSRect(x: 225,y:260,width:470,height:540), xRadius: 60, yRadius: 60).fill()
    let shadow = NSShadow(); shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.shadowBlurRadius = 25; shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(srgbRed: 0.98, green: 0.98, blue: 0.94, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 325,y:200,width:470,height:540), xRadius: 60, yRadius: 60).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.09,green: 0.38,blue: 0.43,alpha: 1).setFill()
    for (y,width) in [(590,270),(495,270),(400,180)] { NSBezierPath(roundedRect: NSRect(x: 415,y:y,width:width,height:28),xRadius:14,yRadius:14).fill() }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(size).png"))
}
