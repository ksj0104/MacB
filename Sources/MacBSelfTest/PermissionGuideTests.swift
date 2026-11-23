import AppKit
import MacBKit

@MainActor
func runPermissionGuideTests(_ t: TestRunner) {
    typealias Guide = PermissionGuide

    t.suite("권한 안내: 상태 조합마다 줄 글과 버튼") {
        let combinations: [Set<PermissionKind>] = [[], [.screenCapture], [.accessibility], [.screenCapture, .accessibility]]
        for granted in combinations {
            let fixture = GuideFixture(granted: granted)
            let content = fixture.makeGuide().content
            let label = "허용: \(granted.map(\.rawValue).sorted())"
            t.expectEqual(content.rows.map(\.permission), [.screenCapture, .accessibility], label)
            t.expectEqual(content.allGranted, granted.count == 2, label)
            t.expectEqual(content.row(.screenCapture)?.title, "화면 기록")
            t.expectEqual(content.row(.accessibility)?.title, "손쉬운 사용")

            for row in content.rows {
                if granted.contains(row.permission) {
                    t.expectEqual(row.stage, .granted, label)
                    t.expectEqual(row.statusText, "허용됨", label)
                    t.expect(row.steps.isEmpty && row.note == nil && row.buttons.isEmpty, "허용된 줄은 설명·버튼 없이 짧게 \(label)")
                    t.expect(!row.isFocused, "허용된 줄은 앞세우지 않음 \(label)")
                } else {
                    t.expectEqual(row.stage, .missing, label)
                    t.expectEqual(row.statusText, "필요", label)
                    t.expectEqual(row.buttons.last?.action, .request, "허용하기가 오른쪽 끝 \(label)")
                    t.expectEqual(row.steps.first, "'허용하기'를 누르면 시스템 설정이 열립니다", label)
                    t.expect(row.note == nil, label)
                    t.expectEqual(row.defaultButton?.action, row.isFocused ? .request : nil, "앞세운 줄만 기본 버튼 \(label)")
                }
            }

            let firstMissing = PermissionKind.allCases.first { !granted.contains($0) }
            t.expectEqual(content.rows.first(where: \.isFocused)?.permission, firstMissing, label)
            t.expectEqual(content.rows.filter(\.isFocused).count, firstMissing == nil ? 0 : 1, label)
            if content.allGranted {
                t.expectEqual(content.headline, "필요한 권한이 모두 허용되었습니다")
            } else {
                t.expectEqual(content.headline, "몇 가지 기능에 macOS 권한이 필요합니다", label)
                t.expect(content.detail.contains("권한 없이도"), label)
            }

            if !granted.contains(.screenCapture) {
                let screen = content.row(.screenCapture)
                t.expectEqual(screen?.steps, ["'허용하기'를 누르면 시스템 설정이 열립니다", "목록에서 MacB를 켭니다", "'MacB 다시 시작'을 누릅니다"])
                t.expectEqual(screen?.buttons.map(\.title), ["MacB 다시 시작", "허용하기"], "셋째 단계의 버튼도 처음부터 있음")
            }
            if !granted.contains(.accessibility) {
                t.expectEqual(content.row(.accessibility)?.buttons.map(\.action), [.request], "손쉬운 사용은 다시 시작할 필요가 없음")
            }
        }

        // 앱이 다시 시작 동작을 넣지 않았으면 그 버튼을 보여 주지 않고 직접 하는 방법을 적는다.
        let fixture = GuideFixture(granted: [])
        let guide = fixture.makeGuide(relaunch: false)
        t.expectEqual(guide.content.row(.screenCapture)?.buttons.map(\.action), [.request])
        t.expectEqual(guide.content.row(.screenCapture)?.steps.last, "MacB를 종료했다가 다시 엽니다")
        guide.perform(.request, on: .screenCapture)
        t.expectEqual(guide.content.row(.screenCapture)?.buttons.map(\.action), [.openSettings])
        t.expect(guide.content.row(.screenCapture)?.note?.contains("다시 열어야") == true)
        guide.perform(.relaunch, on: .screenCapture)
        t.expectEqual(fixture.relaunches, 0, "넣지 않은 다시 시작은 부르지 않음")
    }

    t.suite("권한 안내: 허용하기는 요청하고 맞는 설정 화면을 연다") {
        for permission in PermissionKind.allCases {
            let fixture = GuideFixture(granted: [])
            let guide = fixture.makeGuide()
            guide.perform(.request, on: permission)
            t.expectEqual(fixture.system.calls, ["request \(permission.rawValue)", "open \(permission.rawValue)"], "\(permission)")
            let row = guide.content.row(permission)
            t.expectEqual(row?.stage, .asked, "\(permission)")
            t.expect(row?.isFocused == true, "누른 줄을 앞세움 \(permission)")
            switch permission {
            case .screenCapture:
                t.expectEqual(row?.buttons.map(\.action), [.openSettings, .relaunch])
                t.expectEqual(row?.defaultButton?.action, .relaunch, "요청한 다음은 다시 시작할 차례")
                t.expect(row?.note?.contains("다시 시작") == true)
                guide.perform(.relaunch, on: .screenCapture)
                t.expectEqual(fixture.relaunches, 1)
            case .accessibility:
                t.expectEqual(row?.buttons.map(\.action), [.openSettings])
                t.expectEqual(row?.steps.last, "켜는 대로 여기에 '허용됨'이 표시됩니다")
            }

            fixture.system.calls.removeAll()
            guide.perform(.openSettings, on: permission)
            t.expectEqual(fixture.system.calls, ["open \(permission.rawValue)"], "설정만 다시 열기 \(permission)")
        }

        // 요청하자마자 허용되면(이미 켜져 있던 경우) 바로 허용됨.
        let fixture = GuideFixture(granted: [])
        fixture.system.grantOnRequest = [.accessibility]
        let guide = fixture.makeGuide()
        guide.perform(.request, on: .accessibility)
        t.expectEqual(guide.content.row(.accessibility)?.stage, .granted)
        t.expectEqual(guide.content.rows.first(where: \.isFocused)?.permission, .screenCapture, "앞세움이 남은 권한으로 넘어감")
    }

    t.suite("권한 안내: 기본 버튼(Return)은 어느 상태에서도 초기화가 아님") {
        for (permission, stage, relaunch) in allStageCombinations() {
            let (_, guide) = makeGuide(in: stage, permission, relaunch: relaunch)
            let label = "\(permission) \(stage) 다시 시작 \(relaunch)"
            let defaults = guide.content.rows.flatMap(\.buttons).filter(\.isDefault)
            t.expect(defaults.count <= 1, "기본 버튼은 많아야 하나 \(label)")
            t.expect(defaults.allSatisfy { !$0.action.isDestructive }, "초기화가 기본 버튼 \(label)")
            if let row = guide.content.row(permission), row.isFocused, stage != .resetting {
                t.expect(row.defaultButton != nil, "앞세운 줄에는 안전한 기본 버튼이 있음 \(label)")
            }
            // 창에서도 Return 키가 붙은 버튼이 초기화가 아니어야 한다.
            let titles = returnKeyButtons(in: guide.makeContentView {}).map(\.title)
            t.expect(titles.count <= 1 && titles.allSatisfy { !$0.contains("초기화") }, "Return 버튼 \(titles) \(label)")
        }

        // 리뷰의 재현(P1): 다시 시작 뒤 메뉴에서 권한 설정을 열고 Return.
        let fixture = GuideFixture(granted: [.accessibility])
        fixture.makeGuide().perform(.request, on: .screenCapture)
        let guide = fixture.makeGuide()
        guide.showAtLaunchIfNeeded()
        guide.show(focus: .screenCapture)
        guide.stopPolling()
        t.expectEqual(fixture.presenters.first?.activations, [true])
        t.expectEqual(guide.content.row(.screenCapture)?.stage, .stillMissing)
        let view = guide.makeContentView {}
        let window = offscreenWindow(for: view)
        defer { window.contentView = nil }
        fixture.system.calls.removeAll()
        let returnButtons = returnKeyButtons(in: view)
        t.expectEqual(returnButtons.map(\.title), ["시스템 설정 열기"])
        returnButtons.first?.performClick(nil)
        t.expectEqual(fixture.system.calls, ["open screenCapture"], "Return은 설정만 연다")
    }

    t.suite("권한 안내: 단계 글에 나오는 버튼은 그 줄에 실제로 있음") {
        for (permission, stage, relaunch) in allStageCombinations() {
            let (_, guide) = makeGuide(in: stage, permission, relaunch: relaunch)
            guard let row = guide.content.row(permission) else { continue }
            let label = "\(permission) \(stage) 다시 시작 \(relaunch)"
            let titles = Set(row.buttons.map(\.title))
            for text in row.steps + [row.note].compactMap({ $0 }) {
                for quoted in quotedNames(in: text) where quoted != "필요" && quoted != "허용됨" {
                    t.expect(titles.contains(quoted), "'\(quoted)' 버튼이 없음: \(text) — 버튼 \(titles.sorted()) \(label)")
                }
            }
            t.expect(!row.steps.isEmpty, "빠진 권한에는 순서가 있음 \(label)")
        }
    }

    t.suite("권한 안내: 손쉬운 사용은 설정에 다녀온 뒤에야 '요청했는데도 안 됨'") {
        let fixture = GuideFixture(granted: [.screenCapture])
        let guide = fixture.makeGuide()

        // 요청하기 전의 것은 근거가 되지 않는다.
        guide.systemSettingsActivated()
        guide.userReturned()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .missing)

        guide.perform(.request, on: .accessibility)
        // 리뷰의 재현(P7): 시스템 알림을 닫자마자 창이 다시 키 창이 됨. 설정에 다녀온 근거가 없다.
        guide.userReturned()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .asked, "설정에 가지 않고 돌아온 것은 근거가 아님")

        // '허용하기'가 연 설정이 앞으로 나왔다가 곧바로 돌아옴(알림을 닫는 사이 등). 켤 시간이 없었다.
        guide.systemSettingsActivated()
        fixture.clock.addTimeInterval(Guide.settingsVisitMinimum - 1)
        guide.userReturned()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .asked, "곧바로 돌아온 것은 근거가 아님")
        fixture.clock.addTimeInterval(60)
        guide.userReturned()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .asked, "다녀온 기록은 한 번만 씀")

        guide.systemSettingsActivated()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .asked, "설정에 있는 동안은 그대로")
        fixture.clock.addTimeInterval(20)
        guide.userReturned()
        let row = guide.content.row(.accessibility)
        t.expectEqual(row?.stage, .stillMissing, "설정에 머물다 돌아와도 꺼져 있음")
        t.expectEqual(row?.buttons.map(\.action), [.openSettings, .resetAndRequest])
        t.expectEqual(row?.button(.resetAndRequest)?.title, "초기화하고 다시 요청")
        t.expect(row?.note?.contains("다시 빌드") == true, "왜 그런지 설명: \(row?.note ?? "nil")")

        // 설정에서 MacB를 켜면 허용됨.
        fixture.system.granted.insert(.accessibility)
        guide.refresh()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .granted)

        // 다시 시작해야 반영되는 화면 기록은 돌아온 것만으로 판단하지 않는다.
        let screen = GuideFixture(granted: [.accessibility])
        let other = screen.makeGuide()
        other.perform(.request, on: .screenCapture)
        other.systemSettingsActivated()
        screen.clock.addTimeInterval(20)
        other.userReturned()
        t.expectEqual(other.content.row(.screenCapture)?.stage, .asked)
    }

    t.suite("권한 안내: 초기화 — 손쉬운 사용은 같은 프로세스에서 다시 요청") {
        let fixture = GuideFixture(granted: [.screenCapture])
        let guide = fixture.stillMissingGuide(.accessibility, relaunch: true)
        fixture.system.holdResets = true
        fixture.system.calls.removeAll()
        guide.perform(.resetAndRequest, on: .accessibility)
        t.expectEqual(guide.content.row(.accessibility)?.stage, .resetting)
        t.expect(guide.content.row(.accessibility)?.buttons.allSatisfy { !$0.isEnabled } == true, "지우는 동안은 버튼을 막음")
        guide.perform(.resetAndRequest, on: .accessibility)
        t.expectEqual(fixture.system.calls, ["reset accessibility"], "지우는 중에 또 눌러도 한 번만")
        fixture.system.finishResets(true)
        t.expectEqual(fixture.system.calls, ["reset accessibility", "request accessibility", "open accessibility"])
        t.expectEqual(guide.content.row(.accessibility)?.stage, .asked)
        t.expectEqual(fixture.relaunches, 0, "손쉬운 사용은 다시 시작하지 않음")

        // 실패하면 직접 지우는 방법을 알려 주고 다시 요청하지 않는다.
        let failing = GuideFixture(granted: [.screenCapture])
        let other = failing.stillMissingGuide(.accessibility, relaunch: true)
        failing.system.resetResult = false
        failing.system.calls.removeAll()
        other.perform(.resetAndRequest, on: .accessibility)
        let failed = other.content.row(.accessibility)
        t.expectEqual(failed?.stage, .stillMissing)
        t.expect(failed?.note?.contains("초기화하지 못했습니다") == true, "\(failed?.note ?? "nil")")
        t.expectEqual(failing.system.calls, ["reset accessibility"], "실패하면 다시 요청하지 않음")
        t.expectEqual(failed?.buttons.map(\.action), [.openSettings, .request], "직접 지운 뒤 다시 요청하는 길")
        t.expectEqual(failed?.defaultButton?.action, .openSettings)
        other.perform(.request, on: .accessibility)
        t.expectEqual(failing.system.calls, ["reset accessibility", "request accessibility", "open accessibility"])
        t.expect(other.content.row(.accessibility)?.note?.contains("초기화하지 못했습니다") != true, "다시 요청하면 실패 안내를 내림")
    }

    t.suite("권한 안내: 초기화 — 화면 기록은 다시 시작한 새 프로세스에서 요청") {
        let fixture = GuideFixture(granted: [.accessibility])
        let guide = fixture.stillMissingGuide(.screenCapture, relaunch: true)
        let reset = guide.content.row(.screenCapture)?.buttons.first(where: \.action.isDestructive)
        t.expectEqual(reset?.action, .resetAndRelaunch)
        t.expectEqual(reset?.title, "초기화하고 다시 시작", "누르면 다시 시작한다는 것이 이름에 드러남")
        fixture.system.calls.removeAll()
        guide.perform(.resetAndRelaunch, on: .screenCapture)
        t.expectEqual(fixture.system.calls, ["reset screenCapture"], "이 프로세스에서는 묻지 않음(답이 기억돼 있을 수 있다)")
        t.expectEqual(fixture.relaunches, 1)

        // 새 프로세스: 도착하자마자 요청하고 그 줄을 앞세워 띄운다.
        fixture.system.calls.removeAll()
        let arrived = fixture.makeGuide()
        arrived.showAtLaunchIfNeeded()
        arrived.stopPolling()
        t.expectEqual(fixture.system.calls, ["request screenCapture", "open screenCapture"])
        t.expectEqual(fixture.presenters.last?.activations, [true])
        t.expectEqual(arrived.content.row(.screenCapture)?.stage, .asked)
        t.expect(arrived.content.row(.screenCapture)?.isFocused == true)

        // 다음 다시 시작은 요청이 아니라 결과 확인이다.
        fixture.system.calls.removeAll()
        let afterThat = fixture.makeGuide()
        afterThat.showAtLaunchIfNeeded()
        afterThat.stopPolling()
        t.expect(!fixture.system.calls.contains("request screenCapture"), "요청은 한 번만: \(fixture.system.calls)")
        t.expectEqual(afterThat.content.row(.screenCapture)?.stage, .stillMissing)

        // 오래된 요청 기록은 쓰지 않는다(시스템 창이 엉뚱한 때 뜨면 안 된다).
        let stale = GuideFixture(granted: [.accessibility])
        stale.stillMissingGuide(.screenCapture, relaunch: true).perform(.resetAndRelaunch, on: .screenCapture)
        stale.clock.addTimeInterval(Guide.pendingLifetime + 1)
        stale.system.calls.removeAll()
        let late = stale.makeGuide()
        late.showAtLaunchIfNeeded()
        t.expectEqual(stale.system.calls, [], "오래된 기록으로는 묻지 않음")
        t.expectEqual(stale.presenters.count, 0)

        // 다시 시작 동작이 없으면 예전처럼 같은 프로세스에서 다시 요청한다.
        let plain = GuideFixture(granted: [.accessibility])
        let same = plain.stillMissingGuide(.screenCapture, relaunch: false)
        let plainReset = same.content.row(.screenCapture)?.buttons.first(where: \.action.isDestructive)
        t.expectEqual(plainReset?.action, .resetAndRequest)
        t.expectEqual(plainReset?.title, "초기화하고 다시 요청")
        plain.system.calls.removeAll()
        same.perform(.resetAndRequest, on: .screenCapture)
        t.expectEqual(plain.system.calls, ["reset screenCapture", "request screenCapture", "open screenCapture"])
        t.expectEqual(plain.relaunches, 0)

        // 다시 시작 뒤 할 일을 적지 못하면 다시 시작하지 않고 이 프로세스에서 요청한다.
        let readOnly = GuideFixture(granted: [.accessibility])
        let locked = readOnly.stillMissingGuide(.screenCapture, relaunch: true)
        readOnly.lockStateDirectory()
        defer { readOnly.unlockStateDirectory() }
        readOnly.system.calls.removeAll()
        locked.perform(.resetAndRelaunch, on: .screenCapture)
        t.expectEqual(readOnly.relaunches, 0, "적지 못하면 다시 시작하지 않음")
        t.expectEqual(readOnly.system.calls, ["reset screenCapture", "request screenCapture", "open screenCapture"])
    }

    t.suite("권한 안내: 초기화가 끝나지 않으면 정해 둔 시간 뒤 실패로") {
        let fixture = GuideFixture(granted: [.screenCapture])
        let guide = fixture.stillMissingGuide(.accessibility, relaunch: true, resetTimeout: 0.05)
        fixture.system.holdResets = true
        guide.perform(.resetAndRequest, on: .accessibility)
        t.expectEqual(guide.content.row(.accessibility)?.stage, .resetting)
        pumpGuideRunLoop(timeout: 2) { guide.content.row(.accessibility)?.stage != .resetting }
        let row = guide.content.row(.accessibility)
        t.expectEqual(row?.stage, .stillMissing, "멈춘 초기화에 갇히지 않음")
        t.expect(row?.note?.contains("초기화하지 못했습니다") == true)
        t.expect(row?.buttons.allSatisfy(\.isEnabled) == true, "다시 누를 수 있음")

        // 늦게 온 결과는 버린다.
        fixture.system.calls.removeAll()
        fixture.system.finishResets(true)
        t.expectEqual(fixture.system.calls, [], "시간이 지난 뒤의 성공으로 묻지 않음")
        t.expectEqual(guide.content.row(.accessibility)?.stage, .stillMissing)

        // 리뷰의 재현(P8): 창을 닫았다 다시 열어도 '지우는 중'으로 남지 않는다.
        guide.show(focus: .accessibility)
        guide.stopPolling()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .stillMissing)
    }

    t.suite("권한 안내: 화면 기록을 요청하고 다시 시작한 뒤 결과를 보여 줌") {
        // 다시 시작해도 여전히 없음 → 그 줄은 초기화 안내로 시작하고, 다시 시작할 길도 있다.
        let still = GuideFixture(granted: [.accessibility])
        let before = still.makeGuide()
        before.perform(.request, on: .screenCapture)
        before.perform(.relaunch, on: .screenCapture)
        t.expectEqual(still.relaunches, 1)
        let after = still.makeGuide()
        after.showAtLaunchIfNeeded()
        after.stopPolling()
        t.expectEqual(still.presenters.count, 0, "실패한 재시작이 안내 창을 다시 열지 않음")
        t.expect(!after.allowsScreenCapture(for: .screenshot))
        t.expectEqual(still.presenters.count, 0)
        t.expect(still.announcements.last?.contains("권한 설정") == true)
        still.announcements.removeAll()
        after.show(focus: .screenCapture)
        after.stopPolling()
        let row = after.content.row(.screenCapture)
        t.expectEqual(row?.stage, .stillMissing)
        t.expect(row?.isFocused == true)
        // 리뷰의 재현(P4): 설정에서 직접 켠 사람이 다시 시작할 수 있어야 한다.
        t.expectEqual(row?.buttons.map(\.action), [.relaunch, .openSettings, .resetAndRelaunch])
        after.perform(.relaunch, on: .screenCapture)
        t.expectEqual(still.relaunches, 2)
        still.system.granted.insert(.screenCapture)
        still.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(still.announcements, ["화면 기록 권한이 허용되었습니다"], "직접 켜고 다시 시작한 결과")
        still.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(still.presenters.count, 1, "결과는 한 번만 보여 줌")
        t.expectEqual(still.announcements.count, 1)

        // 시스템의 '종료 후 다시 열기'로 다시 시작해도(우리 버튼을 누르지 않아도) 결과를 보여 준다.
        // 화면 기록은 허용됐고 손쉬운 사용이 남았으면 그쪽을 앞세운다.
        let partly = GuideFixture(granted: [])
        partly.makeGuide().perform(.request, on: .screenCapture)
        partly.clock.addTimeInterval(4 * 60)
        partly.system.granted = [.screenCapture]
        let resumed = partly.makeGuide()
        resumed.showAtLaunchIfNeeded()
        resumed.stopPolling()
        t.expectEqual(partly.presenters.count, 0)
        t.expectEqual(partly.announcements, ["화면 기록 권한이 허용되었습니다"])
        t.expectEqual(resumed.content.row(.screenCapture)?.stage, .granted)
        t.expectEqual(resumed.content.rows.first(where: \.isFocused)?.permission, .accessibility)

        // 실행 중에 허용된 것이 보이면 다시 시작 뒤 확인할 것도 없다.
        let live = GuideFixture(granted: [.accessibility])
        let running = live.makeGuide()
        running.perform(.request, on: .screenCapture)
        live.system.granted.insert(.screenCapture)
        running.refresh()
        live.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(live.presenters.count, 0)
        t.expectEqual(live.announcements, [])
    }

    t.suite("권한 안내: 다시 시작 뒤 확인은 요청 직후의 다시 시작에만") {
        // 리뷰의 재현(P3): 요청하고 그만둔 채 종료했다가 며칠 뒤 로그인.
        let gaveUp = GuideFixture(granted: [.accessibility])
        let first = gaveUp.makeGuide()
        first.showAtLaunchIfNeeded()
        first.stopPolling()
        first.perform(.request, on: .screenCapture)
        gaveUp.clock.addTimeInterval(3 * 86400)
        let later = gaveUp.makeGuide()
        later.showAtLaunchIfNeeded()
        t.expectEqual(gaveUp.presenters.count, 1, "며칠 뒤에는 저절로 띄우지 않음")
        t.expectEqual(later.content.row(.screenCapture)?.stage, .missing, "초기화를 권하지 않음")

        // 유효 시간의 경계.
        for (age, expectShown) in [(Guide.pendingLifetime - 1, true), (Guide.pendingLifetime + 1, false)] {
            let fixture = GuideFixture(granted: [.accessibility])
            fixture.makeGuide().perform(.request, on: .screenCapture)
            fixture.clock.addTimeInterval(age)
            let next = fixture.makeGuide()
            next.showAtLaunchIfNeeded()
            next.stopPolling()
            t.expectEqual(next.content.row(.screenCapture)?.stage == .stillMissing, expectShown, "기록 뒤 \(Int(age))초")
        }

        // 리뷰의 재현(P2): 요청하지 않고 누른 다시 시작은 적지 않는다.
        let untouched = GuideFixture(granted: [.accessibility])
        let intro = untouched.makeGuide()
        intro.showAtLaunchIfNeeded()
        intro.stopPolling()
        intro.perform(.relaunch, on: .screenCapture)
        t.expectEqual(untouched.relaunches, 1)
        t.expect(!untouched.stateText.contains("screenCapture"), "기록 없음: \(untouched.stateText)")
        let next = untouched.makeGuide()
        next.showAtLaunchIfNeeded()
        t.expectEqual(untouched.presenters.count, 1, "다음 실행에서 띄우지 않음")
        t.expectEqual(next.content.row(.screenCapture)?.stage, .missing)

        // 요청한 지 오래돼도 우리 버튼으로 다시 시작하면 그때부터 센다.
        let slow = GuideFixture(granted: [.accessibility])
        let waiting = slow.makeGuide()
        waiting.perform(.request, on: .screenCapture)
        slow.clock.addTimeInterval(45 * 60)
        waiting.perform(.relaunch, on: .screenCapture)
        let resumed = slow.makeGuide()
        resumed.showAtLaunchIfNeeded()
        resumed.stopPolling()
        t.expectEqual(resumed.content.row(.screenCapture)?.stage, .stillMissing)
    }

    t.suite("권한 안내: 실행 직후 경고 알림이 떠 있으면 짧은 알림은 하지 않음") {
        let fixture = GuideFixture(granted: [.accessibility])
        fixture.makeGuide().perform(.request, on: .screenCapture)
        fixture.system.granted = [.screenCapture, .accessibility]
        fixture.makeGuide().showAtLaunchIfNeeded(warningOnScreen: true)
        t.expectEqual(fixture.announcements, [], "설정 오류 같은 경고를 가리지 않음")
        fixture.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(fixture.announcements, [], "기록은 쓴 것으로 끝남(다음 실행에 미루지 않음)")

        let quiet = GuideFixture(granted: [.accessibility])
        quiet.makeGuide().showAtLaunchIfNeeded(warningOnScreen: false)
        t.expectEqual(quiet.presenters.count, 1, "창은 경고와 상관없이 뜸")
        let warned = GuideFixture(granted: [.accessibility])
        let guide = warned.makeGuide()
        guide.showAtLaunchIfNeeded(warningOnScreen: true)
        guide.stopPolling()
        t.expectEqual(warned.presenters.count, 1, "처음 실행 안내 창은 경고가 있어도 뜸")
    }

    t.suite("권한 안내: 상태가 바뀌면 줄이 저절로 바뀜") {
        let fixture = GuideFixture(granted: [])
        let guide = fixture.makeGuide()
        guide.show()
        let presenter = fixture.presenters.first
        guide.perform(.request, on: .accessibility)
        presenter?.changes.removeAll()

        fixture.system.granted.insert(.accessibility)
        guide.refresh()
        t.expectEqual(guide.content.row(.accessibility)?.stage, .granted)
        t.expectEqual(guide.content.row(.accessibility)?.statusText, "허용됨")
        t.expectEqual(presenter?.changes, [true], "창에 '방금 허용됨'을 알림")
        guide.refresh()
        t.expectEqual(presenter?.changes, [true], "바뀐 것이 없으면 다시 그리지 않음")
        guide.stopPolling()

        let polled = GuideFixture(granted: [])
        let polling = polled.makeGuide(pollInterval: 0.03)
        polling.show()
        t.expect(polling.isPolling, "띄우면 확인을 시작함")
        polled.system.granted.insert(.accessibility)
        pumpGuideRunLoop(timeout: 2) { polling.content.row(.accessibility)?.isGranted == true }
        t.expectEqual(polling.content.row(.accessibility)?.stage, .granted, "확인 주기에 맞춰 바뀜")
        t.expectEqual(polled.presenters.first?.changes.last, true)

        polled.presenters.first?.isVisible = false
        pumpGuideRunLoop(timeout: 2) { !polling.isPolling }
        t.expect(!polling.isPolling, "닫힌 창은 확인하지 않음")
        polled.system.granted.insert(.screenCapture)
        pumpGuideRunLoop(timeout: 0.1)
        t.expectEqual(polling.content.row(.screenCapture)?.stage, .missing, "닫힌 동안은 그대로")
        polling.show()
        t.expectEqual(polling.content.row(.screenCapture)?.stage, .granted, "다시 띄우면 바로 확인")
        polling.stopPolling()
    }

    t.suite("권한 안내: 처음 실행할 때 한 번만, 빠진 것이 없으면 띄우지 않음") {
        let fixture = GuideFixture(granted: [.screenCapture])
        let first = fixture.makeGuide()
        first.showAtLaunchIfNeeded()
        first.stopPolling()
        t.expectEqual(fixture.presenters.count, 1, "처음 실행")
        t.expectEqual(fixture.presenters.first?.activations, [true])
        t.expect(FileManager.default.fileExists(atPath: fixture.stateFile.path), "띄운 것을 지원 폴더에 적음")
        fixture.makeGuide().showAtLaunchIfNeeded()
        fixture.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(fixture.presenters.count, 1, "그 뒤로는 저절로 띄우지 않음")

        let complete = GuideFixture(granted: [.screenCapture, .accessibility])
        complete.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(complete.presenters.count, 0, "모두 허용돼 있으면 띄우지 않음")
        complete.system.granted = []
        complete.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(complete.presenters.count, 0, "처음 실행은 지나갔으므로 나중에 빠져도 저절로 띄우지 않음")

        let broken = GuideFixture(granted: [])
        try Data("{ 깨진".utf8).write(to: broken.stateFile)
        broken.makeGuide().showAtLaunchIfNeeded()
        t.expectEqual(broken.presenters.count, 0, "읽을 수 없는 파일은 이미 안내한 것으로 봄")

        let guide = complete.makeGuide()
        guide.show()
        t.expectEqual(complete.presenters.count, 1, "메뉴에서 여는 것은 언제든 됨")
        guide.stopPolling()
    }

    t.suite("권한 안내: 기록을 적지 못하면 실행할 때마다 띄우지 않음") {
        // 리뷰의 재현(P5): 지원 폴더에 쓸 수 없음.
        let unwritable = GuideFixture(granted: [.accessibility])
        unwritable.lockStateDirectory()
        for _ in 0..<3 {
            let guide = unwritable.makeGuide()
            guide.showAtLaunchIfNeeded()
            guide.stopPolling()
        }
        unwritable.unlockStateDirectory()
        t.expectEqual(unwritable.presenters.count, 0, "처음 실행 안내가 매번 뜨지 않음")

        // 리뷰의 재현(P6): 기록 파일을 바꿀 수 없음.
        let readOnly = GuideFixture(granted: [.accessibility])
        readOnly.makeGuide().perform(.request, on: .screenCapture)
        readOnly.system.granted = [.screenCapture, .accessibility]
        readOnly.lockStateDirectory()
        for _ in 0..<3 { readOnly.makeGuide().showAtLaunchIfNeeded() }
        readOnly.unlockStateDirectory()
        t.expectEqual(readOnly.announcements, [], "허용 알림이 매번 뜨지 않음")
    }

    t.suite("권한 안내: 실행·확인·돌아옴은 초기화를 부르지 않음") {
        for (permission, stage, relaunch) in allStageCombinations() where stage != .resetting {
            let (fixture, guide) = makeGuide(in: stage, permission, relaunch: relaunch, pollInterval: 0.02)
            fixture.system.calls.removeAll()
            guide.refresh()
            guide.systemSettingsActivated()
            guide.userReturned()
            guide.show()
            guide.show(for: permission == .screenCapture ? .screenshot : .autoPaste)
            pumpGuideRunLoop(timeout: 0.1)
            guide.stopPolling()
            let next = fixture.makeGuide()
            next.showAtLaunchIfNeeded()
            next.stopPolling()
            next.userReturned()
            t.expect(!fixture.system.calls.contains { $0.hasPrefix("reset") },
                     "\(permission) \(stage) 다시 시작 \(relaunch): \(fixture.system.calls)")
        }
    }

    t.suite("권한 안내: 열려 있을 때 다시 부르면 새 창 없이 그 줄을 앞세움") {
        let fixture = GuideFixture(granted: [])
        let guide = fixture.makeGuide()
        guide.show()
        t.expectEqual(guide.content.headline, "몇 가지 기능에 macOS 권한이 필요합니다")

        guide.show(for: .autoPaste)
        t.expectEqual(fixture.presenters.count, 1, "창은 하나만")
        t.expectEqual(guide.content.headline, "자동으로 붙여넣으려면 손쉬운 사용 권한이 필요합니다")
        t.expectEqual(guide.content.rows.first(where: \.isFocused)?.permission, .accessibility)

        guide.show(for: .textRecognition)
        t.expectEqual(fixture.presenters.count, 1)
        t.expectEqual(guide.content.headline, "글자를 인식하려면 화면 기록 권한이 필요합니다")
        t.expectEqual(guide.content.rows.first(where: \.isFocused)?.permission, .screenCapture)

        guide.show(focus: .accessibility)
        t.expectEqual(guide.content.headline, "몇 가지 기능에 macOS 권한이 필요합니다", "메뉴에서 열면 하려던 일 줄은 없음")
        t.expectEqual(guide.content.rows.first(where: \.isFocused)?.permission, .accessibility)

        t.expectEqual(fixture.presenters.first?.activations, [true, false, true, true], "붙여넣기는 포커스를 빼앗지 않음")
        t.expectEqual(PermissionPurpose.slotCopy.activatesGuide, false)
        t.expectEqual(PermissionPurpose.screenshot.activatesGuide, true)
        t.expectEqual(PermissionPurpose.slotCopy.permission, .accessibility)
        t.expectEqual(PermissionPurpose.screenshot.sentence, "스크린샷을 찍으려면 화면 기록 권한이 필요합니다")

        guide.show(for: .screenshot)
        fixture.system.granted.insert(.screenCapture)
        guide.refresh()
        t.expectEqual(guide.content.headline, "화면 기록 권한이 허용되었습니다")
        t.expectEqual(guide.content.rows.map(\.permission), [.screenCapture], "캡처 중 손쉬운 사용을 요청하지 않음")
        fixture.system.granted.insert(.accessibility)
        guide.refresh()
        t.expectEqual(guide.content.headline, "화면 기록 권한이 허용되었습니다")
        t.expect(guide.content.allGranted)
        guide.stopPolling()
    }

    t.suite("권한 안내: 캡처와 OCR은 거부 상태에서 창을 반복해서 열지 않음") {
        let fixture = GuideFixture(granted: [.accessibility])
        let guide = fixture.makeGuide()
        t.expect(!guide.allowsScreenCapture(for: .screenshot))
        fixture.presenters.first?.isVisible = false
        t.expect(!guide.allowsScreenCapture(for: .textRecognition))
        t.expectEqual(fixture.presenters.first?.activations, [true])
        t.expectEqual(fixture.system.calls, [])
        fixture.system.granted.insert(.screenCapture)
        t.expect(guide.allowsScreenCapture(for: .textRecognition))
        fixture.system.granted.remove(.screenCapture)
        t.expect(!guide.allowsScreenCapture(for: .screenshot))
        t.expectEqual(fixture.presenters.first?.activations, [true, true])
        guide.stopPolling()
    }

    t.suite("권한 요청 고리: 실행당 한 번, 연결이 없으면 시스템 안내 창(앱 번들에서만)") {
        t.expect(PermissionRequestHook.accessibility.handler == nil, "자체 테스트에는 연결이 없음")
        // 연결이 없어도 자체 테스트(맨 실행 파일)에서는 시스템 창을 띄울 수 없다.
        t.expect(!PermissionRequestHook.systemPromptAllowed(bundlePath: Bundle.main.bundlePath),
                 "자체 테스트에서 시스템 안내 창이 뜰 수 있음: \(Bundle.main.bundlePath)")
        t.expect(PermissionRequestHook.systemPromptAllowed(bundlePath: "/Applications/MacB.app"))
        t.expect(PermissionRequestHook.systemPromptAllowed(bundlePath: "/Users/example/MacB/build/MacB.app"))
        t.expect(!PermissionRequestHook.systemPromptAllowed(bundlePath: "/Users/example/MacB/.build-perm/debug"))

        var fallbacks = 0
        let unset = PermissionRequestHook { fallbacks += 1 }
        t.expect(unset.requestOnce(for: .autoPaste))
        t.expect(!unset.requestOnce(for: .slotCopy))
        t.expect(!unset.requestOnce(for: .autoPaste))
        t.expectEqual(fallbacks, 1, "연결이 없으면 예전처럼 시스템 안내 창, 한 번만")
        t.expect(unset.hasRequested)

        var fallbacksWithHandler = 0
        var handled: [PermissionPurpose] = []
        let hooked = PermissionRequestHook { fallbacksWithHandler += 1 }
        hooked.handler = { handled.append($0) }
        hooked.requestOnce(for: .slotCopy)
        hooked.requestOnce(for: .autoPaste)
        t.expectEqual(handled, [.slotCopy], "연결된 안내 창으로, 한 번만")
        t.expectEqual(fallbacksWithHandler, 0)

        let fixture = GuideFixture(granted: [.screenCapture])
        let guide = fixture.makeGuide()
        let wired = PermissionRequestHook { fallbacksWithHandler += 1 }
        wired.handler = { guide.show(for: $0) }
        wired.requestOnce(for: .autoPaste)
        wired.requestOnce(for: .autoPaste)
        t.expectEqual(fixture.presenters.count, 1)
        t.expectEqual(fixture.presenters.first?.activations, [false])
        t.expectEqual(guide.content.headline, PermissionPurpose.autoPaste.sentence)
        guide.stopPolling()
    }

    t.suite("tccutil: 인자와 번들 ID 확인") {
        t.expectEqual(LivePermissionSystem.resetArguments(for: .screenCapture, bundleID: "dev.macb.app"),
                      ["reset", "ScreenCapture", "dev.macb.app"])
        t.expectEqual(LivePermissionSystem.resetArguments(for: .accessibility, bundleID: "dev.macb.app"),
                      ["reset", "Accessibility", "dev.macb.app"])
        // 번들 ID 없이 돌리면 모든 앱의 권한이 지워진다.
        t.expect(LivePermissionSystem.resetArguments(for: .screenCapture, bundleID: nil) == nil)
        t.expect(LivePermissionSystem.resetArguments(for: .accessibility, bundleID: "") == nil)
        t.expect(LivePermissionSystem.resetArguments(for: .accessibility, bundleID: "  \n") == nil)
        t.expect(LivePermissionSystem.resetTimeout > 0 && LivePermissionSystem.resetTimeout <= 30)
    }

    t.suite("권한 안내: 창 내용의 버튼이 동작으로 이어짐") {
        let fixture = GuideFixture(granted: [.accessibility])
        let guide = fixture.makeGuide()
        var closed = 0
        let view = guide.makeContentView { closed += 1 }
        let window = offscreenWindow(for: view)
        defer { window.contentView = nil }

        let buttons = allButtons(in: view)
        t.expectEqual(buttons.map(\.title), ["MacB 다시 시작", "허용하기", "닫기"], "기본 버튼이 오른쪽 끝")
        t.expectEqual(returnKeyButtons(in: view).map(\.title), ["허용하기"], "앞세운 줄의 허용하기가 기본 버튼")
        t.expectEqual(buttons.first { $0.title == "닫기" }?.keyEquivalent, "\u{1b}", "esc로 닫기")
        t.expect(view.fittingSize.width == 480, "창 폭 \(view.fittingSize)")

        buttons.first { $0.title == "허용하기" }?.performClick(nil)
        t.expectEqual(fixture.system.calls, ["request screenCapture", "open screenCapture"])
        buttons.first { $0.title == "MacB 다시 시작" }?.performClick(nil)
        t.expectEqual(fixture.relaunches, 1)
        buttons.first { $0.title == "닫기" }?.performClick(nil)
        t.expectEqual(closed, 1)

        // 요청했는데도 안 됨: 초기화는 안내 글 아래 따로, 아래 줄에는 다시 시작과 설정 열기.
        let stuck = GuideFixture(granted: [.accessibility])
        let stuckGuide = stuck.stillMissingGuide(.screenCapture, relaunch: true)
        let stuckView = stuckGuide.makeContentView {}
        let stuckWindow = offscreenWindow(for: stuckView)
        defer { stuckWindow.contentView = nil }
        t.expectEqual(allButtons(in: stuckView).map(\.title), ["초기화하고 다시 시작", "MacB 다시 시작", "시스템 설정 열기", "닫기"])
        t.expect(allButtons(in: stuckView).first?.keyEquivalent.isEmpty == true, "초기화에는 키가 붙지 않음")

        // 모두 허용되면 '닫기'가 기본 버튼.
        fixture.system.granted.insert(.screenCapture)
        guide.refresh()
        let done = allButtons(in: guide.makeContentView {})
        t.expectEqual(done.map(\.title), ["닫기"])
        t.expectEqual(done.first?.keyEquivalent, "\r")
    }
}

