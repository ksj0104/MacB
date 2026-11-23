import Foundation

public enum AppPaths {
    public static let bundleIdentifier = "dev.macb.app"

    /// `~/Library/Application Support/MacB`. 테스트에서는 `MACB_HOME`으로 바꿀 수 있다.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MACB_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacB", isDirectory: true)
    }

    public static var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static var clipboardDirectory: URL {
        supportDirectory.appendingPathComponent("clipboard", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
