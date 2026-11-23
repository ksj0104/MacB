import AppKit
import Carbon.HIToolbox

/// 단축키 칸. 누르면 기록을 시작하고, 이어서 누른 키 조합을 `onEvent`로 알려 준다.
/// esc는 취소, ⌫는 지우기. 값이 맞는지(보조키, 겹침)는 칸이 아니라 `ShortcutSettings`가 정한다.
///
/// 기록하는 동안에는 MacB의 전역 단축키를 잠시 꺼 두어야 한다. 켜 두면 등록된 조합은 시스템이 먼저 가로채
/// 이 칸까지 오지 않는다. 기록 시작·끝은 `onRecordingChange`로 알린다.
@MainActor
final class ShortcutRecorderView: NSView {
    enum Event {
        case combo(KeyCombo)
        case modifiers(KeyModifiers)
        case clear
    }

    var recording: ShortcutSettings.Recording = .combo {
        didSet { needsDisplay = true }
    }
    var value: ShortcutSettings.Value = .none {
        didSet { refreshAccessibility() }
    }
    var onEvent: ((Event) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    /// 화면 밖 스냅샷에서 기록 중인 모습을 그리기 위한 것.
    var drawsAsRecording = false {
        didSet { needsDisplay = true }
    }

    private(set) var isRecording = false
    private var heldModifiers: KeyModifiers = []

    static let size = NSSize(width: 132, height: 24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "누른 뒤 단축키를 누르세요 · ⌫ 지우기 · esc 취소"
        refreshAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: Recording

    func startRecording() {
        guard !isRecording, let window else { return }
        if window.firstResponder !== self {
            guard window.makeFirstResponder(self) else { return }
        }
        isRecording = true
        heldModifiers = []
        needsDisplay = true
        refreshAccessibility()
        onRecordingChange?(true)
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        needsDisplay = true
        refreshAccessibility()
        onRecordingChange?(false)
    }

    /// 창이 앞에 있지만 MacB가 활성 앱이 아닐 때(활성화가 거절된 경우 등) 첫 클릭이 창만 활성화하고 끝나지 않게,
    /// 그 클릭으로 바로 기록을 시작한다. 버튼·스위치처럼 첫 클릭에 반응한다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func accessibilityPerformPress() -> Bool {
        if isRecording { stopRecording() } else { startRecording() }
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // 칸이 사라질 때 기록 중이면 끝났다고 알려야 전역 단축키가 다시 켜진다.
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // 탭으로 칸에 왔을 때는 Space나 Return으로 기록을 시작한다.
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if plain, [kVK_Space, kVK_Return].contains(Int(event.keyCode)) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        record(event)
    }

    /// ⌘·⌃ 조합은 keyDown보다 먼저 여기로 온다. 기록 중이면 창의 다른 단축키보다 먼저 가져간다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘W는 창을 닫으려고 누른 것이다. 기록하지 않고 칸만 멈춘 뒤 창에게 넘긴다(창이 닫는다).
        // 기록했다면 거절되더라도(모든 앱이 쓰는 단축키) 창이 닫히지 않아 갇힌 것처럼 보인다.
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags)
        if modifiers == [.command], Int(event.keyCode) == kVK_ANSI_W || event.charactersIgnoringModifiers?.lowercased() == "w" {
            stopRecording()
            return false
        }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        heldModifiers = KeyModifiers(eventFlags: event.modifierFlags)
        needsDisplay = true
    }

    private func record(_ event: NSEvent) {
        // 결과를 받은 창이 내용을 다시 그리면 이 칸은 버려진다. 끝날 때까지 붙들어 둔다.
        withExtendedLifetime(self) { recordKey(event) }
    }

    private func recordKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags)
        let keyCode = Int(event.keyCode)
        if modifiers.isEmpty, keyCode == kVK_Escape {
            stopRecording()
            return
        }
        // 먼저 기록을 끝내고(전역 단축키가 다시 켜지도록) 결과를 알린다. 알림을 받은 창이 칸을 새로 만들 수 있다.
        stopRecording()
        if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            onEvent?(.clear)
            return
        }
        switch recording {
        case .modifiers:
            onEvent?(.modifiers(modifiers))
        case .combo:
            onEvent?(.combo(KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers)))
        }
    }

    // MARK: Drawing

    private var showsRecording: Bool { isRecording || drawsAsRecording }

    private var displayText: (text: String, color: NSColor) {
        if showsRecording {
            if heldModifiers.isEmpty {
                return (recording == .modifiers ? "보조키 + 숫자" : "단축키를 누르세요", .secondaryLabelColor)
            }
            let suffix = recording == .modifiers ? " + 숫자" : ""
            return (heldModifiers.displayString + suffix, .labelColor)
        }
        switch value {
        case .none: return ("없음", .tertiaryLabelColor)
        case .combo(let combo): return (combo.displayString, .labelColor)
        case .modifiers(let modifiers): return ("\(modifiers.displayString) + 숫자", .labelColor)
        case .invalid(let text): return (text, .systemRed)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let recording = showsRecording
        let rect = bounds.insetBy(dx: recording ? 1 : 0.5, dy: recording ? 1 : 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        path.lineWidth = recording ? 2 : 1
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let (text, color) = displayText
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: value == .none && !recording ? .regular : .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let height = ceil(string.size().height)
        let textRect = NSRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width - 12, height: height)
        string.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func refreshAccessibility() {
        setAccessibilityValue(isRecording ? "단축키를 누르세요" : displayText.text)
        needsDisplay = true
    }
}
