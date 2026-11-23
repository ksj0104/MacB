import AppKit

/// 권한 안내 창. `PermissionGuide.content`를 그대로 그리고, 버튼은 `PermissionGuide.perform`으로 넘긴다.
/// 창은 하나만 만들어 닫아도 남겨 두고, 다시 열면 같은 창을 앞으로 가져온다.
@MainActor
final class PermissionGuideWindowController: NSObject, NSWindowDelegate, PermissionGuidePresenting {
    private weak var guide: PermissionGuide?
    private var window: NSWindow?
    private var renderScheduled = false
    private var settingsObserver: NSObjectProtocol?

    init(guide: PermissionGuide) {
        self.guide = guide
        super.init()
        // 시스템 설정이 앞으로 나온 것을 알린다. 요청한 뒤 '설정에 다녀왔다'는 근거가 된다.
        let settingsBundleID = "com.apple.systempreferences"
        settingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == settingsBundleID else { return }
            MainActor.assumeIsolated { self?.guide?.systemSettingsActivated() }
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func present(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        let wasVisible = window.isVisible
        render()
        if !wasVisible { window.center() }
        if activate {
            // 메뉴 막대 앱이라 MacB를 활성화해야 버튼과 키 입력을 받는다.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        // macOS 14부터 활성화는 '부탁'이라 거절될 수 있고(로그인 항목으로 떴을 때, 다른 앱을 쓰는 중일 때),
        // 그러면 makeKeyAndOrderFront는 창을 지금 앱의 창 뒤에 둔다. 활성화 여부와 상관없이 다른 앱의 창보다
        // 앞에 오도록 늘 이것으로 올린다. 키 창으로 만들지는 않으므로 포커스를 빼앗지 않는 쪽(클립보드)도 그대로다.
        window.orderFrontRegardless()
    }

    func contentDidChange(newlyGranted: Bool) {
        scheduleRender()
        // 시스템 설정에서 켜는 순간 창을 설정 위로 올려 결과를 보여 준다. 포커스는 빼앗지 않는다.
        if newlyGranted, let window, !window.isKeyWindow {
            window.orderFrontRegardless()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guide?.userReturned()
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = PermissionGuideNSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionGuideView.width, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "MacB 권한 설정"
        window.isReleasedWhenClosed = false
        // 전체 화면 앱 위에서도 뜨게 한다. 포커스를 빼앗지 않고 띄우는 경우(클립보드)는 그 앱의 공간에 그대로 있어야 보인다.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.delegate = self
        return window
    }

    /// 버튼의 동작 안에서 그 버튼을 바로 지우지 않도록 다음 차례에 다시 그린다. 여러 번 바뀌어도 한 번만 그린다.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderScheduled = false
                self.render()
            }
        }
    }

    /// 내용을 새로 만들어 끼우고, 창 위쪽 가장자리를 그대로 둔 채 높이를 맞춘다.
    private func render() {
        guard let window, let guide else { return }
        let view = guide.makeContentView { [weak window] in window?.close() }
        let top = window.frame.maxY
        let left = window.frame.minX
        window.contentView = view
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: view.fittingSize))
        frame.origin = NSPoint(x: left, y: top - frame.height)
        window.setFrame(frame, display: true)
    }
}

/// `esc`와 `⌘W`로 닫히는 창. 메뉴 막대 앱이라 '닫기' 메뉴 항목이 없어서 직접 받는다.
private final class PermissionGuideNSWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

public extension PermissionGuide {
    /// 지금 `content`를 그린 창 내용. 버튼은 `perform`으로, '닫기'는 `close`로 이어진다.
    /// 창, 스냅샷, 자체 테스트가 같은 것을 쓴다.
    func makeContentView(close: @escaping @MainActor () -> Void) -> NSView {
        PermissionGuideView.make(content: content, perform: { [weak self] action, permission in
            self?.perform(action, on: permission)
        }, close: close)
    }
}

// MARK: - Content view

private enum PermissionGuideView {
    static let width: CGFloat = 480
    static let padding: CGFloat = 20
    static let innerWidth = width - padding * 2
    static let rowInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    /// 줄 안에서 아이콘이 차지하는 폭(아이콘 + 간격). 글은 이만큼 들여 쓴다.
    static let iconColumn: CGFloat = 30
    static let textWidth = innerWidth - rowInsets.left - rowInsets.right - iconColumn

