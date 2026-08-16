// iOS 시뮬레이터에 **진짜 마우스 이벤트**를 보낸다.
//
// **왜 필요한가.** `idb ui swipe`/`tap` 의 합성 터치는 `touchesBegan:` 에는 닿지만
// **제스처 인식기에는 안 닿는다**(실측: 가장자리 조건을 뺀 평범한 `UIPanGestureRecognizer`
// 를 붙여도 한 번도 안 불렸다). 그래서 좌측 가장자리 뒤로가기 같은 인식기 기반 경로는
// idb 로 검증이 안 된다. CGEvent 로 보낸 마우스 드래그는 Simulator 가 정상 터치로 바꿔
// 주므로 인식기가 걸린다 — `MARU_NAV edge_back popped=1` 로 확인했다.
//
// 사용:
//   swift tools/mobile-harness/sim_input.swift drag <x0> <y0> <x1> <y1>   # 기기 논리 pt
//   swift tools/mobile-harness/sim_input.swift tap  <x> <y>
//
// 좌표는 **기기 논리 좌표(pt)** 다. 창 안에서 기기 화면이 가운데 놓인다고 보고 베젤을 뺀다.
// **창을 건드리지 말 것** — 제목줄을 클릭하면 창이 움직여 좌표가 통째로 어긋난다(겪었다).
import CoreGraphics
import Foundation

let devW = 402.0, devH = 874.0 // iPhone 17 Pro 세로. 다른 기기면 여기를 바꾼다.

func simulatorFrame() -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Simulator",
           let b = w[kCGWindowBounds as String] as? [String: Any],
           let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
           let ww = b["Width"] as? CGFloat, let hh = b["Height"] as? CGFloat, ww > 200 {
            return CGRect(x: x, y: y, width: ww, height: hh)
        }
    }
    return nil
}

func post(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

guard let win = simulatorFrame() else { print("시뮬레이터 창을 못 찾았다"); exit(3) }
let padX = (win.width - devW) / 2, padY = (win.height - devH) / 2
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: win.minX + padX + x, y: win.minY + padY + y) }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let a = CommandLine.arguments.dropFirst(2).compactMap(Double.init)
switch mode {
case "drag" where a.count == 4:
    let p0 = pt(a[0], a[1]), p1 = pt(a[2], a[3])
    post(.mouseMoved, p0); usleep(100_000)
    post(.leftMouseDown, p0); usleep(80_000)
    // **중간 점을 촘촘히 보낸다.** 두 점만 보내면 인식기가 드래그로 안 본다.
    let steps = 40
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
        usleep(9_000)
    }
    post(.leftMouseUp, p1)
    print("drag \(a[0]),\(a[1]) -> \(a[2]),\(a[3])")
case "tap" where a.count == 2:
    let p = pt(a[0], a[1])
    post(.mouseMoved, p); usleep(80_000)
    post(.leftMouseDown, p); usleep(60_000)
    post(.leftMouseUp, p)
    print("tap \(a[0]),\(a[1])")
default:
    print("사용: sim_input.swift drag x0 y0 x1 y1 | tap x y  (기기 논리 pt)")
    exit(1)
}
