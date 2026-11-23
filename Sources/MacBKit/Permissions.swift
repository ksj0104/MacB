import AppKit
import ApplicationServices

/// macOS 개인정보 보호 권한 확인/요청.
public enum Permissions {
    public enum Pane {
        case accessibility
        case screenCapture

        var url: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenCapture:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    /// 손쉬운 사용: 다른 앱에 ⌘C / ⌘V를 보내는 데 필요.
    public static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 권한이 없으면 시스템 안내 창을 띄운다. 현재 허용 여부를 돌려준다.
    @discardableResult
    public static func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 화면 기록: 다른 앱의 창이 스크린샷에 찍히려면 필요.
    public static var hasScreenCapture: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 처음 한 번은 시스템 안내 창을 띄우고, 앱을 권한 목록에 올린다.
    @discardableResult
    public static func promptScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSettings(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}

/// MacB가 쓰는 개인정보 보호 권한.
public enum PermissionKind: String, CaseIterable, Codable, Sendable {
    /// 화면 기록: 스크린샷, 글자 인식.
    case screenCapture
    /// 손쉬운 사용: 자동 붙여넣기, 슬롯에 복사.
    case accessibility

    /// 허용한 뒤 앱을 다시 시작해야 반영되는지. 화면 기록은 실행 중인 프로세스가 새 허용을 보지 못한다.
    public var needsRelaunch: Bool {
        self == .screenCapture
    }

    var pane: Permissions.Pane {
        switch self {
        case .screenCapture: return .screenCapture
        case .accessibility: return .accessibility
        }
    }

    /// `tccutil`이 쓰는 서비스 이름.
    var tccService: String {
        switch self {
        case .screenCapture: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        }
    }
}

/// 권한이 필요해진 순간 사용자가 하려던 일. 권한 안내 창 맨 위에 한 줄로 보여 준다.
public enum PermissionPurpose: Sendable, Equatable {
    case screenshot
    case textRecognition
    case autoPaste
    case slotCopy

    public var permission: PermissionKind {
        switch self {
        case .screenshot, .textRecognition: return .screenCapture
        case .autoPaste, .slotCopy: return .accessibility
        }
    }

    public var sentence: String {
        switch self {
        case .screenshot: return "스크린샷을 찍으려면 화면 기록 권한이 필요합니다"
        case .textRecognition: return "글자를 인식하려면 화면 기록 권한이 필요합니다"
        case .autoPaste: return "자동으로 붙여넣으려면 손쉬운 사용 권한이 필요합니다"
        case .slotCopy: return "선택 영역을 슬롯에 복사하려면 손쉬운 사용 권한이 필요합니다"
        }
    }

    /// 안내 창을 띄울 때 MacB를 앞으로 가져올지.
    /// 붙여넣기·슬롯 복사는 내용이 이미 클립보드에 있고 사용자가 쓰던 앱에서 ⌘V를 누를 차례라 포커스를 빼앗지 않는다.
    public var activatesGuide: Bool {
        switch self {
        case .screenshot, .textRecognition: return true
        case .autoPaste, .slotCopy: return false
        }
    }
}

/// 권한 확인·요청·설정 열기·초기화. 권한 안내의 동작을 가짜로 바꿔 시험할 수 있도록 시스템을 건드리는 일은 모두 이 뒤에 둔다.
@MainActor
public protocol PermissionSystem: AnyObject {
    /// 지금 허용돼 있는지. 시스템 안내 창을 띄우지 않는다.
    func isGranted(_ permission: PermissionKind) -> Bool
    /// 시스템에 요청한다. 처음 한 번은 시스템 안내 창이 뜨고 MacB가 설정의 목록에 오른다.
    func request(_ permission: PermissionKind)
    /// 시스템 설정의 해당 화면을 연다.
    func openSettings(_ permission: PermissionKind)
    /// 이 앱의 권한 기록만 지운다. 다시 빌드해서 목록의 예전 항목이 맞지 않을 때 쓴다.
    func reset(_ permission: PermissionKind, completion: @escaping @MainActor (_ succeeded: Bool) -> Void)
}

/// 실제 macOS에 묻고 요청하는 구현.
@MainActor
public final class LivePermissionSystem: PermissionSystem {
    public init() {}

    public func isGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .screenCapture: return Permissions.hasScreenCapture
        case .accessibility: return Permissions.hasAccessibility
        }
    }

