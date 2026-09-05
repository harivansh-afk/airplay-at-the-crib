import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.43, green: 0.16, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 215, yRadius: 215).fill()
        NSColor.white.setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 204, y: 340, width: 616, height: 398), xRadius: 40, yRadius: 40)
        screen.lineWidth = 40; screen.stroke()
        NSColor(calibratedRed: 0.43, green: 0.16, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 362, y: 294, width: 300, height: 110)).fill()
        NSColor.white.setFill()
        let triangle = NSBezierPath(); triangle.move(to: NSPoint(x: 512, y: 444)); triangle.line(to: NSPoint(x: 370, y: 258)); triangle.line(to: NSPoint(x: 654, y: 258)); triangle.close(); triangle.fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)\(suffix).png"))
    }
}
