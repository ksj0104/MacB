import AppKit

/// 권한 안내 창의 바깥 껍데기. 앱에서는 진짜 창, 자체 테스트에서는 가짜를 쓴다.
@MainActor
public protocol PermissionGuidePresenting: AnyObject {
    var isVisible: Bool { get }
    /// 창을 띄우거나, 이미 떠 있으면 앞으로 가져온다. `activate`가 false면 지금 쓰던 앱의 포커스를 빼앗지 않는다.
    func present(activate: Bool)
    /// 창이 떠 있는 동안 내용이 바뀌었다. `newlyGranted`면 방금 권한이 허용된 것이다.
    func contentDidChange(newlyGranted: Bool)
}

/// 권한 안내: 권한마다 무엇에 쓰는지, 지금 상태, 해야 할 일과 버튼을 정하고 창에 보여 준다.
///
/// 창은 `content`를 그대로 그리고 버튼은 `perform`으로 넘기기만 한다. 시스템을 건드리는 일은 모두 `PermissionSystem`을 거친다.
/// 처음 실행했는지, 다시 시작한 직후에 할 일(결과 확인, 초기화 뒤 다시 요청)은 `stateFile`(MacB 지원 폴더)에 적어 둔다.
@MainActor
public final class PermissionGuide {
    public enum Stage: Equatable, Sendable {
        case granted
        /// 아직 요청하지 않았다.
        case missing
        /// 요청하고 시스템 설정을 열었다. 사용자가 켜기를 기다린다.
        case asked
        /// 요청했는데도 여전히 허용되지 않았다. 다시 빌드해서 목록의 예전 항목이 맞지 않는 경우가 많다.
        case stillMissing
        /// 이 앱의 권한 기록을 지우는 중.
        case resetting
    }

    public enum Action: Equatable, Sendable {
        /// 시스템에 요청하고 설정 화면을 연다.
        case request
        case openSettings
        case relaunch
        /// 이 앱의 권한 기록을 지우고 같은 프로세스에서 다시 요청한다.
        case resetAndRequest
        /// 이 앱의 권한 기록을 지우고 MacB를 다시 시작한 뒤, 새 프로세스에서 다시 요청한다.
        /// 화면 기록은 프로세스가 답을 기억해 두어서, 지운 뒤 같은 프로세스에서 물으면 목록에 다시 오르지 않을 수 있다.
        case resetAndRelaunch

        /// 되돌릴 수 없는 동작. `Return`(기본 버튼)으로는 절대 실행되지 않는다.
        public var isDestructive: Bool {
            self == .resetAndRequest || self == .resetAndRelaunch
        }
    }

    public struct Button: Equatable, Sendable {
        public var action: Action
        public var title: String
        public var isEnabled: Bool
        /// `Return`에 반응하는 버튼. 앞세운 줄에 많아야 하나이고, 되돌릴 수 없는 동작은 되지 않는다.
        public var isDefault: Bool

        public init(action: Action, title: String, isEnabled: Bool = true, isDefault: Bool = false) {
            self.action = action
            self.title = title
            self.isEnabled = isEnabled
            self.isDefault = isDefault
        }
    }

    public struct Row: Equatable, Sendable {
        public var permission: PermissionKind
        public var title: String
        public var summary: String
        public var symbol: String
        public var stage: Stage
        public var statusText: String
        /// 번호를 붙여 보여 줄 순서. 허용됐으면 비어 있다. 글에 나오는 버튼 이름은 이 줄에 실제로 있는 버튼이다.
        public var steps: [String]
        public var note: String?
        /// 왼쪽부터. 되돌릴 수 없는 동작(초기화)은 창이 안내 글 바로 아래에 따로 놓는다.
        public var buttons: [Button]
        /// 지금 앞세운 줄.
        public var isFocused: Bool

        public var isGranted: Bool { stage == .granted }

