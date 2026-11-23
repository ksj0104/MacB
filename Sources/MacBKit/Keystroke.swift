import AppKit
import Carbon.HIToolbox

/// 다른 앱으로 보내는 합성 키 입력(⌘C / ⌘V). 손쉬운 사용 권한이 있어야 한다.
public enum Keystroke {
    /// ⌘ 플래그에 왼쪽 ⌘ 장치 비트를 더한 값. 일부 앱은 장치 비트가 없으면 단축키로 인식하지 않는다.
    private static let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008)

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// 지금 사용자가 보조키를 실제로 누르고 있는지.
    public static var physicalModifiersDown: Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).isEmpty
    }

    /// 키 누름+뗌을 보낸다. 권한이 없으면 아무것도 보내지 않고 false.
    @discardableResult
    public static func post(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard Permissions.hasAccessibility else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        // 실제 키보드 입력을 막는 필터(setLocalEventsFilterDuringSuppressionState)는 다시 넣지 말 것.
        // 키보드를 빼고 거르면 합성 입력마다 0.25초 동안 사용자가 치는 키가 버려져서,
        // ⌥를 누른 채 1, 2, 3을 연달아 누르는 슬롯 붙여넣기의 둘째·셋째 키가 사라진다.
        // 누르고 있는 ⌥가 ⌘V에 섞여 ⌥⌘V가 되지 않는 것은 아래에서 플래그를 직접 정해 주기 때문이다.
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    @discardableResult
    public static func postCopy() -> Bool {
        post(keyCode: CGKeyCode(kVK_ANSI_C), flags: commandFlags)
    }

    @discardableResult
    public static func postPaste() -> Bool {
        post(keyCode: CGKeyCode(kVK_ANSI_V), flags: commandFlags)
    }

    /// 사용자가 보조키에서 손을 뗀 뒤(또는 `timeout`이 지나면) 메인 스레드에서 `body`를 부른다.
    ///
    /// 단축키(예: ⌃⌥1)를 누른 채로 ⌘C를 합성하면 앱에 따라 ⌃⌥⌘C로 읽힐 수 있어서,
    /// 합성 입력 직전에 이걸 거친다.
    public static func whenModifiersReleased(
        timeout: TimeInterval = 0.4,
        _ body: @escaping @MainActor () -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !physicalModifiersDown || Date() >= deadline {
                MainActor.assumeIsolated { body() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { poll() }
            }
        }
        DispatchQueue.main.async { poll() }
    }
}
