import AppKit
import MacBKit

/// 원형 메뉴의 그림. 블러 배경(NSVisualEffectView) 위에 레이어로만 그린다.
///
/// 구조(아래에서 위로): 그림자 → 블러(조각·가운데 원 모양으로 마스킹) → 조각/아이콘/글자.
/// 입력 처리는 하지 않는다 — 무엇을 강조할지는 `RadialMenuController`가 정해서 알려 준다.
@MainActor
final class RadialMenuView: NSView {
    private enum Style {
        /// 그림자가 잘리지 않도록 바깥에 두는 여백.
        static let padding: CGFloat = 44
        static let gap: CGFloat = 4
        static let corner: CGFloat = 8
        static let hubInset: CGFloat = 10
        static let iconPointSize: CGFloat = 23
        static let labelWidth: CGFloat = 84
        static let hubTextWidth: CGFloat = 92
        static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        static let hubTitleFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        static let hubSubtitleFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        static let restingIconOpacity: Float = 0.9
        static let restingLabelOpacity: Float = 0.78
    }

    private struct Wedge {
        let highlight: CAShapeLayer
        let icon: CALayer
        let label: CATextLayer
    }

    let layout: RadialLayout
    private let items: [RadialItem]
    private let pixelScale: CGFloat
    private(set) var highlightedIndex: Int?

    private let shadowHost = NSView()
    private let blurView = NSVisualEffectView()
    private let contentHost = NSView()
    /// 등장할 때 살짝 커지는 층. 조각·아이콘·글자가 모두 여기에 들어 있다.
    private let stage = CALayer()
    private var wedges: [Wedge] = []
    private let hubTitle = CATextLayer()
    private let hubSubtitle = CATextLayer()
    private let pointer = CAShapeLayer()
    private var hubHint = ""
    private var maskPath = CGMutablePath()

    static func sideLength(for layout: RadialLayout) -> CGFloat {
        (layout.outerRadius + Style.padding) * 2
    }

