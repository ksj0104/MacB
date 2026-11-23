import Foundation

/// '단축키 설정' 창의 편집 논리. 설정을 받아 줄 목록을 만들고, 편집 하나를 적용한 새 설정을 돌려준다.
/// 창은 이것을 그리기만 하고, 바뀐 설정은 앱이 반영·저장한다.
public struct ShortcutSettings {
    /// 내장 기능의 이름과 아이콘. 앱의 기능 목록(`ActionCatalog`)이 정하고, 이 순서대로 줄을 만든다.
    public struct Tool: Equatable, Sendable {
        public var id: String
        public var title: String
        public var symbol: String

        public init(id: String, title: String, symbol: String) {
            self.id = id
            self.title = title
            self.symbol = symbol
        }
    }

    /// 단축키 칸 하나가 가리키는 설정.
    public enum Field: Hashable, Sendable {
        case radialMenu
        case clipboardHistory
        case slotPaste
        case slotCopy
        /// 한영 전환 키를 '직접 지정'으로 고른 경우의 키 조합.
        case inputSwitch
        /// 내장 기능 하나. `shortcuts`에서 그 기능을 가리키는 첫 항목이다.
        case tool(String)
        /// `shortcuts`의 몇 번째 항목(앱, 그 밖의 항목).
        case entry(Int)
    }

    /// 칸에 보이는 값.
    public enum Value: Equatable, Sendable {
        /// 비어 있음(꺼짐).
        case none
        case combo(KeyCombo)
        /// 보조키만 정하는 칸(숫자 슬롯). 숫자는 1–9 모두.
        case modifiers(KeyModifiers)
        /// 설정에 적힌 글을 해석하지 못했다.
        case invalid(String)
    }

    /// 칸이 받는 입력.
    public enum Recording: Sendable {
        case combo
        case modifiers
    }

    public struct Row: Equatable, Sendable {
        public var field: Field
        public var title: String
        public var detail: String?
        /// SF Symbols 이름.
        public var symbol: String?
        /// 앱 줄이면 설정에 적힌 앱(이름, 번들 ID, 경로).
        public var app: String?
        public var recording: Recording
        public var value: Value
        /// 줄을 지울 수 있는지(앱 줄).
        public var isRemovable: Bool

        init(
            field: Field, title: String, detail: String? = nil, symbol: String?, app: String? = nil,
            recording: Recording, value: Value, isRemovable: Bool = false
        ) {
            self.field = field
            self.title = title
            self.detail = detail
            self.symbol = symbol
            self.app = app
            self.recording = recording
            self.value = value
            self.isRemovable = isRemovable
        }
    }

    public enum Edit: Equatable, Sendable {
        case setInputSwitchEnabled(Bool)
        case setInputSwitchKey(InputSwitchKey)
        /// nil이면 지운다.
        case setCombo(Field, KeyCombo?)
        /// nil이면 지운다(끔).
        case setModifiers(Field, KeyModifiers?)
        /// 단축키 없는 앱 줄을 더한다. 단축키는 이어서 `setCombo(.entry(…))`로 정한다.
        case addApp(reference: String, title: String?)
        case remove(Field)
    }

    /// 편집을 받아들이지 않은 이유. 창은 그 칸 아래에 `message`를 보여 준다.
    public enum Refusal: Error, Equatable, Sendable {
        /// ⌃ ⌥ ⌘ 중 하나가 없다(F키는 예외).
        case needsModifier
        /// 숫자 슬롯의 보조키에 ⌃ ⌥ ⌘ 중 하나가 없다.
        case needsSlotModifier
        /// 한영 전환 키 조합에 ⌃나 ⌘가 없다(⇧Space와 F키는 예외). 입력 소스 단축키는 MacB를 꺼도 남으므로
        /// 글자를 치는 조합(⇧A, ⌥E 등)이나 편집 키(⇧Tab, ⇧Return 등)를 잡으면 어디서도 그 키를 칠 수 없게 된다.
        case inputSwitchNeedsModifier
        /// 설정 파일에 이름으로 적을 수 없는 키.
        case unsupportedKey
        /// 다른 MacB 단축키가 이미 쓰고 있다. 값은 그 기능의 이름.
        case inUse(String)
        /// 이 칸에는 할 수 없는 편집.
        case notEditable
        /// 모든 앱이나 macOS가 늘 쓰는 조합이다. `shortcut`은 보여 줄 표기, `reason`은 "Spotlight 단축키"처럼 무엇인지.
        case reserved(shortcut: String, reason: String)

