//! 응답 본문 기록(W9d② — docs/plans/web-osr-backend.md 「W9d② 결정」). maru 가 `net_record` 로 켠 탭에만 CDP `Network.enable` 을 걸고,
//! 그 탭의 CDP 이벤트와 CEF 처리기의 요청을 맞춰(`net_body_table` — CEF 를 모르는 표) 글 응답의 본문을 `Network.getResponseBody` 로 받아
//! `net_body_data`·`net_body_end` 로 보낸다. 다른 탭은 CDP 이벤트를 켜지 않는다(쏟아질 때 요청마다 이벤트 여섯 — J7).
//!
//! - 관찰자는 기록하는 탭에만 따로 단다(`devtools.zig` 의 것과 나눈다 — 이벤트 콜백은 이 관찰자에만). 결과는 그 브라우저의 모든 관찰자에게
//!   가므로 제 번호 대역 `[1<<28, 1<<29)` 만 고른다(J13 — 비었다). 등록은 끄는 명령·브라우저 닫힘에서 놓는다(콜백 안에서는 놓지 않는다).
//! - `Network.enable {maxResourceBufferSize 2 MiB, maxTotalBufferSize 8 MiB, maxPostDataSize 1}` — 2 MiB 인 까닭: Chromium 은 Latin-1
//!   밖의 글자가 하나라도 있으면 글을 UTF-16 으로 센다(J4 — 1 MiB 면 0.6 MB JSON 이 밀렸다). 우리 상한(1 MiB)은 `dataReceived` 합으로 따로
//!   본다(스크립트·스타일은 CDP 상한이 듣지 않았다 — 11 MB). `maxPostDataSize` 는 1(0 은 「상한 없음」 이다 — J10).
//! - 끌 때는 `Network.disable` 을 보내며 곧 세대를 바꾼다 — 그 답이 쏟아짐 뒤로 2.8 초 늦을 수 있다(J6). 렌더러가 죽으면 보낸 호출은 다음
//!   이동까지 답이 없다(J5) — `detached` 로 곧 끝낸다. 렌더러가 바뀌거나 다시 떠도 다시 켤 필요는 없다(J5).
//! - 본문 frame 은 보내는 줄에 본문 하나의 자리를 먼저 잡는다(`events.Writer.reserveBody`) — 없으면 `busy`(maru 가 읽지 않는 동안 UI 스레드가
//!   서지 않는다 — J7).
//! - 시각은 mach_absolute_time 의 µs — Chromium 의 TimeTicks(CDP `timestamp`)와 같은 시계다(J1). `network.zig` 의 IO 스레드도 이것으로 찍는다.
//! - 재검증 5 차 S1·S3b(서비스 워커 갈래 새 설계 — docs/plans/web-osr-backend.md): 기본으로(`MARU_WEB_SW_CDP=0` 이면 끈다) `Network.enable` 의
//!   **성공 답 뒤에** 페이지 세션에 `Target.setAutoAttach{autoAttach, flatten, waitForDebuggerOnStart, filter:[service_worker, worker]}` 를 걸고
//!   붙는 서비스 워커 세션마다 `Network.enable{0, 0, maxPostDataSize 1}`(본문을 받지 않는다 — 공격 2 A9). 그 세션의 사건은 원시 관찰자
//!   (`on_dev_tools_message`)로만 온다(실측 p1 — CEF 파서는 sessionId 메시지를 넘기지 않는다) — 끝이 sessionId 인 메시지만 가로채고(표에 있는
//!   세션이면 1) 나머지는 CEF 에 맡긴다. 워커 사건도 그 탭의 쏟아짐 밸브에 센다. 기록이 멈추는 모든 길(표의 `.detach_workers`)에서
//!   `setAutoAttach{autoAttach:false}` — 떼지 않으면 그 출처의 서비스 워커가 놀아도 멈추지 않는다(실측 75 초). 워커 W 는 서비스 워커 갈래 기록의
//!   쌍둥이이고(짝은 W 의 응답 때), 서비스 워커가 답한 페이지 응답 P 의 본문은 τ(`responseTime`)로 W 와 그 기록에 잇는다(`net_body_table.swLinkOne` — C0–C7′).
//! - 재검증 12 차(눈먼 때를 뿌리에서 — 계획 「재검증 12 차」): `waitForDebuggerOnStart:true` — 새로 뜨는 워커는 멈춰 붙는다
//!   (`attachedToTarget.waitingForDebugger`). 그 세션에 `Network.enable` 을 보내고 **그 뒤 차례로** `Runtime.runIfWaitingForDebugger`(Playwright
//!   `crServiceWorker`·Puppeteer `TargetManager` 의 차례 — 한 세션의 메시지는 차례대로 풀리고 워커는 놓일 때까지 스크립트를 돌리지 않는다; enable 답은
//!   놓기 뒤에야 온다 — 답을 기다려 놓으면 워커가 그 시한까지 멈췄다, 실측 PHASE0). 그래서 새로 뜬 워커는 눈먼 때가 없다(`Table.workerAttachedPaused`).
//!   옛 PHASE0 b 가 막혔던 까닭과 막는 길: ① 렌더러는 filter 를 모른 채 자식 전용 워커를 모두 멈춘다 — filter 로 뺀 전용 워커는 붙지 않아 놓을 길이
//!   없었다(f1·f5) → filter 에 `worker` 를 넣어 붙이고 곧 놓은 뒤 뗀다, ② 붙은 채 멈춘 워커의 다시 뜸(`targetReloadedAfterCrash`)을 놓지 않았다(w1–w3)
//!   → 다시 뜸마다 놓고, 멈춤(`targetCrashed`)에 세션을 떼 다음 시작이 새로 멈춰 붙게 한다(기록 앞에 깐 버전의 다시 뜸은 멈추지 않아 눈멀었다 —
//!   `swwait-restart-pre`). ③ 놓기 답 앞에 세션이 사라지면(다른 출처로 옮김에 Chromium 이 스스로 뗌·탭 닫힘·기록 끔의 떼기) 워커가 아무도 놓지 않는
//!   채 멈춘다(`swwait-navrace`·`closerace` 4/5) → 뗄 세션은 놓기 답 뒤에 떼고(`release`), 관찰자는 탭이 닫힐 때까지 두며(끔 뒤에 온 붙음도 놓는다),
//!   답 앞에 사라진 세션(Chromium 의 뗌·기록 끔의 `autoAttach:false`·탭 닫힘)의 워커는 살아 있는 탭에서 `Target.attachToTarget` 으로 다시 붙어
//!   놓는다(건지기 — `rescueTick`). 떠 있던 워커(`waitingForDebugger` 거짓)에 붙는 순간의 눈먼 때만 남는다 — 넓은 꼴(그 뒤 50 ms 의 서비스 워커 갈래
//!   본문도 어둠 — 남는 틈 ⑩ 을 닫는다).
//! - 재검증 12 차(⑩′ — 사용자 결정 2026-11-06): 다녀간 출처의 세션(`net_body_sw.Session.visited`)은 기록이 끝날 때까지 붙여 둔다 — 남의 출처 시한 떼기를
//!   하지 않고, Chromium 이 떠날 때 뗀 세션(auto-attach 는 그 탭 프레임과 맞지 않는 SW 세션을 뗀다; `Target.attachToTarget` 세션은 떼지 않는다)은 손으로
//!   다시 붙인다. 돌아오면 이미 켜진 세션이라 눈먼 때가 없고, Chromium 이 다시 붙인 세션은 그림자로 쥔다(켜지 않는다). 떠나 있는 동안의 다시 붙음 눈먼
//!   때는 이 탭의 기록을 가리지 못한다(`Blind.away` — 그 출처의 기록은 그 출처를 맨 위에 둔 탭에만 붙는다). 그래서 눈먼 때는 기록 중 그 탭과 떠 있는
//!   워커가 처음 만날 때 한 번만 선다(기록을 켤 때 이미 떠 있던 워커 — 사용자 결정 ②; 몫으로 뗀 출처로 돌아옴·렌더러 죽음 뒤 다시 걸기도 그 꼴 — 어둠).
//! - 재검증 6 차 F13: auto-attach 는 그 탭의 **프레임들의 출처**의 서비스 워커를 붙인다(다른 출처 iframe 의 워커가 기록 중 다시 뜨면 — 다른
//!   사이트도). 붙인 세션마다 워커 스크립트 주소의 출처를 맨 위 출처와 견주어, 다르면 `net_body_sw.foreign_grace_us` 뒤에 뗀다(`foreignCheck` —
//!   C0 가 어차피 그 워커의 W 로 본문을 잇지 않으니 잃는 것이 없다; 곧 떼지 않는 까닭은 이동 중 새 출처의 워커가 주소 바뀜보다 먼저 붙을 수
//!   있어서다). 맨 위 출처가 이동으로 바뀌면(`topOrigin`) 앞 출처의 세션도 같은 시한 뒤에 떼고, 새 출처의 것이 된 세션은 남겨 그때 VS 를
//!   올린다. 그래서 기록 중 살아 있는 워커는 「그 탭이 보이는 출처의 서비스 워커」 다(사용자 결정 ② 의 범위).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("net_body_table.zig");
const events = @import("events.zig");
const network = @import("network.zig"); // W9d② 적대 리뷰 3 회차 P1: CEF 기록의 물 높이(`cefWatermark`)
const sw_mod = @import("net_body_sw.zig"); // 재검증 5 차 S1: 서비스 워커 세션의 표

const msg = protocol.message;
const BrowserId = msg.BrowserId;
const gpa = std.heap.c_allocator;

