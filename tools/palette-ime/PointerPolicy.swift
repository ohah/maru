// Test-only pointer admission. Native foreground/window lookup stays with the relay;
// all request, freshness and bounded path decisions live here for negative controls.
import Foundation
import CoreGraphics

enum IMEPointerPolicy {
    enum Failure: Error { case invalid }
    struct Event { let type: CGEventType; let point: CGPoint }
    static func require(_ value: Bool) throws { if !value { throw Failure.invalid } }
    static func events(request: [String: Any], state: [String: Any], window: CGRect, pid: Int32, now: Double) throws -> [Event] {
        try require(request["kind"] as? String == "pointer" && state["address_pointer_mode"] as? Bool == true)
        try require(request["pid"] as? Int == Int(pid) && state["pid"] as? Int == Int(pid) && state["window_key"] as? Bool == true)
        guard let requestTime = request["time"] as? Double, let stateTime = state["time"] as? Double,
              let generation = request["generation"] as? String else { throw Failure.invalid }
        try require(now.isFinite && requestTime.isFinite && stateTime.isFinite && now >= requestTime && now >= stateTime && now-requestTime < 1 && now-stateTime < 1)
        try require(generation == state["generation"] as? String)
        guard let token = UInt64(generation) else { throw Failure.invalid }
        let addressOwner = token > (1 << 62) && token < (1 << 63)
        try require(token == 0 || addressOwner)
        guard let target = request["target"] as? String, ["address", "terminal"].contains(target),
              let targets = state["pointer_targets"] as? [String: [String: Double]], let r = targets[target],
              let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"],
              let px = request["x"] as? Double, let py = request["y"] as? Double else { throw Failure.invalid }
        try require([x,y,w,h,px,py].allSatisfy { $0.isFinite } && w > 0 && h > 0 && (x+w).isFinite && (y+h).isFinite)
        let rect = CGRect(x:x,y:y,width:w,height:h), start = CGPoint(x:px,y:py)
        try require(window.contains(rect) && rect.contains(start))
        if request["action"] as? String == "click" {
            return [Event(type:.leftMouseDown,point:start), Event(type:.leftMouseUp,point:start)]
        }
        try require(request["action"] as? String == "drag" && target == "address" && addressOwner)
        guard let ex = request["end_x"] as? Double, let ey = request["end_y"] as? Double else { throw Failure.invalid }
        try require(ex.isFinite && ey.isFinite && rect.contains(CGPoint(x:ex,y:ey)))
        var result = [Event(type:.leftMouseDown,point:start)]
        for step in 1...6 {
            let fraction = Double(step)/6
            let point = CGPoint(x:px+(ex-px)*fraction,y:py+(ey-py)*fraction)
            try require(rect.contains(point))
            result.append(Event(type:.leftMouseDragged,point:point))
        }
        result.append(Event(type:.leftMouseUp,point:CGPoint(x:ex,y:ey)))
        return result
    }
}
