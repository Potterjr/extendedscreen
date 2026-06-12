import AppKit

// Generates the extendedscreen app icon: a dark navy plate with an outlined
// "Mac display" and a glowing cyan tablet extending from it bottom-right.
// Usage: swift gen_icon.swift /path/to/repo

let repo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

let navyTop = rgba(0.105, 0.215, 0.330)
let navyBottom = rgba(0.035, 0.085, 0.150)
let cyanTop = rgba(0.00, 0.784, 1.00)   // #00C8FF — app accent
let cyanBottom = rgba(0.00, 0.46, 0.95)
let white = rgba(1, 1, 1, 0.92)

func drawArtwork(in ctx: CGContext, canvas: CGFloat, macStyle: Bool) {
    let plate: CGRect
    var corner: CGFloat = 0
    if macStyle {
        // Big Sur-style margin: content squircle ~82% of canvas.
        let inset = canvas * 0.094
        plate = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
        corner = plate.width * 0.225
    } else {
        plate = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    }
    // Screens are laid out in a content rect: full plate on macOS, but inset on
    // Android so circular launcher masks don't clip the artwork.
    let content = macStyle ? plate : plate.insetBy(dx: plate.width * 0.115, dy: plate.width * 0.115)
    let u = content.width

    ctx.saveGState()
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(platePath)
    ctx.clip()

    // Background gradient (top-lit navy).
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [navyTop, navyBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])

    // Mac display — white outlined rounded rect, upper-left.
    let monW = u * 0.560, monH = u * 0.400
    let monRect = CGRect(x: content.minX + u * 0.130,
                         y: content.maxY - u * 0.175 - monH,
                         width: monW, height: monH)
    let stroke = u * 0.048
    let monPath = CGPath(roundedRect: monRect.insetBy(dx: stroke / 2, dy: stroke / 2),
                         cornerWidth: u * 0.050, cornerHeight: u * 0.050, transform: nil)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(stroke)
    ctx.addPath(monPath)
    ctx.strokePath()

    // Tablet — solid cyan gradient rounded rect with glow, overlapping
    // bottom-right: the "extended" screen, lit up.
    let tabW = u * 0.440, tabH = u * 0.310
    let tabRect = CGRect(x: content.maxX - u * 0.110 - tabW,
                         y: content.minY + u * 0.135,
                         width: tabW, height: tabH)
    let tabPath = CGPath(roundedRect: tabRect, cornerWidth: u * 0.055,
                         cornerHeight: u * 0.055, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: u * 0.085, color: rgba(0.0, 0.784, 1.0, 0.55))
    ctx.addPath(tabPath)
    ctx.setFillColor(cyanTop)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tabPath)
    ctx.clip()
    let tabGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [cyanTop, cyanBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(tabGrad,
                           start: CGPoint(x: tabRect.midX, y: tabRect.maxY),
                           end: CGPoint(x: tabRect.midX, y: tabRect.minY),
                           options: [])
    ctx.restoreGState()

    ctx.restoreGState()
}

func render(_ size: Int, macStyle: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawArtwork(in: ctx, canvas: CGFloat(size), macStyle: macStyle)
    return ctx.makeImage()!
}

func savePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: img.width, height: img.height)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// macOS icon set
let macDir = "\(repo)/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for s in [16, 32, 64, 128, 256, 512, 1024] {
    savePNG(render(s, macStyle: true), "\(macDir)/app_icon_\(s).png")
}

// Android launcher mipmaps (full-bleed; the launcher applies its own mask)
let densities = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
for (d, s) in densities {
    savePNG(render(s, macStyle: false), "\(repo)/android/app/src/main/res/mipmap-\(d)/ic_launcher.png")
}