var table: table_mod.Table = .{};
/// 재검증 5 차 S1: 붙은 서비스 워커 세션·세대(`net_body_sw`).
var sw: sw_mod.Sw = .{};
/// 재검증 5 차 S1·S3b: 서비스 워커 세션을 붙이는가 — 기본 켬(`MARU_WEB_SW_CDP=0` 이면 끈다 — S0 의 길: 서비스 워커가 답한 응답은 본문 없이).
var sw_cdp = true;
/// 재검증 5 차 S3b: 짝이 된 기록에 그 응답을 받은 페이지 P 의 본문을 잇는다(C0–C7′).
const sw_link = true;
/// 재검증 12 차: 새로 뜨는 워커를 멈춰 붙인다(`waitForDebuggerOnStart:true`). 기본 켬(`MARU_WEB_SW_WAIT=0` 이면 11 차 길 — 판정자의 대조).
var sw_wait = true;
/// 재검증 12 차 PHASE0 탐침 손잡이(판정자 전용): auto-attach filter(`sw` 서비스 워커만 · `swdw` 전용 워커도 · `none` 모두), 놓지 않기.
var sw_wait_filter: enum { sw, swdw, none } = .swdw;
var test_norelease = false;
/// 재검증 12 차: 워커가 멈추면(`Inspector.targetCrashed`) 그 세션을 뗀다 — 다음 시작이 새로 멈춰 붙는다(붙은 채 멈춘 워커의 다시 뜸은 그 버전이
/// 멈춰 붙어 깔린 것일 때만 멈춘다 — Chromium `should_pause_on_start`; 기록 앞에 깐 워커는 멈추지 않고 떠 눈멀었다, 실측 `swwait-restart-pre`).
/// PHASE0 대조 `MARU_WEB_SW_WAIT_STOPDETACH=0`.
var stop_detach = true;
/// PHASE0 손잡이(판정자 전용): 놓기 답을 버린다(`MARU_WEB_TEST_SW_NOREPLY` — 답이 끊긴 꼴)·놓기 답 시한(ms — `MARU_WEB_TEST_SW_PEND_MS`).
var test_noreply = false;
var pend_timeout_us: i64 = sw_mod.pend_timeout_us;
var registrations: [registry_mod.capacity]?struct { cef_id: c_int, browser: BrowserId, reg: [*c]c.cef_registration_t } = @splat(null);
var observer: c.cef_dev_tools_message_observer_t = undefined;
var ready = false;
var tick_task: c.cef_task_t = undefined;
var tick_posted = false;
/// 어느 탭이든 기록하는가 — IO 스레드(`network.zig`)가 값싸게 본다(주소 해시를 낼지).
pub var any_recording = std.atomic.Value(bool).init(false);
/// `Network.enable` 의 번호 — 결과가 오면 켜짐을 알린다(본문 호출과 같은 대역). 탭마다 많아야 하나다. `Network.disable` 은 적지 않는다 —
/// 보낸 뒤 곧 관찰자를 놓아 그 결과는 오지 않는다(W9d② 적대 리뷰 1 회차 LOW-1: 적으면 자리가 새어, 서로 다른 탭 32 개를 끈 뒤로는 켬의 결과를
/// 짝지을 자리가 없어 maru 가 영영 `starting` 에 머물렀다). 관찰자를 놓을 때(끄기·닫힘) 그 탭의 자리를 비운다.
/// W9d③ 11 차(같은 꼴 점검): 답은 번호와 **그 답이 온 브라우저**(`cef_id`)로 짝짓는다 — 번호는 본문 호출과 나누는 대역에서 돌고, 이 자리는 답이
/// 오거나 관찰자를 놓을 때까지 남는다(죽은 채 되살리지 않은 탭의 켬). 번호만 보면 한 바퀴 돈 남의 답이 그 탭에 켬·실패를 알릴 수 있었다(코드 읽기 — 대역 256 Mi 라 재지 않았다).
var control_ids: [registry_mod.capacity]struct { id: i32 = 0, cef_id: c_int = 0, browser: BrowserId = 0, session: u32 = 0 } = @splat(.{});

const tick_ms: i64 = 50;

extern "c" fn mach_absolute_time() u64;
const Timebase = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *Timebase) c_int;
var timebase: Timebase = .{ .numer = 0, .denom = 0 };

/// mach_absolute_time 의 µs(CDP `timestamp` 와 같은 시계 — J1). 어느 스레드에서나.
pub fn machUs() i64 {
    if (@atomicLoad(u32, &timebase.denom, .acquire) == 0) {
        var tb: Timebase = undefined;
        _ = mach_timebase_info(&tb);
        @atomicStore(u32, &timebase.numer, tb.numer, .release);
        @atomicStore(u32, &timebase.denom, tb.denom, .release);
    }
    const numer = @atomicLoad(u32, &timebase.numer, .acquire);
    const denom = @atomicLoad(u32, &timebase.denom, .acquire);
    return @intCast(@as(u128, mach_absolute_time()) * numer / denom / 1000);
}

/// 판정자 전용 진단(`MARU_WEB_TEST_BODY_LOG`) — 맞추기의 사건을 stderr 에 한 줄씩. 제품에서는 켜지 않는다(UI 스레드에서 이벤트마다 쓰면 느려진다 — J7).
var debug_log = false;
/// 판정자 진단(`MARU_WEB_TEST_SW_NOTES`) — 서비스 워커 잇기의 까닭 줄만(사건마다의 줄 없이 — 시각을 바꾸지 않게).
var sw_note_log = false;
/// 재검증 8 차(R-1) 판정자 전용(`MARU_WEB_TEST_SW_LOSE=<글>`): 응답 주소에 그 글이 든 워커 응답(`Network.responseReceived`)을 표에 주지 않는다 —
/// 그 W 의 시작 사건이 HEAD 나 `Range` 를 실었으면 준다. 실측의 「워커 W 응답을 눈먼 때 밖에서도 잃는다」(7 실행 중 1)를 판정 `v20n-r1h` 가 판마다
/// 내게 한다(GET W 를 잃고 τ 를 나눈 HEAD·Range W 만 보인다). 제품에서는 켜지 않는다.
var test_lose: []const u8 = "";
var test_lose_keep: [64]u64 = @splat(0);
var test_lose_next: usize = 0;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (!debug_log) return;
    std.debug.print("body: " ++ fmt ++ "\n", args);
}

fn init() void {
    if (ready) return;
    ready = true;
    debug_log = std.c.getenv("MARU_WEB_TEST_BODY_LOG") != null;
    sw_note_log = std.c.getenv("MARU_WEB_TEST_SW_NOTES") != null;
    if (std.c.getenv("MARU_WEB_TEST_SW_LOSE")) |v| test_lose = std.mem.span(v);
    if (std.c.getenv("MARU_WEB_SW_CDP")) |v| sw_cdp = !std.mem.eql(u8, std.mem.span(v), "0");
    if (std.c.getenv("MARU_WEB_SW_WAIT")) |v| sw_wait = !std.mem.eql(u8, std.mem.span(v), "0");
    if (std.c.getenv("MARU_WEB_SW_WAIT_FILTER")) |v| {
        const f = std.mem.span(v);
        sw_wait_filter = if (std.mem.eql(u8, f, "none")) .none else if (std.mem.eql(u8, f, "sw")) .sw else .swdw;
    }
    test_norelease = std.c.getenv("MARU_WEB_TEST_SW_NORELEASE") != null;
    if (std.c.getenv("MARU_WEB_SW_WAIT_STOPDETACH")) |v| stop_detach = !std.mem.eql(u8, std.mem.span(v), "0");
    test_noreply = std.c.getenv("MARU_WEB_TEST_SW_NOREPLY") != null;
    if (std.c.getenv("MARU_WEB_SW_KEEP")) |v| sw.keep_visited = !std.mem.eql(u8, std.mem.span(v), "0");
    if (std.c.getenv("MARU_WEB_TEST_SW_PEND_MS")) |v| pend_timeout_us = (std.fmt.parseInt(i64, std.mem.span(v), 10) catch 30_000) * 1000;
    // 재검증 5 차 S3: 워커 세션을 붙이면 서비스 워커 갈래 기록의 쌍둥이는 워커 W 다. 본문을 잇는 것(S3b)은 `sw_link`.
    table.sw_twin_worker = sw_cdp;
    table.sw_link_body = sw_cdp and sw_link;
    observer = object.zeroed(c.cef_dev_tools_message_observer_t);
    object.staticRefCounted(&observer.base);
    observer.on_dev_tools_message = &onRaw;
    observer.on_dev_tools_event = &onEvent;
    observer.on_dev_tools_method_result = &onResult;
    observer.on_dev_tools_agent_detached = &onDetached;
    tick_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&tick_task.base);
    tick_task.execute = &tick;
    sw_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&sw_task.base);
    sw_task.execute = &swFlush;
    foreign_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&foreign_task.base);
    foreign_task.execute = &foreignCheck;
    rescue_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&rescue_task.base);
    rescue_task.execute = &rescueTick;
    pend_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&pend_task.base);
    pend_task.execute = &pendCheck;
}

fn api() *const library.Api {
    return browsers.state.api;
}

fn writer() *events.Writer {
    return browsers.state.writer;
}

fn refreshAny() void {
    any_recording.store(table.anyRecording(), .release);
}

/// 기록하는 탭인가(UI 스레드 — `network.zig` 가 `body_expected` 를 정할 때).
pub fn recording(browser: BrowserId) bool {
    return table.recording(browser);
}

// ── maru 의 명령 ──────────────────────────────────────────────────────────────────────────────────────────

/// `net_record` — 켜면 그 탭에 관찰자를 달고 `Network.enable`, 끄면 `Network.disable` 과 기다리던 본문의 `recording_stopped`.
pub fn record(v: msg.NetRecord) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse {
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = v.session, .status = if (v.on) .failed else .off } }) catch {};
        return;
    };
    if (!v.on) {
        const was = table.tabOf(v.browser) != null;
        table.stop(gpa, v.browser) catch {};
        runActions();
        // W9d③: Network 도메인은 엄격 모드와 나눈다 — 끄기는 `net_domain` 이 정한다(엄격이 있으면 disable 대신 가벼운 enable). 워커 세션 떼기
        // (위 `runActions` 의 `.detach_workers` — 줄에 넣어 다음 UI task 에서 보낸다)와의 차례는 W9d② 그대로다(페이지 세션의 끔이 먼저 나간다).
        if (was) @import("blocking.zig").recordingOff(entry);
        // 재검증 12 차: 워커를 멈춰 붙였으면 관찰자를 남긴다 — `setAutoAttach{autoAttach:false}` 가 닿기 전에 멈춰 붙은 워커의 알림을 받아 놓아야
        // 한다(놓지 않으면 영영 멈춘다 — 실측 `swwait-offrace`). 탭이 닫힐 때 놓는다(`browserClosed`). W9d③ 의 엄격 명령은 제 관찰자(`blocking`)로 답을 받는다.
        if (!sw_wait) unregister(entry.cef_id);
        clearControl(v.browser);
        refreshAny();
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = 0, .status = .off } }) catch {};
        return;
    }
    const ok = table.start(gpa, v.browser, v.session) catch false;
    // 재검증 6 차 D1: 이 세션의 시작 — 그 앞의 IO 시각의 기록은 적지 않고 그 앞에 시작한 워커 W 는 맞추기에 넣지 않는다(기록 전에 나간 fetch 가
    // 기록 뒤 같은 주소 fetch 의 기록을 가져갔다). 재검증 7 차(E1): IO 스레드가 주소 해시를 내게(`any_recording`) **먼저** 켜고 그 뒤에 잰다 —
    // 전에는 반대라 그 사이 IO 의 기록은 해시 없이 표에 들지 않는데 경계 뒤에 시작한 W 는 맞추기에 들어, 제 기록이 없는 W 가 같은 주소의 남의
    // 기록을 가져갔다. 켜기 전에 해시 없이 읽고 경계 뒤에 상자에 든 기록(IO 스레드가 그 사이 밀렸다)의 W 는 시작 사건이 경계 앞이라 맞추기에
    // 들지 않고, 시작을 잃은 W 는 짝을 맺지 않는다(`net_body_table.tryDecide`).
    if (ok) {
        refreshAny();
        table.markStarted(v.browser, machUs());
    }
    runActions();
    if (!ok or !register(entry)) {
        clearControl(v.browser);
        table.stop(gpa, v.browser) catch {};
        runActions();
        refreshAny();
        writer().send(.{ .net_record_state = .{ .browser = v.browser, .session = v.session, .status = .failed } }) catch {};
        return;
    }
    refreshAny();
    // 재검증 5 차 S3(C3a): 이 기록이 보는 응답은 켠 뒤의 것 — 벽시계로 적는다(붙는 워커 세션마다 다시 올린다).
    table.link.raiseVisible(v.browser, wallUs());
    sendCdp(entry, "Network.enable", "{\"maxResourceBufferSize\":2097152,\"maxTotalBufferSize\":8388608,\"maxPostDataSize\":1}", v.browser, v.session, true);
    @import("blocking.zig").recordingOn(entry); // W9d③: 도메인의 주인에게 알린다(엄격과 나눈다)
    ensureTick();
}

