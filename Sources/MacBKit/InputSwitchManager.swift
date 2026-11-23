import Foundation

/// 한영 전환 키를 설정대로 맞춘다. 설정(`config.json`)이 기준이고, 이 객체는 시스템을 그 상태로 만들거나 되돌린다.
///
/// - 켜기: HID 키 바꾸기(보조키 하나일 때) → 60번 단축키 → 다시 읽어 확인. 시스템에 쓰기 전에 무엇을 쓸지와
///   처음 원래 값을 상태 파일에 적어 둔다. HID 키 바꾸기는 재부팅·로그아웃 때 사라지므로 MacB가 시작할 때마다 다시 부른다.
/// - 끄기: 상태 파일에 적힌 것만 되돌린다. 60번이 MacB가 한 번이라도 쓴 값이면 처음 원래 값으로 돌리고,
///   MacB가 넣은 HID 항목은 모두 뺀다. 다 되돌린 뒤에만 상태 파일을 지운다.
///   상태 파일이 없으면 MacB가 바꾼 것이 없다는 뜻이라 아무것도 건드리지 않는다.
/// - 같은 설정으로 여러 번 불러도 두 번째부터는 아무것도 바꾸지 않는다.
public final class InputSwitchManager {
    public static var defaultStateFile: URL {
        AppPaths.supportDirectory.appendingPathComponent("input-switch.plist")
    }

    private let system: KeyboardSystem
    private let stateFile: URL
    private let queue = DispatchQueue(label: "dev.macb.input-switch")

    public init(system: KeyboardSystem = MacKeyboardSystem(), stateFile: URL = InputSwitchManager.defaultStateFile) {
        self.system = system
        self.stateFile = stateFile
    }

    /// MacB가 바꿔 두고 아직 되돌리지 않은 것이 있는지(상태 파일이 있는지).
    public var hasAppliedChanges: Bool {
        FileManager.default.fileExists(atPath: stateFile.path)
    }

    /// 설정에 맞춘다. 외부 명령을 기다리므로 시간이 조금 걸린다 — 앱에서는 `applyInBackground`를 쓴다.
    /// 어느 스레드에서 불러도 `applyInBackground`와 같은 큐에서 차례로 처리된다.
    public func apply(_ setting: AppConfig.Keyboard.InputSwitch) -> InputSwitchResult {
        queue.sync { applyNow(setting) }
    }

