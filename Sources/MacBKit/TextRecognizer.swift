import CoreGraphics
import Foundation
import ImageIO
import Vision

/// 이미지 속 글자 인식(OCR). 기기 안에서만 처리된다.
public enum TextRecognizer {
    public enum Failure: Error {
        case unreadableImage
    }

    public struct Fragment: Equatable, Sendable {
        public var text: String
        /// 정규화 좌표(0–1), 원점은 왼쪽 아래.
        public var box: CGRect

        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    /// 읽는 순서대로 정리한 줄 목록을 돌려준다. 오래 걸릴 수 있으니 메인 스레드 밖에서 부를 것.
    public static func recognize(imageAt url: URL, languages: [String]) throws -> [String] {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.unreadableImage }
        return try recognize(image: image, languages: languages)
    }

    public static func recognize(image: CGImage, languages: [String]) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 지원하지 않는 언어 코드가 섞이면 요청 전체가 실패하므로 걸러서 넣는다.
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = languages.filter(supported.contains)
        if !usable.isEmpty {
            request.recognitionLanguages = usable
        }

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let fragments = (request.results ?? []).compactMap { observation -> Fragment? in
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Fragment(text: text, box: observation.boundingBox)
        }
        return lines(from: fragments)
    }

    /// 조각들을 위에서 아래로, 같은 높이에 있는 것끼리는 왼쪽에서 오른쪽으로 이어 붙인다.
    public static func lines(from fragments: [Fragment]) -> [String] {
        var rows: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - fragment.box.midY) < min(anchor.box.height, fragment.box.height) * 0.5 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
    }
}
