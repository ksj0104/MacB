import Foundation
import os

/// 가벼운 로깅. `MACB_DEBUG` 환경 변수가 있으면 stderr로도 내보낸다.
/// 클립보드 내용 같은 사용자 데이터는 절대 넘기지 말 것.
public enum Log {
    private static let logger = Logger(subsystem: AppPaths.bundleIdentifier, category: "app")
    private static let mirrorsToStderr = ProcessInfo.processInfo.environment["MACB_DEBUG"] != nil

    public static func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        mirror(text)
    }

    public static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        mirror("error: " + text)
    }

    private static func mirror(_ text: String) {
        guard mirrorsToStderr else { return }
        FileHandle.standardError.write(Data(("[MacB] " + text + "\n").utf8))
    }
}
