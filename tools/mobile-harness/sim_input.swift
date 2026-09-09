// iOS 시뮬레이터에 **진짜 마우스 이벤트**를 보낸다.
//
// **왜 필요한가.** `idb ui swipe`/`tap` 의 합성 터치는 `touchesBegan:` 에는 닿지만
// **제스처 인식기에는 안 닿는다**(실측: 가장자리 조건을 뺀 평범한 `UIPanGestureRecognizer`
// 를 붙여도 한 번도 안 불렸다). 그래서 좌측 가장자리 뒤로가기 같은 인식기 기반 경로는
// idb 로 검증이 안 된다. CGEvent 로 보낸 마우스 드래그는 Simulator 가 정상 터치로 바꿔
// 주므로 인식기가 걸린다 — `MARU_NAV edge_back popped=1` 로 확인했다.
//
// 사용:
//   swift tools/mobile-harness/sim_input.swift calibrate                  # **먼저 한 번**
//   swift tools/mobile-harness/sim_input.swift drag <x0> <y0> <x1> <y1>   # 기기 논리 pt
//   swift tools/mobile-harness/sim_input.swift tap  <x> <y>
//   swift tools/mobile-harness/sim_input.swift hold <x> <y> <ms>   # 길게 누르기(선택)
//
// 좌표는 **기기 논리 좌표(pt)** 다. 창 안에서 기기 화면이 가운데 놓인다고 보고 베젤을 뺀다.
// **창을 건드리지 말 것** — 제목줄을 클릭하면 창이 움직여 좌표가 통째로 어긋난다(겪었다).
import CoreGraphics
import Foundation

// **기기 크기를 안 박는다**(M8). 예전에는 `devW/devH` 와 세로 오프셋 70 을 손으로 적어 뒀는데,
// 그 셋은 **기기·창 크기·시뮬레이터 버전마다 다르다** — 실제로 이 기계에서 창 세로 여유가 66 인데
// 오프셋이 70 이라(여유보다 크다) 보내는 점이 통째로 어긋났고, 그래서 손짓이 **아무 데도 안 닿았다**
// (`MARU_TOUCH` 가 한 줄도 안 찍혔다). 지금은 `calibrate` 가 **앱에게 물어서** 사상을 잰다.
let devW = 402.0, devH = 874.0 // 판정 실패 메시지에만 쓰는 참고값(사상에는 안 쓴다).

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
// ── 창 → 기기 사상 (M8) ─────────────────────────────────────────────────────
//
// **재서 안다.** 창 안에서 기기 화면이 어디에 어떤 배율로 놓이는지는 창 크기·제목줄·시뮬레이터
// 배율에 달렸고, 그 셋 다 우리가 못 정한다. `calibrate` 가 앱에 두 점을 찍어 보고 **앱이 받은
// 좌표**로 `window = offset + scale × device` 를 푼다. 그 결과를 파일에 적어 두고 나머지 모드가
// 읽는다.
//
// **없으면 안 보낸다.** 어림값으로 보내면 손짓이 엉뚱한 자리에 닿거나(더 나쁘게) 아무 데도 안
// 닿는데, 둘 다 **조용하다** — 화면이 안 바뀐 것을 보고 「기능이 안 된다」로 읽게 된다.
struct Calibration {
    var offX: Double, offY: Double, scaleX: Double, scaleY: Double
}

// **부르는 자리를 안 탄다.** `arguments[0]` 은 «부른 대로» 의 경로라 다른 디렉터리에서 돌리면
// 다른 파일을 읽고 쓴다 — 보정해 둔 것이 있는데 「없다」고 하거나, 더 나쁘게 남의 값을 읽는다.
// `#filePath` 는 이 소스의 자리라 어디서 불러도 같다.
let calPath = (#filePath as NSString).deletingLastPathComponent + "/out/sim_input_cal.txt"

func loadCalibration() -> Calibration? {
    guard let text = try? String(contentsOfFile: calPath, encoding: .utf8) else { return nil }
    // **개행까지 쪼갠다.** 공백만으로 쪼개면 마지막 항이 `"1.5\n"` 이 되어 `Double(_:)` 가 nil 을
    // 내고, 그러면 **보정을 해 두고도 「없다」** 가 된다 — 자가 검사가 첫 실행에서 이걸 잡았다.
    let f = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).compactMap { Double($0) }
    guard f.count == 4, f[2] != 0, f[3] != 0 else { return nil }
    return Calibration(offX: f[0], offY: f[1], scaleX: f[2], scaleY: f[3])
}