    static func make(
        content: PermissionGuide.Content,
        perform: @escaping @MainActor (PermissionGuide.Action, PermissionKind) -> Void,
        close: @escaping @MainActor () -> Void
    ) -> NSView {
        let root = PermissionGuideBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: 300))

        let header = makeHeader(content)
        var views: [NSView] = [header]
        views += content.rows.map { makeRow($0, perform: perform) }
        views.append(makeFooter(content, close: close))

        let stack = verticalStack(views, spacing: 10)
        stack.setCustomSpacing(18, after: header)
        if let lastRow = views.dropLast().last {
            stack.setCustomSpacing(16, after: lastRow)
        }
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(equalToConstant: innerWidth),
        ])
        return root
    }

    // MARK: Parts

    private static func makeHeader(_ content: PermissionGuide.Content) -> NSView {
        let icon = symbolView(
            content.allGranted ? "checkmark.shield.fill" : "lock.shield",
            size: 26,
            tint: content.allGranted ? .systemGreen : .controlAccentColor
        )
        let iconBox = fixedWidth(icon, 34)
        let textWidth = innerWidth - 34 - 12
        let headline = label(content.headline, font: .systemFont(ofSize: 15, weight: .semibold), width: textWidth)
        let detail = label(content.detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, width: textWidth)
        let texts = verticalStack([headline, detail], spacing: 4)
        return horizontalStack([iconBox, texts], spacing: 12, alignment: .top)
    }

    private static func makeRow(
        _ row: PermissionGuide.Row,
        perform: @escaping @MainActor (PermissionGuide.Action, PermissionKind) -> Void
    ) -> NSView {
        let title = label(row.title, font: .systemFont(ofSize: 13, weight: .semibold))
        let titleLine = horizontalStack([title, flexibleSpace(), makeStatus(row)], spacing: 8, alignment: .centerY)
        titleLine.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        let summary = label(row.summary, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, width: textWidth)
        var body: [NSView] = [titleLine, summary]
        if !row.steps.isEmpty { body.append(makeSteps(row.steps)) }
        var noteView: NSView?
        if let note = row.note {
            let view = makeNote(note, stage: row.stage)
            body.append(view)
            noteView = view
        }
        // 초기화처럼 되돌릴 수 없는 버튼은 그 이유를 적은 안내 글 바로 아래에 따로 두어, 기본 버튼 줄과 섞이지 않게 한다.
        let destructive = row.buttons.filter(\.action.isDestructive)
        let regular = row.buttons.filter { !$0.action.isDestructive }
        if !destructive.isEmpty { body.append(makeButtonLine(destructive, row: row, perform: perform, alignment: .leading)) }
        if !regular.isEmpty { body.append(makeButtonLine(regular, row: row, perform: perform, alignment: .trailing)) }

        let bodyStack = verticalStack(body, spacing: 10)
        bodyStack.setCustomSpacing(2, after: titleLine)
        if let noteView, !destructive.isEmpty { bodyStack.setCustomSpacing(6, after: noteView) }

        let icon = fixedWidth(
            symbolView(row.symbol, size: 16, tint: row.isGranted ? .secondaryLabelColor : .labelColor),
            iconColumn - 10
        )
        let line = horizontalStack([icon, bodyStack], spacing: 10, alignment: .top)

        let box = PermissionRowBackgroundView(focused: row.isFocused)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: box.topAnchor, constant: rowInsets.top),
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: rowInsets.left),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -rowInsets.bottom),
            box.widthAnchor.constraint(equalToConstant: innerWidth),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("\(row.title): \(row.statusText)")
        return box
    }

    private static func makeStatus(_ row: PermissionGuide.Row) -> NSView {
        let icon = symbolView(
            row.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            size: 12,
            tint: row.isGranted ? .systemGreen : .systemOrange
        )
        let text = label(
            row.statusText,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: row.isGranted ? .secondaryLabelColor : .labelColor
        )
        return horizontalStack([icon, text], spacing: 4, alignment: .centerY)
    }

    private static func makeSteps(_ steps: [String]) -> NSView {
        let badgeWidth: CGFloat = 16
        let lines = steps.enumerated().map { index, step -> NSView in
            let badge = fixedWidth(symbolView("\(index + 1).circle.fill", size: 13, tint: .tertiaryLabelColor), badgeWidth)
            let text = label(step, font: .systemFont(ofSize: 12), width: textWidth - badgeWidth - 6)
            return horizontalStack([badge, text], spacing: 6, alignment: .top)
        }
        return verticalStack(lines, spacing: 5)
    }

    private static func makeNote(_ note: String, stage: PermissionGuide.Stage) -> NSView {
        let symbol: String
        let tint: NSColor
        switch stage {
        case .stillMissing:
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
        case .resetting:
            symbol = "arrow.triangle.2.circlepath"
            tint = .secondaryLabelColor
        default:
            symbol = "info.circle"
            tint = .secondaryLabelColor
        }
        let icon = fixedWidth(symbolView(symbol, size: 11, tint: tint), 16)
        let text = label(note, font: .systemFont(ofSize: 11.5), color: .secondaryLabelColor, width: textWidth - 16 - 6)
        return horizontalStack([icon, text], spacing: 6, alignment: .top)
    }

    /// `.trailing`은 macOS 관례대로 오른쪽에 붙인 줄(기본 버튼이 오른쪽 끝), `.leading`은 안내 글 아래에 들여 붙인 줄.
    private static func makeButtonLine(
        _ specs: [PermissionGuide.Button],
        row: PermissionGuide.Row,
        perform: @escaping @MainActor (PermissionGuide.Action, PermissionKind) -> Void,
        alignment: NSLayoutConstraint.Attribute
    ) -> NSView {
        let permission = row.permission
        let buttons = specs.map { spec -> NSView in
            let button = PermissionGuideButton(title: spec.title) { perform(spec.action, permission) }
            button.isEnabled = spec.isEnabled
            // 기본 버튼은 모델이 정한다(되돌릴 수 없는 동작은 절대 아니다).
            if spec.isDefault, !spec.action.isDestructive {
                button.keyEquivalent = "\r"
            }
            return button
        }
        let views = alignment == .trailing ? [flexibleSpace()] + buttons : [noteIndent()] + buttons + [flexibleSpace()]
        let line = horizontalStack(views, spacing: 8, alignment: .centerY)
        line.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        return line
    }

    /// 안내 글의 아이콘 칸만큼 띄워 버튼을 글의 시작에 맞춘다(아이콘 16 + 간격 6, 줄 간격 8을 뺀 값).
    private static func noteIndent() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 16 + 6 - 8).isActive = true
        return view
    }

    private static func makeFooter(_ content: PermissionGuide.Content, close: @escaping @MainActor () -> Void) -> NSView {
        let button = PermissionGuideButton(title: "닫기", handler: close)
        // 모두 허용되면 할 일은 닫기뿐이라 기본 버튼으로 둔다. 그 전에는 esc로 닫는다.
        button.keyEquivalent = content.allGranted ? "\r" : "\u{1b}"
        let line = horizontalStack([flexibleSpace(), button], spacing: 8, alignment: .centerY)
        line.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        return line
    }

    // MARK: Helpers

    private static func label(
        _ text: String, font: NSFont, color: NSColor = .labelColor, width: CGFloat? = nil
    ) -> NSTextField {
        let field = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.isSelectable = false
        if let width {
            field.preferredMaxLayoutWidth = width
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return field
    }

    private static func symbolView(_ name: String, size: CGFloat, tint: NSColor) -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil))?
            .withSymbolConfiguration(configuration)
        let view = NSImageView()
        view.image = image
        view.contentTintColor = tint
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    /// 아이콘마다 폭이 달라도 글의 시작이 맞도록 가운데 정렬한 고정 폭 칸에 넣는다.
    private static func fixedWidth(_ view: NSView, _ width: CGFloat) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            view.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            view.topAnchor.constraint(equalTo: box.topAnchor),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private static func flexibleSpace() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return view
    }

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func horizontalStack(
        _ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// 창 바탕. 창 안에서는 창이 그리는 것과 같고, 스냅샷에서는 바탕이 비지 않게 한다.
private final class PermissionGuideBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// 권한 한 줄을 감싸는 둥근 상자. 앞세운 줄은 강조색 테두리.
private final class PermissionRowBackgroundView: NSView {
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055)
            : NSColor(white: 1, alpha: 0.8)
    }

    private let focused: Bool

    init(focused: Bool) {
        self.focused = focused
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = focused ? 0.75 : 0.5
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 9, yRadius: 9)
        Self.fill.setFill()
        path.fill()
        if focused {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}

