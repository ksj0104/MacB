import Foundation

// MARK: - 한영 전환 키

/// 한/영 전환에 쓸 키.
///
/// macOS에는 뒤에서 한글 입력기로 확실히 바꿔 주는 API가 없다(`TISSelectInputSource`는 한글·일본어 입력기를
/// 반쯤만 바꿔 놓는 일이 있다). 그래서 전환은 시스템에 맡긴다.
/// - 오른쪽 Command/Option처럼 보조키 하나: 그 키를 HID 단계에서 F18로 바꾸고, 시스템 단축키
///   '이전 입력 소스 선택'(60번)을 F18로 돌린다.
/// - 키 조합(`shift+space` 등): 키는 그대로 두고 60번 단축키만 그 조합으로 돌린다.
public enum InputSwitchKey: Hashable, Sendable {
    case rightCommand
    case rightOption
    case combo(KeyCombo)

    /// `"right_command"`, `"right_option"`, 또는 `"shift+space"` 같은 단축키 표기.
    public init?(configValue: String) {
        let normalized = configValue.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "right_command", "right_cmd":
            self = .rightCommand
        case "right_option", "right_opt", "right_alt":
            self = .rightOption
        default:
            guard let combo = KeyCombo(string: normalized) else { return nil }
            self = .combo(combo)
        }
    }

    /// 설정 파일에 쓰는 값. 이름으로 적을 수 없는 키 조합이면 nil.
    public var configValue: String? {
        switch self {
        case .rightCommand: return "right_command"
        case .rightOption: return "right_option"
        case .combo(let combo): return combo.configString
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: return "오른쪽 Command"
        case .rightOption: return "오른쪽 Option"
        case .combo(let combo): return combo.displayString
        }
    }

    /// 보조키 하나를 바꿔 쓰는 방식인지.
    public var isLoneModifier: Bool {
        if case .combo = self { return false }
        return true
    }

    /// HID 단계에서 바꿀 키(보조키 하나일 때만).
    public var keyMappings: [HIDKeyMapping] {
        switch self {
        case .rightCommand: return [HIDKeyMapping(source: HIDKeyMapping.rightCommand, destination: HIDKeyMapping.f18)]
        case .rightOption: return [HIDKeyMapping(source: HIDKeyMapping.rightOption, destination: HIDKeyMapping.f18)]
        case .combo: return []
        }
    }

    /// 60번 단축키에 적을 값.
    public var hotKeyParameters: HotKeyParameters {
        switch self {
        case .rightCommand, .rightOption: return .f18
        case .combo(let combo): return HotKeyParameters(combo: combo)
        }
    }
}

// MARK: - 시스템 단축키 값

/// 시스템 단축키 값 `(문자 코드, 가상 키코드, 보조키 플래그)`. `AppleSymbolicHotKeys`의 `parameters`.
public struct HotKeyParameters: Hashable, Sendable {
    public var character: Int
    public var keyCode: Int
    public var modifiers: Int

    public static let shiftFlag = 131_072
    public static let controlFlag = 262_144
    public static let optionFlag = 524_288
    public static let commandFlag = 1_048_576
    /// F키·화살표 같은 기능 키에 붙는 표시.
    public static let functionFlag = 8_388_608
    /// '문자 없음'.
    public static let noCharacter = 65_535

    /// macOS 기본값 ⌃Space.
    public static let macDefault = HotKeyParameters(character: 32, keyCode: 49, modifiers: controlFlag)
    /// 보조키 하나를 바꿔 넣는 F18.
    public static let f18 = HotKeyParameters(character: noCharacter, keyCode: 79, modifiers: functionFlag)

