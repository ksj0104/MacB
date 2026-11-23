import Carbon.HIToolbox
import Foundation
import MacBKit

/// 전역 단축키 등록기 테스트. 실제 단축키는 걸지 않고 메모리 속 가짜 시스템으로만 돌린다.
@MainActor
func runHotKeyCenterTests(_ t: TestRunner) {
    let a = KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: [.control, .option])
    let b = KeyCombo(keyCode: UInt32(kVK_ANSI_B), modifiers: [.control, .option])
    let c = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .option])
    let escape = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: [])

    t.suite("단축키: 멈췄다가 다시 걸면 그대로 돌아옴") {
        let system = FakeHotKeySystem()
        let center = HotKeyCenter(system: system)
        var pressed: [String] = []
        let tokenA = center.register(a, onPress: { pressed.append("a") }, onRelease: { pressed.append("a↑") })
        _ = center.register(b, onPress: { pressed.append("b") })
        // 원형 메뉴가 열려 있는 동안 거는 임시 esc 같은 것.
        _ = center.register(escape, onPress: { pressed.append("esc") })
        t.expect(tokenA != nil)
        t.expectEqual(system.active, [a, b, escape])
        let idsBefore = system.activeIDs

        center.suspend()
        t.expectEqual(system.active, [], "멈추면 시스템에서는 모두 떼어야 함")
        t.expectEqual(system.press(a), false, "멈춘 동안 들어온 이벤트는 처리하지 않음")
        t.expectEqual(pressed, [])

        t.expectEqual(center.resume(), [])
        t.expectEqual(system.active, [a, b, escape])
        t.expectEqual(system.activeIDs, idsBefore, "같은 번호로 다시 걸어야 함")
        t.expectEqual(system.press(a), true)
        t.expectEqual(system.release(a), true)
        t.expectEqual(system.press(escape), true)
        t.expectEqual(pressed, ["a", "a↑", "esc"], "누름·뗌 동작도 그대로여야 함")

        // 예전 토큰으로 계속 해제할 수 있다.
        if let tokenA { center.unregister(tokenA) }
        t.expectEqual(system.active, [b, escape])
    }

    t.suite("단축키: 멈춘 동안의 등록·해제") {
        let system = FakeHotKeySystem()
        let center = HotKeyCenter(system: system)
        let tokenA = center.register(a, onPress: {})
        let tokenB = center.register(b, onPress: {})
        center.suspend()

        let tokenC = center.register(c, onPress: {})
        t.expect(tokenC != nil, "멈춘 동안에도 등록은 받아 둠")
        t.expectEqual(system.active, [], "멈춘 동안에는 시스템에 걸지 않음")
        if let tokenB { center.unregister(tokenB) }
        let writesBefore = system.unregistrations
        if let tokenA { center.unregister(tokenA) }
        t.expectEqual(system.unregistrations, writesBefore, "이미 뗀 것은 다시 떼지 않음")

        t.expectEqual(center.resume(), [])
        t.expectEqual(system.active, [c], "해제한 것은 돌아오지 않고, 새로 등록한 것은 걸림")
    }

    t.suite("단축키: 여러 번 멈추고 풀기") {
        let system = FakeHotKeySystem()
        let center = HotKeyCenter(system: system)
        _ = center.register(a, onPress: {})
        center.suspend()
        center.suspend()
        t.expectEqual(center.resume(), [])
        t.expectEqual(center.resume(), [])
        t.expectEqual(system.registrations, 2, "처음 한 번과 다시 건 한 번뿐")
        t.expectEqual(system.active, [a])
    }

    t.suite("단축키: 다시 걸지 못한 조합") {
        let system = FakeHotKeySystem()
        let center = HotKeyCenter(system: system)
        let tokenA = center.register(a, onPress: {})
        _ = center.register(b, onPress: {})
        center.suspend()
        system.refused = [a]
        t.expectEqual(center.resume(), [a], "어느 조합이 안 걸렸는지 알려 줌")
        t.expectEqual(system.active, [b])
        t.expectEqual(system.press(a), false)

        // 다음에 멈췄다 풀 때 다시 시도한다.
        system.refused = []
        center.suspend()
        t.expectEqual(center.resume(), [])
        t.expectEqual(system.active, [a, b])
        if let tokenA { center.unregister(tokenA) }
        t.expectEqual(system.active, [b])
    }

    t.suite("단축키: 등록 실패와 모두 해제") {
        let system = FakeHotKeySystem()
        let center = HotKeyCenter(system: system)
        system.refused = [b]
        t.expect(center.register(b, onPress: {}) == nil, "시스템이 거부하면 nil")
        system.refused = []
        _ = center.register(a, onPress: {})
        _ = center.register(c, onPress: {})
        center.suspend()
        center.unregisterAll()
        t.expectEqual(center.resume(), [])
        t.expectEqual(system.active, [], "모두 해제한 뒤에는 돌아올 것이 없음")

        _ = center.register(a, onPress: {})
        center.unregisterAll()
        t.expectEqual(system.active, [])
        t.expectEqual(system.press(a), false, "해제한 단축키의 늦은 이벤트는 다음 처리기로 넘김")
    }
}

/// 메모리 속 가짜 단축키 시스템. 걸려 있는 조합과 호출 횟수를 기록한다.
@MainActor
final class FakeHotKeySystem: HotKeySystem {
    private var handler: (@MainActor (UInt32, Bool) -> Bool)?
    private var combos: [UInt32: KeyCombo] = [:]
    /// 걸지 못하게 할 조합(다른 앱이 먼저 잡은 경우 역할).
    var refused: Set<KeyCombo> = []
    private(set) var registrations = 0
    private(set) var unregistrations = 0

    /// 지금 걸려 있는 조합(번호 순).
    var active: [KeyCombo] { combos.keys.sorted().compactMap { combos[$0] } }
    var activeIDs: [UInt32] { combos.keys.sorted() }

    func install(handler: @escaping @MainActor (UInt32, Bool) -> Bool) {
        self.handler = handler
    }

    func register(_ combo: KeyCombo, id: UInt32) -> Bool {
        guard !refused.contains(combo), !combos.values.contains(combo) else { return false }
        registrations += 1
        combos[id] = combo
        lastIDs[combo] = id
        return true
    }

    func unregister(id: UInt32) {
        guard combos.removeValue(forKey: id) != nil else { return }
        unregistrations += 1
    }

    /// 마지막으로 그 조합을 걸 때 쓴 번호로 누름 이벤트를 보낸다. 이미 뗀 단축키의 늦은 이벤트도 흉내 낼 수 있다.
    func press(_ combo: KeyCombo) -> Bool { send(combo, pressed: true) }
    func release(_ combo: KeyCombo) -> Bool { send(combo, pressed: false) }

    private var lastIDs: [KeyCombo: UInt32] = [:]

    private func send(_ combo: KeyCombo, pressed: Bool) -> Bool {
        guard let id = lastIDs[combo], let handler else { return false }
        return handler(id, pressed)
    }
}
