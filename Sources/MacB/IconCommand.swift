import AppKit
import MacBKit

/// `MacB --make-icon <폴더.iconset>`: 앱 아이콘을 그려 iconset으로 저장한다(빌드 스크립트가 사용).
/// 원형 메뉴와 같은 배치 계산을 써서 아이콘이 실제 메뉴 모양과 닮게 한다.
@MainActor
enum IconCommand {
    static func run(iconsetPath: String) -> Int32 {
        let directory = URL(fileURLWithPath: (iconsetPath as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    guard
                        let rep = draw(pixels: points * scale),
                        let data = rep.representation(using: .png, properties: [:])
                    else { return 1 }
                    let suffix = scale == 2 ? "@2x" : ""
                    try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
                }
            }
            return 0
        } catch {
            print("icon failed: \(error)")
            return 1
        }
    }

    private static func draw(pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = graphics.cgContext

        // 1024 단위 캔버스에 그리고 실제 픽셀 크기로 줄인다.
        let unit = CGFloat(pixels) / 1024
        context.scaleBy(x: unit, y: unit)

        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(srgbRed: 0.10, green: 0.11, blue: 0.17, alpha: 1).cgColor)
        context.addPath(platePath)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(platePath)
        context.clip()
        let colors = [
            NSColor(srgbRed: 0.21, green: 0.23, blue: 0.36, alpha: 1).cgColor,
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).cgColor,
        ]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        context.restoreGState()

        let center = CGPoint(x: 512, y: 512)
        let layout = RadialLayout(itemCount: 8, innerRadius: 132, outerRadius: 322)
        let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)
        for index in 0..<layout.itemCount {
            let core = layout.sectorPath(index: index, center: center, gap: 18, inset: 20)
            let rim = core.copy(strokingWithWidth: 40, lineCap: .round, lineJoin: .round, miterLimit: 10)
            context.addPath(core.union(rim))
            context.setFillColor((index == 0 ? accent : NSColor.white.withAlphaComponent(0.9)).cgColor)
            context.fillPath()
        }

        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 84, y: center.y - 84, width: 168, height: 168))
        return rep
    }
}