        public var defaultButton: Button? {
            buttons.first(where: \.isDefault)
        }

        public func button(_ action: Action) -> Button? {
            buttons.first { $0.action == action }
        }
    }

    public struct Content: Equatable, Sendable {
        public var headline: String
        public var detail: String
        public var rows: [Row]
        public var allGranted: Bool

        public func row(_ permission: PermissionKind) -> Row? {
            rows.first { $0.permission == permission }
        }
    }

    /// 다시 시작한 직후에 할 일을 적어 둔 것이 유효한 시간. 요청한 뒤 설정에서 켜고 다시 시작하기까지는
    /// 보통 몇 분이면 끝난다. 이보다 오래된 기록은 그만둔 것으로 보고, 다음 실행(며칠 뒤 로그인 등)에서 쓰지 않는다.
    public static let pendingLifetime: TimeInterval = 10 * 60

    /// 시스템 설정에 이만큼은 머물렀다 돌아와야 '켜러 다녀왔다'고 본다. '허용하기'가 설정을 바로 열기 때문에
    /// 설정이 앞으로 나온 것만으로는 근거가 약하다. 시스템 알림을 닫고 곧바로 돌아온 것은 1–2초면 끝나지만,
    /// 목록에서 MacB를 찾아 켜고 암호나 Touch ID로 확인하는 데는 그보다 오래 걸린다.
    public static let settingsVisitMinimum: TimeInterval = 3

    public static let shared = PermissionGuide(
        system: LivePermissionSystem(),
        stateFile: AppPaths.supportDirectory.appendingPathComponent("permission-guide.json"),
        announce: { message in Toast.show(message, symbol: "lock.shield") },
        makePresenter: { guide in PermissionGuideWindowController(guide: guide) }
    )

    /// 'MacB 다시 시작' 버튼이 부른다. 앱이 넣어 준다. 비어 있으면 다시 시작하는 버튼을 보여 주지 않는다.
    public var relaunchAction: (@MainActor () -> Void)? {
        didSet { publish() }
    }

    public private(set) var content: Content

    public var isVisible: Bool {
        presenter?.isVisible ?? false
    }

    public var isPolling: Bool {
        pollTimer != nil
    }

    private enum Progress {
        case notAsked
        case asked
        case stillMissing
        case resetting
    }

    private let system: PermissionSystem
    private let stateFile: URL
    private let pollInterval: TimeInterval
    private let resetTimeout: TimeInterval
    private let now: () -> Date
    private let announce: @MainActor (String) -> Void
    private let makePresenter: @MainActor (PermissionGuide) -> PermissionGuidePresenting
    private var presenter: PermissionGuidePresenting?
    private var granted: [PermissionKind: Bool] = [:]
    private var progress: [PermissionKind: Progress] = [:]
    private var resetFailed: Set<PermissionKind> = []
    /// 요청한 뒤 시스템 설정이 앞으로 나온 시각. 돌아왔을 때 한 번 쓰고 지운다.
    private var settingsVisits: [PermissionKind: Date] = [:]
    /// 끝나기를 기다리는 초기화. 늦게 온 결과(시간 초과 뒤)는 번호가 맞지 않아 버린다.
    private var resetTokens: [PermissionKind: Int] = [:]
    private var nextResetToken = 0
    private var focus: PermissionKind?
    private var hasShownCaptureGuide = false
    private var reason: PermissionPurpose?
    private var pollTimer: Timer?

