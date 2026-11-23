import AppKit
import Carbon.HIToolbox

/// 시스템에 단축키를 걸고 떼는 부분. 테스트는 메모리 안의 가짜로 바꿔 끼운다.
@MainActor
public protocol HotKeySystem: AnyObject {
    /// 단축키가 눌리거나 떼어지면 `handler(번호, 눌림)`을 부르게 한다. 처리했으면 handler가 true를 돌려준다.
    /// 여러 번 불릴 수 있고, 마지막 handler를 쓴다.
    func install(handler: @escaping @MainActor (_ id: UInt32, _ pressed: Bool) -> Bool)
    /// 걸지 못하면 false.
    func register(_ combo: KeyCombo, id: UInt32) -> Bool
    func unregister(id: UInt32)
}

/// 전역 단축키 등록기. 손쉬운 사용 권한 없이 동작하고, 누름·뗌을 모두 알려 준다.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter(system: CarbonHotKeySystem())

    public struct Token: Hashable, Sendable {
        fileprivate let id: UInt32
    }

    private struct Registration {
        let combo: KeyCombo
        /// 시스템에 걸려 있는지. 잠시 멈춘 동안에는 false.
        var isActive: Bool
        let onPress: @MainActor () -> Void
        let onRelease: (@MainActor () -> Void)?
    }

    private let system: HotKeySystem
    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var isSuspended = false

    /// 앱은 `shared`를 쓴다. 다른 시스템을 주는 것은 테스트용이다.
    public init(system: HotKeySystem) {
        self.system = system
    }

    /// 등록에 실패하면 nil. 다른 앱이 같은 조합을 먼저 잡고 있어도 시스템은 성공을 돌려줄 수 있다.
    @discardableResult
    public func register(
        _ combo: KeyCombo,
        onPress: @escaping @MainActor () -> Void,
        onRelease: (@MainActor () -> Void)? = nil
    ) -> Token? {
        system.install { [weak self] id, pressed in
            self?.handle(id: id, pressed: pressed) ?? false
        }
        let id = nextID
        nextID += 1

        // 멈춘 동안에는 적어 두기만 하고 `resume`에서 건다.
        if !isSuspended, !system.register(combo, id: id) { return nil }
        registrations[id] = Registration(combo: combo, isActive: !isSuspended, onPress: onPress, onRelease: onRelease)
        return Token(id: id)
    }

    public func unregister(_ token: Token) {
        guard let registration = registrations.removeValue(forKey: token.id) else { return }
        if registration.isActive { system.unregister(id: token.id) }
    }

    public func unregisterAll() {
        for (id, registration) in registrations where registration.isActive {
            system.unregister(id: id)
        }
        registrations.removeAll()
    }

    /// 등록은 그대로 두고 시스템에서만 잠시 뗀다. 단축키 설정 창이 키를 기록하는 동안 쓴다 —
    /// 걸려 있으면 그 조합은 시스템이 먼저 가로채 칸까지 오지 않는다. 여러 번 불러도 한 번과 같다.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for (id, registration) in registrations where registration.isActive {
            system.unregister(id: id)
            registrations[id]?.isActive = false
        }
        Log.info("hotkeys: suspended \(registrations.count)")
    }

    /// `suspend` 때 뗀 단축키를 같은 번호·같은 동작으로 다시 건다(그 사이 새로 등록·해제한 것도 반영).
    /// 다시 걸지 못한 조합을 돌려준다(그 사이 다른 앱이 잡은 경우 등). 그 등록은 남겨 두므로 토큰은 계속 쓸 수 있다.
    @discardableResult
    public func resume() -> [KeyCombo] {
        guard isSuspended else { return [] }
        isSuspended = false
        var failed: [KeyCombo] = []
        for id in registrations.keys.sorted() {
            guard let registration = registrations[id], !registration.isActive else { continue }
            if system.register(registration.combo, id: id) {
                registrations[id]?.isActive = true
            } else {
                failed.append(registration.combo)
            }
        }
        Log.info("hotkeys: resumed \(registrations.count - failed.count), failed \(failed.count)")
        return failed
    }

    /// 이 등록기가 건 단축키였으면 true. 멈춰 있거나 이미 해제한 단축키는 처리하지 않는다.
    private func handle(id: UInt32, pressed: Bool) -> Bool {
        guard let registration = registrations[id], registration.isActive else { return false }
        if pressed {
            registration.onPress()
        } else {
            registration.onRelease?()
        }
        return true
    }
}

/// Carbon `RegisterEventHotKey`로 거는 실제 시스템.
@MainActor
final class CarbonHotKeySystem: HotKeySystem {
    fileprivate static let signature: OSType = 0x4D41_4342 // "MACB"
    /// C 콜백은 문맥을 들고 다닐 수 없어서 여기에 둔다.
    fileprivate static var handler: (@MainActor (UInt32, Bool) -> Bool)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func install(handler: @escaping @MainActor (UInt32, Bool) -> Bool) {
        Self.handler = handler
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            specs.count,
            &specs,
            nil,
            &handlerRef
        )
        if status != noErr {
            Log.error("hotkey event handler install failed (status \(status))")
        }
    }

    func register(_ combo: KeyCombo, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.error("hotkey \(combo.displayString) registration failed (status \(status))")
            return false
        }
        refs[id] = ref
        return true
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }
}

/// Carbon이 메인 런루프에서 부르는 C 콜백.
private func hotKeyEventHandler(
    _ call: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let signature = hotKeyID.signature
    let id = hotKeyID.id
    let handled = MainActor.assumeIsolated {
        signature == CarbonHotKeySystem.signature && (CarbonHotKeySystem.handler?(id, pressed) ?? false)
    }
    // 다른 서명의 단축키나 이미 해제한 단축키는 우리 것이 아니므로 다음 처리기에게 넘긴다.
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