/// 렌더러가 죽었다(`on_render_process_terminated` — `renderer_gone` 보다 먼저). 보낸 호출은 답이 없다(J5) — 곧 `detached`.
pub fn rendererGone(browser: BrowserId) void {
    table.rendererGone(gpa, browser, machUs()) catch {};
    runActions();
}

/// 브라우저가 닫힌다(`browser_closed` 보다 먼저) — 기다리던 본문은 `detached`, 등록을 놓는다.
pub fn browserClosed(cef_id: c_int, browser: BrowserId) void {
    table.forgetTop(browser);
    @import("blocking.zig").recordingGone(cef_id); // W9d③: 기록 몫만 내린다(엄격은 그 탭의 `on_before_close` 에서 함께 빠진다)
    table.closed(gpa, browser) catch {};
    runActions();
    // 재검증 6 차(F16 과 같은 꼴): 기록을 끈 뒤 닫힌 탭은 표에 없어 닫힘의 떼기 일(`.detach_workers` closed)이 오지 않는다 — 서비스 워커 표의
    // 자리(세대)를 여기서 비운다(남으면 32 번 뒤 새 탭에 붙이기를 걸지 못했다). 재검증 12 차: 놓기 답을 기다리던 세션은 건진다.
    pendClosed(browser);
    sw.forget(browser);
    unregister(cef_id);
    clearControl(browser);
    refreshAny();
}

// ── CEF 쪽(network.zig 의 보내는 task — UI 스레드) ────────────────────────────────────────────────────────

/// 기록하는 탭의 CEF 시작 — 후보로 적었으면 참(`body_expected`).
pub fn cefBegin(browser: BrowserId, cand: table_mod.Candidate) bool {
    const ok = table.cefBegin(gpa, browser, cand) catch false;
    dbg("cef-begin b={d} req={d} url={x} m={x} sw={} t={d} ok={}", .{ browser, cand.request, cand.key.url, cand.key.method, cand.key.sw, cand.t_io_us, ok });
    runActions();
    if (ok) ensureTick();
    return ok;
}

/// CEF 리다이렉트 — 설정이 꺼졌으면(`pending`) 응답 호스트가 다시 정해질 때까지 본문을 받으러 가지 않는다(W9d② 적대 리뷰 1 회차 MED-1).
pub fn cefRedirect(browser: BrowserId, request: u64, pending: bool) void {
    dbg("cef-redirect b={d} req={d} pending={}", .{ browser, request, pending });
    table.cefRedirect(browser, request, pending);
}

/// CEF 응답 — 설정이 꺼졌을 때 응답 호스트가 덮이는가(`net_response` 헤더와 같은 결정).
pub fn cefCovered(browser: BrowserId, request: u64, covered: bool, status: u16) void {
    dbg("cef-response b={d} req={d} covered={} status={d}", .{ browser, request, covered, status });
    table.cefCovered(browser, request, covered);
    table.cefStatus(browser, request, status); // 재검증 8 차(R-1): 서비스 워커 갈래 기록에 P 를 이을 때 상태를 견준다
}

/// CEF 끝 — `ok` 는 CEF 가 성공으로 끝냈는가(W9d② 적대 리뷰 3 회차 P5: 취소·실패로 끝난 기록은 성공한 CDP 요청의 짝이 아니다), `received` 는
/// 받은 바이트(4 회차 N1 — CDP 의 빈 본문이 정말 0 바이트였는가).
pub fn cefEnd(browser: BrowserId, request: u64, ok: bool, received: u64) void {
    dbg("cef-end b={d} req={d} ok={} received={d} t={d}", .{ browser, request, ok, received, machUs() });
    table.cefEndReceived(browser, request, machUs(), ok, received);
    ensureTick();
}

/// 재검증 8 차: `net_watch` 끔(`network.watch`) — 그 탭이 기록 중이면 그 때부터 서비스 워커 본문을 잇지 않는다(`Table.watchOff`). maru 는 기록을
/// 먼저 끄고 지켜보기를 끄니 지금은 닿지 않는다(막아 둔다).
pub fn watchOff(browser: BrowserId) void {
    if (!ready) return;
    if (!table.recording(browser)) return;
    table.watchOff(browser, machUs());
    dbg("watch-off-while-recording b={d}", .{browser});
}

/// 주 프레임에 새 문서가 시작됐다(`network.documentStarted` — UI 스레드). W9d② 20 회 검증 N1: 앞 문서와 함께 끊긴 요청은 CDP 끝이 오지 않는다 —
/// 표가 그 후보를 곧 `unavailable` 로 끝낸다(주기 task 가 돌고 있으면 — 후보가 있으면 돈다).
/// 재검증 5 차 S1: 렌더러가 죽어 서비스 워커 세션을 뗐으면(기록은 이어진다 — J5) 새 문서에서 다시 건다.
pub fn documentStarted(browser: BrowserId) void {
    dbg("doc-start b={d} t={d}", .{ browser, machUs() });
    table.documentStarted(browser, machUs());
    if (sw_cdp and table.recording(browser) and sw.takeRearm(browser)) armWorkers(browser);
}

/// `network.zig` 의 보내는 task 가 상자를 비웠다 — CEF 기록이 IO 시각 `seen_us` 까지 모두 표에 닿았다(W9d② 적대 리뷰 3 회차 P1). 제 기록을
/// 기다리던 CDP 끝을 곧 정한다(주기 task 의 50 ms 를 기다리지 않는다).
pub fn cefFlushed(seen_us: i64) void {
    if (!table.busy()) {
        table.cef_seen_us = @max(table.cef_seen_us, seen_us);
        return;
    }
    table.cefSeen(gpa, seen_us, machUs()) catch {};
    runActions();
    ensureTick();
}

pub fn noteDrop(browser: BrowserId, url_hash: u64, t_us: i64) void {
    table.noteDrop(browser, url_hash, t_us);
}

/// 재검증 5 차 (B): `sw_cap` 이면 서비스 워커 몫이 차서 넘긴 것 — 그 창의 같은 주소 짝만 모호하게(탭 전체를 어둠으로 치지 않는다).
pub fn noteDropKind(browser: BrowserId, url_hash: u64, t_us: i64, sw_cap: bool) void {
    table.noteDropKind(browser, url_hash, t_us, sw_cap);
}

pub fn noteDropOverflow(browser: BrowserId, t_us: i64) void {
    table.noteDropOverflow(browser, t_us);
}

/// W9d② 적대 리뷰 5 회차 C1: 넘김 상자가 넘쳐 이 요청의 리다이렉트·응답·끝이 버려졌다 — 짝 없는 후보는 끝난 것·결과를 모르는 것으로(시한 뒤 `unmatched`,
/// 짝이 되면 `ambiguous`).
pub fn cefLost(browser: BrowserId, request: u64) void {
    cefLostWhy(browser, request, false);
}

/// 재검증 11 차(LOW-J′ — 진단): `evicted` 면 서비스 워커 갈래 자리를 비워 잃었다(`net_gate.evictOrphan` — 판정 `v20o-r12rec` 가 넘김 상자 넘침과 가른다).
pub fn cefLostWhy(browser: BrowserId, request: u64, evicted: bool) void {
    dbg("cef-lost b={d} req={d}{s}", .{ browser, request, if (evicted) " orphan-evicted" else "" });
    table.cefLost(browser, request, machUs());
    ensureTick();
}

/// 표지 자리도 넘쳤다 — 그 탭의 짝 없는 후보 모두.
pub fn cefLostAll(browser: BrowserId) void {
    dbg("cef-lost-all b={d}", .{browser});
    table.cefLostAll(browser, machUs());
    ensureTick();
}

// ── 관찰자 ────────────────────────────────────────────────────────────────────────────────────────────────

fn register(entry: *const registry_mod.Entry) bool {
    for (registrations) |r| if (r) |v| if (v.cef_id == entry.cef_id) return true;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = browser.*.get_host.?(browser);
    if (host == null) return false;
    defer object.release(host);
    for (&registrations) |*r| if (r.* == null) {
        const reg = host.*.add_dev_tools_message_observer.?(host, &observer);
        if (reg == null) return false;
        r.* = .{ .cef_id = entry.cef_id, .browser = entry.id, .reg = reg };
        return true;
    };
    return false;
}

fn unregister(cef_id: c_int) void {
    for (&registrations) |*r| if (r.*) |v| if (v.cef_id == cef_id) {
        object.release(v.reg);
        r.* = null;
    };
}

fn browserOfCef(cef_id: c_int) ?BrowserId {
    for (registrations) |r| if (r) |v| if (v.cef_id == cef_id) return v.browser;
    return null;
}

fn nextId() i32 {
    // 본문 호출과 같은 대역을 쓴다(표가 매기는 번호와 겹치지 않게 표의 차례를 함께 쓴다).
    const id = table.next_id;
    table.next_id = if (table.next_id + 1 >= table_mod.id_end) table_mod.id_base else table.next_id + 1;
    return id;
}

fn sendCdp(entry: *const registry_mod.Entry, method: []const u8, params: []const u8, browser: BrowserId, session: u32, enable: bool) void {
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = b.*.get_host.?(b);
    if (host == null) return;
    defer object.release(host);
    const id = nextId();
    var jb: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }) catch return;
    // 켬의 결과만 짝짓는다(LOW-1 — 끄기의 결과는 관찰자를 놓아 오지 않는다). 그 탭의 앞 켬 자리는 덮는다(다시 켬 — 앞 세션의 결과는 버린다).
    if (enable) {
        const slot = for (&control_ids) |*sl| {
            if (sl.browser == browser) break sl;
        } else for (&control_ids) |*sl| {
            if (sl.id == 0) break sl;
        } else null;
        if (slot) |sl| sl.* = .{ .id = id, .cef_id = entry.cef_id, .browser = browser, .session = session };
    }
    _ = host.*.send_dev_tools_message.?(host, json.ptr, json.len);
}

