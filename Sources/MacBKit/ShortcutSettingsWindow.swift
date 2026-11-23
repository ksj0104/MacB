import AppKit
import UniformTypeIdentifiers

/// 설정 창의 한영 전환 상태 줄.
public struct InputSwitchStatus: Equatable, Sendable {
    public enum Kind: Sendable {
        case active
        case off
        case working
        case error
    }

    public var text: String
    public var kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    /// `InputSwitchManager.apply`의 결과로 만든다.
    public init(_ result: InputSwitchResult) {
        let kind: Kind
        switch result {
        case .applied, .remapped, .alreadyApplied: kind = .active
        case .untouched, .restored: kind = .off
        case .failed: kind = .error
        }
        self.init(text: result.statusText, kind: kind)
    }

    public static let working = InputSwitchStatus(text: "적용하는 중…", kind: .working)
}

/// '단축키 설정' 창. 내용은 `ShortcutSettings`를 그대로 그린 것이고, 바뀐 설정은 `onChange` 하나로 알린다.
/// 반영과 저장은 앱이 한다.
@MainActor
public final class ShortcutSettingsWindowController: NSObject, NSWindowDelegate {
    /// 편집 하나가 받아들여질 때마다 새 설정으로 불린다.
    public var onChange: (@MainActor (AppConfig) -> Void)? {
        get { pane.onChange }
        set { pane.onChange = newValue }
    }

    /// 단축키 칸이 기록을 시작하면 true, 끝나면 false. 기록하는 동안 MacB의 전역 단축키를 꺼 두어야 키가 칸까지 온다.
    public var onRecordingChange: (@MainActor (Bool) -> Void)? {
        get { pane.onRecordingChange }
        set { pane.onRecordingChange = newValue }
    }

    private let pane: ShortcutSettingsPane
    private var window: NSWindow?

    /// - Parameters:
    ///   - tools: 내장 기능 목록(이름·아이콘). 이 순서대로 줄을 만든다.
    ///   - locateApp: 설정에 적힌 앱(이름, 번들 ID, 경로)의 위치. 아이콘과 이름을 보여 주는 데 쓴다.
    public init(config: AppConfig, tools: [ShortcutSettings.Tool], locateApp: @escaping @MainActor (String) -> URL?) {
        pane = ShortcutSettingsPane(settings: ShortcutSettings(config: config, tools: tools), locateApp: locateApp)
        super.init()
        pane.onAddApp = { [weak self] in self?.chooseApp() }
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// 창을 앞으로 가져온다. 메뉴 막대 앱이라 MacB를 활성화해야 키 입력을 받는다.
    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 활성화는 시스템이 거절할 수 있다(macOS 14부터. MacB가 활성 앱이 아니거나 백그라운드로 막 뜬 경우).
        // 거절되면 위 줄만으로는 창이 지금 쓰던 앱의 창 뒤에 깔리므로, 활성화와 상관없이 맨 앞으로 올린다.
        window.orderFrontRegardless()
    }

    public func close() {
        window?.close()
    }

    /// 설정이 밖에서 바뀌었을 때(파일을 직접 고쳐 다시 읽은 경우 등). 창이 보낸 것과 같은 설정이면 그대로 둔다.
    public func update(config: AppConfig) {
        guard config != pane.settings.config else { return }
        pane.settings = ShortcutSettings(config: config, tools: pane.settings.tools)
        pane.reload()
    }

    /// 한영 전환을 적용한 결과를 상태 줄에 보여 준다.
    public func showInputSwitchStatus(_ status: InputSwitchStatus) {
        pane.status = status
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: ShortcutSettingsPane.width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "단축키 설정"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        let document = pane.documentView
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
        ])
        window.contentView = scrollView

        // 내용이 다 보이게 하되 화면보다 길면 스크롤한다.
        document.layoutSubtreeIfNeeded()
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        let height = min(document.fittingSize.height, max(visible - 120, 360))
        window.setContentSize(NSSize(width: ShortcutSettingsPane.width, height: height))
        window.center()
        return window
    }

    public func windowDidResignKey(_ notification: Notification) {
        // 다른 앱으로 넘어가면 기록을 멈춰야 전역 단축키가 다시 켜진다.
        pane.cancelRecording()
    }

    public func windowWillClose(_ notification: Notification) {
        pane.cancelRecording()
    }

    private func chooseApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "추가"
        panel.message = "단축키로 열 앱을 고르세요"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.pane.addApp(at: url)
            }
        }
    }
}