    /// - Parameters:
    ///   - stateFile: 처음 실행 여부와 다시 시작한 직후에 할 일을 적어 두는 파일.
    ///   - pollInterval: 창이 떠 있는 동안 권한 상태를 다시 확인하는 간격.
    ///   - resetTimeout: 초기화가 이 시간 안에 끝나지 않으면 실패로 본다.
    ///   - now: 지금 시각. 시험에서 시간을 건너뛸 때 바꿔 끼운다.
    ///   - announce: 권한 확인 결과를 창 없이 짧게 알린다.
    ///   - makePresenter: 처음 띄울 때 한 번만 불린다.
    public init(
        system: PermissionSystem,
        stateFile: URL,
        pollInterval: TimeInterval = 1,
        resetTimeout: TimeInterval = 15,
        now: @escaping () -> Date = Date.init,
        announce: @escaping @MainActor (String) -> Void,
        makePresenter: @escaping @MainActor (PermissionGuide) -> PermissionGuidePresenting
    ) {
        self.system = system
        self.stateFile = stateFile
        self.pollInterval = pollInterval
        self.resetTimeout = resetTimeout
        self.now = now
        self.announce = announce
        self.makePresenter = makePresenter
        content = Content(headline: "", detail: "", rows: [], allGranted: false)
        for permission in PermissionKind.allCases {
            granted[permission] = system.isGranted(permission)
        }
        content = makeContent()
    }

    // MARK: Showing

    /// 메뉴 막대에서 열 때. `focus`가 있으면 그 권한을 앞세운다.
    public func show(focus: PermissionKind? = nil) {
        self.focus = focus
        reason = nil
        present(activate: true)
    }

    /// 기능이 권한 때문에 멈췄을 때. 하려던 일을 맨 위 한 줄로 보여 준다.
    /// 이미 떠 있으면 새 창을 만들지 않고 앞으로 가져와 그 권한을 앞세운다.
    public func show(for purpose: PermissionPurpose) {
        focus = purpose.permission
        reason = purpose
        present(activate: purpose.activatesGuide)
    }

    /// 캡처와 OCR은 매번 실제 권한을 확인하되, 같은 거부 상태에서 안내 창은 한 번만 띄운다.
    public func allowsScreenCapture(for purpose: PermissionPurpose) -> Bool {
        if system.isGranted(.screenCapture) {
            hasShownCaptureGuide = false
            return true
        }
        if hasShownCaptureGuide {
            if !isVisible { announce("화면 기록 권한을 메뉴 막대의 ‘권한 설정…’에서 확인해 주세요") }
        } else {
            hasShownCaptureGuide = true
            show(for: purpose)
        }
        return false
    }

    /// 실행할 때 한 번 부른다. `warningOnScreen`이면 방금 띄운 경고 알림을 가리지 않도록 짧은 알림은 하지 않는다.
    ///
    /// - 초기화하고 다시 시작한 직후면 새 프로세스에서 그 권한을 다시 요청하고 그 줄을 앞세워 띄운다.
    /// - 요청하고 다시 시작한 직후면 결과를 보여 준다. 여전히 허용되지 않았으면 그 줄은 '요청했는데도 안 됨'으로 시작한다.
    /// - 처음 실행했고 빠진 권한이 있으면 한 번 띄운다. 그 뒤로는 저절로 띄우지 않는다.
    ///
    /// 다시 시작한 직후에 할 일은 `pendingLifetime` 안에 적힌 것만 쓴다. 기록을 지우지 못하면(쓸 수 없는 폴더 등)
    /// 실행할 때마다 같은 것이 뜨므로 아무것도 하지 않는다.
    public func showAtLaunchIfNeeded(warningOnScreen: Bool = false) {
        let saved = loadState()
        let firstLaunch = !(saved?.introShown ?? false)
        let fresh = (saved?.pending ?? []).filter(isFresh)
        let cleared = SavedState(introShown: true, pending: [])
        if saved != cleared {
            guard save(cleared) else {
                Log.error("permission guide: state not recorded, skipping the launch guide")
                return
            }
        }

        updateGranted()
        let missing = PermissionKind.allCases.filter { granted[$0] != true }

        if let entry = fresh.first(where: { $0.step == .request && missing.contains($0.permission) }) {
            focus = entry.permission
            reason = nil
            ask(entry.permission)
            present(activate: true)
            return
        }

        let checked = fresh.filter { $0.step == .check }.map(\.permission)
        if !checked.isEmpty {
            let stillMissing = checked.filter { missing.contains($0) }
            for permission in stillMissing {
                progress[permission] = .stillMissing
            }
            focus = stillMissing.first
            publish()
            guard !warningOnScreen else { return }
            if stillMissing.isEmpty {
                let names = checked.map(Self.title(of:)).joined(separator: ", ")
                announce("\(names) 권한이 허용되었습니다")
            } else {
                hasShownCaptureGuide = stillMissing.contains(.screenCapture)
                announce("권한 변경이 반영되지 않았습니다. 메뉴 막대의 ‘권한 설정…’에서 확인해 주세요")
            }
            return
        }

        guard firstLaunch, !missing.isEmpty else { return }
        focus = nil
        reason = nil
        present(activate: true)
    }

