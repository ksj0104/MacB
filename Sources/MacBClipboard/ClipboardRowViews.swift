import AppKit
import MacBKit

/// 패널 치수. 화면 밖 스냅샷도 같은 값을 쓴다.
enum PanelMetrics {
    static let width: CGFloat = 420
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 42
    static let listPadding: CGFloat = 6
    static let visibleRows = 9
    static let cornerRadius: CGFloat = 16
    /// 행 안쪽 여백(선택 표시 바깥 여백 6 + 안쪽 10).
    static let rowInset: CGFloat = 16

    static var size: NSSize {
        NSSize(
            width: width,
            height: headerHeight + 1 + rowHeight * CGFloat(visibleRows) + listPadding * 2 + 1 + footerHeight
        )
    }
}

// MARK: - Row

/// 앱이 활성 상태가 아니어도(패널은 MacB를 활성화하지 않는다) 강조색으로 선택을 그린다.
/// 기본 표 선택은 비활성 앱에서 회색으로 바뀌어 눈에 잘 안 띈다.
final class ClipboardRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            for case let cell as ClipboardRowCell in subviews {
                cell.backgroundStyle = interiorBackgroundStyle
            }
        }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

/// 행 하나: [번호] [아이콘/썸네일] [미리보기 1–2줄] [앱 이름 / 시간].
/// 고정 높이라 오토레이아웃 대신 직접 배치한다(빠르고 결과가 일정하다).
final class ClipboardRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ClipboardRowCell")

    struct Content {
        var number: Int?
        var icon: NSImage?
        /// SF Symbol처럼 색을 입히는 아이콘인지(썸네일·파일 아이콘은 아니다).
        var iconIsTemplate = false
        var text: String
        var isPlaceholder = false
        var app: String?
        var time: String?
    }

    private let badge = NumberBadge()
    private let iconView = NSImageView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let appLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var content = Content(text: "")

    private static let previewFont = NSFont.systemFont(ofSize: 13)
    private static let metaFont = NSFont.systemFont(ofSize: 11)
    private static let previewLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: previewFont))
    private static let metaLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: metaFont))

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.rowHeight))
        identifier = Self.reuseIdentifier

        iconView.imageAlignment = .alignCenter

        previewLabel.font = Self.previewFont
        previewLabel.isSelectable = false
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.cell?.truncatesLastVisibleLine = true

        for label in [appLabel, timeLabel] {
            label.font = Self.metaFont
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
        }

        for view in [badge, iconView, previewLabel, appLabel, timeLabel] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ content: Content) {
        self.content = content
        badge.number = content.number ?? 0
        badge.isHidden = content.number == nil
        iconView.image = content.icon
        iconView.isHidden = content.icon == nil
        iconView.imageScaling = content.iconIsTemplate ? .scaleNone : .scaleProportionallyUpOrDown
        previewLabel.stringValue = content.text
        appLabel.stringValue = content.app ?? ""
        timeLabel.stringValue = content.time ?? ""
        appLabel.isHidden = content.app?.isEmpty ?? true
        timeLabel.isHidden = content.time?.isEmpty ?? true
        applyColors()
        needsLayout = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let row = superview as? NSTableRowView {
            backgroundStyle = row.interiorBackgroundStyle
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x = PanelMetrics.rowInset

        badge.frame = NSRect(x: x, y: ((height - 18) / 2).rounded(), width: 18, height: 18)
        x += 18 + 10

        let iconSide: CGFloat = 26
        iconView.frame = NSRect(x: x, y: ((height - iconSide) / 2).rounded(), width: iconSide, height: iconSide)
        x += iconSide + 10

        let hasMeta = !appLabel.isHidden || !timeLabel.isHidden
        let metaWidth: CGFloat = 78
        let right = bounds.width - PanelMetrics.rowInset
        let textRight = hasMeta ? right - metaWidth - 10 : right
        let textWidth = max(0, textRight - x)

        // 글자 칸은 테두리 안쪽 여백이 있어 2pt쯤 더 잡는다.
        let maxTextHeight = Self.previewLineHeight * 2 + 2
        let fitting = previewLabel.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: textWidth, height: maxTextHeight * 4)
        ).height ?? Self.previewLineHeight
        let textHeight = min(ceil(fitting), maxTextHeight)
        previewLabel.frame = NSRect(x: x - 2, y: ((height - textHeight) / 2).rounded(), width: textWidth + 4, height: textHeight)

        let lineHeight = Self.metaLineHeight
        let metaX = right - metaWidth
        switch (appLabel.isHidden, timeLabel.isHidden) {
        case (false, false):
            let top = ((height - lineHeight * 2 - 2) / 2).rounded()
            appLabel.frame = NSRect(x: metaX, y: top, width: metaWidth, height: lineHeight)
            timeLabel.frame = NSRect(x: metaX, y: top + lineHeight + 2, width: metaWidth, height: lineHeight)
        case (false, true):
            appLabel.frame = NSRect(x: metaX, y: ((height - lineHeight) / 2).rounded(), width: metaWidth, height: lineHeight)
        case (true, false):
            timeLabel.frame = NSRect(x: metaX, y: ((height - lineHeight) / 2).rounded(), width: metaWidth, height: lineHeight)
        case (true, true):
            break
        }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        badge.isSelected = selected
        if content.isPlaceholder {
            previewLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        } else {
            previewLabel.textColor = selected ? .white : .labelColor
        }
        appLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.88) : .secondaryLabelColor
        timeLabel.textColor = selected ? NSColor.white.withAlphaComponent(0.72) : .tertiaryLabelColor
        if content.iconIsTemplate {
            iconView.contentTintColor = selected ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
        } else {
            iconView.contentTintColor = nil
        }
    }
}

