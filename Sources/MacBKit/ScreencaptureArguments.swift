import CoreGraphics

/// `/usr/sbin/screencapture`에 넘길 인자를 만든다. 화면·파일과 무관한 순수 계산이라 테스트할 수 있다.
public enum ScreencaptureArguments {
    public enum Mode: Equatable, Sendable {
        /// 드래그로 영역을 고른다.
        case area
        /// 창 하나를 클릭해서 고른다.
        case window
        /// 화면 하나 전체. 두 사각형 모두 AppKit 화면 좌표(pt, 주 화면 왼쪽 아래가 원점, y는 위로)이고,
        /// 주 화면은 `NSScreen.screens.first`(메뉴 막대가 있는 화면)다.
        case screen(frame: CGRect, primaryScreenFrame: CGRect)
    }

    public enum Output: Equatable, Sendable {
        case clipboard
        /// 저장할 파일의 절대 경로.
        case file(String)
    }

    public static func make(mode: Mode, output: Output, sound: Bool, windowShadow: Bool) -> [String] {
        var arguments: [String] = []
        switch mode {
        case .area:
            arguments += ["-i"]
        case .window:
            arguments += ["-i", "-W"]
            if !windowShadow { arguments += ["-o"] }
        case .screen(let frame, let primaryScreenFrame):
            // 화면 번호(-D)는 NSScreen.screens의 순서와 같다는 보장이 없어서 사각형으로 고른다.
            let rect = captureRect(for: frame, primaryScreenFrame: primaryScreenFrame)
            arguments += ["-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"]
        }
        if !sound { arguments += ["-x"] }
        switch output {
        case .clipboard:
            arguments += ["-c"]
        case .file(let path):
            arguments += [path]
        }
        return arguments
    }

    /// AppKit 화면 좌표의 사각형을 `screencapture -R`이 받는 전역 좌표로 바꾼다.
    /// `-R`은 주 화면 왼쪽 위가 원점이고 y가 아래로 커진다(pt). 주 화면 위나 왼쪽에 놓인 화면은 음수가 된다.
    public static func captureRect(for frame: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(),
            y: (primaryScreenFrame.maxY - frame.maxY).rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }
}