/// 두 점에서 사상을 푼다. **`calibrate` 와 `selftest` 가 같은 함수를 쓴다** — 자가 검사가 사본을
/// 검사하면 아무것도 안 지킨다.
func solve(win0: CGPoint, dev0: CGPoint, win1: CGPoint, dev1: CGPoint) -> Calibration? {
    guard abs(dev1.x - dev0.x) > 1, abs(dev1.y - dev0.y) > 1 else { return nil }
    let sx = (win1.x - win0.x) / (dev1.x - dev0.x)
    let sy = (win1.y - win0.y) / (dev1.y - dev0.y)
    return Calibration(offX: win0.x - sx * dev0.x, offY: win0.y - sy * dev0.y, scaleX: sx, scaleY: sy)
}

func toWindow(_ c: Calibration, _ p: CGPoint) -> CGPoint {
    CGPoint(x: c.offX + c.scaleX * p.x, y: c.offY + c.scaleY * p.y)
}

func saveCalibration(_ c: Calibration) {
    let dir = (calPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "\(c.offX) \(c.offY) \(c.scaleX) \(c.scaleY)\n".write(toFile: calPath, atomically: true, encoding: .utf8)
}

func run(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}

/// 앱이 지금까지 받은 터치 점 **전부**. `touchesBegan` 이 모든 터치를 남기므로(host 의
/// `MARU_TOUCH`) 그것이 우리의 눈이다 — 화면 픽셀을 견주는 것보다 정확하고 어느 화면에서나 된다.
func touchPoints() -> [CGPoint] {
    let out = run("xcrun simctl spawn booted log show --last 120s --predicate 'eventMessage CONTAINS \"MARU_TOUCH\"' 2>/dev/null | grep -o 'pt=([0-9-]*,[0-9-]*)'")
    var pts: [CGPoint] = []
    for line in out.split(separator: "\n") {
        let d = line.split(whereSeparator: { !"0123456789-".contains($0) }).compactMap { Double($0) }
        if d.count >= 2 { pts.append(CGPoint(x: d[0], y: d[1])) }
    }
    return pts
}

/// **새 줄이 올 때까지 기다렸다가** 그 점을 준다. 그냥 「마지막 줄」을 읽으면 os_log 가 아직 안
/// 내보낸 사이에 **지난 실행의 점**을 새 점으로 읽고, 그러면 틀린 사상을 조용히 저장한다 —
/// 실패보다 나쁘다(틀린 자리를 계속 짚으면서 아무도 모른다).
func awaitNewTouch(after n: Int) -> CGPoint? {
    for _ in 0..<12 {
        let pts = touchPoints()
        if pts.count > n { return pts[n] }
        usleep(500_000)
    }
    return nil
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let a = CommandLine.arguments.dropFirst(2).compactMap(Double.init)

/// 창 좌표로 «미는» 손짓 하나. 탭이 아니라 30pt 를 끄는 것이라 **버튼이 안 눌린다** — 어느
/// 화면에서 재도 부작용이 없다(탭 임계를 넘기므로 코어가 스크롤로 본다).
func nudge(at p: CGPoint) {
    post(.mouseMoved, p); usleep(120_000)
    post(.leftMouseDown, p); usleep(80_000)
    for i in 1...10 {
        post(.leftMouseDragged, CGPoint(x: p.x, y: p.y + Double(i) * 3))
        usleep(9_000)
    }
    post(.leftMouseUp, CGPoint(x: p.x, y: p.y + 30))
    usleep(400_000)
}

if mode == "selftest" {
    // **시뮬레이터 없이 도는 판정.** 이 도구의 성공 경로는 이 기계에서 한 번도 안 돌아 봤다
    // (CGEvent 가 시뮬레이터에 안 닿는다) — 그러면 사상을 푸는 산술이 **아무에게도 안 재어진
    // 채로** 남는다. 알려진 사상을 만들어 왕복시켜 그 자리를 메운다.
    var bad = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  \(name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")   \(detail)")
        if !ok { bad += 1 }
    }
    // 창 = (100,60) + 1.5 × 기기 인 사상을 가정하고 두 표본을 만든다.
    let off = CGPoint(x: 100, y: 60), sc = 1.5
    func w(_ d: CGPoint) -> CGPoint { CGPoint(x: off.x + sc * d.x, y: off.y + sc * d.y) }
    let d0 = CGPoint(x: 40, y: 90), d1 = CGPoint(x: 300, y: 700)
    guard let c = solve(win0: w(d0), dev0: d0, win1: w(d1), dev1: d1) else {
        print("  solve 가 nil 을 냈다"); exit(1)
    }
    check("배율을 되찾는다", abs(c.scaleX - sc) < 1e-9 && abs(c.scaleY - sc) < 1e-9, "sx=\(c.scaleX) sy=\(c.scaleY)")
    check("오프셋을 되찾는다", abs(c.offX - off.x) < 1e-9 && abs(c.offY - off.y) < 1e-9, "off=(\(c.offX),\(c.offY))")
    // **표본이 아닌 셋째 점**으로 왕복한다 — 표본만 맞으면 두 점을 외운 것과 구별이 안 된다.
    let probe = CGPoint(x: 210, y: 333)
    let back = toWindow(c, probe)
    check("표본 밖 점도 맞는다", abs(back.x - w(probe).x) < 1e-9 && abs(back.y - w(probe).y) < 1e-9, "\(back) vs \(w(probe))")
    // 두 점이 같으면 못 푼다 — 0 으로 나누는 값을 저장하면 그 뒤 모든 손짓이 NaN 이다.
    check("같은 두 점은 거절한다", solve(win0: w(d0), dev0: d0, win1: w(d0), dev1: d0) == nil, "")
    // 파일 왕복 — 적은 것을 그대로 읽는가(자릿수를 잃으면 조용히 빗나간다).
    saveCalibration(c)
    let r = loadCalibration()
    check("파일에 적고 그대로 읽는다", r != nil && abs(r!.scaleX - c.scaleX) < 1e-9 && abs(r!.offY - c.offY) < 1e-9, r.map { "\($0)" } ?? "없음")
    try? FileManager.default.removeItem(atPath: calPath) // 판정용 값을 남기지 않는다
    print(bad == 0 ? "selftest: 전부 통과" : "selftest: \(bad) 건 실패")
    exit(bad == 0 ? 0 : 1)
}

if mode == "calibrate" {
    // **두 점이면 축마다 배율과 오프셋이 풀린다.** 창 안쪽으로 넉넉히 들어간 두 점을 골라
    // 기기 화면 밖(제목줄·베젤)을 안 짚게 한다.
    let p0 = CGPoint(x: win.minX + win.width * 0.30, y: win.minY + win.height * 0.35)
    let p1 = CGPoint(x: win.minX + win.width * 0.70, y: win.minY + win.height * 0.75)
    // **이미 있는 줄을 세어 둔다** — 지우기에 기대지 않는다(`log erase` 는 권한을 탄다).
    var seen = touchPoints().count
    nudge(at: p0)
    guard let d0 = awaitNewTouch(after: seen) else {
        print("보정 실패: 앱이 첫 점을 못 받았다 — 앱이 떠 있는지, 시뮬레이터 창이 가려지지 않았는지 본다")
        print("  (이 기계에서 CGEvent 가 시뮬레이터에 안 닿는 것을 겪었다. 우리 화면을 몰 때는 `idb ui swipe/tap` 을 쓴다 — README)")
        exit(4)
    }
    seen += 1
    nudge(at: p1)
    guard let d1 = awaitNewTouch(after: seen) else {
        print("보정 실패: 앱이 둘째 점을 못 받았다")
        exit(4)
    }
    seen += 1
    guard let c = solve(win0: p0, dev0: d0, win1: p1, dev1: d1) else {
        print("보정 실패: 두 점이 너무 가깝다")
        exit(4)
    }

    // **스스로 확인하고 나서 저장한다.** 푼 사상으로 «기기 좌표»를 하나 골라 보내고, 앱이 그
    // 자리를 받았는지 본다 — 안 맞는 값을 적어 두면 그 뒤로 모든 손짓이 조용히 빗나간다.
    let probe = CGPoint(x: d0.x + (d1.x - d0.x) * 0.5, y: d0.y + (d1.y - d0.y) * 0.5)
    nudge(at: toWindow(c, probe))
    guard let got = awaitNewTouch(after: seen) else {
        print("보정 실패: 확인 점을 앱이 못 받았다")
        exit(4)
    }
    let err = max(abs(got.x - probe.x), abs(got.y - probe.y))
    guard err <= 2 else {
        print("보정 실패: 되짚기가 \(err)pt 어긋났다 (보낸 기기점 \(probe), 받은 점 \(got)) — 저장하지 않는다")
        exit(5)
    }
    saveCalibration(c)
    print("보정 완료: 창=(\(c.offX),\(c.offY)) 배율=(\(c.scaleX),\(c.scaleY)) 되짚기 오차 \(err)pt")
    exit(0)
}

// **쓰는 법부터 답한다.** 보정 검사보다 먼저다 — 인자를 틀린 사람에게 「보정이 없다」고 하면
// 엉뚱한 것을 고치러 간다.
if !["drag", "tap", "hold"].contains(mode) {
    print("사용: sim_input.swift selftest | calibrate | drag x0 y0 x1 y1 | tap x y | hold x y ms  (기기 논리 pt)")
    exit(1)
}

// **보정이 없으면 아무것도 안 보낸다.** 어림값으로 보내면 조용히 빗나가고, 그 침묵을 보고
// 「기능이 안 된다」로 읽게 된다 — 이 저장소가 실제로 그렇게 두 슬라이스를 놓쳤다.
guard let cal = loadCalibration() else {
    print("보정이 없다 — 먼저 `swift \(CommandLine.arguments[0]) calibrate` 를 돌려라")
    print("  (앱이 떠 있어야 한다. 기기 기준 크기는 \(Int(devW))x\(Int(devH)) 로 본다)")
    exit(2)
}
func pt(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: cal.offX + cal.scaleX * x, y: cal.offY + cal.scaleY * y)
}

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
case "hold" where a.count == 3:
    // **누르고 있는 제스처.** `idb` 로는 못 만들지만(시작부터 균일하게 움직여 슬롭을 먼저
    // 넘긴다) CGEvent 는 눌러 두고 기다리면 그만이다 — 길게 누름은 프레임에서 판정되므로
    // 그 사이 이벤트를 더 보낼 필요가 없다.
    //
    // **2px 만 흔든다.** 진짜 손가락은 가만히 못 있고, 그 떨림이 속도로 남아 떼는 순간 화면을
    // 미끄러뜨린 결함이 있었다(길게 누름 임계 10px 안이라 선택은 그대로 성립한다).
    let hp = pt(a[0], a[1])
    post(.mouseMoved, hp); usleep(100_000)
    post(.leftMouseDown, hp); usleep(60_000)
    post(.leftMouseDragged, CGPoint(x: hp.x + 2, y: hp.y + 2))
    usleep(useconds_t(a[2] * 1000))
    post(.leftMouseUp, CGPoint(x: hp.x + 2, y: hp.y + 2))
    print("hold \(a[0]),\(a[1]) \(a[2])ms")
case "tap" where a.count == 2:
    let p = pt(a[0], a[1])
    post(.mouseMoved, p); usleep(80_000)
    post(.leftMouseDown, p); usleep(60_000)
    post(.leftMouseUp, p)
    print("tap \(a[0]),\(a[1])")
default:
    print("사용: sim_input.swift selftest | calibrate | drag x0 y0 x1 y1 | tap x y | hold x y ms  (기기 논리 pt)")
    exit(1)
}
