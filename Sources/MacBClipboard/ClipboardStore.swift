import Foundation
import MacBKit

/// 기록과 슬롯을 들고 있고 디스크에 저장한다.
///
/// `directory` 아래 구조:
///
///     history.plist        기록 목록(표시용 정보만). 기록 저장이 꺼져 있으면 없다.
///     slots.plist          슬롯 목록(표시용 정보만). 슬롯은 항상 저장한다.
///     blobs/<UUID>.plist   항목별 실제 내용
///
/// 디스크에 안전하게 쓴 뒤에는 메모리의 내용을 비워, 큰 이미지가 쌓여도 메모리가 늘지 않게 한다.
/// 붙여넣을 때 다시 읽는다.
@MainActor
final class ClipboardStore {
    typealias Item = ClipboardFeature.Item

    struct Entry {
        var item: Item
        /// 메모리에 있는 내용. nil이면 디스크에만 있다.
        var payload: Payload?
    }

    private(set) var history: [Entry] = []
    private(set) var slots: [Int: Entry] = [:]
    private(set) var maxItems: Int
    private(set) var persistsHistory: Bool
    var onChange: (() -> Void)?

    private let disk: ClipboardDisk

    init(directory: URL, maxItems: Int, persistHistory: Bool) {
        disk = ClipboardDisk(root: directory)
        self.maxItems = max(1, maxItems)
        persistsHistory = persistHistory
        disk.prepareDirectories()

        for record in disk.loadSlots()
        where ClipboardFeature.slotRange.contains(record.slot) && disk.hasBlob(record.item.id) {
            slots[record.slot] = Entry(item: record.item, payload: nil)
        }

        if persistHistory {
            var seen = Set<UUID>()
            history = disk.loadHistory()
                .filter { seen.insert($0.id).inserted && disk.hasBlob($0.id) }
                .map { Entry(item: $0, payload: nil) }
            // 지난 실행보다 최대 개수가 줄었을 수 있다. 남는 내용 파일은 아래 정리에서 지워진다.
            if !trimToLimit().isEmpty { saveHistoryIndex() }
        } else {
            disk.deleteHistoryIndex()
        }
        // 지운 항목, 저장이 꺼진 기록, 중간에 죽어 남은 파일 등 아무도 안 쓰는 내용 파일을 치운다.
        disk.sweepBlobs(keeping: referencedBlobIDs)
    }

    private var referencedBlobIDs: Set<UUID> {
        var ids = Set(slots.values.map(\.item.id))
        if persistsHistory { ids.formUnion(history.map(\.item.id)) }
        return ids
    }

    // MARK: History

    /// 맨 위에 넣는다. 같은 내용이 이미 있으면 그것을 빼고 새 것을 올린다(새 서식·출처가 이긴다).
    func insert(_ item: Item, payload: Payload) {
        var removed: [UUID] = []
        if let index = history.firstIndex(where: { $0.item.fingerprint == item.fingerprint }) {
            removed.append(history.remove(at: index).item.id)
        }
        history.insert(Entry(item: item, payload: payload), at: 0)
        removed += trimToLimit()
        if persistsHistory {
            writeBlob(payload, for: item.id)
            disk.deleteBlobs(removed)
            saveHistoryIndex()
        }
        onChange?()
    }

    func moveToTop(_ id: UUID, date: Date) {
        guard let index = history.firstIndex(where: { $0.item.id == id }) else { return }
        var entry = history.remove(at: index)
        entry.item.date = date
        history.insert(entry, at: 0)
        if persistsHistory { saveHistoryIndex() }
        onChange?()
    }

    func remove(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.item.id == id }) else { return }
        history.remove(at: index)
        if persistsHistory {
            disk.deleteBlobs([id])
            saveHistoryIndex()
        }
        onChange?()
    }

    func clearHistory() {
        guard !history.isEmpty else { return }
        let ids = history.map(\.item.id)
        history.removeAll()
        if persistsHistory {
            disk.deleteBlobs(ids)
            saveHistoryIndex()
        }
        onChange?()
    }

    func historyPayload(_ id: UUID) -> Payload? {
        guard let entry = history.first(where: { $0.item.id == id }) else { return nil }
        return entry.payload ?? disk.readBlob(id)
    }

    // MARK: Slots

    func setSlot(_ slot: Int, item: Item, payload: Payload) {
        let previous = slots[slot]?.item.id
        slots[slot] = Entry(item: item, payload: payload)
        writeBlob(payload, for: item.id)
        if let previous { disk.deleteBlobs([previous]) }
        saveSlotsIndex()
        onChange?()
    }

    func clearSlot(_ slot: Int) {
        guard let previous = slots.removeValue(forKey: slot) else { return }
        disk.deleteBlobs([previous.item.id])
        saveSlotsIndex()
        onChange?()
    }

    func slotPayload(_ slot: Int) -> Payload? {
        guard let entry = slots[slot] else { return nil }
        return entry.payload ?? disk.readBlob(entry.item.id)
    }

    // MARK: Settings

    func configure(maxItems newMax: Int, persistHistory newPersist: Bool) {
        let wasPersisting = persistsHistory
        maxItems = max(1, newMax)
        let trimmed = trimToLimit()
        var changed = !trimmed.isEmpty

        if newPersist != wasPersisting {
            changed = true
            if newPersist {
                persistsHistory = true
                for entry in history {
                    if let payload = entry.payload { writeBlob(payload, for: entry.item.id) }
                }
                saveHistoryIndex()
            } else {
                // 이번 실행 동안은 기록을 메모리에 남기고, 디스크의 기록은 지운다.
                for index in history.indices where history[index].payload == nil {
                    history[index].payload = disk.readBlob(history[index].item.id)
                }
                history.removeAll { $0.payload == nil }
                persistsHistory = false
                disk.deleteBlobs(history.map(\.item.id) + trimmed)
                disk.deleteHistoryIndex()
            }
        } else if wasPersisting, !trimmed.isEmpty {
            disk.deleteBlobs(trimmed)
            saveHistoryIndex()
        }
        if changed { onChange?() }
    }

    /// 대기 중인 디스크 작업이 끝날 때까지 기다린다.
    func flush() {
        disk.flush()
    }

    // MARK: Private

    private func trimToLimit() -> [UUID] {
        guard history.count > maxItems else { return [] }
        let removed = history[maxItems...].map(\.item.id)
        history.removeSubrange(maxItems...)
        return removed
    }

    private func writeBlob(_ payload: Payload, for id: UUID) {
        disk.writeBlob(payload, id: id) { [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.blobWritten(id, ok: ok) }
            }
        }
    }

    /// 디스크에 확실히 쓴 뒤에만 메모리의 내용을 비운다. 실패하면 메모리에라도 남겨 둔다.
    private func blobWritten(_ id: UUID, ok: Bool) {
        guard ok else { return }
        if persistsHistory, let index = history.firstIndex(where: { $0.item.id == id }) {
            history[index].payload = nil
        }
        for (slot, entry) in slots where entry.item.id == id {
            slots[slot]?.payload = nil
        }
    }

    private func saveHistoryIndex() {
        disk.writeHistory(history.map(\.item))
    }

    private func saveSlotsIndex() {
        let records = slots.sorted { $0.key < $1.key }.map { SlotRecord(slot: $0.key, item: $0.value.item) }
        disk.writeSlots(records)
    }
}

