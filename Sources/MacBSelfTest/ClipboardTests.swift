import AppKit
import MacBClipboard
import MacBKit

/// 클립보드 모듈 테스트. 사용자의 실제 클립보드(`NSPasteboard.general`)는 절대 건드리지 않는다.
/// 모든 테스트는 고유 이름의 페이스트보드와 임시 폴더만 쓰고, 창·토스트·키 입력이 생기는 경로는 부르지 않는다.
@MainActor
func runClipboardTests(_ t: TestRunner) {
    t.suite("클립보드: 텍스트 복사 → 기록") {
        try withClipboard { feature, pasteboard, _ in
            t.expectEqual(feature.historyCount, 0)
            t.expect(!feature.checkPasteboardNow(), "바뀐 게 없으면 기록하지 않음")

            put("안녕하세요, hello", on: pasteboard)
            t.expect(feature.checkPasteboardNow())
            t.expect(!feature.checkPasteboardNow(), "같은 변경은 한 번만 기록")
            t.expectEqual(feature.historyCount, 1)

            let item = feature.historyItems.first
            t.expectEqual(item?.kind, .text)
            t.expectEqual(item?.text, "안녕하세요, hello")
            t.expectEqual(item?.sourceApp?.name, "테스트 앱")
            t.expectEqual(item?.sourceApp?.bundleID, testSourceBundleID)
            t.expect(abs(item?.date.timeIntervalSinceNow ?? 99) < 5, "기록 시각")
        }
    }

    t.suite("클립보드: 빈 내용은 기록하지 않음") {
        try withClipboard { feature, pasteboard, _ in
            pasteboard.clearContents()
            t.expect(!feature.checkPasteboardNow(), "비운 페이스트보드")
            put("  \n\t ", on: pasteboard)
            t.expect(!feature.checkPasteboardNow(), "공백만")
            pasteboard.clearContents()
            pasteboard.setData(Data("x".utf8), forType: NSPasteboard.PasteboardType("com.example.private-type"))
            t.expect(!feature.checkPasteboardNow(), "저장하지 않는 타입만")
            t.expectEqual(feature.historyCount, 0)
        }
    }

    t.suite("클립보드: 서식 있는 내용이 그대로 복원됨") {
        try withClipboard { feature, pasteboard, _ in
            let rtf = Data(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\b Bold\b0  plain}"#.utf8)
            let html = Data("<b>Bold</b> plain".utf8)
            let source = NSPasteboardItem()
            source.setData(rtf, forType: .rtf)
            source.setData(html, forType: .html)
            source.setString("Bold plain", forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([source])

            t.expect(feature.checkPasteboardNow())
            guard let item = feature.historyItems.first else {
                t.expect(false, "기록이 없음")
                return
            }
            t.expectEqual(item.kind, .text)
            t.expectEqual(item.text, "Bold plain")

            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            t.expect(feature.writeHistoryItem(item.id, to: target))
            let restored = target.pasteboardItems ?? []
            t.expectEqual(restored.count, 1)
            // 페이스트보드 서버가 타입 순서를 정리하고 파생 타입을 덧붙이므로, 원본이 보고한 순서와 비교한다.
            let kept: Set<NSPasteboard.PasteboardType> = [.rtf, .html, .string]
            let sourceTypes = pasteboard.pasteboardItems?.first?.types.filter { kept.contains($0) }
            t.expectEqual(sourceTypes.map(Set.init), kept, "준비: 원본에 세 타입이 모두 있음")
            t.expectEqual(restored.first?.types.filter { kept.contains($0) }, sourceTypes, "타입과 순서")
            t.expectEqual(restored.first?.data(forType: .rtf), rtf)
            t.expectEqual(restored.first?.data(forType: .html), html)
            t.expectEqual(restored.first?.string(forType: .string), "Bold plain")
        }
    }

    t.suite("클립보드: 이미지·파일 분류") {
        try withClipboard { feature, pasteboard, directory in
            guard let png = makePNG(width: 40, height: 30) else {
                t.expect(false, "PNG를 만들지 못함")
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            t.expect(feature.checkPasteboardNow())
            let image = feature.historyItems.first
            t.expectEqual(image?.kind, .image)
            t.expectEqual(image?.imagePixelSize, CGSize(width: 40, height: 30))
            t.expectEqual(image?.text, "")

            let fileA = directory.appendingPathComponent("보고서 초안.txt")
            let fileB = directory.appendingPathComponent("photo.png")
            try Data("a".utf8).write(to: fileA)
            try Data("b".utf8).write(to: fileB)
            pasteboard.clearContents()
            pasteboard.writeObjects([fileA as NSURL, fileB as NSURL])
            t.expect(feature.checkPasteboardNow())
            let files = feature.historyItems.first
            t.expectEqual(files?.kind, .files)
            t.expectEqual(files?.fileNames, ["보고서 초안.txt", "photo.png"])

            // 여러 항목(파일 둘)도 그대로 되살아난다.
            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            t.expect(feature.writeHistoryItem(files?.id ?? UUID(), to: target))
            let urls = target.readObjects(forClasses: [NSURL.self]) as? [URL]
            t.expectEqual(urls?.map(\.lastPathComponent), ["보고서 초안.txt", "photo.png"])
        }
    }

    t.suite("클립보드: 같은 내용은 맨 위로 올라감") {
        try withClipboard { feature, pasteboard, directory in
            for text in ["A", "B", "A"] {
                put(text, on: pasteboard)
                t.expect(feature.checkPasteboardNow(), text)
            }
            t.expectEqual(feature.historyItems.map(\.text), ["A", "B"])
            feature.waitForPendingWrites()
            t.expectEqual(blobCount(in: directory), 2, "밀려난 옛 항목의 내용 파일은 지워짐")
        }
    }

    t.suite("클립보드: 최대 개수와 내용 파일 정리") {
        var config = AppConfig.Clipboard()
        config.maxItems = 3
        try withClipboard(config) { feature, pasteboard, directory in
            for index in 1...5 {
                put("항목 \(index)", on: pasteboard)
                feature.checkPasteboardNow()
            }
            t.expectEqual(feature.historyItems.map(\.text), ["항목 5", "항목 4", "항목 3"])
            feature.waitForPendingWrites()
            t.expectEqual(blobCount(in: directory), 3)

            feature.removeHistoryItem(feature.historyItems[1].id)
            t.expectEqual(feature.historyItems.map(\.text), ["항목 5", "항목 3"])
            feature.waitForPendingWrites()
            t.expectEqual(blobCount(in: directory), 2, "지운 항목의 파일")

            var smaller = config
            smaller.maxItems = 1
            feature.apply(config: smaller)
            t.expectEqual(feature.historyItems.map(\.text), ["항목 5"], "설정으로 줄이면 바로 잘림")
            feature.waitForPendingWrites()
            t.expectEqual(blobCount(in: directory), 1)

            feature.clearHistory()
            t.expectEqual(feature.historyCount, 0)
            feature.waitForPendingWrites()
            t.expectEqual(blobCount(in: directory), 0)
        }
    }

    t.suite("클립보드: 너무 큰 항목") {
        try withClipboard { feature, pasteboard, _ in
            guard let png = makePNG(width: 8, height: 8) else {
                t.expect(false, "PNG를 만들지 못함")
                return
            }
            let hugeTIFF = Data(count: 17 * 1024 * 1024)
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(hugeTIFF, forType: .tiff)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            t.expect(feature.checkPasteboardNow(), "PNG가 있으면 거대한 TIFF만 버리고 기록")
            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            t.expect(feature.writeHistoryItem(feature.historyItems.first?.id ?? UUID(), to: target))
            t.expectEqual(target.pasteboardItems?.first?.data(forType: .png), png)
            t.expect(target.pasteboardItems?.first?.data(forType: .tiff) == nil, "TIFF는 저장하지 않음")

            pasteboard.clearContents()
            pasteboard.setData(Data(count: 17 * 1024 * 1024), forType: .html)
            t.expect(!feature.checkPasteboardNow(), "대신할 표현이 없으면 건너뜀")
            t.expectEqual(feature.historyCount, 1)
        }
    }

    t.suite("클립보드: 암호 등 숨김 표시는 기록하지 않음") {
        try withClipboard { feature, pasteboard, _ in
            let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
            for marker in markers {
                let item = NSPasteboardItem()
                item.setString("hunter2-비밀", forType: .string)
                item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
                pasteboard.clearContents()
                pasteboard.writeObjects([item])
                t.expect(!feature.checkPasteboardNow(), marker)
                t.expect(!feature.storeCurrentPasteboard(inSlot: 1), "\(marker): 슬롯에도 넣지 않음")
            }
            t.expectEqual(feature.historyCount, 0)
            t.expect(feature.slotItem(1) == nil)
        }
    }

    t.suite("클립보드: ignoreApps") {
        var config = AppConfig.Clipboard()
        config.ignoreApps = ["com.example.Secret"]
        try withClipboard(config) { feature, pasteboard, _ in
            feature.frontmostAppProvider = { ClipboardFeature.SourceApp(name: "Secret", bundleID: "com.example.secret") }
            put("무시될 내용", on: pasteboard)
            t.expect(!feature.checkPasteboardNow(), "앞 앱이 무시 목록(대소문자 무시)")

            feature.frontmostAppProvider = { ClipboardFeature.SourceApp(name: "메모", bundleID: "com.apple.Notes") }
            let declared = NSPasteboardItem()
            declared.setString("출처를 밝힌 내용", forType: .string)
            declared.setString("com.example.Secret", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
            pasteboard.clearContents()
            pasteboard.writeObjects([declared])
            t.expect(!feature.checkPasteboardNow(), "org.nspasteboard.source가 무시 목록")

            put("기록될 내용", on: pasteboard)
            t.expect(feature.checkPasteboardNow())
            t.expectEqual(feature.historyItems.map(\.text), ["기록될 내용"])
            t.expectEqual(feature.historyItems.first?.sourceApp?.name, "메모")
        }
    }

    t.suite("클립보드: 꺼져 있으면 기록하지 않음(슬롯은 동작)") {
        var config = AppConfig.Clipboard()
        config.enabled = false
        try withClipboard(config) { feature, pasteboard, _ in
            put("꺼진 동안", on: pasteboard)
            t.expect(!feature.checkPasteboardNow())
            t.expectEqual(feature.historyCount, 0)
            t.expect(feature.storeCurrentPasteboard(inSlot: 2))
            t.expectEqual(feature.slotItem(2)?.text, "꺼진 동안")

            config.enabled = true
            feature.apply(config: config)
            t.expect(!feature.checkPasteboardNow(), "꺼진 동안 복사한 것은 켠 뒤에도 기록하지 않음")
            put("켠 뒤", on: pasteboard)
            t.expect(feature.checkPasteboardNow())
            t.expectEqual(feature.historyItems.map(\.text), ["켠 뒤"])
        }
    }

    t.suite("클립보드: 재시작 후에도 기록 유지") {
        let directory = makeTemporaryDirectory("macb-clipboard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rtf = Data(#"{\rtf1\ansi{\fonttbl{\f0 Helvetica;}}\f0\i Italic\i0}"#.utf8)

        try withClipboard(directory: directory) { feature, pasteboard, _ in
            put("첫째", on: pasteboard)
            feature.checkPasteboardNow()
            let item = NSPasteboardItem()
            item.setData(rtf, forType: .rtf)
            item.setString("Italic", forType: .string)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            feature.checkPasteboardNow()
            put("셋째", on: pasteboard)
            feature.checkPasteboardNow()
        }

        try withClipboard(directory: directory) { feature, _, _ in
            t.expectEqual(feature.historyItems.map(\.text), ["셋째", "Italic", "첫째"])
            t.expectEqual(feature.historyItems.first?.sourceApp?.name, "테스트 앱")
            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            t.expect(feature.writeHistoryItem(feature.historyItems[1].id, to: target))
            t.expectEqual(target.pasteboardItems?.first?.data(forType: .rtf), rtf, "디스크에서 읽은 RTF")
            t.expectEqual(target.string(forType: .string), "Italic")
        }

        // 클립보드 내용이므로 본인만 읽을 수 있어야 한다.
        t.expectEqual(permissions(of: directory), 0o700)
        t.expectEqual(permissions(of: directory.appendingPathComponent("blobs")), 0o700)
        t.expectEqual(permissions(of: directory.appendingPathComponent("history.plist")), 0o600)
        let blobs = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)) ?? []
        t.expect(!blobs.isEmpty)
        for blob in blobs {
            t.expectEqual(permissions(of: blob), 0o600, blob.lastPathComponent)
        }
    }

    t.suite("클립보드: persist=false면 기록 파일을 남기지 않음") {
        let directory = makeTemporaryDirectory("macb-clipboard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyFile = directory.appendingPathComponent("history.plist")

        try withClipboard(directory: directory) { feature, pasteboard, _ in
            put("디스크에 남았던 기록", on: pasteboard)
            feature.checkPasteboardNow()
            t.expect(feature.storeCurrentPasteboard(inSlot: 4))
        }
        t.expect(FileManager.default.fileExists(atPath: historyFile.path), "준비: 저장된 기록")

        var memoryOnly = AppConfig.Clipboard()
        memoryOnly.persist = false
        try withClipboard(memoryOnly, directory: directory) { feature, pasteboard, _ in
            t.expectEqual(feature.historyCount, 0, "예전 기록은 지움")
            feature.waitForPendingWrites()
            t.expect(!FileManager.default.fileExists(atPath: historyFile.path), "기록 색인 삭제")
            t.expectEqual(blobCount(in: directory), 1, "슬롯 내용만 남음")

            put("메모리에만", on: pasteboard)
            t.expect(feature.checkPasteboardNow())
            t.expectEqual(feature.historyCount, 1)
            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            t.expect(feature.writeHistoryItem(feature.historyItems[0].id, to: target), "메모리의 내용으로 복원")
            t.expectEqual(target.string(forType: .string), "메모리에만")
            feature.waitForPendingWrites()
            t.expect(!FileManager.default.fileExists(atPath: historyFile.path))
            t.expectEqual(blobCount(in: directory), 1)
            t.expectEqual(feature.slotItem(4)?.text, "디스크에 남았던 기록", "슬롯은 항상 저장")

            // 실행 중에 저장을 켰다 끄는 경우.
            var persistent = memoryOnly
            persistent.persist = true
            feature.apply(config: persistent)
            feature.waitForPendingWrites()
            t.expect(FileManager.default.fileExists(atPath: historyFile.path), "켜면 저장")
            t.expectEqual(blobCount(in: directory), 2)
            feature.apply(config: memoryOnly)
            t.expectEqual(feature.historyItems.map(\.text), ["메모리에만"], "끄면 이번 실행 동안은 메모리에 유지")
            feature.waitForPendingWrites()
            t.expect(!FileManager.default.fileExists(atPath: historyFile.path), "끄면 파일 삭제")
            t.expectEqual(blobCount(in: directory), 1)
        }
    }

    t.suite("클립보드: 슬롯 저장·비우기·유지") {
        let directory = makeTemporaryDirectory("macb-clipboard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = NSPasteboard.withUniqueName()
        defer { target.releaseGlobally() }

        try withClipboard(directory: directory) { feature, pasteboard, _ in
            put("슬롯에 넣을 글", on: pasteboard)
            feature.checkPasteboardNow()
            let historyID = feature.historyItems[0].id
            t.expect(feature.storeHistoryItem(historyID, inSlot: 3))
            t.expectEqual(feature.slotItem(3)?.text, "슬롯에 넣을 글")
            t.expect(feature.slotItem(3)?.id != historyID, "슬롯은 별도 사본")

            feature.removeHistoryItem(historyID)
            t.expectEqual(feature.slotItem(3)?.text, "슬롯에 넣을 글", "기록에서 지워도 슬롯은 남음")
            t.expect(feature.writeSlot(3, to: target))
            t.expectEqual(target.string(forType: .string), "슬롯에 넣을 글")

            feature.clearSlot(3)
            t.expect(feature.slotItem(3) == nil)
            t.expect(!feature.writeSlot(3, to: target), "빈 슬롯")

            put("다섯", on: pasteboard)
            t.expect(feature.storeCurrentPasteboard(inSlot: 5))
            put("다섯 바꿈", on: pasteboard)
            t.expect(feature.storeCurrentPasteboard(inSlot: 5), "덮어쓰기")
            t.expect(feature.storeCurrentPasteboard(inSlot: 9))
            pasteboard.clearContents()
            t.expect(!feature.storeCurrentPasteboard(inSlot: 6), "빈 클립보드는 슬롯에 넣지 않음")
            feature.waitForPendingWrites()
            // 기록: "다섯"·"다섯 바꿈"은 checkPasteboardNow를 안 불렀으니 없다. 남는 것은 슬롯 5, 9.
            t.expectEqual(blobCount(in: directory), 2, "덮어쓴 슬롯의 옛 파일은 지움")
        }

        try withClipboard(directory: directory) { feature, _, _ in
            t.expectEqual(feature.slotItem(5)?.text, "다섯 바꿈")
            t.expectEqual(feature.slotItem(9)?.text, "다섯 바꿈")
            t.expect(feature.slotItem(3) == nil)
            t.expect(feature.writeSlot(5, to: target))
            t.expectEqual(target.string(forType: .string), "다섯 바꿈", "디스크에서 읽은 슬롯")
        }
    }

    t.suite("클립보드: 연속 슬롯 붙여넣기는 요청 순서대로") {
        try withClipboard { feature, pasteboard, _ in
            fillSlots(feature, pasteboard, ["하나", "둘", "셋"])
            put("붙여넣기 전", on: pasteboard)

            // 실제 키 입력 대신, ⌘V가 나가는 순간의 클립보드 내용을 적어 둔다.
            var observed: [String?] = []
            feature.canSendKeystrokes = { true }
            feature.modifierKeysDown = { false }
            feature.pasteKeystroke = { observed.append(pasteboard.string(forType: .string)) }

            feature.pasteSlot(1)
            feature.pasteSlot(2)
            feature.pasteSlot(3)
            t.expect(observed.isEmpty, "키 입력은 단축키 처리 안에서 바로 나가지 않음")
            pumpMainRunLoop(timeout: 5) { observed.count >= 3 }
            pumpMainRunLoop(timeout: 0.4)
            t.expectEqual(observed, ["하나", "둘", "셋"], "각 ⌘V 순간에 자기 슬롯 내용이 클립보드에 있어야 함")
            t.expectEqual(pasteboard.string(forType: .string), "셋", "마지막 요청이 클립보드에 남음")
            t.expectEqual(feature.historyItems.map(\.text), ["셋", "둘", "하나"], "붙여넣은 슬롯도 실제로 쓴 순서대로 기록")
            t.expect(!feature.checkPasteboardNow(), "우리가 쓴 변경은 감시가 다시 기록하지 않음")
        }
    }

    t.suite("클립보드: 보조키를 누른 채 연타하면 처음 한 번만 기다림") {
        try withClipboard { feature, pasteboard, _ in
            fillSlots(feature, pasteboard, ["하나", "둘", "셋"])

            var sent: [(text: String?, at: Date)] = []
            var held = true  // ⌥를 누르고 있는 상황
            feature.canSendKeystrokes = { true }
            feature.modifierKeysDown = { held }
            feature.pasteKeystroke = { sent.append((pasteboard.string(forType: .string), Date())) }

            let start = Date()
            feature.pasteSlot(1)
            feature.pasteSlot(2)
            feature.pasteSlot(3)
            pumpMainRunLoop(timeout: 5) { sent.count >= 3 }
            t.expectEqual(sent.map(\.text), ["하나", "둘", "셋"])
            guard sent.count == 3 else { return }

            // 첫 요청은 보조키를 뗄 때까지(최대 0.4초) 기다린다.
            t.expect(sent[0].at.timeIntervalSince(start) >= 0.38, "첫 요청은 보조키 대기")
            for index in 1..<3 {
                let gap = sent[index].at.timeIntervalSince(sent[index - 1].at)
                // 앞 붙여넣기를 앱이 읽을 시간(0.15초)은 두되, 보조키 대기(0.4초)를 다시 하지는 않는다.
                t.expect(gap >= 0.14, "간격 \(index): 정착 시간 \(gap)")
                t.expect(gap < 0.38, "간격 \(index): 보조키를 다시 기다리면 안 됨 \(gap)")
            }

            // ⌥를 뗐다가 다시 누르고 시작한 연타는 처음처럼 기다린다.
            held = false
            pumpMainRunLoop(timeout: 0.3)
            held = true
            let restart = Date()
            feature.pasteSlot(2)
            pumpMainRunLoop(timeout: 5) { sent.count >= 4 }
            t.expectEqual(sent.last?.text, "둘")
            t.expect(sent.count == 4 && sent[3].at.timeIntervalSince(restart) >= 0.38, "새 연타의 첫 요청은 다시 보조키 대기")
            held = false
            pumpMainRunLoop(timeout: 0.2)
        }
    }

    t.suite("클립보드: 범위 밖 슬롯 번호") {
        try withClipboard { feature, pasteboard, _ in
            put("아무 내용", on: pasteboard)
            feature.checkPasteboardNow()
            let id = feature.historyItems[0].id
            let target = NSPasteboard.withUniqueName()
            defer { target.releaseGlobally() }
            for slot in [0, 10, -1, Int.max, Int.min] {
                t.expect(!feature.storeHistoryItem(id, inSlot: slot), "\(slot)")
                t.expect(!feature.storeCurrentPasteboard(inSlot: slot), "\(slot)")
                t.expect(feature.slotItem(slot) == nil, "\(slot)")
                t.expect(!feature.writeSlot(slot, to: target), "\(slot)")
                feature.clearSlot(slot)
                // 범위 검사가 맨 먼저라 토스트·키 입력 없이 끝나야 한다.
                feature.pasteSlot(slot)
                feature.copySelectionToSlot(slot)
            }
            t.expectEqual(ClipboardFeature.slotRange.compactMap { feature.slotItem($0) }.count, 0)
            t.expect(!feature.storeHistoryItem(UUID(), inSlot: 1), "없는 기록 항목")
        }
    }

    t.suite("클립보드: 검색") {
        try withClipboard { feature, pasteboard, directory in
            for text in ["Apple pie recipe", "바나나 우유 2개", "apple JUICE", "그냥 메모"] {
                put(text, on: pasteboard)
                feature.checkPasteboardNow()
            }
            let file = directory.appendingPathComponent("분기 보고서.pdf")
            try Data("x".utf8).write(to: file)
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            feature.checkPasteboardNow()

            @MainActor func texts(_ query: String) -> [String] { feature.historyItems(matching: query).map(\.text) }
            t.expectEqual(texts("apple"), ["apple JUICE", "Apple pie recipe"], "대소문자 무시, 최신순")
            t.expectEqual(texts("APPLE pie"), ["Apple pie recipe"], "낱말 모두 포함")
            t.expectEqual(texts("바나나"), ["바나나 우유 2개"])
            t.expectEqual(texts("ＡＰＰＬＥ"), ["apple JUICE", "Apple pie recipe"], "전각 무시")
            t.expectEqual(texts("보고서"), ["분기 보고서.pdf"], "파일 이름")
            t.expectEqual(texts("없는말"), [])
            t.expectEqual(feature.historyItems(matching: "").count, 5)
            t.expectEqual(feature.historyItems(matching: "   ").count, 5)
        }
    }
}

// MARK: - Helpers

private let testSourceBundleID = "dev.macb.selftest.source"

/// 고유 페이스트보드 + 임시 폴더로 기능 하나를 만들고, 끝나면 쓰기를 마저 끝낸 뒤 치운다.
@MainActor
private func withClipboard(
    _ config: AppConfig.Clipboard = AppConfig.Clipboard(),
    directory: URL? = nil,
    _ body: (ClipboardFeature, NSPasteboard, URL) throws -> Void
) throws {
    let storage = directory ?? makeTemporaryDirectory("macb-clipboard")
    let pasteboard = NSPasteboard.withUniqueName()
    let feature = ClipboardFeature(config: config, storageDirectory: storage, pasteboard: pasteboard)
    feature.frontmostAppProvider = { ClipboardFeature.SourceApp(name: "테스트 앱", bundleID: testSourceBundleID) }
    defer {
        feature.waitForPendingWrites()
        pasteboard.releaseGlobally()
        if directory == nil { try? FileManager.default.removeItem(at: storage) }
    }
    try body(feature, pasteboard, storage)
}

private func put(_ text: String, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// 슬롯 1, 2, 3…에 차례로 글자를 넣는다(기록은 남기지 않는다).
@MainActor
private func fillSlots(_ feature: ClipboardFeature, _ pasteboard: NSPasteboard, _ texts: [String]) {
    for (index, text) in texts.enumerated() {
        put(text, on: pasteboard)
        feature.storeCurrentPasteboard(inSlot: index + 1)
    }
}

/// 메인 런루프를 돌려 예약된 작업(asyncAfter 등)을 실행한다. `done`이 참이 되거나 시간이 다 되면 멈춘다.
@MainActor
private func pumpMainRunLoop(timeout: TimeInterval, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func blobCount(in directory: URL) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path)) ?? []
    return names.filter { $0.hasSuffix(".plist") }.count
}

private func permissions(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

private func makePNG(width: Int, height: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.setColor(NSColor(deviceRed: 0.2, green: 0.6, blue: 0.7, alpha: 1), atX: 0, y: 0)
    return rep.representation(using: .png, properties: [:])
}