/// 1–9 숫자 배지. 숫자 키로 바로 고를 수 있는 행이라는 표시.
final class NumberBadge: NSView {
    var number = 0 { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isSelected ? NSColor.white.withAlphaComponent(0.24) : NSColor.labelColor.withAlphaComponent(0.08)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()))
    }
}

// MARK: - Chrome

/// 1px 구분선.
final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// 둥근 반투명 배경. 화면 밖 스냅샷에서는 블러가 그려지지 않으므로 불투명하게 칠한다.
final class PanelBackgroundView: NSView {
    private let isOpaqueFill: Bool
    private let radius: CGFloat

    init(opaqueFill: Bool, radius: CGFloat) {
        isOpaqueFill = opaqueFill
        self.radius = radius
        super.init(frame: .zero)
        guard !opaqueFill else { return }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        // MacB는 활성 앱이 아니므로 '항상 활성'으로 둬야 흐릿한 비활성 모양이 되지 않는다.
        blur.state = .active
        blur.maskImage = VisualMask.rounded(radius: radius)
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isOpaqueFill else { return }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// 맨 위에 얹는 얇은 테두리. 밝은 배경 위에서도 패널 경계가 보이게 한다. 마우스는 통과시킨다.
final class PanelBorderView: NSView {
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        path.stroke()
    }
}

// MARK: - Helpers

enum RowImages {
    static let textSymbol = symbol("text.alignleft")
    static let photoSymbol = symbol("photo")

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// 정사각형으로 채워 자르고 모서리를 둥글린 썸네일. 그릴 때마다 자르지 않도록 한 번 만들어 둔다.
    static func roundedThumbnail(_ image: NSImage, side: CGFloat, radius: CGFloat) -> NSImage {
        let scale: CGFloat = 2
        let pixels = Int(side * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        // 컨텍스트를 만들기 전에 포인트 크기를 정해야 2배 해상도로 그려진다.
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        let size = image.size
        if size.width > 0, size.height > 0 {
            let fill = max(side / size.width, side / size.height)
            let drawn = NSSize(width: size.width * fill, height: size.height * fill)
            image.draw(in: NSRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        border.lineWidth = 0.5
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}

enum RelativeTime {
    /// "방금", "3분 전", "2시간 전", "어제", "4일 전", "11월 3일", "2025. 3. 1."
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "방금" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))시간 전" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "어제" }
        if days < 7 { return "\(days)일 전" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        if parts.year == calendar.component(.year, from: now) { return "\(month)월 \(day)일" }
        return "\(parts.year ?? 0). \(month). \(day)."
    }
}