/// 그 탭의 켬 자리를 비운다(관찰자를 놓았다 — 결과가 오지 않는다).
fn clearControl(browser: BrowserId) void {
    for (&control_ids) |*slot| if (slot.browser == browser) {
        slot.* = .{};
    };
}

fn onEvent(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, method_s: [*c]const c.cef_string_t, params: ?*const anyopaque, params_size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const id = browserOfCef(browser.*.get_identifier.?(browser)) orelse return;
    var mb: [64]u8 = undefined;
    const method = library.readString(api(), method_s, &mb);
    // 재검증 5 차 S1: 페이지 세션의 Target 사건(서비스 워커 세션이 붙고 떨어진다) — 기록이 멈춘(밸브) 탭에 온 것도 본다(곧 뗀다).
    if (std.mem.startsWith(u8, method, "Target.")) {
        const p: []const u8 = if (params != null) @as([*]const u8, @ptrCast(params.?))[0..params_size] else "";
        onTarget(id, method, p);
        return;
    }
    if (!table.recording(id)) return;
    if (!std.mem.startsWith(u8, method, "Network.")) return; // Page.* 도 온다(권한이 Page.enable 을 건다 — J7)
    const p: []const u8 = if (params != null) @as([*]const u8, @ptrCast(params.?))[0..params_size] else "";
    const now = machUs();
    if (std.mem.eql(u8, method, "Network.dataReceived")) {
        table.cdpEvent(gpa, id, table_mod.scanData(p), now) catch {};
    } else if (table_mod.wanted(method)) {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, p, .{}) catch {
            table.cdpEvent(gpa, id, null, now) catch {};
            runActions();
            return;
        };
        defer parsed.deinit();
        const ev = table_mod.parseEvent(method, parsed.value);
        // P1: 끝이면 지금의 물 높이를 먼저 올린다 — 상자가 비었으면 곧 정하고, 아니면 다음 flush(`cefFlushed`)가 정한다.
        if (ev) |e| switch (e) {
            .finished, .failed => table.cef_seen_us = @max(table.cef_seen_us, network.cefWatermark()),
            else => {},
        };
        if (debug_log) if (ev) |e| switch (e) {
            .will_be_sent => |v| dbg("cdp-sent rid={s} url={x} m={x} ts={d} redirect={} now={d}", .{ v.rid, v.url_hash, v.method_hash, v.ts_us, v.redirect, now }),
            .response => |v| dbg("cdp-resp rid={s} mime={s} sw={} src={s} now={d}", .{ v.rid, v.mime, v.from_sw, v.sw_source, now }),
            .finished => |v| dbg("cdp-fin rid={s} now={d} seen={d}", .{ v.rid, now, table.cef_seen_us }),
            // W9d② 적대 리뷰 5 회차 A1: CDP loadingFailed 의 timestamp(µs — `Cdp.failed_at`)를 UI 가 받은 때(now)와 견준다(시각만 — 본문은 싣지 않는다).
            .failed => |v| dbg("cdp-fail rid={s} now={d} seen={d} cdp_ts={d}", .{ v.rid, now, table.cef_seen_us, v.ts_us }),
            .from_cache => |v| dbg("cdp-cache rid={s}", .{v.rid}),
            else => {},
        } else dbg("cdp-unparsed {s}", .{method});
        table.cdpEvent(gpa, id, ev, now) catch {};
    } else {
        table.cdpEvent(gpa, id, null, now) catch {}; // 쏟아짐만 센다
    }
    runActions();
    ensureTick();
}

fn onResult(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, id: c_int, success: c_int, result: ?*const anyopaque, size: usize) callconv(.c) void {
    defer object.releaseArg(browser);
    if (id < table_mod.id_base or id >= table_mod.id_end) return; // 다른 사용처(devtools·권한·알림·미디어)의 결과
    // 브라우저를 모르면 켬의 짝으로 치지 않는다(CEF 번호는 1 부터 — 0 은 어느 자리와도 맞지 않는다); 본문 호출의 답은 아래 그대로 찾는다.
    const cef_id: c_int = if (browser != null) browser.*.get_identifier.?(browser) else 0;
    for (&control_ids) |*slot| if (slot.id == id and slot.cef_id == cef_id) {
        const s = slot.*;
        slot.* = .{};
        // 켬의 답 — 그 사이 끄거나 다시 켜지 않았을 때만 알린다.
        const t = table.tabOf(s.browser);
        if (t != null and t.?.session == s.session) {
            writer().send(.{ .net_record_state = .{ .browser = s.browser, .session = s.session, .status = if (success != 0) .on else .failed } }) catch {};
            if (success == 0) {
                // W9d③ 9 차: 렌더러 쪽 도메인을 모른다(렌더러가 죽은 동안 보낸 켬은 새 렌더러가 붙을 때 실패로 답하는데, 새 렌더러는 죽기 전
                // 상태를 되받는다) — 기록 몫을 내리고 바라는 상태를 명시해 보낸다(`blocking.recordingFailed`).
                if (browsers.state.registry.byId(s.browser)) |e| @import("blocking.zig").recordingFailed(e);
                table.stop(gpa, s.browser) catch {};
                runActions();
                refreshAny();
            } else if (sw_cdp and t.?.recording()) {
                // 재검증 5 차 S1(공격 2 A1): auto-attach 는 켬의 **성공 답 뒤에만** — 켬이 실패하면 걸지 않는다.
                armWorkers(s.browser);
            }
        }
        return;
    };
    dbg("result id={d} ok={} size={d}", .{ id, success, size });
    // 재검증 12 차: 건지기의 붙이기가 실패했다(그 타깃이 없다 — 이미 끝났다) — 지운다.
    if (success == 0 and sw.rescueFailed(id)) return;
    const f = table.takeInflight(id) orelse return; // 끄거나 다시 켠 뒤의 늦은 답(세대)
    const bytes: []const u8 = if (result != null) @as([*]const u8, @ptrCast(result.?))[0..size] else "";
    sendBody(f, success != 0, bytes);
    table.bodyDone(gpa, f, machUs()) catch {};
    runActions();
}

fn onDetached(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const id = browserOfCef(browser.*.get_identifier.?(browser)) orelse return;
    @import("blocking.zig").recordingGone(browser.*.get_identifier.?(browser)); // W9d③: 기록 몫만 내린다(엄격은 그대로)
    // DevTools 가 떨어졌다 — 보낸 호출의 답은 오지 않는다. 기록은 다시 켜야 한다(이벤트가 끊겼다) — maru 에 알린다.
    const session = if (table.tabOf(id)) |t| t.session else 0;
    table.closed(gpa, id) catch {};
    runActions();
    refreshAny();
    if (session != 0) writer().send(.{ .net_record_state = .{ .browser = id, .session = session, .status = .failed } }) catch {};
}

/// 받은 결과를 풀어 보낸다 — 잡았으면 조각들과 끝(보내는 줄에 자리가 없으면 `busy`), 아니면 끝 하나.
fn sendBody(f: table_mod.Inflight, ok: bool, json: []const u8) void {
    var flags: msg.NetBodyFlags = .{ .credentialed = f.credentialed };
    var d = table_mod.decodeResult(gpa, ok, json, f.mimeSlice(), f.charset, f.decoded, f.res_kind) catch table_mod.Decoded{ .state = .busy };
    d.state = table.emptyBodyState(f, d.state); // 4 회차 N1: 빈 본문인데 CEF 는 바이트를 받았다 — `unavailable`
    defer if (d.bytes.len > 0) gpa.free(d.bytes);
    // 넘쳤으면 넘친 글의 크기까지(windows-1252 로 푼 글은 받은 바이트보다 클 수 있다 — 상태와 크기가 엇갈리지 않게).
    const end: msg.NetBodyEnd = .{ .browser = f.browser, .session = f.session, .request = f.request, .state = d.state, .flags = flags, .decoded = @max(f.decoded, d.over_bytes) };
    if (d.state != .captured) return writer().send(.{ .net_body_end = end }) catch {};
    const total = events.bodyFrameBytes(d.bytes.len);
    if (!writer().reserveBody(total)) {
        var busy = end;
        busy.state = .busy;
        return writer().send(.{ .net_body_end = busy }) catch {};
    }
    // 쓰지 못한 몫은 돌려준다(관이 닫혀 중간에 그만뒀다).
    var used: usize = 0;
    defer writer().releaseBody(total -| used);
    var off: usize = 0;
    while (off < d.bytes.len) {
        const k = @min(msg.net_body_chunk_bytes, d.bytes.len - off);
        writer().sendBody(.{ .net_body_data = .{ .browser = f.browser, .session = f.session, .request = f.request, .offset = @intCast(off), .bytes = d.bytes[off..][0..k] } }) catch return;
        used += events.body_data_head_bytes + k;
        off += k;
    }
    flags.binary = d.flags.binary;
    flags.redecoded = d.flags.redecoded;
    flags.chromium_decoded = d.flags.chromium_decoded;
    var done = end;
    done.flags = flags;
    done.size = @intCast(d.bytes.len);
    writer().sendBody(.{ .net_body_end = done }) catch return;
    used = total;
}

// ── 일 하기 ───────────────────────────────────────────────────────────────────────────────────────────────

/// 표가 쌓은 일을 한다 — 일이 새 일을 쌓으면(보내지 못한 호출의 끝 → 다음 기다림) 빌 때까지 되풀이한다.
fn runActions() void {
    var list: std.ArrayList(table_mod.Action) = .empty;
    defer list.deinit(gpa);
    while (true) {
        table.swapActions(&list);
        if (list.items.len == 0) return;
        for (list.items) |a| switch (a) {
            .detach_workers => |d| detachWorkers(d.browser, d.why),
            .sw_paired => |p| if (debug_log or sw_note_log) std.debug.print("body: sw-pair b={d} req={d} wrid={s}\n", .{ p.browser, p.request, p.wrid.slice() }),
            .sw_note => |p| if (debug_log or sw_note_log) std.debug.print("body: sw-note b={d} req={d} prid={s} reason={s}\n", .{ p.browser, p.request, p.prid.slice(), @tagName(p.reason) }),
            .end => |e| {
                dbg("end req={d} state={s}", .{ e.request, @tagName(e.state) });
                writer().send(.{ .net_body_end = .{ .browser = e.browser, .session = e.session, .request = e.request, .state = e.state, .flags = e.flags, .decoded = e.decoded } }) catch {};
            },
            .fetch => |f| {
                dbg("fetch id={d} rid={s}", .{ f.id, f.rid.slice() });
                fetch(f.browser, f.id, f.rid.slice());
            },
            .pause => |p| {
                // 쏟아짐 밸브(J7) — 이벤트를 끈다(관찰자는 남긴다 — 콜백 안이다). maru 가 다시 켜야 풀린다.
                // W9d③: 엄격 모드가 도메인을 쥐고 있으면 끄지 않는다(기록만 멈춘다 — 엄격이 말없이 꺼지지 않게, `net_domain`).
                if (browsers.state.registry.byId(p.browser)) |entry| @import("blocking.zig").recordingOff(entry);
                refreshAny();
                writer().send(.{ .net_record_state = .{ .browser = p.browser, .session = p.session, .status = .paused } }) catch {};
            },
        };
        list.clearRetainingCapacity();
    }
}

