import Foundation

/// 한영 전환 키가 건드리는 시스템 설정. 테스트에서는 메모리 속 가짜로 바꿔 끼운다.
public protocol KeyboardSystem: AnyObject {
    /// 지금의 HID 키 바꾸기 목록.
    func keyMappings() throws -> [HIDKeyMapping]
    /// 목록 전체를 갈아 끼운다(`hidutil property --set`이 그렇게 동작한다).
    func setKeyMappings(_ mappings: [HIDKeyMapping]) throws
    /// '이전 입력 소스 선택'(60번) 항목. 항목이 없으면(시스템 기본값으로 동작) nil.
    func inputSourceHotKey() -> SymbolicHotKey?
    /// 60번 항목만 바꿔 저장한다. 다른 항목은 건드리지 않는다.
    func setInputSourceHotKey(_ hotKey: SymbolicHotKey) throws
    /// 저장한 단축키를 로그아웃 없이 바로 반영한다.
    func activateSettings() throws
}

public struct KeyboardSystemError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// 실제 macOS. HID 키 바꾸기는 `hidutil`, 단축키는 `com.apple.symbolichotkeys` 환경설정,
/// 반영은 `activateSettings -u`로 한다. 관리자 권한은 필요 없다.
///
/// 외부 명령을 기다리므로 메인 스레드 밖에서 부르는 편이 좋다.
public final class MacKeyboardSystem: KeyboardSystem {
    static let hidutilPath = "/usr/bin/hidutil"
    static let activateSettingsPath =
        "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let hotKeysKey = "AppleSymbolicHotKeys" as CFString
    private static let inputSourceID = "60"

    public init() {}

    public func keyMappings() throws -> [HIDKeyMapping] {
        let result = try Self.run(Self.hidutilPath, ["property", "--get", "UserKeyMapping"])
        guard result.status == 0 else {
            throw KeyboardSystemError("hidutil이 실패했습니다 (종료 코드 \(result.status))" + Self.suffix(result.errorOutput))
        }
        return try HIDKeyMapping.parse(result.output)
    }

    public func setKeyMappings(_ mappings: [HIDKeyMapping]) throws {
        let result = try Self.run(Self.hidutilPath, ["property", "--set", HIDKeyMapping.setArgument(mappings)])
        guard result.status == 0 else {
            throw KeyboardSystemError("hidutil이 실패했습니다 (종료 코드 \(result.status))" + Self.suffix(result.errorOutput))
        }
    }

    public func inputSourceHotKey() -> SymbolicHotKey? {
        // 시스템 설정에서 그 사이 바꾼 값도 읽도록 먼저 맞춘다.
        CFPreferencesAppSynchronize(Self.domain)
        guard let all = CFPreferencesCopyAppValue(Self.hotKeysKey, Self.domain) as? NSDictionary,
              let entry = all[Self.inputSourceID] as? NSDictionary else { return nil }
        return SymbolicHotKey(dictionary: entry)
    }

    public func setInputSourceHotKey(_ hotKey: SymbolicHotKey) throws {
        CFPreferencesAppSynchronize(Self.domain)
        let current = CFPreferencesCopyAppValue(Self.hotKeysKey, Self.domain) as? NSDictionary
        // 얕은 복사라 다른 항목은 읽은 객체 그대로 다시 쓰인다.
        let updated = NSMutableDictionary(dictionary: current ?? [:])
        updated[Self.inputSourceID] = hotKey.dictionary
        CFPreferencesSetAppValue(Self.hotKeysKey, updated, Self.domain)
        guard CFPreferencesAppSynchronize(Self.domain) else {
            throw KeyboardSystemError("환경설정(com.apple.symbolichotkeys)을 저장하지 못했습니다")
        }
    }

    public func activateSettings() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.activateSettingsPath) else {
            throw KeyboardSystemError("activateSettings가 없습니다")
        }
        let result = try Self.run(Self.activateSettingsPath, ["-u"])
        guard result.status == 0 else {
            throw KeyboardSystemError("activateSettings가 실패했습니다 (종료 코드 \(result.status))" + Self.suffix(result.errorOutput))
        }
    }

    // MARK: Process

    private struct Output {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            throw KeyboardSystemError("\((path as NSString).lastPathComponent)을(를) 실행하지 못했습니다")
        }
        // 출력이 몇 줄뿐이라 차례로 끝까지 읽어도 파이프가 막히지 않는다.
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func suffix(_ errorOutput: String) -> String {
        let line = errorOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "" : ": " + line.prefix(120)
    }
}
