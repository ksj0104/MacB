import Foundation

/// `config.json`의 모델. 빠진 필드는 기본값으로 채워지므로 바꾸고 싶은 것만 적어도 된다.
public struct AppConfig: Codable, Equatable, Sendable {
    public var hotkeys: Hotkeys
    public var radialMenu: RadialMenu
    public var capture: Capture
    public var clipboard: Clipboard
    public var keyboard: Keyboard
    /// 전역 단축키로 바로 실행할 기능 목록.
    public var shortcuts: [Shortcut]

    public init(
        hotkeys: Hotkeys = Hotkeys(),
        radialMenu: RadialMenu = RadialMenu(),
        capture: Capture = Capture(),
        clipboard: Clipboard = Clipboard(),
        keyboard: Keyboard = Keyboard(),
        shortcuts: [Shortcut] = []
    ) {
        self.hotkeys = hotkeys
        self.radialMenu = radialMenu
        self.capture = capture
        self.clipboard = clipboard
        self.keyboard = keyboard
        self.shortcuts = shortcuts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = try container.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? Hotkeys()
        radialMenu = try container.decodeIfPresent(RadialMenu.self, forKey: .radialMenu) ?? RadialMenu()
        capture = try container.decodeIfPresent(Capture.self, forKey: .capture) ?? Capture()
        clipboard = try container.decodeIfPresent(Clipboard.self, forKey: .clipboard) ?? Clipboard()
        keyboard = try container.decodeIfPresent(Keyboard.self, forKey: .keyboard) ?? Keyboard()
        shortcuts = try container.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
    }

    // MARK: Sections

    public struct Hotkeys: Codable, Equatable, Sendable {
        /// 원형 메뉴. 누르고 있다가 떼면 가리킨 항목 실행, 짧게 누르면 열어 둔 채 클릭으로 선택.
        public var radialMenu: String
        /// 클립보드 기록 패널.
        public var clipboardHistory: String
        /// 이 보조키 + 숫자(1–9) = 슬롯 붙여넣기.
        public var slotPasteModifiers: String
        /// 이 보조키 + 숫자(1–9) = 선택 영역을 슬롯에 복사.
        public var slotCopyModifiers: String

        public init(
            radialMenu: String = "option+tab",
            clipboardHistory: String = "option+v",
            slotPasteModifiers: String = "option",
            slotCopyModifiers: String = "control+option"
        ) {
            self.radialMenu = radialMenu
            self.clipboardHistory = clipboardHistory
            self.slotPasteModifiers = slotPasteModifiers
            self.slotCopyModifiers = slotCopyModifiers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Hotkeys()
            radialMenu = try container.decodeIfPresent(String.self, forKey: .radialMenu) ?? defaults.radialMenu
            clipboardHistory = try container.decodeIfPresent(String.self, forKey: .clipboardHistory) ?? defaults.clipboardHistory
            slotPasteModifiers = try container.decodeIfPresent(String.self, forKey: .slotPasteModifiers) ?? defaults.slotPasteModifiers
            slotCopyModifiers = try container.decodeIfPresent(String.self, forKey: .slotCopyModifiers) ?? defaults.slotCopyModifiers
        }
    }

    public struct RadialMenu: Codable, Equatable, Sendable {
        /// 12시 방향부터 시계 방향 순서.
        public var items: [Item]

        public init(items: [Item] = RadialMenu.defaultItems) {
            self.items = items
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decodeIfPresent([Item].self, forKey: .items) ?? RadialMenu.defaultItems
        }

        public static let defaultItems: [Item] = [
            Item(action: "capture.area.clipboard"),
            Item(action: "capture.window.clipboard"),
            Item(action: "clipboard.history"),
            Item(action: "capture.color"),
            Item(action: "capture.ocr"),
            Item(action: "capture.record"),
            Item(action: "capture.area.file"),
            Item(action: "capture.screen.clipboard"),
        ]

