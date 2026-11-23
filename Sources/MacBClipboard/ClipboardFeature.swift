import AppKit
import MacBKit

/// 클립보드 기록 + 숫자 슬롯 기능의 공개 진입점.
///
/// 앱 본체(`MacB`)는 이 클래스만 사용한다. 전역 단축키 등록은 앱 본체가 맡고,
/// 여기서는 단축키가 눌렸을 때 할 일만 제공한다.
///
/// 테스트용 진입점(`checkPasteboardNow`, `historyItems`, `storeCurrentPasteboard(inSlot:)` 등)은
/// 토스트·창·키 입력 없이 동작한다. 화면에 무언가 띄우는 것은 단축키 동작(`pasteSlot` 등)과 패널뿐이다.
@MainActor
public final class ClipboardFeature {
    /// 패널 하단 안내에 표시할 단축키 문자열 (예: "⌥V", "⌃⌥", "⌥").
    public struct HotkeyHints: Equatable, Sendable {
        public var history: String
        public var slotCopyModifiers: String
        public var slotPasteModifiers: String

        public init(history: String = "", slotCopyModifiers: String = "", slotPasteModifiers: String = "") {
            self.history = history
            self.slotCopyModifiers = slotCopyModifiers
            self.slotPasteModifiers = slotPasteModifiers
        }
    }

    public enum PanelTab: Sendable {
        case history
        case slots
    }

    public static let slotRange = 1...9

    public var hotkeyHints = HotkeyHints() {
        didSet { panelController?.hints = hotkeyHints }
    }