    /// 작업 큐에서 `apply`를 돌리고 결과를 메인 스레드로 돌려준다. 차례대로 처리하므로 마지막에 넘긴 설정이 최종 상태가 된다.
    public func applyInBackground(
        _ setting: AppConfig.Keyboard.InputSwitch,
        completion: @escaping @MainActor (InputSwitchResult) -> Void
    ) {
        queue.async { [self] in
            let result = applyNow(setting)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    private func applyNow(_ setting: AppConfig.Keyboard.InputSwitch) -> InputSwitchResult {
        guard setting.enabled else { return turnOff() }
        guard let key = InputSwitchKey(configValue: setting.key), key.configValue != nil else {
            return .failed(
                turningOn: true,
                reason: "keyboard.inputSwitch.key: '\(setting.key)' 를 해석할 수 없습니다 (right_command, right_option, 또는 shift+space 같은 단축키)"
            )
        }
        // config.json을 손으로 고친 경우에도 설정 창과 같은 규칙을 쓴다. 글자를 치는 조합이 시스템 단축키가 되면 MacB를 꺼도 남는다.
        if case .combo(let combo) = key, let refusal = ShortcutSettings.inputSwitchRefusal(for: combo) {
            return .failed(turningOn: true, reason: "keyboard.inputSwitch.key: '\(setting.key)' — \(refusal.message)")
        }
        return turnOn(key)
    }

    // MARK: Turning on

    private func turnOn(_ key: InputSwitchKey) -> InputSwitchResult {
        func failure(_ reason: String) -> InputSwitchResult { .failed(turningOn: true, reason: reason) }

        let stored: InputSwitchState?
        do {
            stored = try loadState()
        } catch {
            return failure("MacB 상태 파일을 읽지 못했습니다 (\(stateFile.path)) — 아무것도 바꾸지 않았습니다")
        }

        let wantedParameters = key.hotKeyParameters
        let wantedHotKey = SymbolicHotKey(enabled: true, parameters: wantedParameters)
        // 항목이 없으면 시스템은 기본값(⌃Space)으로 동작한다.
        let currentHotKey = system.inputSourceHotKey() ?? .macDefault

        let mappings: [HIDKeyMapping]
        do {
            mappings = try system.keyMappings()
        } catch {
            return failure("키 설정을 읽지 못했습니다: \(error) — 아무것도 바꾸지 않았습니다")
        }

        let owned = stored?.keyMappings ?? []
        let wantedMappings = key.keyMappings
        // 다른 프로그램이 같은 키를 이미 다른 키로 바꿔 두었으면 덮어쓰지 않는다(끌 때 되돌릴 수 없게 된다).
        let clash = mappings.contains { mapping in
            !owned.contains(mapping) && !wantedMappings.contains(mapping)
                && wantedMappings.contains { $0.source == mapping.source }
        }
        if clash {
            return failure("\(key.displayName) 키가 이미 다른 키로 바뀌어 있습니다(hidutil) — 아무것도 바꾸지 않았습니다")
        }
        let removedMappings = owned.filter { !wantedMappings.contains($0) && mappings.contains($0) }
        var newMappings = mappings.filter { !removedMappings.contains($0) }
        for mapping in wantedMappings where !newMappings.contains(mapping) {
            newMappings.append(mapping)
        }
        let mappingsNeedWrite = newMappings != mappings
        let hotKeyNeedsWrite = !currentHotKey.isActive(wantedParameters)
        let activationPending = stored?.needsActivation ?? false
        // F18은 MacB가 한/영 전환에 쓰는 표시다. 이미 들어 있으면(손으로 미리 적용해 둔 경우 등) MacB 것으로 보고,
        // 되돌아갈 값이 따로 없으니 macOS 기본값(⌃Space)을 원래 값으로 삼는다.
        let currentIsMarker = currentHotKey.isActive(.f18)

        // 시스템에 쓰기 전에 먼저 적어 둔다. 도중에 멈춰도 끌 때 되돌릴 수 있도록, 넣을 항목과 아직 남은 옛 항목,
        // 쓰려는 단축키 값을 모두 적는다. 원래 값은 처음 바꿀 때 한 번만 적는다.
        var state = stored ?? InputSwitchState(key: key, keyMappings: [], original: nil, writtenHotKeys: [], needsActivation: false)
        state.key = key
        state.keyMappings = owned.filter { !wantedMappings.contains($0) } + wantedMappings
        if hotKeyNeedsWrite || currentIsMarker {
            if state.original == nil { state.original = currentIsMarker ? .macDefault : currentHotKey }
            if currentIsMarker { state.remember(.f18) }
            if hotKeyNeedsWrite {
                state.remember(wantedParameters)
                state.needsActivation = true
            }
        }
        var saved = stored
        func save() -> Bool {
            guard state != saved else { return true }
            // 바꿀 것도 되돌릴 것도 없으면(이미 손으로 같은 단축키를 써 두었을 때 등) 상태 파일을 만들지 않는다.
            // 그래야 끌 때 MacB가 쓰지 않은 값을 건드리지 않는다.
            if saved == nil, state.isEmpty { return true }
            do {
                try saveState(state)
                saved = state
                return true
            } catch {
                return false
            }
        }
        guard save() else {
            return failure("MacB 상태 파일을 쓰지 못했습니다 (\(stateFile.path)) — 아무것도 바꾸지 않았습니다")
        }

        // 1. HID 키 바꾸기
        if mappingsNeedWrite {
            do {
                try system.setKeyMappings(newMappings)
                let check = try system.keyMappings()
                guard wantedMappings.allSatisfy(check.contains), !removedMappings.contains(where: check.contains) else {
                    throw KeyboardSystemError("바꾼 뒤 다시 읽어 보니 반영되지 않았습니다")
                }
            } catch {
                let what = wantedMappings.isEmpty
                    ? "\(Self.describe(removedMappings))를 원래대로 돌리지 못했습니다"
                    : "\(key.displayName) 키를 한/영 전환용(F18)으로 바꾸지 못했습니다"
                return failure("\(what): \(error) — 입력 소스 단축키는 바꾸지 않았습니다")
            }
        }
        state.keyMappings = wantedMappings
        // 실패해도 상태 파일에 실제보다 많은 항목이 적혀 있을 뿐이라(끌 때 없는 항목은 건너뛴다) 계속 간다.
        _ = save()

        // 2. 60번 단축키
        let mappingDone: String
        if !mappingsNeedWrite {
            mappingDone = ""
        } else if wantedMappings.isEmpty {
            mappingDone = "\(Self.describe(removedMappings))는 원래대로 돌렸지만, "
        } else {
            mappingDone = "\(key.displayName) 키 바꾸기는 됐지만, "
        }
        if hotKeyNeedsWrite {
            do {
                try system.setInputSourceHotKey(wantedHotKey)
                guard system.inputSourceHotKey()?.isActive(wantedParameters) == true else {
                    throw KeyboardSystemError("저장한 뒤 다시 읽어 보니 반영되지 않았습니다")
                }
            } catch {
                return failure(mappingDone + "입력 소스 단축키를 바꾸지 못했습니다: \(error)")
            }
        }
        if hotKeyNeedsWrite || activationPending {
            do {
                try system.activateSettings()
            } catch {
                return failure(
                    mappingDone + "입력 소스 단축키(\(wantedParameters.displayString))는 저장했지만 바로 적용하지 못했습니다: \(error)"
                        + " — 다시 로그인하면 적용됩니다"
                )
            }
            state.needsActivation = false
            _ = save()
            return .applied(key)
        }
        return mappingsNeedWrite ? .remapped(key) : .alreadyApplied(key)
    }

    // MARK: Turning off

    private func turnOff() -> InputSwitchResult {
        func failure(_ reason: String) -> InputSwitchResult { .failed(turningOn: false, reason: reason) }

        let stored: InputSwitchState?
        do {
            stored = try loadState()
        } catch {
            return failure("MacB 상태 파일을 읽지 못해 되돌리지 못했습니다 (\(stateFile.path))")
        }
        guard var state = stored else { return .untouched }

        // 1. HID 키 바꾸기 — MacB가 넣은 항목만 모두 뺀다. 다른 프로그램이 넣은 항목은 그대로 둔다.
        var keyDone = ""
        if !state.keyMappings.isEmpty {
            let owned = state.keyMappings
            do {
                let mappings = try system.keyMappings()
                let present = mappings.filter(owned.contains)
                if !present.isEmpty {
                    try system.setKeyMappings(mappings.filter { !owned.contains($0) })
                    let check = try system.keyMappings()
                    guard !owned.contains(where: check.contains) else {
                        throw KeyboardSystemError("바꾼 뒤 다시 읽어 보니 반영되지 않았습니다")
                    }
                    keyDone = "\(Self.describe(present))는 원래대로 돌렸지만, "
                }
            } catch {
                return failure("\(Self.describe(owned))를 원래대로 돌리지 못했습니다: \(error) — 입력 소스 단축키도 그대로입니다")
            }
            state.keyMappings = []
            // 실패해도 다음에 끌 때 없는 항목을 건너뛸 뿐이다.
            try? saveState(state)
        }

        // 2. 60번 단축키 — MacB가 쓴 값 중 하나가 들어 있으면 처음 원래 값으로 돌린다.
        // 그 밖의 값이면 그 사이 사용자가(또는 다른 프로그램이) 바꾼 것이라 그대로 둔다.
        let outcome: InputSwitchResult.RestoredHotKey
        if let original = state.original {
            let current = system.inputSourceHotKey() ?? .macDefault
            let restored: InputSwitchResult.RestoredHotKey = original.isEnabled
                ? .shortcut(original.parameters?.displayString ?? "원래 단축키")
                : .disabled
            if current.behavesLike(original) {
                outcome = restored
            } else if state.writtenHotKeys.contains(where: current.isActive) {
                // 쓰기 전에 적어 둔다. 저장만 되고 반영 전에 멈춰도 다음에 끌 때 반영을 다시 한다.
                state.needsActivation = true
                try? saveState(state)
                do {
                    try system.setInputSourceHotKey(original)
                    guard system.inputSourceHotKey()?.behavesLike(original) == true else {
                        throw KeyboardSystemError("저장한 뒤 다시 읽어 보니 반영되지 않았습니다")
                    }
                } catch {
                    return failure(keyDone + "입력 소스 단축키를 되돌리지 못했습니다: \(error)")
                }
                outcome = restored
            } else {
                outcome = .keptUserChange
                state.needsActivation = false
            }
            if state.needsActivation {
                do {
                    try system.activateSettings()
                } catch {
                    // 저장한 값은 다음 로그인 때 반영된다. 상태는 남겨 두어 다음에 끌 때 반영을 다시 시도한다.
                    try? saveState(state)
                    return failure(
                        keyDone + "입력 소스 단축키를 원래대로 저장했지만 바로 적용하지 못했습니다: \(error) — 다시 로그인하면 적용됩니다"
                    )
                }
            }
        } else {
            outcome = .notChanged
        }

        do {
            try FileManager.default.removeItem(at: stateFile)
        } catch {
            return failure("되돌렸지만 MacB 상태 파일을 지우지 못했습니다 (\(stateFile.path))")
        }
        return .restored(outcome)
    }

    /// 알림에 쓸 HID 항목 이름. 예: "오른쪽 Command 키".
    private static func describe(_ mappings: [HIDKeyMapping]) -> String {
        let names = [InputSwitchKey.rightCommand, .rightOption]
            .filter { key in key.keyMappings.contains { mapping in mappings.contains { $0.source == mapping.source } } }
            .map(\.displayName)
        return names.isEmpty ? "MacB가 바꿔 둔 키" : names.joined(separator: "·") + " 키"
    }

    // MARK: State file

    private func loadState() throws -> InputSwitchState? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        return try InputSwitchState(data: Data(contentsOf: stateFile))
    }

    private func saveState(_ state: InputSwitchState) throws {
        AppPaths.ensureDirectory(stateFile.deletingLastPathComponent())
        try state.data().write(to: stateFile, options: .atomic)
    }
}

/// MacB가 바꿔 둔 것. 상태 파일(XML plist)에 적어 두었다가 끌 때 되돌린다.
struct InputSwitchState: Equatable {
    /// 마지막으로 적용한 키.
    var key: InputSwitchKey
    /// MacB가 넣었고 아직 남아 있을 수 있는 HID 키 바꾸기 항목.
    var keyMappings: [HIDKeyMapping]
    /// MacB가 60번을 처음 바꾸기 전의 값. 읽은 사전을 그대로 적어 두어 원래 모양 그대로 되돌린다.
    /// MacB가 60번을 바꾼 적이 없으면 nil.
    var original: SymbolicHotKey?
    /// MacB가 60번에 쓴(쓰려던) 값들. 끌 때 60번이 이 중 하나면 MacB가 쓴 값으로 보고 되돌린다.
    var writtenHotKeys: [HotKeyParameters]
    /// 60번에 저장은 했지만 `activateSettings`가 아직 성공하지 못했다.
    var needsActivation: Bool