    private var hubRadius: CGFloat { layout.innerRadius - Style.hubInset }
    private var ringCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    init(items: [RadialItem], pixelScale: CGFloat) {
        self.items = items
        self.layout = RadialLayout(itemCount: items.count)
        self.pixelScale = pixelScale
        let side = RadialMenuView.sideLength(for: layout)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Build

    private func build() {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue

        // 직접 만든 레이어 트리를 쓰는 뷰는 layer를 먼저 넣고 wantsLayer를 켠다(레이어 호스팅).
        for host in [shadowHost, contentHost] {
            host.frame = bounds
            host.layer = CALayer()
            host.wantsLayer = true
        }

        buildShadow()

        blurView.frame = bounds
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.appearance = NSAppearance(named: .vibrantDark)

        stage.frame = bounds
        contentHost.layer?.addSublayer(stage)

        for index in items.indices {
            let path = wedgePath(index)
            maskPath.addPath(path)

            // 블러 위에 얹는 어두운 막. 밝은 화면 위에서도 흰 글자가 읽히게 한다.
            let base = shapeLayer(path: path)
            base.fillColor = NSColor.black.withAlphaComponent(0.34).cgColor
            base.strokeColor = NSColor.white.withAlphaComponent(0.11).cgColor
            base.lineWidth = 1
            stage.addSublayer(base)

            let highlight = shapeLayer(path: path)
            highlight.fillColor = accent.withAlphaComponent(0.94).cgColor
            highlight.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
            highlight.lineWidth = 1
            highlight.opacity = 0
            stage.addSublayer(highlight)

            let anchor = layout.point(of: index, radius: (layout.innerRadius + layout.outerRadius) / 2)
            let itemCenter = CGPoint(x: ringCenter.x + anchor.x, y: ringCenter.y + anchor.y)

            let icon = CALayer()
            icon.contentsScale = pixelScale
            icon.opacity = Style.restingIconOpacity
            if let rendered = IconRenderer.render(
                items[index].icon, pointSize: Style.iconPointSize, color: .white, scale: pixelScale
            ) {
                icon.contents = rendered.image
                icon.bounds = CGRect(origin: .zero, size: rendered.size)
            }
            icon.position = CGPoint(x: itemCenter.x, y: itemCenter.y + 9)
            stage.addSublayer(icon)

            let label = textLayer(font: Style.labelFont)
            label.string = items[index].title
            label.opacity = Style.restingLabelOpacity
            let labelHeight = ceil(Style.labelFont.ascender - Style.labelFont.descender) + 2
            label.bounds = CGRect(x: 0, y: 0, width: Style.labelWidth, height: labelHeight)
            label.position = CGPoint(x: itemCenter.x, y: itemCenter.y - 17)
            stage.addSublayer(label)

            wedges.append(Wedge(highlight: highlight, icon: icon, label: label))
        }

        buildHub(accent: accent)

        blurView.maskImage = maskImage()
        addSubview(shadowHost)
        addSubview(blurView)
        addSubview(contentHost)
        updateHubText()
    }

    private func buildShadow() {
        guard let host = shadowHost.layer else { return }
        let outer = CGPath(ellipseIn: CGRect(
            x: ringCenter.x - layout.outerRadius, y: ringCenter.y - layout.outerRadius,
            width: layout.outerRadius * 2, height: layout.outerRadius * 2
        ), transform: nil)

        let shadow = CALayer()
        shadow.frame = bounds
        shadow.shadowPath = outer
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.38
        shadow.shadowRadius = 22
        shadow.shadowOffset = CGSize(width: 0, height: -7)

        // 그림자가 조각 사이 틈으로 비쳐 지저분해지지 않도록 원 바깥쪽만 남긴다.
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(outer)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = outside
        mask.fillRule = .evenOdd
        shadow.mask = mask
        host.addSublayer(shadow)
    }

    private func buildHub(accent: NSColor) {
        let hubRect = CGRect(
            x: ringCenter.x - hubRadius, y: ringCenter.y - hubRadius,
            width: hubRadius * 2, height: hubRadius * 2
        )
        let hubPath = CGPath(ellipseIn: hubRect, transform: nil)
        maskPath.addPath(hubPath)

        let hub = shapeLayer(path: hubPath)
        hub.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        hub.strokeColor = NSColor.white.withAlphaComponent(0.11).cgColor
        hub.lineWidth = 1
        stage.addSublayer(hub)

        // 커서 방향을 따라 도는 작은 호. 가운데 원과 조각 사이 틈에 놓인다.
        let span: CGFloat = 0.24
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: hubRadius + Style.hubInset / 2, startAngle: -span, endAngle: span, clockwise: false)
        pointer.path = arc
        pointer.fillColor = nil
        pointer.strokeColor = accent.cgColor
        pointer.lineWidth = 3
        pointer.lineCap = .round
        pointer.bounds = .zero
        pointer.position = ringCenter
        pointer.opacity = 0
        stage.addSublayer(pointer)

        for layer in [hubTitle, hubSubtitle] {
            layer.alignmentMode = .center
            // 줄바꿈은 wrapped(_:)가 직접 넣는다. 한 낱말이 너무 길면 말줄임표로 잘린다.
            layer.isWrapped = false
            layer.truncationMode = .end
            layer.contentsScale = pixelScale
            stage.addSublayer(layer)
        }
        hubTitle.font = Style.hubTitleFont
        hubTitle.fontSize = Style.hubTitleFont.pointSize
        hubTitle.foregroundColor = NSColor.white.cgColor
        hubSubtitle.font = Style.hubSubtitleFont
        hubSubtitle.fontSize = Style.hubSubtitleFont.pointSize
        hubSubtitle.foregroundColor = NSColor.white.withAlphaComponent(0.62).cgColor
    }

    /// 모서리가 둥근 조각. 안쪽으로 줄인 조각에 둥근 선 두께만큼을 다시 합쳐서 만든다.
    private func wedgePath(_ index: Int) -> CGPath {
        guard items.count > 1 else {
            return layout.sectorPath(index: index, center: ringCenter, gap: 0, inset: 0)
        }
        let core = layout.sectorPath(index: index, center: ringCenter, gap: Style.gap, inset: Style.corner)
        let rim = core.copy(strokingWithWidth: Style.corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return core.union(rim)
    }

    private func shapeLayer(path: CGPath) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = path
        layer.fillRule = .evenOdd
        return layer
    }

