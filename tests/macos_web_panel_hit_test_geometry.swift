import AppKit

@main
struct WebPanelHitTestGeometryTests {
    static func main() {
        let frame = NSRect(x: 900, y: 120, width: 400, height: 500)
        let allEdges: UInt32 = 1 | 2 | 4

        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.midX, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX + 5, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.maxX - 3, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.midX, y: frame.minY + 5),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX + 5, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: 0,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX + 5, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 0,
            rightBand: 0,
            bottomBand: 0
        ))
        // target 교집합 끝은 half-open이며 frame 밖 point는 pass-through로 분류하지 않는다.
        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX + 6, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX - 1, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: 6,
            rightBand: 4,
            bottomBand: 8
        ))
        precondition(!WebPanelHitTestGeometry.isInDividerGrabBand(
            pointInSuperview: NSPoint(x: frame.minX + 1, y: frame.midY),
            frameInSuperview: frame,
            seamEdges: allEdges,
            leftBand: .infinity,
            rightBand: frame.width + 1,
            bottomBand: .nan
        ))
    }
}
