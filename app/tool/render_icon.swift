// 生成应用图标：macOS AppIcon.appiconset 各尺寸 PNG + Windows app_icon.ico。
// 用法（在 app/ 目录）：swift tool/render_icon.swift
// 图标按 macOS 图标栅格内缩（1024 画布里主体 824），外圈必须保持透明，否则程序坞里会比邻居大一圈。
import AppKit

func render(size: Int) -> Data {
  let canvas = CGFloat(size)
  let image = NSImage(size: NSSize(width: canvas, height: canvas))
  image.lockFocus()
  let context = NSGraphicsContext.current!.cgContext
  context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

  let scale = canvas / 1024
  let inset = 100 * scale
  let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
  let radius = 185 * scale

  // 底板：深色竖向渐变 + 投影
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: NSColor(white: 0, alpha: 0.35).cgColor)
  let plate = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
  context.addPath(plate)
  context.setFillColor(NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor)
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(plate)
  context.clip()
  let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1).cgColor,
    NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor,
  ] as CFArray, locations: [0, 1])!
  context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

  // 顶部标签条：呼应标签栏里激活标签页的高亮线
  let bar = CGRect(x: body.minX, y: body.maxY - 150 * scale, width: body.width, height: 150 * scale)
  context.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
  context.fill(bar)
  let tab = CGRect(x: body.minX + 70 * scale, y: bar.minY, width: 250 * scale, height: bar.height)
  context.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
  context.fill(tab)
  context.setFillColor(NSColor(red: 0.36, green: 0.66, blue: 0.96, alpha: 1).cgColor)
  context.fill(CGRect(x: tab.minX, y: tab.maxY - 14 * scale, width: tab.width, height: 14 * scale))
  context.restoreGState()

  // 提示符 “>_”
  let accent = NSColor(red: 0.69, green: 0.91, blue: 0.41, alpha: 1)
  context.setStrokeColor(accent.cgColor)
  context.setLineWidth(58 * scale)
  context.setLineCap(.round)
  context.setLineJoin(.round)
  let chevronLeft = body.minX + 190 * scale
  let chevronMid = body.minY + 330 * scale
  context.move(to: CGPoint(x: chevronLeft, y: chevronMid + 150 * scale))
  context.addLine(to: CGPoint(x: chevronLeft + 150 * scale, y: chevronMid))
  context.addLine(to: CGPoint(x: chevronLeft, y: chevronMid - 150 * scale))
  context.strokePath()
  context.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
  let cursor = CGRect(x: chevronLeft + 250 * scale, y: chevronMid - 180 * scale, width: 230 * scale, height: 56 * scale)
  context.addPath(CGPath(roundedRect: cursor, cornerWidth: 28 * scale, cornerHeight: 28 * scale, transform: nil))
  context.fillPath()

  image.unlockFocus()
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let macDir = "macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
  try! render(size: size).write(to: URL(fileURLWithPath: "\(macDir)/app_icon_\(size).png"))
}

// ICO：目录项 + 内嵌 PNG（Vista 起支持）
let icoSizes = [16, 24, 32, 48, 64, 128, 256]
let images = icoSizes.map { render(size: $0) }
var ico = Data([0, 0, 1, 0, UInt8(icoSizes.count), 0])
var offset = 6 + 16 * icoSizes.count
for (index, size) in icoSizes.enumerated() {
  let data = images[index]
  let side = UInt8(size == 256 ? 0 : size)
  ico.append(contentsOf: [side, side, 0, 0, 1, 0, 32, 0])
  withUnsafeBytes(of: UInt32(data.count).littleEndian) { ico.append(contentsOf: $0) }
  withUnsafeBytes(of: UInt32(offset).littleEndian) { ico.append(contentsOf: $0) }
  offset += data.count
}
for data in images { ico.append(data) }
try! ico.write(to: URL(fileURLWithPath: "windows/runner/resources/app_icon.ico"))
print("icons written")
