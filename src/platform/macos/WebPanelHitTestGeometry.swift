import AppKit

/// WKWebView 경계의 divider 통과 판정만 소유하는 순수 기하. `NSView.hitTest(_:)` 입력과 `frame`은 둘 다
/// superview 좌표이므로, origin이 0이 아닌 오른쪽/아래 도크에서도 본문 전체를 seam으로 오판하지 않는다.
enum WebPanelHitTestGeometry {
    static func isInDividerGrabBand(
        pointInSuperview point: NSPoint,
        frameInSuperview frame: NSRect,
        seamEdges: UInt32,
        leftBand: CGFloat,
        rightBand: CGFloat,
        bottomBand: CGFloat
    ) -> Bool {
        guard seamEdges != 0, !frame.isEmpty, frame.contains(point) else { return false }
        // ABI는 같은 process의 Zig producer만 쓰지만 손상된 non-finite/과대 폭이 본문 전체를 pass-through로
        // 바꾸지 않도록 edge별로 fail-close한다.
        let left = leftBand.isFinite && leftBand > 0 && leftBand <= frame.width ? leftBand : 0
        let right = rightBand.isFinite && rightBand > 0 && rightBand <= frame.width ? rightBand : 0
        let bottom = bottomBand.isFinite && bottomBand > 0 && bottomBand <= frame.height ? bottomBand : 0
        // left/bottom은 target의 half-open 끝과 맞춰 `<`, right는 시작점을 포함하므로 `>=`다.
        if (seamEdges & 1) != 0, left > 0, point.x < frame.minX + left { return true }
        if (seamEdges & 2) != 0, right > 0, point.x >= frame.maxX - right { return true }
        if (seamEdges & 4) != 0, bottom > 0, point.y < frame.minY + bottom { return true }
        return false
    }
}
