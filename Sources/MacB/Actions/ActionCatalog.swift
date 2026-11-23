import AppKit
import MacBClipboard
import MacBKit

/// 설정 파일의 항목을 실제로 실행할 수 있는 메뉴 항목으로 바꿔 준다.
@MainActor
final class ActionCatalog {
    struct BuiltIn {
        let action: BuiltInAction
        let title: String
        let subtitle: String
        let symbol: String
        /// '단축키 설정' 창 목록의 이름. 원형 메뉴 조각에는 짧은 `title`이 들어가서, 목록에서는 무엇을 하는지
        /// 혼자서도 알 수 있게 쓴다(캡처는 클립보드로인지 파일로인지). 없으면 `title`.
        var settingsTitle: String? = nil
        let perform: @MainActor () -> Void

        var id: String { action.rawValue }
    }

    /// 원형 메뉴가 읽기 편한 최대 항목 수.
    static let maximumItems = 12

    /// 메뉴 막대의 '도구' 목록에 나오는 순서.
    let builtIns: [BuiltIn]
    private let builtInsByID: [String: BuiltIn]

    init(capture: CaptureService, clipboard: ClipboardFeature) {
        // ID 목록과 순서는 MacBKit의 BuiltInAction이 정한다. 주소로 불러도 되는지도 거기서 정한다.
        let list = BuiltInAction.allCases.map { action -> BuiltIn in
            switch action {
            case .areaToClipboard:
                return BuiltIn(action: action, title: "영역 캡처", subtitle: "선택 영역을 클립보드로", symbol: "rectangle.dashed",
                               settingsTitle: "영역을 클립보드로 캡처") {
                    capture.capture(.area, to: .clipboard)
                }
            case .areaToFile:
                return BuiltIn(action: action, title: "파일로 저장", subtitle: "선택 영역을 파일로 저장", symbol: "square.and.arrow.down",
                               settingsTitle: "영역을 파일로 캡처") {
                    capture.capture(.area, to: .file)
                }
            case .windowToClipboard:
                return BuiltIn(action: action, title: "창 캡처", subtitle: "창 하나를 클립보드로", symbol: "macwindow",
                               settingsTitle: "창을 클립보드로 캡처") {
                    capture.capture(.window, to: .clipboard)
                }
            case .windowToFile:
                return BuiltIn(action: action, title: "창 저장", subtitle: "창 하나를 파일로 저장", symbol: "macwindow.badge.plus",
                               settingsTitle: "창을 파일로 캡처") {
                    capture.capture(.window, to: .file)
                }
            case .screenToClipboard:
                return BuiltIn(action: action, title: "전체 화면", subtitle: "화면 전체를 클립보드로", symbol: "display",
                               settingsTitle: "전체 화면을 클립보드로 캡처") {
                    capture.capture(.screen, to: .clipboard)
                }
            case .screenToFile:
                return BuiltIn(action: action, title: "화면 저장", subtitle: "화면 전체를 파일로 저장", symbol: "display.and.arrow.down",
                               settingsTitle: "전체 화면을 파일로 캡처") {
                    capture.capture(.screen, to: .file)
                }
            case .recognizeText:
                return BuiltIn(action: action, title: "글자 인식", subtitle: "화면 속 글자를 복사", symbol: "text.viewfinder") {
                    capture.recognizeText()
                }
            case .pickColor:
                return BuiltIn(action: action, title: "색상 추출", subtitle: "화면의 색상 코드를 복사", symbol: "eyedropper") {
                    capture.pickColor()
                }
            case .recordScreen:
                return BuiltIn(action: action, title: "화면 녹화", subtitle: "녹화 도구 막대 열기", symbol: "record.circle") {
                    capture.openRecordingToolbar()
                }
            case .clipboardHistory:
                return BuiltIn(action: action, title: "클립보드", subtitle: "복사 기록에서 붙여넣기", symbol: "list.clipboard") {
                    clipboard.togglePanel(tab: .history)
                }
            case .clipboardSlots:
                return BuiltIn(action: action, title: "슬롯", subtitle: "숫자 슬롯 보기", symbol: "square.grid.3x3") {
                    clipboard.togglePanel(tab: .slots)
                }
            }
        }
        builtIns = list
        builtInsByID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    /// 내장 기능을 ID로 실행한다. 모르는 ID면 false.
    @discardableResult
    func perform(actionID: String) -> Bool {
        guard let builtIn = builtInsByID[actionID] else { return false }
        builtIn.perform()
        return true
    }

    func resolve(_ configured: [AppConfig.RadialMenu.Item]) -> [RadialItem] {
        configured.prefix(ActionCatalog.maximumItems).enumerated().map { index, item in
            resolve(item, index: index)
        }
    }

    /// '단축키 설정' 창의 '기능 바로 실행' 줄. `builtIns`와 같은 목록·순서(`BuiltInAction.allCases`)다.
    var shortcutTools: [ShortcutSettings.Tool] {
        builtIns.map { ShortcutSettings.Tool(id: $0.id, title: $0.settingsTitle ?? $0.title, symbol: $0.symbol) }
    }

    /// 항목 하나를 실행할 수 있게 만든다. 전역 단축키(`shortcuts`)에도 쓰므로 개수 제한이 없다.
    func resolve(_ item: AppConfig.RadialMenu.Item, index: Int) -> RadialItem {
        let customIcon = item.icon.flatMap(icon(named:))

        if let actionID = item.action {
            guard let builtIn = builtInsByID[actionID] else {
                // 오타를 조용히 삼키면 왜 빠졌는지 알 수 없으니, 자리는 두고 눌렀을 때 알려 준다.
                return RadialItem(
                    id: "unknown.\(index)", title: item.title ?? "알 수 없음",
                    subtitle: actionID, icon: .symbol("questionmark.circle")
                ) {
                    Toast.show("알 수 없는 기능입니다", symbol: "questionmark.circle", detail: actionID)
                }
            }
            return RadialItem(
                id: builtIn.id,
                title: item.title ?? builtIn.title,
                subtitle: item.subtitle ?? builtIn.subtitle,
                icon: customIcon ?? .symbol(builtIn.symbol),
                perform: builtIn.perform
            )
        }

        if let app = item.app {
            let url = ActionCatalog.applicationURL(for: app)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? app
            let appIcon = url.map { RadialItem.Icon.image(NSWorkspace.shared.icon(forFile: $0.path)) }
            return RadialItem(
                id: "app.\(index)", title: item.title ?? name, subtitle: item.subtitle ?? "앱 열기",
                icon: customIcon ?? appIcon ?? .symbol("app")
            ) {
                ActionCatalog.openApplication(app)
            }
        }

        if let shell = item.shell {
            return RadialItem(
                id: "shell.\(index)", title: item.title ?? "명령", subtitle: item.subtitle ?? shell,
                icon: customIcon ?? .symbol("terminal")
            ) {
                ActionCatalog.run("/bin/zsh", ["-lc", shell], label: item.title ?? "명령")
            }
        }

        if let shortcut = item.shortcut {
            return RadialItem(
                id: "shortcut.\(index)", title: item.title ?? shortcut, subtitle: item.subtitle ?? "단축어 실행",
                icon: customIcon ?? .symbol("bolt")
            ) {
                ActionCatalog.run("/usr/bin/shortcuts", ["run", shortcut], label: shortcut)
            }
        }

        if let address = item.url {
            return RadialItem(
                id: "url.\(index)", title: item.title ?? "링크", subtitle: item.subtitle ?? address,
                icon: customIcon ?? .symbol("link")
            ) {
                guard let url = URL(string: address), NSWorkspace.shared.open(url) else {
                    Toast.show("주소를 열지 못했습니다", symbol: "exclamationmark.triangle", detail: address)
                    return
                }
            }
        }

        return RadialItem(
            id: "empty.\(index)", title: item.title ?? "빈 항목", subtitle: "설정에 실행할 내용이 없습니다",
            icon: customIcon ?? .symbol("questionmark.circle")
        ) {
            Toast.show("이 항목에는 실행할 내용이 없습니다", symbol: "questionmark.circle", detail: "config.json을 확인하세요")
        }
    }

    /// SF Symbols 이름이면 심볼, 아니면 이모지 같은 글자로 본다.
    private func icon(named name: String) -> RadialItem.Icon? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if NSImage(systemSymbolName: trimmed, accessibilityDescription: nil) != nil {
            return .symbol(trimmed)
        }
        return .text(String(trimmed.prefix(2)))
    }

    // MARK: Custom actions

    /// 이름("Safari"), 번들 ID("com.apple.Safari"), 또는 경로로 앱을 찾는다.
    static func applicationURL(for reference: String) -> URL? {
        let workspace = NSWorkspace.shared
        let expanded = (reference as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        if let url = workspace.urlForApplication(withBundleIdentifier: reference) {
            return url
        }
        let fileName = reference.hasSuffix(".app") ? reference : "\(reference).app"
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/Applications/Utilities", ("~/Applications" as NSString).expandingTildeInPath,
        ]
        for folder in folders {
            let path = (folder as NSString).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func openApplication(_ reference: String) {
        guard let url = applicationURL(for: reference) else {
            Toast.show("앱을 찾지 못했습니다", symbol: "exclamationmark.triangle", detail: reference)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Log.error("open app failed: \(error.localizedDescription)")
        }
    }

    private static func run(_ executable: String, _ arguments: [String], label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            guard status != 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Toast.show("실행에 실패했습니다 (종료 코드 \(status))", symbol: "exclamationmark.triangle", detail: label)
                }
            }
        }
        do {
            try process.run()
        } catch {
            Toast.show("실행하지 못했습니다", symbol: "exclamationmark.triangle", detail: label)
        }
    }
}
