import AppKit
import Carbon.HIToolbox
import MacBKit

/// 원형 메뉴의 창과 상호작용.
///
/// 두 가지 방식으로 쓸 수 있다.
/// - 누른 채 긋기: 단축키를 누르고 있는 동안 떠 있고, 커서를 항목 쪽으로 밀고 키를 떼면 실행.
///   이때는 키 포커스를 가져오지 않아서 작업 중인 앱이 전혀 방해받지 않는다.
/// - 열어 두기: 단축키를 짧게 톡 누르면 열린 채로 남고, 클릭·숫자키·화살표로 고른다.
///
/// 어느 방식이든 떠 있는 동안에는 화면 전체가 클릭을 받는다. 조각을 클릭하면 실행하고, 그 밖을
/// 클릭(오른쪽 클릭 포함)하거나 esc를 누르면 아래 앱에는 아무것도 전하지 않고 닫는다.
@MainActor
final class RadialMenuController {
    private enum Mode {
        case closed
        case holding
        case latched
    }

    /// 이보다 짧게 누르고 떼면(커서도 그대로면) 열어 두기로 전환.
    private let tapThreshold: TimeInterval = 0.28

    private var items: [RadialItem] = []
    private var mode: Mode = .closed
    private var panel: RadialPanel?
    private var overlay: RadialOverlayView?
    private var menuView: RadialMenuView?
    private var needsRebuild = true
    private var builtScale: CGFloat = 0

    private var center = CGPoint.zero
    private var openedAt = Date.distantPast
    private var holdModifiers: KeyModifiers = []
    private var lastMouse = CGPoint.zero
    private var tracker: Timer?
    private var escapeHotKeys: [HotKeyCenter.Token] = []
    private var resignObserver: NSObjectProtocol?

    var isOpen: Bool { mode != .closed }

    func setItems(_ items: [RadialItem]) {
        if isOpen { close() }
        self.items = items
        needsRebuild = true
    }

    // MARK: Entry points

    /// 전역 단축키가 눌렸다.
    func hotkeyPressed(_ combo: KeyCombo) {
        switch mode {
        case .closed:
            open(as: .holding, hotkey: combo)
        case .latched:
            close()
        case .holding:
            break
        }
    }

    /// 전역 단축키에서 손을 뗐다.
    func hotkeyReleased() {
        guard mode == .holding else { return }
        finishHold()
    }

    /// 메뉴 막대나 `macb://menu`로 열 때: 처음부터 열어 두기 방식.
    func toggleLatched() {
        if isOpen {
            close()
        } else {
            open(as: .latched, hotkey: nil)
        }
    }

    // MARK: Open / close