// MARK: - Disk

struct HistoryIndex: Codable {
    var version = 1
    var items: [ClipboardFeature.Item]
}

struct SlotRecord: Codable, Sendable {
    var slot: Int
    var item: ClipboardFeature.Item
}

struct SlotIndex: Codable {
    var version = 1
    var slots: [SlotRecord]
}

/// 파일 입출력. 모든 작업이 직렬 큐 하나에서 순서대로 돌아서, 쓰기 직후의 읽기·지우기도 순서가 보장된다.
/// 무거운 쓰기는 메인 스레드 밖에서, 읽기는 필요할 때만 동기로 한다.
struct ClipboardDisk: Sendable {
    let root: URL
    let blobsDirectory: URL
    let historyIndex: URL
    let slotsIndex: URL
    private let queue = DispatchQueue(label: "dev.macb.clipboard.disk", qos: .utility)

    init(root: URL) {
        self.root = root
        blobsDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        historyIndex = root.appendingPathComponent("history.plist")
        slotsIndex = root.appendingPathComponent("slots.plist")
    }

    func prepareDirectories() {
        Self.makePrivateDirectory(root)
        Self.makePrivateDirectory(blobsDirectory)
    }

    func blobURL(_ id: UUID) -> URL {
        blobsDirectory.appendingPathComponent(id.uuidString + ".plist")
    }

    func hasBlob(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(id).path)
    }

    func loadHistory() -> [ClipboardFeature.Item] {
        let url = historyIndex
        return queue.sync { Self.read(HistoryIndex.self, from: url)?.items ?? [] }
    }

    func loadSlots() -> [SlotRecord] {
        let url = slotsIndex
        return queue.sync { Self.read(SlotIndex.self, from: url)?.slots ?? [] }
    }

    func writeHistory(_ items: [ClipboardFeature.Item]) {
        let url = historyIndex
        queue.async { Self.write(HistoryIndex(items: items), to: url) }
    }

    func deleteHistoryIndex() {
        let url = historyIndex
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func writeSlots(_ records: [SlotRecord]) {
        let url = slotsIndex
        queue.async { Self.write(SlotIndex(slots: records), to: url) }
    }

    func writeBlob(_ payload: Payload, id: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        let url = blobURL(id)
        queue.async { completion(Self.write(payload, to: url)) }
    }

    func readBlob(_ id: UUID) -> Payload? {
        let url = blobURL(id)
        return queue.sync { Self.read(Payload.self, from: url) }
    }

    func deleteBlobs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let urls = ids.map(blobURL)
        queue.async {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    func sweepBlobs(keeping ids: Set<UUID>) {
        let directory = blobsDirectory
        queue.async {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let stem = (name as NSString).deletingPathExtension
                if name.hasSuffix(".plist"), let id = UUID(uuidString: stem), ids.contains(id) { continue }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    // MARK: Helpers

    /// 클립보드 내용이 들어가므로 본인만 읽을 수 있게(0700) 만든다.
    private static func makePrivateDirectory(_ url: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            Log.error("클립보드 저장 폴더를 만들지 못함: \(error.localizedDescription)")
        }
    }

    /// 원자적으로 쓰고 본인만 읽을 수 있게(0600) 한다. 폴더가 0700이라 잠깐의 기본 권한도 남에게 안 보인다.
    @discardableResult
    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            Log.error("클립보드 파일 저장 실패(\(url.lastPathComponent)): \(error.localizedDescription)")
            return false
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try PropertyListDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            // 내용이 섞일 수 있는 오류 본문은 남기지 않는다.
            Log.error("클립보드 파일을 읽지 못함(\(url.lastPathComponent))")
            return nil
        }
    }
}