// MARK: - Stages

private enum GuideTestStage: CaseIterable {
    case missing
    case asked
    case stillMissing
    case resetFailed
    case resetting
}

@MainActor
private func allStageCombinations() -> [(PermissionKind, GuideTestStage, Bool)] {
    PermissionKind.allCases.flatMap { permission in
        GuideTestStage.allCases.flatMap { stage in [true, false].map { (permission, stage, $0) } }
    }
}

/// 한 권한을 원하는 단계까지 데려간다. 다른 권한은 허용된 상태라 이 줄이 앞세워진다.
@MainActor
private func makeGuide(
    in stage: GuideTestStage, _ permission: PermissionKind, relaunch: Bool, pollInterval: TimeInterval = 60
) -> (GuideFixture, PermissionGuide) {
    let fixture = GuideFixture(granted: Set(PermissionKind.allCases.filter { $0 != permission }))
    let guide: PermissionGuide
    switch stage {
    case .missing:
        guide = fixture.makeGuide(pollInterval: pollInterval, relaunch: relaunch)
    case .asked:
        guide = fixture.makeGuide(pollInterval: pollInterval, relaunch: relaunch)
        guide.perform(.request, on: permission)
    case .stillMissing, .resetFailed, .resetting:
        guide = fixture.stillMissingGuide(permission, relaunch: relaunch, pollInterval: pollInterval)
        if stage != .stillMissing {
            let reset = guide.content.row(permission)?.buttons.first(where: \.action.isDestructive)?.action ?? .resetAndRequest
            fixture.system.resetResult = false
            fixture.system.holdResets = stage == .resetting
            guide.perform(reset, on: permission)
        }
    }
    return (fixture, guide)
}