    private func present(activate: Bool) {
        updateGranted()
        publish()
        let presenter = self.presenter ?? makePresenter(self)
        self.presenter = presenter
        presenter.present(activate: activate)
        startPolling()
    }

    // MARK: Actions

    public func perform(_ action: Action, on permission: PermissionKind) {
        focus = permission
        switch action {
        case .request:
            ask(permission)
        case .openSettings:
            // 단계는 그대로 둔다. '요청했는데도 안 됨'에서 설정을 확인하러 가도 초기화 버튼은 남아야 한다.
            system.openSettings(permission)
        case .relaunch:
            guard let relaunchAction else { return }
            // 요청한 뒤의 다시 시작만 결과를 확인할 일로 적는다. 요청하지 않고 누른 다시 시작은 적지 않는다.
            for kind in PermissionKind.allCases where kind.needsRelaunch && granted[kind] != true {
                if progress[kind] == .asked || progress[kind] == .stillMissing {
                    recordPending(kind, step: .check)
                }
            }
            relaunchAction()
            return
        case .resetAndRequest, .resetAndRelaunch:
            guard progress[permission] != .resetting else { return }
            progress[permission] = .resetting
            publish()
            nextResetToken += 1
            let token = nextResetToken
            resetTokens[permission] = token
            let relaunchAfter = action == .resetAndRelaunch
            system.reset(permission) { [weak self] succeeded in
                self?.finishReset(permission, token: token, succeeded: succeeded, relaunchAfter: relaunchAfter)
            }
            // 초기화가 멈추면(tccutil이 끝나지 않는 등) 줄이 '지우는 중'에 갇힌다. 정해 둔 시간이 지나면 실패로 본다.
            DispatchQueue.main.asyncAfter(deadline: .now() + resetTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.resetTokens[permission] == token else { return }
                    Log.error("permission reset timed out: \(permission.rawValue)")
                    self.finishReset(permission, token: token, succeeded: false, relaunchAfter: relaunchAfter)
                }
            }
        }
        updateGranted()
        publish()
    }

    private func ask(_ permission: PermissionKind) {
        system.request(permission)
        system.openSettings(permission)
        progress[permission] = .asked
        resetFailed.remove(permission)
        settingsVisits[permission] = nil
        if permission.needsRelaunch {
            recordPending(permission, step: .check)
        }
    }

    private func finishReset(_ permission: PermissionKind, token: Int, succeeded: Bool, relaunchAfter: Bool) {
        guard resetTokens[permission] == token else { return }
        resetTokens[permission] = nil
        defer {
            updateGranted()
            publish()
        }
        guard succeeded else {
            progress[permission] = .stillMissing
            resetFailed.insert(permission)
            return
        }
        resetFailed.remove(permission)
        if relaunchAfter, let relaunchAction, recordPending(permission, step: .request) {
            // 다시 시작하지 못하고 남게 되면 이 프로세스에서 '허용하기'로 이어 갈 수 있게 한다.
            progress[permission] = .notAsked
            relaunchAction()
            return
        }
        ask(permission)
    }

    // MARK: Status

    /// 권한 상태를 다시 확인한다. 창이 떠 있는 동안 주기적으로 불린다.
    public func refresh() {
        updateGranted()
        publish()
    }

    /// 시스템 설정이 앞으로 나왔다. 바로 반영되는 권한을 요청한 뒤라면 그 시각을 적어 둔다.
    public func systemSettingsActivated() {
        for permission in PermissionKind.allCases where !permission.needsRelaunch && progress[permission] == .asked {
            settingsVisits[permission] = now()
        }
    }

    /// 창이 다시 키 창이 됐을 때. 바로 반영되는 권한을 요청한 뒤 시스템 설정에 `settingsVisitMinimum` 넘게 다녀왔는데도
    /// 아직 꺼져 있으면 목록의 예전 항목이 맞지 않는 경우라고 보고 초기화를 권한다. 설정에 가지 않았거나 곧바로 돌아온 것
    /// (시스템 알림을 닫은 것 등)은 근거가 되지 않는다. 다녀온 기록은 돌아올 때마다 지워서, 한 번 다녀온 것을 나중에 다시 쓰지 않는다.
    /// 다시 시작해야 반영되는 권한은 여기서 판단하지 않는다.
    public func userReturned() {
        updateGranted()
        let returnedAt = now()
        for permission in PermissionKind.allCases where !permission.needsRelaunch {
            guard let visited = settingsVisits.removeValue(forKey: permission) else { continue }
            if granted[permission] != true, progress[permission] == .asked,
               returnedAt.timeIntervalSince(visited) >= Self.settingsVisitMinimum {
                progress[permission] = .stillMissing
            }
        }
        publish()
    }

    /// 창이 떠 있는 동안 상태를 확인한다. 창이 닫히면 다음 확인 때 스스로 멈춘다.
    public func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.isVisible else {
                    self.stopPolling()
                    return
                }
                self.refresh()
            }
        }
        timer.tolerance = pollInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func updateGranted() {
        for permission in PermissionKind.allCases {
            let isGranted = system.isGranted(permission)
            guard granted[permission] != isGranted else { continue }
            granted[permission] = isGranted
            if isGranted {
                progress[permission] = .notAsked
                resetFailed.remove(permission)
                settingsVisits[permission] = nil
                forgetPending(permission)
            }
        }
    }

    private func publish() {
        let previous = content
        let next = makeContent()
        guard next != previous else { return }
        content = next
        let newlyGranted = next.rows.contains { row in
            row.isGranted && previous.row(row.permission).map { !$0.isGranted } == true
        }
        guard let presenter, presenter.isVisible else { return }
        presenter.contentDidChange(newlyGranted: newlyGranted)
    }

    // MARK: Content

    private func makeContent() -> Content {
        let captureOnly = reason?.permission == .screenCapture
        let permissions: [PermissionKind] = captureOnly ? [.screenCapture] : PermissionKind.allCases
        let missing = permissions.filter { granted[$0] != true }
        let focused = focus.flatMap { missing.contains($0) ? $0 : nil } ?? missing.first
        let rows = permissions.map { makeRow($0, focused: $0 == focused) }

        let headline: String
        let detail: String
        if missing.isEmpty {
            headline = captureOnly ? "화면 기록 권한이 허용되었습니다" : "필요한 권한이 모두 허용되었습니다"
            detail = "이 창은 닫아도 됩니다. 메뉴 막대의 '권한 설정…'에서 언제든 다시 볼 수 있습니다."
        } else {
            if let reason, missing.contains(reason.permission) {
                headline = reason.sentence
            } else {
                headline = "몇 가지 기능에 macOS 권한이 필요합니다"
            }
            detail = "원형 메뉴, 색상 추출, 클립보드 기록은 권한 없이도 동작합니다."
        }
        return Content(headline: headline, detail: detail, rows: rows, allGranted: missing.isEmpty)
    }

    private func makeRow(_ permission: PermissionKind, focused: Bool) -> Row {
        let stage: Stage
        if granted[permission] == true {
            stage = .granted
        } else {
            switch progress[permission] ?? .notAsked {
            case .notAsked: stage = .missing
            case .asked: stage = .asked
            case .stillMissing: stage = .stillMissing
            case .resetting: stage = .resetting
            }
        }
        var row = Row(
            permission: permission,
            title: Self.title(of: permission),
            summary: Self.summary(of: permission),
            symbol: Self.symbol(of: permission),
            stage: stage,
            statusText: stage == .granted ? "허용됨" : "필요",
            steps: [],
            note: nil,
            buttons: [],
            isFocused: focused && stage != .granted
        )
        guard stage != .granted else { return row }

        // 화면 기록은 다시 시작해야 반영된다. 다시 시작 동작이 없으면 직접 종료했다가 여는 방법을 적는다.
        let relaunches = permission.needsRelaunch && relaunchAction != nil
        let finalStep: String
        if permission.needsRelaunch {
            finalStep = relaunches ? "'MacB 다시 시작'을 누릅니다" : "MacB를 종료했다가 다시 엽니다"
        } else {
            finalStep = "켜는 대로 여기에 '허용됨'이 표시됩니다"
        }
        let reset = relaunches
            ? Button(action: .resetAndRelaunch, title: "초기화하고 다시 시작")
            : Button(action: .resetAndRequest, title: "초기화하고 다시 요청")
        let request = Button(action: .request, title: "허용하기")
        let openSettings = Button(action: .openSettings, title: "시스템 설정 열기")
        let relaunch = Button(action: .relaunch, title: "MacB 다시 시작")
        // 기본 버튼(`Return`)이 될 동작. 되돌릴 수 없는 동작은 넣지 않는다.
        var defaultAction: Action?

        switch stage {
        case .granted:
            break
        case .missing:
            row.steps = ["'허용하기'를 누르면 시스템 설정이 열립니다"]
                + (permission.needsRelaunch ? ["목록에서 MacB를 켭니다", finalStep] : ["목록에서 MacB를 켭니다. 다시 시작하지 않아도 바로 반영됩니다"])
            // 셋째 단계가 가리키는 버튼이라 처음부터 보여 준다(설정에서 직접 켠 사람도 쓴다).
            row.buttons = relaunches ? [relaunch, request] : [request]
            defaultAction = .request
        case .asked:
            row.steps = ["시스템 설정의 목록에서 MacB를 켭니다", finalStep]
            if permission.needsRelaunch {
                row.note = relaunches
                    ? "화면 기록은 MacB를 다시 시작해야 반영됩니다."
                    : "화면 기록은 MacB를 다시 열어야 반영됩니다."
                row.buttons = relaunches ? [openSettings, relaunch] : [openSettings]
                defaultAction = relaunches ? .relaunch : .openSettings
            } else {
                row.buttons = [openSettings]
                defaultAction = .openSettings
            }
        case .stillMissing, .resetting:
            // 초기화가 실패했으면 같은 것을 다시 권하지 않고, 직접 지운 뒤 다시 요청하는 길을 준다.
            let failed = stage == .stillMissing && resetFailed.contains(permission)
            row.steps = ["'시스템 설정 열기'를 눌러 목록에서 MacB를 켭니다", finalStep]
            if stage == .resetting {
                row.note = "예전 항목을 지우는 중…"
            } else if failed {
                row.note = "초기화하지 못했습니다. 목록에서 MacB를 직접 지운(−) 다음 '허용하기'를 눌러 주세요."
            } else {
                row.note = "이미 켜져 있는데도 '필요'라면 다시 빌드하기 전의 MacB가 등록되어 있을 수 있습니다. "
                    + (relaunches ? "초기화하면 예전 항목을 지우고 다시 시작해서 다시 묻습니다." : "초기화하면 예전 항목을 지우고 다시 묻습니다.")
            }
            let regular = relaunches ? [relaunch, openSettings] : [openSettings]
            row.buttons = regular + [failed ? request : reset]
            defaultAction = .openSettings
            if stage == .resetting {
                for index in row.buttons.indices { row.buttons[index].isEnabled = false }
                defaultAction = nil
            }
        }

        if row.isFocused, let defaultAction, !defaultAction.isDestructive,
           let index = row.buttons.firstIndex(where: { $0.action == defaultAction && $0.isEnabled }) {
            row.buttons[index].isDefault = true
        }
        return row
    }

    static func title(of permission: PermissionKind) -> String {
        switch permission {
        case .screenCapture: return "화면 기록"
        case .accessibility: return "손쉬운 사용"
        }
    }

    private static func summary(of permission: PermissionKind) -> String {
        switch permission {
        case .screenCapture: return "스크린샷과 글자 인식에 씁니다. 없으면 다른 앱의 창이 찍히지 않습니다."
        case .accessibility: return "자동 붙여넣기와 슬롯에 복사에 씁니다. 다른 앱에 ⌘C·⌘V를 보냅니다."
        }
    }

    private static func symbol(of permission: PermissionKind) -> String {
        switch permission {
        case .screenCapture: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        }
    }

    // MARK: Saved state

    private struct SavedState: Codable, Equatable {
        var introShown: Bool
        var pending: [Pending]

        init(introShown: Bool, pending: [Pending]) {
            self.introShown = introShown
            self.pending = pending
        }

        /// 키가 빠졌거나 예전 모양(시각 없는 `awaitingRelaunch`)이면 그 부분은 없는 것으로 본다.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            introShown = try container.decodeIfPresent(Bool.self, forKey: .introShown) ?? true
            pending = (try? container.decodeIfPresent([Pending].self, forKey: .pending)) ?? []
        }
    }

    /// 다시 시작한 직후에 할 일.
    private struct Pending: Codable, Equatable {
        enum Step: String, Codable {
            /// 결과를 보여 준다(여전히 없으면 초기화를 권한다).
            case check
            /// 초기화한 뒤라 새 프로세스에서 다시 요청한다.
            case request
        }

        var permission: PermissionKind
        var step: Step
        var since: Date
    }

    private func isFresh(_ entry: Pending) -> Bool {
        let age = now().timeIntervalSince(entry.since)
        return age >= 0 && age <= Self.pendingLifetime
    }

    /// 파일이 없으면 nil(처음 실행). 읽을 수 없는 파일이면 이미 안내한 것으로 본다(다시 띄우지 않는 쪽이 덜 성가시다).
    private func loadState() -> SavedState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SavedState.self, from: data)) ?? SavedState(introShown: true, pending: [])
    }

    /// 적었으면 true.
    @discardableResult
    private func save(_ state: SavedState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            return true
        } catch {
            Log.error("permission guide state not saved: \(error.localizedDescription)")
            return false
        }
    }

    /// 적었으면 true. 같은 권한의 이전 기록은 바꾼다.
    @discardableResult
    private func recordPending(_ permission: PermissionKind, step: Pending.Step) -> Bool {
        // 사용자가 이미 안내 창을 본 것이므로 처음 실행 안내도 끝난 것으로 적는다.
        var state = loadState() ?? SavedState(introShown: true, pending: [])
        state.introShown = true
        state.pending.removeAll { $0.permission == permission }
        state.pending.append(Pending(permission: permission, step: step, since: now()))
        return save(state)
    }

    private func forgetPending(_ permission: PermissionKind) {
        guard var state = loadState(), state.pending.contains(where: { $0.permission == permission }) else { return }
        state.pending.removeAll { $0.permission == permission }
        save(state)
    }
}