/// `Network.getResponseBody` 를 보낸다. 요청 번호는 CDP 가 준 글이라 JSON 에 그대로 넣을 수 있는 글자만 받는다(아니면 그 호출은 `unavailable`).
fn fetch(browser: BrowserId, id: i32, rid: []const u8) void {
    const safe = for (rid) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-' and ch != '_') break false;
    } else rid.len > 0;
    const entry = browsers.state.registry.byId(browser);
    if (!safe or entry == null) return failFetch(id);
    const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.?.handle));
    const host = b.*.get_host.?(b);
    if (host == null) return failFetch(id);
    defer object.release(host);
    var jb: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&jb, "{{\"id\":{d},\"method\":\"Network.getResponseBody\",\"params\":{{\"requestId\":\"{s}\"}}}}", .{ id, rid }) catch return failFetch(id);
    if (host.*.send_dev_tools_message.?(host, json.ptr, json.len) == 0) failFetch(id);
}

fn failFetch(id: i32) void {
    const f = table.takeInflight(id) orelse return;
    sendBody(f, false, "");
    table.bodyDone(gpa, f, machUs()) catch {}; // 새 일은 부른 `runActions` 의 다음 바퀴가 한다
}

fn ensureTick() void {
    if (tick_posted or !table.busy()) return;
    tick_posted = api().post_delayed_task(c.TID_UI, &tick_task, tick_ms) != 0;
}

fn tick(_: [*c]c.cef_task_t) callconv(.c) void {
    tick_posted = false;
    dbg("tick", .{});
    table.tickAt(gpa, machUs(), network.cefWatermark()) catch {};
    runActions();
    ensureTick();
}

// ── 재검증 5 차 S1: 서비스 워커 세션(계획 「서비스 워커 갈래 새 설계」) ─────────────────────────────────────────────────

/// 벽시계 µs(`responseTime` 과 같은 시계 — C3a 는 벽시계끼리만 견준다).
fn wallUs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}

/// 그 탭의 페이지 세션에 서비스 워커 auto-attach 를 건다(걸었으면 다시 보내지 않는다).
fn armWorkers(browser: BrowserId) void {
    if (browsers.state.registry.byId(browser) == null) return;
    if (!sw.arm(browser)) return;
    dbg("sw-arm b={d} wait={}", .{ browser, sw_wait });
    _ = autoAttach(browser, sw_wait);
}

/// `Target.setAutoAttach{autoAttach:true}` — `wait` 면 새로 뜨는 타깃을 멈춰 붙인다. 재검증 12 차: filter 는 서비스 워커와 전용 워커(`worker`) —
/// 멈춤은 렌더러가 filter 를 모른 채 자식 전용 워커마다 건다(filter 로 뺀 전용 워커도 멈추고 붙지 않아 놓을 길이 없다 — 옛 PHASE0 b f1·f5, Chromium
/// `RendererAutoAttacherBase` 는 `wait_for_debugger` 만 넘긴다). 그래서 전용 워커도 붙여 곧 놓고 뗀다.
fn autoAttach(browser: BrowserId, wait: bool) i32 {
    const filter = switch (sw_wait_filter) {
        .sw => ",\"filter\":[{\"type\":\"service_worker\",\"exclude\":false},{\"exclude\":true}]",
        .swdw => ",\"filter\":[{\"type\":\"service_worker\",\"exclude\":false},{\"type\":\"worker\",\"exclude\":false},{\"exclude\":true}]",
        .none => "",
    };
    var pb: [400]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"autoAttach\":true,\"waitForDebuggerOnStart\":{},\"flatten\":true{s}}}", .{ wait, filter }) catch return 0;
    return swQueue(browser, null, "Target.setAutoAttach", params);
}

/// 표의 `.detach_workers` — 그 탭의 서비스 워커 세션을 모두 떼고 세대를 올린다. 걸려 있었으면 `setAutoAttach{autoAttach:false}`(실측: 답보다
/// 먼저 붙은 세션마다 `detachedFromTarget` 이 오고 +28 초에 워커가 멈췄다). 닫힘·DevTools 떨어짐은 보낼 곳이 없다. 렌더러 죽음은 새 문서에서
/// 다시 건다(`documentStarted`).
fn detachWorkers(browser: BrowserId, why: table_mod.DetachWhy) void {
    // 재검증 12 차: 손으로 붙인 세션(다녀간 출처의 붙여 두기·건지기)은 `setAutoAttach{autoAttach:false}` 가 떼지 않는다 — 여기서 뗀다(놓기 답을 기다리면
    // 그 뒤에). auto 세션도 하나하나 뗀다: Chromium 은 한 세션을 뗄 때 그 워커의 auto 목록 자리를 지워(같은 워커에 손 세션과 auto 세션이 함께 붙었다가
    // 손 세션을 떼면 auto 세션이 목록 밖에 남는다) `autoAttach:false` 가 그 auto 세션을 떼지 않았다(회귀 `v20l-r15-race`·`r16-toggle` — 끈 뒤 SW 가
    // 멈추지 않았다). 닫힘은 보낼 곳이 없다.
    if (why != .closed) {
        for (sw.sessions) |x| if (x.browser == browser) {
            if (!sw.pendMarkDetach(x.sidSlice())) detachSession(browser, x.sidSlice());
        };
        for (sw.parked) |x| if (x.browser == browser) {
            const ps = x.sid[0..x.sid_len];
            if (!sw.pendMarkDetach(ps)) detachSession(browser, ps);
        };
    }
    const was = sw.detachAll(browser);
    dbg("sw-detach b={d} why={s} armed={}", .{ browser, @tagName(why), was });
    if (why == .renderer_gone and was) sw.setRearm(browser);
    if (why == .closed) {
        pendClosed(browser);
        sw.forget(browser);
        return;
    }
    if (!was) return;
    // 재검증 12 차: 놓기 답을 기다리던 세션도 함께 떨어진다 — 그 떨어짐(`detachedFromTarget` — 관찰자는 남아 있다)에 그 워커를 건진다(`pendFinished`).
    // 떼기를 미루지 않는다: 미루는 동안 다시 켜면 붙은 채 남은 옛 세대 세션은 다시 알려지지 않아 그 워커가 보이지 않았다.
    _ = swQueue(browser, null, "Target.setAutoAttach", "{\"autoAttach\":false,\"waitForDebuggerOnStart\":false}");
}

/// 재검증 12 차: 멈춰 붙은 세션을 놓는다(`Runtime.runIfWaitingForDebugger` — 그 세션의 앞 명령(`Network.enable`) 뒤에 차례로 닿는다: 그 세션의 메시지는
/// 차례대로 풀리고, 워커는 그 세션이 놓을 때까지 스크립트를 돌리지 않는다). `detach` 면 그 답 뒤에 뗀다(답 앞에 떼면 워커의 DevTools 쪽이 아직
/// 서지 않았을 때 영영 멈출 수 있다 — Playwright `CRSession.detach`·Puppeteer `silentDetach` 의 차례). 답을 기다릴 자리가 없으면 곧 뗀다.
fn release(browser: BrowserId, sid: []const u8, target_id: []const u8, detach: bool) void {
    if (test_norelease) {
        if (detach) detachSession(browser, sid);
        return;
    }
    const id = sendSession(browser, sid, "Runtime.runIfWaitingForDebugger", "{}");
    dbg("sw-release b={d} sid={s} id={d} detach={}", .{ browser, sid, id, detach });
    if (!sw.pendAdd(browser, sid, target_id, id, machUs(), detach)) {
        if (detach) detachSession(browser, sid);
        return;
    }
    ensurePendCheck();
}

const PendEnd = enum { reply, detached, closed, timeout };

/// 놓기 답이 왔다 — 뗄 세션이면 뗀다. 답 앞에 세션이 사라졌다(떨어짐·탭 닫힘)·시한 — 그 워커를 건진다(다시 붙여 놓는다).
fn pendFinished(p: sw_mod.Pend, why: PendEnd) void {
    dbg("sw-release-done b={d} sid={s} why={s} after_us={d} detach={}", .{ p.browser, p.sidSlice(), @tagName(why), machUs() - p.since, p.detach });
    if (p.detach and (why == .reply or why == .timeout)) detachSession(p.browser, p.sidSlice());
    // 시한은 세션이 아직 붙어 있다(우리 세션이 그 워커를 쥔다 — 뗄 세션만 떼고 그 워커를 건진다; 남기는 세션은 그대로 둔다).
    if (why == .detached or why == .closed or (why == .timeout and p.detach)) {
        if (sw.rescueAdd(p.targetSlice(), if (why == .closed) 0 else p.browser, machUs())) ensureRescue();
    }
}

/// 재검증 12 차: 탭이 닫혔다·DevTools 가 떨어졌다 — 놓기 답을 기다리던 세션은 사라졌다(건진다).
fn pendClosed(browser: BrowserId) void {
    while (sw.pendOfBrowser(browser)) |p| pendFinished(p, .closed);
}

/// 재검증 12 차: 건지기 — 살아 있는 탭(먼저 그 탭)의 페이지 세션에서 그 타깃에 붙는다(그 붙음이 `onTarget` 에 오면 놓고 답 뒤에 뗀다). 붙인
/// 세션이 놓기 앞에 또 사라지면 다시 넣는다(같은 길).
var rescue_task: c.cef_task_t = undefined;
var rescue_posted = false;
/// 걸어 둔 건지기 task 가 돌 때(단조 µs) — 그보다 이른 건지기가 들어오면 하나 더 건다(task 는 되풀이해도 해가 없다).
var rescue_due_at: i64 = 0;

