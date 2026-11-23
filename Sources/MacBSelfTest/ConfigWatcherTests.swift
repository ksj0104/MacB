import Foundation
import MacBKit

/// 설정 파일 감시 테스트. 임시 폴더에서 실제로 파일을 고치고, 런루프를 정해진 시간만큼만 돌려 알림을 기다린다.
@MainActor
func runConfigWatcherTests(_ t: TestRunner) {
    let fileManager = FileManager.default

    t.suite("ConfigWatcher: 보통 파일 — 제자리 저장") {
        let directory = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{\"a\": 1}".utf8).write(to: file)

        let probe = WatchProbe(file: file)
        t.expect(probe.staysQuiet(), "아무것도 안 했는데 알림이 옴")

        let inode = try inodeNumber(file)
        probe.expectOneNotification(t, "제자리 저장(같은 크기)") {
            try writeInPlace("{\"a\": 2}", to: file)
        }
        let inodeAfterWrite = try inodeNumber(file)
        t.expectEqual(inodeAfterWrite, inode, "테스트 전제: 제자리 저장이어야 함")
        probe.expectOneNotification(t, "제자리 저장(크기 바뀜)") {
            try writeInPlace("{\"a\": 300}", to: file)
        }
    }

    t.suite("ConfigWatcher: 보통 파일 — 바꿔치기 저장") {
        let directory = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{\"a\": 1}".utf8).write(to: file)

        let probe = WatchProbe(file: file)
        let inode = try inodeNumber(file)
        probe.expectOneNotification(t, "바꿔치기 저장") {
            try Data("{\"a\": 2}".utf8).write(to: file, options: .atomic)
        }
        let inodeAfterReplace = try inodeNumber(file)
        t.expect(inodeAfterReplace != inode, "테스트 전제: 바꿔치기 저장이어야 함")
        // 바꿔치기 뒤에는 새 파일을 지켜봐야 한다.
        probe.expectOneNotification(t, "바꿔치기 뒤 제자리 저장") {
            try writeInPlace("{\"a\": 3}", to: file)
        }
    }

    t.suite("ConfigWatcher: 보통 파일 — 지웠다가 다시 만들기") {
        let directory = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{\"a\": 1}".utf8).write(to: file)

        let probe = WatchProbe(file: file)
        probe.expectOneNotification(t, "지우기") {
            try fileManager.removeItem(at: file)
        }
        probe.expectOneNotification(t, "다시 만들기") {
            try Data("{\"a\": 2}".utf8).write(to: file)
        }
        probe.expectOneNotification(t, "다시 만든 파일의 제자리 저장") {
            try writeInPlace("{\"a\": 33}", to: file)
        }
    }

    t.suite("ConfigWatcher: 심볼릭 링크 — 실제 파일 제자리 저장") {
        let root = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: root) }
        let (link, target) = try makeLinkedConfig(in: root)

        let probe = WatchProbe(file: link)
        t.expect(probe.staysQuiet(), "아무것도 안 했는데 알림이 옴")
        let inode = try inodeNumber(target)
        probe.expectOneNotification(t, "링크 대상 제자리 저장(같은 크기)") {
            try writeInPlace("{\"b\": 2}", to: target)
        }
        let inodeAfterWrite = try inodeNumber(target)
        t.expectEqual(inodeAfterWrite, inode, "테스트 전제: 제자리 저장이어야 함")
        probe.expectOneNotification(t, "링크 대상 제자리 저장(크기 바뀜)") {
            try writeInPlace("{\"b\": 200}", to: target)
        }
    }

    t.suite("ConfigWatcher: 심볼릭 링크 — 실제 파일 바꿔치기 저장") {
        let root = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: root) }
        let (link, target) = try makeLinkedConfig(in: root)

        let probe = WatchProbe(file: link)
        let inode = try inodeNumber(target)
        probe.expectOneNotification(t, "링크 대상 바꿔치기 저장") {
            try Data("{\"b\": 2}".utf8).write(to: target, options: .atomic)
        }
        let inodeAfterReplace = try inodeNumber(target)
        t.expect(inodeAfterReplace != inode, "테스트 전제: 바꿔치기 저장이어야 함")
        t.expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "테스트 전제: 링크는 그대로")
        probe.expectOneNotification(t, "바꿔치기 뒤 링크 대상 제자리 저장") {
            try writeInPlace("{\"b\": 3}", to: target)
        }
    }

    t.suite("ConfigWatcher: 심볼릭 링크 — 대상이 나중에 생김, 링크를 다른 곳으로") {
        let root = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: root) }
        let (link, target) = try makeLinkedConfig(in: root)
        try fileManager.removeItem(at: target)

        // 대상이 없는 링크: 대상 폴더를 지켜보고 있어야만 알 수 있다.
        let probe = WatchProbe(file: link)
        probe.expectOneNotification(t, "없던 링크 대상이 생김") {
            try Data("{\"b\": 1}".utf8).write(to: target)
        }

        // 링크를 다른 폴더의 파일로 바꾸면 그 폴더와 파일을 새로 지켜본다.
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let other = elsewhere.appendingPathComponent("other.json")
        try Data("{\"c\": 1}".utf8).write(to: other)
        probe.expectOneNotification(t, "링크가 가리키는 곳이 바뀜") {
            // 새 링크를 만든 뒤 rename으로 한 번에 바꾼다(dotfiles 관리 도구가 흔히 하는 방식).
            let replacement = link.deletingLastPathComponent().appendingPathComponent("config.json.new")
            try fileManager.createSymbolicLink(atPath: replacement.path, withDestinationPath: other.path)
            guard rename(replacement.path, link.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        probe.expectOneNotification(t, "새 대상의 바꿔치기 저장") {
            try Data("{\"c\": 2}".utf8).write(to: other, options: .atomic)
        }
    }

    t.suite("ConfigWatcher + AppConfig.load: 파일을 지우면 기본값을 한 번만 반영") {
        let directory = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        var custom = AppConfig()
        custom.capture.sound = false
        try custom.save(to: file)

        // 앱의 reloadConfig와 같은 순서: 알림 → 읽기(없으면 기본값을 써 둠) → 다르면 반영하고 토스트.
        let state = ReloadState(current: try AppConfig.load(from: file))
        let watcher = ConfigWatcher(file: file, delay: 0.05) {
            state.notifications += 1
            guard let loaded = try? AppConfig.load(from: file), loaded != state.current else { return }
            state.current = loaded
            state.applied += 1
        }
        try fileManager.removeItem(at: file)
        let arrived = pumpRunLoop(timeout: 3) { state.notifications >= 2 }
        t.expect(arrived, "지우기와 기본값 쓰기 알림이 3초 안에 오지 않음 (받은 알림 \(state.notifications)번)")
        // 기본값을 써 둔 것이 또 다른 알림을 부르며 돌지 않는지 조금 더 지켜본다.
        pumpRunLoop(timeout: 0.4) { false }
        t.expectEqual(state.notifications, 2, "지우기 1번 + 기본값 쓰기 1번")
        t.expectEqual(state.applied, 1, "반영(토스트)은 한 번만")
        t.expectEqual(state.current, AppConfig())
        t.expect(fileManager.fileExists(atPath: file.path), "기본 설정 파일이 다시 만들어져야 함")
        withExtendedLifetime(watcher) {}
    }

    t.suite("AppConfig: 대상이 없는 링크는 기본값으로 덮어쓰지 않음") {
        let root = makeTemporaryDirectory("macb-watch")
        defer { try? fileManager.removeItem(at: root) }
        let (link, target) = try makeLinkedConfig(in: root)
        try fileManager.removeItem(at: target)

        // 기본값을 돌려주면 그대로 반영되어 켜 둔 기능이 꺼지므로, 읽을 수 없는 설정으로 다룬다.
        var missing: String?
        do {
            _ = try AppConfig.load(from: link)
        } catch ConfigFileError.missingLinkTarget(let path) {
            missing = path
        }
        t.expectEqual(missing.map { URL(fileURLWithPath: $0).lastPathComponent }, target.lastPathComponent, "가리키는 파일이 없다고 알려야 함")
        t.expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "링크가 보통 파일로 바뀜")
        t.expect(!fileManager.fileExists(atPath: target.path), "대상 파일을 만들면 안 됨")
    }
}