        public var message: String {
            switch self {
            case .needsModifier: return "⌃ ⌥ ⌘ 중 하나와 함께 눌러 주세요 (F1–F19는 혼자 써도 됩니다)"
            case .needsSlotModifier: return "⌃ ⌥ ⌘ 중 하나를 누른 채 숫자를 눌러 주세요"
            case .inputSwitchNeedsModifier: return "⌃나 ⌘와 함께 눌러 주세요 — 글자를 치는 조합은 쓸 수 없습니다 (⇧Space와 F1–F19는 됩니다)"
            case .unsupportedKey: return "이 키는 단축키로 쓸 수 없습니다"
            case .inUse(let owner): return "'\(owner)'에서 이미 쓰고 있습니다"
            case .notEditable: return "여기서는 바꿀 수 없습니다 — config.json에서 고쳐 주세요"
            case .reserved(let shortcut, let reason): return "\(reason)라 쓸 수 없습니다 (\(shortcut))"
            }
        }
    }

    /// 숫자 슬롯 번호. 슬롯 단축키는 보조키 + 이 숫자들이다.
    public static let slotDigits = 1...9

    public let config: AppConfig
    public let tools: [Tool]

    private enum EntryKind: Equatable {
        case tool(String)
        case app
        case other
    }

    private let entryKinds: [EntryKind]
    private let toolEntries: [String: Int]

    public init(config: AppConfig, tools: [Tool]) {
        self.config = config
        self.tools = tools
        let toolIDs = Set(tools.map(\.id))
        var kinds: [EntryKind] = []
        var toolEntries: [String: Int] = [:]
        for (index, shortcut) in config.shortcuts.enumerated() {
            let item = shortcut.item
            // 실행할 때와 같은 순서로 종류를 본다(action → app → shell → shortcut → url).
            if let action = item.action {
                if toolIDs.contains(action), toolEntries[action] == nil {
                    toolEntries[action] = index
                    kinds.append(.tool(action))
                } else {
                    kinds.append(.other)
                }
            } else if item.app != nil {
                kinds.append(.app)
            } else {
                kinds.append(.other)
            }
        }
        entryKinds = kinds
        self.toolEntries = toolEntries
    }

    // MARK: Rows

    public var inputSwitchEnabled: Bool {
        config.keyboard.inputSwitch.enabled
    }

    /// 설정의 한영 전환 키. 해석할 수 없으면 nil.
    public var inputSwitchKey: InputSwitchKey? {
        InputSwitchKey(configValue: config.keyboard.inputSwitch.key)
    }

    public var basicRows: [Row] {
        let hotkeys = config.hotkeys
        return [
            Row(field: .radialMenu, title: title(of: .radialMenu), symbol: "circle.grid.cross",
                recording: .combo, value: Self.comboValue(hotkeys.radialMenu)),
            Row(field: .clipboardHistory, title: title(of: .clipboardHistory), symbol: "list.clipboard",
                recording: .combo, value: Self.comboValue(hotkeys.clipboardHistory)),
            Row(field: .slotPaste, title: title(of: .slotPaste), symbol: "doc.on.clipboard",
                recording: .modifiers, value: Self.modifiersValue(hotkeys.slotPasteModifiers)),
            Row(field: .slotCopy, title: title(of: .slotCopy), symbol: "square.grid.3x3",
                recording: .modifiers, value: Self.modifiersValue(hotkeys.slotCopyModifiers)),
        ]
    }

