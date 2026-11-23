/// 내장 기능 ID. 설정 파일의 `action`과 `macb://run/<ID>`에 쓰인다.
///
/// 순서는 메뉴 막대 '도구' 목록의 순서다.
public enum BuiltInAction: String, CaseIterable, Sendable {
    case areaToClipboard = "capture.area.clipboard"
    case areaToFile = "capture.area.file"
    case windowToClipboard = "capture.window.clipboard"
    case windowToFile = "capture.window.file"
    case screenToClipboard = "capture.screen.clipboard"
    case screenToFile = "capture.screen.file"
    case recognizeText = "capture.ocr"
    case pickColor = "capture.color"
    case recordScreen = "capture.record"
    case clipboardHistory = "clipboard.history"
    case clipboardSlots = "clipboard.slots"

    /// `macb://run/<ID>`로 불러도 되는지.
    ///
    /// 주소는 다른 프로세스나, 한 번 허용해 준 웹 페이지도 열 수 있다. 그래서 화면에서 사용자가
    /// 직접 고르거나 눌러야만 결과가 생기는 기능만 연다. 부르기만 하면 끝나는 기능(전체 화면 캡처 등)을
    /// 열어 두면 남이 MacB의 화면 기록 권한으로 몰래 화면을 찍을 수 있다.
    /// 새 기능은 `urlSafe`에 넣기 전까지 주소로는 거부된다.
    public var isURLSafe: Bool {
        BuiltInAction.urlSafe.contains(self)
    }

    private static let urlSafe: Set<BuiltInAction> = [
        .areaToClipboard, .areaToFile,         // 드래그로 영역을 골라야 찍힌다
        .windowToClipboard, .windowToFile,     // 창을 클릭해야 찍힌다
        .recognizeText,                        // 드래그로 영역을 골라야 찍힌다
        .pickColor,                            // 화면을 클릭해야 색이 정해진다
        .recordScreen,                         // 도구 막대에서 직접 녹화를 시작해야 한다
        .clipboardHistory, .clipboardSlots,    // 패널을 보여 줄 뿐, 고르기 전에는 아무것도 붙여넣지 않는다
    ]
}
