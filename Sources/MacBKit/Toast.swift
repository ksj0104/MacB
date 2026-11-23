import AppKit

/// 화면 아래쪽에 잠깐 떴다 사라지는 알림. 포커스를 가져가지 않고 클릭도 통과시킨다.
@MainActor
public enum Toast {
    /// - Parameters:
    ///   - symbol: SF Symbols 이름.
    ///   - detail: 둘째 줄(작은 글씨, 한 줄로 잘림).
    ///   - swatch: 아이콘 대신 보여 줄 색상 견본.
    public static func show(
        _ message: String,
        symbol: String? = nil,
        detail: String? = nil,
        swatch: NSColor? = nil,
        duration: TimeInterval = 1.8
    ) {
        ToastPresenter.shared.show(
            message: message, symbol: symbol, detail: detail, swatch: swatch, duration: duration
        )
    }
}

@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var panel: NSPanel?
    private var generation = 0

    func show(message: String, symbol: String?, detail: String?, swatch: NSColor?, duration: TimeInterval) {
        generation += 1
        let current = generation

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let content = ToastPresenter.makeContent(message: message, symbol: symbol, detail: detail, swatch: swatch)
        panel.contentView = content
        let size = content.fittingSize

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 96).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        guard self.generation == current else { return }
                        panel.orderOut(nil)
                    }
                })
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .vibrantDark)
        return panel
    }

    // MARK: Content

    /// 화면 밖에서도 그릴 수 있도록 순수 뷰 트리로 만든다.
    static func makeContent(message: String, symbol: String?, detail: String?, swatch: NSColor?) -> NSView {
        let cornerRadius: CGFloat = 14

        // 창의 contentView로 들어가므로 root 자체의 프레임은 창이 정하게 둔다.
        let root = NSView()
        root.appearance = NSAppearance(named: .vibrantDark)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = VisualMask.rounded(radius: cornerRadius)
        blur.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(blur)

        // 블러 위에 얹는 어두운 막. 밝은 배경에서도 글자 대비를 지켜 준다.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        tint.layer?.cornerRadius = cornerRadius
        tint.layer?.cornerCurve = .continuous
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tint)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(row)

        if let swatch {
            let chip = NSView()
            chip.wantsLayer = true
            chip.layer?.backgroundColor = swatch.cgColor
            chip.layer?.cornerRadius = 5
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
            chip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: 20),
                chip.heightAnchor.constraint(equalToConstant: 20),
            ])
            row.addArrangedSubview(chip)
        } else if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            icon.contentTintColor = .white
            icon.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(icon)
        }

        let texts = NSStackView()
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        texts.addArrangedSubview(label(message, font: .systemFont(ofSize: 13, weight: .semibold), color: .white))
        if let detail, !detail.isEmpty {
            texts.addArrangedSubview(label(
                detail, font: .systemFont(ofSize: 11.5), color: NSColor.white.withAlphaComponent(0.66)
            ))
        }
        row.addArrangedSubview(texts)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    /// 한 줄짜리 글자. 폭을 직접 재서 못박아 둔다 — 스택 뷰에 맡기면 가장 긴 줄이 아닌 쪽이 잘리는 일이 있었다.
    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let maximumWidth: CGFloat = 400
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        let natural = ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 6
        field.widthAnchor.constraint(equalToConstant: min(natural, maximumWidth)).isActive = true
        return field
    }
}

public extension Toast {
    /// 화면에 띄우지 않고 그린 미리보기(개발용). 블러 자리는 회색 바탕으로 대신한다.
    static func renderSnapshot(
        _ message: String, symbol: String? = nil, detail: String? = nil, swatch: NSColor? = nil
    ) -> NSBitmapImageRep? {
        let content = ToastPresenter.makeContent(message: message, symbol: symbol, detail: detail, swatch: swatch)
        let size = content.fittingSize
        let margin: CGFloat = 16
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
        content.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        canvas.addSubview(content)
        canvas.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.bounds.width * scale), pixelsHigh: Int(canvas.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = canvas.bounds.size
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        return rep
    }
}

/// `NSVisualEffectView.maskImage`용 마스크 이미지.
public enum VisualMask {
    /// 늘어나도 모서리가 유지되는 둥근 사각형 마스크.
    public static func rounded(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