    /// 내장 기능마다 한 줄.
    public var toolRows: [Row] {
        tools.map { tool in
            let value = toolEntries[tool.id].map { Self.comboValue(config.shortcuts[$0].key) } ?? .none
            return Row(field: .tool(tool.id), title: tool.title, symbol: tool.symbol, recording: .combo, value: value)
        }
    }

    /// 앱 실행 단축키.
    public var appRows: [Row] {
        config.shortcuts.indices.filter { entryKinds[$0] == .app }.map { index in
            let item = config.shortcuts[index].item
            return Row(
                field: .entry(index), title: title(of: .entry(index)), symbol: item.icon, app: item.app,
                recording: .combo, value: Self.comboValue(config.shortcuts[index].key), isRemovable: true
            )
        }
    }

    /// 창에서 단축키만 바꿀 수 있는 항목(명령, 단축어, 링크, 모르는 기능 등). 나머지는 config.json에서 고친다.
    public var otherRows: [Row] {
        config.shortcuts.indices.filter { entryKinds[$0] == .other }.map { index in
            let item = config.shortcuts[index].item
            let detail: String
            let symbol: String
            if let action = item.action {
                if let tool = tools.first(where: { $0.id == action }) {
                    detail = "\(tool.title)의 다른 단축키"
                    symbol = tool.symbol
                } else {
                    detail = "알 수 없는 기능: \(action)"
                    symbol = "questionmark.circle"
                }
            } else if let shell = item.shell {
                detail = shell
                symbol = "terminal"
            } else if item.shortcut != nil {
                detail = "단축어 실행"
                symbol = "bolt"
            } else if let url = item.url {
                detail = url
                symbol = "link"
            } else {
                detail = "실행할 내용이 없습니다"
                symbol = "questionmark.circle"
            }
            return Row(
                field: .entry(index), title: title(of: .entry(index)), detail: detail, symbol: item.icon ?? symbol,
                recording: .combo, value: Self.comboValue(config.shortcuts[index].key)
            )
        }
    }

    /// 겹침 안내에 쓰는 기능 이름.
    public func title(of field: Field) -> String {
        switch field {
        case .radialMenu: return "원형 메뉴"
        case .clipboardHistory: return "클립보드 기록"
        case .slotPaste: return "슬롯 붙여넣기"
        case .slotCopy: return "슬롯에 복사"
        case .inputSwitch: return "한영 전환"
        case .tool(let id):
            return tools.first { $0.id == id }?.title ?? id
        case .entry(let index):
            guard config.shortcuts.indices.contains(index) else { return "항목" }
            let item = config.shortcuts[index].item
            if let title = item.title, !title.isEmpty { return title }
            if let action = item.action { return tools.first { $0.id == action }?.title ?? action }
            if let app = item.app { return Self.appName(app) }
            if item.shell != nil { return "명령" }
            if let shortcut = item.shortcut { return shortcut }
            if item.url != nil { return "링크" }
            return "빈 항목"
        }
    }

    // MARK: Editing

