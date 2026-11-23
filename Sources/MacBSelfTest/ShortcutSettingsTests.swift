import Carbon.HIToolbox
import Foundation
import MacBKit

/// '단축키 설정' 창의 편집 논리 테스트. 창은 만들지 않는다.
@MainActor
func runShortcutSettingsTests(_ t: TestRunner) {
    let tools: [ShortcutSettings.Tool] = [
        .init(id: "capture.area.clipboard", title: "영역 캡처", symbol: "rectangle.dashed"),
        .init(id: "capture.ocr", title: "글자 인식", symbol: "text.viewfinder"),
        .init(id: "capture.color", title: "색상 추출", symbol: "eyedropper"),
    ]
    func combo(_ text: String) -> KeyCombo {
        KeyCombo(string: text)!
    }
    func edit(_ config: AppConfig, _ edit: ShortcutSettings.Edit) -> Result<AppConfig, ShortcutSettings.Refusal> {
        ShortcutSettings(config: config, tools: tools).applying(edit)
    }
    func expectSuccess(_ result: Result<AppConfig, ShortcutSettings.Refusal>, file: StaticString = #fileID, line: UInt = #line) -> AppConfig {
        switch result {
        case .success(let config):
            return config
        case .failure(let refusal):
            t.expect(false, "거부됨: \(refusal.message)", file: file, line: line)
            return AppConfig()
        }
    }
    func refusal(_ result: Result<AppConfig, ShortcutSettings.Refusal>) -> ShortcutSettings.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    t.suite("단축키 설정: 기본 설정의 줄") {
        let settings = ShortcutSettings(config: AppConfig(), tools: tools)
        t.expectEqual(settings.basicRows.map(\.field), [.radialMenu, .clipboardHistory, .slotPaste, .slotCopy])
        t.expectEqual(settings.basicRows.map(\.value), [
            .combo(combo("option+tab")), .combo(combo("option+v")), .modifiers([.option]), .modifiers([.control, .option]),
        ])
        t.expectEqual(settings.basicRows[2].recording, .modifiers)
        t.expectEqual(settings.basicRows[0].recording, .combo)
        t.expectEqual(settings.toolRows.map(\.title), ["영역 캡처", "글자 인식", "색상 추출"])
        t.expect(settings.toolRows.allSatisfy { $0.value == .none })
        t.expect(settings.appRows.isEmpty)
        t.expect(settings.otherRows.isEmpty)
        t.expectEqual(settings.inputSwitchEnabled, false)
        t.expectEqual(settings.inputSwitchKey, .rightCommand)
    }

    t.suite("단축키 설정: 기능에 단축키 지정·바꾸기·지우기") {
        let assigned = expectSuccess(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("control+shift+2"))))
        t.expectEqual(assigned.shortcuts, [AppConfig.Shortcut(key: "control+shift+2", item: .init(action: "capture.ocr"))])
        t.expectEqual(ShortcutSettings(config: assigned, tools: tools).toolRows[1].value, .combo(combo("control+shift+2")))

        let changed = expectSuccess(edit(assigned, .setCombo(.tool("capture.ocr"), combo("control+option+o"))))
        t.expectEqual(changed.shortcuts.count, 1, "같은 항목을 고쳐야 함")
        t.expectEqual(changed.shortcuts.first?.key, "control+option+o")

        let same = expectSuccess(edit(changed, .setCombo(.tool("capture.ocr"), combo("control+option+o"))))
        t.expectEqual(same, changed, "자기 자신과는 겹치지 않음")

        let cleared = expectSuccess(edit(changed, .setCombo(.tool("capture.ocr"), nil)))
        t.expectEqual(cleared.shortcuts, [], "지우면 목록에서 빠짐")
        t.expectEqual(expectSuccess(edit(cleared, .setCombo(.tool("capture.ocr"), nil))), cleared, "없는 것을 지워도 그대로")
        t.expectEqual(expectSuccess(edit(changed, .remove(.tool("capture.ocr")))), cleared)
    }

    t.suite("단축키 설정: 기본 단축키 바꾸기·끄기") {
        let changed = expectSuccess(edit(AppConfig(), .setCombo(.radialMenu, combo("command+shift+space"))))
        t.expectEqual(changed.hotkeys.radialMenu, "shift+command+space")
        t.expectEqual(KeyCombo(string: changed.hotkeys.radialMenu), combo("cmd+shift+space"))
        let off = expectSuccess(edit(changed, .setCombo(.clipboardHistory, nil)))
        t.expectEqual(off.hotkeys.clipboardHistory, "", "빈 문자열 = 끔")
        t.expectEqual(ShortcutSettings(config: off, tools: tools).basicRows[1].value, .none)

        var broken = AppConfig()
        broken.hotkeys.radialMenu = "option+nope"
        t.expectEqual(ShortcutSettings(config: broken, tools: tools).basicRows[0].value, .invalid("option+nope"))
        let fixed = expectSuccess(edit(broken, .setCombo(.radialMenu, combo("option+tab"))))
        t.expectEqual(fixed.hotkeys.radialMenu, "option+tab")
    }

    t.suite("단축키 설정: 겹치는 단축키는 거부하고 주인을 알려 줌") {
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("option+tab")))), .inUse("원형 메뉴"))
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("option+v")))), .inUse("클립보드 기록"))
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("option+3")))), .inUse("슬롯 붙여넣기"))
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.radialMenu, combo("control+option+5")))), .inUse("슬롯에 복사"))
        t.expect(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("option+0")))) == nil, "0은 슬롯이 아님")

        let withOCR = expectSuccess(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("control+shift+2"))))
        t.expectEqual(refusal(edit(withOCR, .setCombo(.tool("capture.color"), combo("control+shift+2")))), .inUse("글자 인식"))
        t.expectEqual(refusal(edit(withOCR, .setCombo(.clipboardHistory, combo("control+shift+2")))), .inUse("글자 인식"))
        t.expectEqual(refusal(edit(withOCR, .setCombo(.inputSwitch, combo("control+shift+2")))), .inUse("글자 인식"))

        var withApp = withOCR
        withApp.shortcuts.append(.init(key: "control+option+t", item: .init(title: "터미널", app: "com.apple.Terminal")))
        t.expectEqual(refusal(edit(withApp, .setCombo(.tool("capture.color"), combo("control+option+t")))), .inUse("터미널"))

        // 켜 둔 한영 전환 키 조합과도 겹치면 안 된다.
        var withSwitch = AppConfig()
        withSwitch.keyboard.inputSwitch = .init(enabled: true, key: "control+space")
        t.expectEqual(refusal(edit(withSwitch, .setCombo(.tool("capture.ocr"), combo("control+space")))), .inUse("한영 전환"))
        withSwitch.keyboard.inputSwitch.enabled = false
        t.expect(refusal(edit(withSwitch, .setCombo(.tool("capture.ocr"), combo("control+space")))) == nil, "꺼져 있으면 비어 있는 조합")
        // 보조키 하나 방식은 그 키가 F18로 들어온다.
        withSwitch.keyboard.inputSwitch = .init(enabled: true, key: "right_command")
        t.expectEqual(refusal(edit(withSwitch, .setCombo(.tool("capture.ocr"), combo("f18")))), .inUse("한영 전환"))
    }

    t.suite("단축키 설정: 보조키 규칙") {
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("a")))), .needsModifier)
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("shift+a")))), .needsModifier, "⇧만으로는 부족")
        t.expect(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("f5")))) == nil, "F키는 혼자 써도 됨")
        t.expect(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("shift+f6")))) == nil)
        let keypad = KeyCombo(keyCode: UInt32(kVK_ANSI_Keypad5), modifiers: [.control])
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), keypad))), .unsupportedKey)
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.slotPaste, combo("option+1")))), .notEditable)
        t.expectEqual(refusal(edit(AppConfig(), .setCombo(.inputSwitch, nil))), .notEditable)
        t.expect(!ShortcutSettings.Refusal.inUse("원형 메뉴").message.isEmpty)
    }

    t.suite("단축키 설정: 숫자 슬롯은 보조키만") {
        let paste = expectSuccess(edit(AppConfig(), .setModifiers(.slotPaste, [.control, .shift])))
        t.expectEqual(paste.hotkeys.slotPasteModifiers, "control+shift")
        t.expectEqual(ShortcutSettings(config: paste, tools: tools).basicRows[2].value, .modifiers([.control, .shift]))
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotPaste, [.control, .option]))), .inUse("슬롯에 복사"))
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotCopy, [.option]))), .inUse("슬롯 붙여넣기"))
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotPaste, [.shift]))), .needsSlotModifier)
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotPaste, []))), .needsSlotModifier)
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.radialMenu, [.option]))), .notEditable)
        let off = expectSuccess(edit(AppConfig(), .setModifiers(.slotPaste, nil)))
        t.expectEqual(off.hotkeys.slotPasteModifiers, "")
        t.expectEqual(ShortcutSettings(config: off, tools: tools).basicRows[2].value, .none)

        // 숫자 키를 쓰는 다른 단축키와 겹치면 거부.
        let withDigit = expectSuccess(edit(AppConfig(), .setCombo(.tool("capture.color"), combo("control+shift+3"))))
        t.expectEqual(refusal(edit(withDigit, .setModifiers(.slotCopy, [.control, .shift]))), .inUse("색상 추출"))
    }

    t.suite("단축키 설정: 앱 줄 더하기·지정·지우기") {
        let added = expectSuccess(edit(AppConfig(), .addApp(reference: "com.apple.Terminal", title: "터미널")))
        let rows = ShortcutSettings(config: added, tools: tools).appRows
        t.expectEqual(rows.count, 1)
        t.expectEqual(rows.first?.title, "터미널")
        t.expectEqual(rows.first?.app, "com.apple.Terminal")
        t.expectEqual(rows.first?.value, ShortcutSettings.Value.none)
        t.expectEqual(rows.first?.isRemovable, true)
        t.expectEqual(added.shortcuts.first?.key, "", "단축키 없이도 목록에 남음")

        guard let field = rows.first?.field else { return }
        let keyed = expectSuccess(edit(added, .setCombo(field, combo("control+option+t"))))
        t.expectEqual(keyed.shortcuts.first?.key, "control+option+t")
        t.expectEqual(keyed.shortcuts.first?.item.app, "com.apple.Terminal")

        let second = expectSuccess(edit(keyed, .addApp(reference: "/Applications/Example Tool.app", title: nil)))
        let secondRows = ShortcutSettings(config: second, tools: tools).appRows
        t.expectEqual(secondRows.map(\.title), ["터미널", "Example Tool"])

        let removed = expectSuccess(edit(second, .remove(field)))
        t.expectEqual(removed.shortcuts.map(\.item.app), ["/Applications/Example Tool.app"])
        t.expectEqual(refusal(edit(removed, .remove(.entry(7)))), .notEditable)
        t.expectEqual(refusal(edit(removed, .remove(.radialMenu))), .notEditable)
    }

    t.suite("단축키 설정: 다른 종류의 항목은 건드리지 않음") {
        let original = try AppConfig.decode(Data("""
        {
          "shortcuts": [
            { "key": "control+option+n", "title": "메모", "icon": "note.text", "shell": "open -a Notes" },
            { "key": "control+option+g", "title": "GitHub", "url": "https://github.com" },
            { "key": "", "shortcut": "집중 모드 켜기" },
            { "key": "control+option+x", "action": "capture.nope" },
            { "key": "control+shift+2", "action": "capture.ocr" },
            { "key": "control+shift+3", "action": "capture.ocr", "title": "OCR 하나 더" },
            { "key": "control+option+s", "app": "Safari" }
          ]
        }
        """.utf8))
        let settings = ShortcutSettings(config: original, tools: tools)
        t.expectEqual(settings.toolRows[1].value, .combo(combo("control+shift+2")), "첫 항목이 기능 줄")
        t.expectEqual(settings.appRows.map(\.title), ["Safari"])
        t.expectEqual(settings.otherRows.map(\.title), ["메모", "GitHub", "집중 모드 켜기", "capture.nope", "OCR 하나 더"])
        t.expectEqual(settings.otherRows.map(\.detail), [
            "open -a Notes", "https://github.com", "단축어 실행", "알 수 없는 기능: capture.nope", "글자 인식의 다른 단축키",
        ])
        t.expectEqual(settings.otherRows.first?.symbol, "note.text")
        t.expect(settings.otherRows.allSatisfy { !$0.isRemovable })

        // 다른 줄을 여러 번 고쳐도 그 밖의 항목은 그대로 남는다.
        var config = expectSuccess(settings.applying(.setCombo(.tool("capture.color"), combo("control+option+c"))))
        config = expectSuccess(edit(config, .remove(ShortcutSettings(config: config, tools: tools).appRows[0].field)))
        config = expectSuccess(edit(config, .setCombo(.tool("capture.ocr"), nil)))
        let untouched = original.shortcuts.filter { $0.item.app == nil && !($0.item.action == "capture.ocr" && $0.item.title == nil) }
        t.expectEqual(config.shortcuts.filter { $0.item.action != "capture.color" }, untouched)

        // 그 밖의 항목도 단축키는 바꿀 수 있다.
        let other = ShortcutSettings(config: config, tools: tools).otherRows[0]
        let rekeyed = expectSuccess(edit(config, .setCombo(other.field, combo("control+option+m"))))
        guard case .entry(let index) = other.field else { return }
        t.expectEqual(rekeyed.shortcuts[index].key, "control+option+m")
        t.expectEqual(rekeyed.shortcuts[index].item, config.shortcuts[index].item)

        let reloaded = try AppConfig.decode(rekeyed.encoded())
        t.expectEqual(reloaded, rekeyed, "저장 후 다시 읽어도 같음")
    }

    t.suite("단축키 설정: 한영 전환 키 편집") {
        let enabled = expectSuccess(edit(AppConfig(), .setInputSwitchEnabled(true)))
        t.expectEqual(enabled.keyboard.inputSwitch, .init(enabled: true, key: "right_command"))
        let option = expectSuccess(edit(enabled, .setInputSwitchKey(.rightOption)))
        t.expectEqual(option.keyboard.inputSwitch.key, "right_option")
        let custom = expectSuccess(edit(option, .setInputSwitchKey(.combo(combo("shift+space")))))
        t.expectEqual(custom.keyboard.inputSwitch.key, "shift+space", "한영 전환은 ⇧ 하나만으로도 됨")
        t.expectEqual(ShortcutSettings(config: custom, tools: tools).inputSwitchKey, .combo(combo("shift+space")))
        t.expectEqual(expectSuccess(edit(option, .setCombo(.inputSwitch, combo("shift+space")))), custom)
        t.expectEqual(refusal(edit(option, .setInputSwitchKey(.combo(combo("space"))))), .inputSwitchNeedsModifier)
        t.expect(refusal(edit(option, .setInputSwitchKey(.combo(combo("f13"))))) == nil)

        // 이미 다른 기능이 쓰는 조합으로 켜거나 바꾸면 거부.
        var taken = expectSuccess(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("control+option+space"))))
        taken.keyboard.inputSwitch.key = "control+option+space"
        t.expectEqual(refusal(edit(taken, .setInputSwitchEnabled(true))), .inUse("글자 인식"))
        var radial = AppConfig()
        radial.hotkeys.radialMenu = "control+option+r"
        t.expectEqual(refusal(edit(radial, .setInputSwitchKey(.combo(combo("control+option+r"))))), .inUse("원형 메뉴"))
        let disabled = expectSuccess(edit(enabled, .setInputSwitchEnabled(false)))
        t.expectEqual(disabled.keyboard.inputSwitch.enabled, false)
    }

    t.suite("단축키 설정: 한영 전환 키는 글자를 치거나 편집에 쓰는 조합을 받지 않음") {
        // 입력 소스 단축키는 MacB를 꺼도 남는다. ⇧A로 정하면 어디서도 대문자 A를 칠 수 없게 된다.
        for text in ["shift+a", "shift+1", "shift+slash", "shift+tab", "shift+return", "shift+left", "shift+delete",
                     "option+e", "option+space", "option+shift+k", "space", "a"] {
            t.expectEqual(refusal(edit(AppConfig(), .setInputSwitchKey(.combo(combo(text))))), .inputSwitchNeedsModifier, text)
            t.expectEqual(refusal(edit(AppConfig(), .setCombo(.inputSwitch, combo(text)))), .inputSwitchNeedsModifier, text)
        }
        for text in ["shift+space", "control+space", "control+option+space", "control+shift+space", "command+shift+space",
                     "f13", "shift+f13", "control+option+a", "control+command+k"] {
            t.expect(refusal(edit(AppConfig(), .setInputSwitchKey(.combo(combo(text))))) == nil, text)
        }
        // ⌃ + 글자는 터미널(⌃C)과 글 입력 칸(⌃A·⌃E)이 쓴다. 입력 소스 단축키가 되면 MacB를 꺼도 그 키가 막힌다.
        for text in ["control+a", "control+c", "control+e", "control+z", "control+shift+e", "control+shift+k"] {
            let expected = ShortcutSettings.Refusal.reserved(shortcut: combo(text).displayString, reason: "터미널과 글 입력 칸에서 늘 쓰는 키")
            t.expectEqual(refusal(edit(AppConfig(), .setInputSwitchKey(.combo(combo(text))))), expected, text)
            t.expectEqual(refusal(edit(AppConfig(), .setCombo(.inputSwitch, combo(text)))), expected, text)
            t.expectEqual(ShortcutSettings.inputSwitchRefusal(for: combo(text)), expected, text)
        }
        t.expectEqual(ShortcutSettings.inputSwitchRefusal(for: combo("control+c"))?.message,
                      "터미널과 글 입력 칸에서 늘 쓰는 키라 쓸 수 없습니다 (⌃C)")
        // 일반 전역 단축키는 이번 규칙과 상관없다.
        t.expect(refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo("control+a")))) == nil, "전역 단축키 ⌃A는 그대로")
        t.expectEqual(refusal(edit(AppConfig(), .setInputSwitchKey(.combo(combo("command+space"))))),
                      .reserved(shortcut: "⌘Space", reason: "Spotlight 단축키"))
        t.expectEqual(ShortcutSettings.inputSwitchRefusal(for: combo("shift+a")), .inputSwitchNeedsModifier)
        t.expect(ShortcutSettings.inputSwitchRefusal(for: combo("shift+space")) == nil)
    }

    t.suite("단축키 설정: 모든 앱·macOS가 쓰는 조합은 거절") {
        for (text, reason) in [
            ("command+w", "모든 앱이 쓰는 단축키"), ("command+q", "모든 앱이 쓰는 단축키"), ("command+c", "모든 앱이 쓰는 단축키"),
            ("command+v", "모든 앱이 쓰는 단축키"), ("command+1", "모든 앱이 쓰는 단축키"), ("command+comma", "모든 앱이 쓰는 단축키"),
            ("command+grave", "모든 앱이 쓰는 단축키"), ("shift+command+z", "모든 앱이 쓰는 단축키"),
            ("command+tab", "앱 전환 단축키"), ("command+space", "Spotlight 단축키"), ("shift+command+3", "macOS 스크린샷 단축키"),
            ("shift+command+4", "macOS 스크린샷 단축키"), ("option+command+escape", "강제 종료 단축키"),
            ("control+command+q", "화면 잠금 단축키"), ("control+tab", "탭 전환에 모든 앱이 쓰는 단축키"),
            ("option+left", "글자 편집·이동에 늘 쓰는 키"), ("command+right", "글자 편집·이동에 늘 쓰는 키"),
            ("shift+option+up", "글자 편집·이동에 늘 쓰는 키"), ("control+left", "Mission Control 단축키"),
            ("option+delete", "글자 편집에 늘 쓰는 키"), ("command+forwarddelete", "글자 편집에 늘 쓰는 키"),
        ] {
            let found = refusal(edit(AppConfig(), .setCombo(.tool("capture.ocr"), combo(text))))
            t.expectEqual(found, .reserved(shortcut: combo(text).displayString, reason: reason), text)
            t.expectEqual(refusal(edit(AppConfig(), .setCombo(.radialMenu, combo(text)))), found, "원형 메뉴도 같음: \(text)")
        }
        let message = ShortcutSettings.Refusal.reserved(shortcut: "⌘W", reason: "모든 앱이 쓰는 단축키").message
        t.expectEqual(message, "모든 앱이 쓰는 단축키라 쓸 수 없습니다 (⌘W)")

        // 앱마다 겹치지 않는 조합은 그대로 받는다.
        for text in ["control+option+c", "option+command+c", "control+option+left", "control+command+left", "control+option+delete",
                     "shift+command+space", "control+shift+4", "option+v", "f5"] {
            var config = AppConfig()
            config.hotkeys.clipboardHistory = ""
            t.expect(refusal(edit(config, .setCombo(.tool("capture.ocr"), combo(text)))) == nil, text)
        }

        // 숫자 슬롯: ⌘1–9는 브라우저 탭 등이, ⇧⌘3·4·5는 스크린샷이 쓴다.
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotPaste, [.command]))),
                      .reserved(shortcut: "⌘ + 숫자", reason: "모든 앱이 쓰는 단축키"))
        t.expectEqual(refusal(edit(AppConfig(), .setModifiers(.slotCopy, [.command, .shift]))),
                      .reserved(shortcut: "⇧⌘ + 숫자", reason: "macOS 스크린샷 단축키"))
        t.expect(refusal(edit(AppConfig(), .setModifiers(.slotCopy, [.command, .option]))) == nil)

        // 기본 설정의 단축키는 모두 받아들여진다.
        let defaults = AppConfig().hotkeys
        for text in [defaults.radialMenu, defaults.clipboardHistory] {
            t.expect(ShortcutSettings.reservedRefusal(for: combo(text)) == nil, text)
        }
    }

    t.suite("단축키 설정: 저장한 설정을 다시 읽으면 똑같음") {
        // 창에서 저장하면 감시기가 파일을 다시 읽는다. 그 결과가 같아야 알림 없이 조용히 끝난다.
        var config = AppConfig()
        let edits: [ShortcutSettings.Edit] = [
            .setCombo(.tool("capture.ocr"), combo("control+option+o")),
            .addApp(reference: "com.apple.Terminal", title: "터미널"),
            .setCombo(.entry(1), combo("control+option+t")),
            .setModifiers(.slotPaste, KeyModifiers([.control])),
            .setCombo(.clipboardHistory, nil),
            .setInputSwitchKey(.combo(combo("shift+space"))),
            .setInputSwitchEnabled(true),
        ]
        for step in edits {
            config = expectSuccess(edit(config, step))
            let reread = try AppConfig.decode(config.encoded())
            t.expectEqual(reread, config, "\(step)")
        }
        t.expectEqual(config.shortcuts.count, 2)

        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try config.save(to: file)
        let loaded = try AppConfig.load(from: file)
        t.expectEqual(loaded, config)
    }

    t.suite("설정 저장: 심볼릭 링크는 링크로 남음") {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dotfiles = directory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("macb.json")
        try AppConfig().save(to: real)
        let link = directory.appendingPathComponent("config.json")
        // 상대 경로 링크(dotfiles 관리 도구가 흔히 만드는 모양).
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/macb.json")

        var config = AppConfig()
        config.keyboard.inputSwitch.enabled = true
        try config.save(to: link)
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        t.expectEqual(linkDestination, "dotfiles/macb.json", "링크가 보통 파일로 바뀌면 안 됨")
        let savedReal = try AppConfig.decode(Data(contentsOf: real))
        t.expectEqual(savedReal, config, "실제 파일에 저장")
        let loadedThroughLink = try AppConfig.load(from: link)
        t.expectEqual(loadedThroughLink, config)

        // 링크를 거쳐 가는 링크.
        let outer = directory.appendingPathComponent("outer.json")
        try FileManager.default.createSymbolicLink(atPath: outer.path, withDestinationPath: link.path)
        config.keyboard.inputSwitch.key = "right_option"
        try config.save(to: outer)
        let outerDestination = try FileManager.default.destinationOfSymbolicLink(atPath: outer.path)
        t.expectEqual(outerDestination, link.path)
        let innerDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        t.expectEqual(innerDestination, "dotfiles/macb.json")
        let savedThroughChain = try AppConfig.decode(Data(contentsOf: real))
        t.expectEqual(savedThroughChain, config)
    }

    t.suite("단축키 표기: 설정 문자열로 되돌리기") {
        let names = (UnicodeScalar("a").value...UnicodeScalar("z").value).map { String(UnicodeScalar($0)!) }
            + (0...9).map(String.init) + (1...19).map { "f\($0)" }
            + ["tab", "space", "return", "escape", "delete", "forwarddelete", "left", "right", "up", "down",
               "home", "end", "pageup", "pagedown", "grave", "minus", "equal", "leftbracket", "rightbracket",
               "backslash", "semicolon", "quote", "comma", "period", "slash"]
        for name in names {
            let text = "control+option+shift+command+" + name
            t.expectEqual(KeyCombo(string: text)?.configString, text, name)
            t.expectEqual(KeyCombo(string: name)?.configString, name, name)
        }
        t.expectEqual(KeyCombo(string: "cmd+alt+esc")?.configString, "option+command+escape", "대표 이름으로")
        t.expect(KeyCombo(keyCode: UInt32(kVK_ANSI_Keypad5), modifiers: []).configString == nil)
        t.expectEqual(KeyModifiers([.command, .control]).configString, "control+command")
        t.expectEqual(KeyModifiers().configString, "")
        t.expect(combo("f19").isFunctionKey)
        t.expect(!combo("control+a").isFunctionKey)
    }
}
