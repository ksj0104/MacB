import AppKit

/// 원형 메뉴의 조각 하나.
struct RadialItem {
    enum Icon {
        /// SF Symbols 이름.
        case symbol(String)
        /// 앱 아이콘 같은 실제 이미지.
        case image(NSImage)
        /// 이모지나 짧은 글자.
        case text(String)
    }

    var id: String
    /// 조각 안에 들어가는 짧은 이름.
    var title: String
    /// 가운데에 보여 주는 설명.
    var subtitle: String
    var icon: Icon
    var perform: @MainActor () -> Void
}

/// 아이콘을 레이어에 바로 넣을 수 있는 비트맵으로 그린다.
///
/// 원형 메뉴는 화면 밖에서도 똑같이 그려져야(스냅샷 검증) 해서 NSImageView 대신 레이어 contents를 쓴다.
@MainActor
enum IconRenderer {
    struct Rendered {
        let image: CGImage
        /// pt 단위 크기.
        let size: CGSize
    }

    static func render(_ icon: RadialItem.Icon, pointSize: CGFloat, color: NSColor, scale: CGFloat) -> Rendered? {
        switch icon {
        case .symbol(let name):
            return renderSymbol(name, pointSize: pointSize, color: color, scale: scale)
                ?? renderSymbol("questionmark.circle", pointSize: pointSize, color: color, scale: scale)
        case .image(let image):
            let side = (pointSize * 1.45).rounded()
            return draw(size: CGSize(width: side, height: side), scale: scale) { rect in
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        case .text(let text):
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: pointSize * 1.05, weight: .medium),
                .foregroundColor: color,
            ])
            let bounds = attributed.size()
            let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            guard size.width > 0, size.height > 0 else { return nil }
            return draw(size: size, scale: scale) { rect in
                attributed.draw(in: rect)
            }
        }
    }

    private static func renderSymbol(_ name: String, pointSize: CGFloat, color: NSColor, scale: CGFloat) -> Rendered? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = CGSize(width: ceil(symbol.size.width), height: ceil(symbol.size.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return draw(size: size, scale: scale) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            // 템플릿 이미지는 검게 그려지므로 그 모양 위에만 원하는 색을 덮는다.
            color.set()
            rect.fill(using: .sourceAtop)
        }
    }

    private static func draw(size: CGSize, scale: CGFloat, _ body: (NSRect) -> Void) -> Rendered? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        return Rendered(image: image, size: size)
    }
}