    /// 편집 하나를 적용한 새 설정. 받아들일 수 없으면 그 이유.
    public func applying(_ edit: Edit) -> Result<AppConfig, Refusal> {
        var next = config
        switch edit {
        case .setInputSwitchEnabled(let enabled):
            if enabled, let key = inputSwitchKey, let owner = conflict(forInputSwitch: key) {
                return .failure(.inUse(owner))
            }
            next.keyboard.inputSwitch.enabled = enabled

        case .setInputSwitchKey(let key):
            if case .combo(let combo) = key, let refusal = validate(combo, for: .inputSwitch) {
                return .failure(refusal)
            }
            if let owner = conflict(forInputSwitch: key) { return .failure(.inUse(owner)) }
            guard let value = key.configValue else { return .failure(.unsupportedKey) }
            next.keyboard.inputSwitch.key = value

        case .setCombo(let field, let combo):
            if let combo, let refusal = validate(combo, for: field) { return .failure(refusal) }
            let text = combo?.configString ?? ""
            switch field {
            case .radialMenu:
                next.hotkeys.radialMenu = text
            case .clipboardHistory:
                next.hotkeys.clipboardHistory = text
            case .inputSwitch:
                guard let combo else { return .failure(.notEditable) }
                return applying(.setInputSwitchKey(.combo(combo)))
            case .tool(let id):
                if let index = toolEntries[id] {
                    if combo == nil {
                        next.shortcuts.remove(at: index)
                    } else {
                        next.shortcuts[index].key = text
                    }
                } else if combo != nil {
                    next.shortcuts.append(AppConfig.Shortcut(key: text, item: .init(action: id)))
                }
            case .entry(let index):
                guard next.shortcuts.indices.contains(index) else { return .failure(.notEditable) }
                next.shortcuts[index].key = text
            case .slotPaste, .slotCopy:
                return .failure(.notEditable)
            }

        case .setModifiers(let field, let modifiers):
            guard field == .slotPaste || field == .slotCopy else { return .failure(.notEditable) }
            if let modifiers {
                guard !modifiers.isDisjoint(with: [.control, .option, .command]) else { return .failure(.needsSlotModifier) }
                // ⌘1–9는 브라우저 탭 등 모든 앱이, ⇧⌘3·4·5는 macOS 스크린샷이 쓴다.
                if modifiers == [.command] {
                    return .failure(.reserved(shortcut: "⌘ + 숫자", reason: "모든 앱이 쓰는 단축키"))
                }
                if modifiers == [.command, .shift] {
                    return .failure(.reserved(shortcut: "⇧⌘ + 숫자", reason: "macOS 스크린샷 단축키"))
                }
                if let owner = conflict(forSlotModifiers: modifiers, excluding: field) { return .failure(.inUse(owner)) }
            }
            let text = modifiers?.configString ?? ""
            if field == .slotPaste {
                next.hotkeys.slotPasteModifiers = text
            } else {
                next.hotkeys.slotCopyModifiers = text
            }

        case .addApp(let reference, let title):
            next.shortcuts.append(AppConfig.Shortcut(key: "", item: .init(title: title, app: reference)))

        case .remove(let field):
            switch field {
            case .entry(let index):
                guard next.shortcuts.indices.contains(index) else { return .failure(.notEditable) }
                next.shortcuts.remove(at: index)
            case .tool:
                return applying(.setCombo(field, nil))
            default:
                return .failure(.notEditable)
            }
        }
        return .success(next)
    }

    // MARK: Validation

    private func validate(_ combo: KeyCombo, for field: Field) -> Refusal? {
        if field == .inputSwitch {
            if let refusal = Self.inputSwitchRefusal(for: combo) { return refusal }
        } else {
            guard combo.configString != nil else { return .unsupportedKey }
            if !combo.isFunctionKey, combo.modifiers.isDisjoint(with: [.control, .option, .command]) {
                return .needsModifier
            }
            if let refusal = Self.reservedRefusal(for: combo) { return refusal }
        }
        if let owner = conflict(for: combo, excluding: field) { return .inUse(owner) }
        return nil
    }

