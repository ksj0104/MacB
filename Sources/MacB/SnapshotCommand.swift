import AppKit
import MacBClipboard
import MacBKit

/// `MacB --snapshot <폴더>`: 화면에 아무것도 띄우지 않고 원형 메뉴, 토스트, 단축키 설정 창을 PNG로 그려 낸다.
/// 생김새를 눈으로 확인하기 위한 개발용 명령이다.
@MainActor
enum SnapshotCommand {
    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // 실제 클립보드와 저장소를 건드리지 않도록 임시 것들로 만든다.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("macb-snapshot-\(UUID().uuidString)", isDirectory: true)
            let pasteboard = NSPasteboard.withUniqueName()
            defer {
                pasteboard.releaseGlobally()
                try? FileManager.default.removeItem(at: scratch)
            }
            let catalog = ActionCatalog(
                capture: CaptureService(config: AppConfig.Capture()),
                clipboard: ClipboardFeature(config: AppConfig.Clipboard(), storageDirectory: scratch, pasteboard: pasteboard)
            )
            let items = catalog.resolve(AppConfig.RadialMenu.defaultItems)

            let shots: [(name: String, highlighted: Int?, light: Bool)] = [
                ("radial-idle-dark", nil, false),
                ("radial-selected-dark", 0, false),
                ("radial-selected-light", 2, true),
                ("radial-idle-light", nil, true),
            ]
            for shot in shots {
                guard let rep = RadialMenuController.renderSnapshot(
                    items: items, highlighted: shot.highlighted, lightBackdrop: shot.light
                ) else { throw SnapshotError.renderFailed(shot.name) }
                try write(rep, to: directory.appendingPathComponent("\(shot.name).png"))
            }

            // 항목 수가 다를 때(사용자 설정)도 모양이 유지되는지.
            for count in [3, 5, 12] {
                let custom = (0..<count).map { index in
                    RadialItem(id: "sample.\(index)", title: "항목 \(index + 1)", subtitle: "예시 항목입니다",
                               icon: index % 2 == 0 ? .symbol("star") : .text("🙂"), perform: {})
                }
                guard let rep = RadialMenuController.renderSnapshot(items: custom, highlighted: 1, lightBackdrop: false)
                else { throw SnapshotError.renderFailed("radial-\(count)") }
                try write(rep, to: directory.appendingPathComponent("radial-\(count)-items.png"))
            }

            let toasts: [(name: String, rep: NSBitmapImageRep?)] = [
                ("toast-basic", Toast.renderSnapshot("스크린샷을 복사했습니다", symbol: "checkmark.circle.fill", detail: "⌘V로 붙여넣기")),
                ("toast-color", Toast.renderSnapshot("#3A7BD5 복사했습니다", detail: "RGB 58, 123, 213", swatch: NSColor(srgbRed: 0.227, green: 0.482, blue: 0.835, alpha: 1))),
                ("toast-long", Toast.renderSnapshot("화면 기록 권한이 필요합니다", symbol: "lock.shield", detail: "시스템 설정에서 MacB를 켠 다음, 메뉴 막대의 'MacB 다시 시작'을 눌러 주세요")),
            ]
            for toast in toasts {
                guard let rep = toast.rep else { throw SnapshotError.renderFailed(toast.name) }
                try write(rep, to: directory.appendingPathComponent("\(toast.name).png"))
            }

            // 단축키 설정 창. 실제 config.json이 아니라 예시 설정으로 그린다.
            _ = try ShortcutSettingsWindowController.writeDebugSnapshots(
                to: directory, tools: catalog.shortcutTools, locateApp: ActionCatalog.applicationURL(for:)
            )

            try PermissionGuide.writeDebugSnapshots(to: directory)

            print("snapshots written to \(directory.path)")
            return 0
        } catch {
            print("snapshot failed: \(error)")
            return 1
        }
    }

    private enum SnapshotError: Error {
        case renderFailed(String)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }
}
