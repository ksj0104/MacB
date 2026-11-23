import AppKit
import MacBClipboard
import MacBKit

// 사용법:
//   MacBSelfTest                    모든 테스트 실행 (실패 시 종료 코드 1)
//   MacBSelfTest --snapshot <폴더>   클립보드 패널을 화면 밖에서 그려 PNG로 저장

// Swift 5 모드에서는 main.swift의 최상위 코드가 메인 액터로 취급되지 않아서 직접 알려 준다.
let exitCode: Int32 = MainActor.assumeIsolated {
    let arguments = CommandLine.arguments

    if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ClipboardFeature.writeDebugSnapshots(to: directory)
            try PermissionGuide.writeDebugSnapshots(to: directory)
            print("snapshots written to \(directory.path)")
            return 0
        } catch {
            print("snapshot failed: \(error)")
            return 1
        }
    }

    let runner = TestRunner()
    runKitTests(runner)
    runURLCommandTests(runner)
    runConfigWatcherTests(runner)
    runCaptureTests(runner)
    runClipboardTests(runner)
    runPermissionGuideTests(runner)
    runHotKeyCenterTests(runner)
    runInputSwitchTests(runner)
    runShortcutSettingsTests(runner)
    runConfigLinkTests(runner)
    return runner.finish()
}
exit(exitCode)
