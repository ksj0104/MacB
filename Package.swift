// swift-tools-version: 5.9
import PackageDescription

// MacB — 단축키로 여는 원형 메뉴 런처.
//
//   MacBKit        공용 기반 (단축키, 토스트, 키 입력 합성, 권한, 설정 모델, 원형 배치 계산)
//   MacBClipboard  클립보드 기록 + 숫자 슬롯
//   MacB           앱 본체 (메뉴바, 원형 메뉴, 캡처 도구)
//   MacBSelfTest   Xcode 없이 돌리는 자체 테스트 실행 파일
let package = Package(
    name: "MacB",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacBKit"),
        .target(name: "MacBClipboard", dependencies: ["MacBKit"]),
        .executableTarget(name: "MacB", dependencies: ["MacBKit", "MacBClipboard"]),
        .executableTarget(name: "MacBSelfTest", dependencies: ["MacBKit", "MacBClipboard"]),
    ]
)