fn ensureRescue() void {
    const at = sw.nextRescue() orelse return;
    if (rescue_posted and at >= rescue_due_at) return;
    // 처음 해 보기는 곧(워커가 그만큼 멈춰 있다 — 실측 `swwait-offrace` p99 +304 ms 는 첫 해 보기를 사이만큼 미룬 탓이었다), 다시 해 보기는 사이 뒤.
    const now = machUs();
    const wait_ms = @divTrunc(@max(at - now, 0), 1000);
    if ((if (wait_ms == 0) api().post_task(c.TID_UI, &rescue_task) else api().post_delayed_task(c.TID_UI, &rescue_task, wait_ms)) != 0) {
        rescue_posted = true;
        rescue_due_at = @max(at, now);
    }
}

fn rescueTick(_: [*c]c.cef_task_t) callconv(.c) void {
    rescue_posted = false;
    while (sw.rescueDue(machUs())) |x| {
        const entry = rescuer(x.hint) orelse {
            x.tries -|= 1; // 탭이 하나도 없다 — 세지 않고 기다린다
            continue;
        };
        // 붙여 두기만(놓을 워커가 아니다)은 그 탭에서만 — 그 탭이 닫혔으면 버린다(다른 탭에 붙였다 떼면 그 탭의 auto 세션이 Chromium 의 auto 목록에서
        // 빠져 기록을 꺼도 떨어지지 않았다 — 회귀 `v20l-r15-race`). 재검증 13 차: 그 사이 그 탭의 기록이 끝났거나 다시 켰으면(세대가 올랐다) 버린다 —
        // 새 기록에서 맨 위였던 적 없는 출처의 세션을 다시 붙여 기록이 끝날 때까지 워커를 살려 두지 않게.
        if (!x.release and (entry.id != x.hint or !sw.keepCurrent(x.*))) {
            x.* = .{};
            continue;
        }
        if (!register(entry)) continue;
        var pb: [160]u8 = undefined;
        const params = std.fmt.bufPrint(&pb, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{x.targetSlice()}) catch continue;
        x.cmd_id = swQueue(entry.id, null, "Target.attachToTarget", params);
        dbg("sw-rescue b={d} target={s} try={d}", .{ entry.id, x.targetSlice(), x.tries });
    }
    ensureRescue();
}

fn rescuer(hint: BrowserId) ?*registry_mod.Entry {
    if (hint != 0) if (browsers.state.registry.byId(hint)) |e| if (!e.closing) return e;
    for (&browsers.state.registry.slots) |*slot| if (slot.*) |*e| if (!e.closing) return e;
    return null;
}

var pend_task: c.cef_task_t = undefined;
var pend_posted = false;

fn ensurePendCheck() void {
    if (pend_posted) return;
    const at = sw.nextPend() orelse return;
    const wait_ms = @divTrunc(@max(at + pend_timeout_us - machUs(), 0), 1000) + 1;
    pend_posted = api().post_delayed_task(c.TID_UI, &pend_task, wait_ms) != 0;
}

fn pendCheck(_: [*c]c.cef_task_t) callconv(.c) void {
    pend_posted = false;
    const now = machUs();
    while (sw.pendExpired(now, pend_timeout_us)) |p| pendFinished(p, .timeout);
    ensurePendCheck();
}

/// 세션 하나에 명령을 보낸다(번호는 본문 호출과 같은 대역 — 답은 원시 관찰자로 온다).
fn sendSession(browser: BrowserId, sid: []const u8, method: []const u8, params: []const u8) i32 {
    return swQueue(browser, sid, method, params);
}

/// 재검증 5 차 S3b: Target 도메인과 워커 세션의 명령은 바로 보내지 않고 줄에 넣어 다음 UI task 에서 보낸다. Target 은 브라우저 쪽 처리기라
/// 답·사건(`attachedToTarget`·`detachedFromTarget`)을 보내는 자리에서 곧 관찰자들에게 돌린다 — 관찰자 콜백 안에서 보내면 CEF 의 관찰자 목록을
/// 도는 중에 다시 돌게 되어(`ObserverList` 재진입 — 실측: 「Check failed: !check_reentrancy」, 그 뒤 그 탭의 사건이 끊겼다) 사건을 잃는다.
const SwCmd = struct { browser: BrowserId, len: u16, json: [600]u8 };
var sw_queue: std.ArrayList(SwCmd) = .empty;
var sw_task: c.cef_task_t = undefined;
var sw_task_posted = false;

fn swQueue(browser: BrowserId, sid: ?[]const u8, method: []const u8, params: []const u8) i32 {
    const id = nextId();
    var cmd: SwCmd = .{ .browser = browser, .len = 0, .json = undefined };
    const json = (if (sid) |x|
        std.fmt.bufPrint(&cmd.json, "{{\"id\":{d},\"sessionId\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}", .{ id, x, method, params })
    else
        std.fmt.bufPrint(&cmd.json, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params })) catch return 0;
    cmd.len = @intCast(json.len);
    sw_queue.append(gpa, cmd) catch return 0;
    if (!sw_task_posted) sw_task_posted = api().post_task(c.TID_UI, &sw_task) != 0;
    return id;
}

fn swFlush(_: [*c]c.cef_task_t) callconv(.c) void {
    sw_task_posted = false;
    var list = sw_queue;
    sw_queue = .empty;
    defer list.deinit(gpa);
    for (list.items) |*cmd| {
        const entry = browsers.state.registry.byId(cmd.browser) orelse continue;
        const b: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
        const host = b.*.get_host.?(b);
        if (host == null) continue;
        defer object.release(host);
        dbg("sw-send b={d} {s}", .{ cmd.browser, cmd.json[0..@min(cmd.len, 200)] });
        _ = host.*.send_dev_tools_message.?(host, &cmd.json, cmd.len);
    }
}

/// 재검증 7 차: 눈먼 때의 열쇠는 워커 타깃만(epoch 없이) — 붙은 뒤 enable 답 전에 `Inspector.targetReloadedAfterCrash` 로 epoch 가 오르면
/// 옛 epoch 열쇠로 연 눈먼 때를 enable 답·떨어짐이 새 epoch 열쇠로 닫지 못해 영영 열려, 그 탭의 그 뒤 서비스 워커 본문이 모두 `w_blind` 였다
/// (실측 `--review-body-v20fa` v20i-swlag-d100 — 앞 사례의 워커가 다시 붙자마자 다시 떴다가 떨어졌다, p2 0/20).
fn blindKey(target: u64) u64 {
    return sw_mod.targetKey(target, 0);
}

fn detachSession(browser: BrowserId, sid: []const u8) void {
    var pb: [160]u8 = undefined;
    const params = std.fmt.bufPrint(&pb, "{{\"sessionId\":\"{s}\"}}", .{sid}) catch return;
    _ = swQueue(browser, null, "Target.detachFromTarget", params);
}

/// 재검증 13 차(D-v20r-1·LOW-L1): 세션 `sid` 의 워커가 멈췄다(`Inspector.targetCrashed` — `stopAllWorkers`·SW 렌더러 죽음·메모리 압박) — 그 워커를
/// 쥔 maru 세션을 **모든 탭에서**(산 세션·옛 세대·그림자, 표에 없는 세션은 놓기 답을 기다리던 것; 시한 떼기를 기다리는 남의 출처·몫 밖 세션은 그대로 —
/// `Sw.stopTarget`) 곧 뗀다. Chromium 은 세션이 남은 멈춘 호스트를 다시 써서 다시 뜬 워커가
/// 같은 `targetId` 로 멈추지 않고 떴다(새 auto 세션은 떠 있는 워커에 붙어 처음 만남 — 어둠, 그 사이의 기록은 설명되지 않아 그 출처를 기록하는 탭이
/// 기록이 끝날 때까지 어두웠다). 모두 떼면 다시 뜸은 새 호스트로 새로 멈춰 붙는다. 놓기 답을 기다리던 세션도 기다리지 않는다(멈춘 워커에는 놓을
/// 것이 없다 — 답 앞에 떨어져도 건지지 않는다).
fn stopWorker(browser: BrowserId, sid: []const u8) void {
    const known = sw.find(sid) != null or sw.isParked(sid);
    const th = sw.stopTarget(sid);
    var n: usize = 0;
    while (sw.takeStopping()) |x| : (n += 1) {
        const xs = x.sid[0..x.sid_len];
        _ = sw.pendGone(xs);
        detachSession(x.browser, xs);
    }
    // 표에 없는 세션은 maru 가 이미 뗌을 보냈거나(남의 출처 시한·몫·끔 — 표에서 뺄 때 늘 뗀다) 놓기 답 뒤에 뗄 세션이다 — 뒤의 것만 곧 뗀다(앞의 것에
    // 또 보내면 iframe 워커가 쏟아질 때 뗌 명령만 늘었다 — `v20m-r13-flood` 1 426 → 2 047).
    if (!known) if (sw.pendGone(sid) != null) {
        detachSession(browser, sid);
        n += 1;
    };
    dbg("sw-stop-detach b={d} sid={s} target={x} sessions={d}", .{ browser, sid, th, n });
}

/// 몫으로 뺀 다녀간 출처 세션을 뗀다(그 출처로 돌아오면 처음 만남 — 어둠).
fn detachEvicted(now: i64) void {
    while (sw.takeEvicted()) |x| {
        dbg("sw-evict b={d} sid={s} target={s}", .{ x.browser, x.sidSlice(), x.targetSlice() });
        table.workerDetached(x.browser, blindKey(x.target), now);
        if (!sw.pendMarkDetach(x.sidSlice())) detachSession(x.browser, x.sidSlice());
    }
}