    struct FormatError: Error {}

    init(key: InputSwitchKey, keyMappings: [HIDKeyMapping], original: SymbolicHotKey?,
         writtenHotKeys: [HotKeyParameters], needsActivation: Bool) {
        self.key = key
        self.keyMappings = keyMappings
        self.original = original
        self.writtenHotKeys = writtenHotKeys
        self.needsActivation = needsActivation
    }

    /// 되돌릴 것이 하나도 없다.
    var isEmpty: Bool {
        keyMappings.isEmpty && original == nil && writtenHotKeys.isEmpty && !needsActivation
    }

    mutating func remember(_ parameters: HotKeyParameters) {
        if !writtenHotKeys.contains(parameters) { writtenHotKeys.append(parameters) }
    }

    init(data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let keyText = root["key"] as? String,
              let key = InputSwitchKey(configValue: keyText),
              let mappingList = root["keyMappings"] as? [[String: Any]] else {
            throw FormatError()
        }
        self.key = key
        self.keyMappings = try mappingList.map { entry in
            guard let source = entry["source"] as? NSNumber, let destination = entry["destination"] as? NSNumber else {
                throw FormatError()
            }
            return HIDKeyMapping(source: source.uint64Value, destination: destination.uint64Value)
        }
        self.original = (root["originalHotKey"] as? NSDictionary).map(SymbolicHotKey.init(dictionary:))
        if let written = root["writtenHotKeys"] as? [[NSNumber]] {
            self.writtenHotKeys = try written.map { values in
                guard values.count == 3 else { throw FormatError() }
                return HotKeyParameters(character: values[0].intValue, keyCode: values[1].intValue, modifiers: values[2].intValue)
            }
        } else {
            // 1판 상태 파일: 마지막 키의 값과 F18을 MacB가 쓴 값으로 본다(그때는 그 둘만 MacB 것으로 알아봤다).
            guard root["originalHotKey"] != nil else { throw FormatError() }
            self.writtenHotKeys = [key.hotKeyParameters]
            if !writtenHotKeys.contains(.f18) { writtenHotKeys.append(.f18) }
        }
        self.needsActivation = (root["needsActivation"] as? NSNumber)?.boolValue ?? false
    }

    func data() throws -> Data {
        var root: [String: Any] = [
            "version": 2,
            "key": key.configValue ?? "",
            "keyMappings": keyMappings.map { mapping in
                ["source": NSNumber(value: mapping.source), "destination": NSNumber(value: mapping.destination)]
            },
            "writtenHotKeys": writtenHotKeys.map { [$0.character, $0.keyCode, $0.modifiers] },
            "needsActivation": needsActivation,
        ]
        if let original { root["originalHotKey"] = original.dictionary }
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}
