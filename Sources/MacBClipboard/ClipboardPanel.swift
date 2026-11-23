import AppKit
import Carbon.HIToolbox
import MacBKit
import UniformTypeIdentifiers

// MARK: - Window

/// 키 입력은 받지만 MacB를 활성화하지 않는 패널.
/// 원래 앞에 있던 앱이 계속 활성 상태로 남아야 패널을 닫은 뒤 보내는 ⌘V가 그 앱에 닿는다.
final class ClipboardPanel: NSPanel {
    /// 처리했으면 true. 검색 칸(필드 편집기)보다 먼저 키를 본다.
    var keyHandler: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, keyHandler?(event) == true { return true }
        if performEditShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// 슬롯 탭처럼 글자 칸이 없으면 창 자신이 키를 받는다. 처리하지 않은 일반 키가 위로 올라가면
    /// 시스템 경고음이 나므로 여기서 조용히 삼킨다. ⌘·⌃ 조합은 원래대로 넘긴다.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty { return }
        super.keyDown(with: event)
    }

    /// 메뉴 막대 앱이라 편집 메뉴가 없을 수 있어 ⌘A/⌘C/⌘V/⌘X/⌘Z를 검색 칸에 직접 넘긴다.
    /// 한글 입력 상태에서는 글자가 'ㅁ'처럼 들어오므로 키 코드로 본다.
    private func performEditShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command || flags == [.command, .shift], let editor = firstResponder as? NSTextView else {
            return false
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_A where flags == .command: editor.selectAll(nil)
        case kVK_ANSI_C where flags == .command: editor.copy(nil)
        case kVK_ANSI_V where flags == .command: editor.paste(nil)
        case kVK_ANSI_X where flags == .command: editor.cut(nil)
        case kVK_ANSI_Z:
            if flags.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
        default:
            return false
        }
        return true
    }
}

// MARK: - Controller