/// 페이지 세션의 `Target.attachedToTarget`·`detachedFromTarget`.
fn onTarget(browser: BrowserId, method: []const u8, p: []const u8) void {
    const attached = std.mem.eql(u8, method, "Target.attachedToTarget");
    if (!attached and !std.mem.eql(u8, method, "Target.detachedFromTarget")) return;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, p, .{}) catch return;
    defer parsed.deinit();
    const v = parsed.value;
    if (v != .object) return;
    const sid_v = v.object.get("sessionId") orelse return;
    if (sid_v != .string) return;
    const sid = sid_v.string;
    if (!attached) {
        dbg("sw-detached b={d} sid={s}", .{ browser, sid });
        // 재검증 7 차: 떨어진 세션의 눈먼 때를 닫는다(그 뒤의 W 는 아예 보이지 않는다 — 그 기록은 설명되지 않아 C3b′ 가 막는다). 재검증 11 차:
        // 떨어진 때도 적는다(`Table.workerDetached` — 그 뒤 이 탭이 그 워커를 보았다고 치지 않는다).
        if (sw.find(sid)) |x| table.workerDetached(x.browser, blindKey(x.target), machUs());
        // 재검증 12 차(⑩′): Chromium 이 뗀 다녀간 출처의 세션(그 탭이 떠났다 — 그 출처의 SW 가 그 탭 프레임과 맞지 않게 되었다)은 손으로 다시 붙여
        // 기록이 끝날 때까지 둔다(돌아오면 이미 켜진 세션 — 눈먼 때가 없다). 떠나 있는 동안의 다시 붙음 눈먼 때는 이 탭의 기록을 가리지 못한다(`away`).
        const keep = sw.keepAfterDetach(sid);
        sw.detached(sid);
        if (keep) |k| {
            dbg("sw-keep-reattach b={d} sid={s} target={s}", .{ k.browser, sid, k.targetSlice() });
            if (sw.rescueAddAs(k.targetSlice(), k.browser, machUs(), true)) ensureRescue();
        }
        // 재검증 12 차: 떨어진 세션의 놓기 답은 오지 않는다(뗄 것도 없다).
        if (sw.pendGone(sid)) |gone| pendFinished(gone, .detached);
        return;
    }
    var kind: []const u8 = "";
    var target_id: []const u8 = "";
    var url: []const u8 = "";
    // 재검증 12 차: 멈춰 붙었는가(`waitForDebuggerOnStart:true` 로 새로 뜬 타깃 — 아직 스크립트를 돌리지 않았다).
    var waiting = if (v.object.get("waitingForDebugger")) |x| x == .bool and x.bool else false;
    if (v.object.get("targetInfo")) |ti| if (ti == .object) {
        if (ti.object.get("type")) |x| if (x == .string) {
            kind = x.string;
        };
        if (ti.object.get("targetId")) |x| if (x == .string) {
            target_id = x.string;
        };
        if (ti.object.get("url")) |x| if (x == .string) {
            url = x.string;
        };
    };
    // 재검증 12 차: 건지던 타깃이 붙었다(건지기의 붙이기든 auto-attach 든) — 놓은 뒤 답을 기다린다(뗄 세션은 그 뒤에 뗀다). 눈먼 때는 멈춰 붙음
    // (`paused` — Chromium 이 알린 것)으로만 가른다: 건진 워커에 붙은 이 세션의 enable 앞에 다른 세션(건지기)이 그 워커를 놓을 수 있다.
    const paused = waiting;
    const rescued = sw.rescueTake(target_id, browser);
    if (rescued) |x| {
        // 재검증 13 차: Chromium 이 알린 값(`paused`)도 적는다 — 아래 `waiting` 은 건진 세션이면 늘 참으로 둔다(놓기를 보낸다).
        dbg("sw-rescued b={d} sid={s} target={s} keep={} release={} paused={}", .{ browser, sid, target_id, x.keep, x.release, paused });
        waiting = true;
    }
    // 기록하는 탭이고 걸어 둔 auto-attach 의 서비스 워커면 둔다 — 아니면(밸브로 멈춤·떼는 중·옛 세대·다른 꼴) 곧 뗀다(공격 2 A1).
    // 재검증 7 차(N13): 몫을 넘으면 세워 둔다(`.park` — enable 하지 않고 시한 뒤 뗀다; 곧 떼면 Chromium 이 같은 워커를 곧 다시 붙였다).
    const now = machUs();
    const a: sw_mod.Attach = if (sw_cdp and table.recording(browser) and std.mem.eql(u8, kind, "service_worker")) sw.attachedAt(browser, sid, target_id, now) else .detach;
    if (a == .detach) {
        dbg("sw-attached b={d} sid={s} type={s} target={s} keep=false waiting={}", .{ browser, sid, kind, target_id, waiting });
        // 재검증 12 차: 멈춰 붙었으면 놓고 그 답 뒤에 뗀다(뗌만으로는 풀리지 않을 수 있다).
        if (waiting) return release(browser, sid, target_id, true);
        return detachSession(browser, sid);
    }
    // 재검증 12 차: 몫(전체 64)으로 뺀 다녀간 출처 세션을 뗀다(그 출처로 돌아오면 처음 만남 — 어둠).
    detachEvicted(now);
    if (a == .park) {
        dbg("sw-attached b={d} sid={s} type={s} target={s} keep=park waiting={} paused={}", .{ browser, sid, kind, target_id, waiting, paused });
        if (waiting) release(browser, sid, target_id, false);
        return ensureForeignCheck();
    }
    if (a == .shadow) {
        // 재검증 12 차: 이 탭이 그 워커에 켠 세션(다녀간 출처의 붙여 둔 세션)을 이미 쥐었다 — 켜지 않고 쥐어만 둔다(눈먼 때 없음).
        dbg("sw-attached b={d} sid={s} type={s} target={s} keep=shadow waiting={} paused={}", .{ browser, sid, kind, target_id, waiting, paused });
        if (waiting) release(browser, sid, target_id, false);
        return;
    }
    // 붙여 두기의 다시 붙음은 그 탭에서만 다녀간 출처의 것이다(그 탭이 닫혀 다른 탭이 건졌으면 보통 세션). 재검증 13 차: 그 사이 기록을 끄고 다시
    // 켰으면(세대가 올랐다) 보통 세션 — 새 기록에서 맨 위였던 적 없는 출처를 붙여 두지 않는다.
    if (rescued) |x| if (x.hint == browser and sw.keepCurrent(x)) sw.markVisited(sid);
    // 재검증 6 차 F13: 워커 스크립트 주소의 출처가 맨 위 출처가 아니면(다른 출처 iframe 의 워커·이동 중) 시한 뒤 뗀다(`foreignCheck`).
    // 재검증 7 차(N13): 남의 출처 세션은 탭마다 따로 묶은 몫(`max_foreign_per_tab`)까지만 — 넘으면 세워 둔다.
    const origin = sw.noteOrigin(sid, table_mod.originHash(url), table.topOriginOf(browser), now);
    dbg("sw-attached b={d} sid={s} type={s} target={s} keep=true own={} waiting={} paused={} url={s}", .{ browser, sid, kind, target_id, origin == .own, waiting, paused, url[0..@min(url.len, 160)] });
    // 재검증 13 차(LOW-Q1): 탭 몫(16)의 빼기는 맨 위 출처의 세션으로 정해진 뒤(`noteOrigin`)에 선다 — 그 뺀 세션을 뗀다.
    detachEvicted(now);
    if (origin == .drop) {
        if (waiting) return release(browser, sid, target_id, true);
        return detachSession(browser, sid);
    }
    if (origin != .own) ensureForeignCheck();
    if (origin == .park) {
        if (waiting) release(browser, sid, target_id, false);
        return;
    }
    // 재검증 7 차: enable 답이 올 때까지(그리고 붙기 앞) 시작한 W 는 시작 사건 없이 보인다 — 눈먼 때를 연다.
    // 재검증 8 차: 맨 위 출처의 세션이면 그 눈먼 때 앞에 맺은 짝을 되돌린다(늦게 안 눈먼 때), 남의 출처 세션은 눈먼 때만.
    // 재검증 12 차: 멈춰 붙은 워커는 아직 아무것도 하지 않았고 놓기(enable 뒤 차례)까지 하지 않는다 — 눈먼 때가 없다(앎만 — `workerAttachedPaused`).
    // 떠 있던 워커에 붙었으면 눈먼 때(넓은 꼴 — 그 뒤 50 ms 의 서비스 워커 갈래 본문도 어둠; 기록 중 그 탭과 그 워커가 처음 만날 때 한 번 — 다녀간
    // 출처는 붙여 두므로 돌아와도 다시 붙지 않는다). 떠나 있는 동안 다시 붙인 다녀간 출처 세션은 `away`(이 탭의 기록을 가리지 못한다).
    if (sw.find(sid)) |x| (if (paused) table.workerAttachedPaused(gpa, browser, blindKey(x.target), now) else if (origin == .own) table.workerAttached(gpa, browser, blindKey(x.target), now) else table.workerAttachedForeign(gpa, browser, blindKey(x.target), now, x.visited)) catch {};
    const eid = sendSession(browser, sid, "Network.enable", "{\"maxTotalBufferSize\":0,\"maxResourceBufferSize\":0,\"maxPostDataSize\":1}");
    sw.noteEnable(sid, eid);
    if (waiting) return release(browser, sid, target_id, false);
    // 멈춰 붙지 않았다(기록을 켤 때 이미 떠 있던 워커 — 눈먼 때) — 놓기는 해가 없다(11 차 그대로).
    _ = sendSession(browser, sid, "Runtime.runIfWaitingForDebugger", "{}");
}

