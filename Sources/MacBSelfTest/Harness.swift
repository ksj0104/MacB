import Foundation

/// Xcode 없이(Command Line Tools만으로) 돌리는 최소 테스트 러너.
///
/// 이 환경의 `swift test`는 테스트를 실제로 실행하지 않고도 성공을 돌려주기 때문에,
/// 결과를 믿을 수 있도록 평범한 실행 파일로 만들었다. 실패가 하나라도 있으면 종료 코드 1.
final class TestRunner {
    private var currentSuite = ""
    private var checks = 0
    private var failures: [String] = []

    func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        let before = failures.count
        do {
            try body()
        } catch {
            failures.append("[\(name)] threw: \(error)")
        }
        let status = failures.count == before ? "ok  " : "FAIL"
        print("\(status)  \(name)")
    }

    func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        if !condition() {
            failures.append("[\(currentSuite)] \(file):\(line) \(message())")
        }
    }

    func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                                   _ message: @autoclosure () -> String = "",
                                   file: StaticString = #fileID, line: UInt = #line) {
        checks += 1
        let a = actual()
        let e = expected()
        if a != e {
            failures.append("[\(currentSuite)] \(file):\(line) expected \(e), got \(a) \(message())")
        }
    }

    /// 요약을 찍고 종료 코드를 돌려준다.
    func finish() -> Int32 {
        print("")
        if failures.isEmpty {
            print("PASS — \(checks) checks")
            return 0
        }
        for failure in failures { print("  ✘ \(failure)") }
        print("FAIL — \(failures.count) of \(checks) checks failed")
        return 1
    }
}

/// 테스트가 쓰고 버리는 임시 폴더.
func makeTemporaryDirectory(_ label: String = "macb-selftest") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
