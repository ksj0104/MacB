import Foundation

// 설정 파일 표기로 되돌려 쓰기. 단축키 설정 창이 기록한 키를 config.json에 저장할 때 쓴다.

public extension KeyModifiers {
    /// 설정 파일 표기(`"control+option"`). 보조키가 없으면 빈 문자열.
    var configString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("control") }
        if contains(.option) { parts.append("option") }
        if contains(.shift) { parts.append("shift") }
        if contains(.command) { parts.append("command") }
        return parts.joined(separator: "+")
    }
}

public extension KeyCombo {
    /// 설정 파일 표기(`"control+option+t"`). 설정 파일에 이름으로 적을 수 없는 키(숫자 패드 등)면 nil.
    var configString: String? {
        guard let name = KeyCombo.configName(forKeyCode: keyCode) else { return nil }
        let prefix = modifiers.configString
        return prefix.isEmpty ? name : prefix + "+" + name
    }

    /// F1–F19. 보조키 없이 혼자 단축키로 써도 되는 키.
    var isFunctionKey: Bool {
        KeyCombo.functionKeyCodes.contains(keyCode)
    }

    /// 가상 키코드 → 설정 파일에 쓰는 이름.
    static func configName(forKeyCode keyCode: UInt32) -> String? {
        namedKeys[keyCode]?.name
    }

    /// 시스템 단축키(`AppleSymbolicHotKeys`)에 적는 문자 코드. 기능 키(F키, 화살표 등)는 nil —
    /// 시스템은 그런 키를 '문자 없음'(65535)과 기능 키 표시로 적는다.
    internal static func hotKeyCharacter(forKeyCode keyCode: UInt32) -> Int? {
        namedKeys[keyCode]?.character
    }

    private static let functionKeyCodes: Set<UInt32> = Set((1...19).compactMap { keyCode(named: "f\($0)") })

    /// 설정 이름과 문자 코드. 이름은 `KeyCombo(string:)`이 읽는 대표 이름이다.
    private static let namedKeys: [UInt32: (name: String, character: Int?)] = {
        var entries: [(String, Int?)] = []
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            entries.append((String(UnicodeScalar(scalar)!), Int(scalar)))
        }
        for digit in 0...9 { entries.append((String(digit), 48 + digit)) }
        for number in 1...19 { entries.append(("f\(number)", nil)) }
        entries += [
            ("tab", 9), ("space", 32), ("return", 13), ("escape", 27), ("delete", 127),
            ("forwarddelete", nil), ("left", nil), ("right", nil), ("up", nil), ("down", nil),
            ("home", nil), ("end", nil), ("pageup", nil), ("pagedown", nil),
            ("grave", 96), ("minus", 45), ("equal", 61), ("leftbracket", 91), ("rightbracket", 93),
            ("backslash", 92), ("semicolon", 59), ("quote", 39), ("comma", 44), ("period", 46), ("slash", 47),
        ]
        var table: [UInt32: (name: String, character: Int?)] = [:]
        for (name, character) in entries {
            guard let code = keyCode(named: name) else { continue }
            table[code] = (name, character)
        }
        return table
    }()
}