    private func textLayer(font: NSFont) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = NSColor.white.cgColor
        layer.alignmentMode = .center
        layer.truncationMode = .end
        layer.contentsScale = pixelScale
        return layer
    }

    private func maskImage() -> NSImage {
        let path = maskPath
        return NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
            return true
        }
    }

    // MARK: State

    /// 가운데에 보여 줄 안내 문구(아무것도 가리키지 않을 때).
    func setHubHint(_ hint: String) {
        guard hint != hubHint else { return }
        hubHint = hint
        if highlightedIndex == nil { updateHubText() }
    }

    func setHighlighted(_ index: Int?) {
        guard index != highlightedIndex else { return }
        let previous = highlightedIndex
        highlightedIndex = index

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if let previous, wedges.indices.contains(previous) {
            apply(highlighted: false, to: wedges[previous])
        }
        if let index, wedges.indices.contains(index) {
            apply(highlighted: true, to: wedges[index])
        }
        CATransaction.commit()
        updateHubText()
    }

    private func apply(highlighted: Bool, to wedge: Wedge) {
        wedge.highlight.opacity = highlighted ? 1 : 0
        wedge.icon.opacity = highlighted ? 1 : Style.restingIconOpacity
        wedge.label.opacity = highlighted ? 1 : Style.restingLabelOpacity
        let scale: CGFloat = highlighted ? 1.13 : 1
        wedge.icon.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    /// 커서 방향 표시. nil이면 숨긴다. 각도는 수학 관례(+x가 0, 반시계).
    func setPointer(angle: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let angle {
            pointer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            pointer.opacity = 1
        } else {
            pointer.opacity = 0
        }
        CATransaction.commit()
    }

    private func updateHubText() {
        let width = Style.hubTextWidth
        let title: String
        let subtitle: String
        if let index = highlightedIndex, items.indices.contains(index) {
            title = wrapped(items[index].title, font: Style.hubTitleFont, width: width, maxLines: 2)
            subtitle = wrapped(items[index].subtitle, font: Style.hubSubtitleFont, width: width, maxLines: 3)
        } else {
            title = ""
            subtitle = wrapped(hubHint, font: Style.hubSubtitleFont, width: width, maxLines: 3)
        }

        let titleHeight = title.isEmpty ? 0 : measure(title, font: Style.hubTitleFont)
        let subtitleHeight = subtitle.isEmpty ? 0 : measure(subtitle, font: Style.hubSubtitleFont)
        let spacing: CGFloat = (titleHeight > 0 && subtitleHeight > 0) ? 3 : 0
        let top = ringCenter.y + (titleHeight + spacing + subtitleHeight) / 2
        let left = ringCenter.x - width / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hubTitle.string = title
        hubTitle.frame = CGRect(x: left, y: top - titleHeight, width: width, height: titleHeight)
        hubSubtitle.string = subtitle
        hubSubtitle.frame = CGRect(
            x: left, y: top - titleHeight - spacing - subtitleHeight, width: width, height: subtitleHeight
        )
        CATransaction.commit()
    }

    /// 이미 줄바꿈이 들어간 글의 높이.
    private func measure(_ text: String, font: NSFont) -> CGFloat {
        let rect = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: 2000, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height) + 2
    }

    /// 낱말 단위로 줄을 나눈다. CATextLayer에 맡기면 한글을 글자 단위로 끊어 "붙여넣 / 기"처럼 된다.
    private func wrapped(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> String {
        func fits(_ candidate: String) -> Bool {
            NSAttributedString(string: candidate, attributes: [.font: font]).size().width <= width
        }
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var current = ""
            for word in paragraph.split(separator: " ") {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if current.isEmpty || fits(candidate) {
                    current = candidate
                } else {
                    lines.append(current)
                    current = String(word)
                }
            }
            if !current.isEmpty { lines.append(current) }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[maxLines - 1] += "…"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Animation

    func playAppear() {
        setPointer(angle: nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.9
        pop.toValue = 1
        pop.duration = 0.16
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        stage.add(pop, forKey: "appear")
    }

    // MARK: Snapshot

    /// 화면 밖에서 그린 미리보기. 실제 블러는 화면에 떠야만 나오므로, 그 자리는 비슷한 농도의 색으로 대신한다.
    func snapshot(lightBackdrop: Bool) -> NSBitmapImageRep? {
        let size = bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * pixelScale), pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = graphics.cgContext

        // 배경화면 대역: 밝은 화면과 어두운 화면 양쪽에서 읽히는지 보기 위한 그라디언트.
        let colors = lightBackdrop
            ? [NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.88, alpha: 1), NSColor(calibratedRed: 0.72, green: 0.83, blue: 0.94, alpha: 1)]
            : [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1), NSColor(calibratedRed: 0.32, green: 0.16, blue: 0.30, alpha: 1)]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]
        ) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }

        shadowHost.layer?.render(in: context)

        // HUD 블러 대역.
        context.setFillColor(NSColor(calibratedWhite: lightBackdrop ? 0.34 : 0.16, alpha: 0.82).cgColor)
        context.addPath(maskPath)
        context.fillPath(using: .evenOdd)

        contentHost.layer?.render(in: context)
        return rep
    }
}