    /// 한영 전환 키 조합으로 쓸 수 없으면 그 이유(다른 MacB 단축키와 겹치는지는 보지 않는다).
    /// 이 조합은 macOS의 입력 소스 단축키가 되어 MacB를 꺼도 남으므로, 글자를 치거나 늘 쓰는 키는 받지 않는다.
    /// ⇧Space는 예부터 쓰던 한/영 전환 조합이라 예외로 둔다. config.json을 손으로 고친 경우에도 같은 규칙을 쓴다.
    public static func inputSwitchRefusal(for combo: KeyCombo) -> Refusal? {
        guard combo.configString != nil else { return .unsupportedKey }
        if !combo.isFunctionKey, combo.modifiers.isDisjoint(with: [.control, .command]) {
            let isShiftSpace = combo.modifiers == [.shift] && KeyCombo.configName(forKeyCode: combo.keyCode) == "space"
            if !isShiftSpace { return .inputSwitchNeedsModifier }
        }
        // ⌃ + 글자(⇧ 포함)는 터미널(⌃C 중단)과 모든 글 입력 칸(⌃A·⌃E 줄 처음·끝)이 쓴다. ⌃Space·⌃⇧Space는 그대로 받는다.
        if combo.modifiers == [.control] || combo.modifiers == [.control, .shift],
           let name = KeyCombo.configName(forKeyCode: combo.keyCode), name.count == 1, name.first?.isLetter == true {
            return .reserved(shortcut: combo.displayString, reason: "터미널과 글 입력 칸에서 늘 쓰는 키")
        }
        return reservedRefusal(for: combo)
    }

    /// 모든 앱이나 macOS가 늘 쓰는 조합이면 그 이유. 전역 단축키로 잡으면 그 기능이 어느 앱에서도 동작하지 않는다.
    public static func reservedRefusal(for combo: KeyCombo) -> Refusal? {
        guard let name = KeyCombo.configName(forKeyCode: combo.keyCode) else { return nil }
        let modifiers = combo.modifiers
        let reason: String?
        if let system = systemShortcuts[combo] {
            reason = system
        } else if modifiers == [.command], name.count == 1 || Self.punctuationKeys.contains(name) {
            // ⌘ + 글자·숫자·문장부호: 복사·붙여넣기·닫기·종료·탭 전환처럼 앱마다 쓴다.
            reason = "모든 앱이 쓰는 단축키"
        } else if ["left", "right", "up", "down"].contains(name) {
            if modifiers == [.control] {
                reason = "Mission Control 단축키"
            } else if !modifiers.isEmpty, modifiers.isSubset(of: [.command, .option, .shift]) {
                reason = "글자 편집·이동에 늘 쓰는 키"
            } else {
                reason = nil
            }
        } else if ["delete", "forwarddelete"].contains(name), !modifiers.isEmpty, modifiers.isSubset(of: [.command, .option, .shift]) {
            reason = "글자 편집에 늘 쓰는 키"
        } else {
            reason = nil
        }
        return reason.map { .reserved(shortcut: combo.displayString, reason: $0) }
    }

    /// 한 글자가 아닌 이름을 가진 문장부호 키.
    private static let punctuationKeys: Set<String> = [
        "grave", "minus", "equal", "leftbracket", "rightbracket", "backslash", "semicolon", "quote", "comma", "period", "slash",
    ]

    /// macOS나 모든 앱이 쓰는 조합 중 위의 규칙으로 잡히지 않는 것.
    private static let systemShortcuts: [KeyCombo: String] = {
        let table: [(String, String)] = [
            ("command+space", "Spotlight 단축키"),
            ("option+command+space", "Finder 검색 단축키"),
            ("control+command+space", "문자 뷰어(이모지) 단축키"),
            ("command+tab", "앱 전환 단축키"),
            ("shift+command+tab", "앱 전환 단축키"),
            ("control+tab", "탭 전환에 모든 앱이 쓰는 단축키"),
            ("control+shift+tab", "탭 전환에 모든 앱이 쓰는 단축키"),
            ("shift+command+3", "macOS 스크린샷 단축키"),
            ("shift+command+4", "macOS 스크린샷 단축키"),
            ("shift+command+5", "macOS 스크린샷 단축키"),
            ("option+command+escape", "강제 종료 단축키"),
            ("control+command+q", "화면 잠금 단축키"),
            ("shift+command+q", "로그아웃 단축키"),
            ("control+command+f", "전체 화면 단축키"),
            ("shift+command+z", "모든 앱이 쓰는 단축키"),
            ("option+command+h", "모든 앱이 쓰는 단축키"),
            ("option+command+d", "Dock 가리기 단축키"),
        ]
        var result: [KeyCombo: String] = [:]
        for (text, reason) in table {
            if let combo = KeyCombo(string: text) { result[combo] = reason }
        }
        return result
    }()

