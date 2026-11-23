import AppKit
import MacBKit
import ServiceManagement

/// 메뉴 막대 아이콘과 그 메뉴. 열 때마다 현재 상태(권한, 단축키, 자동 실행)를 반영해 새로 만든다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    struct Handlers {
        var openRadialMenu: @MainActor () -> Void
        var openClipboard: @MainActor () -> Void
        var openSlots: @MainActor () -> Void
        var runTool: @MainActor (String) -> Void
        var reloadConfig: @MainActor () -> Void
        var clearClipboard: @MainActor () -> Void
        var relaunch: @MainActor () -> Void
        var toggleInputSwitch: @MainActor () -> Void
        var openShortcutSettings: @MainActor () -> Void
    }

    var hotkeys = AppConfig.Hotkeys()
    var keyboard = AppConfig.Keyboard()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let tools: [ActionCatalog.BuiltIn]
    private let handlers: Handlers

    init(tools: [ActionCatalog.BuiltIn], handlers: Handlers) {
        self.tools = tools
        self.handlers = handlers
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: "MacB")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "◎" }
            button.toolTip = "MacB"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let handlers = self.handlers

        let radial = ActionMenuItem("원형 메뉴 열기", symbol: "circle.grid.cross", handler: handlers.openRadialMenu)
        showShortcut(KeyCombo(string: hotkeys.radialMenu), on: radial)
        menu.addItem(radial)

        let clipboard = ActionMenuItem("클립보드 기록", symbol: "list.clipboard", handler: handlers.openClipboard)
        showShortcut(KeyCombo(string: hotkeys.clipboardHistory), on: clipboard)
        menu.addItem(clipboard)

        menu.addItem(ActionMenuItem("숫자 슬롯", symbol: "square.grid.3x3", handler: handlers.openSlots))

        if let hint = slotHint() {
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let toolsItem = NSMenuItem(title: "도구", action: nil, keyEquivalent: "")
        toolsItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        let toolsMenu = NSMenu()
        for tool in tools {
            let id = tool.id
            toolsMenu.addItem(ActionMenuItem(tool.title + " — " + tool.subtitle, symbol: tool.symbol) {
                handlers.runTool(id)
            })
        }
        toolsItem.submenu = toolsMenu
        menu.addItem(toolsItem)

        menu.addItem(.separator())
        // 체크 표시는 설정 값이다. 실제로 적용됐는지는 켜고 끌 때 알림과 '단축키 설정' 창의 상태 줄이 알려 준다.
        let inputSwitch = keyboard.inputSwitch
        let keyName = InputSwitchKey(configValue: inputSwitch.key)?.displayName ?? "설정 확인 필요"
        let inputSwitchItem = ActionMenuItem("한영 전환 키 (\(keyName))", symbol: "globe", handler: handlers.toggleInputSwitch)
        inputSwitchItem.state = inputSwitch.enabled ? .on : .off
        menu.addItem(inputSwitchItem)
        menu.addItem(ActionMenuItem("단축키 설정…", symbol: "keyboard", handler: handlers.openShortcutSettings))
        menu.addItem(ActionMenuItem("권한 설정…", symbol: "lock.shield") { PermissionGuide.shared.show() })

        let missingScreen = !Permissions.hasScreenCapture
        let missingAccessibility = !Permissions.hasAccessibility
        if missingScreen || missingAccessibility {
            menu.addItem(.separator())
            // 바로 시스템에 묻지 않고 권한 안내 창을 그 권한에 맞춰 연다. 요청과 설정 열기는 창의 버튼이 한다.
            if missingScreen {
                menu.addItem(ActionMenuItem("화면 기록 권한 허용하기… (스크린샷)", symbol: "exclamationmark.triangle") {
                    PermissionGuide.shared.show(focus: .screenCapture)
                })
            }
            if missingAccessibility {
                menu.addItem(ActionMenuItem("손쉬운 사용 권한 허용하기… (자동 붙여넣기)", symbol: "exclamationmark.triangle") {
                    PermissionGuide.shared.show(focus: .accessibility)
                })
            }
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("설정 파일 열기…", symbol: "doc.text") {
            NSWorkspace.shared.open(AppPaths.configFile)
        })
        menu.addItem(ActionMenuItem("설정 폴더 보기", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configFile])
        })
        menu.addItem(ActionMenuItem("설정 다시 불러오기", symbol: "arrow.clockwise", handler: handlers.reloadConfig))
        menu.addItem(ActionMenuItem("클립보드 기록 지우기", symbol: "trash", handler: handlers.clearClipboard))

        // 체크 표시는 시스템이 알려 주는 실제 상태를 그대로 보여 준다.
        let loginStatus = SMAppService.mainApp.status
        let needsApproval = loginStatus == .requiresApproval
        let login = ActionMenuItem(
            needsApproval ? "로그인할 때 자동 실행 (시스템 설정에서 허용 필요)" : "로그인할 때 자동 실행", symbol: nil
        ) { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        switch loginStatus {
        case .enabled: login.state = .on
        case .requiresApproval: login.state = .mixed
        default: login.state = .off
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("MacB 다시 시작", symbol: nil, handler: handlers.relaunch))
        let quit = ActionMenuItem("MacB 종료", symbol: nil) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func slotHint() -> String? {
        let copy = KeyModifiers(string: hotkeys.slotCopyModifiers)?.displayString
        let paste = KeyModifiers(string: hotkeys.slotPasteModifiers)?.displayString
        switch (copy, paste) {
        case let (copy?, paste?): return "    \(copy)1–9 슬롯에 복사 · \(paste)1–9 붙여넣기"
        case let (copy?, nil): return "    \(copy)1–9 슬롯에 복사"
        case let (nil, paste?): return "    \(paste)1–9 슬롯 붙여넣기"
        case (nil, nil): return nil
        }
    }

    /// 메뉴 오른쪽에 전역 단축키를 표시한다(표시할 수 있는 키만).
    private func showShortcut(_ combo: KeyCombo?, on item: NSMenuItem) {
        guard let combo, let name = KeyCombo.displayName(forKeyCode: combo.keyCode) else { return }
        let key: String
        switch name {
        case "⇥": key = "\t"
        case "Space": key = " "
        case "↩": key = "\r"
        default:
            guard name.count == 1 else { return }
            key = name.lowercased()
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = combo.modifiers.eventFlags
    }

    // MARK: Launch at login

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            do {
                try service.unregister()
                Toast.show("자동 실행을 껐습니다", symbol: "power")
            } catch {
                reportLoginItemError(error, message: "자동 실행을 끄지 못했습니다")
            }
        case .requiresApproval:
            // 등록은 되어 있고 사용자의 허용만 남았다. 켜고 끄는 것은 시스템 설정에서 한다.
            askForLoginItemApproval()
        default:
            do {
                try service.register()
            } catch {
                reportLoginItemError(error, message: "자동 실행을 켜지 못했습니다")
                return
            }
            switch service.status {
            case .enabled:
                Toast.show("로그인할 때 자동으로 실행합니다", symbol: "power")
            case .requiresApproval:
                askForLoginItemApproval()
            default:
                Log.error("launch at login: register returned but status is \(service.status.rawValue)")
                Toast.show(
                    "자동 실행이 켜지지 않았습니다", symbol: "exclamationmark.triangle",
                    detail: "MacB.app을 응용 프로그램 폴더로 옮긴 뒤 다시 시도해 보세요", duration: 5
                )
            }
        }
    }

    /// 사용자가 방금 메뉴를 눌렀으므로 설정 화면을 바로 열어 준다.
    private func askForLoginItemApproval() {
        Log.info("launch at login: requires approval")
        SMAppService.openSystemSettingsLoginItems()
        Toast.show(
            "시스템 설정에서 MacB를 허용해 주세요", symbol: "power",
            detail: "일반 › 로그인 항목에서 MacB를 켜 주세요", duration: 6
        )
    }

    private func reportLoginItemError(_ error: Error, message: String) {
        let nsError = error as NSError
        Log.error("launch at login: \(message) — \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
        Toast.show(message, symbol: "exclamationmark.triangle", detail: nsError.localizedDescription, duration: 6)
    }
}

/// 클로저로 동작하는 메뉴 항목.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String?, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