    public init(character: Int, keyCode: Int, modifiers: Int) {
        self.character = character
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(combo: KeyCombo) {
        var flags = 0
        if combo.modifiers.contains(.shift) { flags |= Self.shiftFlag }
        if combo.modifiers.contains(.control) { flags |= Self.controlFlag }
        if combo.modifiers.contains(.option) { flags |= Self.optionFlag }
        if combo.modifiers.contains(.command) { flags |= Self.commandFlag }
        if let character = KeyCombo.hotKeyCharacter(forKeyCode: combo.keyCode) {
            self.init(character: character, keyCode: Int(combo.keyCode), modifiers: flags)
        } else {
            self.init(character: Self.noCharacter, keyCode: Int(combo.keyCode), modifiers: flags | Self.functionFlag)
        }
    }

    /// `⌃Space`, `F18`.
    public var displayString: String {
        var text = ""
        if modifiers & Self.controlFlag != 0 { text += "⌃" }
        if modifiers & Self.optionFlag != 0 { text += "⌥" }
        if modifiers & Self.shiftFlag != 0 { text += "⇧" }
        if modifiers & Self.commandFlag != 0 { text += "⌘" }
        let name = keyCode >= 0 ? KeyCombo.displayName(forKeyCode: UInt32(keyCode)) : nil
        return text + (name ?? "키 \(keyCode)")
    }
}

/// `AppleSymbolicHotKeys`의 항목 하나. 읽어 온 사전을 그대로 들고 있어서, 되돌릴 때 원래 모양 그대로 쓴다.
public struct SymbolicHotKey: Equatable {
    public let dictionary: NSDictionary

    public init(dictionary: NSDictionary) {
        self.dictionary = dictionary
    }

    /// 시스템 설정이 쓰는 모양(`enabled`, `value.type = standard`, `value.parameters`)으로 만든다.
    public init(enabled: Bool, parameters: HotKeyParameters) {
        let value: [String: Any] = [
            "type": "standard",
            "parameters": [parameters.character, parameters.keyCode, parameters.modifiers],
        ]
        dictionary = ["enabled": enabled, "value": value] as NSDictionary
    }

    /// macOS 기본값(켜짐, ⌃Space).
    public static var macDefault: SymbolicHotKey {
        SymbolicHotKey(enabled: true, parameters: .macDefault)
    }

    public var isEnabled: Bool {
        (dictionary["enabled"] as? NSNumber)?.boolValue ?? false
    }

    public var parameters: HotKeyParameters? {
        guard let value = dictionary["value"] as? NSDictionary,
              let list = value["parameters"] as? [NSNumber], list.count == 3 else { return nil }
        return HotKeyParameters(character: list[0].intValue, keyCode: list[1].intValue, modifiers: list[2].intValue)
    }

    /// 켜져 있고 이 값으로 동작하는지.
    public func isActive(_ parameters: HotKeyParameters) -> Bool {
        isEnabled && self.parameters == parameters
    }

    /// 켜짐 여부와 값이 같은지(사전의 세부 모양은 보지 않는다).
    public func behavesLike(_ other: SymbolicHotKey) -> Bool {
        isEnabled == other.isEnabled && parameters == other.parameters
    }
}

// MARK: - HID 키 바꾸기

/// `hidutil`의 `UserKeyMapping` 항목 하나: `source` 키를 누르면 `destination` 키로 들어간다.
/// 값은 `0x700000000 | 사용 코드`(키보드 페이지 7).
public struct HIDKeyMapping: Hashable, Sendable {
    public var source: UInt64
    public var destination: UInt64

    public static let rightCommand: UInt64 = 0x7_0000_00E7
    public static let rightOption: UInt64 = 0x7_0000_00E6
    public static let f18: UInt64 = 0x7_0000_006D

    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// `hidutil property --get "UserKeyMapping"`의 출력을 읽는다. 설정이 없으면 `(null)`이 나온다.
    ///
    /// 출력은 옛 NeXTSTEP 형식 plist이고 숫자도 글자로 나온다. 한 항목이라도 읽지 못하면 throw —
    /// 모르는 항목을 빼고 다시 쓰면 다른 프로그램이 넣어 둔 설정이 사라진다.
    public static func parse(_ output: String) throws -> [HIDKeyMapping] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "(null)" { return [] }
        let parsed: Any
        do {
            parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
        } catch {
            throw ParseError(description: "hidutil 출력을 읽지 못했습니다")
        }
        guard let list = parsed as? [Any] else {
            throw ParseError(description: "hidutil 출력이 목록이 아닙니다")
        }
        return try list.map { element in
            guard let entry = element as? [String: Any],
                  let source = number(entry[sourceKey]),
                  let destination = number(entry[destinationKey]) else {
                throw ParseError(description: "hidutil 출력에 읽을 수 없는 항목이 있습니다")
            }
            return HIDKeyMapping(source: source, destination: destination)
        }
    }

