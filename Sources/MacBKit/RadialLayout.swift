import CoreGraphics

/// 원형 메뉴의 기하 계산. 화면·뷰와 무관한 순수 계산이라 테스트하기 쉽다.
///
/// 좌표는 중심 기준 오프셋이고 y축이 위를 향한다(AppKit 기본).
/// 0번 항목이 12시 방향, 이후 시계 방향으로 놓인다.
public struct RadialLayout: Equatable, Sendable {
    public var itemCount: Int
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    /// 중심에서 이 거리 안쪽은 "선택 없음".
    public var deadZoneRadius: CGFloat
    /// `bounded` 판정에서 이 거리 바깥은 "선택 없음".
    public var hoverLimitRadius: CGFloat

    public init(
        itemCount: Int,
        innerRadius: CGFloat = 66,
        outerRadius: CGFloat = 158,
        deadZoneRadius: CGFloat = 30,
        hoverLimitRadius: CGFloat = 200
    ) {
        self.itemCount = max(itemCount, 0)
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.deadZoneRadius = deadZoneRadius
        self.hoverLimitRadius = hoverLimitRadius
    }

    public var sectorAngle: CGFloat {
        itemCount > 0 ? 2 * .pi / CGFloat(itemCount) : 2 * .pi
    }

    /// 항목 중심의 각도(라디안, 수학 관례: +x가 0, 반시계 방향이 양수).
    public func centerAngle(of index: Int) -> CGFloat {
        .pi / 2 - CGFloat(index) * sectorAngle
    }

    /// 중심에서 `radius`만큼 떨어진, 항목 방향의 점.
    public func point(of index: Int, radius: CGFloat) -> CGPoint {
        let angle = centerAngle(of: index)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    /// 중심 기준 오프셋이 가리키는 항목.
    ///
    /// - Parameter bounded: true면 `hoverLimitRadius` 바깥을 선택 없음으로 본다(클릭 방식).
    ///   false면 거리 제한 없이 방향만 본다(누른 채 휙 긋는 방식).
    public func index(at offset: CGPoint, bounded: Bool) -> Int? {
        guard itemCount > 0 else { return nil }
        let distance = hypot(offset.x, offset.y)
        guard distance >= deadZoneRadius else { return nil }
        if bounded, distance > hoverLimitRadius { return nil }

        var clockwiseFromTop = .pi / 2 - atan2(offset.y, offset.x)
        clockwiseFromTop = clockwiseFromTop.truncatingRemainder(dividingBy: 2 * .pi)
        if clockwiseFromTop < 0 { clockwiseFromTop += 2 * .pi }
        let index = Int(((clockwiseFromTop + sectorAngle / 2) / sectorAngle).rounded(.down))
        return index % itemCount
    }

    /// 항목 하나의 부채꼴 조각 경로.
    ///
    /// - Parameters:
    ///   - gap: 이웃 조각 사이의 일정한 간격(pt).
    ///   - inset: 조각 테두리에서 안쪽으로 줄이는 양. 둥근 선(lineJoin round, 두께 2×inset)으로
    ///     다시 덧그리면 모서리가 둥근 조각이 된다.
    public func sectorPath(index: Int, center: CGPoint, gap: CGFloat = 4, inset: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        let outer = outerRadius - inset
        let inner = innerRadius + inset
        guard itemCount > 0, outer > inner else { return path }

        if itemCount == 1 {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return path
        }

        let mid = centerAngle(of: index)
        let half = sectorAngle / 2
        let margin = gap / 2 + inset
        // 간격을 각도가 아닌 길이로 일정하게 유지하려면 반지름마다 깎는 각도가 달라진다.
        let outerTrim = asin(min(1, margin / outer))
        let innerTrim = asin(min(1, margin / inner))
        guard half > innerTrim else { return path }

        path.addArc(
            center: center, radius: outer,
            startAngle: mid + half - outerTrim, endAngle: mid - half + outerTrim,
            clockwise: true
        )
        path.addArc(
            center: center, radius: inner,
            startAngle: mid - half + innerTrim, endAngle: mid + half - innerTrim,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
