import AppKit

// Swift 5 모드에서는 main.swift의 최상위 코드가 메인 액터로 취급되지 않아서 직접 알려 준다.
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    // 개발·빌드용 명령. 화면에는 아무것도 띄우지 않는다.
    if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
        exit(SnapshotCommand.run(outputDirectory: arguments[flag + 1]))
    }
    if let flag = arguments.firstIndex(of: "--make-icon"), arguments.count > flag + 1 {
        exit(IconCommand.run(iconsetPath: arguments[flag + 1]))
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // Dock 아이콘 없이 메뉴 막대에만 사는 앱.
    application.setActivationPolicy(.accessory)
    // NSApplication은 delegate를 약하게 잡으므로 실행 내내 살아 있도록 붙들어 둔다.
    withExtendedLifetime(delegate) {
        application.run()
    }
}
