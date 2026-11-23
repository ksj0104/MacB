import Foundation

/// 설정 파일이 바뀌면 알려 준다.
///
/// 편집기마다 저장 방식이 달라서 여러 군데를 함께 지켜본다.
/// - 임시 파일을 쓴 뒤 바꿔치기하는 저장 → 폴더에 변화가 생긴다.
/// - 같은 파일에 제자리 덮어쓰는 저장 → 폴더는 그대로고 파일에만 변화가 생긴다.
/// - 설정 파일이 심볼릭 링크면(dotfiles 저장소 등) 실제 파일은 다른 폴더에 있다.
///   링크가 거치는 폴더를 모두 지켜보고, 바뀌었는지는 링크가 아니라 실제 파일을 보고 판단한다.
@MainActor
public final class ConfigWatcher {
    private let file: URL
    private let delay: TimeInterval
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var lastSignature: Signature?
    private var pending: DispatchWorkItem?

    /// - Parameter delay: 저장 한 번에 이벤트가 여러 개 오므로, 마지막 이벤트 뒤 이만큼 기다렸다가 한 번만 확인한다.
    public init(file: URL, delay: TimeInterval = 0.3, onChange: @escaping @MainActor () -> Void) {
        self.file = file
        self.delay = delay
        self.onChange = onChange
        lastSignature = ConfigWatcher.signature(of: file.path)
        watch()
    }

    deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
    }

    /// 지켜볼 대상을 새로 건다. 파일이 바꿔치기되면 예전 파일을 붙들고 있게 되고,
    /// 링크가 가리키는 곳이 바뀌면 지켜볼 폴더도 달라지므로 확인할 때마다 다시 건다.
    private func watch() {
        for source in sources { source.cancel() }
        sources.removeAll()

        let chain = ConfigWatcher.linkChain(from: file.path)
        var directories: [String] = []
        for path in chain {
            // 링크가 가리키는 폴더가 아직 없으면(iCloud에서 내려받는 중 등) 있는 데까지 올라가 지켜본다.
            // 폴더가 생기면 그 알림으로 다시 걸면서 한 단계씩 내려온다.
            var directory = (path as NSString).deletingLastPathComponent
            while !directory.isEmpty, directory != "/", !FileManager.default.fileExists(atPath: directory) {
                directory = (directory as NSString).deletingLastPathComponent
            }
            if !directories.contains(directory) { directories.append(directory) }
        }
        for directory in directories {
            if let source = makeSource(path: directory, events: [.write, .rename, .delete]) {
                sources.append(source)
            }
        }
        // open()은 링크를 따라가므로 실제 파일의 제자리 저장이 잡힌다.
        if let source = makeSource(path: file.path, events: [.write, .extend, .rename, .delete]) {
            sources.append(source)
        }
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func check() {
        // 다시 건 다음에 상태를 읽어야, 그 사이에 생긴 변경이 이벤트든 비교든 둘 중 하나로 반드시 잡힌다.
        watch()
        let current = ConfigWatcher.signature(of: file.path)
        guard current != lastSignature else { return }
        // 알리기 전에 기준을 먼저 옮긴다. 받는 쪽이 파일을 읽는 사이에 또 저장되면 그건 다음 이벤트로 다시 알린다.
        lastSignature = current
        onChange()
    }

    // MARK: File state

    /// 실제 파일(링크를 끝까지 따라간 것)의 상태. 바꿔치기 저장은 inode로, 제자리 저장은 크기·시각으로 알아본다.
    private struct Signature: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: Int
        var modifiedNanoseconds: Int
        var changed: Int
        var changedNanoseconds: Int
    }

    private static func signature(of path: String) -> Signature? {
        var info = stat()
        // stat은 링크를 따라간다(lstat이면 링크 자체만 보게 되어 실제 파일을 고쳐도 모른다).
        guard stat(path, &info) == 0 else { return nil }
        return Signature(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            modified: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changed: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec
        )
    }

    /// `path`에서 시작해 심볼릭 링크를 따라간 경로들. 첫 항목은 `path`, 마지막은 링크가 아닌 곳.
    static func linkChain(from path: String) -> [String] {
        var chain = [path]
        var current = path
        // 순환 링크에서 멈추도록 횟수를 제한한다.
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { break }
            current = destination.hasPrefix("/")
                ? destination
                : ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            chain.append(current)
        }
        return chain
    }
}