/// 원시 관찰자 — 서비스 워커 세션의 메시지(끝이 sessionId)만 가로챈다. 페이지 세션의 것은 0 을 돌려 CEF 가 풀게 한다(`onEvent`·`onResult`).
fn onRaw(_: [*c]c.cef_dev_tools_message_observer_t, browser: [*c]c.cef_browser_t, message: ?*const anyopaque, size: usize) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (browser == null or message == null) return 0;
    const m = @as([*]const u8, @ptrCast(message.?))[0..size];
    const sid = sw_mod.sessionTail(m) orelse return 0;
    // 모르는·옛 세대의 세션도 삼킨다 — CEF 파서는 어차피 넘기지 않는다(실측 p1 0/285).
    // 재검증 12 차: 놓기의 답(세션이 표에 있든 없든 — 기록하지 않는 탭·떼는 세션) — 뗄 세션이면 이제 뗀다.
    if (!test_noreply) if (sw_mod.resultId(m)) |rid| if (sw.pendDone(sid, rid)) |p| pendFinished(p, .reply);
    const s = sw.live(sid) orelse {
        // 재검증 12 차: 모르는·옛 세대·세워 둔 세션의 워커도 다시 뜨면 멈춘다(그 세션이 붙어 있는 동안) — 곧 놓는다. 재검증 13 차: 그 워커의
        // `targetId` 를 안다면 넘긴다(놓기 답 앞에 떨어지면 건진다).
        if (sw_wait) if (sw_mod.eventMethod(m)) |method| {
            if (std.mem.eql(u8, method, "Inspector.targetReloadedAfterCrash")) {
                if (browserOfCef(browser.*.get_identifier.?(browser))) |bid| release(bid, sid, sw.targetOf(sid), false);
            } else if (stop_detach and std.mem.eql(u8, method, "Inspector.targetCrashed")) {
                // 재검증 13 차(D-v20r-1·LOW-L1): 세운·그림자·옛 세대·모르는 세션도 멈춘 워커를 쥐지 않게 뗀다(`stopWorker`).
                if (browserOfCef(browser.*.get_identifier.?(browser))) |bid| stopWorker(bid, sid);
            }
        };
        return 1;
    };
    const id = browserOfCef(browser.*.get_identifier.?(browser)) orelse return 1;
    if (s.browser != id) return 1;
    table.link.clockSample(wallUs(), machUs());
    if (sw_mod.resultId(m)) |rid| {
        const ok = sw_mod.resultOk(m);
        _ = sw.result(sid, rid, ok, wallUs());
        // 재검증 5 차 S3(C3a): 워커 세션의 enable 답 — 이 뒤에 워커에 닿은 응답만 보인다(새 타깃마다 VS 를 올린다 — 공격 1 M5). 재검증 6 차 F13:
        // 맨 위 출처가 아닌 워커는 올리지 않는다 — 그 탭의 P(맨 위 출처 문서의 것 — C0)는 맨 위 출처의 워커만 답한다. 맨 위 출처의 것이 되면
        // 그때 올린다(`topOrigin`).
        if (ok and rid == s.enable_id and table.recording(id) and s.foreign_since == 0) table.link.raiseVisible(id, s.enabled_wall_us);
        // 재검증 7 차: enable 답(성공·실패) — 그 세션의 눈먼 때를 닫는다(그 뒤에 시작한 W 는 시작 사건이 보인다).
        if (rid == s.enable_id) table.workerEnabled(id, blindKey(s.target), machUs());
        dbg("sw-result b={d} sid={s} id={d} ok={}", .{ id, sid, rid, ok });
        return 1;
    }
    const method = sw_mod.eventMethod(m) orelse return 1;
    if (std.mem.eql(u8, method, "Inspector.targetReloadedAfterCrash") or std.mem.eql(u8, method, "Inspector.targetCrashed")) {
        // 재검증 12 차: 멈춤에 그 세션을 뗀다 — 다음 시작은 새로 멈춰 붙는다. 재검증 13 차(D-v20r-1): 그 워커를 쥔 다른 세션(그림자·세운 세션·다른
        // 탭의 것)도 함께 — 하나라도 남으면 Chromium 이 멈춘 호스트를 다시 써 멈추지 않고 뜬다(`stopWorker`).
        if (stop_detach and sw_wait and std.mem.eql(u8, method, "Inspector.targetCrashed")) stopWorker(id, sid);
        sw.reloaded(sid);
        // 재검증 12 차: 다시 뜬 워커가 멈춰 있으면(그 세션이 멈춰 붙인 버전 — Chromium `should_pause_on_start`) 곧 놓는다(Playwright `CRServiceWorker`).
        // 재검증 13 차: 그 워커의 `targetId` 를 넘긴다(놓기 답 앞에 세션이 떨어지면 건진다 — 전에는 빈 글이라 건지지 못했다).
        if (sw_wait and std.mem.eql(u8, method, "Inspector.targetReloadedAfterCrash")) release(id, sid, s.targetSlice(), false);
        // 재검증 7 차: 새 epoch 의 앞뒤를 눈먼 때로 — 다시 뜬 워커의 첫 요청이 시작 사건 없이 올 수 있다.
        table.workerReloaded(gpa, id, blindKey(s.target), machUs()) catch {};
    }
    if (debug_log) dbg("sw-ev b={d} sid={s} epoch={d} method={s} t={d} head={s}", .{ id, sid, s.epoch, method, machUs(), m[0..@min(m.len, 240)] });
    // 쏟아짐 밸브는 워커 사건도 센다(공격 2 A9 — 같은 사건이 기록하는 탭마다 온다). 재검증 7 차(N11): 남의 출처 세션(떼기를 기다린다 —
    // 맞추기에 넣지 않는다)의 사건은 세지 않는다 — 다른 출처 iframe 의 워커가 쏟는 fetch 가 그 3 초 안에 밸브를 닫아 이 탭의 기록 전체를
    // 멈췄다(실측 v20m r11-valve — 1.85 초에 paused, 그 뒤 본문 0/10).
    if (table.recording(id)) {
        const now = machUs();
        if (s.foreign_since == 0) table.cdpEvent(gpa, id, null, now) catch {};
        // 재검증 5 차 S3: 쓰는 사건만 푼다(요청·응답·실패 — 받기·ExtraInfo 는 풀지 않는다).
        if (table.recording(id) and (std.mem.eql(u8, method, "Network.requestWillBeSent") or std.mem.eql(u8, method, "Network.responseReceived") or std.mem.eql(u8, method, "Network.loadingFailed"))) {
            workerEvent(id, s, method, m, now);
        }
        runActions();
        ensureTick();
    }
    return 1;
}

/// 재검증 5 차 S3: 워커 세션의 사건을 풀어 표에 준다.
fn workerEvent(id: BrowserId, s: *const sw_mod.Session, method: []const u8, m: []const u8, now: i64) void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, m, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const params = parsed.value.object.get("params") orelse return;
    const ev = table_mod.parseWorkerEvent(method, params) orelse return;
    if (test_lose.len > 0 and testLose(ev, params, s)) return;
    if (debug_log) switch (ev) {
        .sent => |v| dbg("sw-wsent b={d} t={x} rid={s} url={x} ts={d} redirect={} excl={}", .{ id, s.target, v.rid, v.url_hash, v.ts_us, v.redirect, v.excluded }),
        .response => |v| {
            // 판정자 진단: 워커가 받은 응답의 서버 셈(X-Served) — 짝 정확도를 서버 참값으로 견준다(S3a).
            var xs: []const u8 = "";
            if (params == .object) if (params.object.get("response")) |r| if (r == .object) if (r.object.get("headers")) |h| if (h == .object) {
                var it = h.object.iterator();
                while (it.next()) |kv| if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, "x-served") and kv.value_ptr.* == .string) {
                    xs = kv.value_ptr.string;
                };
            };
            // 재검증 13 차: `start` — 그 W 의 `timing.requestTime`(µs — 짝의 기록 IO 와 견주어 requestTime − IO 의 지연을 잰다, 계획 「재검증 13 차」).
            dbg("sw-wresp b={d} t={x} rid={s} tau={d} disk={} status={d} excl={} xs={s} now={d} start={d}", .{ id, s.target, v.rid, v.tau, v.disk, v.status, v.excluded, xs, now, v.start_us });
        },
        .failed => |v| dbg("sw-wfail b={d} rid={s}", .{ id, v.rid }),
    };
    // 재검증 6 차 F13·D1: 남의 출처 세션의 W 는 맞추기에 넣지 않는다(문이 그 출처의 기록을 이 탭에 붙이지 않았다 — 제 기록이 없는 W 가 같은 주소의
    // 기록을 가져간다), 맨 위 출처의 것이 된 세션은 그 뒤에 시작한 W 만.
    // 재검증 12 차(⑩′): 다녀간 출처의 붙여 둔 세션이 떠나 있으면 자리만 적는다(`net_body_table.away_from`).
    const from: i64 = if (s.foreign_since != 0) (if (s.visited) table_mod.away_from else std.math.maxInt(i64)) else s.own_since;
    table.workerEventFrom(gpa, id, sw_mod.targetKey(s.target, s.epoch), ev, now, from) catch {};
}

/// 재검증 8 차(R-1) 판정자 전용(`test_lose`): 이 워커 사건을 표에 주지 않는가.
fn testLose(ev: table_mod.WorkerEvent, params: std.json.Value, s: *const sw_mod.Session) bool {
    const field = struct {
        fn get(v: std.json.Value, a: []const u8, b: []const u8) []const u8 {
            if (v != .object) return "";
            const o = v.object.get(a) orelse return "";
            if (o != .object) return "";
            const x = o.object.get(b) orelse return "";
            return if (x == .string) x.string else "";
        }
    };
    switch (ev) {
        .sent => |v| {
            if (std.mem.indexOf(u8, field.get(params, "request", "url"), test_lose) == null) return false;
            if (v.method_hash != table_mod.hashMethod("GET") or v.range_hash != 0) {
                test_lose_keep[test_lose_next] = sw_mod.hashId(v.rid) ^ s.target;
                test_lose_next = (test_lose_next + 1) % test_lose_keep.len;
            }
            return false;
        },
        .response => |v| {
            if (std.mem.indexOf(u8, field.get(params, "response", "url"), test_lose) == null) return false;
            if (std.mem.indexOfScalar(u64, &test_lose_keep, sw_mod.hashId(v.rid) ^ s.target) != null) return false;
            std.debug.print("body: sw-lose t={x} rid={s} tau={d}\n", .{ s.target, v.rid, v.tau });
            return true;
        },
        .failed => return false,
    }
}

/// 재검증 5 차 S3b(C0): 맨 위 문서의 출처(`network.mainFrameAddress` — `scheme://host[:port]`).
pub fn topOrigin(browser: BrowserId, origin: []const u8) void {
    const h = if (origin.len == 0) 0 else table_mod.originHash(origin);
    table.topOrigin(browser, h, machUs());
    // 재검증 6 차 F13: 붙은 워커 세션을 새 맨 위 출처와 다시 견준다 — 앞 출처의 것은 시한 뒤 떼고, 새 출처의 것이 된 세션(주소가 바뀌기 전에
    // 붙었다)은 남기며 그 enable 답으로 VS 를 올린다(남의 출처인 동안에는 올리지 않았다).
    if (!ready) return;
    const raise = sw.retarget(browser, h, machUs());
    if (raise != 0 and table.recording(browser)) table.link.raiseVisible(browser, raise);
    // 재검증 12 차: 돌아온 다녀간 출처 세션 — 떠나 있던 동안 다시 붙인 그 워커의 눈먼 때가 아직 닿으면 보통 눈먼 때로(`Table.workerReturned`).
    while (sw.takeReturned(browser)) |x| table.workerReturned(browser, blindKey(x.target), machUs());
    dbg("sw-retarget b={d} origin={x} raise={d}", .{ browser, h, raise });
    ensureForeignCheck();
}

/// 재검증 6 차 F13: 맨 위 출처가 아닌 워커 세션을 시한 뒤 뗀다 — 가장 이른 시한에 맞춰 다음 확인을 건다.
var foreign_task: c.cef_task_t = undefined;
var foreign_posted = false;

fn ensureForeignCheck() void {
    if (foreign_posted) return;
    const at = sw.nextForeign() orelse return;
    const wait_ms = @divTrunc(@max(at + sw_mod.foreign_grace_us - machUs(), 0), 1000) + 1;
    foreign_posted = api().post_delayed_task(c.TID_UI, &foreign_task, wait_ms) != 0;
}

fn foreignCheck(_: [*c]c.cef_task_t) callconv(.c) void {
    foreign_posted = false;
    const now = machUs();
    while (sw.takeForeign(now)) |x| {
        dbg("sw-foreign-detach b={d} sid={s} origin={x}", .{ x.browser, x.sidSlice(), x.origin });
        if (x.target != 0) table.workerDetached(x.browser, blindKey(x.target), now); // 재검증 7 차: 그 세션의 눈먼 때를 닫는다(11 차: 떨어진 때도)
        // 재검증 12 차: 놓기 답을 아직 기다리면 그 답 뒤에 뗀다.
        if (sw.pendMarkDetach(x.sidSlice())) continue;
        detachSession(x.browser, x.sidSlice());
    }
    ensureForeignCheck();
}