// MARK: - Fakes

@MainActor
private final class FakePermissionSystem: PermissionSystem {
    var granted: Set<PermissionKind>
    var calls: [String] = []
    /// 요청하자마자 허용되는 권한(이미 켜져 있던 경우).
    var grantOnRequest: Set<PermissionKind> = []
    var resetResult = true
    /// true면 초기화를 끝내지 않고 `finishResets`를 기다린다.
    var holdResets = false
    private var pendingResets: [@MainActor (Bool) -> Void] = []

    init(granted: Set<PermissionKind>) {
        self.granted = granted
    }

    func isGranted(_ permission: PermissionKind) -> Bool {
        granted.contains(permission)
    }

    func request(_ permission: PermissionKind) {
        calls.append("request \(permission.rawValue)")
        if grantOnRequest.contains(permission) { granted.insert(permission) }
    }

    func openSettings(_ permission: PermissionKind) {
        calls.append("open \(permission.rawValue)")
    }

    func reset(_ permission: PermissionKind, completion: @escaping @MainActor (Bool) -> Void) {
        calls.append("reset \(permission.rawValue)")
        if holdResets {
            pendingResets.append(completion)
        } else {
            completion(resetResult)
        }
    }

    func finishResets(_ succeeded: Bool) {
        let pending = pendingResets
        pendingResets.removeAll()
        for completion in pending { completion(succeeded) }
    }
}