/// 클로저로 동작하는 버튼.
private final class PermissionGuideButton: NSButton {
    private var handler: (@MainActor () -> Void)?

    convenience init(title: String, handler: @escaping @MainActor () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .push
        controlSize = .regular
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func fire() {
        handler?()
    }
}

// MARK: - Snapshot

public extension PermissionGuide {
    /// 예시 상태로 창 내용을 화면 밖에서 그려 PNG로 저장한다(눈으로 확인하는 용도). 실제 권한·설정은 건드리지 않는다.
    /// `permissions-<상태>.png`와 어두운 모드 `permissions-<상태>-dark.png`를 만든다.
    static func writeDebugSnapshots(to directory: URL) throws {
        // 창 객체를 만들려면 AppKit이 초기화돼 있어야 한다. 실행(run)은 하지 않으므로 화면에는 아무것도 뜨지 않는다.
        if NSApp == nil {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("macb-permission-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 설정에 머문 시간을 흉내 내려고 시계를 앞으로 돌린다.
        var clock = Date()
        func makeGuide(granted: Set<PermissionKind>, stateFile: URL? = nil, resetSucceeds: Bool = true) -> PermissionGuide {
            let guide = PermissionGuide(
                system: PermissionSnapshotSystem(granted: granted, resetSucceeds: resetSucceeds),
                stateFile: stateFile ?? scratch.appendingPathComponent("\(UUID().uuidString).json"),
                now: { clock },
                announce: { _ in },
                makePresenter: { _ in PermissionSnapshotPresenter() }
            )
            guide.relaunchAction = {}
            return guide
        }

        var states: [(name: String, guide: PermissionGuide)] = []

        // 스크린샷을 찍으려다 권한이 없어 열린 모습.
        let missing = makeGuide(granted: [])
        missing.show(for: .screenshot)
        states.append(("missing", missing))

        // 메뉴에서 연 모습. 손쉬운 사용만 허용됨.
        let oneGranted = makeGuide(granted: [.accessibility])
        oneGranted.show()
        states.append(("one-granted", oneGranted))

        // 화면 기록을 요청하고 시스템 설정을 연 뒤: 다시 시작할 차례.
        let relaunch = makeGuide(granted: [.accessibility])
        relaunch.show()
        relaunch.perform(.request, on: .screenCapture)
        states.append(("relaunch", relaunch))

        // 손쉬운 사용을 요청하고 시스템 설정에 다녀왔는데 여전히 꺼져 있음(다시 빌드해서 예전 항목이 맞지 않는 경우).
        let stillMissing = makeGuide(granted: [.screenCapture])
        stillMissing.show(for: .autoPaste)
        stillMissing.perform(.request, on: .accessibility)
        stillMissing.systemSettingsActivated()
        clock.addTimeInterval(30)
        stillMissing.userReturned()
        states.append(("still-missing", stillMissing))

        // 화면 기록을 요청하고 다시 시작했는데 여전히 꺼져 있음.
        let resumeFile = scratch.appendingPathComponent("resume.json")
        makeGuide(granted: [.accessibility], stateFile: resumeFile).perform(.request, on: .screenCapture)
        let stillMissingScreen = makeGuide(granted: [.accessibility], stateFile: resumeFile)
        stillMissingScreen.showAtLaunchIfNeeded()
        states.append(("still-missing-screen", stillMissingScreen))

        // 그 상태에서 초기화하지 못함(버튼이 가장 많은 줄).
        let failedFile = scratch.appendingPathComponent("failed.json")
        makeGuide(granted: [.accessibility], stateFile: failedFile).perform(.request, on: .screenCapture)
        let resetFailed = makeGuide(granted: [.accessibility], stateFile: failedFile, resetSucceeds: false)
        resetFailed.showAtLaunchIfNeeded()
        resetFailed.perform(.resetAndRelaunch, on: .screenCapture)
        states.append(("reset-failed", resetFailed))

        let allGranted = makeGuide(granted: [.screenCapture, .accessibility])
        allGranted.show()
        states.append(("all-granted", allGranted))

        let appearances: [(suffix: String, name: NSAppearance.Name)] = [("", .aqua), ("-dark", .darkAqua)]
        for variant in appearances {
            guard let appearance = NSAppearance(named: variant.name) else { continue }
            for state in states {
                let png = try renderSnapshot(state.guide, appearance: appearance)
                try png.write(to: directory.appendingPathComponent("permissions-\(state.name)\(variant.suffix).png"), options: .atomic)
            }
        }
        for state in states { state.guide.stopPolling() }
    }

    private static func renderSnapshot(_ guide: PermissionGuide, appearance: NSAppearance) throws -> Data {
        let view = guide.makeContentView {}
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        // 화면에 올리지 않는(orderFront 하지 않는) 창. 컨트롤이 제 모양으로 그려지려면 창 안에 있어야 한다.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
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
        guard let data else { throw PermissionGuideSnapshotError.renderFailed }
        return data
    }
}

private enum PermissionGuideSnapshotError: Error {
    case renderFailed
}

/// 스냅샷용: 정해 둔 상태만 돌려주고 아무것도 요청하지 않는다.
@MainActor
private final class PermissionSnapshotSystem: PermissionSystem {
    private let granted: Set<PermissionKind>
    private let resetSucceeds: Bool

    init(granted: Set<PermissionKind>, resetSucceeds: Bool) {
        self.granted = granted
        self.resetSucceeds = resetSucceeds
    }

    func isGranted(_ permission: PermissionKind) -> Bool { granted.contains(permission) }
    func request(_ permission: PermissionKind) {}
    func openSettings(_ permission: PermissionKind) {}
    func reset(_ permission: PermissionKind, completion: @escaping @MainActor (Bool) -> Void) { completion(resetSucceeds) }
}

/// 스냅샷용: 창을 띄우지 않는다.
@MainActor
private final class PermissionSnapshotPresenter: PermissionGuidePresenting {
    var isVisible: Bool { false }
    func present(activate: Bool) {}
    func contentDidChange(newlyGranted: Bool) {}
}
