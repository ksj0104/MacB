import AppKit
import MacBClipboard
import MacBKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig()
    private var capture: CaptureService?
    private var clipboard: ClipboardFeature?
    private var catalog: ActionCatalog?
    private var statusMenu: StatusMenuController?
    private var watcher: ConfigWatcher?
    private let radial = RadialMenuController()
    private let inputSwitch = InputSwitchManager()
    /// 마지막으로 적용을 맡긴 한영 전환 설정. 같은 설정이면 다시 하지 않는다.
    private var requestedInputSwitch: AppConfig.Keyboard.InputSwitch?
    /// 마지막 적용이 실패했다. 같은 설정이라도 다음 기회(다시 불러오기, 창·메뉴에서 무엇을 바꿀 때)에 다시 한다.
    private var inputSwitchNeedsRetry = false
    /// 마지막으로 알린 한영 전환 실패. 다른 편집 때문에 다시 시도했다가 같은 이유로 또 실패하면 알림을 되풀이하지 않는다.
    private var lastInputSwitchFailure: InputSwitchResult?
    /// 시작할 때 config.json을 읽지 못해 기본값으로 떠 있는 동안은 한영 전환을 건드리지 않는다.
    /// 기본값은 '꺼짐'이라 그대로 적용하면 사용자가 켜 둔 한영 전환 키를 되돌려 버린다.
    private var holdInputSwitch = false
    private var inputSwitchStatus: InputSwitchStatus?
    private var settingsWindow: ShortcutSettingsWindowController?

    private var isReady = false
    private var pendingURLs: [URL] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var terminatingOnSignal = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOnSignals()
        if anotherInstanceIsRunning() {
            Log.info("another instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        AppPaths.ensureDirectory(AppPaths.supportDirectory)
        // 처음 읽기 전에 감시를 시작해야, 읽는 사이에 저장된 변경도 놓치지 않는다.
        // (파일이 없어 기본값을 써 두는 것도 알림이 되지만, 다시 읽어 보면 같은 내용이라 조용히 끝난다.)
        watcher = ConfigWatcher(file: AppPaths.configFile) { [weak self] in
            self?.reloadConfig()
        }
        var startupProblem: String?
        do {
            config = try AppConfig.load(from: AppPaths.configFile)
        } catch {
            // 설정이 깨져 있어도 앱은 기본값으로 떠야 고칠 수 있다.
            startupProblem = describe(error)
        }

        let capture = CaptureService(config: config.capture)
        let clipboard = ClipboardFeature(config: config.clipboard, storageDirectory: AppPaths.clipboardDirectory)
        let catalog = ActionCatalog(capture: capture, clipboard: clipboard)
        self.capture = capture
        self.clipboard = clipboard
        self.catalog = catalog

        statusMenu = StatusMenuController(tools: catalog.builtIns, handlers: .init(
            openRadialMenu: { [radial] in radial.toggleLatched() },
            openClipboard: { clipboard.togglePanel(tab: .history) },
            openSlots: { clipboard.togglePanel(tab: .slots) },
            runTool: { id in catalog.perform(actionID: id) },
            reloadConfig: { [weak self] in self?.reloadConfig(explicit: true) },
            clearClipboard: {
                clipboard.clearHistory()
                Toast.show("클립보드 기록을 지웠습니다", symbol: "trash")
            },
            relaunch: { [weak self] in self?.relaunch() },
            toggleInputSwitch: { [weak self] in self?.toggleInputSwitch() },
            openShortcutSettings: { [weak self] in self?.openShortcutSettings() }
        ))
        // 권한 안내 창: 'MacB 다시 시작' 버튼과 클립보드의 손쉬운 사용 요청을 연결한다.
        PermissionGuide.shared.relaunchAction = { [weak self] in self?.relaunch() }
        PermissionRequestHook.accessibility.handler = { purpose in PermissionGuide.shared.show(for: purpose) }

        holdInputSwitch = startupProblem != nil
        let hotkeyProblems = applyConfig()
        clipboard.start()

        isReady = true
        pendingURLs.forEach(handle)
        pendingURLs.removeAll()

        if let startupProblem {
            Toast.show("config.json을 읽지 못해 기본 설정으로 실행합니다", symbol: "exclamationmark.triangle", detail: startupProblem, duration: 6)
        } else if let problem = hotkeyProblems.first {
            Toast.show("단축키 설정을 확인하세요", symbol: "exclamationmark.triangle", detail: problem, duration: 6)
        } else {
            let hint = KeyCombo(string: config.hotkeys.radialMenu).map { "\($0.displayString) 를 누르고 있으면 원형 메뉴가 열립니다" }
            Toast.show("MacB 준비 완료", symbol: "circle.grid.cross", detail: hint, duration: 3.2)
        }
        Log.info("ready (active=\(NSApp.isActive))")

        // 처음 실행했거나 화면 기록을 허용하고 다시 시작한 직후면 권한 안내 창을 띄운다.
        // 다른 인스턴스 때문에 곧 종료할 때는 위에서 이미 돌아갔으므로 여기까지 오지 않는다.
        PermissionGuide.shared.showAtLaunchIfNeeded(warningOnScreen: startupProblem != nil || !hotkeyProblems.isEmpty)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Log.info("app: became active")
    }

    func applicationDidResignActive(_ notification: Notification) {
        Log.info("app: resigned active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "macb" {
            if isReady {
                handle(url)
            } else {
                pendingURLs.append(url)
            }
        }
    }

    // MARK: Config

    /// 현재 `config`를 모든 구성 요소에 반영한다. 단축키 문제 목록을 돌려준다.
    @discardableResult
    private func applyConfig() -> [String] {
        guard let capture, let clipboard, let catalog else { return [] }
        capture.config = config.capture
        clipboard.apply(config: config.clipboard)
        clipboard.hotkeyHints = .init(
            history: KeyCombo(string: config.hotkeys.clipboardHistory)?.displayString ?? "",
            slotCopyModifiers: KeyModifiers(string: config.hotkeys.slotCopyModifiers)?.displayString ?? "",
            slotPasteModifiers: KeyModifiers(string: config.hotkeys.slotPasteModifiers)?.displayString ?? ""
        )
        radial.setItems(catalog.resolve(config.radialMenu.items))
        statusMenu?.hotkeys = config.hotkeys
        statusMenu?.keyboard = config.keyboard
        settingsWindow?.update(config: config)
        applyInputSwitch()
        return registerHotkeys()
    }

    /// 감시기가 기준 상태를 먼저 기록한 뒤 부르므로, 읽는 사이에 또 저장되면 다음 알림으로 다시 불린다.
    /// 파일이 없어서 `load`가 기본값을 써 두면 그 쓰기도 한 번 더 알림이 되지만,
    /// 그때 읽는 내용은 지금 반영한 기본값과 같아서 아래에서 조용히 끝난다.
    /// - Parameter explicit: 사용자가 직접 다시 불러오기를 했다(메뉴, macb://reload). 실패했던 한영 전환을 다시 하고 결과를 알린다.
    private func reloadConfig(explicit: Bool = false) {
        do {
            let loaded = try AppConfig.load(from: AppPaths.configFile)
            let wasHolding = holdInputSwitch
            holdInputSwitch = false
            if explicit { lastInputSwitchFailure = nil }
            guard loaded != config else {
                // 시작할 때 깨져 있던 파일이 기본값과 같은 내용으로 고쳐진 경우에는 이제야 한영 전환을 맞출 수 있다.
                // 직접 다시 불러온 경우에는 지난번에 실패한 한영 전환을 다시 해 본다.
                if wasHolding || explicit { applyInputSwitch() }
                return
            }
            config = loaded
            let problems = applyConfig()
            if let problem = problems.first {
                Toast.show("단축키 설정을 확인하세요", symbol: "exclamationmark.triangle", detail: problem, duration: 6)
            } else {
                Toast.show("설정을 다시 불러왔습니다", symbol: "arrow.clockwise")
            }
            Log.info("config reloaded")
        } catch {
            // 고치는 중일 수 있으니 이전 설정을 그대로 유지한다.
            Log.error("config rejected: \(describe(error))")
            Toast.show("config.json에 오류가 있습니다", symbol: "exclamationmark.triangle", detail: describe(error), duration: 6)
        }
    }

    /// '단축키 설정' 창이나 메뉴에서 바꾼 설정을 반영하고 config.json에 저장한다.
    /// 먼저 반영하고 나서 저장하므로, 저장이 일으킨 감시 알림은 같은 설정을 읽어 조용히 끝난다.
    private func applyEditedConfig(_ edited: AppConfig) {
        // 받아들이지 않은 편집은 창에서도 되돌린다. 창이 미리 '적용하는 중'으로 바꿔 둔 한영 상태도 마지막 상태로 돌린다.
        func revertSettingsWindow() {
            settingsWindow?.update(config: config)
            if let inputSwitchStatus { settingsWindow?.showInputSwitchStatus(inputSwitchStatus) }
        }
        // 편집은 지금 들고 있는 설정을 바탕으로 한다. 파일이 깨져 있거나 그사이 바뀌었으면 덮어쓰지 않는다.
        switch configFileState() {
        case .matches:
            break
        case .broken(let problem):
            // 그때 들고 있는 설정은 파일 내용이 아니라 이전 값이나 기본값이다.
            Toast.show("config.json에 오류가 있어 저장하지 않았습니다", symbol: "exclamationmark.triangle", detail: problem, duration: 6)
            revertSettingsWindow()
            return
        case .changed:
            // 직접 고쳐 저장한 직후라 아직 다시 읽기 전인 경우. 바뀐 내용을 먼저 반영한다.
            reloadConfig()
            revertSettingsWindow()
            Toast.show("config.json이 바뀌어 있어 저장하지 않았습니다", symbol: "exclamationmark.triangle", detail: "바뀐 내용을 불러왔으니 다시 설정해 주세요", duration: 6)
            return
        }
        // 저장한 파일을 감시기가 다시 읽었을 때 똑같은 설정이 나와야 조용히 끝난다. 그래서 읽어 들인 모양으로 맞춰 둔다.
        do {
            config = try AppConfig.decode(edited.encoded())
        } catch {
            Log.error("config encode failed: \(error.localizedDescription)")
            Toast.show("설정을 저장하지 못했습니다", symbol: "exclamationmark.triangle", detail: error.localizedDescription, duration: 6)
            revertSettingsWindow()
            return
        }
        let problems = applyConfig()
        do {
            try config.save(to: AppPaths.configFile)
        } catch {
            Log.error("config save failed: \(error.localizedDescription)")
            Toast.show("설정을 저장하지 못했습니다", symbol: "exclamationmark.triangle", detail: error.localizedDescription, duration: 6)
            return
        }
        Log.info("config saved from settings")
        if let problem = problems.first {
            Toast.show("단축키 설정을 확인하세요", symbol: "exclamationmark.triangle", detail: problem, duration: 6)
        }
    }

    private enum ConfigFileState {
        /// 지금 들고 있는 설정과 같다(파일이 없을 때도 — 저장하면 새로 생긴다).
        case matches
        case changed
        case broken(String)
    }

    private func configFileState() -> ConfigFileState {
        let url = AppPaths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 링크가 가리키는 파일이 없으면 저장하지 않는다(링크를 따라 엉뚱한 곳에 파일을 만들지 않게).
            if let missing = AppConfig.missingLinkTarget(of: url) {
                return .broken(ConfigFileError.missingLinkTarget(missing).localizedDescription)
            }
            return .matches
        }
        do {
            return try AppConfig.decode(Data(contentsOf: url)) == config ? .matches : .changed
        } catch {
            return .broken(describe(error))
        }
    }

    // MARK: Input switch

    /// 한영 전환 키를 설정대로 맞춘다. 같은 설정을 이미 맡겼고 성공했으면 다시 하지 않는다.
    /// 시작할 때는 맡긴 것이 없으므로 늘 한다 — 재부팅·로그아웃하면 키 바꾸기가 풀리기 때문이다.
    private func applyInputSwitch() {
        guard !holdInputSwitch else {
            showInputSwitchStatus(InputSwitchStatus(text: "config.json을 읽지 못해 한영 전환 키를 그대로 두었습니다", kind: .error))
            return
        }
        let setting = config.keyboard.inputSwitch
        guard setting != requestedInputSwitch || inputSwitchNeedsRetry else { return }
        let previous = requestedInputSwitch
        let retrying = setting == previous
        requestedInputSwitch = setting
        inputSwitchNeedsRetry = false
        let launching = !isReady
        // 켜고 끄기를 바꾼 것이면(메뉴 막대 항목 등) 아무것도 안 바뀌었어도 결과를 알린다.
        let toggled = previous.map { $0.enabled != setting.enabled } ?? false
        showInputSwitchStatus(.working)
        inputSwitch.applyInBackground(setting) { [weak self] result in
            guard let self else { return }
            Log.info("input switch: \(result.message)" + (result.detail.map { " — \($0)" } ?? ""))
            self.showInputSwitchStatus(InputSwitchStatus(result))
            // 그 사이 다른 설정을 맡겼으면 그쪽 결과가 따로 온다(차례대로 처리된다).
            if self.requestedInputSwitch == setting { self.inputSwitchNeedsRetry = result.isFailure }
            // 다른 편집 때문에 다시 시도했다가 같은 이유로 또 실패하면 알림은 되풀이하지 않는다(상태 줄에는 보인다).
            let repeated = retrying && result.isFailure && result == self.lastInputSwitchFailure
            self.lastInputSwitchFailure = result.isFailure ? result : nil
            guard !repeated, Self.shouldAnnounce(result, launching: launching, toggled: toggled) else { return }
            Toast.show(result.message, symbol: result.symbol, detail: result.detail, duration: result.isFailure ? 6 : 2.5)
        }
    }

    /// 시작할 때는 실패와 입력 소스 단축키를 새로 쓴 경우만 알린다(다른 Mac에 config.json을 옮겨 와 처음 켠 경우 등).
    /// 재부팅 뒤 키 바꾸기만 다시 건 경우나 이미 맞춰져 있는 경우는 'MacB 준비 완료'를 가리지 않도록 조용히 지나간다.
    /// 그 뒤에는 설정을 바꿨거나 실패를 다시 시도할 때만 여기까지 오므로 결과를 알린다. 꺼져 있는 채로 키만 바꾼 것은 알리지 않는다.
    private static func shouldAnnounce(_ result: InputSwitchResult, launching: Bool, toggled: Bool) -> Bool {
        switch result {
        case .failed, .applied, .restored:
            return true
        case .remapped, .alreadyApplied:
            return !launching
        case .untouched:
            return !launching && toggled
        }
    }

    private func showInputSwitchStatus(_ status: InputSwitchStatus) {
        inputSwitchStatus = status
        settingsWindow?.showInputSwitchStatus(status)
    }

    /// 메뉴 막대의 '한영 전환 키' 항목. 창에서 켜는 것과 같은 검사(다른 단축키와 겹침)를 거친다.
    private func toggleInputSwitch() {
        guard let catalog else { return }
        let enabling = !config.keyboard.inputSwitch.enabled
        switch ShortcutSettings(config: config, tools: catalog.shortcutTools).applying(.setInputSwitchEnabled(enabling)) {
        case .success(let edited):
            applyEditedConfig(edited)
        case .failure(let refusal):
            Toast.show("한영 전환 키를 켜지 못했습니다", symbol: "exclamationmark.triangle", detail: refusal.message, duration: 5)
        }
    }

    // MARK: Shortcut settings

    private func openShortcutSettings() {
        guard let catalog else { return }
        let window = settingsWindow ?? makeShortcutSettingsWindow(catalog: catalog)
        settingsWindow = window
        window.update(config: config)
        if let inputSwitchStatus { window.showInputSwitchStatus(inputSwitchStatus) }
        window.show()
    }

    private func makeShortcutSettingsWindow(catalog: ActionCatalog) -> ShortcutSettingsWindowController {
        let window = ShortcutSettingsWindowController(
            config: config, tools: catalog.shortcutTools, locateApp: ActionCatalog.applicationURL(for:)
        )
        window.onChange = { [weak self] edited in self?.applyEditedConfig(edited) }
        window.onRecordingChange = { [weak self] recording in self?.setHotkeysSuspended(recording) }
        return window
    }

    /// 단축키 칸이 키를 기록하는 동안 MacB의 전역 단축키를 잠시 뗀다. 걸려 있으면 그 조합이 칸까지 오지 않는다.
    private func setHotkeysSuspended(_ suspended: Bool) {
        if suspended {
            HotKeyCenter.shared.suspend()
            return
        }
        if let combo = HotKeyCenter.shared.resume().first {
            Toast.show(
                "단축키 설정을 확인하세요", symbol: "exclamationmark.triangle",
                detail: "\(combo.displayString) 단축키를 다시 등록하지 못했습니다 (중복이거나 시스템이 거부)", duration: 6
            )
        }
    }

    private func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func location(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : "\(path): "
        }
        switch decoding {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return location(context) + "값의 형식이 맞지 않습니다"
        case .keyNotFound(let key, let context):
            return location(context) + "'\(key.stringValue)' 항목이 없습니다"
        case .dataCorrupted(let context):
            let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return location(context) + (underlying ?? "JSON 형식이 올바르지 않습니다")
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: Hotkeys

    private func registerHotkeys() -> [String] {
        guard let clipboard, let catalog else { return [] }
        let center = HotKeyCenter.shared
        center.unregisterAll()

        var problems: [String] = []
        var registered = 0
        let hotkeys = config.hotkeys

        func register(_ combo: KeyCombo, onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)? = nil) {
            if center.register(combo, onPress: onPress, onRelease: onRelease) == nil {
                problems.append("\(combo.displayString) 단축키를 등록하지 못했습니다 (중복이거나 시스템이 거부)")
            } else {
                registered += 1
            }
        }

        // 빈 문자열은 "끔"이라는 뜻이라 오류로 치지 않는다.
        func combo(_ text: String, name: String) -> KeyCombo? {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let combo = KeyCombo(string: text) else {
                problems.append("hotkeys.\(name): '\(text)' 를 해석할 수 없습니다")
                return nil
            }
            return combo
        }

        func modifiers(_ text: String, name: String) -> KeyModifiers? {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard let modifiers = KeyModifiers(string: text) else {
                problems.append("hotkeys.\(name): '\(text)' 는 보조키 조합이 아닙니다")
                return nil
            }
            return modifiers
        }

        if let combo = combo(hotkeys.radialMenu, name: "radialMenu") {
            register(combo, onPress: { [radial] in
                radial.hotkeyPressed(combo)
            }, onRelease: { [radial] in
                radial.hotkeyReleased()
            })
        }

        if let combo = combo(hotkeys.clipboardHistory, name: "clipboardHistory") {
            register(combo, onPress: { clipboard.togglePanel(tab: .history) })
        }

        var paste = modifiers(hotkeys.slotPasteModifiers, name: "slotPasteModifiers")
        let copy = modifiers(hotkeys.slotCopyModifiers, name: "slotCopyModifiers")
        if let pasteModifiers = paste, pasteModifiers == copy {
            problems.append("슬롯 복사와 붙여넣기의 보조키가 같습니다 — 붙여넣기 단축키를 껐습니다")
            paste = nil
        }
        for slot in ClipboardFeature.slotRange {
            guard let keyCode = KeyCombo.digitKeyCode(slot) else { continue }
            if let paste {
                register(KeyCombo(keyCode: keyCode, modifiers: paste), onPress: { clipboard.pasteSlot(slot) })
            }
            if let copy {
                register(KeyCombo(keyCode: keyCode, modifiers: copy), onPress: { clipboard.copySelectionToSlot(slot) })
            }
        }

        // 기능 바로 실행. 빈 key는 목록에만 있는 항목이다(단축키 설정 창에서 앱만 추가해 둔 경우 등).
        for (index, shortcut) in config.shortcuts.enumerated() {
            let text = shortcut.key.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let combo = KeyCombo(string: text) else {
                problems.append("shortcuts[\(index)].key: '\(text)' 를 해석할 수 없습니다")
                continue
            }
            register(combo, onPress: catalog.resolve(shortcut.item, index: index).perform)
        }

        Log.info("hotkeys: registered \(registered), problems \(problems.count)")
        for problem in problems { Log.error("hotkeys: \(problem)") }
        return problems
    }

    // MARK: URL scheme

    /// 다른 런처나 마우스 버튼 도구에서 MacB를 부를 때 쓴다. 허용하는 주소는 `URLCommand`가 정한다.
    /// 아무 프로세스나 주소를 열 수 있으므로, 사용자가 화면에서 직접 고르는 기능만 실행된다.
    private func handle(_ url: URL) {
        guard let clipboard, let catalog else { return }
        switch URLCommand.parse(url) {
        case .success(.menu):
            radial.toggleLatched()
        case .success(.clipboard):
            clipboard.togglePanel(tab: .history)
        case .success(.slots):
            clipboard.togglePanel(tab: .slots)
        case .success(.reload):
            reloadConfig(explicit: true)
        case .success(.run(let action)):
            Log.info("url: run \(action.rawValue)")
            catalog.perform(actionID: action.rawValue)
        case .failure(let refusal):
            // 주소는 밖에서 들어온 글이라 알림에는 그대로 옮기지 않는다.
            Log.error("url refused (\(refusal)): \(URLCommand.logSummary(of: url))")
            switch refusal {
            case .notAllowed:
                Toast.show("주소로는 실행할 수 없는 기능입니다", symbol: "hand.raised", detail: "메뉴 막대나 원형 메뉴에서 실행해 주세요")
            case .unknownAction:
                Toast.show("알 수 없는 기능입니다", symbol: "questionmark.circle")
            case .notMacB, .malformed, .unknownCommand:
                Toast.show("알 수 없는 MacB 주소입니다", symbol: "questionmark.circle")
            }
        }
    }

    // MARK: Signals

    /// `pkill`이나 로그아웃이 보내는 SIGTERM, 터미널의 ⌃C(SIGINT)를 평소 종료로 바꾼다.
    /// 그냥 죽으면 `applicationWillTerminate`가 불리지 않아 클립보드 기록이 디스크에 남지 않는다.
    private func terminateOnSignals() {
        for number in [SIGTERM, SIGINT] {
            // 기본 동작(즉시 종료)을 끄고 디스패치로 받는다. 자식 프로세스(Process)는 기본 동작으로 되돌려 띄워진다.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.terminatingOnSignal {
                        // 정상 종료가 어딘가에서 막혔을 때는 두 번째 신호로 바로 끝낼 수 있게 한다.
                        signal(number, SIG_DFL)
                        raise(number)
                        return
                    }
                    self.terminatingOnSignal = true
                    Log.info("signal \(number): terminating")
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Process

    /// 다른 MacB가 이미 떠 있는지.
    ///
    /// 종료 중인 인스턴스는 잠깐 기다려 준다. 권한을 바꾼 뒤 시스템이 "종료 후 다시 열기"를 하거나
    /// 'MacB 다시 시작'을 누르면, 이전 인스턴스가 아직 목록에 남아 있는 사이에 새 인스턴스가 뜰 수 있다.
    /// 그때 바로 포기하면 둘 다 사라져 앱이 꺼진 것처럼 보인다.
    private func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .filter { $0 > 0 && $0 != own }
        guard !others.isEmpty else { return false }

        // NSRunningApplication의 상태는 런루프가 돌아야 갱신되므로 프로세스가 살아 있는지 직접 본다.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if others.allSatisfy({ kill($0, 0) != 0 }) { return false }
            usleep(100_000)
        }
        return true
    }

    /// 권한을 새로 허용한 뒤에는 앱을 다시 띄워야 반영된다.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            NSApp.terminate(nil)
            return
        }
        // 이 인스턴스가 완전히 내려간 뒤에 열어야 한다. 아직 살아 있을 때 열면 시스템이
        // "이미 실행 중"으로 보고 아무것도 띄우지 않는다. (기다림은 최대 10초)
        let script = """
        n=0
        while /bin/kill -0 "$1" 2>/dev/null && [ "$n" -lt 100 ]; do /bin/sleep 0.1; n=$((n+1)); done
        exec /usr/bin/open "$0"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try process.run()
        } catch {
            // 다시 띄울 방법이 없는데 종료해 버리면 앱만 사라진다.
            Log.error("relaunch failed to start: \(error.localizedDescription)")
            Toast.show("다시 시작하지 못했습니다", symbol: "exclamationmark.triangle", detail: "MacB를 종료한 뒤 직접 다시 열어 주세요")
            return
        }
        NSApp.terminate(nil)
    }
}
