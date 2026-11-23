import AppKit

/// 패널을 화면에 띄우지 않고 그려 PNG로 남긴다. 예시 데이터는 모두 메모리에서 만든다
/// (실제 클립보드·디스크는 건드리지 않는다).
@MainActor
enum ClipboardSnapshot {
    enum SnapshotError: Error {
        case renderFailed(String)
    }

    static func write(to directory: URL) throws {
        // 창 객체를 만들려면 AppKit이 초기화돼 있어야 한다. 실행(run)은 하지 않으므로 화면에는 아무것도 뜨지 않는다.
        // 이미 돌고 있는 앱 안에서 불렸다면 그 앱의 설정은 건드리지 않는다.
        if NSApp == nil {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }

        let now = Date()
        let history = sampleHistory(now: now)
        let slots = sampleSlots(now: now, history: history)
        let hints = ClipboardFeature.HotkeyHints(history: "⌥V", slotCopyModifiers: "⌃⌥", slotPasteModifiers: "⌥")

        let appearances: [(suffix: String, name: NSAppearance.Name)] = [("", .aqua), ("-dark", .darkAqua)]
        let tabs: [(name: String, tab: ClipboardFeature.PanelTab, selectedRow: Int)] = [
            ("clipboard-history", .history, 0),
            ("clipboard-slots", .slots, 1),
        ]
        for variant in appearances {
            guard let appearance = NSAppearance(named: variant.name) else { continue }
            for page in tabs {
                let controller = ClipboardPanelController(opaqueBackground: true)
                controller.hints = hints
                let png = try render(controller, appearance: appearance) {
                    controller.prepareSnapshot(history: history, slots: slots, tab: page.tab, selectedRow: page.selectedRow)
                }
                try png.write(to: directory.appendingPathComponent(page.name + variant.suffix + ".png"), options: .atomic)
            }
        }

        // 처음 실행했을 때 보이는 빈 기록 화면.
        if let light = NSAppearance(named: .aqua) {
            let controller = ClipboardPanelController(opaqueBackground: true)
            controller.hints = hints
            let png = try render(controller, appearance: light) {
                controller.prepareSnapshot(history: [], slots: slots, tab: .history, selectedRow: 0)
            }
            try png.write(to: directory.appendingPathComponent("clipboard-history-empty.png"), options: .atomic)
        }
    }

    // MARK: Rendering

    private static func render(
        _ controller: ClipboardPanelController,
        appearance: NSAppearance,
        prepare: () -> Void
    ) throws -> Data {
        let size = PanelMetrics.size
        let view = controller.contentView
        // 화면에 올리지 않는(orderFront 하지 않는) 창. 표가 행을 만들려면 창 안에 있어야 한다.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            prepare()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        window.contentView = nil
        guard let data else { throw SnapshotError.renderFailed("PNG 인코딩 실패") }
        return data
    }

    // MARK: Samples

    private typealias Item = ClipboardFeature.Item

    private static func app(_ name: String, _ bundleID: String) -> ClipboardFeature.SourceApp {
        ClipboardFeature.SourceApp(name: name, bundleID: bundleID)
    }

    private static func textItem(_ text: String, _ source: ClipboardFeature.SourceApp, _ date: Date) -> Item? {
        Payload(items: [[.init(type: Payload.plainTextType, data: Data(text.utf8))]])
            .makeItem(date: date, source: source)
    }

    private static func filesItem(_ names: [String], _ source: ClipboardFeature.SourceApp, _ date: Date) -> Item? {
        let items = names.map { name -> [Payload.Representation] in
            let url = URL(fileURLWithPath: "/Users/example/Documents").appendingPathComponent(name)
            return [.init(type: Payload.fileURLType, data: Data(url.absoluteString.utf8))]
        }
        return Payload(items: items).makeItem(date: date, source: source)
    }

    private static func imageItem(_ source: ClipboardFeature.SourceApp, _ date: Date) -> Item? {
        guard let png = sampleImagePNG(width: 1280, height: 720) else { return nil }
        return Payload(items: [[.init(type: Payload.pngType, data: png)]]).makeItem(date: date, source: source)
    }

