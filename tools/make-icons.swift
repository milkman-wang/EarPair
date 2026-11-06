// 生成 EarPair 的图标（自己画的耳朵，和 Mac 菜单栏的耳朵图标呼应；SF Symbols 只许用在 Apple 平台，所以不用它）。
//   Windows：EarPair.ico（渐变耳朵，不加底板）、托盘图标 Tray/{idle,on,warn}-{light,dark}.ico
//   Mac：AppIcon.icns（渐变圆角方块 + 白色耳朵）
// 用法（仓库根目录）：xcrun swift tools/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - 耳朵（24×24 网格，只用 M / C / Z 绝对坐标）

let outerOutline = "M7.5 9.5 C7.5 5.9 10.2 3.5 13.25 3.5 C16.6 3.5 19 6.1 19 9.5 C19 12.4 17.4 13.8 16.1 15.1 C15.2 16 14.8 16.9 14.6 18.1 C14.3 20 12.9 21 11.25 21 C9.8 21 8.7 20.1 8.3 18.9"
let innerOutline = "M10.5 9.75 C10.5 8.1 11.75 6.75 13.25 6.75 C14.8 6.75 16 8 16 9.5 C16 11 14.9 11.7 14 12.5 C13.3 13.1 12.75 13.5 12.75 14.5"
let filledShape = "M7.5 9.5 C7.5 5.9 10.2 3.5 13.25 3.5 C16.6 3.5 19 6.1 19 9.5 C19 12.4 17.4 13.8 16.1 15.1 C15.2 16 14.8 16.9 14.6 18.1 C14.3 20 12.9 21 11.25 21 C9.8 21 8.7 20.1 8.3 18.9 C7.9 16.4 7.5 12.6 7.5 9.5 Z"
let filledInner = "M10.6 10.2 C10.6 8.2 11.9 6.8 13.4 6.8 C15 6.8 16.1 8.1 16.1 9.6 C16.1 10.9 15.3 11.7 14.5 12.3"

/// 把只含 M / C / Z 的 SVG 路径转成 CGPath（y 轴朝下，和 SVG 一致）
func path(_ d: String) -> CGPath {
    var spaced = d.replacingOccurrences(of: ",", with: " ")
    for letter in ["M", "C", "Z"] { spaced = spaced.replacingOccurrences(of: letter, with: " \(letter) ") }
    let tokens = spaced.split(separator: " ").map(String.init)
    let result = CGMutablePath()
    var i = 0
    var command = ""
    func number() -> CGFloat {
        defer { i += 1 }
        return CGFloat(Double(tokens[i])!)
    }
    while i < tokens.count {
        if let first = tokens[i].first, first.isLetter {
            command = String(first)
            i += 1
            if command == "Z" { result.closeSubpath(); continue }
        }
        switch command {
        case "M": result.move(to: CGPoint(x: number(), y: number()))
        case "C":
            let c1 = CGPoint(x: number(), y: number())
            let c2 = CGPoint(x: number(), y: number())
            result.addCurve(to: CGPoint(x: number(), y: number()), control1: c1, control2: c2)
        default: i += 1
        }
    }
    return result
}

