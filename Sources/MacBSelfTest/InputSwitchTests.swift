import Carbon.HIToolbox
import Foundation
import MacBKit

/// 한영 전환 키 테스트. 실제 시스템(hidutil, 키보드 단축키 환경설정)은 절대 건드리지 않는다 —
/// 모두 메모리 속 가짜 시스템과 임시 폴더의 상태 파일로만 돌린다.
@MainActor
func runInputSwitchTests(_ t: TestRunner) {
    let rightCommandMapping = HIDKeyMapping(source: 0x7_0000_00E7, destination: 0x7_0000_006D)
    let rightOptionMapping = HIDKeyMapping(source: 0x7_0000_00E6, destination: 0x7_0000_006D)
    // Caps Lock → Escape. 다른 프로그램이 넣어 둔 항목 역할.
    let foreignMapping = HIDKeyMapping(source: 0x7_0000_0039, destination: 0x7_0000_0029)
    let commandSpace = HotKeyParameters(character: 32, keyCode: 49, modifiers: HotKeyParameters.commandFlag)

    func on(_ key: String = "right_command") -> AppConfig.Keyboard.InputSwitch {
        .init(enabled: true, key: key)
    }
    let off = AppConfig.Keyboard.InputSwitch(enabled: false, key: "right_command")

    t.suite("한영: 설정 기본값과 부분 설정") {
        let empty = try AppConfig.decode(Data("{}".utf8))
        t.expectEqual(empty.keyboard.inputSwitch.enabled, false, "처음 설치한 MacB는 시스템 설정을 건드리지 않아야 함")
        t.expectEqual(empty.keyboard.inputSwitch.key, "right_command")
        t.expectEqual(empty.shortcuts, [])

        let partial = try AppConfig.decode(Data(#"{ "keyboard": { "inputSwitch": { "enabled": true } } }"#.utf8))
        t.expectEqual(partial.keyboard.inputSwitch, .init(enabled: true, key: "right_command"))
        let onlyKey = try AppConfig.decode(Data(#"{ "keyboard": { "inputSwitch": { "key": "shift+space" } } }"#.utf8))
        t.expectEqual(onlyKey.keyboard.inputSwitch, .init(enabled: false, key: "shift+space"))
        let emptySection = try AppConfig.decode(Data(#"{ "keyboard": {} }"#.utf8))
        t.expectEqual(emptySection.keyboard, AppConfig.Keyboard())
    }

    t.suite("한영: 단축키 목록 읽기·쓰기") {
        let config = try AppConfig.decode(Data("""
        {
          "shortcuts": [
            { "key": "control+option+t", "app": "Terminal" },
            { "key": "control+shift+4", "action": "capture.area.clipboard" },
            { "app": "Safari", "title": "사파리" },
            { "key": "control+option+n", "title": "메모", "icon": "note.text", "shell": "open -a Notes" }
          ]
        }
        """.utf8))
        t.expectEqual(config.shortcuts.count, 4)
        t.expectEqual(config.shortcuts[0].key, "control+option+t")
        t.expectEqual(config.shortcuts[0].item.app, "Terminal")
        t.expectEqual(config.shortcuts[1].item.action, "capture.area.clipboard")
        t.expectEqual(config.shortcuts[2].key, "", "key가 없으면 빈 문자열")
        t.expectEqual(config.shortcuts[2].item.title, "사파리")
        t.expectEqual(config.shortcuts[3].item.shell, "open -a Notes")
        t.expectEqual(config.shortcuts[3].item.icon, "note.text")

        var changed = config
        changed.keyboard.inputSwitch = .init(enabled: true, key: "right_option")
        let data = try changed.encoded()
        let reloaded = try AppConfig.decode(data)
        t.expectEqual(reloaded, changed, "저장 후 다시 읽으면 같아야 함")

        // 항목 필드와 key가 한 단계에 나란히 적혀야 손으로 고치기 쉽다.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (json?["shortcuts"] as? [[String: Any]])?.first
        t.expectEqual(first?["key"] as? String, "control+option+t")
        t.expectEqual(first?["app"] as? String, "Terminal")
        t.expect(first?["item"] == nil, "item으로 한 번 더 감싸면 안 됨")
        t.expect(first?["title"] == nil, "없는 필드는 쓰지 않음")
        let keyboard = (json?["keyboard"] as? [String: Any])?["inputSwitch"] as? [String: Any]
        t.expectEqual(keyboard?["enabled"] as? Bool, true)
        t.expectEqual(keyboard?["key"] as? String, "right_option")
    }

    t.suite("한영: 키 해석") {
        t.expectEqual(InputSwitchKey(configValue: "right_command"), .rightCommand)
        t.expectEqual(InputSwitchKey(configValue: " Right_Option "), .rightOption)
        t.expectEqual(InputSwitchKey(configValue: "shift+space"), .combo(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: [.shift])))
        t.expect(InputSwitchKey(configValue: "nope") == nil)
        t.expect(InputSwitchKey(configValue: "") == nil)
        for value in ["right_command", "right_option", "shift+space", "control+option+k", "f5"] {
            t.expectEqual(InputSwitchKey(configValue: value)?.configValue, value)
        }
        t.expectEqual(InputSwitchKey.rightCommand.displayName, "오른쪽 Command")
        t.expectEqual(InputSwitchKey(configValue: "shift+space")?.displayName, "⇧Space")
        t.expectEqual(InputSwitchKey.rightCommand.keyMappings, [rightCommandMapping])
        t.expectEqual(InputSwitchKey.rightOption.keyMappings, [rightOptionMapping])
        t.expectEqual(InputSwitchKey(configValue: "shift+space")?.keyMappings, [])
    }

    t.suite("한영: 시스템 단축키 값") {
        func parameters(_ value: String) -> HotKeyParameters? {
            InputSwitchKey(configValue: value)?.hotKeyParameters
        }
        let f18 = HotKeyParameters(character: 65535, keyCode: 79, modifiers: 8_388_608)
        t.expectEqual(parameters("right_command"), f18)
        t.expectEqual(parameters("right_option"), f18)
        t.expectEqual(HotKeyParameters.f18, f18)
        t.expectEqual(parameters("shift+space"), HotKeyParameters(character: 32, keyCode: 49, modifiers: 131_072))
        t.expectEqual(parameters("control+space"), HotKeyParameters(character: 32, keyCode: 49, modifiers: 262_144))
        t.expectEqual(parameters("control+space"), HotKeyParameters.macDefault)
        t.expectEqual(parameters("option+k"), HotKeyParameters(character: 107, keyCode: kVK_ANSI_K, modifiers: 524_288))
        t.expectEqual(parameters("command+shift+1"), HotKeyParameters(character: 49, keyCode: kVK_ANSI_1, modifiers: 1_048_576 | 131_072))
        t.expectEqual(parameters("f5"), HotKeyParameters(character: 65535, keyCode: kVK_F5, modifiers: 8_388_608))
        t.expectEqual(parameters("command+f13"), HotKeyParameters(character: 65535, keyCode: kVK_F13, modifiers: 1_048_576 | 8_388_608))
        // 화살표도 기능 키 표시가 붙는다(시스템의 '왼쪽 스페이스로 이동'이 ⌃← = 8650752).
        t.expectEqual(parameters("control+left"), HotKeyParameters(character: 65535, keyCode: kVK_LeftArrow, modifiers: 8_650_752))

        t.expectEqual(HotKeyParameters.macDefault.displayString, "⌃Space")
        t.expectEqual(HotKeyParameters.f18.displayString, "F18")
        t.expectEqual(commandSpace.displayString, "⌘Space")

        // 시스템 설정이 쓰는 모양 그대로.
        let entry = SymbolicHotKey(enabled: true, parameters: .f18)
        t.expectEqual(entry.dictionary["enabled"] as? Bool, true)
        let value = entry.dictionary["value"] as? NSDictionary
        t.expectEqual(value?["type"] as? String, "standard")
        t.expectEqual(value?["parameters"] as? [Int], [65535, 79, 8_388_608])
        t.expect(entry.isActive(.f18))
        t.expect(!SymbolicHotKey(enabled: false, parameters: .f18).isActive(.f18), "꺼진 항목은 동작하지 않음")
        t.expect(SymbolicHotKey(dictionary: ["enabled": 1, "value": ["parameters": [32, 49, 262_144], "type": "standard"]])
            .behavesLike(.macDefault), "enabled가 숫자 1로 적혀 있어도 같은 값")
    }

    t.suite("한영: hidutil 출력 읽기와 쓰기") {
        let unset = try HIDKeyMapping.parse("(null)")
        let unsetWithNewline = try HIDKeyMapping.parse("(null)\n")
        let blank = try HIDKeyMapping.parse("")
        t.expectEqual(unset, [])
        t.expectEqual(unsetWithNewline, [])
        t.expectEqual(blank, [])
        let sample = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771303;
            }
        )

        """
        let parsedSample = try HIDKeyMapping.parse(sample)
        t.expectEqual(parsedSample, [rightCommandMapping])
        let two = """
        ( { HIDKeyboardModifierMappingDst = 30064771113; HIDKeyboardModifierMappingSrc = 30064771129; },
          { HIDKeyboardModifierMappingDst = 0x70000006D; HIDKeyboardModifierMappingSrc = 0x7000000E6; } )
        """
        let parsedTwo = try HIDKeyMapping.parse(two)
        t.expectEqual(parsedTwo, [foreignMapping, rightOptionMapping])

        var threw = false
        do { _ = try HIDKeyMapping.parse("( { Something = 1; } )") } catch { threw = true }
        t.expect(threw, "읽을 수 없는 항목이 있으면 throw (모르는 항목을 지우지 않도록)")
        threw = false
        do { _ = try HIDKeyMapping.parse("{ not a list") } catch { threw = true }
        t.expect(threw, "깨진 출력은 throw")

        t.expectEqual(
            HIDKeyMapping.setArgument([rightCommandMapping]),
            #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x7000000E7,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
        )
        t.expectEqual(HIDKeyMapping.setArgument([]), #"{"UserKeyMapping":[]}"#)
        t.expectEqual(
            HIDKeyMapping.setArgument([foreignMapping, rightCommandMapping]),
            #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000029},{"HIDKeyboardModifierMappingSrc":0x7000000E7,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
        )
    }

    t.suite("한영: 켜기 → 끄기는 원래대로") {
        try withInputSwitch { manager, system, stateFile in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(system.mappings, [rightCommandMapping])
            t.expect(system.hotKey?.isActive(.f18) == true, "60번이 F18")
            t.expectEqual(system.activations, 1)
            t.expect(FileManager.default.fileExists(atPath: stateFile.path), "상태 파일이 있어야 함")
            t.expect(manager.hasAppliedChanges)

            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.mappings, [])
            t.expect(system.hotKey?.behavesLike(.macDefault) == true, "⌃Space로 되돌아와야 함")
            t.expectEqual(system.activations, 2)
            t.expect(!FileManager.default.fileExists(atPath: stateFile.path), "상태 파일을 지워야 함")
            t.expect(!manager.hasAppliedChanges)

            t.expectEqual(manager.apply(off), .untouched, "다시 꺼도 할 일이 없음")
            t.expectEqual(system.writes, 6, "켤 때 셋(HID, 단축키, 반영), 끌 때 셋")
        }
    }

    t.suite("한영: 두 번 켜면 두 번째는 아무것도 바꾸지 않음") {
        try withInputSwitch { manager, system, stateFile in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            let writes = system.writes
            let stateData = try Data(contentsOf: stateFile)
            t.expectEqual(manager.apply(on()), .alreadyApplied(.rightCommand))
            t.expectEqual(manager.apply(on()), .alreadyApplied(.rightCommand))
            t.expectEqual(system.writes, writes, "시스템에 아무것도 쓰지 않아야 함")
            let stateDataAfter = try Data(contentsOf: stateFile)
            t.expectEqual(stateDataAfter, stateData, "상태 파일도 그대로")
        }
    }

    t.suite("한영: 손으로 이미 적용해 둔 상태에서 켜고 끄기") {
        try withInputSwitch { manager, system, _ in
            system.mappings = [rightCommandMapping]
            system.hotKey = SymbolicHotKey(enabled: true, parameters: .f18)

            t.expectEqual(manager.apply(on()), .alreadyApplied(.rightCommand))
            t.expectEqual(system.writes, 0, "이미 그 상태면 쓰지 않음")
            t.expect(manager.hasAppliedChanges, "끌 때 되돌릴 수 있도록 상태는 적어 둠")

            // MacB가 쓰는 값(F18)을 원래 값으로 적었다면 되돌려도 F18이 남는다. macOS 기본값으로 돌아와야 한다.
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)
            t.expectEqual(system.mappings, [])
        }
    }

    t.suite("한영: 기본값이 아닌 원래 단축키를 정확히 되돌림") {
        try withInputSwitch { manager, system, _ in
            // 오래된 macOS처럼 enabled를 숫자로 적고, 모르는 필드도 하나 넣어 둔다.
            let original: NSDictionary = [
                "enabled": NSNumber(value: 1),
                "value": ["parameters": [32, 49, 1_048_576], "type": "standard"],
                "note": "keep",
            ]
            system.hotKey = SymbolicHotKey(dictionary: original)

            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌘Space")))
            t.expect(system.hotKey?.dictionary.isEqual(original) == true, "원래 사전 그대로")
            let enabled = system.hotKey?.dictionary["enabled"] as AnyObject?
            t.expect(enabled.map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false, "숫자는 숫자로 되돌려야 함")
            t.expectEqual(system.hotKey?.dictionary["note"] as? String, "keep")
        }
    }

    t.suite("한영: 원래 꺼져 있던 단축키는 꺼진 채로 되돌림") {
        try withInputSwitch { manager, system, _ in
            system.hotKey = SymbolicHotKey(enabled: false, parameters: .macDefault)
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(manager.apply(off), .restored(.disabled))
            t.expect(system.hotKey?.isEnabled == false)
            t.expectEqual(system.hotKey?.parameters, .macDefault)
        }
    }

    t.suite("한영: 60번 항목이 없으면 ⌃Space가 원래 값") {
        try withInputSwitch { manager, system, _ in
            system.hotKey = nil
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)
        }
    }

    t.suite("한영: 키를 바꿔도 처음 원래 값을 유지") {
        try withInputSwitch { manager, system, _ in
            system.hotKey = SymbolicHotKey(enabled: true, parameters: commandSpace)
            t.expectEqual(manager.apply(on("right_command")), .applied(.rightCommand))
            t.expectEqual(manager.apply(on("right_option")), .remapped(.rightOption), "60번은 그대로라 키 바꾸기만")
            t.expectEqual(system.mappings, [rightOptionMapping], "오른쪽 Command 항목은 빠지고 Option만")
            t.expectEqual(system.hotKeyWrites, 1, "60번은 이미 F18이라 다시 쓰지 않음")

            let shiftSpace = InputSwitchKey(configValue: "shift+space")!
            t.expectEqual(manager.apply(on("shift+space")), .applied(shiftSpace))
            t.expectEqual(system.mappings, [], "키 조합은 HID를 바꾸지 않음")
            t.expectEqual(system.hotKey?.parameters, HotKeyParameters(character: 32, keyCode: 49, modifiers: 131_072))

            t.expectEqual(manager.apply(off), .restored(.shortcut("⌘Space")))
            t.expect(system.hotKey?.isActive(commandSpace) == true, "처음 원래 값(⌘Space)으로")
        }
    }

    t.suite("한영: 다른 프로그램의 HID 항목은 그대로") {
        try withInputSwitch { manager, system, _ in
            system.mappings = [foreignMapping]
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(system.mappings, [foreignMapping, rightCommandMapping])
            t.expectEqual(manager.apply(on("right_option")), .remapped(.rightOption))
            t.expectEqual(system.mappings, [foreignMapping, rightOptionMapping])
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.mappings, [foreignMapping])
        }
    }

    t.suite("한영: 같은 키를 다른 프로그램이 이미 바꿔 두었으면 손대지 않음") {
        try withInputSwitch { manager, system, stateFile in
            let other = HIDKeyMapping(source: 0x7_0000_00E7, destination: 0x7_0000_00E6)
            system.mappings = [other]
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("이미 다른 키로") == true, "\(result)")
            t.expectEqual(system.mappings, [other])
            t.expectEqual(system.writes, 0)
            t.expect(!FileManager.default.fileExists(atPath: stateFile.path))
        }
    }

    t.suite("한영: 꺼져 있고 상태 파일이 없으면 아무것도 건드리지 않음") {
        try withInputSwitch { manager, system, stateFile in
            system.mappings = [rightCommandMapping, foreignMapping]
            system.hotKey = SymbolicHotKey(enabled: true, parameters: .f18)
            t.expectEqual(manager.apply(off), .untouched)
            t.expectEqual(system.writes, 0)
            t.expectEqual(system.mappings, [rightCommandMapping, foreignMapping])
            t.expect(system.hotKey?.isActive(.f18) == true)
            t.expect(!FileManager.default.fileExists(atPath: stateFile.path))
        }
    }

    t.suite("한영: 그 사이 사용자가 바꾼 단축키는 존중") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            let optionSpace = SymbolicHotKey(enabled: true, parameters: HotKeyParameters(character: 32, keyCode: 49, modifiers: 524_288))
            system.hotKey = optionSpace
            t.expectEqual(manager.apply(off), .restored(.keptUserChange))
            t.expectEqual(system.hotKey, optionSpace)
            t.expectEqual(system.mappings, [], "HID 항목은 그래도 뺀다")
            t.expect(!manager.hasAppliedChanges)
        }
    }

    t.suite("한영: 실패 — 키 설정을 읽지 못함") {
        try withInputSwitch { manager, system, stateFile in
            system.failReadingMappings = true
            let result = manager.apply(on())
            t.expectEqual(result.message, "한영 전환 키를 켜지 못했습니다")
            t.expect(result.detail?.contains("아무것도 바꾸지 않았습니다") == true, "\(result)")
            t.expectEqual(system.writes, 0)
            t.expect(!FileManager.default.fileExists(atPath: stateFile.path))
        }
    }

    t.suite("한영: 실패 — hidutil이 거부") {
        try withInputSwitch { manager, system, _ in
            system.failWritingMappings = true
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("F18") == true, "\(result)")
            t.expect(result.detail?.contains("입력 소스 단축키는 바꾸지 않았습니다") == true, "\(result)")
            t.expectEqual(system.hotKeyWrites, 0)
            t.expectEqual(system.activations, 0)
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)

            // 고쳐진 뒤 다시 켜면 끝까지 적용된다.
            system.failWritingMappings = false
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(system.mappings, [rightCommandMapping])
            t.expect(system.hotKey?.isActive(.f18) == true)
        }
    }

    t.suite("한영: 실패 — HID가 반영되지 않음") {
        try withInputSwitch { manager, system, _ in
            system.mappingsDontStick = true
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("반영되지 않았습니다") == true, "\(result)")
            t.expectEqual(system.hotKeyWrites, 0)
        }
    }

    t.suite("한영: 실패 — 단축키 저장 실패는 어느 쪽이 됐는지 알림") {
        try withInputSwitch { manager, system, _ in
            system.failWritingHotKey = true
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("오른쪽 Command 키 바꾸기는 됐지만") == true, "\(result)")
            t.expect(result.detail?.contains("입력 소스 단축키를 바꾸지 못했습니다") == true, "\(result)")
            t.expectEqual(system.mappings, [rightCommandMapping], "알린 대로 HID는 바뀌어 있음")
            t.expectEqual(system.activations, 0)

            // 끄면 HID 항목을 빼고, 단축키는 원래 그대로라 쓰지 않는다.
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.mappings, [])
            t.expect(!manager.hasAppliedChanges)
        }
    }

    t.suite("한영: 실패 — 단축키가 반영되지 않음") {
        try withInputSwitch { manager, system, _ in
            system.hotKeyDoesntStick = true
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("반영되지 않았습니다") == true, "\(result)")
            t.expectEqual(system.activations, 0)
        }
    }

    t.suite("한영: 실패 — activateSettings 없음, 다음에 다시 시도") {
        try withInputSwitch { manager, system, _ in
            system.activateMissing = true
            let result = manager.apply(on())
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("저장했지만 바로 적용하지 못했습니다") == true, "\(result)")
            t.expect(result.detail?.contains("다시 로그인하면") == true, "\(result)")
            t.expect(system.hotKey?.isActive(.f18) == true, "저장은 됨")

            // 같은 설정으로 다시 부르면 저장은 건너뛰고 반영만 다시 시도한다.
            system.activateMissing = false
            let writes = system.hotKeyWrites
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(system.activations, 1)
            t.expectEqual(system.hotKeyWrites, writes)
            t.expectEqual(manager.apply(on()), .alreadyApplied(.rightCommand))
            t.expectEqual(system.activations, 1)
        }
    }

    t.suite("한영: 실패 — 끌 때 hidutil이 거부하면 상태를 남겨 다시 시도") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            system.failWritingMappings = true
            let result = manager.apply(off)
            t.expectEqual(result.message, "한영 전환 키를 끄지 못했습니다")
            t.expect(result.detail?.contains("입력 소스 단축키도 그대로입니다") == true, "\(result)")
            t.expect(system.hotKey?.isActive(.f18) == true)
            t.expect(manager.hasAppliedChanges, "다시 끌 수 있도록 상태를 남김")

            system.failWritingMappings = false
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.mappings, [])
        }
    }

    t.suite("한영: 실패 — 끌 때 단축키 저장 실패") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            system.failWritingHotKey = true
            let result = manager.apply(off)
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("키는 원래대로 돌렸지만") == true, "\(result)")
            t.expectEqual(system.mappings, [])
            t.expect(manager.hasAppliedChanges)

            system.failWritingHotKey = false
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)
        }
    }

    t.suite("한영: 실패 — 끌 때 activateSettings 없음") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            system.activateMissing = true
            let result = manager.apply(off)
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("다시 로그인하면") == true, "\(result)")
            t.expect(system.hotKey?.behavesLike(.macDefault) == true, "저장은 됨")
            t.expect(manager.hasAppliedChanges, "반영이 남았으므로 상태를 지우지 않음")

            // 다음에 끄면 저장은 건너뛰고 반영만 다시 한다.
            system.activateMissing = false
            let writes = system.hotKeyWrites
            let activations = system.activations
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.hotKeyWrites, writes)
            t.expectEqual(system.activations, activations + 1)
            t.expect(!manager.hasAppliedChanges)
        }
    }

    t.suite("한영: 키를 바꾸다 단축키 저장이 실패한 뒤 끄면 처음 값으로") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            system.failWritingHotKey = true
            let failed = manager.apply(on("shift+space"))
            t.expect(failed.isFailure)
            // 실제로 된 일만 말한다: 오른쪽 Command를 되돌렸고, ⇧Space는 쓰지 못했다.
            t.expect(failed.detail?.contains("오른쪽 Command 키는 원래대로 돌렸지만") == true, "\(failed)")
            t.expect(failed.detail?.contains("⇧Space 키 바꾸기는") == false, "\(failed)")
            t.expectEqual(system.mappings, [])
            t.expect(system.hotKey?.isActive(.f18) == true, "60번에는 아직 MacB가 쓴 F18")
            t.expect(manager.hasAppliedChanges)

            system.failWritingHotKey = false
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")), "F18도 MacB가 쓴 값이라 되돌림")
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)
            t.expect(!manager.hasAppliedChanges)
        }
    }

    t.suite("한영: 키를 바꾸다 hidutil이 실패한 뒤 끄면 처음 값으로") {
        try withInputSwitch { manager, system, _ in
            let shiftSpace = InputSwitchKey(configValue: "shift+space")!
            t.expectEqual(manager.apply(on("shift+space")), .applied(shiftSpace))
            system.failWritingMappings = true
            t.expect(manager.apply(on()).isFailure)
            t.expect(system.hotKey?.isActive(shiftSpace.hotKeyParameters) == true, "⇧Space가 아직 들어 있음")
            system.failWritingMappings = false
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expect(system.hotKey?.behavesLike(.macDefault) == true)
            t.expectEqual(system.mappings, [])
            t.expect(!manager.hasAppliedChanges)
        }
    }

    t.suite("한영: 끄다 실패하면 실제로 남은 키 이름을 알림") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            system.failWritingMappings = true
            t.expect(manager.apply(on("shift+space")).isFailure, "오른쪽 Command 항목을 빼지 못함")
            let result = manager.apply(off)
            t.expect(result.detail?.contains("오른쪽 Command 키를 원래대로 돌리지 못했습니다") == true, "\(result)")
            t.expect(result.detail?.contains("⇧Space") == false, "\(result)")
            system.failWritingMappings = false
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌃Space")))
            t.expectEqual(system.mappings, [])
        }
    }

    t.suite("한영: 이미 같은 단축키를 손으로 써 두었으면 끌 때 건드리지 않음") {
        try withInputSwitch { manager, system, _ in
            let shiftSpace = HotKeyParameters(character: 32, keyCode: 49, modifiers: HotKeyParameters.shiftFlag)
            system.hotKey = SymbolicHotKey(enabled: true, parameters: shiftSpace)
            let key = InputSwitchKey(configValue: "shift+space")!
            t.expectEqual(manager.apply(on("shift+space")), .alreadyApplied(key))
            t.expectEqual(system.writes, 0)
            t.expect(!manager.hasAppliedChanges, "MacB가 바꾼 것이 없으니 적어 둘 것도 없음")
            t.expectEqual(manager.apply(off), .untouched)
            t.expect(system.hotKey?.isActive(shiftSpace) == true, "사용자의 ⇧Space가 그대로")
            t.expectEqual(system.writes, 0)

            // 그 뒤 다른 키로 바꾸면 그때의 값(⇧Space)이 원래 값이다.
            _ = manager.apply(on("shift+space"))
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            t.expectEqual(manager.apply(off), .restored(.shortcut("⇧Space")))
            t.expect(system.hotKey?.isActive(shiftSpace) == true)
        }
    }

    t.suite("한영: 재부팅 뒤 키 바꾸기만 다시 걸면 remapped") {
        try withInputSwitch { manager, system, _ in
            t.expectEqual(manager.apply(on()), .applied(.rightCommand))
            let hotKeyWrites = system.hotKeyWrites
            let activations = system.activations
            system.mappings = []
            t.expectEqual(manager.apply(on()), .remapped(.rightCommand))
            t.expectEqual(system.mappings, [rightCommandMapping])
            t.expectEqual(system.hotKeyWrites, hotKeyWrites, "입력 소스 단축키는 쓰지 않음")
            t.expectEqual(system.activations, activations)
            t.expectEqual(InputSwitchResult.remapped(.rightCommand).message, "한영 전환: 오른쪽 Command")
            t.expectEqual(InputSwitchStatus(.remapped(.rightCommand)).kind, .active)
        }
    }

    t.suite("한영: 예전(1판) 상태 파일도 읽어 되돌림") {
        try withInputSwitch { manager, system, stateFile in
            let commandSpace: NSDictionary = ["enabled": true, "value": ["type": "standard", "parameters": [32, 49, 1_048_576]]]
            let root: [String: Any] = [
                "version": 1, "key": "right_command",
                "keyMappings": [["source": NSNumber(value: rightCommandMapping.source), "destination": NSNumber(value: rightCommandMapping.destination)]],
                "originalHotKey": commandSpace, "needsActivation": false,
            ]
            try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0).write(to: stateFile)
            system.mappings = [rightCommandMapping]
            system.hotKey = SymbolicHotKey(enabled: true, parameters: .f18)
            t.expectEqual(manager.apply(off), .restored(.shortcut("⌘Space")))
            t.expectEqual(system.mappings, [])
            t.expect(system.hotKey?.dictionary.isEqual(commandSpace) == true)
        }
    }

    t.suite("한영: 글자를 치는 조합은 config.json에 적혀 있어도 적용하지 않음") {
        try withInputSwitch { manager, system, _ in
            let result = manager.apply(on("shift+a"))
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("shift+a") == true, "\(result)")
            t.expectEqual(system.writes, 0)
            t.expect(!manager.hasAppliedChanges)
            t.expect(manager.apply(on("command+space")).isFailure, "Spotlight 단축키")
            t.expectEqual(system.writes, 0)
            let controlC = manager.apply(on("control+c"))
            t.expect(controlC.isFailure, "터미널의 ⌃C")
            t.expect(controlC.detail?.contains("터미널과 글 입력 칸에서 늘 쓰는 키") == true, "\(controlC)")
            t.expect(manager.apply(on("control+shift+a")).isFailure)
            t.expectEqual(system.writes, 0)
            t.expect(!manager.hasAppliedChanges)
            t.expect(!manager.apply(on("control+space")).isFailure, "⌃Space는 그대로 됨")
        }
    }

    t.suite("한영: 켜기·키 바꾸기·실패·끄기를 어떤 순서로 해도 끄면 원래대로") {
        try checkInputSwitchSequences(t)
    }

    t.suite("한영: 실패 — 상태 파일이 깨져 있으면 아무것도 건드리지 않음") {
        try withInputSwitch { manager, system, stateFile in
            try Data("not a plist".utf8).write(to: stateFile)
            let turningOn = manager.apply(on())
            t.expect(turningOn.isFailure)
            t.expect(turningOn.detail?.contains("상태 파일") == true, "\(turningOn)")
            let turningOff = manager.apply(off)
            t.expect(turningOff.isFailure)
            t.expectEqual(system.writes, 0)
        }
    }

    t.suite("한영: 실패 — 해석할 수 없는 키") {
        try withInputSwitch { manager, system, _ in
            let result = manager.apply(on("left_banana"))
            t.expect(result.isFailure)
            t.expect(result.detail?.contains("left_banana") == true, "\(result)")
            t.expectEqual(system.writes, 0)
        }
    }

    t.suite("한영: 알림 문구") {
        t.expectEqual(InputSwitchResult.applied(.rightCommand).message, "한영 전환: 오른쪽 Command")
        t.expectEqual(InputSwitchResult.restored(.shortcut("⌃Space")).message, "한영 전환 키를 껐습니다 · ⌃Space로 되돌림")
        t.expectEqual(InputSwitchResult.untouched.statusText, "꺼져 있습니다")
        t.expect(InputSwitchResult.failed(turningOn: true, reason: "x").isFailure)
        t.expect(!InputSwitchResult.alreadyApplied(.rightOption).isFailure)
        t.expectEqual(InputSwitchManager.defaultStateFile.deletingLastPathComponent().standardizedFileURL,
                      AppPaths.supportDirectory.standardizedFileURL)
    }

    t.suite("한영: 백그라운드 적용 후 메인 스레드로 결과") {
        try withInputSwitch { manager, system, _ in
            var received: [InputSwitchResult] = []
            manager.applyInBackground(on()) { received.append($0) }
            manager.applyInBackground(off) { received.append($0) }
            let deadline = Date().addingTimeInterval(3)
            while received.count < 2 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            t.expectEqual(received, [.applied(.rightCommand), .restored(.shortcut("⌃Space"))], "넘긴 순서대로")
            t.expectEqual(system.mappings, [])
        }
    }
}

/// 켜기(키마다)·끄기를 실패 하나씩과 함께 이어 부른 뒤, 실패 없이 끄면 늘 처음 상태로 돌아오는지 본다.
/// 두 단계는 모든 조합을, 그보다 긴 것은 정해진 씨앗으로 고른 조합을 돌린다. 매 단계 뒤에는
/// "상태 파일이 없으면 시스템도 처음 그대로"(MacB가 바꾼 것이 남아 있는데 상태를 지우지 않음)도 본다.
@MainActor
private func checkInputSwitchSequences(_ t: TestRunner) throws {
    enum Failure: CaseIterable {
        case none, readMappings, writeMappings, mappingsDontStick, writeHotKey, hotKeyDoesntStick, activate
    }
    typealias Step = (key: String?, failure: Failure)
    let keys: [String?] = ["right_command", "right_option", "shift+space", "control+option+space", nil]
    let steps: [Step] = keys.flatMap { key in Failure.allCases.map { (key, $0) } }

    let foreign = HIDKeyMapping(source: 0x7_0000_0039, destination: 0x7_0000_0029)
    func hotKey(_ modifiers: Int, enabled: Bool = true) -> SymbolicHotKey {
        SymbolicHotKey(enabled: enabled, parameters: HotKeyParameters(character: 32, keyCode: 49, modifiers: modifiers))
    }
    let starts: [(hotKey: SymbolicHotKey?, mappings: [HIDKeyMapping])] = [
        (.macDefault, []),
        (hotKey(HotKeyParameters.commandFlag), [foreign]),
        (hotKey(HotKeyParameters.controlFlag, enabled: false), []),
        (nil, [foreign]),
        (hotKey(HotKeyParameters.shiftFlag), []),
    ]

    let directory = makeTemporaryDirectory("macb-input-switch-sequences")
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("input-switch.plist")

    var sequences: [[Step]] = []
    for first in steps {
        for second in steps { sequences.append([first, second]) }
    }
    var seed: UInt64 = 0x4D41_4342
    func next(_ bound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(bound))
    }
    for _ in 0..<1500 {
        sequences.append((0..<(3 + next(3))).map { _ in steps[next(steps.count)] })
    }

    var problems: [String] = []
    var runs = 0
    for start in starts {
        for sequence in sequences {
            try? FileManager.default.removeItem(at: stateFile)
            let system = FakeKeyboardSystem()
            system.hotKey = start.hotKey
            system.mappings = start.mappings
            let manager = InputSwitchManager(system: system, stateFile: stateFile)
            let original = start.hotKey ?? .macDefault
            func describe() -> String {
                let text = sequence.map { "\($0.key ?? "off")/\($0.failure)" }.joined(separator: " → ")
                return "[\(original.parameters?.displayString ?? "?")\(original.isEnabled ? "" : " 꺼짐")] \(text)"
            }
            func backToStart() -> Bool {
                system.mappings == start.mappings && (system.hotKey ?? .macDefault).behavesLike(original)
            }

            for step in sequence {
                system.failReadingMappings = step.failure == .readMappings
                system.failWritingMappings = step.failure == .writeMappings
                system.mappingsDontStick = step.failure == .mappingsDontStick
                system.failWritingHotKey = step.failure == .writeHotKey
                system.hotKeyDoesntStick = step.failure == .hotKeyDoesntStick
                system.activateMissing = step.failure == .activate
                _ = manager.apply(.init(enabled: step.key != nil, key: step.key ?? "right_command"))
                if !manager.hasAppliedChanges, !backToStart() {
                    problems.append("상태 파일 없이 바뀐 것이 남음: \(describe()) 뒤 \(step.key ?? "off")")
                }
            }
            system.failReadingMappings = false
            system.failWritingMappings = false
            system.mappingsDontStick = false
            system.failWritingHotKey = false
            system.hotKeyDoesntStick = false
            system.activateMissing = false

            let result = manager.apply(.init(enabled: false, key: "right_command"))
            if result.isFailure { problems.append("끄기 실패 \(result): \(describe())") }
            if !backToStart() {
                problems.append("처음으로 안 돌아옴 (\(system.mappings), \(system.hotKey?.parameters?.displayString ?? "nil")): \(describe())")
            }
            if manager.hasAppliedChanges { problems.append("상태 파일이 남음: \(describe())") }
            let writes = system.writes
            if manager.apply(.init(enabled: false, key: "right_command")) != .untouched || system.writes != writes {
                problems.append("다시 끄면 아무것도 안 해야 함: \(describe())")
            }
            runs += 1
        }
    }
    t.expect(problems.isEmpty, "\(problems.count)개 실패, 예: " + problems.prefix(4).joined(separator: " | "))
    t.expect(runs == starts.count * (steps.count * steps.count + 1500), "돌린 횟수 \(runs)")
}

/// 가짜 시스템과 임시 상태 파일로 관리자를 만든다.
@MainActor
private func withInputSwitch(_ body: (InputSwitchManager, FakeKeyboardSystem, URL) throws -> Void) throws {
    let directory = makeTemporaryDirectory("macb-input-switch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("input-switch.plist")
    let system = FakeKeyboardSystem()
    try body(InputSwitchManager(system: system, stateFile: stateFile), system, stateFile)
}

/// 메모리 속 키보드 설정. 실패를 골라 일으킬 수 있다.
final class FakeKeyboardSystem: KeyboardSystem {
    var mappings: [HIDKeyMapping] = []
    var hotKey: SymbolicHotKey? = .macDefault

    var failReadingMappings = false
    var failWritingMappings = false
    /// hidutil은 성공을 돌려주지만 실제로는 바뀌지 않는다.
    var mappingsDontStick = false
    var failWritingHotKey = false
    /// 저장은 성공했다고 하지만 다시 읽으면 예전 값.
    var hotKeyDoesntStick = false
    var activateMissing = false

    private(set) var mappingWrites = 0
    private(set) var hotKeyWrites = 0
    private(set) var activations = 0
    var writes: Int { mappingWrites + hotKeyWrites + activations }

    func keyMappings() throws -> [HIDKeyMapping] {
        if failReadingMappings { throw KeyboardSystemError("hidutil이 실패했습니다 (종료 코드 1)") }
        return mappings
    }

    func setKeyMappings(_ mappings: [HIDKeyMapping]) throws {
        if failWritingMappings { throw KeyboardSystemError("hidutil이 실패했습니다 (종료 코드 1)") }
        mappingWrites += 1
        if !mappingsDontStick { self.mappings = mappings }
    }

    func inputSourceHotKey() -> SymbolicHotKey? {
        hotKey
    }

    func setInputSourceHotKey(_ hotKey: SymbolicHotKey) throws {
        if failWritingHotKey { throw KeyboardSystemError("환경설정(com.apple.symbolichotkeys)을 저장하지 못했습니다") }
        hotKeyWrites += 1
        if !hotKeyDoesntStick { self.hotKey = hotKey }
    }

    func activateSettings() throws {
        if activateMissing { throw KeyboardSystemError("activateSettings가 없습니다") }
        activations += 1
    }
}