/// 기록/슬롯 패널. 데이터는 `update`로 받고, 사용자의 선택은 `actions`로 돌려준다.
/// 화면 밖 스냅샷도 같은 뷰 트리를 쓴다.
@MainActor
final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    typealias Item = ClipboardFeature.Item
    typealias Tab = ClipboardFeature.PanelTab

    struct Actions {
        var pasteHistory: @MainActor (UUID) -> Void = { _ in }
        var pasteSlot: @MainActor (Int) -> Void = { _ in }
        var deleteHistory: @MainActor (UUID) -> Void = { _ in }
        var clearSlot: @MainActor (Int) -> Void = { _ in }
    }

    var actions = Actions()
    var hints = ClipboardFeature.HotkeyHints() {
        didSet { updateChrome() }
    }

    private(set) var tab: Tab = .history

    let contentView: NSView
    /// 테두리 없는 진짜 글자 칸. 첫 응답자로 두어야 한글 조합이 그대로 동작한다.
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let slotsHeader = NSTextField(labelWithString: "")
    private let tabControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")
    private var panel: ClipboardPanel?
    private var isHiding = false

    private var history: [Item] = []
    private var filtered: [Item] = []
    private var slots: [Item?] = Array(repeating: nil, count: ClipboardFeature.slotRange.count)
    private var recordingEnabled = true
    private var thumbnails: [UUID: NSImage] = [:]
    private var fileIcons: [String: NSImage] = [:]

    init(opaqueBackground: Bool) {
        contentView = NSView(frame: NSRect(origin: .zero, size: PanelMetrics.size))
        super.init()
        buildViews(opaqueBackground: opaqueBackground)
        applyTab()
    }

    // MARK: Public

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 기록 탭에서 선택된 항목.
    var selectedHistoryID: UUID? {
        guard tab == .history else { return nil }
        let row = tableView.selectedRow
        return filtered.indices.contains(row) ? filtered[row].id : nil
    }

    func update(history: [Item], slots: [Item?], recordingEnabled: Bool) {
        let previousID = selectedItemID
        let previousRow = tableView.selectedRow
        self.history = history
        self.slots = slots
        self.recordingEnabled = recordingEnabled
        let ids = Set(history.map(\.id) + slots.compactMap { $0?.id })
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        reload(selecting: previousID, fallbackRow: previousRow)
    }

    func show(tab newTab: Tab) {
        let panel = self.panel ?? makePanel()
        searchField.stringValue = ""
        tab = newTab
        applyTab()
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        focusForTab()
    }

    func switchTo(_ newTab: Tab) {
        guard newTab != tab else { return }
        tab = newTab
        applyTab()
        focusForTab()
    }

    func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        panel.orderOut(nil)
        isHiding = false
    }

    /// 스냅샷용: 화면에 띄우지 않고 내용만 채운다.
    func prepareSnapshot(history: [Item], slots: [Item?], tab: Tab, selectedRow: Int) {
        self.history = history
        self.slots = slots
        self.tab = tab
        applyTab()
        select(row: selectedRow)
    }

    // MARK: Building

    private func buildViews(opaqueBackground: Bool) {
        let root = contentView
        root.autoresizingMask = [.width, .height]

        let background = PanelBackgroundView(opaqueFill: opaqueBackground, radius: PanelMetrics.cornerRadius)
        let topLine = HairlineView()
        let bottomLine = HairlineView()
        let border = PanelBorderView(radius: PanelMetrics.cornerRadius)

        searchField.placeholderString = "클립보드 검색"
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.delegate = self

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.setContentHuggingPriority(.required, for: .horizontal)

        slotsHeader.font = .systemFont(ofSize: 13, weight: .medium)
        slotsHeader.textColor = .secondaryLabelColor
        slotsHeader.lineBreakMode = .byTruncatingTail
        slotsHeader.stringValue = "숫자 키로 붙여넣기 · ⌫ 비우기"

        tabControl.segmentCount = 2
        tabControl.setLabel("기록", forSegment: 0)
        tabControl.setLabel("슬롯", forSegment: 1)
        tabControl.setWidth(54, forSegment: 0)
        tabControl.setWidth(54, forSegment: 1)
        tabControl.trackingMode = .selectOne
        tabControl.selectedSegment = 0
        tabControl.refusesFirstResponder = true
        tabControl.target = self
        tabControl.action = #selector(tabClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        column.width = PanelMetrics.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = PanelMetrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.allowsTypeSelect = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        // 검색 칸이 계속 키 입력을 받도록 표는 포커스를 가져가지 않는다.
        tableView.refusesFirstResponder = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: PanelMetrics.listPadding, left: 0, bottom: PanelMetrics.listPadding, right: 0
        )

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2

        for label in [footerLeft, footerRight] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        footerLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerRight.setContentCompressionResistancePriority(.required, for: .horizontal)

        let views: [NSView] = [
            background, searchIcon, searchField, slotsHeader, tabControl, topLine, scrollView, emptyLabel,
            bottomLine, footerLeft, footerRight, border,
        ]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        let header = PanelMetrics.headerHeight
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            border.topAnchor.constraint(equalTo: root.topAnchor),
            border.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            border.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            tabControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabControl.centerYAnchor.constraint(equalTo: root.topAnchor, constant: header / 2),
            searchIcon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PanelMetrics.rowInset),
            searchIcon.centerYAnchor.constraint(equalTo: tabControl.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: tabControl.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: tabControl.centerYAnchor),
            slotsHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PanelMetrics.rowInset),
            slotsHeader.trailingAnchor.constraint(lessThanOrEqualTo: tabControl.leadingAnchor, constant: -10),
            slotsHeader.centerYAnchor.constraint(equalTo: tabControl.centerYAnchor),

            topLine.topAnchor.constraint(equalTo: root.topAnchor, constant: header),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomLine.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -48),

            bottomLine.heightAnchor.constraint(equalToConstant: 1),
            bottomLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -PanelMetrics.footerHeight),

            footerLeft.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: PanelMetrics.rowInset),
            footerLeft.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -PanelMetrics.footerHeight / 2),
            footerRight.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -PanelMetrics.rowInset),
            footerRight.centerYAnchor.constraint(equalTo: footerLeft.centerYAnchor),
            footerLeft.trailingAnchor.constraint(lessThanOrEqualTo: footerRight.leadingAnchor, constant: -12),
        ])
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        // 빠르게 뜨고 사라지도록 창 애니메이션을 끈다.
        panel.animationBehavior = .none
        panel.contentView = contentView
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in self?.hide() }
        self.panel = panel
        return panel
    }

    /// 마우스가 있는 화면 가운데, 조금 위쪽.
    private func position(_ panel: NSPanel) {
        let size = PanelMetrics.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let spare = max(0, visible.height - size.height)
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + spare * 0.62).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func focusForTab() {
        guard let panel else { return }
        if tab == .history {
            panel.makeFirstResponder(searchField)
        } else {
            // 슬롯 탭에서는 숫자가 검색 칸에 들어가지 않게 창 자체가 키를 받는다.
            panel.makeFirstResponder(nil)
        }
    }

    // MARK: State

    private var selectedItemID: UUID? {
        let row = tableView.selectedRow
        switch tab {
        case .history: return filtered.indices.contains(row) ? filtered[row].id : nil
        case .slots: return slots.indices.contains(row) ? slots[row]?.id : nil
        }
    }

    private var rowCount: Int {
        tab == .history ? filtered.count : slots.count
    }

    private func applyTab() {
        tabControl.selectedSegment = tab == .history ? 0 : 1
        searchField.isHidden = tab != .history
        searchIcon.isHidden = tab != .history
        slotsHeader.isHidden = tab != .slots
        reload(selecting: nil, fallbackRow: 0)
    }

    private func reload(selecting id: UUID?, fallbackRow: Int) {
        filtered = tab == .history ? filteredHistory() : []
        tableView.reloadData()
        var row = fallbackRow
        if let id {
            switch tab {
            case .history: row = filtered.firstIndex { $0.id == id } ?? fallbackRow
            case .slots: row = slots.firstIndex { $0?.id == id } ?? fallbackRow
            }
        }
        select(row: row)
        updateChrome()
    }

    private func select(row: Int) {
        let count = rowCount
        guard count > 0 else {
            tableView.deselectAll(nil)
            return
        }
        let clamped = min(max(row, 0), count - 1)
        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        // 처음 열 때는 아직 배치 전이라 보이는 높이가 0이다. 그 상태로 스크롤하면 위쪽 행이 가려진다.
        contentView.layoutSubtreeIfNeeded()
        tableView.scrollRowToVisible(clamped)
    }

    /// 한글 조합 중인 글자도 검색에 넣되, 그 때문에 결과가 비면 확정된 글자까지만 쓴다.
    /// ('바나ㄴ'에서 잠깐 목록이 비었다가 '바나나'에서 다시 차는 깜박임을 막는다.)
    private func filteredHistory() -> [Item] {
        let (full, committed) = searchTexts()
        let result = Item.filter(history, query: full)
        if result.isEmpty, committed != full {
            return Item.filter(history, query: committed)
        }
        return result
    }

    private func searchTexts() -> (full: String, committed: String) {
        guard let editor = searchField.currentEditor() as? NSTextView else {
            return (searchField.stringValue, searchField.stringValue)
        }
        let full = editor.string
        let marked = editor.markedRange()
        guard marked.location != NSNotFound, marked.length > 0, let range = Range(marked, in: full) else {
            return (full, full)
        }
        var committed = full
        committed.removeSubrange(range)
        return (full, committed)
    }

    private var isSearchEmpty: Bool {
        searchTexts().full.isEmpty
    }

    private func updateChrome() {
        var parts: [String] = []
        if !hints.slotCopyModifiers.isEmpty { parts.append("\(hints.slotCopyModifiers)+숫자 슬롯에 복사") }
        if !hints.slotPasteModifiers.isEmpty { parts.append("\(hints.slotPasteModifiers)+숫자 슬롯 붙여넣기") }
        if parts.isEmpty {
            parts = tab == .history ? ["↩ 붙여넣기", "⌫ 삭제"] : ["↩ 붙여넣기", "⌫ 비우기"]
        }
        footerLeft.stringValue = parts.joined(separator: " · ")
        footerRight.stringValue = tab == .history ? "⇥ 슬롯" : "⇥ 기록"

        let showEmpty = tab == .history && filtered.isEmpty
        emptyLabel.isHidden = !showEmpty
        if showEmpty {
            if history.isEmpty {
                emptyLabel.stringValue = recordingEnabled
                    ? "아직 기록이 없습니다\n복사한 내용이 여기에 쌓입니다"
                    : "클립보드 기록이 꺼져 있습니다"
            } else {
                emptyLabel.stringValue = "검색 결과가 없습니다"
            }
        }
    }

    // MARK: Actions

    func controlTextDidChange(_ obj: Notification) {
        reload(selecting: nil, fallbackRow: 0)
    }

    @objc private func tabClicked(_ sender: NSSegmentedControl) {
        switchTo(sender.selectedSegment == 0 ? .history : .slots)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        activate(row: row)
    }

    private func activate(row: Int) {
        switch tab {
        case .history:
            guard filtered.indices.contains(row) else { return }
            actions.pasteHistory(filtered[row].id)
        case .slots:
            guard slots.indices.contains(row) else { return }
            actions.pasteSlot(row + 1)
        }
    }

    private func deleteSelected() {
        let row = tableView.selectedRow
        switch tab {
        case .history:
            guard filtered.indices.contains(row) else { return }
            actions.deleteHistory(filtered[row].id)
        case .slots:
            guard slots.indices.contains(row), slots[row] != nil else { return }
            actions.clearSlot(row + 1)
        }
    }

    private func moveSelection(by delta: Int) {
        guard rowCount > 0 else { return }
        let current = tableView.selectedRow
        select(row: current < 0 ? 0 : current + delta)
    }

    private static let keypadDigits: [Int: Int] = [
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3,
        kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6,
        kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9,
    ]

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // 한글 조합 중이면 ↩·↑↓·Esc 등은 입력기가 먼저 처리해야 한다.
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let keyCode = Int(event.keyCode)
        // 숫자·⌫ 단독 입력은 검색어를 칠 때는 글자로 쓰고, 검색 칸이 비었거나 슬롯 탭일 때만 명령으로 쓴다.
        let bareKeyIsCommand = flags.isEmpty && (tab == .slots || isSearchEmpty)

        switch keyCode {
        case kVK_Escape:
            hide()
            return true
        case kVK_Tab where flags.isEmpty || flags == .shift:
            switchTo(tab == .history ? .slots : .history)
            return true
        case kVK_UpArrow where flags.isEmpty:
            moveSelection(by: -1)
            return true
        case kVK_DownArrow where flags.isEmpty:
            moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard flags.isEmpty else { return false }
            activate(row: tableView.selectedRow)
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard flags == .command || bareKeyIsCommand else { return false }
            deleteSelected()
            return true
        default:
            break
        }

        let digit = KeyCombo.digit(forKeyCode: UInt32(keyCode)) ?? Self.keypadDigits[keyCode]
        if let digit, ClipboardFeature.slotRange.contains(digit), flags == .command || bareKeyIsCommand {
            activate(row: digit - 1)
            return true
        }
        return false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        PanelMetrics.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ClipboardRowCell.reuseIdentifier, owner: nil) as? ClipboardRowCell
            ?? ClipboardRowCell()
        cell.configure(content(forRow: row))
        return cell
    }

    private func content(forRow row: Int) -> ClipboardRowCell.Content {
        switch tab {
        case .history:
            let item = filtered[row]
            return content(for: item, number: row < ClipboardFeature.slotRange.count ? row + 1 : nil)
        case .slots:
            guard let item = slots[row] else {
                return ClipboardRowCell.Content(number: row + 1, text: "비어 있음", isPlaceholder: true)
            }
            return content(for: item, number: row + 1)
        }
    }

    private func content(for item: Item, number: Int?) -> ClipboardRowCell.Content {
        let (icon, isTemplate) = icon(for: item)
        return ClipboardRowCell.Content(
            number: number,
            icon: icon,
            iconIsTemplate: isTemplate,
            text: item.previewText,
            app: item.sourceApp?.name,
            time: RelativeTime.text(for: item.date)
        )
    }

    private func icon(for item: Item) -> (NSImage?, Bool) {
        switch item.kind {
        case .text:
            return (RowImages.textSymbol, true)
        case .image:
            if let cached = thumbnails[item.id] { return (cached, false) }
            guard let data = item.thumbnailPNG, let image = NSImage(data: data) else {
                return (RowImages.photoSymbol, true)
            }
            let rounded = RowImages.roundedThumbnail(image, side: 26, radius: 5)
            thumbnails[item.id] = rounded
            return (rounded, false)
        case .files:
            // 파일을 직접 읽지 않고 확장자로 아이콘을 고른다.
            // (데스크탑·문서 폴더의 파일을 건드리면 개인정보 보호 권한 창이 뜰 수 있다.)
            let ext = ((item.fileNames.first ?? "") as NSString).pathExtension.lowercased()
            if let cached = fileIcons[ext] { return (cached, false) }
            let type = ext.isEmpty ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
            let image = NSWorkspace.shared.icon(for: type)
            fileIcons[ext] = image
            return (image, false)
        }
    }
}