        /// 메뉴 항목 하나. `action`(내장 기능) 또는 `shell` / `app` / `url` / `shortcut` 중 하나를 지정한다.
        public struct Item: Codable, Equatable, Sendable {
            /// 내장 기능 ID (예: `capture.area.clipboard`).
            public var action: String?
            /// 표시 이름. 내장 기능은 생략하면 기본 이름을 쓴다.
            public var title: String?
            public var subtitle: String?
            /// SF Symbols 이름 또는 이모지.
            public var icon: String?
            /// 셸 명령(`/bin/zsh -lc`).
            public var shell: String?
            /// 실행할 앱: 이름, 번들 ID, 또는 `.app` 경로.
            public var app: String?
            /// 열 URL.
            public var url: String?
            /// 실행할 '단축어' 앱의 단축어 이름.
            public var shortcut: String?

            public init(
                action: String? = nil,
                title: String? = nil,
                subtitle: String? = nil,
                icon: String? = nil,
                shell: String? = nil,
                app: String? = nil,
                url: String? = nil,
                shortcut: String? = nil
            ) {
                self.action = action
                self.title = title
                self.subtitle = subtitle
                self.icon = icon
                self.shell = shell
                self.app = app
                self.url = url
                self.shortcut = shortcut
            }
        }
    }

    public struct Capture: Codable, Equatable, Sendable {
        /// 파일 저장 위치. 비우면 시스템 스크린샷 저장 위치(기본은 데스크탑).
        public var saveDirectory: String
        /// 찰칵 소리.
        public var sound: Bool
        /// 창 캡처에 그림자 포함.
        public var windowShadow: Bool
        /// 글자 인식 언어(우선순위 순).
        public var ocrLanguages: [String]

        public init(
            saveDirectory: String = "",
            sound: Bool = true,
            windowShadow: Bool = true,
            ocrLanguages: [String] = ["ko-KR", "en-US"]
        ) {
            self.saveDirectory = saveDirectory
            self.sound = sound
            self.windowShadow = windowShadow
            self.ocrLanguages = ocrLanguages
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Capture()
            saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? defaults.saveDirectory
            sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? defaults.sound
            windowShadow = try container.decodeIfPresent(Bool.self, forKey: .windowShadow) ?? defaults.windowShadow
            ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages) ?? defaults.ocrLanguages
        }
    }

    public struct Clipboard: Codable, Equatable, Sendable {
        /// 클립보드 기록 수집 여부.
        public var enabled: Bool
        /// 기록 최대 개수.
        public var maxItems: Int
        /// 기록을 디스크에 저장해 재시작 후에도 유지.
        public var persist: Bool
        /// 이 번들 ID의 앱에서 복사한 내용은 기록하지 않는다.
        public var ignoreApps: [String]

        public init(
            enabled: Bool = true,
            maxItems: Int = 100,
            persist: Bool = true,
            ignoreApps: [String] = []
        ) {
            self.enabled = enabled
            self.maxItems = maxItems
            self.persist = persist
            self.ignoreApps = ignoreApps
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Clipboard()
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? defaults.maxItems
            persist = try container.decodeIfPresent(Bool.self, forKey: .persist) ?? defaults.persist
            ignoreApps = try container.decodeIfPresent([String].self, forKey: .ignoreApps) ?? defaults.ignoreApps
        }
    }

    public struct Keyboard: Codable, Equatable, Sendable {
        public var inputSwitch: InputSwitch

        public init(inputSwitch: InputSwitch = InputSwitch()) {
            self.inputSwitch = inputSwitch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputSwitch = try container.decodeIfPresent(InputSwitch.self, forKey: .inputSwitch) ?? InputSwitch()
        }

        /// 한/영 전환 키. 켜 두면 MacB가 시작할 때마다 다시 적용하고, 끄면 원래대로 되돌린다.
        /// 기본은 꺼짐 — 처음 설치한 MacB가 시스템 설정을 건드리는 일은 없다.
        public struct InputSwitch: Codable, Equatable, Sendable {
            public var enabled: Bool
            /// `"right_command"`, `"right_option"`, 또는 `"shift+space"` 같은 단축키.
            public var key: String

            public init(enabled: Bool = false, key: String = "right_command") {
                self.enabled = enabled
                self.key = key
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let defaults = InputSwitch()
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
                key = try container.decodeIfPresent(String.self, forKey: .key) ?? defaults.key
            }
        }
    }

    /// 전역 단축키 하나와 그 단축키로 실행할 기능. 원형 메뉴 항목과 같은 필드에 `key`를 더해 한 단계로 적는다:
    /// `{ "key": "control+option+t", "app": "Terminal" }`.
    public struct Shortcut: Codable, Equatable, Sendable {
        /// 단축키. 빈 문자열이면 목록에만 남고 등록하지 않는다.
        public var key: String
        public var item: RadialMenu.Item

        public init(key: String, item: RadialMenu.Item) {
            self.key = key
            self.item = item
        }

        private enum CodingKeys: String, CodingKey {
            case key
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
            item = try RadialMenu.Item(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            // 항목의 필드와 `key`를 같은 JSON 객체에 쓴다.
            try item.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
        }
    }
}

