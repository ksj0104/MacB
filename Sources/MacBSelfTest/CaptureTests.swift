import AppKit
import MacBKit

@MainActor
func runCaptureTests(_ t: TestRunner) {
    t.suite("TextRecognizer: 조각을 읽는 순서의 줄로 정리") {
        typealias Fragment = TextRecognizer.Fragment
        let lines = TextRecognizer.lines(from: [
            Fragment(text: "둘째 줄", box: CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.1)),
            Fragment(text: "오른쪽", box: CGRect(x: 0.6, y: 0.81, width: 0.2, height: 0.1)),
            Fragment(text: "첫 줄 왼쪽", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.1)),
        ])
        t.expectEqual(lines, ["첫 줄 왼쪽 오른쪽", "둘째 줄"])
        t.expectEqual(TextRecognizer.lines(from: []), [])
    }

    t.suite("TextRecognizer: 실제 인식 (한글 + 영어)") {
        // 화면을 찍는 대신 글자를 직접 그린 이미지로 인식 경로 전체를 돌려 본다.
        let image = try renderText(["Hello MacB 2026", "안녕하세요 클립보드"])
        let lines = try TextRecognizer.recognize(image: image, languages: ["ko-KR", "en-US"])
        let joined = lines.joined(separator: "\n")
        t.expectEqual(lines.count, 2, "줄 수: \(lines)")
        t.expect(joined.contains("Hello"), "영어 인식 실패: \(lines)")
        t.expect(joined.contains("2026"), "숫자 인식 실패: \(lines)")
        t.expect(joined.contains("안녕하세요"), "한글 인식 실패: \(lines)")
        t.expect(joined.contains("클립보드"), "한글 인식 실패: \(lines)")

        // 지원하지 않는 언어 코드가 섞여 있어도 요청이 통째로 실패하면 안 된다.
        let tolerant = try TextRecognizer.recognize(image: image, languages: ["xx-XX", "en-US"])
        t.expect(tolerant.joined().contains("Hello"), "언어 코드 걸러내기 실패: \(tolerant)")
    }

    t.suite("ScreencaptureArguments: 모드·저장 위치·소리·그림자") {
        typealias Arguments = ScreencaptureArguments
        t.expectEqual(Arguments.make(mode: .area, output: .clipboard, sound: true, windowShadow: true), ["-i", "-c"])
        t.expectEqual(Arguments.make(mode: .area, output: .clipboard, sound: true, windowShadow: false), ["-i", "-c"],
                      "그림자 설정은 창 캡처에만")
        t.expectEqual(Arguments.make(mode: .area, output: .file("/tmp/스크린샷 1.png"), sound: false, windowShadow: true),
                      ["-i", "-x", "/tmp/스크린샷 1.png"], "글자 인식도 이 형태(소리 없이 임시 파일로)")
        t.expectEqual(Arguments.make(mode: .window, output: .clipboard, sound: true, windowShadow: true), ["-i", "-W", "-c"])
        t.expectEqual(Arguments.make(mode: .window, output: .file("/a/b.png"), sound: false, windowShadow: false),
                      ["-i", "-W", "-o", "-x", "/a/b.png"])

        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        t.expectEqual(Arguments.make(mode: .screen(frame: primary, primaryScreenFrame: primary), output: .clipboard,
                                     sound: true, windowShadow: false),
                      ["-R", "0,0,1512,982", "-c"])
        t.expectEqual(Arguments.make(mode: .screen(frame: primary, primaryScreenFrame: primary), output: .file("/s.png"),
                                     sound: false, windowShadow: true),
                      ["-R", "0,0,1512,982", "-x", "/s.png"])
        let all = [
            Arguments.make(mode: .screen(frame: primary, primaryScreenFrame: primary), output: .clipboard, sound: true, windowShadow: true),
            Arguments.make(mode: .area, output: .clipboard, sound: true, windowShadow: true),
        ]
        t.expect(all.allSatisfy { !$0.contains("-D") }, "화면 번호(-D)로 고르지 않음")
    }

    t.suite("ScreencaptureArguments: 화면 사각형을 -R 좌표로") {
        typealias Arguments = ScreencaptureArguments
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func rect(_ frame: CGRect) -> CGRect { Arguments.captureRect(for: frame, primaryScreenFrame: primary) }

        t.expectEqual(rect(primary), CGRect(x: 0, y: 0, width: 1440, height: 900), "주 화면은 그대로")
        // 오른쪽, 아랫변을 맞춘 더 큰 화면: 위쪽이 주 화면보다 180pt 높다.
        t.expectEqual(rect(CGRect(x: 1440, y: 0, width: 1920, height: 1080)), CGRect(x: 1440, y: -180, width: 1920, height: 1080))
        // 왼쪽, 윗변을 맞춘 화면.
        t.expectEqual(rect(CGRect(x: -1920, y: -180, width: 1920, height: 1080)), CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        // 위에 놓인 화면.
        t.expectEqual(rect(CGRect(x: -560, y: 900, width: 2560, height: 1440)), CGRect(x: -560, y: -1440, width: 2560, height: 1440))
        // 아래에 놓인 화면.
        t.expectEqual(rect(CGRect(x: 0, y: -1080, width: 1920, height: 1080)), CGRect(x: 0, y: 900, width: 1920, height: 1080))

        t.expectEqual(
            Arguments.make(mode: .screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), primaryScreenFrame: primary),
                           output: .clipboard, sound: false, windowShadow: true),
            ["-R", "-1920,-180,1920,1080", "-x", "-c"], "왼쪽 화면은 음수 좌표"
        )
        t.expectEqual(
            Arguments.make(mode: .screen(frame: CGRect(x: 0, y: 900, width: 2560, height: 1440), primaryScreenFrame: primary),
                           output: .file("/s.png"), sound: true, windowShadow: true),
            ["-R", "0,-1440,2560,1440", "/s.png"], "위쪽 화면은 음수 좌표"
        )
    }

    t.suite("TextRecognizer: 글자가 없는 이미지") {
        let image = try renderText([])
        let lines = try TextRecognizer.recognize(image: image, languages: ["ko-KR", "en-US"])
        t.expectEqual(lines, [])
    }
}

private struct RenderFailure: Error {}

private func renderText(_ lines: [String]) throws -> CGImage {
    let size = NSSize(width: 900, height: 320)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { throw RenderFailure() }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 48, weight: .regular),
        .foregroundColor: NSColor.black,
    ]
    for (index, line) in lines.enumerated() {
        let y = size.height - 110 - CGFloat(index) * 110
        NSAttributedString(string: line, attributes: attributes).draw(at: NSPoint(x: 50, y: y))
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let image = rep.cgImage else { throw RenderFailure() }
    return image
}