@MainActor
private final class FakeGuidePresenter: PermissionGuidePresenting {
    var isVisible = false
    var activations: [Bool] = []
    var changes: [Bool] = []

    func present(activate: Bool) {
        isVisible = true
        activations.append(activate)
    }

    func contentDidChange(newlyGranted: Bool) {
        changes.append(newlyGranted)
    }
}

/// 가짜 시스템, 임시 지원 폴더, 바꿀 수 있는 시계. 같은 고정 장치에서 만든 안내끼리는 상태 파일을 같이 쓴다(다시 시작을 흉내 낸다).
@MainActor
private final class GuideFixture {
    let system: FakePermissionSystem
    let stateFile: URL
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var presenters: [FakeGuidePresenter] = []
    var announcements: [String] = []
    var relaunches = 0

    init(granted: Set<PermissionKind>) {
        system = FakePermissionSystem(granted: granted)
        stateFile = makeTemporaryDirectory("macb-permission-guide").appendingPathComponent("permission-guide.json")
    }

    var stateText: String {
        (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
    }

    func makeGuide(pollInterval: TimeInterval = 60, relaunch: Bool = true, resetTimeout: TimeInterval = 60) -> PermissionGuide {
        let guide = PermissionGuide(
            system: system,
            stateFile: stateFile,
            pollInterval: pollInterval,
            resetTimeout: resetTimeout,
            now: { [unowned self] in self.clock },
            announce: { [unowned self] message in self.announcements.append(message) },
            makePresenter: { [unowned self] _ in
                let presenter = FakeGuidePresenter()
                self.presenters.append(presenter)
                return presenter
            }
        )
        if relaunch {
            guide.relaunchAction = { [unowned self] in self.relaunches += 1 }
        }
        return guide
    }

    /// 요청했는데도 허용되지 않은 단계의 안내. 화면 기록은 요청 → 다시 시작 → 여전히 없음,
    /// 손쉬운 사용은 요청 → 시스템 설정에 다녀옴 → 여전히 없음. 거치며 생긴 창·호출 기록은 지운다.
    func stillMissingGuide(
        _ permission: PermissionKind, relaunch: Bool, pollInterval: TimeInterval = 60, resetTimeout: TimeInterval = 60
    ) -> PermissionGuide {
        let guide: PermissionGuide
        if permission.needsRelaunch {
            makeGuide(relaunch: relaunch).perform(.request, on: permission)
            guide = makeGuide(pollInterval: pollInterval, relaunch: relaunch, resetTimeout: resetTimeout)
            guide.showAtLaunchIfNeeded()
        } else {
            guide = makeGuide(pollInterval: pollInterval, relaunch: relaunch, resetTimeout: resetTimeout)
            guide.perform(.request, on: permission)
            guide.systemSettingsActivated()
            clock.addTimeInterval(20)
            guide.userReturned()
        }
        guide.stopPolling()
        presenters.removeAll()
        system.calls.removeAll()
        return guide
    }

    func lockStateDirectory() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateFile.deletingLastPathComponent().path)
    }

    func unlockStateDirectory() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateFile.deletingLastPathComponent().path)
    }
}

// MARK: - Helpers

/// 글에서 작은따옴표로 감싼 이름들.
private func quotedNames(in text: String) -> [String] {
    text.components(separatedBy: "'").enumerated().compactMap { index, part in index % 2 == 1 ? part : nil }
}

/// 화면에 올리지 않는 창. 버튼을 누르려면 창 안에 있어야 한다.
@MainActor
private func offscreenWindow(for view: NSView) -> NSWindow {
    if NSApp == nil {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless],
                          backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    return window
}

@MainActor
private func allButtons(in view: NSView) -> [NSButton] {
    var found: [NSButton] = []
    for subview in view.subviews {
        if let button = subview as? NSButton {
            found.append(button)
        } else {
            found += allButtons(in: subview)
        }
    }
    return found
}

@MainActor
private func returnKeyButtons(in view: NSView) -> [NSButton] {
    allButtons(in: view).filter { $0.keyEquivalent == "\r" }
}

/// 메인 런루프를 돌려 예약된 작업(타이머 등)을 실행한다. `done`이 참이 되거나 시간이 다 되면 멈춘다.
@MainActor
private func pumpGuideRunLoop(timeout: TimeInterval, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
