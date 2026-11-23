import AppKit
import Carbon.HIToolbox

/// 보조키 집합. 설정 파일에서는 `"control+option"`처럼 쓴다.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    private static let tokens: [String: KeyModifiers] = [
        "control": .control, "ctrl": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "command": .command, "cmd": .command, "⌘": .command,
    ]

    static func modifier(forToken token: String) -> KeyModifiers? {
        tokens[token]
    }

    /// `"control+option"` → `[.control, .option]`. 비어 있거나 보조키가 아닌 토큰이 섞이면 nil.
    public init?(string: String) {
        let parts = KeyCombo.tokens(in: string)
        guard !parts.isEmpty else { return nil }
        var result: KeyModifiers = []
        for part in parts {
            guard let modifier = KeyModifiers.tokens[part] else { return nil }
            result.insert(modifier)
        }
        self = result
    }

    public init(eventFlags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.shift) { result.insert(.shift) }
        if eventFlags.contains(.command) { result.insert(.command) }
        self = result
    }

    public var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Carbon `RegisterEventHotKey`용 플래그.
    public var carbonFlags: UInt32 {
        var flags = 0
        if contains(.control) { flags |= controlKey }
        if contains(.option) { flags |= optionKey }
        if contains(.shift) { flags |= shiftKey }
        if contains(.command) { flags |= cmdKey }
        return UInt32(flags)
    }

    /// 표준 순서(⌃⌥⇧⌘)의 기호 문자열.
    public var displayString: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// 전역 단축키 하나. 설정 파일에서는 `"option+tab"`처럼 쓴다.
public struct KeyCombo: Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers

    public init(keyCode: UInt32, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// `"option+tab"`, `"cmd+shift+4"` 등. 보조키가 아닌 토큰이 정확히 하나 있어야 한다.
    public init?(string: String) {
        var modifiers: KeyModifiers = []
        var keyCode: UInt32?
        for part in KeyCombo.tokens(in: string) {
            if let modifier = KeyModifiers.modifier(forToken: part) {
                modifiers.insert(modifier)
            } else if let code = KeyCombo.keyCode(named: part), keyCode == nil {
                keyCode = code
            } else {
                return nil
            }
        }
        guard let keyCode else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    public var displayString: String {
        modifiers.displayString + (KeyCombo.displayName(forKeyCode: keyCode) ?? "#\(keyCode)")
    }

    static func tokens(in string: String) -> [String] {
        string.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Key tables

    public static func keyCode(named name: String) -> UInt32? {
        keyTable[name.lowercased()].map { UInt32($0.code) }
    }

    public static func displayName(forKeyCode keyCode: UInt32) -> String? {
        displayTable[Int(keyCode)]
    }

    /// 숫자 키(0–9)의 가상 키코드.
    public static func digitKeyCode(_ digit: Int) -> UInt32? {
        guard (0...9).contains(digit) else { return nil }
        return keyCode(named: String(digit))
    }

    /// 가상 키코드가 숫자 키면 그 숫자.
    public static func digit(forKeyCode keyCode: UInt32) -> Int? {
        (0...9).first { digitKeyCode($0) == keyCode }
    }

    private static let keyTable: [String: (code: Int, display: String)] = {
        var table: [String: (code: Int, display: String)] = [:]
        func add(_ names: [String], _ code: Int, _ display: String) {
            for name in names { table[name] = (code, display) }
        }
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        for (name, code) in letters { add([name], code, name.uppercased()) }
        let digits = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        for (digit, code) in digits.enumerated() { add([String(digit)], code, String(digit)) }
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
        ]
        for (index, code) in functionKeys.enumerated() { add(["f\(index + 1)"], code, "F\(index + 1)") }

        add(["tab"], kVK_Tab, "⇥")
        add(["space", "spacebar"], kVK_Space, "Space")
        add(["return", "enter"], kVK_Return, "↩")
        add(["escape", "esc"], kVK_Escape, "⎋")
        add(["delete", "backspace"], kVK_Delete, "⌫")
        add(["forwarddelete"], kVK_ForwardDelete, "⌦")
        add(["left"], kVK_LeftArrow, "←")
        add(["right"], kVK_RightArrow, "→")
        add(["up"], kVK_UpArrow, "↑")
        add(["down"], kVK_DownArrow, "↓")
        add(["home"], kVK_Home, "↖")
        add(["end"], kVK_End, "↘")
        add(["pageup"], kVK_PageUp, "⇞")
        add(["pagedown"], kVK_PageDown, "⇟")
        add(["grave", "backtick", "`"], kVK_ANSI_Grave, "`")
        add(["minus", "-"], kVK_ANSI_Minus, "-")
        add(["equal", "plus", "="], kVK_ANSI_Equal, "=")
        add(["leftbracket", "["], kVK_ANSI_LeftBracket, "[")
        add(["rightbracket", "]"], kVK_ANSI_RightBracket, "]")
        add(["backslash", "\\"], kVK_ANSI_Backslash, "\\")
        add(["semicolon", ";"], kVK_ANSI_Semicolon, ";")
        add(["quote", "'"], kVK_ANSI_Quote, "'")
        add(["comma", ","], kVK_ANSI_Comma, ",")
        add(["period", "."], kVK_ANSI_Period, ".")
        add(["slash", "/"], kVK_ANSI_Slash, "/")
        return table
    }()

    private static let displayTable: [Int: String] = {
        var table: [Int: String] = [:]
        for entry in keyTable.values { table[entry.code] = entry.display }
        return table
    }()
}
