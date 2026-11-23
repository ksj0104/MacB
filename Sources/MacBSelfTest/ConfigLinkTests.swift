import Foundation
import MacBKit

/// config.json이 심볼릭 링크인데 가리키는 파일이나 폴더가 아직 없을 때(dotfiles를 옮기는 중, 로그인 직후 iCloud 등).
@MainActor
func runConfigLinkTests(_ t: TestRunner) {
    let fileManager = FileManager.default

    t.suite("설정 파일: 가리키는 파일이 없는 링크로는 읽지도 쓰지도 않음") {
        let root = makeTemporaryDirectory("macb-dangling")
        defer { try? fileManager.removeItem(at: root) }
        let link = root.appendingPathComponent("config.json")
        let target = root.appendingPathComponent("missing/macb.json")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        t.expectEqual(AppConfig.missingLinkTarget(of: link), target.path)
        var loadError: ConfigFileError?
        do { _ = try AppConfig.load(from: link) } catch let error as ConfigFileError { loadError = error }
        t.expectEqual(loadError, .missingLinkTarget(target.path), "기본값으로 읽으면 켜 둔 기능이 꺼짐")
        t.expect(loadError?.localizedDescription.contains("config.json이 가리키는 파일이 없습니다") == true)

        var config = AppConfig()
        config.keyboard.inputSwitch.enabled = true
        var saveError: ConfigFileError?
        do { try config.save(to: link) } catch let error as ConfigFileError { saveError = error }
        t.expectEqual(saveError, .missingLinkTarget(target.path), "저장도 거절")
        t.expect(!fileManager.fileExists(atPath: target.deletingLastPathComponent().path), "링크를 따라 폴더를 만들면 안 됨")
        t.expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil, "링크는 그대로")

        // 가리키는 파일이 생기면 평소처럼 읽고 쓴다.
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AppConfig().save(to: target)
        t.expect(AppConfig.missingLinkTarget(of: link) == nil)
        try config.save(to: link)
        let loaded = try AppConfig.load(from: link)
        t.expectEqual(loaded, config)

        // 링크가 아닌 파일이 없을 때는 예전처럼 기본값을 써 둔다.
        let plain = root.appendingPathComponent("plain.json")
        t.expect(AppConfig.missingLinkTarget(of: plain) == nil)
        let created = try AppConfig.load(from: plain)
        t.expectEqual(created, AppConfig())
        t.expect(fileManager.fileExists(atPath: plain.path))
    }

    t.suite("설정 감시: 링크가 가리키는 폴더가 나중에 생겨도 알아챔") {
        let root = makeTemporaryDirectory("macb-dangling-watch")
        defer { try? fileManager.removeItem(at: root) }
        let directory = root.appendingPathComponent("home", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("cloud/sub", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("config.json")
        let target = targetDirectory.appendingPathComponent("macb.json")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        var calls = 0
        let watcher = ConfigWatcher(file: link, delay: 0.05) { calls += 1 }
        // 폴더가 두 단계 모두 없는 상태에서 하나씩 생긴다.
        try fileManager.createDirectory(at: targetDirectory.deletingLastPathComponent(), withIntermediateDirectories: false)
        spin(until: Date().addingTimeInterval(0.3)) { false }
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        spin(until: Date().addingTimeInterval(0.3)) { false }
        t.expectEqual(calls, 0, "파일이 생기기 전에는 알리지 않음")
        try Data("{}".utf8).write(to: target)
        spin(until: Date().addingTimeInterval(3)) { calls > 0 }
        withExtendedLifetime(watcher) {}
        t.expectEqual(calls, 1, "파일이 생기면 한 번 알림")
    }

    t.suite("설정 감시: 링크가 가리키는 폴더는 있고 파일이 나중에 생김") {
        let root = makeTemporaryDirectory("macb-dangling-watch2")
        defer { try? fileManager.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        try fileManager.createDirectory(at: other, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("config.json")
        let target = other.appendingPathComponent("macb.json")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        var calls = 0
        let watcher = ConfigWatcher(file: link, delay: 0.05) { calls += 1 }
        try Data("{}".utf8).write(to: target)
        spin(until: Date().addingTimeInterval(3)) { calls > 0 }
        withExtendedLifetime(watcher) {}
        t.expectEqual(calls, 1)
    }
}

/// 조건이 맞거나 시간이 다 될 때까지 메인 런루프를 돌린다(감시기 알림은 메인 큐로 온다).
@MainActor
private func spin(until deadline: Date, _ done: () -> Bool) {
    while !done(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