    /// 지금 쓰이고 있는 키 조합과 그 주인. 숫자 슬롯은 따로 본다.
    private var assignedCombos: [(field: Field, combo: KeyCombo)] {
        var result: [(Field, KeyCombo)] = []
        if let combo = KeyCombo(string: config.hotkeys.radialMenu) { result.append((.radialMenu, combo)) }
        if let combo = KeyCombo(string: config.hotkeys.clipboardHistory) { result.append((.clipboardHistory, combo)) }
        if inputSwitchEnabled, let key = inputSwitchKey {
            result.append((.inputSwitch, Self.inputSwitchCombo(key)))
        }
        for (index, shortcut) in config.shortcuts.enumerated() {
            guard let combo = KeyCombo(string: shortcut.key) else { continue }
            if case .tool(let id) = entryKinds[index] {
                result.append((.tool(id), combo))
            } else {
                result.append((.entry(index), combo))
            }
        }
        return result
    }

    private var assignedSlotModifiers: [(field: Field, modifiers: KeyModifiers)] {
        var result: [(Field, KeyModifiers)] = []
        if let modifiers = KeyModifiers(string: config.hotkeys.slotPasteModifiers) { result.append((.slotPaste, modifiers)) }
        if let modifiers = KeyModifiers(string: config.hotkeys.slotCopyModifiers) { result.append((.slotCopy, modifiers)) }
        return result
    }

    private func conflict(for combo: KeyCombo, excluding field: Field) -> String? {
        if let owner = assignedCombos.first(where: { $0.field != field && $0.combo == combo }) {
            return title(of: owner.field)
        }
        if let digit = KeyCombo.digit(forKeyCode: combo.keyCode), Self.slotDigits.contains(digit),
           let owner = assignedSlotModifiers.first(where: { $0.field != field && $0.modifiers == combo.modifiers }) {
            return title(of: owner.field)
        }
        return nil
    }

    private func conflict(forSlotModifiers modifiers: KeyModifiers, excluding field: Field) -> String? {
        if let owner = assignedSlotModifiers.first(where: { $0.field != field && $0.modifiers == modifiers }) {
            return title(of: owner.field)
        }
        let digitCodes = Set(Self.slotDigits.compactMap(KeyCombo.digitKeyCode))
        if let owner = assignedCombos.first(where: { $0.combo.modifiers == modifiers && digitCodes.contains($0.combo.keyCode) }) {
            return title(of: owner.field)
        }
        return nil
    }

    private func conflict(forInputSwitch key: InputSwitchKey) -> String? {
        conflict(for: Self.inputSwitchCombo(key), excluding: .inputSwitch)
    }

    /// 한영 전환이 차지하는 키 조합. 보조키 하나를 쓰는 방식은 그 키가 F18로 들어온다.
    private static func inputSwitchCombo(_ key: InputSwitchKey) -> KeyCombo {
        switch key {
        case .combo(let combo):
            return combo
        case .rightCommand, .rightOption:
            return KeyCombo(keyCode: UInt32(HotKeyParameters.f18.keyCode), modifiers: [])
        }
    }

    // MARK: Values

    static func comboValue(_ text: String) -> Value {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .none }
        return KeyCombo(string: trimmed).map(Value.combo) ?? .invalid(trimmed)
    }

    static func modifiersValue(_ text: String) -> Value {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .none }
        return KeyModifiers(string: trimmed).map(Value.modifiers) ?? .invalid(trimmed)
    }

    /// 설정에 적힌 앱 참조의 짧은 이름: 경로면 파일 이름, 아니면 그대로.
    static func appName(_ reference: String) -> String {
        guard reference.contains("/") else { return reference }
        let name = (reference as NSString).lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