    /// - Parameter hotkey: 누른 채 긋기로 열 때 누르고 있는 단축키.
    private func open(as newMode: Mode, hotkey: KeyCombo?) {
        guard !items.isEmpty else {
            Toast.show("원형 메뉴에 항목이 없습니다", symbol: "exclamationmark.triangle", detail: "config.json의 radialMenu.items를 확인하세요")
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let panel = self.panel ?? makePanel()
        // 배율이 다른 모니터로 옮겨 가면 아이콘·글자가 흐려지므로 그때도 다시 만든다.
        if needsRebuild || menuView == nil || builtScale != screen.backingScaleFactor {
            menuView?.removeFromSuperview()
            let view = RadialMenuView(items: items, pixelScale: screen.backingScaleFactor)
            overlay?.addSubview(view)
            menuView = view
            builtScale = screen.backingScaleFactor
            needsRebuild = false
        }
        guard let menuView else { return }

        // 화면 가장자리에서는 원이 잘리지 않게 안쪽으로 옮기고, 커서도 중심으로 데려온다.
        // (방향 판정이 커서–중심 기준이라 둘이 어긋나면 엉뚱한 항목이 잡힌다.)
        let reach = menuView.layout.outerRadius + 14
        let frame = screen.frame
        var point = mouse
        point.x = min(max(point.x, frame.minX + reach), frame.maxX - reach)
        point.y = min(max(point.y, frame.minY + reach), frame.maxY - reach)
        if point != mouse { warpCursor(to: point) }
        center = point
        lastMouse = point

        panel.setFrame(frame, display: false)
        let side = menuView.bounds.width
        menuView.setFrameOrigin(NSPoint(
            x: (point.x - frame.minX - side / 2).rounded(),
            y: (point.y - frame.minY - side / 2).rounded()
        ))
        menuView.setHighlighted(nil)

        mode = newMode
        openedAt = Date()
        holdModifiers = hotkey?.modifiers ?? []
        menuView.setHubHint(hint(for: newMode))
        captureEscape(holding: hotkey)

        panel.alphaValue = 1
        if newMode == .latched {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(overlay)
        } else {
            panel.orderFrontRegardless()
        }
        menuView.playAppear()
        startTracking()
        Log.info("radial: open \(newMode == .latched ? "latched" : "holding") items=\(items.count) center=(\(Int(point.x)),\(Int(point.y))) warped=\(point != mouse) visible=\(panel.isVisible) key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
    }

    private func latch() {
        mode = .latched
        menuView?.setHubHint(hint(for: .latched))
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(overlay)
        Log.info("radial: latched key=\(panel?.isKeyWindow ?? false)")
    }

    /// 바로 내린다. 사라지는 애니메이션을 두면 그동안 이 창이 키 포커스를 쥐고 있어서
    /// 닫은 직후 친 글자가 사라지고, 고른 기능도 포커스가 돌아가기 전에 시작된다.
    private func close() {
        guard mode != .closed else { return }
        mode = .closed
        Log.info("radial: close")
        tracker?.invalidate()
        tracker = nil
        releaseEscape()
        panel?.orderOut(nil)
    }

    private func execute(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        Log.info("radial: run \(item.id)")
        close()
        // 화면 캡처류가 메뉴 잔상을 찍지 않도록, 창이 실제로 사라질 틈을 준 뒤 실행한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated { item.perform() }
        }
    }

    private func finishHold() {
        // 마지막 타이머 틱 뒤에 커서가 더 움직였을 수 있으니 뗀 순간의 위치로 다시 고른다.
        trackHold()
        if let index = menuView?.highlightedIndex {
            execute(index)
        } else if Date().timeIntervalSince(openedAt) < tapThreshold {
            latch()
        } else {
            close()
        }
    }

    private func hint(for mode: Mode) -> String {
        switch mode {
        case .holding: return "밀어서 고르고\n키를 떼면 실행"
        case .latched: return "클릭 · 숫자키\nesc 닫기"
        case .closed: return ""
        }
    }

    // MARK: Tracking

    private func startTracking() {
        tracker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tracker = timer
    }

    private func tick() {
        guard let menuView, mode != .closed else { return }
        let mouse = NSEvent.mouseLocation
        let offset = CGPoint(x: mouse.x - center.x, y: mouse.y - center.y)
        let layout = menuView.layout

        switch mode {
        case .holding:
            trackHold()
            // 키 뗌 이벤트가 오지 않는 경우(보조키를 먼저 뗀 경우 등)를 대비해 보조키 상태도 직접 본다.
            // 보조키가 없는 단축키는 이렇게 알 수 없지만, 그때도 esc나 클릭으로 닫을 수 있다(captureEscape).
            if !holdModifiers.isEmpty,
               !KeyModifiers(eventFlags: NSEvent.modifierFlags).isSuperset(of: holdModifiers) {
                finishHold()
                return
            }
        case .latched:
            // 커서가 움직였을 때만 따라간다. 가만히 있는 커서가 키보드로 고른 항목을 덮어쓰면 안 된다.
            if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 0.5 {
                menuView.setHighlighted(layout.index(at: offset, bounded: true))
                updatePointer(offset: offset, bounded: true)
            }
        case .closed:
            break
        }
        lastMouse = mouse
    }

    /// 누른 채 긋는 동안: 지금 커서 방향의 항목을 강조한다(거리 제한 없음).
    private func trackHold() {
        guard let menuView else { return }
        let mouse = NSEvent.mouseLocation
        let offset = CGPoint(x: mouse.x - center.x, y: mouse.y - center.y)
        menuView.setHighlighted(menuView.layout.index(at: offset, bounded: false))
        updatePointer(offset: offset, bounded: false)
    }

    private func updatePointer(offset: CGPoint, bounded: Bool) {
        guard let menuView else { return }
        let visible = menuView.layout.index(at: offset, bounded: bounded) != nil
        menuView.setPointer(angle: visible ? atan2(offset.y, offset.x) : nil)
    }

    // MARK: Escape

    /// 누른 채 긋는 동안에는 키 포커스가 없어서 esc가 이 창에 오지 않는다. 그래서 떠 있는 동안에는
    /// esc를 전역 단축키로 잡아 둔다. 단축키를 누른 채로 누르는 경우(⌥esc 등)도 함께 잡는다.
    /// 보조키 없는 단축키의 뗌 이벤트를 놓쳐 긋기 상태로 남더라도 이것으로 빠져나올 수 있다.
    private func captureEscape(holding hotkey: KeyCombo?) {
        releaseEscape()
        let escape = UInt32(kVK_Escape)
        var variants: [KeyModifiers] = [[]]
        if let modifiers = hotkey?.modifiers, !modifiers.isEmpty { variants.append(modifiers) }
        for modifiers in variants {
            let combo = KeyCombo(keyCode: escape, modifiers: modifiers)
            // 원형 메뉴 단축키 자체가 esc 조합이면 이미 등록되어 있다.
            guard combo != hotkey else { continue }
            if let token = HotKeyCenter.shared.register(combo, onPress: { [weak self] in self?.close() }) {
                escapeHotKeys.append(token)
            }
        }
    }

    private func releaseEscape() {
        for token in escapeHotKeys { HotKeyCenter.shared.unregister(token) }
        escapeHotKeys.removeAll()
    }

    // MARK: Input from the overlay

    /// `location`은 화면 좌표.
    fileprivate func handleClick(at location: CGPoint) {
        guard let menuView, mode != .closed else { return }
        let offset = CGPoint(x: location.x - center.x, y: location.y - center.y)
        if let index = menuView.layout.index(at: offset, bounded: true) {
            execute(index)
        } else {
            close()
        }
    }

    fileprivate func handleCancel() {
        close()
    }

    fileprivate func handleKeyDown(_ event: NSEvent) {
        guard let menuView, mode == .latched else { return }
        let layout = menuView.layout
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            if let index = menuView.highlightedIndex { execute(index) }
        case kVK_UpArrow:
            highlightByKeyboard(layout.index(at: CGPoint(x: 0, y: 100), bounded: false))
        case kVK_RightArrow:
            highlightByKeyboard(layout.index(at: CGPoint(x: 100, y: 0), bounded: false))
        case kVK_DownArrow:
            highlightByKeyboard(layout.index(at: CGPoint(x: 0, y: -100), bounded: false))
        case kVK_LeftArrow:
            highlightByKeyboard(layout.index(at: CGPoint(x: -100, y: 0), bounded: false))
        case kVK_Tab:
            let step = event.modifierFlags.contains(.shift) ? items.count - 1 : 1
            let next = menuView.highlightedIndex.map { ($0 + step) % items.count } ?? 0
            highlightByKeyboard(next)
        default:
            let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
            if event.modifierFlags.intersection(blocking).isEmpty,
               let digit = KeyCombo.digit(forKeyCode: UInt32(event.keyCode)),
               digit >= 1, digit <= items.count {
                execute(digit - 1)
            }
        }
    }

