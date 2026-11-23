import AppKit
import MacBKit

/// 캡처 도구 모음: 스크린샷, 글자 인식, 색상 추출, 화면 녹화.
///
/// 영역·창을 고르는 화면은 시스템의 `screencapture`를 그대로 쓴다(⌘⇧4와 같은 조작감).
@MainActor
final class CaptureService {
    enum Mode {
        case area
        case window
        case screen
    }

    enum Destination {
        case clipboard
        case file
    }

    var config: AppConfig.Capture

    private let pasteboard = NSPasteboard.general
    private var isSelecting = false
    private var colorSampler: NSColorSampler?

    init(config: AppConfig.Capture) {
        self.config = config
    }

    // MARK: Screenshots

    func capture(_ mode: Mode, to destination: Destination) {
        guard !isSelecting, PermissionGuide.shared.allowsScreenCapture(for: .screenshot) else { return }

        let target: ScreencaptureArguments.Mode
        switch mode {
        case .area:
            target = .area
        case .window:
            target = .window
        case .screen:
            // 커서가 있는 화면만 찍는다.
            let mouse = NSEvent.mouseLocation
            guard
                let primary = NSScreen.screens.first,
                let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            else { return }
            target = .screen(frame: screen.frame, primaryScreenFrame: primary.frame)
        }

        switch destination {
        case .clipboard:
            let arguments = ScreencaptureArguments.make(
                mode: target, output: .clipboard, sound: config.sound, windowShadow: config.windowShadow
            )
            let before = pasteboard.changeCount
            runScreencapture(arguments) { [weak self] succeeded in
                // 사용자가 esc로 취소하면 클립보드가 그대로다. 그 사이 다른 앱이 글을 복사했을 수도 있어서 이미지인지도 본다.
                guard let self, succeeded, self.pasteboard.changeCount != before,
                      self.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else { return }
                Toast.show("스크린샷을 복사했습니다", symbol: "checkmark.circle.fill", detail: "⌘V로 붙여넣기")
            }
        case .file:
            let file = nextScreenshotURL()
            let arguments = ScreencaptureArguments.make(
                mode: target, output: .file(file.path), sound: config.sound, windowShadow: config.windowShadow
            )
            runScreencapture(arguments) { succeeded in
                guard succeeded, FileManager.default.fileExists(atPath: file.path) else { return }
                Toast.show("스크린샷을 저장했습니다", symbol: "checkmark.circle.fill", detail: file.lastPathComponent)
            }
        }
    }

    // MARK: Text recognition

    func recognizeText() {
        guard !isSelecting, PermissionGuide.shared.allowsScreenCapture(for: .textRecognition) else { return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macb-ocr-\(UUID().uuidString).png")
        let languages = config.ocrLanguages

        let arguments = ScreencaptureArguments.make(
            mode: .area, output: .file(file.path), sound: false, windowShadow: config.windowShadow
        )
        runScreencapture(arguments) { [weak self] succeeded in
            guard succeeded, FileManager.default.fileExists(atPath: file.path) else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try TextRecognizer.recognize(imageAt: file, languages: languages) }
                try? FileManager.default.removeItem(at: file)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishTextRecognition(result) }
                }
            }
        }
    }

    private func finishTextRecognition(_ result: Result<[String], Error>) {
        switch result {
        case .success(let lines) where !lines.isEmpty:
            pasteboard.clearContents()
            pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
            let preview = lines[0].count > 40 ? String(lines[0].prefix(40)) + "…" : lines[0]
            Toast.show("글자 \(lines.count)줄을 복사했습니다", symbol: "text.viewfinder", detail: preview)
        case .success:
            Toast.show("글자를 찾지 못했습니다", symbol: "text.viewfinder")
        case .failure(let error):
            Log.error("ocr failed: \(error)")
            Toast.show("글자 인식에 실패했습니다", symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Color

    func pickColor() {
        guard colorSampler == nil else { return }
        let sampler = NSColorSampler()
        colorSampler = sampler
        sampler.show { [weak self] color in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.colorSampler = nil
                guard let color = color?.usingColorSpace(.sRGB) else { return }
                let red = Int((color.redComponent * 255).rounded())
                let green = Int((color.greenComponent * 255).rounded())
                let blue = Int((color.blueComponent * 255).rounded())
                let hex = String(format: "#%02X%02X%02X", red, green, blue)
                self.pasteboard.clearContents()
                self.pasteboard.setString(hex, forType: .string)
                Toast.show("\(hex) 복사했습니다", detail: "RGB \(red), \(green), \(blue)", swatch: color)
            }
        }
    }

    // MARK: Recording

    /// 시스템의 캡처 도구 막대(⌘⇧5)를 연다. 녹화 범위·마이크 선택은 거기서 한다.
    func openRecordingToolbar() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Log.error("screenshot toolbar failed to open: \(error.localizedDescription)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Toast.show("화면 녹화 도구를 열지 못했습니다", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: Plumbing

    /// `completion`은 `screencapture`가 0으로 끝났는지를 받는다. 0이어도 사용자가 esc로 취소했으면
    /// 결과물이 없을 수 있으니, 받는 쪽은 결과물(파일, 클립보드)도 따로 확인해야 한다.
    private func runScreencapture(_ arguments: [String], completion: @escaping @MainActor (_ succeeded: Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let bySignal = finished.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isSelecting = false
                    if status != 0 || bySignal {
                        // 선택 중 esc로 취소해도 0이 아닐 수 있어서 알림 없이 기록만 남긴다.
                        Log.info("screencapture ended with \(bySignal ? "signal" : "status") \(status)")
                    }
                    completion(status == 0 && !bySignal)
                }
            }
        }
        do {
            isSelecting = true
            try process.run()
        } catch {
            isSelecting = false
            Log.error("screencapture failed to start: \(error.localizedDescription)")
            Toast.show("캡처를 시작하지 못했습니다", symbol: "exclamationmark.triangle")
        }
    }

    private var saveDirectory: URL {
        let configured = config.saveDirectory.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        // 시스템 스크린샷 저장 위치를 바꿔 둔 사람은 거기에 맞춘다.
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func nextScreenshotURL() -> URL {
        let directory = AppPaths.ensureDirectory(saveDirectory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "스크린샷 \(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent("\(base).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix)).png")
            suffix += 1
        }
        return candidate
    }
}