// MARK: - Snapshot

public extension ShortcutSettingsWindowController {
    /// 화면에 띄우지 않고 창 내용을 그린다(개발용). `prepare`로 오류 안내나 기록 중 모습을 미리 넣을 수 있다.
    static func renderSnapshot(
        config: AppConfig,
        tools: [ShortcutSettings.Tool],
        status: InputSwitchStatus,
        appearance: NSAppearance,
        locateApp: @escaping @MainActor (String) -> URL?,
        message: (field: ShortcutSettings.Field, text: String)? = nil,
        recordingField: ShortcutSettings.Field? = nil
    ) -> NSBitmapImageRep? {
        // 창 객체를 만들려면 AppKit이 초기화돼 있어야 한다. 실행(run)은 하지 않으므로 화면에는 아무것도 뜨지 않는다.
        if NSApp == nil {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
        }
        let pane = ShortcutSettingsPane(settings: ShortcutSettings(config: config, tools: tools), locateApp: locateApp)
        pane.status = status
        if let message { pane.showMessage(message.text, for: message.field) }
        if let recordingField { pane.previewRecording(recordingField) }

        let view = pane.documentView
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: ShortcutSettingsPane.width, height: ceil(view.fittingSize.height))
        // 화면에 올리지 않는(orderFront 하지 않는) 창. 컨트롤이 제 모양으로 그려지려면 창 안에 있어야 한다.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        var result: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            container.layoutSubtreeIfNeeded()
            container.displayIfNeeded()
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return }
            rep.size = size
            container.cacheDisplay(in: container.bounds, to: rep)
            result = rep
        }
        window.contentView = nil
        return result
    }

    /// 예시 설정으로 밝은·어두운 화면을 그려 PNG로 남긴다. 쓴 파일 목록을 돌려준다.
    static func writeDebugSnapshots(
        to directory: URL,
        tools: [ShortcutSettings.Tool],
        locateApp: @escaping @MainActor (String) -> URL?
    ) throws -> [URL] {
        struct RenderFailed: Error, CustomStringConvertible {
            let description: String
        }
        let ocr = BuiltInAction.recognizeText.rawValue
        let sample = AppConfig(
            keyboard: .init(inputSwitch: .init(enabled: true, key: "right_command")),
            shortcuts: [
                .init(key: "control+shift+4", item: .init(action: BuiltInAction.areaToClipboard.rawValue)),
                .init(key: "control+option+o", item: .init(action: ocr)),
                .init(key: "control+option+c", item: .init(action: BuiltInAction.pickColor.rawValue)),
                .init(key: "control+option+t", item: .init(title: "터미널", app: "com.apple.Terminal")),
                .init(key: "", item: .init(title: "Safari", app: "com.apple.Safari")),
                .init(key: "control+option+n", item: .init(title: "메모", icon: "note.text", shell: "open -a Notes")),
                .init(key: "control+option+g", item: .init(title: "GitHub", url: "https://github.com")),
            ]
        )
        var custom = sample
        custom.keyboard.inputSwitch.key = "shift+space"

        let applied = InputSwitchStatus(InputSwitchResult.applied(.rightCommand))
        let failed = InputSwitchStatus(InputSwitchResult.failed(
            turningOn: true,
            reason: "입력 소스 단축키를 바꾸지 못했습니다: 환경설정(com.apple.symbolichotkeys)을 저장하지 못했습니다"
        ))
        let refusal = ShortcutSettings.Refusal.inUse("원형 메뉴").message

        let shots: [(name: String, appearance: NSAppearance.Name, config: AppConfig, status: InputSwitchStatus, error: Bool)] = [
            ("shortcut-settings", .aqua, sample, applied, false),
            ("shortcut-settings-dark", .darkAqua, sample, applied, false),
            ("shortcut-settings-custom", .aqua, custom, failed, true),
            ("shortcut-settings-custom-dark", .darkAqua, custom, failed, true),
        ]
        var written: [URL] = []
        for shot in shots {
            guard let appearance = NSAppearance(named: shot.appearance),
                  let rep = renderSnapshot(
                      config: shot.config, tools: tools, status: shot.status, appearance: appearance, locateApp: locateApp,
                      message: shot.error ? (.tool(BuiltInAction.windowToClipboard.rawValue), refusal) : nil,
                      recordingField: shot.error ? .tool(BuiltInAction.recordScreen.rawValue) : nil
                  ),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw RenderFailed(description: "\(shot.name) 그리기 실패")
            }
            let url = directory.appendingPathComponent(shot.name + ".png")
            try png.write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }
}

