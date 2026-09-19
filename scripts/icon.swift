// Рисует иконку Offload 1024×1024: внешний диск, из которого уходит стрелка, и зелёная галочка сверки.
import AppKit

let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("нет контекста") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rgb(_ hex: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func rounded(_ rect: CGRect, _ r: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

// фон
let card = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x0b3b4e), rgb(0x0f766e)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// внешний диск
let disk = CGRect(x: 214, y: 196, width: 596, height: 236)
rounded(disk, 60, rgb(0xffffff, 0.12))
ctx.addPath(CGPath(roundedRect: disk.insetBy(dx: 14, dy: 14), cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.setStrokeColor(rgb(0xffffff, 0.92))
ctx.setLineWidth(28)
ctx.strokePath()
ctx.setFillColor(rgb(0x5eead4))
ctx.fillEllipse(in: CGRect(x: 694, y: 291, width: 46, height: 46))

// стрелка вверх: данные уходят с диска Mac
rounded(CGRect(x: 358, y: 470, width: 84, height: 240), 32, rgb(0xffffff))
let head = CGMutablePath()
head.move(to: CGPoint(x: 236, y: 680))
head.addLine(to: CGPoint(x: 564, y: 680))
head.addLine(to: CGPoint(x: 400, y: 850))
head.closeSubpath()
ctx.addPath(head)
ctx.setFillColor(rgb(0xffffff))
ctx.fillPath()

// галочка сверки
ctx.setFillColor(rgb(0x22c55e))
ctx.fillEllipse(in: CGRect(x: 588, y: 520, width: 236, height: 236))
let check = CGMutablePath()
check.move(to: CGPoint(x: 650, y: 640))
check.addLine(to: CGPoint(x: 694, y: 594))
check.addLine(to: CGPoint(x: 768, y: 684))
ctx.addPath(check)
ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(32)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
