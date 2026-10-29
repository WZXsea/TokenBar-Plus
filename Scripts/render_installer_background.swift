import AppKit

// Finder 图标位置与 build_dmg.py 对齐；背景中的文字与箭头采用矢量绘制。
let size = NSSize(width: 680, height: 440)
let image = NSImage(size: size)
image.lockFocusFlipped(true)

let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [
    NSColor(srgbRed: 0.965, green: 0.961, blue: 0.993, alpha: 1),
    NSColor(srgbRed: 0.988, green: 0.988, blue: 0.996, alpha: 1),
])!.draw(in: bounds, angle: 90)

func label(_ text: String, rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    (text as NSString).draw(in: rect, withAttributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
    ])
}

let ink = NSColor(srgbRed: 0.14, green: 0.13, blue: 0.22, alpha: 1)
let secondary = NSColor(srgbRed: 0.43, green: 0.42, blue: 0.51, alpha: 1)
let purple = NSColor(srgbRed: 0.48, green: 0.32, blue: 0.86, alpha: 1)

label("TokenBar Plus", rect: NSRect(x: 44, y: 32, width: 500, height: 40),
      font: .systemFont(ofSize: 29, weight: .bold), color: ink)
label("将 TokenBar 拖入「应用程序」完成安装", rect: NSRect(x: 45, y: 78, width: 590, height: 25),
      font: .systemFont(ofSize: 16), color: secondary)

for centerX in [180.0, 500.0] {
    let card = NSBezierPath(roundedRect: NSRect(x: centerX - 78, y: 147, width: 156, height: 156),
                            xRadius: 26, yRadius: 26)
    NSColor.white.withAlphaComponent(0.72).setFill()
    card.fill()
    NSColor(srgbRed: 0.86, green: 0.84, blue: 0.93, alpha: 0.5).setStroke()
    card.lineWidth = 1
    card.stroke()
}

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 298, y: 218))
arrow.line(to: NSPoint(x: 380, y: 218))
arrow.move(to: NSPoint(x: 366, y: 204))
arrow.line(to: NSPoint(x: 380, y: 218))
arrow.line(to: NSPoint(x: 366, y: 232))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
purple.setStroke()
arrow.stroke()
label("拖拽安装", rect: NSRect(x: 285, y: 247, width: 110, height: 24),
      font: .systemFont(ofSize: 13, weight: .medium), color: purple, centered: true)

NSColor(srgbRed: 0.87, green: 0.86, blue: 0.92, alpha: 0.7).setFill()
NSRect(x: 44, y: 332, width: 592, height: 1).fill()
label("已有版本：退出 TokenBar 后替换即可", rect: NSRect(x: 44, y: 351, width: 592, height: 24),
      font: .systemFont(ofSize: 13), color: secondary, centered: true)
label("macOS 14+  ·  Apple Silicon", rect: NSRect(x: 44, y: 389, width: 592, height: 20),
      font: .systemFont(ofSize: 11, weight: .medium), color: secondary, centered: true)

image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let data = bitmap.representation(using: .png, properties: [:])!
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: output)
print("Created \(output.path)")
