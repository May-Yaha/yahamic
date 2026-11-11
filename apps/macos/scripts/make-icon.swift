// 生成 App 图标「四环」:浅底上三道进度环(青/蓝/紫粉,呼应设备首页的状态环),中间一支话筒。
// 话筒是自绘路径:SF Symbols 许可不允许用在 App 图标里。
// 用法:swift make-icon.swift <输出 1024px PNG 路径> [ios]
//   mac(默认):可见方块占画布 80%,圆角与阴影自带;ios:满幅不透明方图,圆角由系统裁。
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "AppIcon-1024.png"
let ios = args.count > 2 && args[2] == "ios"
let size: CGFloat = 1024

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(_ r: NSRect) {
    NSGradient(colors: [c(0xFFFFFF), c(0xEDF0F7)])!.draw(in: r, angle: -90)
    let w = r.width, line = w * 0.075, center = NSPoint(x: r.midX, y: r.midY)
    for (i, (color, sweep)) in [(c(0x1AD1C7), CGFloat(290)), (c(0x4D6BF5), 230), (c(0xDB4DB8), 165)].enumerated() {
        let radius = w * 0.355 - CGFloat(i) * line * 1.42
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = line; color.withAlphaComponent(0.15).setStroke(); track.stroke()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        ring.lineWidth = line; ring.lineCapStyle = .round; color.setStroke(); ring.stroke()
    }
    // 话筒:胶囊 + U 形支架 + 立杆 + 底座,整体收在最内环以内。
    let ink = c(0x1B2030), stroke = w * 0.02, bw = w * 0.06, bh = w * 0.095
    let m = NSRect(x: r.midX - w * 0.065, y: r.midY - w * 0.078, width: w * 0.13, height: w * 0.16)
    ink.setFill(); ink.setStroke()
    let body = NSRect(x: m.midX - bw / 2, y: m.maxY - bh, width: bw, height: bh)
    NSBezierPath(roundedRect: body, xRadius: bw / 2, yRadius: bw / 2).fill()
    let holder = NSBezierPath(), hr = bw / 2 + stroke * 1.6, hy = body.minY + bw / 2 + bh * 0.12
    holder.appendArc(withCenter: NSPoint(x: m.midX, y: hy), radius: hr, startAngle: 180, endAngle: 360)
    let base = m.minY + stroke / 2
    holder.move(to: NSPoint(x: m.midX, y: hy - hr)); holder.line(to: NSPoint(x: m.midX, y: base))
    holder.move(to: NSPoint(x: m.midX - bw * 0.55, y: base)); holder.line(to: NSPoint(x: m.midX + bw * 0.55, y: base))
    holder.lineWidth = stroke; holder.lineCapStyle = .round; holder.stroke()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
if ios {
    draw(canvas)
} else {
    let rect = canvas.insetBy(dx: size * 0.10, dy: size * 0.10)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowColor = .black.withAlphaComponent(0.3); shadow.set()
    NSColor.white.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip(); draw(rect)
}
NSGraphicsContext.restoreGraphicsState()
// App Store 拒收带 alpha 通道的 iOS 图标:重绘进无 alpha 的位图。
var final = rep
if ios, let image = rep.cgImage,
   let flat = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    flat.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    if let opaque = flat.makeImage() { final = NSBitmapImageRep(cgImage: opaque) }
}
guard let png = final.representation(using: .png, properties: [:]) else { fputs("render failed\n", stderr); exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("icon written: \(out)")
