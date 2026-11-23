import Foundation
import MacBKit

@MainActor
func runURLCommandTests(_ t: TestRunner) {
    /// 테스트에 쓰는 주소는 모두 URL로 만들어져야 한다. 못 만들면 형식 오류로 본다.
    func parse(_ text: String) -> Result<URLCommand, URLCommand.Refusal> {
        guard let url = URL(string: text) else { return .failure(.malformed) }
        return URLCommand.parse(url)
    }

    t.suite("BuiltInAction: 모든 내장 기능의 주소 허용 여부") {
        // 내장 기능을 새로 넣으면 여기에도 적어야 통과한다. 주소로 열어도 되는지 일부러 정하게 하려는 것이다.
        let expected: [String: Bool] = [
            "capture.area.clipboard": true,
            "capture.area.file": true,
            "capture.window.clipboard": true,
            "capture.window.file": true,
            "capture.screen.clipboard": false,
            "capture.screen.file": false,
            "capture.ocr": true,
            "capture.color": true,
            "capture.record": true,
            "clipboard.history": true,
            "clipboard.slots": true,
        ]
        t.expectEqual(Set(BuiltInAction.allCases.map(\.rawValue)), Set(expected.keys), "분류표와 내장 기능 목록이 다름")
        for action in BuiltInAction.allCases {
            t.expectEqual(action.isURLSafe, expected[action.rawValue], action.rawValue)
        }
        for item in AppConfig.RadialMenu.defaultItems {
            t.expect(item.action.flatMap(BuiltInAction.init(rawValue:)) != nil, "기본 메뉴 항목이 내장 기능이 아님: \(item.action ?? "nil")")
        }
    }

    t.suite("URLCommand: 기본 명령") {
        t.expectEqual(parse("macb://menu"), .success(.menu))
        t.expectEqual(parse("macb://clipboard"), .success(.clipboard))
        t.expectEqual(parse("macb://slots"), .success(.slots))
        t.expectEqual(parse("macb://reload"), .success(.reload))
        t.expectEqual(parse("macb://menu/"), .success(.menu), "끝의 / 하나는 봐줌")
        t.expectEqual(parse("MACB://MENU"), .success(.menu), "scheme·명령 대소문자")
        t.expectEqual(parse("Macb://Clipboard/"), .success(.clipboard))
        t.expectEqual(parse("macb://menu//"), .failure(.malformed))
        t.expectEqual(parse("macb://menu/extra"), .failure(.malformed))
        t.expectEqual(parse("macb://menu?x=1"), .failure(.malformed), "쿼리는 받지 않음")
        t.expectEqual(parse("macb://menu#top"), .failure(.malformed))
        t.expectEqual(parse("macb://nope"), .failure(.unknownCommand))
        t.expectEqual(parse("macb://"), .failure(.malformed))
        t.expectEqual(parse("macb:menu"), .failure(.malformed))
        t.expectEqual(parse("macb:///menu"), .failure(.malformed))
        t.expectEqual(parse("https://menu"), .failure(.notMacB))
        t.expectEqual(parse("macbx://menu"), .failure(.notMacB))
        t.expectEqual(parse("file:///tmp/menu"), .failure(.notMacB))
    }

    t.suite("URLCommand: run은 화면에서 직접 고르는 기능만") {
        for action in BuiltInAction.allCases {
            let expected: Result<URLCommand, URLCommand.Refusal> =
                action.isURLSafe ? .success(.run(action)) : .failure(.notAllowed(action))
            t.expectEqual(parse("macb://run/\(action.rawValue)"), expected, action.rawValue)
        }
        // 사용자 조작 없이 끝나는 두 기능은 어떻게 써도 거부된다.
        t.expectEqual(parse("macb://run/capture.screen.clipboard"), .failure(.notAllowed(.screenToClipboard)))
        t.expectEqual(parse("macb://run/capture.screen.file"), .failure(.notAllowed(.screenToFile)))
        t.expectEqual(parse("MACB://RUN/capture.screen.file/"), .failure(.notAllowed(.screenToFile)))
        t.expectEqual(parse("macb://run/capture.screen%2Eclipboard"), .failure(.notAllowed(.screenToClipboard)), "인코딩으로 우회되지 않음")
        t.expectEqual(parse("macb://run/capture%2Escreen%2Efile"), .failure(.notAllowed(.screenToFile)))
        // 설정 파일의 앱·셸·단축어·주소 항목은 내장 기능이 아니다. 모르는 ID도 마찬가지.
        for id in ["shell.0", "app.1", "shortcut.2", "url.3", "unknown.4", "empty.5", "nope", "CAPTURE.OCR", "capture.ocr.extra", ".."] {
            t.expectEqual(parse("macb://run/\(id)"), .failure(.unknownAction), id)
        }
    }

    t.suite("URLCommand: run의 이상한 형식") {
        t.expectEqual(parse("macb://run"), .failure(.malformed), "ID 없음")
        t.expectEqual(parse("macb://run/"), .failure(.malformed), "빈 ID")
        t.expectEqual(parse("macb://run//"), .failure(.malformed))
        t.expectEqual(parse("macb://run/a/b"), .failure(.malformed), "경로가 깊음")
        t.expectEqual(parse("macb://run/capture.ocr/extra"), .failure(.malformed))
        t.expectEqual(parse("macb://run//capture.ocr"), .failure(.malformed))
        t.expectEqual(parse("macb://run/capture.ocr//"), .failure(.malformed))
        t.expectEqual(parse("macb://run/capture.ocr/"), .success(.run(.recognizeText)), "끝의 / 하나는 봐줌")
        t.expectEqual(parse("MACB://Run/capture.ocr"), .success(.run(.recognizeText)), "scheme·명령 대소문자")
        t.expectEqual(parse("macb://run/capture%2Eocr"), .success(.run(.recognizeText)), "퍼센트 인코딩은 풀어서 봄")
        t.expectEqual(parse("macb://run/capture.area%2Fclipboard"), .failure(.unknownAction), "%2F는 경로 구분자가 아님")
        t.expectEqual(parse("macb://run/capture.ocr%00"), .failure(.unknownAction))
        t.expectEqual(parse("macb://run/%20capture.ocr"), .failure(.unknownAction))
        t.expectEqual(parse("macb://run/capture.ocr?lang=ko"), .failure(.malformed), "쿼리는 받지 않음")
        t.expectEqual(parse("macb://run/capture.ocr#x"), .failure(.malformed))
        t.expectEqual(parse("macb://user@run/capture.ocr"), .failure(.malformed))
        t.expectEqual(parse("macb://run:80/capture.ocr"), .failure(.malformed))
        t.expectEqual(parse("macb:run/capture.ocr"), .failure(.malformed))
        t.expectEqual(parse("https://run/capture.ocr"), .failure(.notMacB))
    }

    t.suite("URLCommand: 로그에는 짧고 안전한 형태만") {
        guard let long = URL(string: "macb://run/" + String(repeating: "a", count: 500)),
              let odd = URL(string: "macb://run/%E2%80%AE%0A%3Cscript%3E%22")
        else {
            t.expect(false, "테스트 주소를 만들지 못함")
            return
        }
        let summary = URLCommand.logSummary(of: long)
        t.expect(summary.count <= 61, "길이: \(summary.count)")
        t.expect(summary.hasSuffix("…"))
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/._-%?…")
        t.expect(URLCommand.logSummary(of: odd).allSatisfy(allowed.contains), URLCommand.logSummary(of: odd))
        t.expectEqual(URLCommand.logSummary(of: URL(string: "macb://run/capture.ocr")!), "macb://run/capture.ocr")
    }
}
