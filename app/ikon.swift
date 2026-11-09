import Cocoa
// Hece simgesi: yeşil yuvarlak kare, beyaz mikrofon (kullanım: swiftc ikon.swift -o ikon && ./ikon <klasör>)
let cikis = CommandLine.arguments[1]
let set = cikis + "/Hece.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (ad, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let kenar = s * 0.1
    let kutu = NSRect(x: kenar, y: kenar, width: s - 2*kenar, height: s - 2*kenar)
    let yol = NSBezierPath(roundedRect: kutu, xRadius: kutu.width * 0.225, yRadius: kutu.width * 0.225)
    NSGradient(starting: NSColor(red: 0.30, green: 0.86, blue: 0.45, alpha: 1), ending: NSColor(red: 0.09, green: 0.58, blue: 0.27, alpha: 1))!.draw(in: yol, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
    if let mik = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let beyaz = NSImage(size: mik.size, flipped: false) { r in
            mik.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
        let w = beyaz.size.width, h = beyaz.size.height
        beyaz.draw(in: NSRect(x: (s - w)/2, y: (s - h)/2 - s*0.01, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(ad).png"))
}