    /// 복사 시점의 맨 앞 앱. 기록의 출처 표시와 `ignoreApps` 판단에 쓴다. 테스트에서 바꿔 끼운다.
    public var frontmostAppProvider: @MainActor () -> SourceApp? = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(name: app.localizedName, bundleID: app.bundleIdentifier)
    }

    /// 다른 앱에 키 입력을 보낼 수 있는지(손쉬운 사용 권한). 테스트에서 바꿔 끼운다.
    public var canSendKeystrokes: @MainActor () -> Bool = { Permissions.hasAccessibility }

    /// 사용자가 보조키를 실제로 누르고 있는지. 테스트에서 바꿔 끼운다.
    public var modifierKeysDown: @MainActor () -> Bool = { Keystroke.physicalModifiersDown }

    /// 현재 앱에 ⌘V를 보내는 단계. 테스트에서 바꿔 끼워 키 입력 없이 순서를 확인한다.
    public var pasteKeystroke: @MainActor () -> Void = { Keystroke.postPaste() }

    private var config: AppConfig.Clipboard
    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private var timer: Timer?
    /// 마지막으로 처리한 `changeCount`. 우리가 직접 올린 내용도 여기 적어 두어 다시 기록하지 않는다.
    private var lastChangeCount: Int
    private var emptyReads = (changeCount: -1, attempts: 0)
    private var panelController: ClipboardPanelController?

    private static let pollInterval: TimeInterval = 0.4
    /// 패널을 닫은 뒤 키 포커스가 원래 앱으로 돌아갈 시간.
    private static let focusReturnDelay: TimeInterval = 0.08
    /// ⌘C를 보낸 뒤 페이스트보드가 바뀌기를 기다리는 시간.
    private static let copyTimeout: TimeInterval = 0.6
    /// 비어 보이는 변경을 다시 읽어 보는 횟수(다른 앱이 비운 직후 아직 쓰기 전일 수 있다).
    private static let emptyReadAttempts = 3

    /// - Parameters:
    ///   - storageDirectory: 기록/슬롯을 저장할 폴더 (없으면 만든다).
    ///   - pasteboard: 감시할 페이스트보드. 테스트에서는 `NSPasteboard.withUniqueName()`을 넘긴다.
    public init(config: AppConfig.Clipboard, storageDirectory: URL, pasteboard: NSPasteboard = .general) {
        let config = Self.sanitized(config)
        self.config = config
        self.pasteboard = pasteboard
        store = ClipboardStore(directory: storageDirectory, maxItems: config.maxItems, persistHistory: config.persist)
        // 실행 전부터 있던 내용은 출처를 알 수 없으므로 기록하지 않는다.
        lastChangeCount = pasteboard.changeCount
        store.onChange = { [weak self] in self?.refreshPanel() }
    }

    /// 페이스트보드 감시를 시작한다.
    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.checkPasteboardNow()
            }
        }
        timer.tolerance = 0.1
        // 메뉴 추적·스크롤 중에도 돌도록 common 모드에 건다.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        store.flush()
    }

    /// 설정이 바뀌었을 때 호출된다.
    public func apply(config newValue: AppConfig.Clipboard) {
        let newConfig = Self.sanitized(newValue)
        if newConfig.enabled, !config.enabled {
            // 꺼져 있는 동안 복사한 것은 켠 뒤에도 기록하지 않는다.
            lastChangeCount = pasteboard.changeCount
        }
        config = newConfig
        store.configure(maxItems: newConfig.maxItems, persistHistory: newConfig.persist)
        refreshPanel()
    }

    /// 현재 기록 개수.
    public var historyCount: Int { store.history.count }

    /// 기록, 최신순.
    public var historyItems: [Item] { store.history.map(\.item) }

    /// 패널 검색과 같은 규칙으로 거른 기록(공백으로 나눈 낱말이 모두 들어 있는 항목).
    public func historyItems(matching query: String) -> [Item] {
        Item.filter(historyItems, query: query)
    }

    /// 슬롯 내용. 비었거나 범위 밖이면 nil.
    public func slotItem(_ slot: Int) -> Item? {
        store.slots[slot]?.item
    }

    public var isPanelVisible: Bool { panelController?.isVisible ?? false }

    // MARK: Capture

    /// 페이스트보드를 지금 한 번 확인해 바뀌었으면 기록한다. 기록했으면 true.
    /// 감시 타이머가 이것을 부른다. 테스트는 타이머 없이 직접 부른다.
    @discardableResult
    public func checkPasteboardNow() -> Bool {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return false }
        guard config.enabled else {
            lastChangeCount = count
            return false
        }
        let source = frontmostAppProvider()
        if isIgnored(source?.bundleID) {
            lastChangeCount = count
            return false
        }

        switch Payload.read(from: pasteboard) {
        case .empty:
            if emptyReads.changeCount != count { emptyReads = (count, 0) }
            emptyReads.attempts += 1
            if emptyReads.attempts >= Self.emptyReadAttempts { lastChangeCount = count }
            return false
        case .doNotRecord:
            lastChangeCount = count
            return false
        case .tooLarge:
            lastChangeCount = count
            Log.info("클립보드 항목이 너무 커서 기록하지 않음")
            return false
        case let .contents(payload, declaredSource):
            lastChangeCount = count
            guard !isIgnored(declaredSource), let item = payload.makeItem(date: Date(), source: source) else { return false }
            store.insert(item, payload: payload)
            return true
        }
    }

    private func isIgnored(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return config.ignoreApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    // MARK: Slots

    /// 기록 항목을 슬롯에 넣는다. 슬롯은 기록과 따로 보관되어 기록에서 지워져도 남는다.
    @discardableResult
    public func storeHistoryItem(_ id: UUID, inSlot slot: Int) -> Bool {
        guard Self.slotRange.contains(slot),
              var item = store.history.first(where: { $0.item.id == id })?.item,
              let payload = store.historyPayload(id)
        else { return false }
        item.id = UUID()
        item.date = Date()
        store.setSlot(slot, item: item, payload: payload)
        return true
    }

    /// 지금 클립보드 내용을 슬롯에 넣는다(키 입력 없이). 보호된 내용·빈 내용이면 false.
    @discardableResult
    public func storeCurrentPasteboard(inSlot slot: Int) -> Bool {
        if case .saved = saveCurrentPasteboard(toSlot: slot) { return true }
        return false
    }

    public func clearSlot(_ slot: Int) {
        guard Self.slotRange.contains(slot) else { return }
        store.clearSlot(slot)
    }

    /// 현재 앱의 선택 영역을 복사(⌘C)해서 슬롯에 넣는다.
    /// 패널이 열려 있으면 대신 패널에서 선택된 기록 항목을 슬롯에 넣는다.
    public func copySelectionToSlot(_ slot: Int) {
        guard Self.slotRange.contains(slot) else {
            Log.error("슬롯 번호가 범위 밖: \(slot)")
            return
        }
        if let controller = panelController, controller.isVisible {
            if let id = controller.selectedHistoryID {
                if storeHistoryItem(id, inSlot: slot), let item = slotItem(slot) {
                    announceSaved(item, slot: slot)
                }
                return
            }
            // 패널이 키 창이면 ⌘C가 패널로 가므로 먼저 닫고 포커스가 돌아갈 틈을 둔다.
            controller.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusReturnDelay) { [weak self] in
                MainActor.assumeIsolated { self?.copyFromFrontApp(toSlot: slot) }
            }
            return
        }
        copyFromFrontApp(toSlot: slot)
    }

    /// 슬롯 내용을 클립보드에 올리고 현재 앱에 붙여넣는다(⌘V).
    public func pasteSlot(_ slot: Int) {
        guard Self.slotRange.contains(slot) else {
            Log.error("슬롯 번호가 범위 밖: \(slot)")
            return
        }
        guard let entry = store.slots[slot] else {
            announceEmptySlot(slot)
            return
        }
        guard let payload = store.slotPayload(slot) else {
            Toast.show("슬롯 \(slot)\(Korean.subject(slot)) 불러오지 못했습니다", symbol: "exclamationmark.triangle")
            return
        }
        let panelWasOpen = isPanelVisible
        panelController?.hide()
        enqueuePaste(PasteRequest(
            payload: payload,
            origin: .slot(entry.item),
            notBefore: Date().addingTimeInterval(panelWasOpen ? Self.focusReturnDelay : 0)
        ))
    }

    // MARK: Writing (테스트·앱 공용)

    /// 기록 항목을 지정한 페이스트보드에 올린다. 감시 중인 페이스트보드면 그 항목을 맨 위로 올린다.
    @discardableResult
    public func writeHistoryItem(_ id: UUID, to target: NSPasteboard) -> Bool {
        guard let payload = store.historyPayload(id) else { return false }
        if target.name == pasteboard.name {
            let ok = place(payload)
            store.moveToTop(id, date: Date())
            return ok
        }
        return payload.write(to: target)
    }

    /// 슬롯 내용을 지정한 페이스트보드에 올린다(키 입력 없이).
    @discardableResult
    public func writeSlot(_ slot: Int, to target: NSPasteboard) -> Bool {
        guard Self.slotRange.contains(slot), let payload = store.slotPayload(slot) else { return false }
        if target.name == pasteboard.name { return place(payload) }
        return payload.write(to: target)
    }

    public func removeHistoryItem(_ id: UUID) {
        store.remove(id)
    }

    public func clearHistory() {
        store.clearHistory()
    }

    /// 대기 중인 디스크 쓰기가 끝날 때까지 기다린다(테스트, 종료 직전).
    public func waitForPendingWrites() {
        store.flush()
    }

    // MARK: Panel

    /// 패널을 열거나(닫혀 있으면) 닫는다(이미 같은 탭으로 열려 있으면).
    public func togglePanel(tab: PanelTab = .history) {
        let controller = panelController ?? makePanelController()
        if controller.isVisible {
            if controller.tab == tab {
                controller.hide()
            } else {
                controller.switchTo(tab)
            }
            return
        }
        controller.update(history: historyItems, slots: slotItems, recordingEnabled: config.enabled)
        controller.show(tab: tab)
    }

    public func hidePanel() {
        panelController?.hide()
    }

    /// 예시 데이터로 채운 패널을 화면 밖에서 그려 PNG로 저장한다(눈으로 확인하는 용도).
    /// `clipboard-history.png`, `clipboard-slots.png`를 만든다(어두운 모드는 `-dark`가 붙은 파일).
    public static func writeDebugSnapshots(to directory: URL) throws {
        try ClipboardSnapshot.write(to: directory)
    }

    private var slotItems: [Item?] {
        Self.slotRange.map { store.slots[$0]?.item }
    }

    private func makePanelController() -> ClipboardPanelController {
        let controller = ClipboardPanelController(opaqueBackground: false)
        controller.hints = hotkeyHints
        controller.actions = ClipboardPanelController.Actions(
            pasteHistory: { [weak self] id in self?.pasteFromPanel(historyID: id) },
            pasteSlot: { [weak self] slot in self?.pasteSlot(slot) },
            deleteHistory: { [weak self] id in self?.removeHistoryItem(id) },
            clearSlot: { [weak self] slot in self?.clearSlot(slot) }
        )
        panelController = controller
        return controller
    }

    private func refreshPanel() {
        guard let controller = panelController, controller.isVisible else { return }
        controller.update(history: historyItems, slots: slotItems, recordingEnabled: config.enabled)
    }

    private func pasteFromPanel(historyID id: UUID) {
        guard let payload = store.historyPayload(id) else {
            Toast.show("내용을 불러오지 못했습니다", symbol: "exclamationmark.triangle")
            return
        }
        panelController?.hide()
        enqueuePaste(PasteRequest(
            payload: payload,
            origin: .history(id),
            notBefore: Date().addingTimeInterval(Self.focusReturnDelay)
        ))
    }

    // MARK: Keystrokes

    /// 감시 중인 페이스트보드에 올리고, 우리가 만든 변경이라고 표시해 둔다.
    @discardableResult
    private func place(_ payload: Payload) -> Bool {
        let ok = payload.write(to: pasteboard)
        lastChangeCount = pasteboard.changeCount
        return ok
    }

    // MARK: Paste queue
    //
    // 붙여넣기 요청은 한 줄로 세워 하나씩 처리한다: (포커스·보조키 대기) → 그 요청의 내용을 클립보드에 쓰기
    // → ⌘V → 앱이 읽을 시간만큼 쉬기 → 다음 요청. 단축키를 누른 순간에 클립보드에 쓰면, ⌥를 누른 채
    // 1·2·3을 연타했을 때 앞 요청의 ⌘V가 나가기 전에 뒤 요청이 클립보드를 덮어써서 "22"처럼 붙는다.

    private struct PasteRequest {
        enum Origin {
            /// 슬롯 붙여넣기. 쓰는 순간 기록에도 남긴다.
            case slot(Item)
            /// 패널에서 고른 기록 항목. 쓰는 순간 맨 위로 올린다.
            case history(UUID)
        }

        var payload: Payload
        var origin: Origin
        /// 패널을 닫은 뒤 포커스가 돌아갈 때까지는 키를 보내지 않는다.
        var notBefore: Date
    }

    private var pasteQueue: [PasteRequest] = []
    private var isPasting = false
    /// 이번 연타에서 보조키를 누른 채로 이미 한 번 보냈는지. 그랬다면 보조키를 뗄 때까지 다시 기다리지 않는다.
    private var modifiersHeldThroughBurst = false

    /// ⌘V를 보낸 뒤 다음 요청의 내용을 쓰기 전까지 쉬는 시간.
    /// 키 입력은 비동기로 전달되고 앱은 자기 차례에 클립보드를 읽는다. 일반 앱은 수십 ms면 충분하지만
    /// Electron 계열(Slack, VS Code 등)은 렌더러↔브라우저 프로세스를 거쳐 더 걸린다. 0.15초면 그 여유를
    /// 두면서도 세 개 연타가 0.5초 안팎에 끝난다.
    private static let pasteSettleInterval: TimeInterval = 0.15
    /// 단축키 보조키(⌥ 등)를 뗄 때까지 기다리는 최대 시간(`Keystroke.whenModifiersReleased`와 같은 값).
    private static let modifierReleaseTimeout: TimeInterval = 0.4

    private func enqueuePaste(_ request: PasteRequest) {
        guard canSendKeystrokes() else {
            // 보낼 키가 없으니 순서를 맞출 것도 없다. 바로 쓰고 안내한다(마지막 요청이 이긴다).
            commit(request)
            Toast.show(
                "클립보드에 올렸습니다 · ⌘V로 붙여넣기",
                symbol: "doc.on.clipboard",
                detail: "자동 붙여넣기는 손쉬운 사용 권한이 필요합니다",
                duration: 2.6
            )
            requestAccessibilityOnce(for: .autoPaste)
            return
        }
        pasteQueue.append(request)
        if !isPasting { runNextPaste() }
    }

    private func runNextPaste() {
        guard !pasteQueue.isEmpty else {
            isPasting = false
            return
        }
        isPasting = true
        let request = pasteQueue.removeFirst()
        runOnMain(after: request.notBefore.timeIntervalSinceNow) { [weak self] in
            guard let self else { return }
            if self.modifiersHeldThroughBurst, self.modifierKeysDown() {
                self.sendPaste(request)
            } else {
                self.modifiersHeldThroughBurst = false
                let deadline = Date().addingTimeInterval(Self.modifierReleaseTimeout)
                self.waitForModifierRelease(until: deadline) { [weak self] in self?.sendPaste(request) }
            }
        }
    }

    private func sendPaste(_ request: PasteRequest) {
        // 쓰기는 반드시 이 요청의 ⌘V 바로 앞에서 한다.
        commit(request)
        pasteKeystroke()
        if modifierKeysDown(), !modifiersHeldThroughBurst {
            modifiersHeldThroughBurst = true
            watchForBurstEnd()
        }
        runOnMain(after: Self.pasteSettleInterval) { [weak self] in self?.runNextPaste() }
    }

    /// 보조키를 떼면 연타가 끝난 것으로 본다. 다시 누르고 시작하는 다음 연타는 처음처럼 기다린다.
    /// 표시가 켜져 있는 동안(⌥를 누르고 있는 동안)만 가볍게 확인한다.
    private func watchForBurstEnd() {
        guard modifiersHeldThroughBurst else { return }
        guard modifierKeysDown() else {
            modifiersHeldThroughBurst = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.watchForBurstEnd() }
        }
    }

    /// 요청의 내용을 클립보드에 쓰고, 그 시점 기준으로 기록을 맞춘다.
    private func commit(_ request: PasteRequest) {
        place(request.payload)
        switch request.origin {
        case let .slot(slotItem):
            if config.enabled {
                // 클립보드에 올라간 것은 기록에도 남는다는 규칙을 슬롯 붙여넣기에도 지킨다.
                var item = slotItem
                item.id = UUID()
                item.date = Date()
                store.insert(item, payload: request.payload)
            }
        case let .history(id):
            store.moveToTop(id, date: Date())
        }
    }

    /// 단축키(⌥1 등)를 누른 채로 ⌘V를 합성하면 앱에 따라 ⌥⌘V로 읽혀서, 보조키를 뗄 때까지 잠깐 기다린다.
    private func waitForModifierRelease(until deadline: Date, then body: @escaping @MainActor () -> Void) {
        guard modifierKeysDown(), Date() < deadline else {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            MainActor.assumeIsolated { self?.waitForModifierRelease(until: deadline, then: body) }
        }
    }

    /// 단축키 처리 안에서 바로 키를 보내지 않도록 늘 한 번은 다음 차례로 미룬다.
    private func runOnMain(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let work: @Sendable () -> Void = { MainActor.assumeIsolated { body() } }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func copyFromFrontApp(toSlot slot: Int) {
        guard Permissions.hasAccessibility else {
            // ⌘C를 보낼 수 없으니 지금 클립보드를 넣는다. 직접 ⌘C 한 뒤 단축키를 누르면 같은 결과가 된다.
            switch saveCurrentPasteboard(toSlot: slot) {
            case let .saved(item):
                Toast.show(
                    "슬롯 \(slot)에 현재 클립보드를 저장",
                    symbol: "\(slot).square.fill",
                    detail: "\(item.shortPreview) · 선택 영역 자동 복사는 손쉬운 사용 권한이 필요합니다",
                    duration: 2.6
                )
            default:
                Toast.show(
                    "손쉬운 사용 권한이 필요합니다",
                    symbol: "lock",
                    detail: "선택 영역을 슬롯에 복사하려면 권한을 허용하세요",
                    duration: 2.6
                )
            }
            requestAccessibilityOnce(for: .slotCopy)
            return
        }
        Keystroke.whenModifiersReleased { [weak self] in
            guard let self else { return }
            let before = self.pasteboard.changeCount
            Keystroke.postCopy()
            let deadline = Date().addingTimeInterval(Self.copyTimeout)
            self.waitForPasteboardChange(since: before, deadline: deadline) { [weak self] changed in
                guard let self else { return }
                guard changed else {
                    Toast.show("복사할 선택 영역이 없습니다", symbol: "text.cursor")
                    return
                }
                // 새로 복사한 내용은 클립보드에 그대로 두고(되돌리지 않는다) 기록에도 평소처럼 남긴다.
                self.checkPasteboardNow()
                self.saveCopiedSelection(toSlot: slot, retries: 2)
            }
        }
    }

    /// 다른 앱이 페이스트보드를 비운 직후 아직 쓰는 중일 수 있어, 비어 보이면 잠깐 뒤 다시 본다.
    private func saveCopiedSelection(toSlot slot: Int, retries: Int) {
        let result = saveCurrentPasteboard(toSlot: slot)
        if case .empty = result, retries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.saveCopiedSelection(toSlot: slot, retries: retries - 1) }
            }
            return
        }
        announce(result, slot: slot)
    }

    private func waitForPasteboardChange(
        since count: Int,
        deadline: Date,
        then completion: @escaping @MainActor (Bool) -> Void
    ) {
        if pasteboard.changeCount != count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { completion(true) }
            }
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                self?.waitForPasteboardChange(since: count, deadline: deadline, then: completion)
            }
        }
    }

    /// 실행당 한 번만. 앱이 권한 안내 창을 연결해 두었으면 그 창을, 아니면 시스템 안내 창을 띄운다.
    private func requestAccessibilityOnce(for purpose: PermissionPurpose) {
        PermissionRequestHook.accessibility.requestOnce(for: purpose)
    }

    // MARK: Slot saving

    private enum SlotSaveResult {
        case saved(Item)
        case empty
        case doNotRecord
        case tooLarge
        case invalidSlot
    }

    private func saveCurrentPasteboard(toSlot slot: Int) -> SlotSaveResult {
        guard Self.slotRange.contains(slot) else { return .invalidSlot }
        switch Payload.read(from: pasteboard) {
        case .empty:
            return .empty
        case .doNotRecord:
            // 슬롯은 디스크에 남으므로 암호처럼 표시된 내용은 넣지 않는다.
            return .doNotRecord
        case .tooLarge:
            return .tooLarge
        case let .contents(payload, _):
            guard let item = payload.makeItem(date: Date(), source: frontmostAppProvider()) else { return .empty }
            store.setSlot(slot, item: item, payload: payload)
            return .saved(item)
        }
    }

    private func announce(_ result: SlotSaveResult, slot: Int) {
        switch result {
        case let .saved(item):
            announceSaved(item, slot: slot)
        case .empty:
            Toast.show("복사할 선택 영역이 없습니다", symbol: "text.cursor")
        case .doNotRecord:
            Toast.show("보호된 내용은 슬롯에 저장하지 않습니다", symbol: "lock", detail: "암호 관리자 등이 숨김 표시한 항목입니다")
        case .tooLarge:
            Toast.show("너무 커서 슬롯에 저장하지 않았습니다", symbol: "exclamationmark.triangle", detail: "항목당 16MB까지 저장합니다")
        case .invalidSlot:
            break
        }
    }

    private func announceSaved(_ item: Item, slot: Int) {
        Toast.show("슬롯 \(slot)에 저장", symbol: "\(slot).square.fill", detail: item.shortPreview)
    }

    private func announceEmptySlot(_ slot: Int) {
        let modifiers = hotkeyHints.slotCopyModifiers
        let detail = modifiers.isEmpty ? nil : "\(modifiers)\(slot)\(Korean.instrumental(slot)) 선택 영역을 저장하세요"
        Toast.show("슬롯 \(slot)\(Korean.subject(slot)) 비어 있습니다", symbol: "\(slot).square", detail: detail)
    }

    // MARK: Config

    private static func sanitized(_ config: AppConfig.Clipboard) -> AppConfig.Clipboard {
        var config = config
        config.maxItems = min(max(config.maxItems, 1), 5000)
        return config
    }
}

/// 숫자 뒤 조사. 1(일)·3(삼)·6(육)·7(칠)·8(팔)·0(영)은 받침이 있다.
private enum Korean {
    private static func hasFinalConsonant(_ digit: Int) -> Bool {
        [0, 1, 3, 6, 7, 8].contains(abs(digit) % 10)
    }

    /// 이/가
    static func subject(_ number: Int) -> String {
        hasFinalConsonant(number) ? "이" : "가"
    }

    /// 으로/로 (ㄹ 받침은 '로')
    static func instrumental(_ number: Int) -> String {
        [0, 3, 6].contains(abs(number) % 10) ? "으로" : "로"
    }
}