/// 감시기 하나와 알림 횟수.
@MainActor
private final class WatchProbe {
    private final class Counter {
        var value = 0
    }

    private let counter = Counter()
    private var watcher: ConfigWatcher?

    /// 테스트가 빨리 끝나도록 모으는 시간을 짧게 둔다.
    init(file: URL) {
        let counter = self.counter
        watcher = ConfigWatcher(file: file, delay: 0.05) { counter.value += 1 }
    }

    /// `change` 뒤에 알림이 정확히 한 번 오는지 본다. 안 오면 제한 시간 뒤 실패로 넘어간다(멈추지 않는다).
    func expectOneNotification(_ t: TestRunner, _ label: String,
                               file: StaticString = #fileID, line: UInt = #line,
                               _ change: () throws -> Void) {
        let before = counter.value
        do {
            try change()
        } catch {
            t.expect(false, "\(label): 파일을 바꾸지 못함 \(error)", file: file, line: line)
            return
        }
        let timeout: TimeInterval = 3
        let arrived = pumpRunLoop(timeout: timeout) { self.counter.value > before }
        t.expect(arrived, "\(label): \(Int(timeout))초 안에 변경 알림이 오지 않음", file: file, line: line)
        guard arrived else { return }
        // 저장 한 번에 알림이 두 번 오지 않는지 조금 더 지켜본다.
        pumpRunLoop(timeout: 0.3) { false }
        t.expectEqual(counter.value, before + 1, "\(label): 알림 횟수", file: file, line: line)
    }

    /// 한동안 알림이 오지 않으면 true.
    func staysQuiet() -> Bool {
        let before = counter.value
        pumpRunLoop(timeout: 0.3) { false }
        return counter.value == before
    }
}

@MainActor
private final class ReloadState {
    var current: AppConfig
    var notifications = 0
    var applied = 0

    init(current: AppConfig) {
        self.current = current
    }
}

/// 조건이 맞을 때까지 메인 런루프를 돌린다. `timeout`이 지나면 false.
@MainActor
@discardableResult
private func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        let now = Date()
        if now >= deadline { return false }
        RunLoop.main.run(mode: .default, before: min(deadline, now.addingTimeInterval(0.02)))
    }
    return true
}

/// dotfiles 저장소처럼, 설정 폴더의 `config.json`이 다른 폴더의 실제 파일을 가리키게 만든다.
private func makeLinkedConfig(in root: URL) throws -> (link: URL, target: URL) {
    let support = root.appendingPathComponent("support", isDirectory: true)
    let dotfiles = root.appendingPathComponent("dotfiles", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let target = dotfiles.appendingPathComponent("macb.json")
    try Data("{\"b\": 1}".utf8).write(to: target)
    let link = support.appendingPathComponent("config.json")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    return (link, target)
}

/// 같은 파일(같은 inode)에 내용을 덮어쓴다. 바꿔치기하지 않는 편집기를 흉내 낸다.
private func writeInPlace(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(text.utf8))
}

private func inodeNumber(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}