// MARK: - File I/O

public extension AppConfig {
    static func decode(_ data: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// 파일이 없으면 기본 설정을 써 두고 그것을 돌려준다. 형식이 틀리면 throw.
    ///
    /// 심볼릭 링크인데 가리키는 파일이 없으면(dotfiles 저장소를 옮기는 중, 로그인 직후 iCloud 파일이 아직 없음 등)
    /// `ConfigFileError.missingLinkTarget`을 던진다. 기본값을 돌려주면 그대로 반영되어 사용자가 켜 둔 기능(한영 전환 키 등)이
    /// 꺼져 버리고, 기본값을 써 두면 링크를 따라 엉뚱한 곳에 파일이 생긴다.
    static func load(from url: URL) throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let missing = missingLinkTarget(of: url) { throw ConfigFileError.missingLinkTarget(missing) }
            let config = AppConfig()
            try? config.save(to: url)
            return config
        }
        return try decode(Data(contentsOf: url))
    }

    /// 심볼릭 링크면 링크가 가리키는 실제 파일에 쓴다. 링크 자리에 바로 쓰면(바꿔치기 저장) 링크가 보통 파일로 바뀐다.
    /// 링크가 가리키는 파일이 없으면 만들지 않고 `ConfigFileError.missingLinkTarget`을 던진다.
    func save(to url: URL) throws {
        if let missing = Self.missingLinkTarget(of: url) { throw ConfigFileError.missingLinkTarget(missing) }
        let target = Self.resolvingLinks(url)
        AppPaths.ensureDirectory(target.deletingLastPathComponent())
        try encoded().write(to: target, options: .atomic)
    }

    /// `url`이 심볼릭 링크인데 링크를 끝까지 따라간 곳에 파일이 없으면 그 경로. 링크가 아니면 nil.
    static func missingLinkTarget(of url: URL) -> String? {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
        let target = resolvingLinks(url)
        return FileManager.default.fileExists(atPath: target.path) ? nil : target.path
    }

    /// 심볼릭 링크를 끝까지 따라간 경로(상대 경로 링크 포함). 순환 링크에서 멈추도록 횟수를 제한한다.
    private static func resolvingLinks(_ url: URL) -> URL {
        var target = url
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { break }
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).standardizedFileURL
        }
        return target
    }
}

/// config.json을 읽거나 쓸 수 없는 이유(내용의 형식 오류 말고).
public enum ConfigFileError: Error, LocalizedError, Equatable {
    /// 심볼릭 링크인데 가리키는 파일이 없다. 값은 그 경로.
    case missingLinkTarget(String)

    public var errorDescription: String? {
        switch self {
        case .missingLinkTarget(let path):
            return "config.json이 가리키는 파일이 없습니다 (\(path))"
        }
    }
}