// MARK: - Content

/// 창의 내용. 창 없이도 그릴 수 있어 화면 밖 스냅샷도 이것을 쓴다.
@MainActor
final class ShortcutSettingsPane {
    typealias Field = ShortcutSettings.Field

    static let width: CGFloat = 540
    private static let margin: CGFloat = 20
    private static var groupWidth: CGFloat { width - margin * 2 }

    var settings: ShortcutSettings
    var status: InputSwitchStatus {
        didSet { updateStatusRow() }
    }
    var onChange: (@MainActor (AppConfig) -> Void)?
    var onRecordingChange: (@MainActor (Bool) -> Void)?
    var onAddApp: (@MainActor () -> Void)?

    let documentView = FlippedBackgroundView()
    private let locateApp: @MainActor (String) -> URL?
    private var messages: [Field: String] = [:]
    private var recorders: [Field: ShortcutRecorderView] = [:]
    private weak var activeRecorder: ShortcutRecorderView?
    /// '직접 지정'을 골랐지만 아직 키를 누르지 않았다.
    private var pendingCustomKey = false
    private var targets: [ClosureTarget] = []
    /// 칸 아래의 안내 줄.
    private var notes: [NSView] = []
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: ShortcutSettings, locateApp: @escaping @MainActor (String) -> URL?) {
        self.settings = settings
        self.locateApp = locateApp
        status = settings.inputSwitchEnabled
            ? InputSwitchStatus(text: "켜져 있습니다", kind: .active)
            : InputSwitchStatus(text: "꺼져 있습니다", kind: .off)
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.preferredMaxLayoutWidth = Self.groupWidth - 60
        statusLabel.isSelectable = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDot.imageScaling = .scaleProportionallyDown
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 20),
            statusDot.heightAnchor.constraint(equalToConstant: 12),
        ])
        updateStatusRow()
        reload()
    }

    // MARK: Actions

    func cancelRecording() {
        activeRecorder?.stopRecording()
    }

    func showMessage(_ text: String, for field: Field) {
        messages = [field: text]
        reload()
    }

    func previewRecording(_ field: Field) {
        recorders[field]?.drawsAsRecording = true
    }

    func addApp(at url: URL) {
        let reference = Bundle(url: url)?.bundleIdentifier ?? url.path
        // 이미 있는 앱이면 그 줄의 칸을 바로 연다.
        if let existing = settings.appRows.first(where: { $0.app == reference }) {
            recorders[existing.field]?.startRecording()
            return
        }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        guard perform(.addApp(reference: reference, title: name), messageField: nil),
              let added = settings.appRows.last else { return }
        recorders[added.field]?.startRecording()
    }

    /// 편집을 적용한다. 받아들여지면 다시 그리고 `onChange`로 알린다. 거부되면 그 칸 아래에 이유를 보여 준다.
    @discardableResult
    private func perform(_ edit: ShortcutSettings.Edit, messageField: Field?) -> Bool {
        switch settings.applying(edit) {
        case .success(let config):
            messages.removeAll()
            let previous = settings.config
            settings = ShortcutSettings(config: config, tools: settings.tools)
            if config.keyboard.inputSwitch != previous.keyboard.inputSwitch {
                status = .working
            }
            reload()
            if config != previous { onChange?(config) }
            return true
        case .failure(let refusal):
            messages = messageField.map { [$0: refusal.message] } ?? [:]
            reload()
            return false
        }
    }

    private func handle(_ event: ShortcutRecorderView.Event, for row: ShortcutSettings.Row) {
        switch event {
        case .clear:
            switch row.recording {
            case .modifiers: perform(.setModifiers(row.field, nil), messageField: row.field)
            case .combo: perform(.setCombo(row.field, nil), messageField: row.field)
            }
        case .modifiers(let modifiers):
            perform(.setModifiers(row.field, modifiers), messageField: row.field)
        case .combo(let combo):
            perform(.setCombo(row.field, combo), messageField: row.field)
        }
    }

    private func handleInputSwitchEvent(_ event: ShortcutRecorderView.Event) {
        switch event {
        case .combo(let combo):
            if perform(.setInputSwitchKey(.combo(combo)), messageField: .inputSwitch) { pendingCustomKey = false }
        case .clear, .modifiers:
            // 한영 전환 키는 비워 둘 수 없다. 지우기는 취소로 본다.
            cancelPendingCustomKey()
        }
    }

    private func cancelPendingCustomKey() {
        guard pendingCustomKey else { return }
        pendingCustomKey = false
        reload()
    }

    private func choosePopupItem(tag: Int) {
        switch tag {
        case 0:
            pendingCustomKey = false
            perform(.setInputSwitchKey(.rightCommand), messageField: .inputSwitch)
        case 1:
            pendingCustomKey = false
            perform(.setInputSwitchKey(.rightOption), messageField: .inputSwitch)
        default:
            if case .combo = settings.inputSwitchKey {
                recorders[.inputSwitch]?.startRecording()
                return
            }
            pendingCustomKey = true
            messages.removeAll()
            reload()
            recorders[.inputSwitch]?.startRecording()
        }
    }

    // MARK: Building

    func reload() {
        cancelRecording()
        documentView.subviews.forEach { $0.removeFromSuperview() }
        recorders.removeAll()
        targets.removeAll()
        notes.removeAll()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: Self.margin, bottom: 20, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        // 1. 한영 전환 키
        stack.addArrangedSubview(sectionHeader("한영 전환 키"))
        stack.addArrangedSubview(group(inputSwitchRows()))
        stack.addArrangedSubview(caption(consequenceText()))
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }

        // 2. 기본 단축키
        stack.addArrangedSubview(sectionHeader("기본 단축키"))
        stack.addArrangedSubview(group(settings.basicRows.map { recorderRow($0) }))
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(22, after: last) }

        // 3. 기능 바로 실행
        stack.addArrangedSubview(sectionHeader("기능 바로 실행"))
        stack.addArrangedSubview(group(settings.toolRows.map { recorderRow($0) }))
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }

        stack.addArrangedSubview(subsectionHeader("앱 열기"))
        var appRows = settings.appRows.map { recorderRow($0) }
        appRows.append(addAppRow())
        stack.addArrangedSubview(group(appRows))

        let others = settings.otherRows
        if !others.isEmpty {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }
            stack.addArrangedSubview(subsectionHeader("그 밖의 항목"))
            stack.addArrangedSubview(group(others.map { recorderRow($0) }))
            stack.addArrangedSubview(caption("단축키만 여기서 바꿀 수 있습니다. 실행할 내용은 config.json의 shortcuts에서 고칩니다."))
        }

        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
        stack.addArrangedSubview(caption("칸을 누르고 키를 누르면 바로 저장됩니다 · ⌫ 지우기 · esc 취소"))
    }

    private func inputSwitchRows() -> [NSView] {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = settings.inputSwitchEnabled ? .on : .off
        bind(toggle) { [weak self, weak toggle] in
            guard let self, let toggle else { return }
            self.perform(.setInputSwitchEnabled(toggle.state == .on), messageField: .inputSwitch)
        }
        toggle.setAccessibilityLabel("한영 전환 키 사용")
        let switchRow = row(icon: symbol("globe"), title: "한영 전환 키 사용", detail: nil, accessories: [toggle])

        let key = settings.inputSwitchKey
        let isCustom: Bool
        if case .combo = key { isCustom = true } else { isCustom = pendingCustomKey }

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .regular
        popup.addItem(withTitle: InputSwitchKey.rightCommand.displayName)
        popup.lastItem?.tag = 0
        popup.addItem(withTitle: InputSwitchKey.rightOption.displayName)
        popup.lastItem?.tag = 1
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "직접 지정…")
        popup.lastItem?.tag = 2
        if isCustom {
            popup.selectItem(withTag: 2)
        } else {
            popup.selectItem(withTag: key == .rightOption ? 1 : 0)
        }
        bind(popup) { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.choosePopupItem(tag: popup.selectedTag())
        }
        popup.setAccessibilityLabel("전환 키")

        var accessories: [NSView] = []
        if isCustom {
            let recorder = makeRecorder(field: .inputSwitch, recording: .combo, value: {
                if case .combo(let combo) = key { return .combo(combo) }
                return .none
            }())
            recorder.onEvent = { [weak self] event in self?.handleInputSwitchEvent(event) }
            recorder.setAccessibilityLabel("한영 전환 단축키")
            accessories.append(recorder)
        }
        accessories.append(popup)
        var keyDetail: String?
        if key == nil {
            keyDetail = "config.json의 값을 해석할 수 없습니다: \(settings.config.keyboard.inputSwitch.key)"
        }
        let keyRow = row(
            icon: symbol("keyboard"), title: "전환 키", detail: keyDetail, detailColor: .systemRed,
            accessories: accessories, message: messages[.inputSwitch]
        )

        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        statusRow.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 10, right: 12)
        return [switchRow, keyRow, statusRow]
    }

    private func updateStatusRow() {
        statusLabel.stringValue = status.text
        let tint: NSColor
        switch status.kind {
        case .active: tint = .systemGreen
        case .off: tint = .tertiaryLabelColor
        case .working: tint = .systemOrange
        case .error: tint = .systemRed
        }
        statusLabel.textColor = status.kind == .error ? .systemRed : .secondaryLabelColor
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        statusDot.contentTintColor = tint
    }

    private func consequenceText() -> String {
        let consequence = "시스템의 '이전 입력 소스 선택' 단축키를 바꾸며, 끄면 원래대로 되돌립니다."
        switch settings.inputSwitchKey {
        case .rightCommand:
            return "오른쪽 Command 키는 더 이상 ⌘로 쓰이지 않습니다. " + consequence
        case .rightOption:
            return "오른쪽 Option 키는 더 이상 ⌥로 쓰이지 않습니다. " + consequence
        case .combo, nil:
            return "키는 그대로 두고 " + consequence
        }
    }

    private func recorderRow(_ model: ShortcutSettings.Row) -> NSView {
        let recorder = makeRecorder(field: model.field, recording: model.recording, value: model.value)
        recorder.onEvent = { [weak self] event in self?.handle(event, for: model) }
        recorder.setAccessibilityLabel(model.title)

        var icon = model.symbol.flatMap(symbol)
        var title = model.title
        var detail = model.detail
        var detailColor = NSColor.secondaryLabelColor
        if let app = model.app {
            if let url = locateApp(app) {
                icon = icon ?? Self.appIcon(at: url)
                if title == app { title = Self.displayName(of: url) }
            } else {
                icon = icon ?? symbol("app.dashed")
                detail = "앱을 찾지 못했습니다: \(app)"
                detailColor = .systemRed
            }
        }

        var accessories: [NSView] = [recorder]
        if model.isRemovable {
            let remove = NSButton(image: symbol("minus.circle") ?? NSImage(), target: nil, action: nil)
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "이 줄 지우기"
            remove.setAccessibilityLabel("\(title) 지우기")
            bind(remove) { [weak self] in self?.perform(.remove(model.field), messageField: nil) }
            accessories.append(remove)
        }
        return row(icon: icon, title: title, detail: detail, detailColor: detailColor, accessories: accessories, message: messages[model.field])
    }

    private func addAppRow() -> NSView {
        let button = NSButton(title: "앱 추가…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        bind(button) { [weak self] in self?.onAddApp?() }
        let hint = settings.appRows.isEmpty ? "앱을 추가하고 단축키를 정하면 그 키로 바로 열립니다" : nil
        return row(icon: nil, title: "", detail: nil, leading: [button], accessories: [], trailingText: hint)
    }

    private func makeRecorder(field: Field, recording: ShortcutSettings.Recording, value: ShortcutSettings.Value) -> ShortcutRecorderView {
        let recorder = ShortcutRecorderView(frame: NSRect(origin: .zero, size: ShortcutRecorderView.size))
        recorder.recording = recording
        recorder.value = value
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.setContentHuggingPriority(.required, for: .horizontal)
        recorder.onRecordingChange = { [weak self, weak recorder] recording in
            guard let self else { return }
            self.activeRecorder = recording ? recorder : nil
            if recording { self.hideMessages() }
            self.onRecordingChange?(recording)
            if !recording, field == .inputSwitch {
                // 키를 누르지 않고 끝났으면(esc, 다른 곳 클릭) '직접 지정' 고르기를 취소한다.
                // 누른 키는 이 알림 바로 뒤에 오므로 한 바퀴 뒤에 본다.
                // 거부된 경우에는 안내를 보이며 칸을 남겨 둔다.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.messages[.inputSwitch] == nil else { return }
                        if case .combo = self.settings.inputSwitchKey { return }
                        self.cancelPendingCustomKey()
                    }
                }
            }
        }
        recorders[field] = recorder
        return recorder
    }

    /// 다시 기록을 시작하면 지난 안내는 감춘다. 다시 그리면 기록 중인 칸이 사라지므로 숨기기만 한다.
    private func hideMessages() {
        messages.removeAll()
        notes.forEach { $0.isHidden = true }
    }

    // MARK: Pieces

    private func row(
        icon: NSImage?, title: String, detail: String?, detailColor: NSColor = .secondaryLabelColor,
        leading: [NSView] = [], accessories: [NSView], trailingText: String? = nil, message: String? = nil
    ) -> NSView {
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)

        if let icon {
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = .secondaryLabelColor
            view.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 20),
                view.heightAnchor.constraint(equalToConstant: 20),
            ])
            line.addArrangedSubview(view)
        }
        leading.forEach { line.addArrangedSubview($0) }

        let texts = NSStackView()
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        if !title.isEmpty {
            texts.addArrangedSubview(label(title, font: .systemFont(ofSize: 13), color: .labelColor))
        }
        if let detail, !detail.isEmpty {
            let detailLabel = label(detail, font: .systemFont(ofSize: 11), color: detailColor)
            detailLabel.lineBreakMode = .byTruncatingMiddle
            texts.addArrangedSubview(detailLabel)
        }
        if let trailingText {
            texts.addArrangedSubview(label(trailingText, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        }
        // 글자 무리가 남는 폭을 모두 가져가야 칸이 오른쪽 끝에 붙는다.
        texts.setHuggingPriority(.init(1), for: .horizontal)
        texts.setClippingResistancePriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(texts)
        accessories.forEach {
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            line.addArrangedSubview($0)
        }
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true

        guard let message else { return line }
        let note = label(message, font: .systemFont(ofSize: 11), color: .systemRed)
        let noteRow = NSStackView(views: [note])
        noteRow.edgeInsets = NSEdgeInsets(top: 0, left: icon == nil ? 12 : 42, bottom: 8, right: 12)
        let container = NSStackView(views: [line, noteRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        line.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        notes.append(noteRow)
        return container
    }

    private func group(_ rows: [NSView]) -> NSView {
        let box = SettingsGroupView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = SeparatorLine()
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            box.widthAnchor.constraint(equalToConstant: Self.groupWidth),
        ])
        return box
    }

    private func sectionHeader(_ text: String) -> NSView {
        let field = label(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        return indented(field, left: 2)
    }

    private func subsectionHeader(_ text: String) -> NSView {
        let field = label(text, font: .systemFont(ofSize: 12, weight: .medium), color: .secondaryLabelColor)
        return indented(field, left: 2)
    }

    private func caption(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = Self.groupWidth - 8
        field.isSelectable = false
        return indented(field, left: 4)
    }

    private func indented(_ view: NSView, left: CGFloat) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: left, bottom: 0, right: 0)
        return wrapper
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        control.target = target
        control.action = #selector(ClosureTarget.fire)
        targets.append(target)
    }

    /// 앱 아이콘을 지금 그려 둔다. 시스템 아이콘은 늦게 채워져서 처음 그릴 때 빈칸으로 나올 수 있다.
    private static func appIcon(at url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 20, height: 20)
        var rect = NSRect(x: 0, y: 0, width: 40, height: 40)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            icon.size = size
            return icon
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: - Views

/// 메뉴 막대 앱이라 편집 메뉴가 없어서 ⌘W를 창이 직접 받는다. 단축키 칸이 기록 중이면 칸이 먼저 가져간다.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return false
    }
}

/// 위에서부터 쌓이는 문서 뷰. 창 바탕색을 직접 칠해 화면 밖 스냅샷에서도 같은 바탕이 나온다.
final class FlippedBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// 시스템 설정처럼 둥근 모서리로 묶은 줄 무리.
final class SettingsGroupView: NSView {
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055)
            : NSColor(white: 1, alpha: 0.75)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Self.fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// 줄 사이의 가는 선. 시스템 설정처럼 왼쪽은 조금 띄운다.
final class SeparatorLine: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 12, y: 0, width: max(bounds.width - 12, 0), height: 1).fill()
    }
}

/// 클로저로 동작하는 컨트롤 대상.
@MainActor
final class ClosureTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() {
        // 동작이 창 내용을 다시 그리면 이 대상도 버려진다. 끝날 때까지 붙들어 둔다.
        withExtendedLifetime(self) { action() }
    }
}