    /// `hidutil property --set`에 넘길 값. 목록 전체를 갈아 끼운다.
    public static func setArgument(_ mappings: [HIDKeyMapping]) -> String {
        let entries = mappings.map { mapping in
            "{\"\(sourceKey)\":\(hex(mapping.source)),\"\(destinationKey)\":\(hex(mapping.destination))}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    private static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.lowercased().hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }
}

// MARK: - 결과

/// `InputSwitchManager.apply`가 한 일. 알림 문구와 설정 창의 상태 줄에 그대로 쓴다.
public enum InputSwitchResult: Equatable, Sendable {
    /// 꺼져 있고, MacB가 바꿔 둔 것도 없다. 아무것도 건드리지 않았다.
    case untouched
    /// 입력 소스 단축키를 새로 쓰거나 반영했다(처음 켠 경우, 다른 Mac에서 처음 적용한 경우 등).
    case applied(InputSwitchKey)
    /// 입력 소스 단축키는 이미 맞았고, 키 바꾸기(HID)만 새로 걸었다(재부팅 뒤 다시 건 경우, 보조키끼리 바꾼 경우).
    case remapped(InputSwitchKey)
    /// 이미 그 상태여서 바꾼 것이 없다.
    case alreadyApplied(InputSwitchKey)
    /// 껐고 MacB가 바꾼 것을 되돌렸다.
    case restored(RestoredHotKey)
    /// 실패. `reason`은 어디까지 됐고 무엇이 안 됐는지 적은 문장이다.
    case failed(turningOn: Bool, reason: String)

    /// 끌 때 60번 단축키를 어떻게 했는지.
    public enum RestoredHotKey: Equatable, Sendable {
        /// 원래 단축키(예: "⌃Space")로 되돌렸다.
        case shortcut(String)
        /// 원래 꺼져 있던 상태로 되돌렸다.
        case disabled
        /// 그 사이 사용자가 직접 바꿔 두어서 그 값을 그대로 두었다.
        case keptUserChange
        /// MacB가 입력 소스 단축키를 바꾼 적이 없어서 그대로 두었다.
        case notChanged
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 알림 첫 줄.
    public var message: String {
        switch self {
        case .untouched:
            return "한영 전환 키를 쓰지 않습니다"
        case .applied(let key), .remapped(let key), .alreadyApplied(let key):
            return "한영 전환: \(key.displayName)"
        case .restored(.shortcut(let shortcut)):
            return "한영 전환 키를 껐습니다 · \(shortcut)로 되돌림"
        case .restored:
            return "한영 전환 키를 껐습니다"
        case .failed(let turningOn, _):
            return turningOn ? "한영 전환 키를 켜지 못했습니다" : "한영 전환 키를 끄지 못했습니다"
        }
    }

    /// 알림 둘째 줄.
    public var detail: String? {
        switch self {
        case .untouched, .restored(.shortcut):
            return nil
        case .applied(let key), .remapped(let key), .alreadyApplied(let key):
            return "\(key.displayName) 키로 한/영을 바꿉니다"
        case .restored(.disabled):
            return "입력 소스 단축키를 원래대로(꺼짐) 되돌렸습니다"
        case .restored(.keptUserChange):
            return "입력 소스 단축키는 그 사이 직접 바꾸신 값 그대로 두었습니다"
        case .restored(.notChanged):
            return "입력 소스 단축키는 MacB가 바꾼 적이 없어 그대로 두었습니다"
        case .failed(_, let reason):
            return reason
        }
    }

    public var symbol: String {
        isFailure ? "exclamationmark.triangle" : "keyboard"
    }

    /// 설정 창의 상태 줄.
    public var statusText: String {
        switch self {
        case .untouched:
            return "꺼져 있습니다"
        case .applied(let key), .remapped(let key), .alreadyApplied(let key):
            return "켜져 있습니다 · \(key.displayName) 키로 한/영 전환"
        case .restored(.shortcut(let shortcut)):
            return "껐습니다 · 입력 소스 단축키를 \(shortcut)로 되돌렸습니다"
        case .restored(.disabled):
            return "껐습니다 · 입력 소스 단축키를 원래대로(꺼짐) 되돌렸습니다"
        case .restored(.keptUserChange):
            return "껐습니다 · 입력 소스 단축키는 직접 바꾸신 값 그대로입니다"
        case .restored(.notChanged):
            return "껐습니다 · 입력 소스 단축키는 그대로입니다"
        case .failed(_, let reason):
            return reason
        }
    }
}