    private func highlightByKeyboard(_ index: Int?) {
        guard let menuView, let index else { return }
        menuView.setHighlighted(index)
        menuView.setPointer(angle: menuView.layout.centerAngle(of: index))
    }

    // MARK: Window

    private func makePanel() -> RadialPanel {
        let panel = RadialPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 투명한 창은 기본적으로 다 비치는 부분의 클릭을 아래 앱으로 흘려보낸다. 그러면 메뉴는 닫혀도
        // 클릭이 아래 앱에 그대로 들어가고, Dock처럼 포커스를 가져가지 않는 곳을 누르면 닫히지도 않는다.
        // 명시적으로 false를 주면 화면 전체에서 클릭을 받는다.
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let overlay = RadialOverlayView(frame: panel.contentLayoutRect)
        overlay.autoresizingMask = [.width, .height]
        overlay.controller = self
        panel.contentView = overlay

        // 안전망: 열어 둔 상태에서 ⌘⇥ 등으로 포커스가 다른 창으로 넘어가면 닫는다.
        // 평소에 닫는 길(클릭, esc, 단축키)은 이것에 기대지 않는다.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .latched else { return }
                self.close()
            }
        }

        self.panel = panel
        self.overlay = overlay
        return panel
    }

    private func warpCursor(to point: CGPoint) {
        // AppKit은 왼쪽 아래, CoreGraphics는 주 화면의 왼쪽 위가 원점이다.
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - point.y))
        // 커서를 옮긴 직후 잠깐 마우스 입력이 멈추는 것을 풀어 준다.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: Snapshot

    /// 화면에 띄우지 않고 그린 미리보기(눈으로 확인하는 용도).
    static func renderSnapshot(items: [RadialItem], highlighted: Int?, lightBackdrop: Bool) -> NSBitmapImageRep? {
        let view = RadialMenuView(items: items, pixelScale: 2)
        view.setHubHint("밀어서 고르고\n키를 떼면 실행")
        if let highlighted {
            view.setHighlighted(highlighted)
            view.setPointer(angle: view.layout.centerAngle(of: highlighted))
        }
        CATransaction.flush()
        return view.snapshot(lightBackdrop: lightBackdrop)
    }
}

/// 다른 앱을 비활성화하지 않고도 키 입력을 받을 수 있는 패널.
private final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 화면 전체를 덮는 투명한 바닥. 메뉴가 떠 있는 동안의 클릭과 키 입력을 모두 받는다.
/// 누름은 삼키고 뗄 때 처리한다(누른 채 조각 밖으로 끌고 나가 떼면 취소).
private final class RadialOverlayView: NSView {
    weak var controller: RadialMenuController?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 하위 뷰(블러 등)가 이벤트를 가로채지 않게 한다.
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        controller?.handleClick(at: location)
    }

    override func rightMouseDown(with event: NSEvent) {}

    override func rightMouseUp(with event: NSEvent) {
        controller?.handleCancel()
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        controller?.handleCancel()
    }

    override func keyDown(with event: NSEvent) {
        controller?.handleKeyDown(event)
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.handleCancel()
    }
}