    private static func sampleHistory(now: Date) -> [Item] {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        let items: [Item?] = [
            textItem(
                "내일 오전 10시 회의실 B에서 분기 리뷰 진행합니다. 자료는 공유 드라이브에 올려 두었어요.",
                app("Slack", "com.tinyspeck.slackmacgap"), now.addingTimeInterval(-20)
            ),
            textItem(
                "https://developer.apple.com/documentation/appkit/nspanel",
                app("Safari", "com.apple.Safari"), now.addingTimeInterval(-2 * minute)
            ),
            imageItem(app("미리보기", "com.apple.Preview"), now.addingTimeInterval(-5 * minute)),
            textItem(
                "let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)",
                app("Visual Studio Code", "com.microsoft.VSCode"), now.addingTimeInterval(-12 * minute)
            ),
            filesItem(
                ["2026_4분기_예산안.xlsx", "회의록_11월.pdf", "logo@2x.png"],
                app("Finder", "com.apple.finder"), now.addingTimeInterval(-34 * minute)
            ),
            textItem("서울특별시 강남구 테헤란로 123, 4층", app("메모", "com.apple.Notes"), now.addingTimeInterval(-1 * hour - 5 * minute)),
            textItem(
                "Thanks! I'll take a look at the PR this afternoon and leave comments.",
                app("Mail", "com.apple.mail"), now.addingTimeInterval(-3 * hour)
            ),
            textItem("010-1234-5678", app("메시지", "com.apple.MobileSMS"), now.addingTimeInterval(-1 * day)),
            textItem(
                "SELECT id, name FROM users WHERE created_at > now() - interval '7 days';",
                app("터미널", "com.apple.Terminal"), now.addingTimeInterval(-2 * day)
            ),
            textItem("주간 보고서 초안 — 진행 상황 요약 및 다음 주 계획", app("Pages", "com.apple.iWork.Pages"), now.addingTimeInterval(-10 * day)),
        ]
        return items.compactMap { $0 }
    }

    private static func sampleSlots(now: Date, history: [Item]) -> [Item?] {
        var slots = [Item?](repeating: nil, count: ClipboardFeature.slotRange.count)
        slots[0] = textItem("hello@example.com", app("메일", "com.apple.mail"), now.addingTimeInterval(-3 * 86400))
        slots[1] = textItem(
            "감사합니다. 확인 후 오늘 중으로 회신드리겠습니다. 좋은 하루 보내세요!",
            app("Slack", "com.tinyspeck.slackmacgap"), now.addingTimeInterval(-2 * 3600)
        )
        slots[2] = history.first { $0.kind == .image }.map { image in
            var copy = image
            copy.id = UUID()
            return copy
        }
        slots[4] = textItem("123-45-67890", app("메모", "com.apple.Notes"), now.addingTimeInterval(-40 * 60))
        slots[6] = filesItem(["계약서_최종.pdf"], app("Finder", "com.apple.finder"), now.addingTimeInterval(-86400))
        return slots
    }

    /// 썸네일이 실제처럼 보이도록 간단한 풍경을 그린다.
    private static func sampleImagePNG(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSGradient(
            starting: NSColor(srgbRed: 0.99, green: 0.74, blue: 0.52, alpha: 1),
            ending: NSColor(srgbRed: 0.33, green: 0.55, blue: 0.93, alpha: 1)
        )?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)

        NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w * 0.62, y: h * 0.45, width: h * 0.24, height: h * 0.24)).fill()

        let far = NSBezierPath()
        far.move(to: NSPoint(x: 0, y: h * 0.38))
        far.curve(to: NSPoint(x: w, y: h * 0.42), controlPoint1: NSPoint(x: w * 0.3, y: h * 0.62), controlPoint2: NSPoint(x: w * 0.6, y: h * 0.25))
        far.line(to: NSPoint(x: w, y: 0))
        far.line(to: NSPoint(x: 0, y: 0))
        far.close()
        NSColor(srgbRed: 0.27, green: 0.45, blue: 0.42, alpha: 1).setFill()
        far.fill()

        let near = NSBezierPath()
        near.move(to: NSPoint(x: 0, y: h * 0.2))
        near.curve(to: NSPoint(x: w, y: h * 0.16), controlPoint1: NSPoint(x: w * 0.35, y: h * 0.05), controlPoint2: NSPoint(x: w * 0.7, y: h * 0.4))
        near.line(to: NSPoint(x: w, y: 0))
        near.line(to: NSPoint(x: 0, y: 0))
        near.close()
        NSColor(srgbRed: 0.16, green: 0.3, blue: 0.27, alpha: 1).setFill()
        near.fill()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
