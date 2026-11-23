import AppKit
import Carbon.HIToolbox
import MacBKit

@MainActor
func runKitTests(_ t: TestRunner) {
    t.suite("KeyCombo: 문자열 해석") {
        let tab = KeyCombo(string: "option+tab")
        t.expectEqual(tab?.keyCode, UInt32(kVK_Tab))
        t.expectEqual(tab?.modifiers, [.option])
        t.expectEqual(tab?.displayString, "⌥⇥")

        let shot = KeyCombo(string: " Cmd + Shift + 4 ")
        t.expectEqual(shot?.keyCode, UInt32(kVK_ANSI_4))
        t.expectEqual(shot?.modifiers, [.command, .shift])
        t.expectEqual(shot?.displayString, "⇧⌘4")

        t.expectEqual(KeyCombo(string: "ctrl+alt+v")?.displayString, "⌃⌥V")
        t.expectEqual(KeyCombo(string: "f5")?.modifiers, [])
        t.expect(KeyCombo(string: "option") == nil, "키 없이 보조키만 있으면 실패해야 함")
        t.expect(KeyCombo(string: "option+a+b") == nil, "키가 둘이면 실패해야 함")
        t.expect(KeyCombo(string: "option+nope") == nil)
        t.expect(KeyCombo(string: "") == nil)
    }

    t.suite("KeyModifiers: 해석과 변환") {
        t.expectEqual(KeyModifiers(string: "control+option"), [.control, .option])
        t.expectEqual(KeyModifiers(string: "⌥"), [.option])
        t.expect(KeyModifiers(string: "option+tab") == nil, "키가 섞이면 실패해야 함")
        t.expect(KeyModifiers(string: "") == nil)
        t.expectEqual(KeyModifiers([.control, .option]).displayString, "⌃⌥")
        t.expectEqual(KeyModifiers([.control, .option]).carbonFlags, UInt32(controlKey | optionKey))
        t.expectEqual(KeyModifiers(eventFlags: [.command, .shift, .capsLock]), [.command, .shift])
    }

    t.suite("KeyCombo: 숫자 키") {
        t.expectEqual(KeyCombo.digitKeyCode(1), UInt32(kVK_ANSI_1))
        t.expectEqual(KeyCombo.digitKeyCode(9), UInt32(kVK_ANSI_9))
        t.expect(KeyCombo.digitKeyCode(10) == nil)
        for digit in 0...9 {
            t.expectEqual(KeyCombo.digitKeyCode(digit).flatMap(KeyCombo.digit(forKeyCode:)), digit)
        }
        t.expect(KeyCombo.digit(forKeyCode: UInt32(kVK_ANSI_A)) == nil)
    }

    t.suite("RadialLayout: 방향 → 항목") {
        let layout = RadialLayout(itemCount: 8, deadZoneRadius: 30, hoverLimitRadius: 200)
        // 0번이 12시, 시계 방향.
        t.expectEqual(layout.index(at: CGPoint(x: 0, y: 100), bounded: false), 0)
        t.expectEqual(layout.index(at: CGPoint(x: 100, y: 100), bounded: false), 1)
        t.expectEqual(layout.index(at: CGPoint(x: 100, y: 0), bounded: false), 2)
        t.expectEqual(layout.index(at: CGPoint(x: 0, y: -100), bounded: false), 4)
        t.expectEqual(layout.index(at: CGPoint(x: -100, y: 0), bounded: false), 6)
        t.expectEqual(layout.index(at: CGPoint(x: -100, y: 100), bounded: false), 7)
        // 경계 근처: 12시에서 ±22.5° 안쪽은 0번.
        t.expectEqual(layout.index(at: CGPoint(x: 40, y: 100), bounded: false), 0)
        t.expectEqual(layout.index(at: CGPoint(x: -40, y: 100), bounded: false), 0)
        t.expectEqual(layout.index(at: CGPoint(x: 43, y: 100), bounded: false), 1)
        // 가운데는 선택 없음.
        t.expect(layout.index(at: CGPoint(x: 5, y: 5), bounded: false) == nil)
        // 멀리 가면: 긋기 방식은 방향만 보고, 클릭 방식은 선택 없음.
        t.expectEqual(layout.index(at: CGPoint(x: 0, y: 900), bounded: false), 0)
        t.expect(layout.index(at: CGPoint(x: 0, y: 900), bounded: true) == nil)
        t.expectEqual(layout.index(at: CGPoint(x: 0, y: 150), bounded: true), 0)
    }

    t.suite("RadialLayout: 항목 수가 달라도 일관됨") {
        for count in 1...12 {
            let layout = RadialLayout(itemCount: count)
            for index in 0..<count {
                let point = layout.point(of: index, radius: 110)
                t.expectEqual(layout.index(at: point, bounded: true), index, "count=\(count)")
                let path = layout.sectorPath(index: index, center: .zero, gap: 4, inset: 7)
                t.expect(!path.isEmpty, "count=\(count) index=\(index) 경로가 비어 있음")
                if count > 1 {
                    t.expect(path.contains(point), "count=\(count) index=\(index) 조각이 자기 중심을 포함해야 함")
                    let neighbor = layout.point(of: (index + 1) % count, radius: 110)
                    t.expect(!path.contains(neighbor), "count=\(count) index=\(index) 조각이 이웃 중심을 포함하면 안 됨")
                }
            }
        }
        t.expect(RadialLayout(itemCount: 0).index(at: CGPoint(x: 0, y: 100), bounded: false) == nil)
    }

    t.suite("AppConfig: 기본값과 부분 설정") {
        let empty = try AppConfig.decode(Data("{}".utf8))
        t.expectEqual(empty, AppConfig())
        t.expectEqual(empty.radialMenu.items.count, 8)

        let partial = try AppConfig.decode(Data("""
        {
          "hotkeys": { "radialMenu": "cmd+shift+space" },
          "clipboard": { "maxItems": 30 },
          "radialMenu": { "items": [
            { "action": "capture.ocr" },
            { "title": "터미널", "icon": "terminal", "app": "Terminal" }
          ] }
        }
        """.utf8))
        t.expectEqual(partial.hotkeys.radialMenu, "cmd+shift+space")
        t.expectEqual(partial.hotkeys.clipboardHistory, "option+v", "안 적은 값은 기본값")
        t.expectEqual(partial.clipboard.maxItems, 30)
        t.expectEqual(partial.clipboard.persist, true)
        t.expectEqual(partial.radialMenu.items.count, 2)
        t.expectEqual(partial.radialMenu.items[1].app, "Terminal")
        t.expectEqual(partial.capture.ocrLanguages, ["ko-KR", "en-US"])

        var failed = false
        do { _ = try AppConfig.decode(Data("{ not json".utf8)) } catch { failed = true }
        t.expect(failed, "깨진 JSON은 오류를 던져야 함")
    }

    t.suite("AppConfig: 저장 후 다시 읽기") {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/config.json")

        // 파일이 없으면 기본 설정을 만들어 둔다.
        let created = try AppConfig.load(from: file)
        t.expectEqual(created, AppConfig())
        t.expect(FileManager.default.fileExists(atPath: file.path))

        var changed = created
        changed.hotkeys.slotPasteModifiers = "control+option"
        changed.capture.sound = false
        changed.radialMenu.items.append(.init(title: "메모", icon: "note.text", shell: "open -a Notes"))
        try changed.save(to: file)
        let reloaded = try AppConfig.load(from: file)
        t.expectEqual(reloaded, changed)
    }

    t.suite("기본 단축키가 모두 유효함") {
        let hotkeys = AppConfig.Hotkeys()
        t.expect(KeyCombo(string: hotkeys.radialMenu) != nil)
        t.expect(KeyCombo(string: hotkeys.clipboardHistory) != nil)
        t.expect(KeyModifiers(string: hotkeys.slotPasteModifiers) != nil)
        t.expect(KeyModifiers(string: hotkeys.slotCopyModifiers) != nil)
        t.expect(hotkeys.slotPasteModifiers != hotkeys.slotCopyModifiers)
    }
}