/// 新建一张透明位图，坐标系换成“24×24 网格、y 朝下”，在里面画
func canvas(size: Int, inset: CGFloat = 0, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setShouldAntialias(true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// 在 [0,size] 的画布里，把 24 网格的耳朵放进 rect（y 朝下）
func withEarSpace(_ cg: CGContext, rect: CGRect, _ body: () -> Void) {
    cg.saveGState()
    cg.translateBy(x: rect.minX, y: rect.maxY)
    cg.scaleBy(x: rect.width / 24, y: -rect.height / 24)
    body()
    cg.restoreGState()
}

/// 让耳朵的外框（含描边）等比放大、居中填满 area，返回 24 网格对应的矩形
func earRect(in area: CGRect, stroke: CGFloat) -> CGRect {
    let box = path(filledShape).boundingBoxOfPath.insetBy(dx: -stroke / 2, dy: -stroke / 2)
    let k = min(area.width / box.width, area.height / box.height) // 每个网格单位多少像素
    // 网格 (gx, gy) → 画布 x = minX + gx·k；y（朝上）= maxY − gy·k
    let minX = area.midX - box.midX * k
    let maxY = area.midY + box.midY * k
    return CGRect(x: minX, y: maxY - 24 * k, width: 24 * k, height: 24 * k)
}

let gradientTop = NSColor(srgbRed: 0x3D / 255.0, green: 0xA0 / 255.0, blue: 1, alpha: 1).cgColor
let gradientBottom = NSColor(srgbRed: 0x6E / 255.0, green: 0x4B / 255.0, blue: 0xF2 / 255.0, alpha: 1).cgColor

/// Windows App 图标：渐变实心耳朵，内耳一段白色弧线
func appEar(size: Int) -> Data {
    canvas(size: size) { cg in
        let s = CGFloat(size)
        let rect = earRect(in: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.03, dy: s * 0.03), stroke: 1.5)
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
        // 先填充外形，再用同样的渐变描一圈 1.5 的边，让轮廓圆润
        withEarSpace(cg, rect: rect) {
            cg.saveGState()
            cg.addPath(path(filledShape))
            cg.clip()
            cg.drawLinearGradient(gradient, start: CGPoint(x: 7, y: 3), end: CGPoint(x: 19.5, y: 21.5), options: [])
            cg.restoreGState()
            cg.addPath(path(filledShape))
            cg.setLineWidth(1.5)
            cg.setLineJoin(.round)
            cg.replacePathWithStrokedPath()
            cg.clip()
            cg.drawLinearGradient(gradient, start: CGPoint(x: 7, y: 3), end: CGPoint(x: 19.5, y: 21.5), options: [])
        }
        withEarSpace(cg, rect: rect) {
            cg.addPath(path(filledInner))
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(1.6)
            cg.setLineCap(.round)
            cg.strokePath()
        }
    }
}

enum TrayGlyph: String, CaseIterable { case idle, on, warn }

/// 托盘图标：单色。浅色任务栏用黑色，深色任务栏用白色
func trayEar(_ glyph: TrayGlyph, size: Int, dark: Bool) -> Data {
    canvas(size: size) { cg in
        let s = CGFloat(size)
        let ink = dark ? NSColor.white.cgColor : NSColor.black.cgColor
        let line = max(1.5, 24 / s * 1.0) // 小尺寸时线宽至少 1 像素
        let rect = earRect(in: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.02, dy: s * 0.02), stroke: line)
        withEarSpace(cg, rect: rect) {
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            switch glyph {
            case .idle, .warn:
                cg.setStrokeColor(ink)
                cg.setLineWidth(line)
                cg.addPath(path(outerOutline))
                cg.addPath(path(innerOutline))
                cg.strokePath()
            case .on:
                cg.setFillColor(ink)
                cg.setStrokeColor(ink)
                cg.setLineWidth(line)
                cg.addPath(path(filledShape))
                cg.drawPath(using: .fillStroke)
                cg.setBlendMode(.clear)
                cg.addPath(path(filledInner))
                cg.setLineWidth(line)
                cg.strokePath()
            }
        }
        if glyph == .warn {
            // 右下角黄色徽标，深色感叹号；周围挖空一圈和耳朵隔开
            let r = s * 0.25
            let center = CGPoint(x: s - r - s * 0.02, y: r + s * 0.02)
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: CGRect(x: center.x - r - s * 0.07, y: center.y - r - s * 0.07,
                                      width: 2 * (r + s * 0.07), height: 2 * (r + s * 0.07)))
            cg.setBlendMode(.normal)
            let yellow = dark ? NSColor(srgbRed: 0xFC / 255.0, green: 0xE1 / 255.0, blue: 0, alpha: 1)
                              : NSColor(srgbRed: 0xF7 / 255.0, green: 0xB5 / 255.0, blue: 0, alpha: 1)
            cg.setFillColor(yellow.cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            cg.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
            let w = max(1, r * 0.28)
            cg.fill(CGRect(x: center.x - w / 2, y: center.y - r * 0.05, width: w, height: r * 0.62))
            cg.fill(CGRect(x: center.x - w / 2, y: center.y - r * 0.55, width: w, height: w))
        }
    }
}

/// Mac App 图标：渐变圆角方块 + 白色耳朵（macOS 图标按规范四周留白）
func macIcon(size: Int) -> Data {
    canvas(size: size) { cg in
        let s = CGFloat(size)
        let inset = s * 0.098
        let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = plate.width * 0.225
        if size >= 64 {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.025,
                         color: NSColor.black.withAlphaComponent(0.28).cgColor)
            cg.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.setFillColor(gradientBottom)
            cg.fillPath()
            cg.restoreGState()
        }
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                              end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
        cg.restoreGState()
        let ear = CGRect(x: plate.minX + plate.width * 0.02, y: plate.minY + plate.height * 0.12,
                         width: plate.width * 0.76, height: plate.height * 0.76)
        withEarSpace(cg, rect: ear) {
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(1.9)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path(outerOutline))
            cg.addPath(path(innerOutline))
            cg.strokePath()
        }
    }
}

/// 把多张 PNG 打包成 .ico（Vista 起支持 PNG 格式的图标项）
func writeICO(_ images: [(Int, Data)], to url: URL) throws {
    var data = Data()
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
    u16(0); u16(1); u16(images.count)
    var offset = 6 + 16 * images.count
    for (size, png) in images {
        data.append(UInt8(size >= 256 ? 0 : size))
        data.append(UInt8(size >= 256 ? 0 : size))
        data.append(0); data.append(0)
        u16(1); u16(32)
        u32(png.count); u32(offset)
        offset += png.count
    }
    for (_, png) in images { data.append(png) }
    try data.write(to: url)
}

let assets = root.appendingPathComponent("windows/EarPair.App/Assets")
let tray = assets.appendingPathComponent("Tray")
try FileManager.default.createDirectory(at: tray, withIntermediateDirectories: true)
try writeICO([16, 20, 24, 32, 40, 48, 64, 256].map { ($0, appEar(size: $0)) },
             to: assets.appendingPathComponent("EarPair.ico"))
try appEar(size: 256).write(to: assets.appendingPathComponent("EarPair.png"))
for glyph in TrayGlyph.allCases {
    for dark in [false, true] {
        try writeICO([16, 20, 24, 32, 40, 48].map { ($0, trayEar(glyph, size: $0, dark: dark)) },
                     to: tray.appendingPathComponent("\(glyph.rawValue)-\(dark ? "dark" : "light").ico"))
    }
}
// 预览：托盘图标放大
try trayEar(.on, size: 96, dark: false).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tray-on.png"))

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try macIcon(size: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
let icns = root.appendingPathComponent("macos/Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
try macIcon(size: 512).write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mac-icon.png"))
print("完成：\(assets.path)、\(icns.path)；预览在 \(NSTemporaryDirectory())")