    public func request(_ permission: PermissionKind) {
        switch permission {
        case .screenCapture: Permissions.promptScreenCapture()
        case .accessibility: Permissions.promptAccessibility()
        }
    }

    public func openSettings(_ permission: PermissionKind) {
        Permissions.openSettings(permission.pane)
    }

    /// `tccutil`이 이 시간 안에 끝나지 않으면 멈추고 실패로 알린다.
    public static let resetTimeout: TimeInterval = 10

    /// `tccutil`에 넘길 인자. 번들 ID 없이 돌리면 모든 앱의 그 권한이 지워지므로, 번들 ID가 없거나 비어 있으면 nil.
    public static func resetArguments(for permission: PermissionKind, bundleID: String?) -> [String]? {
        guard let bundleID = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else { return nil }
        return ["reset", permission.tccService, bundleID]
    }

    /// `tccutil reset <서비스> <번들 ID>`로 이 앱의 기록만 지운다. `completion`은 꼭 한 번 불린다.
    public func reset(_ permission: PermissionKind, completion: @escaping @MainActor (_ succeeded: Bool) -> Void) {
        guard let arguments = Self.resetArguments(for: permission, bundleID: Bundle.main.bundleIdentifier) else {
            Log.error("permission reset skipped: no bundle identifier")
            completion(false)
            return
        }
        let finish = ResetCompletion(completion)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let service = permission.tccService
        process.terminationHandler = { finished in
            let succeeded = finished.terminationReason == .exit && finished.terminationStatus == 0
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.info("tccutil reset \(service): \(succeeded ? "ok" : "failed (\(status))")")
                    finish.call(succeeded)
                }
            }
        }
        do {
            try process.run()
        } catch {
            Log.error("tccutil failed to start: \(error.localizedDescription)")
            finish.call(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resetTimeout) {
            MainActor.assumeIsolated {
                guard !finish.isDone else { return }
                Log.error("tccutil reset \(service): timed out")
                process.terminate()
                finish.call(false)
            }
        }
    }
}

/// 초기화 결과를 한 번만 넘긴다(끝남과 시간 초과 중 먼저 온 것).
@MainActor
private final class ResetCompletion {
    private let completion: @MainActor (Bool) -> Void
    private(set) var isDone = false

    init(_ completion: @escaping @MainActor (Bool) -> Void) {
        self.completion = completion
    }

    func call(_ succeeded: Bool) {
        guard !isDone else { return }
        isDone = true
        completion(succeeded)
    }
}

/// 클립보드처럼 앱 본체를 모르는 모듈이 권한을 요청할 때 거치는 곳.
///
/// 앱은 실행할 때 `handler`에 권한 안내 창을 연결한다. 연결하지 않았으면 예전처럼 시스템 안내 창만 띄운다.
/// 어느 쪽이든 실행당 한 번만 띄워서, 붙여넣을 때마다 귀찮게 하지 않는다.
@MainActor
public final class PermissionRequestHook {
    /// 연결이 없을 때의 시스템 안내 창은 `.app` 번들로 실행될 때만 띄운다. 자체 테스트 같은 맨 실행 파일이
    /// 이 길에 닿아도 사용자의 Mac에 시스템 창이 뜨지 않는다(맨 실행 파일이 물으면 터미널의 권한을 묻게 된다).
    public static let accessibility = PermissionRequestHook {
        guard PermissionRequestHook.systemPromptAllowed(bundlePath: Bundle.main.bundlePath) else {
            Log.info("accessibility prompt skipped: not running from an app bundle")
            return
        }
        _ = Permissions.promptAccessibility()
    }

    /// 시스템 안내 창을 띄워도 되는 실행인지(`.app` 번들 안에서 실행 중인지).
    public nonisolated static func systemPromptAllowed(bundlePath: String) -> Bool {
        bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".app/")
    }

    public var handler: (@MainActor (PermissionPurpose) -> Void)?
    public private(set) var hasRequested = false
    private let fallback: @MainActor () -> Void

    public init(fallback: @escaping @MainActor () -> Void) {
        self.fallback = fallback
    }

    /// 이번 실행에서 처음이면 요청하고 true, 이미 요청했으면 아무것도 하지 않고 false.
    @discardableResult
    public func requestOnce(for purpose: PermissionPurpose) -> Bool {
        guard !hasRequested else { return false }
        hasRequested = true
        if let handler {
            handler(purpose)
        } else {
            fallback()
        }
        return true
    }
}
