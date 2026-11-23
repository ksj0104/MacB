import Foundation

/// `macb://` 주소로 들어온 명령. 다른 런처나 마우스 버튼 도구에서 MacB를 부를 때 쓴다.
///
/// 주소는 아무 프로세스나 열 수 있으므로, 허용하는 형식을 정해 두고 나머지는 모두 거부한다.
///
///     macb://menu            원형 메뉴 열기/닫기
///     macb://clipboard       클립보드 기록
///     macb://slots           숫자 슬롯
///     macb://reload          설정 다시 불러오기
///     macb://run/<기능 ID>   내장 기능 (`BuiltInAction.isURLSafe`인 것만)
///
/// scheme·명령 이름의 대소문자와 끝의 `/` 하나는 봐준다. 쿼리·조각(#)·사용자·포트가 붙거나
/// 경로가 더 깊으면 형식 오류로 거부한다. 설정 파일의 앱·셸·단축어·주소 항목은 내장 기능이 아니라서
/// 주소로는 실행할 수 없다.
public enum URLCommand: Equatable, Sendable {
    case menu
    case clipboard
    case slots
    case reload
    case run(BuiltInAction)

    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// `macb`가 아닌 주소.
        case notMacB
        /// 형식이 틀림 (기능 ID가 없거나, 경로가 깊거나, 쿼리 등이 붙음).
        case malformed
        /// `macb://` 뒤의 명령 이름을 모름.
        case unknownCommand
        /// 내장 기능 ID가 아님.
        case unknownAction
        /// 사용자가 화면에서 아무것도 하지 않아도 끝나는 기능이라 주소로는 열지 않는다.
        case notAllowed(BuiltInAction)

        public var description: String {
            switch self {
            case .notMacB: return "not a macb url"
            case .malformed: return "malformed"
            case .unknownCommand: return "unknown command"
            case .unknownAction: return "unknown action"
            case .notAllowed(let action): return "not allowed via url: \(action.rawValue)"
            }
        }
    }

    public static func parse(_ url: URL) -> Result<URLCommand, Refusal> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformed)
        }
        guard components.scheme?.lowercased() == "macb" else { return .failure(.notMacB) }
        guard
            components.user == nil, components.password == nil, components.port == nil,
            components.percentEncodedQuery?.isEmpty ?? true,
            components.percentEncodedFragment?.isEmpty ?? true
        else { return .failure(.malformed) }

        // 경로는 퍼센트 인코딩된 채로 나눈다. 디코딩한 뒤에 나누면 `%2F`가 경로 구분자로 바뀐다.
        var segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.first == "" { segments.removeFirst() }
        if segments.last == "" { segments.removeLast() }

        let command = (components.host ?? "").lowercased()
        let withoutArgument: [String: URLCommand] = [
            "menu": .menu, "clipboard": .clipboard, "slots": .slots, "reload": .reload,
        ]
        if let simple = withoutArgument[command] {
            return segments.isEmpty ? .success(simple) : .failure(.malformed)
        }
        switch command {
        case "run":
            guard segments.count == 1, let id = segments[0].removingPercentEncoding, !id.isEmpty else {
                return .failure(.malformed)
            }
            guard let action = BuiltInAction(rawValue: id) else { return .failure(.unknownAction) }
            guard action.isURLSafe else { return .failure(.notAllowed(action)) }
            return .success(.run(action))
        case "":
            return .failure(.malformed)
        default:
            return .failure(.unknownCommand)
        }
    }

    /// 로그에 남길 짧은 형태. 주소는 밖에서 들어온 글이라 길이를 자르고 낯선 글자는 `?`로 바꾼다.
    public static func logSummary(of url: URL, limit: Int = 60) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/._-%")
        let text = url.absoluteString
        let cleaned = String(text.prefix(limit).map { allowed.contains($0) ? $0 : "?" })
        return text.count > limit ? cleaned + "…" : cleaned
    }
}
