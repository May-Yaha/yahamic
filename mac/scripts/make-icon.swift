// 生成 App 图标:圆角方块,青→蓝→紫粉渐变(与设备频谱同色系),白色麦克风。
// 用法:swift make-icon.swift <输出 1024px PNG 路径>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS 图标网格:可见方块约占画布 80%,四周留透明边。
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.10, green: 0.82, blue: 0.78, alpha: 1),   // 青
        NSColor(red: 0.30, green: 0.42, blue: 0.96, alpha: 1),   // 蓝
        NSColor(red: 0.86, green: 0.30, blue: 0.72, alpha: 1),   // 紫粉
    ])!
    gradient.draw(in: shape, angle: -55)

    // 底部一组"频谱条"作为点缀,呼应设备屏幕。
    let heights: [CGFloat] = [0.18, 0.30, 0.44, 0.34, 0.22]
    let barW = rect.width * 0.045, gap = rect.width * 0.03
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    for h in heights {
        let bar = NSRect(x: x, y: rect.minY + rect.height * 0.16, width: barW, height: rect.height * h)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }

    // 麦克风(SF Symbol)居中偏上,白色。
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let white = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = white.size
        let origin = NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 + rect.height * 0.08)
        white.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("render failed\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
print("icon written: \(out)")
