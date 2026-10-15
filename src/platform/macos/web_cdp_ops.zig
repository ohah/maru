//! Chromium(OSR) 탭의 `browser.*` 를 DevTools(CDP) 호출 차례로 푼다(W9b① — 에이전트용 브라우저 제어). 한 요청은 호출 여러
//! 번(예: click = 노드 찾기 → 화면 안으로 → 자리 → 덮였는지 → 누르기)이고, 각 호출의 결과를 보고 다음 호출을 정한다. 이 파일은
//! 그 차례만 안다 — 보내기·받기는 `web_osr.devtoolsCall`, 요청 완료는 `app_host_abi` 가 한다(CEF·control-plane 없이 시험한다).
//!
//! - 입력은 **진짜 입력**이다(`Input.dispatchMouseEvent` — 페이지에는 `isTrusted` 인 사람 클릭으로 보인다, 착수 전 실측). 그래서
//!   누르기 직전에 그 자리에서 맞는 것이 그 요소(또는 그 안)인지 본다 — 다른 요소가 덮었으면 누르지 않고 실패로 답한다. 이 검사는
//!   **격리된 world**(`Page.createIsolatedWorld`)에서 돈다: 페이지 world 에서 돌리면 페이지가 `elementFromPoint`·`contains` 를 바꿔
//!   검사를 속이고 검사 순간을 알아챘다(W9b①a 적대 리뷰 1 회차 실측 — 격리 world 는 둘 다 막는다). 검사와 누르기 사이에는 왕복이
//!   하나뿐이다. **이 검사는 오클릭 방지이지 적대 페이지에 대한 경계가 아니다** — 페이지가 검사 순간을 몰라도 덮개를 계속 켰다 껐다
//!   하면 검사는 「맞음」·누름은 덮개에 떨어지는 경우가 생긴다(W9b①a 적대 리뷰 2 회차). 누르기 전 움직임(`mouseMoved`)은 보내지
//!   않는다: 숨긴 탭에서는 답이 오지 않았고(실측) 페이지에 「곧 누른다」는 신호가 됐다. 누름을 보냈으면 떼기·놓기는 끝까지 보낸다
//!   (`committed` — 철회돼도, 누름의 답이 시한을 넘겨도 버튼을 눌린 채 두지 않는다).
//! - 검사는 DOM 속성을 프로토타입 getter 로 읽는다 — 이름 속성(DOM clobbering)은 격리 world 에서도 보인다(3 회차 실측).
//! - 다른 frame 의 요소(같은 출처 iframe 노드를 ref 로)는 누르지 않는다 — 자리는 주 화면 좌표인데 검사는 그 frame 문서에서 돌아
//!   어긋난다. 그림자 DOM 의 slot 에 꽂힌 내용·host 는 그 요소 안으로 본다.
//! - 자리는 요소 상자와 화면(layout viewport)이 겹친 곳의 가운데다(화면보다 큰 요소의 가운데가 화면 밖이면 거기서는 아무것도 맞지
//!   않는다). 원격 객체는 요청마다 다른 묶음(`maru-w9b-<번호>`)이라 같은 탭의 다른 요청이 놓지 못한다.
//! - ref 는 `n<backendNodeId>`(같은 문서 안에서 바뀌지 않는다 — WebKit 의 `e1` 은 다음 snapshot 까지만이다). 모르는 ref·없는 요소는
//!   WebKit 과 같이 `{ok:false}`.
//! - 결과의 status 숫자는 `control_browser.BrowserCompletionStatus` 계약이다(성공 = 0 + "true"/"false", 실패 = 1 + 메시지).

const std = @import("std");
const web_cdp_snapshot = @import("web_cdp_snapshot.zig");
const web_cdp_keys = @import("web_cdp_keys.zig");
const web_cdp_locate = @import("web_cdp_locate.zig");
/// W9a 의 페이지 op(navigate·getUrl·screenshot) — 이 Op 이 그쪽으로 넘긴다.
pub const web_cdp_page = @import("web_cdp_page.zig");
/// W9a② 의 executeScript — 같이 넘긴다.
pub const web_cdp_exec = @import("web_cdp_exec.zig");
/// W9a③ 의 localStorage·쿠키·clearStorage — 같이 넘긴다.
pub const web_cdp_storage = @import("web_cdp_storage.zig");
/// W9c③ 의 upload — 로케이터는 이 Op 가 풀고, 요소를 찾으면 그쪽으로 넘긴다(`scrollStep` 자리).
pub const web_cdp_upload = @import("web_cdp_upload.zig");
/// text·label 로케이터의 격리 world 함수(W9b②-2 — 계획 공격 3 회차에 실측한 것).
const finder_js = @embedFile("web_cdp_finder.js");

/// 앱이 DevTools 결과 상한을 넘은 답에 싣는 글 — 로케이터 질의가 이것이면 「너무 많다」 로 바꿔 답한다.
pub const result_too_large = "the DevTools result was too large";

/// 페이지가 JS 대화상자(alert·confirm·prompt·떠나기 확인)를 띄워 멈췄다 — 답하기 전에는 그 페이지로 가는 호출이 답하지 않는다(W9b③ 적대 리뷰
/// 1·2 회차). W9c②: 에이전트가 답해도 되는 것이면 `handle-dialog` 로 답한다 — 아니면 사용자가 그 탭에서 답한다. 두 글은 표지로 그대로
/// 비교된다(`std.mem.eql`) — 고치면 상수만 고친다.
/// W9a 적대 리뷰 4 회차: 같은 팝업 가족의 **다른** 탭이 대화상자를 띄웠다 — 그 탭의 스크립트는 멈춘 것이 아니다(다른 렌더러에서 돈다).
pub const family_dialog_reason = "a tab in the same popup family is showing a dialog (alert, confirm or prompt) — the script was stopped; answer the dialog with maru browser handle-dialog if you may (otherwise the user answers it in that tab), then run it again";

pub const dialog_reason = "the page, or a tab it opened or that opened it, is showing a dialog (alert, confirm, prompt or leave-page question) — answer it with maru browser handle-dialog if you may (see maru browser dialog), otherwise the user answers it in that tab";

/// 누르기 전 프레임(W9b③)의 인자 — **kick 과 바이트까지 같아야 한다**(`app_host_abi` 가 컴파일 때 본다). sidecar 는 kick 과 꼭 같은
/// 호출만 짧은 시한(3 초)에 놓는다 — 다르면 이동하는 순간 답을 잃은 프레임이 35 초 자리를 쥐어 click 이 30 초 시한이 됐다(적대 리뷰
/// 1 회차 하네스 실측: 같으면 3.0–3.6 초에 풀린다).
pub const frame_params = "{\"format\":\"jpeg\",\"quality\":1,\"clip\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1,\"scale\":1}}";

pub const Status = enum(u32) { success = 0, failed = 1, timeout = 2, invalid_params = 3 };

pub const Kind = enum { click, back, forward, reload, type_text, scroll, wait, snapshot, hover, press, navigate, get_url, screenshot, execute_script, get_local_storage, set_local_storage, remove_local_storage, get_cookies, set_cookie, delete_cookie, clear_storage, upload };

/// W9c②: 이 op 이 페이지를 움직이는가 — 그 호출 뒤의 JS 대화상자를 에이전트 것으로 볼 근거(`web_osr.noteAgentInput`). 읽기만 하는 op
/// (스냅숏·기다림·주소·스크린샷)과 저장소 op 은 아니다 — 대화상자를 부르지 않는다.
pub fn acting(kind: Kind) bool {
    return switch (kind) {
        .click, .back, .forward, .reload, .type_text, .scroll, .hover, .press, .navigate, .execute_script => true,
        .wait, .snapshot, .get_url, .screenshot, .get_local_storage, .set_local_storage, .remove_local_storage, .get_cookies, .set_cookie, .delete_cookie, .clear_storage => false,
        // W9c③: 모달 전·승인 뒤의 확인 호출은 페이지를 움직이지 않는다 — 앱이 넣기(`DOM.setFileInputFiles`) 바로 앞에서만 적는다(`Op.uploadSetting`):
        // 그래야 change 처리기가 띄운 대화상자가 에이전트 것이 되고(5 초 창), 모달 동안 사용자가 띄운 것은 에이전트 것이 되지 않는다.
        .upload => false,
    };
}

/// kick 을 붙이는가(`web_cdp_kick.zig`).
pub const Kick = @import("web_cdp_kick.zig").Kick;

/// 탭·전체 DevTools 자리가 다 찼다 — 부른 쪽(`app_host_abi` `cdpAdvance`·`cdpDone`)이 `not_sent` 에 이 글을 그대로 싣는다. kick 을
/// 실은 호출은 이 이유일 때만 잠깐 뒤 다시 보낸다(4 회차 — 탭이 준비 안 됨·요청 실패에도 4.5 초 다시 보냈다).
pub const busy_reason = "too many DevTools calls at once (on this tab, or across all tabs) — retry shortly";

/// 확정되지 않은 이동 중이라 페이지 호출을 보내지 않았다 — 부른 쪽(`app_host_abi` `uncommittedReply`)이 `not_sent` 에 이 글을 그대로 싣는다.
/// 업로드는 넣은 뒤의 읽기가 이 글이면 「넣고 곧 옮겨 갔다」 로 가른다(W9c③ 적대 리뷰 2 회차 — 「then try again」 이 다시 올리게 했다).
pub const loading_reason = "the tab is loading a new page — wait for it (wait --load), then try again";

/// 다음에 할 일 — CDP 호출 하나(`params` 는 소유 — 부른 쪽이 놓는다) 또는 끝(`result` 소유).
pub const Step = union(enum) {
    /// `kick` — 바로 뒤에 작은 스크린샷을 함께 보낸다(`web_osr.devtoolsCallKick` 이 이 값을 그대로 받는다 — 숨은 탭의 접근성 질의·포인터 이동·rAF 가 그래야 돈다,
    /// W9b②-3). `Kick` 참고.
    call: struct { method: []const u8, params: []u8, kick: Kick = .none },
    done: struct { status: Status, result: []u8 },
    /// 이만큼(ms) 뒤에 `wake` 로 다시 부른다(wait 의 확인 간격 — 페이지 타이머를 쓰지 않는다: 숨긴 탭은 그것을 늦춘다).
    sleep: u32,
    /// W9c③: 업로드가 모달 전 확인을 마쳤다 — 앱이 확인 모달을 띄우고(출처 `origin` 만 — 소유), 승인되면 사본을 만들어 `resumeUpload` 로 잇는다.
    /// 그동안 이 op 은 그 탭의 줄을 쥔다(한 탭에 업로드 모달은 하나).
    confirm: struct { origin: []u8 },
};

/// 한 호출의 결과(`web_osr.DevtoolsOutcome` 을 이 모듈이 아는 셋으로 접는다).
pub const Reply = union(enum) {
    ok: []const u8,
    cdp_error: []const u8,
    /// 보내지 못했다·답이 없다(떨어짐·sidecar 죽음) — 이유 글.
    failed: []const u8,
    /// 시한 안에 답이 없었다 — status timeout.
    timed_out: []const u8,
    /// 확실히 보내지 않았다(탭의 DevTools 자리가 다 찼다·보내기 실패 등) — 누름이면 떼기를 보내지 않는다(3 회차: 떼기만 가면
    /// 페이지는 keydown 없는 진짜 keyup 을 받았다).
    not_sent: []const u8,
};

/// 여러 줄 링크의 줄 상자 상한 — 화면보다 긴 링크는 앞줄이 화면 밖일 수 있어 넉넉히(3 회차 — 8 이면 9 줄째부터 보여도 실패했다).
const max_boxes = 64;

/// wait 의 확인 간격(백오프) — 50 ms 에서 두 배씩 500 ms 까지. 확인 한 번 = DevTools 호출 둘(world·평가). 이벤트로 깨우는 길은
/// DevTools 이벤트를 받는 W9c 에서(그때 이 되풀이 확인을 없앤다).
pub const wait_first_interval_ms: u32 = 50;
pub const wait_max_interval_ms: u32 = 500;

/// 누른 뒤의 떼기를 확실히 보내지 못했을 때(DevTools 자리가 참 등) 다시 보내는 간격·횟수(4 회차 — 그냥 끝내 키가 눌린 채 남았다).
pub const up_retry_ms: u32 = 50;
pub const max_up_retries: u8 = 3;
/// `required` kick 을 실은 호출을 자리가 없어 못 보냈을 때 다시 보내는 간격·횟수 — 잃은 kick 을 sidecar 가 놓는 시한(3–3.75 초,
/// `devtools_kick_stale_ms`)보다 길게(적대 리뷰 3 회차 — 세 번 50 ms 로는 곧 「too many」 로 끝났고 다시 해도 35 초 같았다).
pub const kick_retry_ms: u32 = 100;
pub const max_kick_retries: u8 = 45;

const Stage = enum { document, query, describe, scroll, quads, metrics, frame_tree, world, resolve, frame, hit_test, mouse_down, mouse_up, release, history, navigate_entry, reload, focus, select, insert, delete_down, delete_up, verify, ax_tree, check, sleeping, hover_move, focus_check, key_down, key_up, size_check, loc_document, locate, loc_find, loc_release, judge_resolve, judge, rel_then, upload };

/// 묶음을 놓은 뒤에 할 일(`rel_then`) — wait 의 다음 확인, act 의 화면 안으로, 또는 그 답(소유).
const Then = union(enum) {
    sleep,
    scroll,
    done: struct { status: Status, result: []u8 },
};

/// role wait 의 보임 판정은 후보를 이만큼씩 잡아 한 번에 본다(계획 공격 2 회차 — 하나씩이면 확인 한 번에 호출 40 개).
const judge_batch = 20;

/// 첫 무거운 호출 시간의 상한 — 견줄 앞의 것이 없을 때 페이지의 긴 작업에 부푼 값이 다음 확인을 10 초 뒤로 밀지 않게(적대 리뷰 1 회차 실측 —
/// 요소는 2.7 초에 생겼는데 12.5 초에 답했다). 그 뒤로는 직전 두 번 가운데 작은 것(부푼 한 번을 거른다 — 2 회차: 2 초 상한이 숨은 큰 탭의
/// 페이지를 절반 넘게 멈췄다).
const wait_first_heavy_cap_ms: i64 = 500;
/// 마지막 확인이 시한을 넘길 수 있는 여유 — 다음 잠과 확인이 이보다 더 넘길 것 같을 때만 시한 전에 답한다(첫 확인이 긴 작업에 막혀 3 초
/// 걸리자 5 초 시한의 wait 이 3 초에 포기했다 — 1 회차). 확인 시간은 앞의 것으로 짐작한다 — 그보다 길면 더 넘긴다.
const wait_max_overrun_ms: i64 = 2000;

pub const Op = struct {
    kind: Kind,
    stage: Stage = .document,
    /// 원격 객체 묶음 이름의 번호(요청마다 다르게 — 부른 쪽의 async id).
    id: u64 = 0,
    selector: ?[]u8 = null,
    backend: i64 = 0,
    /// 요소 상자들(viewport CSS px, 앞에서 `max_boxes` 개 — 여러 줄에 걸친 링크는 줄마다 하나) — 화면과 겹친 첫 상자를 고른다.
    boxes: [max_boxes][4]f64 = undefined,
    box_count: usize = 0,
    frame_id: ?[]u8 = null,
    context_id: i64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    /// 덮였는지 본 결과의 실패 이유(놓기 뒤에 답한다). null = 맞았다.
    miss: ?[]const u8 = null,
    /// 누름·떼기의 답이 시한을 넘겼다 — 그래도 떼기·놓기를 보내고 끝에 timeout 으로 답한다.
    late: ?[]const u8 = null,
    /// 누름·넣기를 보냈다(W9b③ 적대 리뷰 3 회차) — 그 뒤 대화상자 이유가 오면 실패가 아니라 「갔다 + 대화상자」 다.
    sent_input: bool = false,
    /// 입력을 보낸 뒤 페이지가 JS 대화상자를 띄웠다 — 성공에 `"dialog":true` 를 싣는다(다시 하면 두 번 제출된다).
    dialog: bool = false,
    /// type 의 글(소유).
    text: ?[]u8 = null,
    /// wait — selector 가 보일 때까지(null 이면 문서가 다 불릴 때까지), 시한.
    wait_selector: ?[]u8 = null,
    wait_timeout_ms: u32 = 0,
    wait_deadline_ms: i64 = 0,
    /// 다음 확인까지의 간격 — 처음엔 짧게(곧 생기는 요소를 빨리), 두 배씩 늘려 `wait_max_interval_ms` 에서 멈춘다(오래 기다리는
    /// 동안의 DevTools 호출을 줄인다).
    wait_interval_ms: u32 = wait_first_interval_ms,
    /// 부른 쪽이 넣는 지금 시각(start·wake 전에)과 그 탭이 불러오는 중인가(wait --load — sidecar 의 nav_state).
    now_ms: i64 = 0,
    page_loading: bool = false,
    /// type — 고른 요소(넣은 뒤 다시 읽는다, 소유)와 넣기 전 값의 해시·길이(다시 읽을 때 「바뀌지 않았나·덧붙지 않았나」를 본다 —
    /// 값 자체는 싣지 않는다: 큰 글 상자면 DevTools 인자 상한(64 KiB)을 넘고, 결과의 서로게이트 정화가 값을 바꾼다 — 3 회차).
    object_id: ?[]u8 = null,
    before_hash: i64 = -1,
    before_len: i64 = 0,
    /// snapshot 선택.
    snap: web_cdp_snapshot.Options = .{},
    /// press — 키 이름(소유 — 이벤트를 만들 때마다 `web_cdp_keys` 로 다시 푼다)과 대상(없으면 지금 초점에 누른다).
    press_key: ?[]u8 = null,
    press_target: bool = false,
    /// 떼기를 다시 보낸 횟수.
    up_retries: u8 = 0,
    /// 로케이터(W9b② — role) — 찾는 동안 `locating`. 역할은 Chromium 역할(정적), 이름은 정규화한 것(소유), 입력한 역할 이름(메시지용, 소유).
    locating: bool = false,
    loc_role: []const u8 = "",
    loc_input_role: ?[]u8 = null,
    loc_name: ?[]u8 = null,
    loc_level: ?i64 = null,
    loc_exact: bool = false,
    loc_nth: ?u32 = null,
    /// 로케이터로 찾은 요소의 이름(소유) — 성공 답에 `matched` 로 싣는다(부분 일치가 하나면 그것을 누른다 — 무엇을 눌렀는지 보이게).
    matched_name: ?[]u8 = null,
    /// 로케이터 종류 — role 은 접근성 질의, text·label 은 격리 world 의 JS(W9b②-2).
    loc_kind: enum { role, text, label } = .role,
    /// text·label 찾기의 결과 — 놓기(`loc_release`) 뒤에 쓴다.
    loc_found: ?web_cdp_locate.Found = null,
    /// text·label 로 찾은 요소 — 덮임 검사가 그 요소에서 가장 가까운 조작 가능한 조상까지의 조상에 맞아도 통과시킨다(2 회차 —
    /// `pointer-events:none` 글·조상의 의사 요소 덮개: 사람이 그 글을 누르면 그 조상이 받는다).
    hit_up: bool = false,
    /// wait visible(W9b②-3) — 로케이터가 보일 때까지. 시한 답에 마지막 확인의 숨은 일치 수.
    wait_visible: bool = false,
    wait_hidden: u64 = 0,
    /// 찾기가 일시적으로 실패했다(이동 중 context 가 사라짐·시한·자리 없음) — wait 은 다음 확인으로.
    find_transient: bool = false,
    /// 이번 확인의 시작과 직전 확인 전체 시간(마감 판단), 무거운 호출(질의·찾기)의 시작과 시간(간격 — 앱의 tick 대기를 빼고, 계획 공격 2 회차).
    check_start_ms: i64 = 0,
    last_check_ms: i64 = 0,
    heavy_start_ms: i64 = 0,
    /// 이번 확인의 무거운 호출(찾기·질의·크기 세기·판정) 시간의 합 — 확인이 끝나면 `noteHeavy`(3 회차 — 질의만 셌다).
    check_heavy_ms: i64 = 0,
    /// wait 를 시작한 시각과 지금까지 무거운 확인의 합(첫 것은 `wait_first_heavy_cap_ms` 로 센다) — 누적으로 1/5 아래(3 회차).
    wait_start_ms: i64 = 0,
    heavy_total_ms: i64 = 0,
    /// 시한 전 마지막 확인을 앞당겼다 — 한 번만.
    final_check: bool = false,
    /// 이번 확인 안에서 kick 자리를 기다리며 잔 시간 — 확인 시간 짐작에서 뺀다(4 회차 — 4.5 초가 다음 확인 짐작에 들어가 20 초 wait 이
    /// 14 초에 끝났다).
    check_wait_ms: i64 = 0,
    last_heavy_ms: i64 = 0,
    /// 그 앞의 무거운 호출 시간(-1 = 아직 하나뿐이거나 없다).
    prev_heavy_ms: i64 = -1,
    heavy_count: u8 = 0,
    /// role 질의의 대상 — 그 확인의 격리 world 의 `document`(묶음 안, 소유). 이동하면 질의가 곧바로 오류다(backendNodeId 로 부르면 옛 문서에
    /// 영영 매달렸다 — 계획 공격 1 회차 실측).
    doc_obj: ?[]u8 = null,
    /// role wait 의 후보·지금 보는 묶음의 시작·그 묶음에서 잡은 원격 객체(소유, 못 잡았으면 null).
    cands: ?web_cdp_locate.Cands = null,
    cand_at: usize = 0,
    cand_objs: std.ArrayList(?[]u8) = .empty,
    /// kick 을 실은 호출을 자리가 없어 못 보냈다 — 잠깐 뒤 다시(`max_kick_retries` 까지).
    kick_retries: u8 = 0,
    /// 놓은 뒤에 할 일.
    then: Then = .sleep,
    /// W9a 의 페이지 op(navigate·screenshot) — 있으면 start·feed·wake 를 모두 넘긴다.
    page: ?web_cdp_page.Op = null,
    /// W9a② 의 executeScript — 같다.
    exec: ?web_cdp_exec.Op = null,
    /// W9a③ 의 localStorage·쿠키·clearStorage — 같다.
    storage: ?web_cdp_storage.Op = null,
    /// W9c③ 의 upload — 로케이터를 푼 뒤(`stage == .upload`)의 차례.
    upload: ?web_cdp_upload.Op = null,
    /// W9c③ 적대 리뷰 1 회차: 업로드가 마지막으로 낸 호출(params 소유). 승인 뒤 그 호출을 자리 없음(`busy_reason`)으로 못 보냈으면 잠깐 뒤
    /// 그대로 다시 보낸다 — 사용자가 승인한 업로드를 「retry shortly」 로 버리면 에이전트가 다시 불러 모달이 또 뜬다(click·type 의 kick 재시도와 같은 간격·횟수).
    up_last: ?struct { method: []const u8, params: []u8, kick: Kick } = null,
    up_resend: bool = false,
    up_busy_retries: u8 = 0,

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.up_last) |l| gpa.free(l.params);
        if (self.upload) |*u| u.deinit(gpa);
        if (self.page) |*p| p.deinit(gpa);
        if (self.exec) |*e| e.deinit(gpa);
        if (self.storage) |*st| st.deinit(gpa);
        if (self.selector) |s| gpa.free(s);
        if (self.frame_id) |s| gpa.free(s);
        if (self.text) |s| gpa.free(s);
        if (self.wait_selector) |s| gpa.free(s);
        if (self.object_id) |s| gpa.free(s);
        if (self.press_key) |s| gpa.free(s);
        if (self.loc_input_role) |s| gpa.free(s);
        if (self.loc_name) |s| gpa.free(s);
        if (self.matched_name) |s| gpa.free(s);
        if (self.loc_found) |*f| f.deinit(gpa);
        self.dropRoleState(gpa);
        if (self.then == .done) gpa.free(self.then.done.result);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg — click·scroll `{"selector"|"ref"}`, type `{…, "text"}`, wait `{"condition","selector"?,
    /// "timeout_ms"}`, snapshot `{"interactive_only","max_depth"?,"selector"?}`, back·forward·reload 는 빈 것. `id` 는 원격 객체
    /// 묶음 이름에 쓴다.
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8, id: u64) !Op {
        var op: Op = .{ .kind = kind, .id = id };
        errdefer op.deinit(gpa);
        switch (kind) {
            .back, .forward, .reload => return op,
            .execute_script => {
                op.exec = try web_cdp_exec.Op.init(gpa, arg, id);
                return op;
            },
            .get_local_storage, .set_local_storage, .remove_local_storage, .get_cookies, .set_cookie, .delete_cookie, .clear_storage => {
                op.storage = try web_cdp_storage.Op.init(gpa, switch (kind) {
                    .get_local_storage => .get_local_storage,
                    .set_local_storage => .set_local_storage,
                    .remove_local_storage => .remove_local_storage,
                    .get_cookies => .get_cookies,
                    .set_cookie => .set_cookie,
                    .delete_cookie => .delete_cookie,
                    else => .clear_storage,
                }, arg);
                return op;
            },
            .navigate, .get_url, .screenshot => {
                op.page = try web_cdp_page.Op.init(gpa, switch (kind) {
                    .navigate => .navigate,
                    .get_url => .get_url,
                    else => .screenshot,
                }, arg);
                return op;
            },
            else => {},
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidArg;
        const o = parsed.value.object;
        switch (kind) {
            .upload => {
                // 파일 경로는 앱이 다룬다(열기·사본) — 이 차례는 수만 안다(여러 개면 `multiple` 칸이어야 한다).
                const files = o.get("files") orelse return error.InvalidArg;
                if (files != .array or files.array.items.len == 0 or files.array.items.len > web_cdp_upload.max_files) return error.InvalidArg;
                op.upload = web_cdp_upload.Op.init(files.array.items.len, id);
            },
            .wait => {
                const cond = o.get("condition") orelse return error.InvalidArg;
                if (cond != .string) return error.InvalidArg;
                if (std.mem.eql(u8, cond.string, "selector")) {
                    const sel = o.get("selector") orelse return error.InvalidArg;
                    if (sel != .string) return error.InvalidArg;
                    op.wait_selector = try gpa.dupe(u8, sel.string);
                } else if (std.mem.eql(u8, cond.string, "visible")) {
                    // W9b②-3 — 로케이터(selector 면 L2 가 `selector` 조건으로 바꿔 넘긴다).
                    try op.parseLocator(gpa, o.get("locator") orelse return error.InvalidArg);
                    op.wait_visible = true;
                } else if (!std.mem.eql(u8, cond.string, "load")) return error.InvalidArg;
                const t = o.get("timeout_ms") orelse return error.InvalidArg;
                if (t != .integer or t.integer <= 0) return error.InvalidArg;
                op.wait_timeout_ms = @intCast(@min(t.integer, std.math.maxInt(u32)));
                return op;
            },
            .snapshot => {
                if (o.get("interactive_only")) |v| if (v == .bool) {
                    op.snap.interactive_only = v.bool;
                };
                if (o.get("max_depth")) |v| if (v == .integer and v.integer >= 0) {
                    op.snap.max_depth = @intCast(@min(v.integer, std.math.maxInt(u32)));
                };
                if (o.get("selector")) |v| if (v == .string) {
                    op.selector = try gpa.dupe(u8, v.string);
                };
                return op;
            },
            .type_text => {
                const t = o.get("text") orelse return error.InvalidArg;
                if (t != .string) return error.InvalidArg;
                // 넣기·다시 읽기가 글을 DevTools 인자(64 KiB)에 싣는다 — 다시 읽기 JS 와 함께 넘치지 않게 JSON 으로 48 KiB 까지(넘으면
                // 넣은 뒤 다시 읽기만 거절돼 「들어갔는데 실패」가 됐다 — 적대 리뷰 4 회차).
                if (jsonStringBytes(t.string) > max_type_text_json_bytes) return error.InvalidArg;
                op.text = try gpa.dupe(u8, t.string);
            },
            .press => {
                const k = o.get("key") orelse return error.InvalidArg;
                if (k != .string) return error.InvalidArg;
                var probe: web_cdp_keys.Press = undefined;
                web_cdp_keys.parse(k.string, &probe) catch return error.InvalidKey;
                op.press_key = try gpa.dupe(u8, k.string);
                // 대상이 없으면 지금 초점에 누른다(페이지의 초점 — 다른 출처 iframe 일 수도 있다).
                if (o.get("ref") == null and o.get("selector") == null and o.get("locator") == null) return op;
                op.press_target = true;
            },
            else => {},
        }
        if (o.get("locator") != null and (o.get("selector") != null or o.get("ref") != null)) return error.InvalidArg; // L2 가 막지만 엔진도
        if (o.get("locator")) |l| switch (kind) {
            .click, .type_text, .scroll, .hover, .press, .upload => {
                try op.parseLocator(gpa, l);
                return op;
            },
            else => return error.InvalidArg,
        };
        if (o.get("ref")) |r| {
            if (r != .string) return error.InvalidArg;
            op.backend = parseRef(r.string) orelse 0; // 모르는 ref — start 가 곧바로 {ok:false}
            op.stage = .scroll;
        } else if (o.get("selector")) |sel| {
            if (sel != .string) return error.InvalidArg;
            op.selector = try gpa.dupe(u8, sel.string);
        } else return error.InvalidArg;
        return op;
    }

    /// `{"role", "name"?, "level"?, "exact"?, "nth"?}` — 모양은 L2 가 봤다. 역할 이름은 여기서 푼다(모르는 역할은 error.UnknownRole).
    fn parseLocator(op: *Op, gpa: std.mem.Allocator, l: std.json.Value) !void {
        if (l != .object) return error.InvalidArg;
        const lo = l.object;
        if (lo.get("role") == null) if (lo.get("text") orelse lo.get("label")) |t| {
            // text·label(W9b②-2) — 정규화한 질의를 격리 world 의 JS 에 넘긴다.
            if (t != .string or t.string.len == 0 or t.string.len > web_cdp_locate.max_text_bytes) return error.InvalidArg;
            op.loc_kind = if (lo.get("text") != null) .text else .label;
            op.loc_name = try web_cdp_locate.normalize(gpa, t.string);
            if (op.loc_name.?.len == 0) return error.InvalidArg;
            if (lo.get("exact")) |v| {
                if (v != .bool) return error.InvalidArg;
                op.loc_exact = v.bool;
            }
            if (lo.get("nth")) |v| {
                if (v != .integer or v.integer < 0 or v.integer > 1_000_000) return error.InvalidArg;
                op.loc_nth = @intCast(v.integer);
            }
            op.locating = true;
            if (op.kind == .press) op.press_target = true;
            return;
        };
        const role = lo.get("role") orelse return error.InvalidArg;
        if (role != .string) return error.InvalidArg;
        op.loc_role = web_cdp_locate.chromiumRole(role.string) orelse return error.UnknownRole;
        op.loc_input_role = try gpa.dupe(u8, role.string);
        if (lo.get("name")) |n| {
            if (n != .string or n.string.len == 0 or n.string.len > web_cdp_locate.max_text_bytes) return error.InvalidArg;
            op.loc_name = try web_cdp_locate.normalize(gpa, n.string);
            if (op.loc_name.?.len == 0) return error.InvalidArg; // 공백·보이지 않는 글자뿐 — 이름 조건이 사라진다(1 회차)
        }
        if (lo.get("level")) |v| {
            if (v != .integer or v.integer < 1 or v.integer > 100) return error.InvalidArg;
            op.loc_level = v.integer;
        }
        if (lo.get("exact")) |v| {
            if (v != .bool) return error.InvalidArg;
            op.loc_exact = v.bool;
        }
        if (lo.get("nth")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 1_000_000) return error.InvalidArg;
            op.loc_nth = @intCast(v.integer);
        }
        op.locating = true;
        if (op.kind == .press) op.press_target = true;
    }

    /// 이미 페이지에 누름을 보냈다 — 남은 호출(떼기·놓기)은 그 요청이 철회돼도 보낸다(버튼을 눌린 채 두지 않는다).
    pub fn committed(self: *const Op) bool {
        if (self.stage == .upload) return self.upload.?.committed();
        if (self.page) |*p| return p.committed();
        if (self.exec) |*e| return e.committed();
        if (self.storage) |*st| return st.committed();
        return switch (self.stage) {
            // 누름·Delete 키 누름을 보냈다 — 뗌·놓기를 끝까지. 넣은 뒤의 다시 읽기도(읽기만 한다 — 놓기까지 가게).
            // 키를 눌렀다 — 떼기까지(눌린 채 두지 않는다).
            // 찾기 결과를 쥔 원격 객체는 철회돼도 놓는다(W9b②-2).
            .mouse_up, .release, .delete_up, .verify, .key_up, .loc_release, .rel_then => true,
            else => false,
        };
    }

    /// 철회됐다(부른 쪽이 다음 호출을 보내기 전에 본다) — 문서·후보 원격 객체를 쥐었으면 놓은 뒤 끝낸다(1 회차 — 그냥 끝내 페이지에 남았다).
    /// 업로드는 곧 끝내고 떼기·놓기를 답 뒤의 정리로 넘긴다(`takeUploadCleanup` — W9c③ 적대 리뷰 4 회차 L1). 쥔 것이 없으면 null(부른 쪽이 곧 끝낸다).
    pub fn cancel(self: *Op, gpa: std.mem.Allocator) !?Step {
        self.up_resend = false;
        if (self.stage == .upload) return if (try self.upload.?.cancel(gpa)) |st| try self.uploadRemember(gpa, st) else null;
        if (self.page != null) return null; // 쥔 원격 객체가 없다
        if (self.exec) |*e| return e.cancel(gpa);
        if (self.storage != null) return null; // 쥔 원격 객체가 없다(격리 world 는 이동까지)
        // 덮임 검사·초점 검사·고르기용으로 잡은 그 요소의 원격 객체도(2 회차 — role 상태만 놓았다; 누름 앞이라 누른 것은 없다).
        const holds = switch (self.stage) {
            .frame, .hit_test, .focus_check, .hover_move, .mouse_down, .select, .insert, .delete_down => true,
            .key_down => self.press_target,
            else => false,
        };
        if (self.doc_obj == null and self.cands == null and !holds) return null;
        return try self.releaseThenDone(gpa, .failed, "the request was cancelled");
    }

    /// `sleep` 뒤에 다시 부른다(부른 쪽이 `now_ms` 를 넣은 뒤) — 시한이 지났으면 timeout, 아니면 다음 확인.
    pub fn wake(self: *Op, gpa: std.mem.Allocator) !Step {
        // W9c③: 자리가 없어 못 보낸 업로드의 호출 — 그대로 다시(차례는 그 호출의 답을 기다리는 자리에 그대로 있다).
        if (self.up_resend) {
            self.up_resend = false;
            const l = self.up_last.?;
            return .{ .call = .{ .method = l.method, .params = try gpa.dupe(u8, l.params), .kick = l.kick } };
        }
        return self.uploadRemember(gpa, try self.uploadFix(gpa, try self.wakeInner(gpa)));
    }

    fn wakeInner(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.page) |*p| {
            p.now_ms = self.now_ms;
            return p.wake(gpa);
        }
        if (self.exec) |*e| return e.wake(gpa);
        if (self.storage) |*st| return st.wake(gpa);
        // 떼기를 다시 보낸다(못 보냈던 것 — 철회돼도 committed 라 보낸다).
        if (self.stage == .key_up) return self.keyStep(gpa, false);
        if (self.stage == .mouse_up) return self.mouse(gpa, "mouseReleased");
        if (self.stage == .delete_up) return deleteUp(gpa);
        // kick 을 실은 호출을 자리가 없어 못 보냈다 — 다시.
        if (self.stage == .locate) return self.locateCall(gpa);
        // 포인터 이동은 옛 좌표로 다시 보내지 않는다 — 기다린 사이(최대 4.5 초) 페이지가 바뀌었을 수 있다: 묶음을 놓고 화면 안으로·자리·
        // 덮임 검사부터 다시(4 회차 — 「검사와 이동 사이 왕복 하나」 가 깨졌다).
        if (self.stage == .hover_move) return self.releaseThen(gpa, .scroll);
        if (self.now_ms >= self.wait_deadline_ms) return self.waitTimeout(gpa);
        self.check_start_ms = self.now_ms;
        self.check_wait_ms = 0;
        return if (self.frame_id == null) self.frameTreeStep(gpa) else self.worldStep(gpa);
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        return self.uploadRemember(gpa, try self.uploadFix(gpa, try self.startInner(gpa)));
    }

    /// W9c③: 업로드의 호출을 적어 둔다(승인 뒤 자리 없음이면 그대로 다시 보낸다 — `uploadBusyRetry`). 다른 op 은 그대로.
    fn uploadRemember(self: *Op, gpa: std.mem.Allocator, step: Step) !Step {
        if (self.kind != .upload) return step;
        switch (step) {
            .call => |c| {
                const copy = gpa.dupe(u8, c.params) catch |e| {
                    gpa.free(c.params);
                    return e;
                };
                if (self.up_last) |l| gpa.free(l.params);
                self.up_last = .{ .method = c.method, .params = copy, .kick = c.kick };
            },
            else => {},
        }
        return step;
    }

    /// W9c③: 승인 뒤 호출을 자리 없음(`busy_reason` — 확실히 보내지 않았다)으로 못 보냈다 — 잠깐 뒤 그대로 다시 보낼까(횟수는 kick 재시도와 같다).
    /// 모달 전에는 다시 하지 않는다(에이전트가 다시 부르면 된다 — 아직 아무도 승인하지 않았다).
    fn uploadBusyRetry(self: *Op, reply: Reply) bool {
        const u = if (self.upload) |*x| x else return false;
        if (u.phase != .post) return false;
        if (reply != .not_sent or !std.mem.eql(u8, reply.not_sent, busy_reason)) {
            self.up_busy_retries = 0;
            return false;
        }
        // 적대 리뷰 5 회차 S1: 보낸 넣기를 sidecar 가 자리 없음으로 돌려줬다 — 넣기는 가지 않았다. 다시 보낼 때까지 요청 시한은 「넣었다」 가 아니다
        // (다시 보내면 앱이 `uploadSent` 로 다시 적는다).
        u.markSetRefused();
        if (self.up_last == null or self.up_busy_retries >= max_kick_retries) return false;
        self.up_busy_retries += 1;
        self.up_resend = true;
        return true;
    }

    /// W9c③: 업로드가 요소를 찾기 **전에** 끝났다(없는 요소 — click 의 계약은 `{ok:false}` 성공이지만 업로드는 넣을 곳이 없으면 실패다). 찾은
    /// 뒤(`stage == .upload`)의 답은 업로드 차례의 것이라 그대로.
    fn uploadFix(self: *Op, gpa: std.mem.Allocator, step: Step) !Step {
        if (self.kind != .upload or self.stage == .upload) return step;
        switch (step) {
            .done => |d| if (d.status == .success) {
                const hidden = d.result.len > 0 and d.result[0] == '{' and std.mem.indexOf(u8, d.result, "\"hint\"") != null;
                gpa.free(d.result);
                return done(gpa, .failed, if (hidden) web_cdp_upload.hidden_reason else web_cdp_upload.not_found_reason);
            },
            else => {},
        }
        return step;
    }

    /// W9c③: 승인 뒤 — 사본을 업로드 차례에 주고 로케이터를 **처음부터 다시** 푼다(같은 요소인지는 업로드 차례가 `located` 에서 본다).
    /// 모달 동안 쥔 것은 없다(모달 전에 놓았다).
    pub fn resumeUpload(self: *Op, gpa: std.mem.Allocator, staged: []const web_cdp_upload.Staged) !Step {
        try self.upload.?.beginPost(gpa, staged);
        if (self.matched_name) |m| gpa.free(m);
        self.matched_name = null;
        if (self.frame_id) |f| gpa.free(f);
        self.frame_id = null;
        if (self.loc_found) |*f| f.deinit(gpa);
        self.loc_found = null;
        self.dropRoleState(gpa);
        if (self.then == .done) gpa.free(self.then.done.result);
        self.then = .sleep;
        self.context_id = 0;
        self.hit_up = false;
        self.miss = null;
        self.kick_retries = 0;
        if (self.selector != null) {
            self.backend = 0;
            self.stage = .document;
        } else if (self.loc_role.len > 0 or self.loc_name != null) {
            self.backend = 0;
            self.locating = true;
            self.stage = .document;
        } else self.stage = .scroll; // ref — 같은 번호로(그 번호가 다른 문서에서 다시 쓰여도 loaderId·objectId 가 막는다)
        return self.start(gpa);
    }

    /// W9c③: 곧 보낼 호출이 업로드의 넣기인가 — 앱이 그 앞에서 에이전트 시각을 적는다.
    pub fn uploadSetting(self: *const Op) bool {
        return self.stage == .upload and self.upload.?.setting();
    }

    /// W9c③ 적대 리뷰 3 회차: 업로드가 넣은 뒤 읽기를 보내려 한다 — 앱이 그 호출의 시한을 `web_cdp_upload.verify_wait_ms` 로 줄이고 요청 시한을 그
    /// 뒤로 둔다(읽기가 붙잡히면 요청 시한이 먼저 와 맨 `-32004` 였다).
    pub fn uploadVerifying(self: *const Op) bool {
        return self.stage == .upload and self.upload.?.verifying();
    }

    /// W9c③ 적대 리뷰 4 회차 L1: 앱이 곧 보낼 호출을 실제로 보냈다 — 업로드의 넣기면 적어 둔다(그 뒤의 요청 시한은 「넣었다」 다).
    pub fn uploadSent(self: *Op) void {
        if (self.stage == .upload) self.upload.?.markSetSent();
    }

    /// W9c③ 적대 리뷰 4 회차 L1: 요청 시한에 낼 업로드의 답 — 넣기를 보냈으면 성공 JSON(소유), 아니면 null(맨 시한).
    pub fn uploadLateSuccess(self: *const Op, gpa: std.mem.Allocator) !?[]u8 {
        const u = if (self.upload) |*x| x else return null;
        return u.lateSuccessJson(gpa);
    }

    /// W9c③ 적대 리뷰 4 회차 L1: 끝난 업로드가 남긴 정리 호출(떼기·놓기)을 하나씩 — 앱이 요청과 묶지 않고 보낸다. 업로드가 아니면 null.
    pub fn takeUploadCleanup(self: *Op, gpa: std.mem.Allocator) !?Step {
        const u = if (self.upload) |*x| x else return null;
        return u.takeCleanup(gpa);
    }

    fn startInner(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.page) |*p| {
            p.now_ms = self.now_ms;
            return p.start(gpa);
        }
        if (self.exec) |*e| return e.start(gpa);
        if (self.storage) |*st| return st.start(gpa);
        return switch (self.kind) {
            // 로케이터 — 먼저 페이지 크기를 보고(격리 world) 접근성 질의로 찾는다.
            .click, .type_text, .scroll, .hover, .press, .upload => if (self.locating) self.frameTreeStep(gpa) else switch (self.kind) {
                .press => self.startPress(gpa),
                else => self.startAct(gpa),
            },
            .back, .forward => blk: {
                self.stage = .history;
                break :blk call(gpa, "Page.getNavigationHistory", "", .{});
            },
            .reload => blk: {
                self.stage = .reload;
                break :blk call(gpa, "Page.reload", "", .{});
            },
            .wait => blk: {
                self.wait_deadline_ms = self.now_ms + self.wait_timeout_ms;
                self.wait_start_ms = self.now_ms;
                self.check_start_ms = self.now_ms;
                break :blk self.frameTreeStep(gpa);
            },
            .snapshot => if (self.selector != null) call(gpa, "DOM.getDocument", "{{\"depth\":0}}", .{}) else self.axStep(gpa),
            .navigate, .get_url, .screenshot, .execute_script, .get_local_storage, .set_local_storage, .remove_local_storage, .get_cookies, .set_cookie, .delete_cookie, .clear_storage => unreachable, // `page`·`exec`·`storage` 가 맡는다
        };
    }

    fn startPress(self: *Op, gpa: std.mem.Allocator) !Step {
        if (!self.press_target) return self.frameStep(gpa);
        return self.startAct(gpa);
    }

    /// 누르기 전 프레임(W9b③) — 숨긴 탭이 숨은 채 새 문서를 받으면 그 뒤 첫 누르기(마우스·키)가 페이지에 닿지 않는다. 답을 받은 뒤
    /// `afterFrame` 으로. click 만 했다가 press·Delete 키도 같았다(3 회차 실측: 새 숨긴 탭의 Enter 넷 모두 ok, 닿은 것은 click 뒤 둘).
    fn frameStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .frame;
        return call(gpa, "Page.captureScreenshot", "{s}", .{frame_params});
    }

    fn afterFrame(self: *Op, gpa: std.mem.Allocator) !Step {
        return switch (self.kind) {
            .press => self.keyStep(gpa, true),
            .type_text => blk: {
                self.stage = .delete_down;
                self.sent_input = true;
                break :blk call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyDown\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
            },
            else => self.hitTestCall(gpa, self.object_id.?),
        };
    }

    fn startAct(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.selector != null) return call(gpa, "DOM.getDocument", "{{\"depth\":0}}", .{});
        if (self.backend == 0) return done(gpa, .success, "false");
        return self.scrollStep(gpa);
    }

    /// text·label 을 격리 world 의 JS 로 찾는다 — deep 직렬화로 backendNodeId 를 바로 받고, 쥔 원격 객체(답에 늘 objectId 가 온다 — 실측)는
    /// 묶음 `maru-w9b-<id>` 에 넣어 곧 놓는다.
    fn findStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .loc_find;
        const action: []const u8 = switch (self.kind) {
            .click => "click",
            .hover => "hover",
            .type_text => "type",
            .press => "press",
            .wait => "wait",
            // 업로드는 type 처럼 — 라벨이면 그 라벨의 칸(파일 입력칸)으로 옮긴다.
            .upload => "type",
            else => "scroll",
        };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        writeFindParams(&s, self, action) catch return error.OutOfMemory;
        self.heavy_start_ms = self.now_ms;
        // wait 의 확인은 kick 과 함께 — 숨은 탭에서 rAF·애니메이션으로 나타나는 요소도 보게(계획 공격 3 회차).
        return .{ .call = .{ .method = "Runtime.callFunctionOn", .params = try aw.toOwnedSlice(), .kick = if (self.kind == .wait) .best_effort else .none } };
    }

    fn writeFindParams(s: *std.json.Stringify, self: *const Op, action: []const u8) !void {
        try s.beginObject();
        try s.objectField("functionDeclaration");
        try s.write(finder_js);
        try s.objectField("executionContextId");
        try s.write(self.context_id);
        try s.objectField("arguments");
        try s.beginArray();
        for ([_]?[]const u8{ if (self.loc_kind == .text) "text" else "label", self.loc_name.? }) |a| {
            try s.beginObject();
            try s.objectField("value");
            try s.write(a.?);
            try s.endObject();
        }
        try s.beginObject();
        try s.objectField("value");
        try s.write(self.loc_exact);
        try s.endObject();
        try s.beginObject();
        try s.objectField("value");
        if (self.loc_nth) |n| try s.write(n) else try s.write(null);
        try s.endObject();
        try s.beginObject();
        try s.objectField("value");
        try s.write(action);
        try s.endObject();
        try s.endArray();
        try s.objectField("serializationOptions");
        try s.beginObject();
        try s.objectField("serialization");
        try s.write("deep");
        try s.objectField("maxDepth");
        try s.write(2);
        try s.endObject();
        try s.objectField("objectGroup");
        var buf: [32]u8 = undefined;
        try s.write(std.fmt.bufPrint(&buf, "maru-w9b-{d}", .{self.id}) catch unreachable);
        try s.endObject();
    }

    /// 찾기 결과를 둔 채 그 묶음을 놓는다(결과는 놓은 뒤에 쓴다).
    fn findRelease(self: *Op, gpa: std.mem.Allocator, found: web_cdp_locate.Found) !Step {
        if (self.loc_found) |*f| f.deinit(gpa);
        self.loc_found = found;
        self.stage = .loc_release;
        return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
    }

    /// 놓은 뒤 — 찾기 결과대로(놓기의 성공·실패와 무관하다).
    fn afterFind(self: *Op, gpa: std.mem.Allocator) !Step {
        var found = self.loc_found.?;
        self.loc_found = null;
        if (self.wait_visible) switch (found) {
            // 일시적 실패(이동 중·시한·자리 없음)는 다음 확인으로, 멈춤 상한(too_large)·스크립트 오류는 그 답으로.
            .done => |d| {
                if (self.find_transient) {
                    gpa.free(d.msg);
                    self.find_transient = false;
                    return self.sleepOrTimeout(gpa);
                }
                return .{ .done = .{ .status = if (d.status == .timeout) .timeout else .failed, .result = d.msg } };
            },
            .none => |hidden| {
                self.wait_hidden = hidden;
                return self.sleepOrTimeout(gpa);
            },
            .one => |o| {
                defer gpa.free(o.name);
                return self.waitMet(gpa, o.backend, o.name, o.many);
            },
        };
        switch (found) {
            .done => |d| return .{ .done = .{ .status = if (d.status == .timeout) .timeout else .failed, .result = d.msg } },
            .none => |hidden| {
                if (hidden == 0) return done(gpa, .success, "false");
                // 숨은 일치만 있었다 — 계약(없으면 ok:false)은 지키고 안내를 싣는다(흔한 예: 숨긴 커스텀 체크박스와 보이는 label).
                const msg = try std.fmt.allocPrint(gpa, "{{\"ok\":false,\"hint\":\"{d} matching element(s) are hidden (not rendered, aria-hidden or off-page) — for a hidden checkbox or radio, use its visible label with a text locator\"}}", .{hidden});
                return .{ .done = .{ .status = .success, .result = msg } };
            },
            .one => |o| {
                found = undefined;
                self.backend = o.backend;
                self.matched_name = try clipName(gpa, o.name, max_matched_name_bytes);
                self.locating = false;
                self.hit_up = true;
                return self.scrollStep(gpa);
            },
        }
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        if (self.uploadBusyRetry(reply)) return .{ .sleep = kick_retry_ms };
        if (self.stage == .upload) return self.uploadRemember(gpa, try self.upload.?.feed(gpa, reply));
        return self.uploadRemember(gpa, try self.uploadFix(gpa, try self.feedInner(gpa, reply)));
    }

    fn feedInner(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        if (self.page) |*p| {
            p.now_ms = self.now_ms;
            return p.feed(gpa, reply);
        }
        if (self.exec) |*e| return e.feed(gpa, reply);
        if (self.storage) |*st| return st.feed(gpa, reply);
        // 누르기 전 프레임의 답(무엇이든 — 오류여도 그린 뒤다) — 덮임 검사·키·Delete 로. 못 보냈으면 아래에서 놓고 실패.
        if (self.stage == .frame and reply != .not_sent) return self.afterFrame(gpa);
        // 입력을 보낸 뒤 대화상자 이유 — 입력은 갔다(3 회차: 실패로 답해 다시 하면 두 번 제출됐다).
        // 누름·넣기 단계의 not_sent 는 확실히 보내지 않은 것이다 — 「갔다」 가 아니다(4 회차: 넣기를 못 보냈는데 dialog:true 성공이었다).
        const unsent_input = reply == .not_sent and (self.stage == .insert or self.stage == .key_down or self.stage == .mouse_down or self.stage == .delete_down);
        if (self.sent_input and !unsent_input) switch (reply) {
            .failed, .not_sent => |why| if (std.mem.eql(u8, why, dialog_reason)) {
                self.dialog = true;
            },
            else => {},
        };
        // 찾기 결과를 둔 채 놓는 중 — 놓기의 답(무엇이든) 뒤에 그 결과대로.
        if (self.stage == .loc_release) return self.afterFind(gpa);
        // 묶음을 놓았다(무엇이든) — 정해 둔 다음 일로.
        if (self.stage == .rel_then) return self.afterRelThen(gpa);
        // kick 쌍이 갔다 — 다음 kick 호출은 다시 처음부터 센다(1 회차 — 한 op 안에서 횟수를 나눠 써 뒤의 호출은 다시 보내지 못했다).
        // (그 사이 다른 답 — hover 를 다시 재는 동안의 상자·덮임 검사 — 으로는 세지 않는다: 끝없이 다시 재지 않게, 4 회차)
        if (reply != .not_sent and (self.stage == .locate or self.stage == .hover_move)) self.kick_retries = 0;
        // 찾기 호출 자체가 실패·시한 — 쥔 객체가 있을 수 있어 놓은 뒤 그 이유로 끝낸다.
        if (self.stage == .loc_find) switch (reply) {
            // 답은 곧장 해석해 놓기로 — 공통 JSON 파싱이 깨진 답에 놓지 않고 끝내던 것(1 회차).
            .ok => |b| {
                const found = web_cdp_locate.parseFound(gpa, b, if (self.loc_kind == .text) "text" else "label", self.loc_name.?, self.loc_exact) catch |e| switch (e) {
                    error.OutOfMemory => return self.findRelease(gpa, .{ .done = .{ .status = .failed, .msg = try gpa.dupe(u8, "out of memory") } }),
                    else => web_cdp_locate.Found{ .done = .{ .status = .failed, .msg = try gpa.dupe(u8, "malformed locator result") } },
                };
                self.heavyEnd();
                return self.findRelease(gpa, found);
            },
            .cdp_error => self.find_transient = self.wait_visible,
            .timed_out => |why| {
                self.find_transient = self.wait_visible;
                return self.findRelease(gpa, .{ .done = .{ .status = .timeout, .msg = try gpa.dupe(u8, why) } });
            },
            .not_sent => |why| {
                self.find_transient = self.wait_visible;
                return self.findRelease(gpa, .{ .done = .{ .status = .failed, .msg = try gpa.dupe(u8, why) } });
            },
            .failed => |why| return self.findRelease(gpa, .{ .done = .{ .status = .failed, .msg = try gpa.dupe(u8, if (std.mem.eql(u8, why, result_too_large)) "too_large: the locator result was too large — use a selector or ref" else why) } }),
        };
        // 누른 뒤의 시한 — 페이지가 막혀 답이 늦을 뿐 입력은 갔을 수 있다: 떼기·놓기를 마저 보내고 끝에 timeout 으로 답한다.
        if (reply == .timed_out) switch (self.stage) {
            .mouse_down => {
                self.late = reply.timed_out;
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .mouse_up => {
                self.late = reply.timed_out;
                return self.releaseStep(gpa);
            },
            .release => return self.finish(gpa),
            // 고르기·넣기·다시 읽기의 시한 — 묶음을 놓고 timeout(Delete 를 눌렀으면 뗀 뒤).
            .select, .insert, .verify, .delete_up => {
                self.late = reply.timed_out;
                return self.releaseStep(gpa);
            },
            .delete_down => {
                self.late = reply.timed_out;
                self.stage = .delete_up;
                return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyUp\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
            },
            // 움직임의 답이 늦었다(숨긴 탭은 다음 프레임까지 — 실측 5 초) — 놓고 timeout. 덮임 검사·노드 잡기의 시한도 쥔 묶음을
            // 놓는다(적대 리뷰 1 회차 — 곧장 끝내 묶음이 남았다).
            .hover_move, .focus_check, .hit_test, .resolve => {
                self.late = reply.timed_out;
                return self.releaseStep(gpa);
            },
            // 키 누름이 시한 — 그래도 떼기를 보낸다.
            .key_down => {
                self.late = reply.timed_out;
                return self.keyStep(gpa, false);
            },
            .key_up => {
                self.late = reply.timed_out;
                return self.afterKeys(gpa);
            },
            // wait 의 확인이 시한 — 다음 확인으로(시한은 wake 가 본다). 묶음을 쥔 단계면 놓은 뒤.
            .check, .world, .frame_tree, .size_check, .loc_document => if (self.kind == .wait) return self.sleepOrTimeout(gpa),
            .locate, .judge_resolve, .judge => return if (self.kind == .wait) self.releaseThen(gpa, .sleep) else self.releaseThenDone(gpa, .timeout, reply.timed_out),
            else => {},
        };
        // 누름의 답이 실패(보내지 못함·결과가 깨짐) — 이미 갔을 수 있으니 떼기·놓기를 마저 보내고 실패로 답한다(2 회차).
        if (reply == .failed) switch (self.stage) {
            .mouse_down => {
                if (!self.dialog) self.miss = reply.failed;
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .key_down => {
                if (!self.dialog) self.miss = reply.failed;
                return self.keyStep(gpa, false);
            },
            // Delete 누름도 같다 — 떼기를 마저(5 회차 — 시한에는 떼면서 실패에는 떼지 않았다).
            .delete_down => {
                if (!self.dialog) self.miss = reply.failed;
                self.stage = .delete_up;
                return deleteUp(gpa);
            },
            else => {},
        };
        // 입력 뒤 대화상자 — 넣기·떼기·다시 읽기는 답하지 않는다: 다시 읽지 않고 놓기로(놓기는 web_osr 가 대화상자 뒤로 미룬다).
        if (self.dialog and (reply == .failed or reply == .not_sent)) switch (self.stage) {
            .insert, .verify, .delete_up => return self.releaseStep(gpa),
            else => {},
        };
        // kick 을 실은 호출을 자리가 없어 못 보냈다 — 잠깐 뒤 다시(직전 kick 의 답이 아직이면 자리 하나를 쥐고 있다 — 잃은 kick 은
        // sidecar 가 3 초 남짓에 놓는다).
        // 자리 없음(`busy_reason`)일 때만 — 탭이 준비 안 됨·요청 실패는 기다려도 풀리지 않는다(4 회차). wait 은 시한을 넘겨 다시 보내지
        // 않고, 남은 확인(`checkEstimateMs` 로 짐작)이 시한을 2 초 넘게 넘길 것 같아도 다시 보내지 않는다(그때는 아래 「다음 확인」 이 끝낸다).
        const retry_in_time = self.kind != .wait or (self.now_ms + kick_retry_ms < self.wait_deadline_ms and
            self.now_ms + kick_retry_ms + self.checkEstimateMs() <= self.wait_deadline_ms + wait_max_overrun_ms);
        const busy = reply == .not_sent and std.mem.eql(u8, reply.not_sent, busy_reason);
        if (busy and (self.stage == .locate or self.stage == .hover_move) and self.kick_retries < max_kick_retries and retry_in_time) {
            self.kick_retries += 1;
            self.check_wait_ms += kick_retry_ms;
            return .{ .sleep = kick_retry_ms };
        }
        // 페이지가 JS 대화상자로 멈췄다 — wait 은 되풀이해도 시한까지 막힌다: 쥔 묶음을 놓고 곧 그 이유로(W9b③ 적대 리뷰 2 회차).
        if (reply == .not_sent and self.kind == .wait and std.mem.eql(u8, reply.not_sent, dialog_reason)) return self.releaseThenDone(gpa, .failed, dialog_reason);
        // wait 의 확인을 보내지 못했다 — 다음 확인으로(묶음을 쥐었으면 놓은 뒤).
        if (reply == .not_sent and self.kind == .wait) switch (self.stage) {
            .check, .world, .frame_tree, .size_check, .loc_document => return self.sleepOrTimeout(gpa),
            .locate, .judge_resolve, .judge => return self.releaseThen(gpa, .sleep),
            else => {},
        };
        // 누름을 확실히 보내지 않았다 — 떼지 않고, 쥔 묶음만 놓는다.
        if (reply == .not_sent) switch (self.stage) {
            .mouse_down => {
                self.miss = reply.not_sent;
                return self.releaseStep(gpa);
            },
            // Delete 누름도 — 쥔 묶음을 놓고 실패(4 회차: 놓지 않고 끝나 묶음이 이동 전까지 남았다).
            .delete_down => {
                self.miss = reply.not_sent;
                return self.releaseStep(gpa);
            },
            .key_down => {
                self.miss = reply.not_sent;
                return self.afterKeys(gpa);
            },
            else => {},
        };
        // 떼기를 확실히 보내지 못했다 — 잠깐 뒤 다시(세 번까지). 그래도 못 보내면 놓고 실패.
        if (reply == .not_sent and (self.stage == .key_up or self.stage == .mouse_up or self.stage == .delete_up)) {
            if (self.up_retries < max_up_retries) {
                self.up_retries += 1;
                return .{ .sleep = up_retry_ms };
            }
            // 앞선 실패 이유(엔진이 멈춤 등)가 있으면 그것으로 답한다(5 회차 — 「not ready」 가 다시 덮었다). 없으면 「누름은 이미 갔다」 —
            // 자리 없음의 「retry shortly」 를 그대로 주면 다시 해 Enter 가 두 번 간다(적대 리뷰 5 회차).
            if (self.miss == null) self.miss = switch (self.stage) {
                .key_up => "the key was pressed but releasing it could not be sent — the press already reached the page; do not repeat it",
                .mouse_up => "the button was pressed but releasing it could not be sent — the click may have reached the page; do not repeat it",
                else => "a delete key was pressed to clear the field but releasing it could not be sent — nothing was typed; check the field before repeating",
            };
            return if (self.stage == .key_up) self.afterKeys(gpa) else self.releaseStep(gpa);
        }
        if (reply == .failed or reply == .not_sent) {
            const why = if (reply == .failed) reply.failed else reply.not_sent;
            if (self.stage == .locate and std.mem.eql(u8, why, result_too_large))
                return self.releaseThenDone(gpa, .failed, "too_large: the accessibility query result was too large — use a selector or ref"); // exact 는 질의를 줄이지 않는다(2 회차)
            // 문서·후보 묶음을 쥔 단계 — 놓고 그 이유로.
            if (self.stage == .locate or self.stage == .judge_resolve or self.stage == .judge) return self.releaseThenDone(gpa, .failed, why);
            switch (self.stage) {
                // 놓기의 실패 — 동작은 이미 끝났다: 그 결과로 답한다(4 회차 — 실패로 답하면 다시 시도해 Enter 가 두 번 갔다).
                .release => return self.finish(gpa),
                // 원격 객체 묶음을 쥔 단계의 실패 — 놓고 실패(4 회차 — 곧장 끝내 묶음이 남았다).
                .resolve, .frame, .hit_test, .focus_check, .hover_move, .select, .insert, .delete_up, .verify => {
                    if (self.miss == null) self.miss = why;
                    return self.releaseStep(gpa);
                },
                // 떼기의 실패(보냈을 수도) — 누름은 갔다: 실패로 덮지 않고 놓은 뒤 동작의 결과로(5 회차 — 결과가 깨진 답에도 실패였다).
                .key_up => return self.afterKeys(gpa),
                .mouse_up => return self.releaseStep(gpa),
                else => {},
            }
        }
        const bytes = switch (reply) {
            .failed, .not_sent => |why| return done(gpa, .failed, why),
            .timed_out => |why| return done(gpa, .timeout, why),
            .cdp_error => |e| return self.cdpError(gpa, e),
            .ok => |b| b,
        };
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return done(gpa, .failed, "malformed DevTools result");
        defer parsed.deinit();
        const v = parsed.value;
        switch (self.stage) {
            .document => {
                const root = intAt(v, &.{ "root", "nodeId" }) orelse return done(gpa, .failed, "no document");
                self.stage = .query;
                return call(gpa, "DOM.querySelector", "{{\"nodeId\":{d},\"selector\":{f}}}", .{ root, std.json.fmt(self.selector.?, .{}) });
            },
            .query => {
                const node = intAt(v, &.{"nodeId"}) orelse 0;
                if (node == 0) return self.missing(gpa); // 없는 요소 — WebKit 과 같다
                self.stage = .describe;
                return call(gpa, "DOM.describeNode", "{{\"nodeId\":{d}}}", .{node});
            },
            .describe => {
                self.backend = intAt(v, &.{ "node", "backendNodeId" }) orelse return self.missing(gpa);
                if (self.kind == .snapshot) {
                    self.snap.root_backend = self.backend;
                    return self.axStep(gpa);
                }
                return self.scrollStep(gpa);
            },
            .scroll => switch (self.kind) {
                .scroll => return self.succeed(gpa),
                .type_text, .press => {
                    self.stage = .focus;
                    return call(gpa, "DOM.focus", "{{\"backendNodeId\":{d}}}", .{self.backend});
                },
                else => {
                    self.stage = .quads;
                    return call(gpa, "DOM.getContentQuads", "{{\"backendNodeId\":{d}}}", .{self.backend});
                },
            },
            .focus => return self.frameTreeStep(gpa),
            .quads => {
                self.box_count = collectBoxes(v, &self.boxes);
                if (self.box_count == 0) return done(gpa, .failed, "the element has no visible box");
                self.stage = .metrics;
                return call(gpa, "Page.getLayoutMetrics", "", .{});
            },
            .metrics => {
                // 상자와 화면이 겹친 곳의 가운데 — 화면보다 큰 요소의 가운데가 화면 밖이어도 보이는 곳을 누른다.
                const w = numberAt(v, &.{ "cssLayoutViewport", "clientWidth" }) orelse return done(gpa, .failed, "no viewport");
                const h = numberAt(v, &.{ "cssLayoutViewport", "clientHeight" }) orelse return done(gpa, .failed, "no viewport");
                const picked = for (self.boxes[0..self.box_count]) |box| {
                    const left = @max(box[0], 0);
                    const top = @max(box[1], 0);
                    const right = @min(box[2], w);
                    const bottom = @min(box[3], h);
                    if (right > left and bottom > top) break [4]f64{ left, top, right, bottom };
                } else return done(gpa, .failed, "the element is outside the viewport");
                self.x = (picked[0] + picked[2]) / 2;
                self.y = (picked[1] + picked[3]) / 2;
                return self.frameTreeStep(gpa);
            },
            .frame_tree => {
                const fid = stringAt(v, &.{ "frameTree", "frame", "id" }) orelse return done(gpa, .failed, "no main frame");
                if (self.frame_id) |old| gpa.free(old); // 로케이터가 찾을 때 한 번, 그 뒤 click 이 다시 받는다
                self.frame_id = try gpa.dupe(u8, fid);
                return self.worldStep(gpa);
            },
            .world => {
                self.context_id = intAt(v, &.{"executionContextId"}) orelse return done(gpa, .failed, "no isolated world");
                if (self.locating and self.loc_kind != .role) return self.findStep(gpa);
                if (self.locating) {
                    // 요소 수를 먼저 본다 — 접근성 질의는 DOM 크기의 제곱으로 느려지고 그동안 페이지가 멈춘다(프로토타입 함수 — DOM clobbering).
                    self.stage = .size_check;
                    self.heavy_start_ms = self.now_ms;
                    // open shadow root 안도 센다(1 회차 — 셀 때 빠져 6 만 요소 페이지가 상한을 지나 2.8 초 멈췄다). 상한을 넘으면 곧 멈춘다.
                    // 접근성 트리를 비싸게 만드는 구성도 함께 센다(3·4 회차 — 어떤 역할을 찾든 질의마다 트리를 새로 만든다): 대상 없는 같은 문서
                    // fragment 링크(Chromium 처럼 URL 을 풀어 같은 문서인지 본다 — 대상은 그 트리 범위의 id 로), radio, role=radio, 라벨이 붙은
                    // 컨트롤, 블록마다 줄 상자 수의 제곱 합(긴 글 노드의 Range 사각형 — 보이지 않는 글은 0, textarea 는 값의 줄)과 글 노드 수의
                    // 제곱 합(5 회차). 상한을 넘으면 그 자리에서 멈춘다. 결과는 [요소, …](web_cdp_locate.costly 순서).
                    const expr = try std.fmt.allocPrint(gpa, "(function(LIM){{var G=function(p,k){{return Object.getOwnPropertyDescriptor(p,k).get}},sr=G(Element.prototype,'shadowRoot'),eid=G(Element.prototype,'id'),qa=Document.prototype.querySelectorAll,fa=DocumentFragment.prototype.querySelectorAll,ga=Element.prototype.getAttribute,ctl=G(HTMLLabelElement.prototype,'control'),ah=G(HTMLAnchorElement.prototype,'href'),arh=G(HTMLAreaElement.prototype,'href'),durl=G(Document.prototype,'URL'),tw=Document.prototype.createTreeWalker,nx=TreeWalker.prototype.nextNode,dat=G(CharacterData.prototype,'data'),tav=G(HTMLTextAreaElement.prototype,'value'),pe=G(Node.prototype,'parentElement'),tag=G(Element.prototype,'tagName'),mk=Document.prototype.createRange,sel=Range.prototype.selectNodeContents,rects=Range.prototype.getClientRects,rl=G(DOMRectList.prototype,'length'),S=String.prototype,base=function(u){{var i=S.indexOf.call(u,'#');return i<0?u:S.slice.call(u,0,i)}},lines=function(t){{var c=0,i=-1;while((i=S.indexOf.call(t,'\\n',i+1))>=0)c++;return c}},skip={{SCRIPT:1,STYLE:1,TEMPLATE:1,NOSCRIPT:1}},doc=base(durl.call(document)),C=[0,0,0,0,0,0,0],over=function(){{for(var k=0;k<7;k++)if(C[k]>LIM[k])return true;return false}},todo=[document];while(todo.length){{var r=todo.pop(),q=r===document?qa:fa,l=q.call(r,'*');C[0]+=l.length;if(over())return C;var ids=new Set(),wid=q.call(r,'[id]');for(var k=0;k<wid.length;k++)ids.add(eid.call(wid[k]));var links=q.call(r,'a[*|href],area[href]');for(var k=0;k<links.length;k++){{var a=links[k],f=null;if(a instanceof HTMLAnchorElement||a instanceof HTMLAreaElement){{var u=(a instanceof HTMLAreaElement?arh:ah).call(a),hi=S.indexOf.call(u,'#');if(hi>=0&&base(u)===doc)f=S.slice.call(u,hi+1)}}else{{var h=S.trim.call(ga.call(a,'href')||ga.call(a,'xlink:href')||'');if(S.charAt.call(h,0)==='#')f=S.slice.call(h,1)}}if(!f)continue;var d=f;try{{d=decodeURIComponent(f)}}catch(e){{}}if(!ids.has(f)&&!ids.has(d))C[1]++}}C[2]+=q.call(r,'input[type=radio]').length;C[3]+=q.call(r,'[role~=radio i]').length;var lbs=q.call(r,'label');for(var k=0;k<lbs.length;k++)if(ctl.call(lbs[k]))C[4]++;var per=new Map(),w=tw.call(document,r,4),t;while((t=nx.call(w))){{var p=pe.call(t);if(!p||skip[tag.call(p)])continue;var e=per.get(p);if(!e){{e=[0,0];per.set(p,e)}}e[0]++;var dt=dat.call(t);if(dt.length>=2000){{var rg=mk.call(document);sel.call(rg,t);e[1]+=rl.call(rects.call(rg))}}}}per.forEach(function(e){{C[5]+=e[1]*e[1];C[6]+=e[0]*e[0]}});var tas=q.call(r,'textarea');for(var k=0;k<tas.length;k++){{var c=lines(tav.call(tas[k]));C[5]+=c*c}}if(over())return C;for(var i=0;i<l.length;i++){{var s=sr.call(l[i]);if(s)todo.push(s)}}}}return C}})([{d},{d},{d},{d},{d},{d},{d}])", .{ web_cdp_locate.max_role_page_elements, web_cdp_locate.costly[0].limit, web_cdp_locate.costly[1].limit, web_cdp_locate.costly[2].limit, web_cdp_locate.costly[3].limit, web_cdp_locate.costly[4].limit, web_cdp_locate.costly[5].limit });
                    defer gpa.free(expr);
                    return call(gpa, "Runtime.evaluate", "{{\"expression\":{f},\"contextId\":{d},\"returnByValue\":true}}", .{ std.json.fmt(expr, .{}), self.context_id });
                }
                if (self.kind == .wait) {
                    // 한 번 확인한다(격리 world — 이동했으면 새 문서의 world 다, 객체를 쥐지 않는다).
                    self.stage = .check;
                    const expr = try std.fmt.allocPrint(gpa, "(function(sel,load){{try{{var D=Document.prototype;if(load)return Object.getOwnPropertyDescriptor(D,'readyState').get.call(document)==='complete';var e=D.querySelector.call(document,sel);if(!e)return false;var r=Element.prototype.getBoundingClientRect.call(e),cs=getComputedStyle(e);return r.width>0&&r.height>0&&cs.visibility!=='hidden'&&cs.display!=='none'}}catch(x){{return 'error'}}}})({f},{})", .{ std.json.fmt(self.wait_selector orelse "", .{}), self.wait_selector == null });
                    defer gpa.free(expr);
                    var step = try call(gpa, "Runtime.evaluate", "{{\"expression\":{f},\"contextId\":{d},\"returnByValue\":true}}", .{ std.json.fmt(expr, .{}), self.context_id });
                    step.call.kick = .best_effort; // 숨은 탭에서도 rAF·애니메이션으로 나타나는 요소를 보게(W9b②-3)
                    return step;
                }
                self.stage = .resolve;
                return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.backend, self.context_id, self.id });
            },
            .resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" }) orelse return done(gpa, .success, "false");
                if (self.kind == .press) {
                    // 초점이 아직 그 요소인가(type 과 같은 걷기 — 요소의 root 에서 host 를 따라 문서까지). 아니면 누르지 않는다.
                    self.stage = .focus_check;
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(){{var t=this,P=function(o,k){{return Object.getOwnPropertyDescriptor(o,k).get}};if((P(Node.prototype,'ownerDocument').call(t)||t)!==document)return 'frame';var gr=Node.prototype.getRootNode,dae=P(Document.prototype,'activeElement'),sae=P(ShadowRoot.prototype,'activeElement'),host=P(ShadowRoot.prototype,'host'),ce=P(HTMLElement.prototype,'isContentEditable');var cur=t,root=gr.call(cur);for(var i=0;i<64;i++){{var ae=(root instanceof ShadowRoot)?sae.call(root):(root instanceof Document)?dae.call(root):null;if(ae!==cur&&!(cur===t&&ae&&(t instanceof HTMLElement)&&ce.call(t)&&Node.prototype.contains.call(t,ae)))return 'focus moved';if(!(root instanceof ShadowRoot))return 'ok';cur=host.call(root);root=gr.call(cur)}}return 'focus moved'}}\",\"returnByValue\":true}}", .{std.json.fmt(oid, .{})});
                }
                if (self.kind == .type_text) {
                    self.object_id = try gpa.dupe(u8, oid);
                    // 격리 world 에서 그 요소의 글을 고른다(입력칸·글 상자·contenteditable) — 그 위에 넣으면 바꿔 쓴다(WebKit 의 type 과 같다).
                    // 프로토타입 함수·getter 로 부른다(DOM clobbering).
                    self.stage = .select;
                    return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(){{var t=this,P=function(o,k){{return Object.getOwnPropertyDescriptor(o,k).get}};var od=P(Node.prototype,'ownerDocument');if((od.call(t)||t)!==document)return {{r:'frame'}};var ok=false,before='',H=function(s){{var h=2166136261;for(var i=0;i<s.length;i++){{h=Math.imul(h^String.prototype.charCodeAt.call(s,i),16777619)}}return h|0}};var val=function(e){{return (e instanceof HTMLInputElement)?P(HTMLInputElement.prototype,'value').call(e):(e instanceof HTMLTextAreaElement)?P(HTMLTextAreaElement.prototype,'value').call(e):P(Node.prototype,'textContent').call(e)}};if(t instanceof HTMLInputElement){{var ty=P(HTMLInputElement.prototype,'type').call(t);if(!{{text:1,search:1,url:1,tel:1,email:1,password:1,number:1}}[ty])return {{r:'not editable'}};before=val(t);HTMLInputElement.prototype.select.call(t);ok=true}}else if(t instanceof HTMLTextAreaElement){{before=val(t);HTMLTextAreaElement.prototype.select.call(t);ok=true}}else if(t instanceof HTMLElement&&P(HTMLElement.prototype,'isContentEditable').call(t)){{before=val(t);var d=od.call(t);var g=Document.prototype.getSelection.call(d),r=Document.prototype.createRange.call(d);Range.prototype.selectNodeContents.call(r,t);Selection.prototype.removeAllRanges.call(g);Selection.prototype.addRange.call(g,r);ok=true}}if(!ok)return {{r:'not editable'}};var gr=Node.prototype.getRootNode,dae=P(Document.prototype,'activeElement'),sae=P(ShadowRoot.prototype,'activeElement'),host=P(ShadowRoot.prototype,'host'),ce=P(HTMLElement.prototype,'isContentEditable');var cur=t,root=gr.call(cur);for(var i=0;i<64;i++){{var ae=(root instanceof ShadowRoot)?sae.call(root):(root instanceof Document)?dae.call(root):null;if(ae!==cur&&!(cur===t&&ae&&ce.call(t)&&Node.prototype.contains.call(t,ae)))return {{r:'focus moved'}};if(!(root instanceof ShadowRoot))return {{r:'ok',h:H(before),n:before.length}};cur=host.call(root);root=gr.call(cur)}}return {{r:'focus moved'}}}}\",\"returnByValue\":true}}", .{std.json.fmt(oid, .{})});
                }
                if (self.kind == .click) {
                    // 누르기 전에 프레임 하나를 그리게 하고 그 답을 기다린다 — 숨긴 탭이 숨은 채 새 문서를 받으면 그 뒤 첫 마우스 누르기가
                    // 페이지에 닿지 않았다(W9b③ 계획 공격 2 회차 실측: 제품 차례로 0/3, 2 초 기다려도 0/3 — 답은 「눌렀다」). 1×1 스크린샷을
                    // kick 으로 곁들이면 그 프레임이 누르기보다 늦을 수 있어(6 번 가운데 3–5 번) 보통 호출로 보내 답을 받은 뒤 덮임 검사로 간다
                    // (20/20). 보이는 탭에서는 GPU 약 3 ms 의 왕복 하나다. hover 의 이동·글 넣기는 새 숨은 문서에서도 닿았다(3/3). 키는 계획 공격
                    // 때 닿았지만 적대 리뷰 3 회차에 새 숨긴 탭의 Enter 가 닿지 않았다 — press·Delete 도 같은 단계를 거친다(`frameStep`).
                    self.object_id = try gpa.dupe(u8, oid);
                    return self.frameStep(gpa);
                }
                return self.hitTestCall(gpa, oid);
            },
            .frame => unreachable, // 답은 위에서 덮임 검사로 넘겼다
            .hit_test => {
                if (at(v, &.{"exceptionDetails"}) != null) {
                    self.miss = "could not check what is at the element's position";
                    return self.releaseStep(gpa);
                }
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                if (std.mem.eql(u8, verdict, "frame")) {
                    self.miss = "elements inside frames are not supported yet";
                    return self.releaseStep(gpa);
                }
                if (!std.mem.eql(u8, verdict, "ok")) {
                    self.miss = "the element is covered by another element at its center";
                    return self.releaseStep(gpa);
                }
                // 맞았다 — 그 자리로 포인터를 옮긴다(누르지 않는다 — 페이지는 isTrusted mouseover·:hover).
                if (self.kind == .hover) return self.hoverMove(gpa);
                // 맞았다 — 왕복 하나 안에 누른다(놓기는 뗀 뒤).
                self.stage = .mouse_down;
                self.sent_input = true;
                return self.mouse(gpa, "mousePressed");
            },
            .hover_move => return self.releaseStep(gpa),
            .focus_check => {
                if (at(v, &.{"exceptionDetails"}) != null) {
                    self.miss = "could not check the focus";
                    return self.releaseStep(gpa);
                }
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                if (std.mem.eql(u8, verdict, "frame")) {
                    // 같은 출처 iframe 안의 요소(ref) — 격리 world 는 주 frame 의 것이라 그 frame 의 초점을 볼 수 없다.
                    self.miss = "elements inside frames are not supported yet";
                    return self.releaseStep(gpa);
                }
                if (!std.mem.eql(u8, verdict, "ok")) {
                    self.miss = "focus moved away from the element (the page moved it) — no key was pressed";
                    return self.releaseStep(gpa);
                }
                return self.frameStep(gpa);
            },
            .key_down => return self.keyStep(gpa, false),
            .key_up => return self.afterKeys(gpa),
            .mouse_down => {
                self.stage = .mouse_up;
                return self.mouse(gpa, "mouseReleased");
            },
            .mouse_up => return self.releaseStep(gpa),
            .release => return self.finish(gpa),
            .history => {
                const current = intAt(v, &.{"currentIndex"}) orelse return done(gpa, .failed, "no navigation history");
                const entries = arrayAt(v, &.{"entries"}) orelse return done(gpa, .failed, "no navigation history");
                const target: i64 = if (self.kind == .back) current - 1 else current + 1;
                if (target < 0 or target >= entries.len) return done(gpa, .success, "false"); // 갈 곳이 없다
                const entry_id = intAt(entries[@intCast(target)], &.{"id"}) orelse return done(gpa, .failed, "no navigation history");
                self.stage = .navigate_entry;
                return call(gpa, "Page.navigateToHistoryEntry", "{{\"entryId\":{d}}}", .{entry_id});
            },
            .navigate_entry, .reload => return done(gpa, .success, "true"),
            .select => {
                const verdict = stringAt(v, &.{ "result", "value", "r" }) orelse "";
                self.before_hash = intAt(v, &.{ "result", "value", "h" }) orelse -1;
                self.before_len = intAt(v, &.{ "result", "value", "n" }) orelse 0;
                if (std.mem.eql(u8, verdict, "frame")) {
                    self.miss = "elements inside frames are not supported yet";
                    return self.releaseStep(gpa);
                }
                if (std.mem.eql(u8, verdict, "focus moved")) {
                    // 페이지가 초점을 다른 곳으로 옮겼다(모달의 초점 가두기 등) — 넣으면 엉뚱한 칸(다른 출처 iframe 일 수도)에 간다.
                    self.miss = "focus moved away from the element (the page moved it) — nothing was typed";
                    return self.releaseStep(gpa);
                }
                if (!std.mem.eql(u8, verdict, "ok")) {
                    self.miss = "the element is not editable";
                    return self.releaseStep(gpa);
                }
                // 빈 글이면 고른 것을 지운다(Delete 키 — 진짜 입력). 아니면 고른 것 위에 넣는다(`Input.insertText` — 한 번의 입력 이벤트).
                if (self.text.?.len == 0) return self.frameStep(gpa);
                self.stage = .insert;
                self.sent_input = true;
                return call(gpa, "Input.insertText", "{{\"text\":{f}}}", .{std.json.fmt(self.text.?, .{})});
            },
            .delete_down => {
                self.stage = .delete_up;
                return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyUp\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
            },
            .insert, .delete_up => {
                // 넣은 뒤 다시 읽는다 — readonly·disabled·maxlength·형식(number 에 글자)은 insertText 가 조용히 안 넣거나 자른다.
                self.stage = .verify;
                return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(want,bh,bn){{var t=this,P=function(o,k){{return Object.getOwnPropertyDescriptor(o,k).get}},S=String.prototype,J=Array.prototype.join,H=function(s){{var h=2166136261;for(var i=0;i<s.length;i++){{h=Math.imul(h^String.prototype.charCodeAt.call(s,i),16777619)}}return h|0}};var same=function(s){{return s.length===bn&&H(s)===bh}};var flat=function(s){{return J.call(S.split.call(J.call(S.split.call(s,String.fromCharCode(13)),''),String.fromCharCode(10)),'')}};var field=(t instanceof HTMLInputElement)||(t instanceof HTMLTextAreaElement);var v=(t instanceof HTMLInputElement)?P(HTMLInputElement.prototype,'value').call(t):(t instanceof HTMLTextAreaElement)?P(HTMLTextAreaElement.prototype,'value').call(t):P(Node.prototype,'textContent').call(t);if(v===want)return 'ok';if(field&&(v===S.trim.call(want)||v===flat(want)||v===S.trim.call(flat(want))))return 'ok';if(same(v)&&!same(want))return 'rejected';if(field&&v.length<want.length&&S.indexOf.call(want,v)===0)return 'rejected';if(bn>0&&v.length===bn+want.length&&((S.slice.call(v,bn)===want&&same(S.slice.call(v,0,bn)))||(S.slice.call(v,0,want.length)===want&&same(S.slice.call(v,want.length)))))return 'rejected';return 'ok'}}\",\"arguments\":[{{\"value\":{f}}},{{\"value\":{d}}},{{\"value\":{d}}}],\"returnByValue\":true}}", .{ std.json.fmt(self.object_id.?, .{}), std.json.fmt(self.text.?, .{}), self.before_hash, self.before_len });
            },
            .verify => {
                const verdict = stringAt(v, &.{ "result", "value" }) orelse "";
                // 값이 바뀌지 않았거나·넣은 글의 앞부분으로 잘렸거나·원래 값 앞뒤에 덧붙었을 때만 거절한다 — 칸의 줄바꿈·앞뒤 공백 정리,
                // 입력 마스크가 바꾼 값은 들어간 것이다.
                if (!std.mem.eql(u8, verdict, "ok")) self.miss = "the field did not take the text (read-only, disabled, a length limit or its type)";
                return self.releaseStep(gpa);
            },
            .size_check => {
                self.heavyEnd();
                const counts = arrayAt(v, &.{ "result", "value" }) orelse return done(gpa, .failed, "could not count the page's elements");
                if (counts.len != 1 + web_cdp_locate.costly.len) return done(gpa, .failed, "could not count the page's elements");
                for (counts) |c| if (c != .integer or c.integer < 0) return done(gpa, .failed, "could not count the page's elements");
                const count = counts[0].integer;
                // 상한들은 더해진다 — 상한 대비 비율의 합이 1 을 넘으면 거절(4 회차).
                var load: f64 = 0;
                for (web_cdp_locate.costly, counts[1..]) |c, n| load += @as(f64, @floatFromInt(n.integer)) / @as(f64, @floatFromInt(c.limit));
                if (load > 1.0) {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    defer aw.deinit();
                    aw.writer.writeAll("too_large: the accessibility query would freeze this page (") catch return error.OutOfMemory;
                    var first = true;
                    for (web_cdp_locate.costly, counts[1..]) |c, n| if (n.integer > 0) {
                        // 제곱 합은 「블록 하나로 치면」 제곱근으로 보인다.
                        const shown = if (c.squared) std.math.sqrt(@as(u64, @intCast(n.integer))) else @as(u64, @intCast(n.integer));
                        const lim = if (c.squared) std.math.sqrt(@as(u64, @intCast(c.limit))) else @as(u64, @intCast(c.limit));
                        aw.writer.print("{s}{s}{d} {s} (limit {d})", .{ if (first) "" else ", ", if (c.squared) "~" else "", shown, c.what, lim }) catch return error.OutOfMemory;
                        first = false;
                    };
                    aw.writer.writeAll(") — use a selector or ref") catch return error.OutOfMemory;
                    return .{ .done = .{ .status = .failed, .result = try aw.toOwnedSlice() } };
                }
                if (count > web_cdp_locate.max_role_page_elements) {
                    const msg = try std.fmt.allocPrint(gpa, "too_large: page has {d} elements (role locator limit {d}; the query freezes the page) — use a selector or ref", .{ count, web_cdp_locate.max_role_page_elements });
                    return .{ .done = .{ .status = .failed, .result = msg } };
                }
                // 질의 대상 = 이 확인의 격리 world 의 document(묶음 안) — 이동하면 곧바로 오류다(W9b②-3 계획 공격 1 회차).
                self.stage = .loc_document;
                return call(gpa, "Runtime.evaluate", "{{\"expression\":\"document\",\"contextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ self.context_id, self.id });
            },
            .loc_document => {
                const oid = stringAt(v, &.{ "result", "objectId" }) orelse return done(gpa, .failed, "no document");
                if (self.doc_obj) |old| gpa.free(old);
                self.doc_obj = try gpa.dupe(u8, oid);
                return self.locateCall(gpa);
            },
            .locate => {
                self.heavyEnd();
                const q: web_cdp_locate.RoleQuery = .{ .role = self.loc_role, .name = self.loc_name, .level = self.loc_level, .exact = self.loc_exact, .nth = self.loc_nth };
                if (self.wait_visible) {
                    // wait — act 와 같은 거르기로 후보를 모아 앞에서부터 보이는 것을 찾는다.
                    var c = web_cdp_locate.listFromAx(gpa, bytes, q) catch |e| return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => self.releaseThenDone(gpa, .failed, "malformed accessibility query result"),
                    };
                    if (c.backends.len == 0) {
                        c.deinit(gpa);
                        self.wait_hidden = 0;
                        return self.releaseThen(gpa, .sleep);
                    }
                    self.cands = c;
                    self.cand_at = 0;
                    return self.judgeNext(gpa);
                }
                const pick = web_cdp_locate.pickFromAx(gpa, bytes, q, self.loc_input_role orelse self.loc_role) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => self.releaseThenDone(gpa, .failed, "malformed accessibility query result"),
                };
                switch (pick) {
                    .none => return self.releaseThenDone(gpa, .success, "false"),
                    .ambiguous => |msg| {
                        defer gpa.free(msg);
                        return self.releaseThenDone(gpa, .failed, msg);
                    },
                    .one => |one| {
                        // 찾았다 — 문서 묶음을 놓고 그 노드를 ref 처럼(화면 안으로 → …).
                        self.backend = one.backend;
                        // 이름은 잘리지 않고 온다(실측 2 MB) — 답이 CLI 프레임 상한(1 MiB)을 넘으면 클릭은 됐는데 「응답 없음」 이 된다(2 회차).
                        self.matched_name = try clipName(gpa, one.name, max_matched_name_bytes);
                        self.locating = false;
                        return self.releaseThen(gpa, .scroll);
                    },
                }
            },
            .judge_resolve => {
                const oid = stringAt(v, &.{ "object", "objectId" });
                try self.cand_objs.append(gpa, if (oid) |o| try gpa.dupe(u8, o) else null);
                return self.judgeNext(gpa);
            },
            .judge => {
                self.heavyEnd();
                if (at(v, &.{"exceptionDetails"}) != null) return self.releaseThen(gpa, .sleep);
                const idx = intAt(v, &.{ "result", "value" }) orelse -1;
                const c = &self.cands.?;
                const end = @min(self.cand_at + judge_batch, c.backends.len);
                if (idx >= 0 and self.cand_at + @as(usize, @intCast(idx)) < end) {
                    const i = self.cand_at + @as(usize, @intCast(idx));
                    const result = try waitResult(gpa, c.backends[i], c.names[i], self.loc_nth == null and c.total > 1);
                    return self.releaseThen(gpa, .{ .done = .{ .status = .success, .result = result } });
                }
                self.cand_at = end;
                self.freeCandObjs(gpa);
                if (self.cand_at < c.backends.len) return self.judgeNext(gpa);
                // 판정한 것이 모두 보이지 않았다 — 그 수(nth 면 그 하나, 상한 100 을 넘은 것은 보지 않았다).
                self.wait_hidden = c.backends.len;
                return self.releaseThen(gpa, .sleep);
            },
            .rel_then => unreachable, // feed 앞에서
            .loc_find, .loc_release => unreachable, // feed 앞에서
            .ax_tree => {
                const json = web_cdp_snapshot.build(gpa, bytes, self.snap) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => done(gpa, .failed, "malformed accessibility tree"),
                };
                return .{ .done = .{ .status = .success, .result = json } };
            },
            .check => {
                const value = at(v, &.{ "result", "value" }) orelse return self.sleepOrTimeout(gpa);
                if (value == .string) return done(gpa, .invalid_params, "Invalid selector");
                // load 는 그 문서가 다 불렸고 Chromium 이 불러오는 중이 아닐 때(이동이 시작된 옛 문서의 complete 를 믿지 않는다).
                const met = value == .bool and value.bool and !(self.wait_selector == null and self.page_loading);
                if (met) return done(gpa, .success, "true");
                return self.sleepOrTimeout(gpa);
            },
            .sleeping => unreachable, // 잠든 동안은 답이 오지 않는다(wake 로 깨운다)
            .upload => unreachable, // feed 앞에서 업로드 차례로 넘겼다
        }
    }

    fn deleteUp(gpa: std.mem.Allocator) !Step {
        return call(gpa, "Input.dispatchKeyEvent", "{{\"type\":\"keyUp\",\"key\":\"Delete\",\"code\":\"Delete\",\"windowsVirtualKeyCode\":46}}", .{});
    }

    /// press 의 누름(`down`)·뗌.
    fn keyStep(self: *Op, gpa: std.mem.Allocator, down: bool) !Step {
        self.stage = if (down) .key_down else .key_up;
        if (down) self.sent_input = true;
        const params = web_cdp_keys.eventParams(gpa, self.press_key.?, down) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidKey => done(gpa, .invalid_params, "invalid key"), // init 이 이미 걸렀다
        };
        return .{ .call = .{ .method = "Input.dispatchKeyEvent", .params = params } };
    }

    /// 키를 뗀 뒤 — 대상이 있었으면 묶음을 놓고, 없으면 곧 답한다.
    fn afterKeys(self: *Op, gpa: std.mem.Allocator) !Step {
        return if (self.press_target) self.releaseStep(gpa) else self.finish(gpa);
    }

    /// 없는 요소 — click·type·scroll 은 `{ok:false}`(WebKit 과 같다), snapshot 은 빈 트리.
    fn missing(self: *Op, gpa: std.mem.Allocator) !Step {
        return if (self.kind == .snapshot) done(gpa, .success, "{\"tree\":[]}") else done(gpa, .success, "false");
    }

    fn worldStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .world;
        return call(gpa, "Page.createIsolatedWorld", "{{\"frameId\":{f},\"worldName\":\"maru-w9b\"}}", .{std.json.fmt(self.frame_id.?, .{})});
    }

    /// wait — 아직이면 다음 간격 뒤 다시(시한이 지났으면 timeout). 간격은 두 배씩 늘린다. 로케이터의 확인(질의·찾기)은 그동안 페이지를
    /// 붙잡는다 — 쉼은 그 확인 시간의 네 배 이상, 그리고 지금까지 붙잡은 시간의 합이 지난 시간의 1/5 아래가 되게(3 회차 — 직전 확인만
    /// 보면 긴 첫 확인·높낮이가 갈리는 확인이 페이지를 절반 넘게 멈췄다). 그만큼 쉬면 시한 안에 확인이 끝나지 않을 때는 마지막 확인
    /// 하나를 시한 즈음 끝나게 앞당긴다(3 회차 — 전에는 그 자리에서 포기해 20 초 시한의 wait 이 8 초에 끝났다).
    fn sleepOrTimeout(self: *Op, gpa: std.mem.Allocator) !Step {
        self.last_check_ms = self.now_ms - self.check_start_ms - self.check_wait_ms;
        self.check_wait_ms = 0;
        if (self.check_heavy_ms > 0) {
            self.heavy_total_ms += if (self.heavy_count == 0) @min(self.check_heavy_ms, wait_first_heavy_cap_ms) else self.check_heavy_ms;
            self.noteHeavy(self.check_heavy_ms);
            self.check_heavy_ms = 0;
        }
        if (self.now_ms >= self.wait_deadline_ms) return self.waitTimeout(gpa);
        const left = self.wait_deadline_ms - self.now_ms;
        const last = self.checkEstimateMs();
        var want: i64 = self.wait_interval_ms;
        if (self.wait_visible) {
            want = @max(want, self.heavyMs() *| 4);
            want = @max(want, self.wait_start_ms + 5 *| self.heavy_total_ms - self.now_ms);
        }
        self.wait_interval_ms = @min(self.wait_interval_ms *| 2, wait_max_interval_ms);
        self.stage = .sleeping;
        if (want +| last <= left) return .{ .sleep = @intCast(@max(want, 1)) };
        // 쉰 뒤의 확인이 시한 안에 끝나지 않는다 — 마지막 확인 하나(이미 했으면 끝). 지금 시작해도 시한을 크게 넘길 확인이면 하지 않는다
        // (확인 하나가 늦으면 시한 25 초를 넘겨 서버 reaper 30 초에 닿았다 — 계획 공격 1·3 회차).
        if (self.final_check or last > left + wait_max_overrun_ms) return self.waitTimeout(gpa);
        self.final_check = true;
        return .{ .sleep = @intCast(@max(left - last, 1)) };
    }

    /// 다음 확인이 걸릴 시간의 짐작 — 직전 확인과 마지막 무거운 확인 가운데 긴 것(5 회차 — 직전 확인이 자리 없음으로 짧게 끝나면
    /// 그것만 보고 시한을 2 초 넘길 질의를 보냈다).
    fn checkEstimateMs(self: *const Op) i64 {
        return @max(@max(self.last_check_ms, self.last_heavy_ms), 0);
    }

    fn heavyEnd(self: *Op) void {
        self.check_heavy_ms += @max(self.now_ms - self.heavy_start_ms, 0);
    }

    fn noteHeavy(self: *Op, ms: i64) void {
        self.prev_heavy_ms = if (self.heavy_count > 0) self.last_heavy_ms else -1;
        self.last_heavy_ms = @max(ms, 0);
        self.heavy_count +|= 1;
    }

    /// 간격에 쓸 무거운 호출 시간 — 직전 두 번 가운데 작은 것, 하나뿐이면 그것을 `wait_first_heavy_cap_ms` 까지.
    fn heavyMs(self: *const Op) i64 {
        if (self.heavy_count == 0) return 0;
        if (self.prev_heavy_ms < 0) return @min(self.last_heavy_ms, wait_first_heavy_cap_ms);
        return @min(self.last_heavy_ms, self.prev_heavy_ms);
    }

    /// wait 의 시한 — 로케이터면 마지막 확인의 숨은 일치 수를 싣는다(L2 가 -32004 data 에).
    fn waitTimeout(self: *Op, gpa: std.mem.Allocator) !Step {
        if (!self.wait_visible) return done(gpa, .timeout, "");
        return .{ .done = .{ .status = .timeout, .result = try std.fmt.allocPrint(gpa, "{{\"hidden\":{d}}}", .{self.wait_hidden}) } };
    }

    /// wait 의 성공 답(로케이터).
    fn waitMet(self: *Op, gpa: std.mem.Allocator, backend: i64, name: []const u8, many: bool) !Step {
        _ = self;
        return .{ .done = .{ .status = .success, .result = try waitResult(gpa, backend, name, many) } };
    }

    /// role 질의(+kick).
    fn locateCall(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .locate;
        self.heavy_start_ms = self.now_ms;
        // 이름은 싣지 않는다 — 서버는 계산된 이름 원문과 비교해(nbsp·soft hyphen 그대로) 정규화한 exact 이름을 못 찾았다
        // (W9b②-1 적대 리뷰 1 회차 실측). 이름은 받은 뒤 정규화해 거른다. kick — 숨은 탭에서는 그래야 답한다(W9b②-3).
        var step = try call(gpa, "Accessibility.queryAXTree", "{{\"objectId\":{f},\"role\":{f}}}", .{ std.json.fmt(self.doc_obj.?, .{}), std.json.fmt(self.loc_role, .{}) });
        step.call.kick = .required;
        return step;
    }

    /// 덮임 검사 — 그 자리에서 맞는 것이 이 요소(또는 그 안)인가.
    fn hitTestCall(self: *Op, gpa: std.mem.Allocator, oid: []const u8) !Step {
        self.stage = .hit_test;
        // 격리 world 에서 — 그 자리에서 맞는 것이 이 요소(또는 그 안)인가. 다른 frame 의 요소면 "frame"(자리가 주 화면 좌표라
        // 그 frame 에서 보면 어긋난다). 그림자 DOM 안이면 그 뿌리에서 맞히고, slot 에 꽂힌 내용·host 를 따라 올라가며 본다.
        // **DOM 속성은 프로토타입의 getter 로 읽는다** — 격리 world 여도 `<form>` 안의 `<input name=parentNode>` 같은 이름
        // 속성(DOM clobbering)이 `n.parentNode` 를 가린다: 실측으로 걷기가 끝없이 돌거나(렌더러 멈춤) 덮인 요소를 「맞음」으로
        // 통과시켰다(W9b①a 적대 리뷰 3 회차). 걷기는 4096 단계로 끊는다.
        return call(gpa, "Runtime.callFunctionOn", "{{\"objectId\":{f},\"functionDeclaration\":\"function(x,y,up){{var G=function(p,k){{return Object.getOwnPropertyDescriptor(p,k).get}};var od=G(Node.prototype,'ownerDocument'),pn=G(Node.prototype,'parentNode'),es=G(Element.prototype,'assignedSlot'),ts=G(Text.prototype,'assignedSlot'),hs=G(ShadowRoot.prototype,'host');var grn=Node.prototype.getRootNode,def=Document.prototype.elementFromPoint,sef=ShadowRoot.prototype.elementFromPoint;var me=this;if(me instanceof Text)me=G(Node.prototype,'parentElement').call(me)||me;if((od.call(me)||me)!==document)return 'frame';var r=grn.call(me);var h=(r instanceof ShadowRoot)?sef.call(r,x,y):def.call(document,x,y);if(up){{var tg=G(Element.prototype,'tagName'),ga=Element.prototype.getAttribute,SP=String.prototype,sr=G(Element.prototype,'shadowRoot'),ce=G(HTMLElement.prototype,'isContentEditable'),lc=G(HTMLLabelElement.prototype,'control'),R=',button,link,tab,menuitem,menuitemcheckbox,menuitemradio,option,checkbox,radio,switch,treeitem,textbox,searchbox,combobox,slider,spinbutton,listbox,';var act=function(m){{var t=SP.toUpperCase.call(tg.call(m));if(t==='BUTTON'||t==='LABEL'||t==='SUMMARY'||t==='INPUT'||t==='SELECT'||t==='TEXTAREA'||t==='IFRAME'||t==='FRAME'||t==='EMBED'||t==='OBJECT'||(t==='A'&&ga.call(m,'href')!==null))return true;if(m instanceof HTMLElement&&ce.call(m))return true;var ro=ga.call(m,'role');return ro!==null&&SP.indexOf.call(R,','+SP.split.call(SP.toLowerCase.call(SP.trim.call(ro)),/\\\\s/)[0]+',')>=0}};var upf=function(m){{var q=es.call(m)||pn.call(m);if(q instanceof ShadowRoot)q=hs.call(q);return(q instanceof Element)?q:null}};}}var via=false;for(var n=h,i=0;n&&i<4096;i++){{if(n===me)return via?'covered':'ok';if(up&&(n instanceof Element)&&act(n)&&!((me instanceof HTMLLabelElement)&&lc.call(me)===n))via=true;var s=(n instanceof Element)?es.call(n):(n instanceof Text)?ts.call(n):null;n=s||pn.call(n)||((n instanceof ShadowRoot)?hs.call(n):null)}}if(up){{var A=null;for(var m=me,j=0;m&&j<4096;j++,m=upf(m))if(act(m)){{A=m;break}}if(A){{var d=h;for(var k=0;d&&k<64;k++){{var s3=sr.call(d);if(!s3)break;var d2=sef.call(s3,x,y);if(!d2||d2===d)break;d=d2}}for(var n2=d,j2=0;n2&&j2<4096;j2++,n2=upf(n2)){{if(n2===A||(n2 instanceof HTMLLabelElement&&lc.call(n2)===A)||(A instanceof HTMLLabelElement&&lc.call(A)===n2))return 'ok';if(act(n2))break}}}}}}return 'covered'}}\",\"arguments\":[{{\"value\":{d}}},{{\"value\":{d}}},{{\"value\":{s}}}],\"returnByValue\":true}}", .{ std.json.fmt(oid, .{}), self.x, self.y, if (self.hit_up) "true" else "false" });
    }

    /// hover 의 포인터 이동(+kick — 숨은 탭에서 5 초 걸렸다, W9b②-3 계획 공격 3 회차).
    fn hoverMove(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .hover_move;
        var step = try call(gpa, "Input.dispatchMouseEvent", "{{\"type\":\"mouseMoved\",\"x\":{d},\"y\":{d}}}", .{ self.x, self.y });
        step.call.kick = .required;
        return step;
    }

    /// role wait — 지금 묶음의 다음 후보를 잡거나, 다 잡았으면 한 번에 보임을 본다(finder 의 `visible` — text·label 과 같은 판정).
    fn judgeNext(self: *Op, gpa: std.mem.Allocator) !Step {
        const c = &self.cands.?;
        const end = @min(self.cand_at + judge_batch, c.backends.len);
        const next = self.cand_at + self.cand_objs.items.len;
        if (next < end) {
            self.stage = .judge_resolve;
            return call(gpa, "DOM.resolveNode", "{{\"backendNodeId\":{d},\"executionContextId\":{d},\"objectGroup\":\"maru-w9b-{d}\"}}", .{ c.backends[next], self.context_id, self.id });
        }
        self.stage = .judge;
        self.heavy_start_ms = self.now_ms;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        writeJudgeParams(&s, self) catch return error.OutOfMemory;
        return .{ .call = .{ .method = "Runtime.callFunctionOn", .params = try aw.toOwnedSlice() } };
    }

    fn writeJudgeParams(s: *std.json.Stringify, self: *const Op) !void {
        try s.beginObject();
        try s.objectField("functionDeclaration");
        try s.write(finder_js);
        try s.objectField("executionContextId");
        try s.write(self.context_id);
        try s.objectField("arguments");
        try s.beginArray();
        for ([_]std.json.Value{ .{ .string = "visible" }, .{ .string = "" }, .{ .bool = false }, .null, .{ .string = "wait" } }) |a| {
            try s.beginObject();
            try s.objectField("value");
            try s.write(a);
            try s.endObject();
        }
        for (self.cand_objs.items) |o| {
            try s.beginObject();
            if (o) |id| {
                try s.objectField("objectId");
                try s.write(id);
            } else {
                try s.objectField("value");
                try s.write(null);
            }
            try s.endObject();
        }
        try s.endArray();
        try s.objectField("returnByValue");
        try s.write(true);
        try s.endObject();
    }

    fn freeCandObjs(self: *Op, gpa: std.mem.Allocator) void {
        for (self.cand_objs.items) |o| if (o) |id| gpa.free(id);
        self.cand_objs.clearRetainingCapacity();
    }

    /// 한 확인의 role 상태(문서·후보·잡은 객체)를 버린다 — 원격 객체는 묶음 놓기가 놓는다.
    fn dropRoleState(self: *Op, gpa: std.mem.Allocator) void {
        if (self.doc_obj) |d| gpa.free(d);
        self.doc_obj = null;
        if (self.cands) |*c| c.deinit(gpa);
        self.cands = null;
        self.freeCandObjs(gpa);
        self.cand_objs.deinit(gpa);
        self.cand_objs = .empty;
    }

    /// 묶음(문서·후보)을 놓은 뒤 `then` 으로 — 놓기는 committed(철회돼도 놓는다).
    fn releaseThen(self: *Op, gpa: std.mem.Allocator, then: Then) !Step {
        if (self.then == .done) gpa.free(self.then.done.result);
        self.then = then;
        self.stage = .rel_then;
        return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
    }

    fn releaseThenDone(self: *Op, gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
        const owned = try gpa.dupe(u8, result);
        errdefer gpa.free(owned);
        return self.releaseThen(gpa, .{ .done = .{ .status = status, .result = owned } });
    }

    fn afterRelThen(self: *Op, gpa: std.mem.Allocator) !Step {
        self.dropRoleState(gpa);
        const then = self.then;
        self.then = .sleep;
        return switch (then) {
            .sleep => self.sleepOrTimeout(gpa),
            .scroll => self.scrollStep(gpa),
            .done => |d| .{ .done = .{ .status = d.status, .result = d.result } },
        };
    }

    fn frameTreeStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .frame_tree;
        return call(gpa, "Page.getFrameTree", "", .{});
    }

    fn axStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .ax_tree;
        return call(gpa, "Accessibility.getFullAXTree", "", .{});
    }

    /// 놓은 뒤의 답 — 덮였으면 실패, 누름·떼기가 시한을 넘겼으면 timeout, 아니면 눌렀다.
    fn finish(self: *Op, gpa: std.mem.Allocator) !Step {
        if (self.miss) |why| return done(gpa, .failed, why);
        if (self.late) |why| return done(gpa, .timeout, why);
        return self.succeed(gpa);
    }

    /// 성공 — 로케이터로 찾았으면 `{"ok":true,"matched":{"ref","name"}}`(L2 가 그대로 싣는다), 아니면 "true".
    fn succeed(self: *Op, gpa: std.mem.Allocator) !Step {
        // 입력 뒤 페이지가 대화상자를 띄웠다 — `"dialog":true`(L2 가 싣고 CLI 가 「다시 하지 말라」 를 낸다, 3 회차).
        const dialog: []const u8 = if (self.dialog) ",\"dialog\":true" else "";
        const name = self.matched_name orelse {
            if (!self.dialog) return done(gpa, .success, "true");
            return .{ .done = .{ .status = .success, .result = try gpa.dupe(u8, "{\"ok\":true,\"dialog\":true}") } };
        };
        const msg = try std.fmt.allocPrint(gpa, "{{\"ok\":true,\"matched\":{{\"ref\":\"n{d}\",\"name\":{f}}}{s}}}", .{ self.backend, std.json.fmt(name, .{}), dialog });
        return .{ .done = .{ .status = .success, .result = msg } };
    }

    /// 모르는 역할(Op.init 의 error.UnknownRole)의 답 — 가까운 역할과 흔한 역할(소유).
    pub fn unknownRoleMessage(gpa: std.mem.Allocator, arg: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return gpa.dupe(u8, "unknown role");
        defer parsed.deinit();
        const role = stringAt(parsed.value, &.{ "locator", "role" }) orelse "";
        var clipped = role[0..@min(role.len, 40)];
        while (clipped.len > 0 and !std.unicode.utf8ValidateSlice(clipped)) clipped = clipped[0 .. clipped.len - 1];
        if (web_cdp_locate.suggestRole(role)) |near|
            return std.fmt.allocPrint(gpa, "unknown role {f} — did you mean \"{s}\"? common: {s} (generic, none, presentation and text cannot be located; full list: docs/control-plane-browser.md)", .{ std.json.fmt(clipped, .{}), near, web_cdp_locate.common_roles });
        return std.fmt.allocPrint(gpa, "unknown role {f} — common: {s} (generic, none, presentation and text cannot be located; full list: docs/control-plane-browser.md)", .{ std.json.fmt(clipped, .{}), web_cdp_locate.common_roles });
    }

    fn scrollStep(self: *Op, gpa: std.mem.Allocator) !Step {
        // W9c③: 업로드는 찾은 요소를 스크롤하지 않는다(파일 입력칸은 숨어 있어도 된다 — 실측 d) — 업로드 차례로.
        if (self.upload) |*u| {
            self.stage = .upload;
            return u.located(gpa, self.backend);
        }
        self.stage = .scroll;
        return call(gpa, "DOM.scrollIntoViewIfNeeded", "{{\"backendNodeId\":{d}}}", .{self.backend});
    }

    fn releaseStep(self: *Op, gpa: std.mem.Allocator) !Step {
        self.stage = .release;
        return call(gpa, "Runtime.releaseObjectGroup", "{{\"objectGroup\":\"maru-w9b-{d}\"}}", .{self.id});
    }

    fn mouse(self: *Op, gpa: std.mem.Allocator, comptime kind: []const u8) !Step {
        return call(gpa, "Input.dispatchMouseEvent", "{{\"type\":\"" ++ kind ++ "\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ self.x, self.y });
    }

    /// CDP 가 오류로 답했다 — selector 문법이면 invalid_params, 노드가 사라졌으면(문서가 바뀌었다) 없는 요소(`{ok:false}`). 누른 뒤의
    /// 오류는 눌렀다는 사실을 덮지 않는다(떼기·놓기 실패는 그대로 성공 — 페이지는 이미 클릭을 받았다).
    fn cdpError(self: *Op, gpa: std.mem.Allocator, err_json: []const u8) !Step {
        var owned: ?[]u8 = null;
        defer if (owned) |m| gpa.free(m);
        if (std.json.parseFromSlice(std.json.Value, gpa, err_json, .{})) |parsed| {
            defer parsed.deinit();
            if (stringAt(parsed.value, &.{"message"})) |m| owned = try gpa.dupe(u8, m);
        } else |_| {}
        const message: []const u8 = owned orelse "DevTools error";
        const gone = containsAny(message, &.{ "No node", "Could not find node", "not found", "No target" });
        return switch (self.stage) {
            .query => if (gone) self.missing(gpa) else done(gpa, .invalid_params, message),
            .describe, .scroll, .quads, .resolve => if (gone) self.missing(gpa) else done(gpa, .failed, message),
            .focus => done(gpa, .failed, "the element cannot be focused"),
            // wait 의 world·확인 오류 — 이동 중이라 문서·world 가 사라졌다: 다음 확인으로(새 문서의 world).
            // world 오류면 주 frame 이 바뀌었을 수 있다(prerender 등) — 다음엔 frame tree 부터 다시 받는다.
            .world, .check => if (self.kind == .wait) blk: {
                if (self.stage == .world) if (self.frame_id) |f| {
                    gpa.free(f);
                    self.frame_id = null;
                };
                break :blk self.sleepOrTimeout(gpa);
            } else done(gpa, .failed, message),
            // 고르기·넣기 실패 — 쥔 묶음은 놓고 실패.
            .select, .insert, .delete_down, .delete_up, .verify => blk: {
                // 다시 읽기의 오류면 글은 이미 들어갔다 — 「넣지 못했다」 고 하지 않는다.
                self.miss = if (self.stage == .verify) "the text was entered but could not be read back" else "the text could not be entered";
                break :blk self.releaseStep(gpa);
            },
            .mouse_up => self.releaseStep(gpa), // 떼기 실패 — 그래도 묶음은 놓는다
            .hover_move => blk: {
                self.miss = "the pointer could not be moved";
                break :blk self.releaseStep(gpa);
            },
            .focus_check => blk: {
                self.miss = "could not check the focus";
                break :blk self.releaseStep(gpa);
            },
            // 키 누름 실패 — 누르지 못했다(떼기는 보내지 않는다). 키 떼기 실패 — 누름은 갔다.
            .key_down => blk: {
                self.miss = "the key could not be dispatched";
                break :blk self.afterKeys(gpa);
            },
            .key_up => self.afterKeys(gpa),
            // 검사·누름이 CDP 오류 — 누르지 못했다. 쥔 묶음은 놓고 실패로 답한다(3 회차 — 그냥 끝내 묶음이 남았다).
            .hit_test => blk: {
                self.miss = "could not check what is at the element's position";
                break :blk self.releaseStep(gpa);
            },
            .mouse_down => blk: {
                self.miss = "the click could not be dispatched";
                break :blk self.releaseStep(gpa);
            },
            .release => self.finish(gpa),
            // 찾기 스크립트를 DevTools 가 거절했다 — 놓은 뒤 그 이유로(wait 은 다음 확인 — 이동 중 context 가 사라졌다).
            .loc_find => self.findRelease(gpa, .{ .done = .{ .status = .failed, .msg = try std.fmt.allocPrint(gpa, "locator script failed: {s}", .{message}) } }),
            // role 의 단계 — 이동 중이면 context·문서가 사라졌다: wait 은 다음 확인(쥔 묶음은 놓고), act 는 그 이유로.
            .frame_tree, .size_check, .loc_document => if (self.kind == .wait) self.sleepOrTimeout(gpa) else done(gpa, .failed, message),
            .locate, .judge => if (self.kind == .wait) self.releaseThen(gpa, .sleep) else self.releaseThenDone(gpa, .failed, message),
            // 후보 하나를 잡지 못했다 — 사라진 노드면 그것만 빼고 이어서, 이동이면 다음 확인.
            .judge_resolve => if (gone) blk: {
                try self.cand_objs.append(gpa, null);
                break :blk self.judgeNext(gpa);
            } else self.releaseThen(gpa, .sleep),
            else => done(gpa, .failed, message),
        };
    }
};

/// `n<backendNodeId>` → id(0 이상의 정수가 아니면 null).
pub fn parseRef(ref: []const u8) ?i64 {
    if (ref.len < 2 or ref[0] != 'n') return null;
    const id = std.fmt.parseInt(i64, ref[1..], 10) catch return null;
    return if (id > 0) id else null;
}

fn call(gpa: std.mem.Allocator, method: []const u8, comptime fmt: []const u8, args: anytype) !Step {
    const params = if (fmt.len == 0) try gpa.alloc(u8, 0) else try std.fmt.allocPrint(gpa, fmt, args);
    return .{ .call = .{ .method = method, .params = params } };
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

/// wait visible 의 성공 답 `{"ok":true,"matched":{"ref","name"},"ambiguous"?:true}` — ambiguous = 같은 로케이터로 act 하면 「여럿」 일 것.
fn waitResult(gpa: std.mem.Allocator, backend: i64, name: []const u8, many: bool) ![]u8 {
    const clipped = try clipName(gpa, try gpa.dupe(u8, name), max_matched_name_bytes);
    defer gpa.free(clipped);
    return std.fmt.allocPrint(gpa, "{{\"ok\":true,\"matched\":{{\"ref\":\"n{d}\",\"name\":{f}}}{s}}}", .{ backend, std.json.fmt(clipped, .{}), if (many) ",\"ambiguous\":true" else "" });
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, haystack, n) != null) return true;
    return false;
}

fn at(v: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = v;
    for (path) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

/// type 의 글 상한(JSON 으로 쓴 길이).
pub const max_type_text_json_bytes = 48 * 1024;

/// 글을 JSON 문자열로 쓴 바이트 수(따옴표 빼고) — 제어 문자는 `\u00XX`, `"`·`\` 는 두 바이트.
fn jsonStringBytes(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += if (c < 0x20) 6 else if (c == '"' or c == '\\') 2 else 1;
    return n;
}

test "type: 글이 JSON 으로 48 KiB 를 넘으면 시작하지 않는다(제어 문자는 여섯 바이트로 센다)" {
    const big = try testing.allocator.alloc(u8, max_type_text_json_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    const arg = try std.fmt.allocPrint(testing.allocator, "{{\"selector\":\"#in\",\"text\":{f}}}", .{std.json.fmt(big, .{})});
    defer testing.allocator.free(arg);
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .type_text, arg, 1));
    const fits = try std.fmt.allocPrint(testing.allocator, "{{\"selector\":\"#in\",\"text\":{f}}}", .{std.json.fmt(big[0..max_type_text_json_bytes], .{})});
    defer testing.allocator.free(fits);
    var ok = try Op.init(testing.allocator, .type_text, fits, 1); // 상한과 같으면 시작한다
    ok.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6 + 2 + 1), jsonStringBytes("\n\"a"));
}

fn intAt(v: std.json.Value, path: []const []const u8) ?i64 {
    const x = at(v, path) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn numberAt(v: std.json.Value, path: []const []const u8) ?f64 {
    const x = at(v, path) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn stringAt(v: std.json.Value, path: []const []const u8) ?[]const u8 {
    const x = at(v, path) orelse return null;
    return if (x == .string) x.string else null;
}

fn boolAt(v: std.json.Value, path: []const []const u8) ?bool {
    const x = at(v, path) orelse return null;
    return if (x == .bool) x.bool else null;
}

fn arrayAt(v: std.json.Value, path: []const []const u8) ?[]std.json.Value {
    const x = at(v, path) orelse return null;
    return if (x == .array) x.array.items else null;
}

/// `quads` 의 상자들(넓이 0 은 뺀다) — 앞에서 `out.len` 개까지. 모양이 틀린 quad 는 건너뛴다.
fn collectBoxes(v: std.json.Value, out: *[max_boxes][4]f64) usize {
    const quads = arrayAt(v, &.{"quads"}) orelse return 0;
    var n: usize = 0;
    for (quads) |q| {
        if (n == out.len) break;
        if (q != .array or q.array.items.len != 8) continue;
        var c: [8]f64 = undefined;
        const ok = for (q.array.items, 0..) |x, i| {
            c[i] = switch (x) {
                .integer => |iv| @floatFromInt(iv),
                .float => |fv| fv,
                else => break false,
            };
        } else true;
        if (!ok) continue;
        const box = [4]f64{
            @min(@min(c[0], c[2]), @min(c[4], c[6])),
            @min(@min(c[1], c[3]), @min(c[5], c[7])),
            @max(@max(c[0], c[2]), @max(c[4], c[6])),
            @max(@max(c[1], c[3]), @max(c[5], c[7])),
        };
        if (box[2] <= box[0] or box[3] <= box[1]) continue;
        out[n] = box;
        n += 1;
    }
    return n;
}

// ── 시험: 가짜 DevTools 로 차례를 돈다 ──

const testing = std.testing;

const Trail = struct {
    methods: std.ArrayList([]const u8) = .empty,
    params: std.ArrayList([]u8) = .empty,
    /// 누름을 보낸 뒤 `committed` 였는가(떼기·놓기마다).
    committed_after_press: bool = true,
    /// 누름 Step 을 받을 때 `committed` 가 거짓이었는가(누르기 직전에는 재허가를 거친다).
    uncommitted_at_press: bool = true,
    sleeps: usize = 0,
    /// kick 을 실은 호출의 순번(W9b②-3).
    kicked: std.ArrayList(usize) = .empty,
    /// 그 가운데 `required`.
    required: std.ArrayList(usize) = .empty,
    /// 답을 낸 뒤의 정리 호출 수(업로드의 떼기·놓기 — `takeUploadCleanup`, W9c③ 적대 리뷰 4 회차 L1). 그 호출도 `methods` 끝에 붙는다.
    cleanup: usize = 0,

    fn deinit(self: *Trail) void {
        for (self.params.items) |p| testing.allocator.free(p);
        self.params.deinit(testing.allocator);
        self.methods.deinit(testing.allocator);
        self.kicked.deinit(testing.allocator);
        self.required.deinit(testing.allocator);
    }

    fn reset(self: *Trail) void {
        self.deinit();
        self.* = .{};
    }

    fn count(self: *const Trail, method: []const u8) usize {
        var n: usize = 0;
        for (self.methods.items) |m| if (std.mem.eql(u8, m, method)) {
            n += 1;
        };
        return n;
    }
};

/// 차례를 끝까지 돌린다 — `answer` 가 메서드마다 답을 준다.
fn drive(op: *Op, answer: *const fn (method: []const u8, params: []const u8) Reply, trail: *Trail) !struct { status: Status, result: []u8 } {
    var step = try op.start(testing.allocator);
    var pressed = false;
    while (true) switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .done => |d| return .{ .status = d.status, .result = d.result },
        .sleep => |ms| {
            // 가짜 시계 — 잠든 만큼 흘려 깨운다.
            trail.sleeps += 1;
            op.now_ms += ms;
            step = try op.wake(testing.allocator);
        },
        .call => |c| {
            if (c.kick != .none) try trail.kicked.append(testing.allocator, trail.methods.items.len);
            if (c.kick == .required) try trail.required.append(testing.allocator, trail.methods.items.len);
            try trail.methods.append(testing.allocator, c.method);
            try trail.params.append(testing.allocator, c.params);
            if (pressed and !op.committed()) trail.committed_after_press = false;
            if (std.mem.indexOf(u8, c.params, "mousePressed") != null) {
                if (op.committed()) trail.uncommitted_at_press = false;
                pressed = true;
            }
            step = try op.feed(testing.allocator, answer(c.method, c.params));
        },
    };
}

fn happyPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getDocument")) return .{ .ok = "{\"root\":{\"nodeId\":1}}" };
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .ok = if (std.mem.indexOf(u8, params, "#none") != null) "{\"nodeId\":0}" else "{\"nodeId\":6}" };
    if (std.mem.eql(u8, method, "DOM.describeNode")) return .{ .ok = "{\"node\":{\"backendNodeId\":9}}" };
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,0,46,0,46,20,0,20]]}" };
    if (std.mem.eql(u8, method, "Page.getLayoutMetrics")) return .{ .ok = "{\"cssLayoutViewport\":{\"pageX\":0,\"pageY\":0,\"clientWidth\":800,\"clientHeight\":600}}" };
    if (std.mem.eql(u8, method, "Page.getFrameTree")) return .{ .ok = "{\"frameTree\":{\"frame\":{\"id\":\"F1\"}}}" };
    if (std.mem.eql(u8, method, "Page.createIsolatedWorld")) return .{ .ok = "{\"executionContextId\":7}" };
    if (std.mem.eql(u8, method, "DOM.resolveNode")) return .{ .ok = "{\"object\":{\"objectId\":\"o-1\"}}" };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"ok\"}}" };
    return .{ .ok = "{}" };
}

fn coveredPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"covered\"}}" };
    return happyPage(method, params);
}

fn framePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"frame\"}}" };
    return happyPage(method, params);
}

fn twoLinePage(method: []const u8, params: []const u8) Reply {
    // 두 줄에 걸친 링크 — 첫 줄은 화면 위로 나갔고 둘째 줄이 보인다. 넓이 0 상자도 섞였다.
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,-40,100,-40,100,-20,0,-20],[5,5,5,5,5,5,5,5],[0,0,60,0,60,20,0,20]]}" };
    return happyPage(method, params);
}

fn stuckReleasePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mouseReleased") != null) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn stuckGroupReleasePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn hitErrorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Cannot find context\"}" };
    return happyPage(method, params);
}

fn pressErrorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent")) return .{ .cdp_error = "{\"code\":-32602,\"message\":\"bad\"}" };
    return happyPage(method, params);
}

fn stuckPressPage(method: []const u8, params: []const u8) Reply {
    // 누름 핸들러가 alert 를 띄웠다 — 누름의 답이 시한을 넘긴다.
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mousePressed") != null) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn throwingPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"object\"},\"exceptionDetails\":{\"text\":\"x\"}}" };
    return happyPage(method, params);
}

fn hugePage(method: []const u8, params: []const u8) Reply {
    // 화면(800×600)보다 큰 요소 — 위로 500 px 넘친다.
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,-500,1000,-500,1000,700,0,700]]}" };
    return happyPage(method, params);
}

fn offscreenPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .ok = "{\"quads\":[[0,900,40,900,40,920,0,920]]}" };
    return happyPage(method, params);
}

fn badSelectorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"DOM Error while querying\"}" };
    return happyPage(method, params);
}

fn staleDocumentPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.querySelector")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Could not find node with given id\"}" };
    return happyPage(method, params);
}

fn goneNodePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.scrollIntoViewIfNeeded")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"No node with given id found\"}" };
    return happyPage(method, params);
}

fn detachedPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .failed = "the browser's DevTools detached" };
    return happyPage(method, params);
}

fn slowPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn releaseFailsPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mouseReleased") != null) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" };
    return happyPage(method, params);
}

fn history(method: []const u8, _: []const u8) Reply {
    if (std.mem.eql(u8, method, "Page.getNavigationHistory")) return .{ .ok = "{\"currentIndex\":1,\"entries\":[{\"id\":5},{\"id\":8}]}" };
    return .{ .ok = "{}" };
}

test "click(selector): 찾기 → 화면 안으로 → 자리 → 화면과 겹친 곳 → 격리 world 에서 덮였는지 → 누르고 떼기 → 놓기" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 42);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "Page.getLayoutMetrics", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Page.captureScreenshot", "Runtime.callFunctionOn", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    // 검사는 격리 world(페이지가 바꿔 놓은 함수를 쓰지 않는다)·묶음 이름은 요청마다.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "\"executionContextId\":7") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "\"objectGroup\":\"maru-w9b-42\"") != null);
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-42\"}", trail.params.items[13]);
    // selector·ref 는 그 요소(또는 그 안)에 맞아야 한다 — 조상 허용은 text·label 로케이터만(W9b②-2 2 회차).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[10], "{\"value\":false}],") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[10]));
    // 누르기 전 프레임은 kick 이 아니라 답을 기다리는 보통 호출이다(W9b③ — kick 이면 프레임이 누르기보다 늦었다).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[9], "\"width\":1,\"height\":1") != null);
    try testing.expectEqual(@as(usize, 0), trail.kicked.items.len);
    // 누르기 앞에 움직임이 없다(숨긴 탭에서 답이 없었다) — 검사 바로 다음이 누름이다.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[11], "mousePressed") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[12], "mouseReleased") != null);
    try testing.expect(trail.committed_after_press);
    try testing.expect(trail.uncommitted_at_press);
    try testing.expectEqual(@as(f64, 23), op.x);
    try testing.expectEqual(@as(f64, 10), op.y);
}

test "click: 화면보다 큰 요소는 화면과 겹친 곳의 가운데, 화면 밖은 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 1);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &hugePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqual(@as(f64, 400), op.x);
    try testing.expectEqual(@as(f64, 300), op.y);
    trail.reset();
    var off = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 2);
    defer off.deinit(testing.allocator);
    const o = try drive(&off, &offscreenPage, &trail);
    defer testing.allocator.free(o.result);
    try testing.expectEqual(Status.failed, o.status);
    try testing.expect(std.mem.indexOf(u8, o.result, "outside the viewport") != null);
    try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
}

test "click: 누름의 답이 시한을 넘겨도 떼기·놓기를 보내고 timeout, 다른 frame 의 요소는 누르지 않는다, 두 줄 링크는 보이는 줄을" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 11);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &stuckPressPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.timeout, r.status);
        try testing.expectEqual(@as(usize, 2), trail.count("Input.dispatchMouseEvent")); // 누름 + 떼기
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
        try testing.expect(trail.committed_after_press);
    }
    // 떼기가 시한 → 놓기를 마저 보내고 timeout, 놓기만 시한 → 눌렀으니 성공, 누름이 CDP 오류 → 묶음을 놓고 실패.
    const more = [_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, presses: usize }{
        .{ .answer = &stuckReleasePage, .status = .timeout, .presses = 2 },
        .{ .answer = &stuckGroupReleasePage, .status = .success, .presses = 2 },
        .{ .answer = &pressErrorPage, .status = .failed, .presses = 1 },
        .{ .answer = &hitErrorPage, .status = .failed, .presses = 0 },
    };
    for (more) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 14);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqual(c.presses, trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .click, "{\"ref\":\"n9\"}", 12);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &framePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "frames") != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"a\"}", 13);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &twoLinePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("true", r.result);
        try testing.expectEqual(@as(f64, 30), op.x); // 둘째 줄의 가운데
        try testing.expectEqual(@as(f64, 10), op.y);
    }
}

test "click(ref): n<backendNodeId> 는 찾기를 건너뛴다, 모르는 ref·없는 요소는 {ok:false}" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"ref\":\"n9\"}", 3);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("DOM.scrollIntoViewIfNeeded", trail.methods.items[0]);
    for ([_][]const u8{ "{\"ref\":\"e1\"}", "{\"ref\":\"n0\"}", "{\"ref\":\"nx\"}", "{\"selector\":\"#none\"}" }) |arg| {
        trail.reset();
        var o = try Op.init(testing.allocator, .click, arg, 4);
        defer o.deinit(testing.allocator);
        const x = try drive(&o, &happyPage, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(Status.success, x.status);
        try testing.expectEqualStrings("false", x.result);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
    }
}

test "click: 덮였거나 검사가 예외면 누르지 않고 묶음을 놓은 뒤 실패, 오류는 나눠 답한다" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, want: []const u8 }{
        .{ .answer = &coveredPage, .want = "covered" },
        .{ .answer = &throwingPage, .want = "could not check" },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 5);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    const cases = [_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, result: []const u8 }{
        .{ .answer = &badSelectorPage, .status = .invalid_params, .result = "DOM Error while querying" },
        .{ .answer = &staleDocumentPage, .status = .success, .result = "false" }, // 그사이 문서가 바뀌었다 — selector 탓이 아니다
        .{ .answer = &goneNodePage, .status = .success, .result = "false" },
        .{ .answer = &detachedPage, .status = .failed, .result = "the browser's DevTools detached" },
        .{ .answer = &slowPage, .status = .timeout, .result = "DevTools did not answer in time" },
        .{ .answer = &releaseFailsPage, .status = .success, .result = "true" }, // 눌렀다 — 떼기·놓기 오류가 그 사실을 덮지 않는다
    };
    for (cases) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 6);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqualStrings(c.result, r.result);
    }
}

test "click 의 selector 는 JSON 으로 감싸 넘긴다(따옴표가 메시지를 깨지 않는다)" {
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"a[title=\\\"x\\\"]\"}", 7);
    defer op.deinit(testing.allocator);
    const s1 = try op.start(testing.allocator);
    testing.allocator.free(s1.call.params);
    const s2 = try op.feed(testing.allocator, .{ .ok = "{\"root\":{\"nodeId\":1}}" });
    defer testing.allocator.free(s2.call.params);
    try testing.expectEqualStrings("{\"nodeId\":1,\"selector\":\"a[title=\\\"x\\\"]\"}", s2.call.params);
    try testing.expect(try std.json.validate(testing.allocator, s2.call.params));
}

test "back·forward 는 방문 기록의 앞뒤 항목으로, 갈 곳이 없으면 {ok:false}, reload 는 한 번" {
    var trail: Trail = .{};
    defer trail.deinit();
    var back = try Op.init(testing.allocator, .back, "", 8);
    const b = try drive(&back, &history, &trail);
    defer testing.allocator.free(b.result);
    try testing.expectEqualStrings("true", b.result);
    try testing.expectEqualStrings("Page.navigateToHistoryEntry", trail.methods.items[1]);
    try testing.expectEqualStrings("{\"entryId\":5}", trail.params.items[1]);
    trail.reset();
    var fwd = try Op.init(testing.allocator, .forward, "", 9);
    const f = try drive(&fwd, &history, &trail); // 지금이 마지막 항목
    defer testing.allocator.free(f.result);
    try testing.expectEqualStrings("false", f.result);
    try testing.expectEqual(@as(usize, 1), trail.methods.items.len);
    trail.reset();
    var rel = try Op.init(testing.allocator, .reload, "", 10);
    const r = try drive(&rel, &history, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("Page.reload", trail.methods.items[0]);
}

// ── W9b①b: type·scroll·wait·snapshot ──

const tiny_ax =
    \\{"nodes":[{"nodeId":"1","role":{"value":"RootWebArea"},"name":{"value":"t"},"backendDOMNodeId":5,"childIds":["2"]},
    \\{"nodeId":"2","role":{"value":"button"},"name":{"value":"Go"},"backendDOMNodeId":9,"parentId":"1","childIds":[]}]}
;

fn editorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Accessibility.getFullAXTree")) return .{ .ok = tiny_ax };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null and std.mem.indexOf(u8, params, "function(want,bh,bn)") == null and std.mem.indexOf(u8, params, "function(x,y,up)") == null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"ok\",\"h\":123,\"n\":3}}}" };
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        // wait 의 한 번 확인 — `#late` 면 보인다, `#never` 면 아직, `[` 면 selector 오류, load 는 complete.
        if (std.mem.indexOf(u8, params, "#never") != null) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":false}}" };
        if (std.mem.indexOf(u8, params, "\\\"[\\\"") != null) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"error\"}}" };
        return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":true}}" };
    }
    return happyPage(method, params);
}

fn notEditablePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null and std.mem.indexOf(u8, params, "function(x,y,up)") == null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"not editable\"}}}" };
    return editorPage(method, params);
}

test "type: 찾기 → 화면 안으로 → 초점 → 격리 world 에서 글 고르기(프로토타입 함수) → 그 위에 insertText → 놓기" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"새 \\\"값\\\"\"}", 21);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &editorPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.focus", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Input.insertText", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "HTMLInputElement.prototype.select.call") != null);
    try testing.expectEqualStrings("{\"text\":\"새 \\\"값\\\"\"}", trail.params.items[9]);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[8]));
    // 고른 뒤 초점이 그 요소인지 보고, 넣은 뒤 값을 다시 읽는다(넣은 글을 인자로).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "focus moved") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[10], "\"arguments\":[{\"value\":\"새 \\\"값\\\"\"},{\"value\":123},{\"value\":3}]") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[10]));
}

fn focusStealPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "isContentEditable") != null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":{\"r\":\"focus moved\"}}}" };
    return editorPage(method, params);
}

fn rejectingPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(want,bh,bn)") != null) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"rejected\"}}" };
    return editorPage(method, params);
}

test "type: 페이지가 초점을 옮겼으면 넣지 않고, 넣은 값이 거부됐으면(readonly·maxlength·형식) 실패 — 묶음은 놓는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, want: []const u8, inserts: usize }{
        .{ .answer = &focusStealPage, .want = "focus moved", .inserts = 0 },
        .{ .answer = &rejectingPage, .want = "did not take", .inserts = 1 },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"x\"}", 31);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(c.inserts, trail.count("Input.insertText"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "type: 빈 글은 고른 것을 Delete 키로 지우고, 편집할 수 없는 요소는 넣지 않고 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .type_text, "{\"ref\":\"n9\",\"text\":\"\"}", 22);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("true", r.result);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.insertText"));
        try testing.expectEqual(@as(usize, 2), trail.count("Input.dispatchKeyEvent"));
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#cb\",\"text\":\"x\"}", 23);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &notEditablePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "not editable") != null);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.insertText"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "scroll: 화면 안으로 스크롤하고 끝, 없는 요소는 {ok:false}" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .scroll, "{\"selector\":\"#far\"}", 24);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &editorPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    try testing.expectEqualStrings("DOM.scrollIntoViewIfNeeded", trail.methods.items[trail.methods.items.len - 1]);
    trail.reset();
    var none = try Op.init(testing.allocator, .scroll, "{\"selector\":\"#none\"}", 25);
    defer none.deinit(testing.allocator);
    const n = try drive(&none, &editorPage, &trail);
    defer testing.allocator.free(n.result);
    try testing.expectEqualStrings("false", n.result);
}

test "wait: 격리 world 에서 한 번씩 본다(간격 50→100→200…→500 ms) — 보이면 성공, 시한이면 timeout, selector 오류는 invalid_params" {
    var trail: Trail = .{};
    defer trail.deinit();
    const cases = [_]struct { arg: []const u8, status: Status, sleeps: usize }{
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"#late\",\"timeout_ms\":5000}", .status = .success, .sleeps = 0 },
        // 350 ms: 50 + 100 + 200(남은 만큼) — 시한에서 끝.
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"#never\",\"timeout_ms\":350}", .status = .timeout, .sleeps = 3 },
        .{ .arg = "{\"condition\":\"selector\",\"selector\":\"[\",\"timeout_ms\":100}", .status = .invalid_params, .sleeps = 0 },
        .{ .arg = "{\"condition\":\"load\",\"timeout_ms\":100}", .status = .success, .sleeps = 0 },
    };
    for (cases) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .wait, c.arg, 26);
        defer op.deinit(testing.allocator);
        op.now_ms = 1000;
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqual(c.sleeps, trail.sleeps);
        const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate" };
        for (want, trail.methods.items[0..3]) |w, got| try testing.expectEqualStrings(w, got);
        try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "\"contextId\":7") != null); // 격리 world
        try testing.expect(try std.json.validate(testing.allocator, trail.params.items[2]));
        // 확인마다 world 를 다시 받는다(이동했으면 새 문서의 world) — 잠든 수만큼 더.
        // (시한으로 끝나는 마지막 깨어남은 world 를 받지 않는다.)
        try testing.expectEqual(if (c.status == .timeout) c.sleeps else 1 + c.sleeps, trail.count("Page.createIsolatedWorld"));
    }
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"timeout_ms\":5}", 1));
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .wait, "{\"condition\":\"idle\",\"timeout_ms\":5}", 1));
}

var navigating_checks: usize = 0;
fn navigatingPage(method: []const u8, params: []const u8) Reply {
    // 처음 두 번은 이동 중이라 문서·world 가 사라진다 — 그다음 새 문서에서 보인다.
    if (std.mem.eql(u8, method, "Runtime.evaluate")) {
        navigating_checks += 1;
        if (navigating_checks <= 2) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Execution context was destroyed.\"}" };
    }
    return editorPage(method, params);
}

fn loadingPage(method: []const u8, params: []const u8) Reply {
    return editorPage(method, params);
}

test "wait: 이동 중 world 가 사라져도 다음 확인으로 넘긴다, load 는 그 탭이 불러오는 중이면 기다린다" {
    var trail: Trail = .{};
    defer trail.deinit();
    navigating_checks = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#result\",\"timeout_ms\":5000}", 32);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &navigatingPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 2), trail.sleeps);
    trail.reset();
    var load = try Op.init(testing.allocator, .wait, "{\"condition\":\"load\",\"timeout_ms\":250}", 33);
    defer load.deinit(testing.allocator);
    load.page_loading = true; // 이동이 시작됐다 — 옛 문서의 complete 를 믿지 않는다
    const l = try drive(&load, &loadingPage, &trail);
    defer testing.allocator.free(l.result);
    try testing.expectEqual(Status.timeout, l.status);
    try testing.expect(trail.sleeps >= 2);
}

test "snapshot: 접근성 트리를 WebKit 모양으로, selector 는 그 노드부터, 없는 selector 는 빈 트리" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":false}", 27);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[{\"role\":\"button\",\"name\":\"Go\",\"ref\":\"n9\"}]}", r.result);
        try testing.expectEqual(@as(usize, 1), trail.methods.items.len);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":true,\"selector\":\"#b\"}", 28);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[{\"role\":\"button\",\"name\":\"Go\",\"ref\":\"n9\"}]}", r.result);
        try testing.expectEqualStrings("Accessibility.getFullAXTree", trail.methods.items[trail.methods.items.len - 1]);
    }
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .snapshot, "{\"interactive_only\":false,\"selector\":\"#none\"}", 29);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &editorPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"tree\":[]}", r.result);
    }
}

test "wait 의 간격은 두 배씩 늘어 500 ms 에서 멈추고, 시한을 넘겨 자지 않는다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"load\",\"timeout_ms\":3000}", 40);
    defer op.deinit(testing.allocator);
    op.now_ms = 0;
    op.wait_deadline_ms = 3000;
    var got: [8]u32 = undefined;
    for (&got) |*g| {
        op.check_start_ms = op.now_ms; // 확인은 0 ms(3 회차 — 마감 판단이 직전 확인 시간을 본다)
        const step = try op.sleepOrTimeout(testing.allocator);
        g.* = step.sleep;
        op.now_ms += g.*;
        if (op.now_ms >= op.wait_deadline_ms) break;
    }
    try testing.expectEqualSlices(u32, &.{ 50, 100, 200, 400, 500, 500, 500, 500 }, &got);
    // 남은 시간이 간격보다 짧으면 남은 만큼만.
    op.now_ms = 2990;
    op.check_start_ms = 2990;
    try testing.expectEqual(@as(u32, 10), (try op.sleepOrTimeout(testing.allocator)).sleep);
    op.now_ms = 3000;
    const end = try op.sleepOrTimeout(testing.allocator);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.timeout, end.done.status);
}

fn frameGonePage(method: []const u8, params: []const u8) Reply {
    // 주 frame 이 바뀌었다 — 옛 frame id 의 world 는 늘 오류, frame tree 를 다시 받으면 새 id.
    if (std.mem.eql(u8, method, "Page.createIsolatedWorld") and std.mem.indexOf(u8, params, "\"F1\"") != null and frame_gone_seen > 0) return .{ .cdp_error = "{\"code\":-32000,\"message\":\"No frame for given id found\"}" };
    if (std.mem.eql(u8, method, "Page.getFrameTree")) {
        frame_gone_seen += 1;
        return .{ .ok = if (frame_gone_seen == 1) "{\"frameTree\":{\"frame\":{\"id\":\"F1\"}}}" else "{\"frameTree\":{\"frame\":{\"id\":\"F2\"}}}" };
    }
    if (std.mem.eql(u8, method, "Runtime.evaluate") and frame_gone_seen == 1) return .{ .ok = "{\"result\":{\"type\":\"boolean\",\"value\":false}}" };
    return editorPage(method, params);
}
var frame_gone_seen: usize = 0;

test "wait: world 오류(주 frame 이 바뀜)면 frame tree 부터 다시 받는다 — 옛 id 로 시한까지 헛돌지 않는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    frame_gone_seen = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#late\",\"timeout_ms\":5000}", 41);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &frameGonePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 2), trail.count("Page.getFrameTree"));
}

fn focusMovedPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"focus moved\"}}" };
    return happyPage(method, params);
}

fn stuckMovePage(method: []const u8, params: []const u8) Reply {
    // 숨긴 탭 — 움직임의 답이 다음 프레임까지 늦는다(실측 5 초).
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn stuckKeyDownPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent") and std.mem.indexOf(u8, params, "keyUp") == null) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn keyErrorPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent")) return .{ .cdp_error = "{\"code\":-32602,\"message\":\"bad\"}" };
    return happyPage(method, params);
}

test "hover: click 과 같은 길(화면 안으로·자리·덮임 검사) 뒤 누르지 않고 그 자리로 움직이기만 — 덮였으면 움직이지 않는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 51);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "Page.getLayoutMetrics", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Input.dispatchMouseEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqualStrings("{\"type\":\"mouseMoved\",\"x\":23,\"y\":10}", trail.params.items[10]);
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, moves: usize }{
        .{ .answer = &coveredPage, .status = .failed, .moves = 0 },
        .{ .answer = &stuckMovePage, .status = .timeout, .moves = 1 },
    }) |c| {
        trail.reset();
        var o = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 52);
        defer o.deinit(testing.allocator);
        const x = try drive(&o, c.answer, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(c.status, x.status);
        try testing.expectEqual(c.moves, trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "hover: 움직임을 보내기 전에는 committed 가 아니다(철회됐으면 움직이지 않는다), 덮임 검사의 시한에도 묶음을 놓는다" {
    var op = try Op.init(testing.allocator, .hover, "{\"ref\":\"n9\"}", 53);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    var saw_move = false;
    while (step == .call) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        if (std.mem.indexOf(u8, c.params, "mouseMoved") != null) {
            saw_move = true;
            try testing.expect(!op.committed());
        }
        step = try op.feed(testing.allocator, happyPage(c.method, c.params));
    }
    testing.allocator.free(step.done.result);
    try testing.expect(saw_move);
    var trail: Trail = .{};
    defer trail.deinit();
    var slow = try Op.init(testing.allocator, .hover, "{\"ref\":\"n9\"}", 54);
    defer slow.deinit(testing.allocator);
    const r = try drive(&slow, &stuckHitPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.timeout, r.status);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
}

fn stuckHitPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn throwingFocusPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"object\"},\"exceptionDetails\":{\"text\":\"x\"}}" };
    return happyPage(method, params);
}

fn stuckResolvePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.resolveNode")) return .{ .timed_out = "DevTools did not answer in time" };
    return happyPage(method, params);
}

fn framedPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"frame\"}}" };
    return happyPage(method, params);
}

fn failedPressPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent") and std.mem.indexOf(u8, params, "mousePressed") != null) return .{ .failed = "DevTools request failed" };
    return happyPage(method, params);
}

fn unsentKeyDownPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent") and std.mem.indexOf(u8, params, "keyUp") == null) return .{ .not_sent = "too many DevTools calls on this tab" };
    return happyPage(method, params);
}

fn unsentPressPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent")) return .{ .not_sent = "too many DevTools calls on this tab" };
    return happyPage(method, params);
}

fn failedKeyDownPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent") and std.mem.indexOf(u8, params, "keyUp") == null) return .{ .failed = "DevTools request failed" };
    return happyPage(method, params);
}

test "click·press: 노드 잡기·초점 검사의 시한에도 묶음을 놓고 timeout, iframe 안 요소는 frame 으로, 누름 실패 뒤에도 뗀다" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { kind: Kind, arg: []const u8, answer: *const fn ([]const u8, []const u8) Reply, status: Status, want: []const u8, keys: usize }{
        .{ .kind = .click, .arg = "{\"selector\":\"#b\"}", .answer = &stuckResolvePage, .status = .timeout, .want = "", .keys = 0 },
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"selector\":\"#e\"}", .answer = &stuckHitPage, .status = .timeout, .want = "", .keys = 0 },
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"ref\":\"n9\"}", .answer = &framedPage, .status = .failed, .want = "frames", .keys = 0 },
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"selector\":\"#e\"}", .answer = &failedKeyDownPage, .status = .failed, .want = "request failed", .keys = 2 },
        // 확실히 못 보낸 누름은 떼지 않는다(keydown 없는 keyup 을 만들지 않는다).
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"selector\":\"#e\"}", .answer = &unsentKeyDownPage, .status = .failed, .want = "too many", .keys = 1 },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, c.kind, c.arg, 70);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(c.keys, trail.count("Input.dispatchKeyEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "press: 초점 검사가 예외면 「focus moved」 가 아니라 검사 실패로, 대상 없는 누름의 오류는 떼지 않고 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"x\",\"selector\":\"#e\"}", 65);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &throwingFocusPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expect(std.mem.indexOf(u8, r.result, "could not check the focus") != null);
    try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchKeyEvent"));
    trail.reset();
    var bare = try Op.init(testing.allocator, .press, "{\"key\":\"x\"}", 66);
    defer bare.deinit(testing.allocator);
    const b = try drive(&bare, &keyErrorPage, &trail);
    defer testing.allocator.free(b.result);
    try testing.expectEqual(Status.failed, b.status);
    try testing.expectEqual(@as(usize, 1), trail.count("Input.dispatchKeyEvent"));
}

test "press: 대상이 없으면 지금 초점에 누르고 떼기만, 누른 뒤에는 철회돼도 뗀다" {
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\"}", 61);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    // 누르기 전 프레임(W9b③ 적대 리뷰 3 회차) — 아직 누르지 않았다.
    try testing.expectEqualStrings("Page.captureScreenshot", step.call.method);
    try testing.expect(!op.committed());
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .ok = "{\"data\":\"\"}" });
    try testing.expectEqualStrings("Input.dispatchKeyEvent", step.call.method);
    try testing.expect(std.mem.indexOf(u8, step.call.params, "\"type\":\"keyDown\"") != null);
    try testing.expect(!op.committed()); // 누르기 전 — 재허가를 거친다
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .ok = "{}" });
    try testing.expect(std.mem.indexOf(u8, step.call.params, "\"type\":\"keyUp\"") != null);
    try testing.expect(op.committed()); // 눌렀다 — 떼기는 끝까지
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .ok = "{}" });
    try testing.expectEqual(Status.success, step.done.status);
    testing.allocator.free(step.done.result);
    try testing.expectError(error.InvalidKey, Op.init(testing.allocator, .press, "{\"key\":\"Hyper+a\"}", 1));
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .press, "{}", 1));
}

test "press(selector): 화면 안으로 → 초점 → 격리 world 에서 초점이 그 요소인가 → 누름·뗌(편집 명령) → 놓기, 초점이 옮겨졌으면 누르지 않는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"Meta+a\",\"selector\":\"#e\"}", 62);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &happyPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("true", r.result);
    const want = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "DOM.scrollIntoViewIfNeeded", "DOM.focus", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Page.captureScreenshot", "Input.dispatchKeyEvent", "Input.dispatchKeyEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[8], "focus moved") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[8]));
    try testing.expectEqualStrings(frame_params, trail.params.items[9]); // 누르기 전 프레임(W9b③ 적대 리뷰 3 회차)
    try testing.expect(std.mem.indexOf(u8, trail.params.items[10], "\"commands\":[\"selectAll\"]") != null);
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, status: Status, keys: usize }{
        .{ .answer = &focusMovedPage, .status = .failed, .keys = 0 },
        .{ .answer = &stuckKeyDownPage, .status = .timeout, .keys = 2 }, // 누름이 시한이어도 뗀다
        .{ .answer = &keyErrorPage, .status = .failed, .keys = 1 }, // 누르지 못했다 — 떼지 않는다
    }) |c| {
        trail.reset();
        var o = try Op.init(testing.allocator, .press, "{\"key\":\"x\",\"selector\":\"#e\"}", 63);
        defer o.deinit(testing.allocator);
        const x = try drive(&o, c.answer, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(c.status, x.status);
        try testing.expectEqual(c.keys, trail.count("Input.dispatchKeyEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    trail.reset();
    var unknown = try Op.init(testing.allocator, .press, "{\"key\":\"x\",\"ref\":\"n0\"}", 64);
    defer unknown.deinit(testing.allocator);
    const u = try drive(&unknown, &happyPage, &trail);
    defer testing.allocator.free(u.result);
    try testing.expectEqualStrings("false", u.result);
    try testing.expectEqual(@as(usize, 0), trail.methods.items.len);
}

test "click: 누름의 답이 실패면 떼기·놓기를 마저 보내고, 확실히 못 보냈으면 떼지 않고 놓기만" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { answer: *const fn ([]const u8, []const u8) Reply, mouse: usize }{
        .{ .answer = &failedPressPage, .mouse = 2 },
        .{ .answer = &unsentPressPage, .mouse = 1 },
    }) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 80);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.failed, r.status);
        try testing.expectEqual(c.mouse, trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

var up_unsent_left: usize = 0;

fn flakyKeyUpPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent") and std.mem.indexOf(u8, params, "keyUp") != null and up_unsent_left > 0) {
        up_unsent_left -= 1;
        return .{ .not_sent = "too many DevTools calls on this tab" };
    }
    return happyPage(method, params);
}

fn failedReleasePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .not_sent = "the Chromium tab is not ready" };
    return happyPage(method, params);
}

fn failedHitPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return .{ .failed = "DevTools request failed" };
    return happyPage(method, params);
}

test "press: 못 보낸 떼기는 50 ms 뒤 세 번까지 다시, 놓기 실패는 동작의 결과로, 묶음을 쥔 단계의 실패는 놓고 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    // 둘 못 보내고 셋째에 갔다 — 성공, 누름 1·뗌 3.
    up_unsent_left = 2;
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\",\"selector\":\"#e\"}", 90);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &flakyKeyUpPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 4), trail.count("Input.dispatchKeyEvent"));
    try testing.expectEqual(@as(usize, 2), trail.sleeps);
    // 끝까지 못 보냈다 — 세 번 다시 보낸 뒤 놓고 실패.
    trail.reset();
    up_unsent_left = 100;
    var stuck = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\",\"selector\":\"#e\"}", 91);
    defer stuck.deinit(testing.allocator);
    const s = try drive(&stuck, &flakyKeyUpPage, &trail);
    defer testing.allocator.free(s.result);
    try testing.expectEqual(Status.failed, s.status);
    try testing.expectEqual(@as(usize, 1 + 1 + max_up_retries), trail.count("Input.dispatchKeyEvent"));
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    up_unsent_left = 0;
    // 키는 갔고 놓기만 실패 — 성공으로 답한다(실패로 답하면 다시 시도해 두 번 누른다).
    for ([_]Kind{ .press, .click }) |kind| {
        trail.reset();
        var rel = try Op.init(testing.allocator, kind, if (kind == .press) "{\"key\":\"Enter\",\"selector\":\"#e\"}" else "{\"selector\":\"#b\"}", 92);
        defer rel.deinit(testing.allocator);
        const x = try drive(&rel, &failedReleasePage, &trail);
        defer testing.allocator.free(x.result);
        try testing.expectEqual(Status.success, x.status);
        try testing.expectEqualStrings("true", x.result);
    }
    // 덮임 검사의 실패(보냈을 수도) — 묶음을 놓고 실패, 누르지 않는다.
    trail.reset();
    var hit = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 93);
    defer hit.deinit(testing.allocator);
    const h = try drive(&hit, &failedHitPage, &trail);
    defer testing.allocator.free(h.result);
    try testing.expectEqual(Status.failed, h.status);
    try testing.expectEqual(@as(usize, 0), trail.count("Input.dispatchMouseEvent"));
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
}

/// `fail_method`(+`fail_needle` 이 params 에 있을 때)에 `fail_reply` 로 답하는 페이지 — 단계별 표 시험용.
var fail_method: []const u8 = "";
var fail_needle: []const u8 = "";
var fail_reply: Reply = .{ .failed = "DevTools request failed" };
var fail_left: usize = 0;

fn tablePage(method: []const u8, params: []const u8) Reply {
    if (fail_left > 0 and std.mem.eql(u8, method, fail_method) and std.mem.indexOf(u8, params, fail_needle) != null) {
        fail_left -= 1;
        return fail_reply;
    }
    // press 의 초점 검사(글 하나로 답한다) — type 의 고르기(객체로 답한다)와 가른다.
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "return 'focus moved'") != null) return happyPage(method, params);
    return editorPage(method, params);
}

test "묶음을 쥔 단계마다(노드 잡기·검사·움직임·고르기·넣기·Delete·다시 읽기) 실패해도 묶음을 놓는다, 마우스·Delete 떼기도 다시 보낸다" {
    var trail: Trail = .{};
    defer trail.deinit();
    const failed: Reply = .{ .failed = "DevTools request failed" };
    const unsent: Reply = .{ .not_sent = "too many DevTools calls on this tab" };
    const cases = [_]struct { kind: Kind, arg: []const u8, method: []const u8, needle: []const u8, reply: Reply, times: usize, status: Status }{
        .{ .kind = .click, .arg = "{\"selector\":\"#b\"}", .method = "DOM.resolveNode", .needle = "", .reply = failed, .times = 1, .status = .failed },
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"selector\":\"#e\"}", .method = "Runtime.callFunctionOn", .needle = "", .reply = failed, .times = 1, .status = .failed },
        .{ .kind = .hover, .arg = "{\"selector\":\"#h\"}", .method = "Input.dispatchMouseEvent", .needle = "mouseMoved", .reply = failed, .times = 1, .status = .failed },
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"x\"}", .method = "Runtime.callFunctionOn", .needle = "isContentEditable", .reply = failed, .times = 1, .status = .failed },
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"x\"}", .method = "Input.insertText", .needle = "", .reply = unsent, .times = 1, .status = .failed },
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"x\"}", .method = "Runtime.callFunctionOn", .needle = "function(want,bh,bn)", .reply = failed, .times = 1, .status = .failed },
        // Delete 누름이 실패(보냈을 수도) — 떼기를 마저.
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"\"}", .method = "Input.dispatchKeyEvent", .needle = "keyDown", .reply = failed, .times = 1, .status = .failed },
        // 떼기를 둘 못 보냈다 — 다시 보내 성공(마우스·Delete).
        .{ .kind = .click, .arg = "{\"selector\":\"#b\"}", .method = "Input.dispatchMouseEvent", .needle = "mouseReleased", .reply = unsent, .times = 2, .status = .success },
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"\"}", .method = "Input.dispatchKeyEvent", .needle = "keyUp", .reply = unsent, .times = 2, .status = .success },
        // 떼기의 답이 깨졌다(보냈을 수도) — 누름은 갔다: 성공으로.
        .{ .kind = .press, .arg = "{\"key\":\"x\",\"selector\":\"#e\"}", .method = "Input.dispatchKeyEvent", .needle = "keyUp", .reply = failed, .times = 1, .status = .success },
    };
    for (cases, 0..) |c, i| {
        trail.reset();
        fail_method = c.method;
        fail_needle = c.needle;
        fail_reply = c.reply;
        fail_left = c.times;
        var op = try Op.init(testing.allocator, c.kind, c.arg, 100 + i);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &tablePage, &trail);
        defer testing.allocator.free(r.result);
        errdefer std.debug.print("case {d}: {s} {s}\n", .{ i, @tagName(r.status), r.result });
        try testing.expectEqual(c.status, r.status);
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
        if (i == 6) {
            // Delete 누름이 실패해도 떼기는 갔다.
            var ups: usize = 0;
            for (trail.params.items) |p| if (std.mem.indexOf(u8, p, "\"keyUp\"") != null) {
                ups += 1;
            };
            try testing.expectEqual(@as(usize, 1), ups);
        }
    }
    fail_left = 0;
}

test "떼기를 끝까지 못 보내도 앞선 실패 이유로 답한다(엔진이 멈춤 — 「not ready」 가 덮지 않는다)" {
    var trail: Trail = .{};
    defer trail.deinit();
    fail_method = "Input.dispatchKeyEvent";
    fail_needle = "";
    fail_reply = .{ .failed = "the Chromium engine stopped" };
    fail_left = 1;
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"x\"}", 120);
    defer op.deinit(testing.allocator);
    // 누름이 실패 → 떼기는 못 보냄(not_sent) 셋 — 마지막 답은 앞선 이유. 처음은 누르기 전 프레임.
    var step = try op.start(testing.allocator);
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .ok = "{\"data\":\"\"}" });
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, fail_reply);
    var n: usize = 0;
    while (step != .done) : (n += 1) {
        switch (step) {
            .confirm => unreachable, // W9c③: 업로드만 멈춘다
            .call => |c| {
                testing.allocator.free(c.params);
                step = try op.feed(testing.allocator, .{ .not_sent = "the Chromium tab is not ready" });
            },
            .sleep => step = try op.wake(testing.allocator),
            .done => unreachable,
        }
    }
    defer testing.allocator.free(step.done.result);
    try testing.expectEqual(Status.failed, step.done.status);
    try testing.expectEqualStrings("the Chromium engine stopped", step.done.result);
    fail_left = 0;
}

fn rolePage(method: []const u8, params: []const u8) Reply {
    // 질의 대상 document(W9b②-3 — 격리 world 의 objectId, 묶음 안).
    if (std.mem.eql(u8, method, "Runtime.evaluate") and std.mem.indexOf(u8, params, "\"expression\":\"document\"") != null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"className\":\"HTMLDocument\",\"objectId\":\"doc-1\"}}" };
    if (std.mem.eql(u8, method, "Runtime.evaluate")) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":[120,0,0,0,0,0,0]}}" };
    if (std.mem.eql(u8, method, "DOM.getDocument")) return .{ .ok = "{\"root\":{\"nodeId\":1,\"backendNodeId\":2}}" };
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return .{ .ok = "{\"nodes\":[{\"ignored\":false,\"name\":{\"value\":\"Save\"},\"backendDOMNodeId\":11},{\"ignored\":false,\"name\":{\"value\":\"Save changes\"},\"backendDOMNodeId\":12},{\"ignored\":true,\"name\":{\"value\":\"\"},\"backendDOMNodeId\":13}]}" };
    return happyPage(method, params);
}

fn hugeRolePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.evaluate") and std.mem.indexOf(u8, params, "\"expression\":\"document\"") == null) return .{ .ok = "{\"result\":{\"type\":\"object\",\"value\":[40000,0,0,0,0,0,0]}}" };
    return rolePage(method, params);
}

fn tooLargeAxPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return .{ .failed = result_too_large };
    return rolePage(method, params);
}

test "role 로케이터: 크기 검사 → 문서 → 접근성 질의 → 하나면 ref 처럼 누르고 matched 로 답한다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"Button\",\"name\":\"save\",\"exact\":false,\"nth\":0}}", 200);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &rolePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save\"}}", r.result);
    const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate", "Runtime.evaluate", "Accessibility.queryAXTree", "Runtime.releaseObjectGroup", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "Page.getLayoutMetrics", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Page.captureScreenshot", "Runtime.callFunctionOn", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    // 크기 검사는 격리 world·프로토타입 함수로, 질의는 Chromium 역할로(부분 일치라 이름은 싣지 않는다).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "sr=G(Element.prototype,'shadowRoot')") != null); // open shadow 도 센다
    try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "([30000,") != null);
    // 질의 대상은 그 격리 world 의 document(묶음 안 — 이동하면 곧 오류, W9b②-3), 질의는 kick 과 함께, 그 묶음은 누르기 전에 놓는다.
    try testing.expectEqualStrings("{\"expression\":\"document\",\"contextId\":7,\"objectGroup\":\"maru-w9b-200\"}", trail.params.items[3]);
    try testing.expectEqualStrings("{\"objectId\":\"doc-1\",\"role\":\"button\"}", trail.params.items[4]);
    try testing.expectEqualSlices(usize, &.{4}, trail.kicked.items);
    try testing.expectEqualSlices(usize, &.{4}, trail.required.items);
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-200\"}", trail.params.items[5]);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[6], "\"backendNodeId\":11") != null);
}

test "role 로케이터: exact 여도 이름은 질의에 싣지 않는다, 여럿이면 후보 ref 로 실패, 없으면 {ok:false}, 큰 페이지·큰 결과는 too_large" {
    var trail: Trail = .{};
    defer trail.deinit();
    {
        var op = try Op.init(testing.allocator, .scroll, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 201);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &rolePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqualStrings("{\"objectId\":\"doc-1\",\"role\":\"button\"}", trail.params.items[4]); // exact 여도 이름은 싣지 않는다
        try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save\"}}", r.result);
    }
    const cases = [_]struct { arg: []const u8, answer: *const fn ([]const u8, []const u8) Reply, status: Status, want: []const u8, presses: usize }{
        .{ .arg = "{\"locator\":{\"role\":\"button\",\"name\":\"save\"}}", .answer = &rolePage, .status = .failed, .want = "ambiguous: 2 elements match role=button name~\"save\" — n11 \"Save\", n12 \"Save changes\"", .presses = 0 },
        .{ .arg = "{\"locator\":{\"role\":\"button\",\"name\":\"nope\"}}", .answer = &rolePage, .status = .success, .want = "false", .presses = 0 },
        .{ .arg = "{\"locator\":{\"role\":\"button\",\"nth\":5}}", .answer = &rolePage, .status = .success, .want = "false", .presses = 0 },
        .{ .arg = "{\"locator\":{\"role\":\"button\"}}", .answer = &hugeRolePage, .status = .failed, .want = "too_large: page has 40000 elements", .presses = 0 },
        .{ .arg = "{\"locator\":{\"role\":\"button\"}}", .answer = &tooLargeAxPage, .status = .failed, .want = "too_large: the accessibility query result", .presses = 0 },
    };
    for (cases) |c| {
        trail.reset();
        var op = try Op.init(testing.allocator, .click, c.arg, 202);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.answer, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, c.want) != null);
        try testing.expectEqual(c.presses, trail.count("Input.dispatchMouseEvent"));
        try testing.expectEqual(@as(usize, 0), trail.count("DOM.scrollIntoViewIfNeeded"));
        // 문서를 잡았으면(질의를 보냈으면) 그 묶음을 놓고 끝낸다.
        try testing.expectEqual(trail.count("Accessibility.queryAXTree"), trail.count("Runtime.releaseObjectGroup"));
    }
    // 큰 페이지면 질의 자체를 보내지 않는다.
    try testing.expectEqual(@as(usize, 1), trail.count("Accessibility.queryAXTree"));
}

test "role 로케이터: 모르는 역할은 UnknownRole(가까운 역할을 권하는 답), 모양이 틀리면 InvalidArg, press 는 그 요소에 누른다" {
    try testing.expectError(error.UnknownRole, Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"buton\"}}", 1));
    const msg = try Op.unknownRoleMessage(testing.allocator, "{\"locator\":{\"role\":\"buton\"}}");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.startsWith(u8, msg, "unknown role \"buton\" — did you mean \"button\"? common: button link"));
    for ([_][]const u8{
        "{\"locator\":{\"role\":\"generic\"}}",
        "{\"locator\":\"button\"}",
        "{\"locator\":{\"label\":\"\"}}",
        "{\"locator\":{\"text\":\" \\u00ad \"}}", // 정규화하면 빈 글
        "{\"locator\":{\"role\":\"button\",\"name\":\"\"}}",
        "{\"locator\":{\"role\":\"button\",\"level\":0}}",
        "{\"locator\":{\"role\":\"button\",\"nth\":-1}}",
        "{\"locator\":{\"role\":\"button\",\"exact\":\"yes\"}}",
        "{\"locator\":{\"role\":\"button\",\"name\":\" \\u200b \"}}", // 공백·보이지 않는 글자뿐
        "{\"locator\":{\"role\":\"button\"},\"selector\":\"#b\"}",
    }) |bad| {
        if (Op.init(testing.allocator, .click, bad, 1)) |op_val| {
            var op = op_val;
            op.deinit(testing.allocator);
            return error.TestExpectedError;
        } else |_| {}
    }
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 203);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &rolePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save\"}}", r.result);
    try testing.expectEqual(@as(usize, 1), trail.count("DOM.focus"));
    try testing.expectEqual(@as(usize, 2), trail.count("Input.dispatchKeyEvent"));
}

/// 성공 답에 싣는 이름의 상한(바이트).
const max_matched_name_bytes = 256;

/// `name` 을 UTF-8 경계에서 `max` 바이트까지 자르고 넘쳤으면 「…」 — `name` 은 넘겨받아 놓는다(소유한 새 글).
fn clipName(gpa: std.mem.Allocator, name: []u8, max: usize) ![]u8 {
    if (name.len <= max) return name;
    defer gpa.free(name);
    var end = max;
    while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1;
    const out = try gpa.alloc(u8, end + "…".len);
    @memcpy(out[0..end], name[0..end]);
    @memcpy(out[end..], "…");
    return out;
}

var costly_counts: []const u8 = "[200,0,0,0,0,0,0]";

fn costlyPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.evaluate") and std.mem.indexOf(u8, params, "\"expression\":\"document\"") == null) {
        const Buf = struct {
            var b: [128]u8 = undefined;
        };
        const json = std.fmt.bufPrint(&Buf.b, "{{\"result\":{{\"type\":\"object\",\"value\":{s}}}}}", .{costly_counts}) catch unreachable;
        return .{ .ok = json };
    }
    return rolePage(method, params);
}

fn longNamePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return .{ .ok = "{\"nodes\":[{\"ignored\":false,\"name\":{\"value\":\"" ++ "é" ** 200 ++ "\"},\"backendDOMNodeId\":31}]}" };
    return rolePage(method, params);
}

test "role 로케이터: 트리를 비싸게 만드는 구성(대상 없는 # 링크·radio·role=radio)이 상한을 넘으면 어떤 역할이든 질의 전에 거절, 긴 이름은 256 바이트에서" {
    var trail: Trail = .{};
    defer trail.deinit();
    for ([_]struct { counts: []const u8, want: ?[]const u8 }{
        .{ .counts = "[200,3001,0,0,0,0,0]", .want = "too_large: the accessibility query would freeze this page (3001 same-page #links without a target (limit 3000)) — use a selector or ref" },
        .{ .counts = "[200,0,3001,0,0,0,0]", .want = "too_large: the accessibility query would freeze this page (3001 radio inputs (limit 3000))" },
        .{ .counts = "[200,0,0,801,0,0,0]", .want = "too_large: the accessibility query would freeze this page (801 role=radio elements (limit 800))" },
        .{ .counts = "[200,0,0,0,3001,0,0]", .want = "too_large: the accessibility query would freeze this page (3001 labeled form controls (limit 3000))" },
        // 블록마다 제곱 합 — 9 999 줄 블록 둘이면 넘는다(하나는 통과), 글 노드도.
        .{ .counts = "[200,0,0,0,0,512000000,0]", .want = "too_large: the accessibility query would freeze this page (~22627 line fragments per block (limit 20000))" },
        .{ .counts = "[200,0,0,0,0,399960001,0]", .want = null },
        .{ .counts = "[200,0,0,0,0,0,900000000]", .want = "too_large: the accessibility query would freeze this page (~30000 text nodes per block (limit 20000))" },
        // 상한들은 더해진다 — 각자는 상한 아래여도 합이 넘으면 거절.
        .{ .counts = "[200,2000,0,600,0,0,0]", .want = "too_large: the accessibility query would freeze this page (2000 same-page #links without a target (limit 3000), 600 role=radio elements (limit 800))" },
        .{ .counts = "[200,3000,0,0,0,0,0]", .want = null },
        .{ .counts = "[200,1000,1000,0,0,0,0]", .want = null },
        // 모양이 틀린 결과(짧다·정수가 아니다·음수)는 셀 수 없음 — 질의하지 않는다(엉뚱한 칸을 읽지 않는다).
        .{ .counts = "[200,0]", .want = "could not count" },
        .{ .counts = "[200,0,0,0,0,0,\"x\"]", .want = "could not count" },
        .{ .counts = "[200,0,0,0,0,0,-5]", .want = "could not count" },
    }) |c| {
        trail.reset();
        costly_counts = c.counts;
        var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 300);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &costlyPage, &trail);
        defer testing.allocator.free(r.result);
        if (c.want) |w| {
            try testing.expectEqual(Status.failed, r.status);
            try testing.expect(std.mem.startsWith(u8, r.result, w));
            try testing.expectEqual(@as(usize, 0), trail.count("Accessibility.queryAXTree"));
        } else try testing.expectEqual(@as(usize, 1), trail.count("Accessibility.queryAXTree"));
    }
    // 세기 JS 는 그 구성들을 센다(같은 문서 # 링크의 대상·radio·role=radio·라벨 컨트롤·줄 수) — 상한은 web_cdp_locate 의 값.
    for ([_][]const u8{ "a[*|href],area[href]", "input[type=radio]", "[role~=radio i]", "HTMLLabelElement.prototype,'control'", "createTreeWalker", "Range.prototype.getClientRects", "([30000,3000,3000,800,3000,400000000,400000000])" }) |needle|
        try testing.expect(std.mem.indexOf(u8, trail.params.items[2], needle) != null);
    trail.reset();
    {
        var op = try Op.init(testing.allocator, .scroll, "{\"locator\":{\"role\":\"button\"}}", 302);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &longNamePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.success, r.status);
        try testing.expect(r.result.len < 400);
        try testing.expect(std.mem.endsWith(u8, r.result, "…\"}}"));
        try testing.expect(std.unicode.utf8ValidateSlice(r.result));
    }
}

var find_reply: Reply = .{ .ok = "" };

fn findPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(KIND, Q, EXACT, NTH, ACTION)") != null) return find_reply;
    return happyPage(method, params);
}

const found_one = "{\"result\":{\"type\":\"object\",\"objectId\":\"o9\",\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":1}],[\"el\",{\"type\":\"node\",\"value\":{\"backendNodeId\":41}}],[\"name\",{\"type\":\"string\",\"value\":\"Sign in\"}]]}}}";

test "text·label 로케이터: 격리 world 의 JS 로 찾고(deep 직렬화) 그 묶음을 놓은 뒤 ref 처럼 누른다 — matched 는 찾은 글" {
    var trail: Trail = .{};
    defer trail.deinit();
    find_reply = .{ .ok = found_one };
    var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"text\":\"  Sign\\u00a0in \",\"nth\":0}}", 400);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &findPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n41\",\"name\":\"Sign in\"}}", r.result);
    const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup", "DOM.scrollIntoViewIfNeeded", "DOM.getContentQuads", "Page.getLayoutMetrics", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Page.captureScreenshot", "Runtime.callFunctionOn", "Input.dispatchMouseEvent", "Input.dispatchMouseEvent", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    // 질의는 정규화해 인자로(문자열로 끼워 넣지 않는다), deep 직렬화·묶음.
    const p = trail.params.items[2];
    for ([_][]const u8{ "\"arguments\":[{\"value\":\"text\"},{\"value\":\"Sign in\"},{\"value\":false},{\"value\":0},{\"value\":\"click\"}]", "\"serialization\":\"deep\"", "\"objectGroup\":\"maru-w9b-400\"", "\"executionContextId\":7" }) |needle|
        try testing.expect(std.mem.indexOf(u8, p, needle) != null);
    try testing.expect(try std.json.validate(testing.allocator, p));
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-400\"}", trail.params.items[3]);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[4], "\"backendNodeId\":41") != null);
    // 덮임 검사는 가장 가까운 조작 가능한 조상까지의 조상을 받는다(2 회차 — pointer-events:none 글·의사 요소 덮개).
    try testing.expectEqualStrings("Runtime.callFunctionOn", trail.methods.items[11]);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[11], "{\"value\":true}],") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[11], "if(up){") != null);
    // 맞은 것에서 대상까지 다른 조작 가능한 요소(링크·버튼)를 지나면 covered — 그것이 눌린다(5 회차).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[11], "return via?'covered':'ok'") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[11]));
    // label·exact·nth 없음·동작 이름도 그대로 인자로(1 회차 변이 — exact 를 버려도 살아남았다).
    trail.reset();
    var op2 = try Op.init(testing.allocator, .hover, "{\"locator\":{\"label\":\"Email\",\"exact\":true}}", 401);
    defer op2.deinit(testing.allocator);
    const r2 = try drive(&op2, &findPage, &trail);
    defer testing.allocator.free(r2.result);
    try testing.expectEqualStrings("Runtime.callFunctionOn", trail.methods.items[2]);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "\"arguments\":[{\"value\":\"label\"},{\"value\":\"Email\"},{\"value\":true},{\"value\":null},{\"value\":\"hover\"}]") != null);
}

test "text·label 로케이터: 숨은 일치만이면 ok:false + hint, 여럿이면 후보 ref, 찾기의 시한·오류·결과 상한에도 놓은 뒤 끝낸다, 놓기는 철회돼도" {
    var trail: Trail = .{};
    defer trail.deinit();
    const cases = [_]struct { reply: Reply, status: Status, want: []const u8 }{
        .{ .reply = .{ .ok = "{\"result\":{\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":0}],[\"hidden\",{\"type\":\"number\",\"value\":1}]]}}}" }, .status = .success, .want = "{\"ok\":false,\"hint\":\"1 matching element(s) are hidden" },
        .{ .reply = .{ .ok = "{\"result\":{\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":0}],[\"hidden\",{\"type\":\"number\",\"value\":0}]]}}}" }, .status = .success, .want = "false" },
        .{ .reply = .{ .ok = "{\"result\":{\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":2}],[\"cands\",{\"type\":\"array\",\"value\":[{\"type\":\"node\",\"value\":{\"backendNodeId\":7}},{\"type\":\"node\",\"value\":{\"backendNodeId\":9}}]}],[\"names\",{\"type\":\"array\",\"value\":[{\"type\":\"string\",\"value\":\"Email\"},{\"type\":\"string\",\"value\":\"Email 2\"}]}],[\"more\",{\"type\":\"boolean\",\"value\":false}]]}}}" }, .status = .failed, .want = "ambiguous: 2 elements match label~\"Email\" — n7 \"Email\", n9 \"Email 2\"" },
        .{ .reply = .{ .timed_out = "DevTools did not answer in time" }, .status = .timeout, .want = "DevTools did not answer in time" },
        .{ .reply = .{ .failed = result_too_large }, .status = .failed, .want = "too_large: the locator result was too large" },
        .{ .reply = .{ .cdp_error = "{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}" }, .status = .failed, .want = "locator script failed: Cannot find context" },
        .{ .reply = .{ .ok = "{\"result\":{}}" }, .status = .failed, .want = "malformed locator result" },
        .{ .reply = .{ .ok = "{not json" }, .status = .failed, .want = "malformed locator result" }, // 깨진 답에도 놓는다
    };
    for (cases) |c| {
        trail.reset();
        find_reply = c.reply;
        var op = try Op.init(testing.allocator, .type_text, "{\"locator\":{\"label\":\"Email\"},\"text\":\"x\"}", 401);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &findPage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        try testing.expect(std.mem.startsWith(u8, r.result, c.want));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
        try testing.expectEqual(@as(usize, 0), trail.count("Input.insertText"));
    }
    // 놓기 단계는 committed — 철회돼도 놓는다.
    find_reply = .{ .ok = found_one };
    var op = try Op.init(testing.allocator, .hover, "{\"locator\":{\"text\":\"Sign in\"}}", 402);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    while (step == .call and !std.mem.eql(u8, step.call.method, "Runtime.releaseObjectGroup")) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        step = try op.feed(testing.allocator, findPage(c.method, c.params));
    }
    try testing.expect(op.committed());
    testing.allocator.free(step.call.params);
}

// ── W9b②-3 — wait visible(로케이터)·kick ──

var wait_find_calls: usize = 0;
const found_none_hidden2 = "{\"result\":{\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":0}],[\"hidden\",{\"type\":\"number\",\"value\":2}]]}}}";
const found_wait_many = "{\"result\":{\"type\":\"object\",\"objectId\":\"o9\",\"deepSerializedValue\":{\"type\":\"object\",\"value\":[[\"n\",{\"type\":\"number\",\"value\":3}],[\"el\",{\"type\":\"node\",\"value\":{\"backendNodeId\":41}}],[\"name\",{\"type\":\"string\",\"value\":\"Sign in\"}]]}}}";

/// 처음 확인엔 숨은 일치 둘만, 그다음엔 셋이 맞는다(wait 의 답 — 첫 것과 그 수).
fn waitTextPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(KIND, Q, EXACT, NTH, ACTION)") != null) {
        wait_find_calls += 1;
        return .{ .ok = if (wait_find_calls == 1) found_none_hidden2 else found_wait_many };
    }
    return happyPage(method, params);
}

fn waitTextNonePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(KIND, Q, EXACT, NTH, ACTION)") != null) return .{ .ok = found_none_hidden2 };
    return happyPage(method, params);
}

test "wait visible(text): 확인마다 격리 world 의 JS 로(wait 모드·kick) 찾고 놓는다 — 숨은 것만이면 다음 확인, 보이면 matched·여럿이면 ambiguous, 누르거나 스크롤하지 않는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    wait_find_calls = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"text\":\"Sign in\"},\"timeout_ms\":5000}", 500);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &waitTextPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n41\",\"name\":\"Sign in\"},\"ambiguous\":true}", r.result);
    try testing.expectEqual(@as(usize, 1), trail.sleeps);
    const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup", "Page.createIsolatedWorld", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqualSlices(usize, &.{ 2, 5 }, trail.kicked.items);
    try testing.expectEqual(@as(usize, 0), trail.required.items.len); // 찾기는 kick 없이도 답한다
    try testing.expect(std.mem.indexOf(u8, trail.params.items[2], "{\"value\":\"wait\"}]") != null);
    // 시한 — 마지막 확인의 숨은 일치 수를 싣는다.
    trail.reset();
    var none = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"label\":\"Email\",\"exact\":true},\"timeout_ms\":300}", 501);
    defer none.deinit(testing.allocator);
    const t = try drive(&none, &waitTextNonePage, &trail);
    defer testing.allocator.free(t.result);
    try testing.expectEqual(Status.timeout, t.status);
    try testing.expectEqualStrings("{\"hidden\":2}", t.result);
    try testing.expectEqual(trail.count("Runtime.callFunctionOn"), trail.count("Runtime.releaseObjectGroup"));
    // 모양: visible 엔 로케이터가 있어야 한다(selector 면 L2 가 selector 조건으로 바꾼다).
    try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"selector\":\"#a\",\"timeout_ms\":5}", 1));
    try testing.expectError(error.UnknownRole, Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"buton\"},\"timeout_ms\":5}", 1));
}

var judge_answer: []const u8 = "{\"result\":{\"type\":\"number\",\"value\":1}}";
var doc_errors_left: usize = 0;

/// role wait — 후보의 보임 판정(finder 의 visible)에 `judge_answer`, 문서 잡기는 `doc_errors_left` 번 이동 오류.
fn waitRolePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "{\"value\":\"visible\"}") != null) return .{ .ok = judge_answer };
    if (doc_errors_left > 0 and std.mem.eql(u8, method, "Runtime.evaluate") and std.mem.indexOf(u8, params, "\"expression\":\"document\"") != null) {
        doc_errors_left -= 1;
        return .{ .cdp_error = "{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}" };
    }
    return rolePage(method, params);
}

test "wait visible(role): 질의(kick)로 후보를 모아 한 번에 보임을 보고 묶음을 놓는다 — 보이는 첫 것이 matched, 맞는 것이 여럿이면 ambiguous, 없으면 시한에 hidden" {
    var trail: Trail = .{};
    defer trail.deinit();
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":1}}";
    doc_errors_left = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"save\"},\"timeout_ms\":5000}", 510);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &waitRolePage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n12\",\"name\":\"Save changes\"},\"ambiguous\":true}", r.result);
    const want = [_][]const u8{ "Page.getFrameTree", "Page.createIsolatedWorld", "Runtime.evaluate", "Runtime.evaluate", "Accessibility.queryAXTree", "DOM.resolveNode", "DOM.resolveNode", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(want.len, trail.methods.items.len);
    for (want, trail.methods.items) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqualSlices(usize, &.{4}, trail.kicked.items);
    try testing.expectEqualSlices(usize, &.{4}, trail.required.items); // 질의는 꼭 kick 과(숨은 탭에서 kick 없이 가면 30 초 매달린다)
    // 후보는 그 world 에, 같은 묶음에 잡고 판정 JS 에 넘긴다.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[5], "\"backendNodeId\":11,\"executionContextId\":7,\"objectGroup\":\"maru-w9b-510\"") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[7], "{\"objectId\":\"o-1\"},{\"objectId\":\"o-1\"}]") != null);
    try testing.expect(try std.json.validate(testing.allocator, trail.params.items[7]));
    // nth 면 그 하나만 보고 ambiguous 가 아니다.
    trail.reset();
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":0}}";
    var nth = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"nth\":0},\"timeout_ms\":5000}", 511);
    defer nth.deinit(testing.allocator);
    const n = try drive(&nth, &waitRolePage, &trail);
    defer testing.allocator.free(n.result);
    try testing.expectEqualStrings("{\"ok\":true,\"matched\":{\"ref\":\"n11\",\"name\":\"Save\"}}", n.result);
    try testing.expectEqual(@as(usize, 1), trail.count("DOM.resolveNode"));
    // 보이는 것이 없으면 다음 확인 — 확인마다 묶음을 놓고, 시한엔 맞는 것의 수.
    trail.reset();
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":-1}}";
    var none = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"save\"},\"timeout_ms\":300}", 512);
    defer none.deinit(testing.allocator);
    const t = try drive(&none, &waitRolePage, &trail);
    defer testing.allocator.free(t.result);
    try testing.expectEqual(Status.timeout, t.status);
    try testing.expectEqualStrings("{\"hidden\":2}", t.result);
    try testing.expect(trail.sleeps >= 2);
    try testing.expectEqual(trail.count("Accessibility.queryAXTree"), trail.count("Runtime.releaseObjectGroup"));
    try testing.expectEqual(@as(usize, 0), trail.count("DOM.scrollIntoViewIfNeeded") + trail.count("Input.dispatchMouseEvent"));
    // 이동 중(문서를 잡을 context 가 사라졌다) — 다음 확인으로.
    trail.reset();
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":0}}";
    doc_errors_left = 1;
    var nav = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true},\"timeout_ms\":5000}", 513);
    defer nav.deinit(testing.allocator);
    const v = try drive(&nav, &waitRolePage, &trail);
    defer testing.allocator.free(v.result);
    try testing.expectEqual(Status.success, v.status);
    try testing.expectEqual(@as(usize, 1), trail.sleeps);
}

var ax_unsent_left: usize = 0;

fn busyAxPage(method: []const u8, params: []const u8) Reply {
    if (ax_unsent_left > 0 and std.mem.eql(u8, method, "Accessibility.queryAXTree")) {
        ax_unsent_left -= 1;
        return .{ .not_sent = busy_reason };
    }
    return rolePage(method, params);
}

test "kick: 자리가 없어 못 보낸 질의·포인터 이동은 잠깐 뒤 다시(잃은 kick 을 sidecar 가 놓을 때까지) — 그래도 안 되면 묶음을 놓고 실패, hover 는 꼭, wait 의 확인은 되면 kick" {
    var trail: Trail = .{};
    defer trail.deinit();
    ax_unsent_left = 2;
    var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 520);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &busyAxPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expectEqual(@as(usize, 2), trail.sleeps);
    try testing.expectEqual(@as(usize, 3), trail.count("Accessibility.queryAXTree"));
    trail.reset();
    ax_unsent_left = 1000;
    var busy = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 521);
    defer busy.deinit(testing.allocator);
    const b = try drive(&busy, &busyAxPage, &trail);
    defer testing.allocator.free(b.result);
    try testing.expectEqual(Status.failed, b.status);
    try testing.expectEqualStrings(busy_reason, b.result);
    try testing.expectEqual(@as(usize, 1 + max_kick_retries), trail.count("Accessibility.queryAXTree"));
    try testing.expectEqual(@as(usize, max_kick_retries), trail.sleeps); // 4.5 초 — sidecar 가 잃은 kick 을 3–3.75 초에 놓는다(app_host_abi 의 comptime 검사)
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    ax_unsent_left = 0;
    // hover 의 포인터 이동, selector wait 의 확인.
    trail.reset();
    var hover = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 522);
    defer hover.deinit(testing.allocator);
    const h = try drive(&hover, &happyPage, &trail);
    defer testing.allocator.free(h.result);
    try testing.expectEqual(@as(usize, 1), trail.kicked.items.len);
    try testing.expectEqualSlices(usize, trail.kicked.items, trail.required.items);
    try testing.expectEqualStrings("Input.dispatchMouseEvent", trail.methods.items[trail.kicked.items[0]]);
    trail.reset();
    var w = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#late\",\"timeout_ms\":5000}", 523);
    defer w.deinit(testing.allocator);
    const ws_ = try drive(&w, &editorPage, &trail);
    defer testing.allocator.free(ws_.result);
    try testing.expectEqualSlices(usize, &.{2}, trail.kicked.items);
    try testing.expectEqual(@as(usize, 0), trail.required.items.len); // 확인은 kick 없이도 답한다 — 자리가 하나뿐이면 주 호출만
}

test "kick: wait 의 질의 재시도는 시한을 넘기지 않는다 — 자리가 계속 없으면 시한에 끝나고 묶음을 놓는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    ax_unsent_left = 1000;
    defer ax_unsent_left = 0;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":300}", 524);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &busyAxPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.timeout, r.status);
    try testing.expect(op.now_ms <= op.wait_deadline_ms + kick_retry_ms);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
}

/// 확인 하나를 끝낸 것처럼(시작·끝·그 안의 무거운 호출 합) 다음 차례를 묻는다.
fn endCheck(op: *Op, start: i64, now: i64, heavy: i64) !Step {
    op.check_start_ms = start;
    op.now_ms = now;
    op.check_heavy_ms = heavy;
    return op.sleepOrTimeout(testing.allocator);
}

test "wait 의 간격·마감: 확인 시간의 네 배 이상(직전 두 번 가운데 작은 것, 첫 것은 0.5 초까지)과 누적 1/5 를 함께 지키고, 그만큼 쉬면 시한을 넘길 때는 마지막 확인 하나를 앞당긴다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"text\":\"Go\"},\"timeout_ms\":25000}", 530);
    defer op.deinit(testing.allocator);
    op.wait_deadline_ms = 25_000;
    // 첫 확인이 긴 작업에 부풀었다(2.5 초) — 0.5 초로 본다(1 회차: 10 초 잤다).
    try testing.expectEqual(@as(u32, 2000), (try endCheck(&op, 0, 2_500, 2_500)).sleep);
    // 숨은 큰 탭의 확인이 1.9 초 — 7.6 초 쉰다(2 회차: 2 초 상한이 페이지를 절반 넘게 멈췄다).
    try testing.expectEqual(@as(u32, 7600), (try endCheck(&op, 4_500, 6_400, 1_900)).sleep);
    // 한 번만 짧았다(0.2 초) — 직전 두 번 가운데 작은 쪽의 네 배(0.8 초).
    try testing.expectEqual(@as(u32, 800), (try endCheck(&op, 14_000, 14_200, 200)).sleep);
    // 다시 길다(3 초) — 직전 둘만 보면 0.8 초지만 누적(0.5+1.9+0.2+3=5.6 초)의 다섯 배인 28 초까지는 쉬어야 한다(3 회차 — 높낮이가
    // 갈리면 페이지를 절반 넘게 멈췄다). 그러면 시한 안에 확인이 없다 — 마지막 확인(직전처럼 3 초)이 시한에 끝나게 4 초 뒤.
    try testing.expectEqual(@as(u32, 4000), (try endCheck(&op, 15_000, 18_000, 3_000)).sleep);
    // 마지막 확인은 한 번 — 그 뒤엔 시한 전이어도 끝, 숨은 일치 수를 싣는다.
    op.wait_hidden = 4;
    const t = try endCheck(&op, 22_000, 24_000, 2_000);
    defer testing.allocator.free(t.done.result);
    try testing.expectEqual(Status.timeout, t.done.status);
    try testing.expectEqualStrings("{\"hidden\":4}", t.done.result);

    // 3 회차: 숨은 2.95 만 요소 탭(확인 3.3·3.1 초)의 21 초 wait 이 8.4 초에 포기했다(쉼 12.3 초는 남은 12.6 초보다 짧아 일찍 깨지
    // 않고, 쉼과 확인이 시한을 2 초 넘겨 곧 포기 — 옛 판으로 재현). 이제 마지막 확인을 시한 즈음에 한다.
    var mid = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":21000}", 531);
    defer mid.deinit(testing.allocator);
    mid.wait_deadline_ms = 21_000;
    try testing.expectEqual(@as(u32, 2000), (try endCheck(&mid, 0, 3_301, 3_301)).sleep);
    try testing.expectEqual(@as(u32, 9533), (try endCheck(&mid, 5_301, 8_384, 3_083)).sleep);

    // 첫 확인이 3 초 걸린 5 초 wait — 남은 2 초에 한 번 더 본다(1 회차: 3 초에 포기했다).
    var short = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"text\":\"Go\"},\"timeout_ms\":5000}", 532);
    defer short.deinit(testing.allocator);
    short.wait_deadline_ms = 5_000;
    try testing.expectEqual(@as(u32, 1), (try endCheck(&short, 0, 3_000, 3_000)).sleep);

    // 지금 시작해도 시한을 2 초 넘게 넘길 확인(직전 6 초, 남은 3 초)은 하지 않는다(서버 reaper 30 초 — 계획 공격 1·3 회차).
    var late = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"text\":\"Go\"},\"timeout_ms\":25000}", 533);
    defer late.deinit(testing.allocator);
    late.wait_deadline_ms = 25_000;
    _ = try endCheck(&late, 0, 1_000, 1_000);
    const l = try endCheck(&late, 16_000, 22_000, 6_000);
    defer testing.allocator.free(l.done.result);
    try testing.expectEqual(Status.timeout, l.done.status);

    // selector 도 마지막 확인을 시한 안에 한다(3 회차 — 전에는 시한까지 자고 확인 없이 끝났다). 확인은 짧아 누적은 보지 않는다.
    var sel = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#x\",\"timeout_ms\":1000}", 534);
    defer sel.deinit(testing.allocator);
    sel.wait_deadline_ms = 1_000;
    try testing.expectEqual(@as(u32, 50), (try endCheck(&sel, 0, 5, 0)).sleep);
    sel.wait_interval_ms = 500;
    try testing.expectEqual(@as(u32, 395), (try endCheck(&sel, 595, 600, 0)).sleep); // 500 ms 쉬면 시한을 넘는다 — 직전 확인(5 ms)이 시한에 끝나게 395 ms 뒤 마지막 확인
    const sd = try endCheck(&sel, 995, 1_000, 0);
    defer testing.allocator.free(sd.done.result);
    try testing.expectEqual(Status.timeout, sd.done.status);
}

test "철회: 문서·후보 묶음을 쥐었으면 놓은 뒤(committed) 「cancelled」 로 끝낸다, 쥔 것이 없으면 부른 쪽이 곧 끝낸다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":5000}", 540);
    defer op.deinit(testing.allocator);
    try testing.expect(try op.cancel(testing.allocator) == null);
    op.doc_obj = try testing.allocator.dupe(u8, "doc-1");
    const step = (try op.cancel(testing.allocator)).?;
    defer testing.allocator.free(step.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", step.call.method);
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-540\"}", step.call.params);
    try testing.expect(op.committed());
    const d = try op.feed(testing.allocator, .{ .ok = "{}" });
    defer testing.allocator.free(d.done.result);
    try testing.expectEqual(Status.failed, d.done.status);
    try testing.expectEqualStrings("the request was cancelled", d.done.result);
    try testing.expect(op.doc_obj == null);
    // 덮임 검사 앞(요소의 원격 객체를 잡았다) — 그것도 놓는다(2 회차). 대상 없는 press 의 키 누름 앞은 쥔 것이 없다.
    var act = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 541);
    defer act.deinit(testing.allocator);
    act.stage = .hit_test;
    const rel = (try act.cancel(testing.allocator)).?;
    defer testing.allocator.free(rel.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", rel.call.method);
    var press = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\"}", 542);
    defer press.deinit(testing.allocator);
    press.stage = .key_down;
    try testing.expect(try press.cancel(testing.allocator) == null);
}

// ── W9b②-3 적대 리뷰 4 회차 ──────────────────────────────────────────────────────────────────────────────

var r4_quads_calls: usize = 0;
var r4_move_unsent_left: usize = 0;

/// 덮임 검사 뒤 첫 mouseMoved 는 자리가 없다 — 그 사이 요소가 옮겨 간다(두 번째 상자 조회부터 다른 자리).
fn r4MovingHoverPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "DOM.getContentQuads")) {
        r4_quads_calls += 1;
        return .{ .ok = if (r4_quads_calls == 1) "{\"quads\":[[0,0,46,0,46,20,0,20]]}" else "{\"quads\":[[100,200,146,200,146,220,100,220]]}" };
    }
    if (r4_move_unsent_left > 0 and std.mem.eql(u8, method, "Input.dispatchMouseEvent")) {
        r4_move_unsent_left -= 1;
        return .{ .not_sent = busy_reason };
    }
    return happyPage(method, params);
}

test "4 회차: hover 가 자리를 기다려 다시 보낼 때는 옛 좌표가 아니라 다시 재고(덮임 검사까지) 옮긴다" {
    var trail: Trail = .{};
    defer trail.deinit();
    r4_quads_calls = 0;
    r4_move_unsent_left = 1;
    var op = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 600);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &r4MovingHoverPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    var last_move: []const u8 = "";
    for (trail.methods.items, trail.params.items) |m, p| if (std.mem.eql(u8, m, "Input.dispatchMouseEvent")) {
        last_move = p;
    };
    try testing.expect(std.mem.indexOf(u8, last_move, "\"x\":123,\"y\":210") != null);
    try testing.expectEqual(@as(usize, 2), trail.count("Runtime.callFunctionOn")); // 덮임 검사도 다시
}

var r4_ax_unsent_reason: []const u8 = busy_reason;
fn r4UnsentAxPage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return .{ .not_sent = r4_ax_unsent_reason };
    return rolePage(method, params);
}

test "4 회차: 자리 없음(busy)만 다시 보낸다 — 탭이 준비 안 됨·요청 실패는 곧 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    r4_ax_unsent_reason = "the Chromium tab is not ready";
    defer r4_ax_unsent_reason = busy_reason;
    var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 601);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &r4UnsentAxPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expectEqual(@as(usize, 0), trail.sleeps);
    try testing.expectEqual(@as(usize, 1), trail.count("Accessibility.queryAXTree"));
}

test "4 회차: wait 의 질의가 자리를 계속 못 얻어도 재시도 시간을 확인 시간으로 치지 않는다 — 시한 근처까지 기다린다" {
    var trail: Trail = .{};
    defer trail.deinit();
    r4_ax_unsent_reason = busy_reason;
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":20000}", 602);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &r4UnsentAxPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.timeout, r.status);
    try testing.expect(op.now_ms >= op.wait_deadline_ms - 1_000); // 옛 판: 약 14 초에 시한
    try testing.expect(op.now_ms <= op.wait_deadline_ms + kick_retry_ms);
}

var r4_unsent_locate: usize = 0;
var r4_unsent_move: usize = 0;
fn r4BusyBothPage(method: []const u8, params: []const u8) Reply {
    if (r4_unsent_locate > 0 and std.mem.eql(u8, method, "Accessibility.queryAXTree")) {
        r4_unsent_locate -= 1;
        return .{ .not_sent = busy_reason };
    }
    if (r4_unsent_move > 0 and std.mem.eql(u8, method, "Input.dispatchMouseEvent")) {
        r4_unsent_move -= 1;
        return .{ .not_sent = busy_reason };
    }
    return rolePage(method, params);
}

test "4 회차: kick 재시도 횟수는 kick 을 실은 호출이 나가면 처음부터 — 질의에서 거의 다 써도 포인터 이동은 다시 다 쓴다" {
    var trail: Trail = .{};
    defer trail.deinit();
    r4_unsent_locate = max_kick_retries - 1;
    r4_unsent_move = max_kick_retries - 1;
    var op = try Op.init(testing.allocator, .hover, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 603);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &r4BusyBothPage, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
}

/// 메서드마다 걸리는 시간 — 확인 시간(heavy)은 질의·크기 세기·보임 판정의 합이어야 한다.
fn r4Cost(method: []const u8, params: []const u8) i64 {
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return 1_000;
    if (std.mem.eql(u8, method, "Runtime.evaluate") and std.mem.indexOf(u8, params, "\"expression\":\"document\"") == null) return 200; // 크기 세기
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) return 300; // 보임 판정
    return 5;
}

test "4 회차: 확인 시간은 그 확인의 질의·크기 세기·판정의 합이다(시계를 흘려 본다)" {
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":-1}}";
    defer judge_answer = "{\"result\":{\"type\":\"number\",\"value\":1}}";
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true},\"timeout_ms\":5000}", 604);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    var checks: usize = 0;
    while (true) switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .done => |d| {
            testing.allocator.free(d.result);
            break;
        },
        .sleep => |ms| {
            checks += 1;
            if (checks == 1) {
                try testing.expectEqual(@as(i64, 1_500), op.last_heavy_ms); // 200 + 1000 + 300
                op.wait_deadline_ms = op.now_ms; // 첫 확인만 본다
            }
            op.now_ms += ms;
            step = try op.wake(testing.allocator);
        },
        .call => |c| {
            op.now_ms += r4Cost(c.method, c.params);
            const reply = waitRolePage(c.method, c.params);
            testing.allocator.free(c.params);
            step = try op.feed(testing.allocator, reply);
        },
    };
    try testing.expect(checks >= 1);
}

test "4 회차: kick 종류 — best_effort 만 자리가 하나뿐이면 주 호출만 보낸다(optional)" {
    try testing.expect(Kick.best_effort.optional());
    try testing.expect(!Kick.required.optional());
}

test "4 회차: 확인 안에서 kick 자리를 기다린 시간은 그 확인의 시간 짐작에서 뺀다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":20000}", 605);
    defer op.deinit(testing.allocator);
    op.wait_deadline_ms = 20_000;
    op.check_start_ms = 0;
    op.now_ms = 5_000;
    op.check_wait_ms = 4_500; // 45 번 × 100 ms
    _ = try op.sleepOrTimeout(testing.allocator);
    try testing.expectEqual(@as(i64, 500), op.last_check_ms);
    try testing.expectEqual(@as(i64, 0), op.check_wait_ms);
}

// ── W9b②-3 적대 리뷰 5 회차 ──────────────────────────────────────────────────────────────────────────────

/// 시계를 흘리며 끝까지 돌린다 — `cost` 가 메서드마다 걸린 시간, 안전판 `cap` 번에서 멈춘다(끝없이 도는 변이에 시험이 매달리지 않게).
fn r5DriveClock(op: *Op, answer: *const fn (now: i64, method: []const u8, params: []const u8) Reply, cost: *const fn (method: []const u8, params: []const u8) i64, cap: usize, trail: *Trail) !struct { status: Status, result: []u8, steps: usize } {
    var step = try op.start(testing.allocator);
    var n: usize = 0;
    while (n < cap) : (n += 1) switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .done => |d| return .{ .status = d.status, .result = d.result, .steps = n },
        .sleep => |ms| {
            trail.sleeps += 1;
            op.now_ms += ms;
            step = try op.wake(testing.allocator);
        },
        .call => |c| {
            try trail.methods.append(testing.allocator, c.method);
            try trail.params.append(testing.allocator, c.params);
            // 보내지 못한 호출(자리 없음)은 시간이 들지 않는다 — 답은 보낸 순간의 시각으로 정한다.
            const reply = answer(op.now_ms, c.method, c.params);
            if (reply != .not_sent) op.now_ms += cost(c.method, c.params);
            step = try op.feed(testing.allocator, reply);
        },
    };
    // 안전판 — 끝나지 않았다. 남은 Step 을 놓고 실패로.
    switch (step) {
        .call => |c| testing.allocator.free(c.params),
        .done => |d| testing.allocator.free(d.result),
        .confirm => |cf| testing.allocator.free(cf.origin),
        .sleep => {},
    }
    return error.TestDidNotFinish;
}

fn r5NoCost(method: []const u8, params: []const u8) i64 {
    _ = method;
    _ = params;
    return 0;
}

fn r5AlwaysBusyMove(now: i64, method: []const u8, params: []const u8) Reply {
    _ = now;
    if (std.mem.eql(u8, method, "Input.dispatchMouseEvent")) return .{ .not_sent = busy_reason };
    return happyPage(method, params);
}

test "5 회차: 포인터 이동이 끝내 자리를 못 얻으면 정확히 max_kick_retries 번 다시 재고 실패한다(끝없이 돌지 않는다)" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 700);
    defer op.deinit(testing.allocator);
    const r = try r5DriveClock(&op, &r5AlwaysBusyMove, &r5NoCost, 5_000, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expectEqual(@as(usize, max_kick_retries), trail.sleeps);
    try testing.expectEqual(@as(usize, max_kick_retries + 1), trail.count("Input.dispatchMouseEvent"));
    // 다시 재기 전에 늘 묶음을 놓는다(놓기 → 화면 안으로 순서).
    var released_before_scroll: usize = 0;
    for (trail.methods.items, 0..) |m, i| if (std.mem.eql(u8, m, "DOM.scrollIntoViewIfNeeded") and i > 0 and std.mem.eql(u8, trail.methods.items[i - 1], "Runtime.releaseObjectGroup")) {
        released_before_scroll += 1;
    };
    try testing.expectEqual(@as(usize, max_kick_retries), released_before_scroll);
}

test "5 회차: 포인터 이동을 기다리며 자는 동안 철회되면 묶음을 놓는다" {
    var op = try Op.init(testing.allocator, .hover, "{\"selector\":\"#h\"}", 701);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    while (true) switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .call => |c| {
            defer testing.allocator.free(c.params);
            step = try op.feed(testing.allocator, r5AlwaysBusyMove(0, c.method, c.params));
        },
        .sleep => break,
        .done => |d| {
            testing.allocator.free(d.result);
            return error.TestUnexpectedResult;
        },
    };
    const release = (try op.cancel(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(release.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", release.call.method);
}

fn r5Busy1to9(now: i64, method: []const u8, params: []const u8) Reply {
    // 첫 질의 뒤 둘째 확인부터 자리가 없다 — 재시도를 다 쓰고(45 번), 짧게 끝나는 확인이 이어지다가 시한 3.5 초 전에 풀린다.
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree") and now >= 4_000 and now < 16_500) return .{ .not_sent = busy_reason };
    return waitRolePage(method, params);
}

fn r5SlowQuery(method: []const u8, params: []const u8) i64 {
    _ = params;
    if (std.mem.eql(u8, method, "Accessibility.queryAXTree")) return 6_500;
    return 0;
}

test "5 회차: 자리 없음으로 짧게 끝난 확인 뒤에도 「시한을 2 초 넘길 질의는 보내지 않는다」 — 질의 시간은 마지막 무거운 확인으로 짐작한다" {
    var trail: Trail = .{};
    defer trail.deinit();
    judge_answer = "{\"result\":{\"type\":\"number\",\"value\":-1}}";
    defer judge_answer = "{\"result\":{\"type\":\"number\",\"value\":1}}";
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true},\"timeout_ms\":20000}", 702);
    defer op.deinit(testing.allocator);
    const r = try r5DriveClock(&op, &r5Busy1to9, &r5SlowQuery, 5_000, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.timeout, r.status);
    try testing.expect(op.now_ms <= op.wait_deadline_ms + 2_000); // 옛 판: 17 초에 6.5 초 질의를 보내 23.5 초
}

test "5 회차: 재시도로 기다린 시간은 그 확인의 check_wait_ms 에 쌓인다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\"},\"timeout_ms\":20000}", 703);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    while (true) switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .call => |c| {
            defer testing.allocator.free(c.params);
            const reply: Reply = if (std.mem.eql(u8, c.method, "Accessibility.queryAXTree")) .{ .not_sent = busy_reason } else rolePage(c.method, c.params);
            step = try op.feed(testing.allocator, reply);
        },
        .sleep => break,
        .done => |d| {
            testing.allocator.free(d.result);
            return error.TestUnexpectedResult;
        },
    };
    try testing.expectEqual(@as(i64, kick_retry_ms), op.check_wait_ms);
    if (try op.cancel(testing.allocator)) |s| testing.allocator.free(s.call.params);
}

fn r5BusyKeyUp(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Input.dispatchKeyEvent") and std.mem.indexOf(u8, params, "keyUp") != null) return .{ .not_sent = busy_reason };
    return happyPage(method, params);
}

test "5 회차: 누른 뒤 떼기를 끝내 못 보낸 실패는 「다시 하라」 고 하지 않는다 — 누름은 이미 갔다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .press, "{\"key\":\"Enter\"}", 704);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &r5BusyKeyUp, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expect(std.mem.indexOf(u8, r.result, "retry") == null);
    try testing.expect(std.mem.indexOf(u8, r.result, "pressed") != null);
}

test "5 회차: 질의 재시도도 마지막 무거운 확인으로 짐작한다 — 직전 확인이 짧았어도 시한을 2 초 넘길 질의는 다시 보내지 않는다" {
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"visible\",\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true},\"timeout_ms\":10000}", 705);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    while (true) switch (step) {
        .call => |c| {
            defer testing.allocator.free(c.params);
            if (std.mem.eql(u8, c.method, "Accessibility.queryAXTree")) break;
            step = try op.feed(testing.allocator, waitRolePage(c.method, c.params));
        },
        else => return error.TestUnexpectedResult,
    };
    // 앞선 무거운 확인은 6 초, 직전 확인은 자리 없음으로 곧 끝났다. 시한 1 초 전 — 지금 다시 보내면 질의가 시한을 5 초 넘긴다.
    op.heavy_count = 1;
    op.last_heavy_ms = 6_000;
    op.last_check_ms = 10;
    op.now_ms = op.wait_deadline_ms - 1_000;
    step = try op.feed(testing.allocator, .{ .not_sent = busy_reason });
    try testing.expectEqual(@as(usize, 0), op.kick_retries);
    switch (step) {
        .confirm => unreachable, // W9c③: 업로드만 멈춘다
        .sleep => return error.TestUnexpectedResult, // 옛 판: kick_retry_ms 뒤 다시
        .call => |c| testing.allocator.free(c.params),
        .done => |d| testing.allocator.free(d.result),
    }
}

// ── W9b③: 누르기 전 프레임 ────────────────────────────────────────────────────────────────────────────────

var w9b3_frame_reply: Reply = .{ .ok = "{\"data\":\"\"}" };
fn w9b3FramePage(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Page.captureScreenshot")) return w9b3_frame_reply;
    return happyPage(method, params);
}

test "W9b③: 누르기 전 프레임 — 스크린샷이 오류로 답해도(그린 뒤다) 덮임 검사·누르기로, 못 보냈으면 누르지 않고 놓고 실패" {
    defer w9b3_frame_reply = .{ .ok = "{\"data\":\"\"}" };
    const cases = [_]struct { reply: Reply, status: Status, presses: usize }{
        .{ .reply = .{ .cdp_error = "{\"code\":-32000,\"message\":\"Unable to capture screenshot\"}" }, .status = .success, .presses = 1 },
        .{ .reply = .{ .not_sent = busy_reason }, .status = .failed, .presses = 0 },
    };
    for (cases, 0..) |c, n| {
        var trail: Trail = .{};
        defer trail.deinit();
        w9b3_frame_reply = c.reply;
        var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 800 + n);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &w9b3FramePage, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(c.status, r.status);
        var presses: usize = 0;
        for (trail.params.items) |p| if (std.mem.indexOf(u8, p, "mousePressed") != null) {
            presses += 1;
        };
        try testing.expectEqual(c.presses, presses);
        // 어느 쪽이든 쥔 묶음은 놓는다.
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

test "W9b③: 누르기 전 프레임을 기다리는 동안 철회되면 묶음을 놓는다(누르지 않는다)" {
    var op = try Op.init(testing.allocator, .click, "{\"selector\":\"#b\"}", 810);
    defer op.deinit(testing.allocator);
    var step = try op.start(testing.allocator);
    while (true) switch (step) {
        .call => |c| {
            defer testing.allocator.free(c.params);
            if (std.mem.eql(u8, c.method, "Page.captureScreenshot")) break;
            step = try op.feed(testing.allocator, happyPage(c.method, c.params));
        },
        else => return error.TestUnexpectedResult,
    };
    const release = (try op.cancel(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(release.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", release.call.method);
}

fn w9b3DialogCheck(method: []const u8, params: []const u8) Reply {
    if (std.mem.eql(u8, method, "Runtime.evaluate")) return .{ .not_sent = dialog_reason };
    return happyPage(method, params);
}

test "W9b③ 적대 리뷰 2 회차: wait 의 확인이 대화상자로 거절되면 시한까지 되풀이하지 않고 곧 그 이유로 끝난다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .wait, "{\"condition\":\"selector\",\"selector\":\"#never\",\"timeout_ms\":4000}", 820);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &w9b3DialogCheck, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expectEqualStrings(dialog_reason, r.result);
    try testing.expectEqual(@as(usize, 0), trail.sleeps);
}

test "W9b③ 적대 리뷰 3 회차: press(대상 있음·없음)와 빈 글 type 의 Delete 도 누르기 바로 앞에 프레임을 그린다 — 숨긴 탭의 키가 닿게" {
    const cases = [_]struct { kind: Kind, arg: []const u8, down: []const u8, page: *const fn ([]const u8, []const u8) Reply = &happyPage }{
        .{ .kind = .press, .arg = "{\"key\":\"Enter\",\"selector\":\"#e\"}", .down = "\"keyDown\"" },
        .{ .kind = .press, .arg = "{\"key\":\"Enter\"}", .down = "\"keyDown\"" },
        .{ .kind = .type_text, .arg = "{\"selector\":\"#e\",\"text\":\"\"}", .down = "\"keyDown\",\"key\":\"Delete\"", .page = &editorPage },
    };
    for (cases, 0..) |c, n| {
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, c.kind, c.arg, 830 + n);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, c.page, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.success, r.status);
        const down = for (trail.params.items, 0..) |p, i| {
            if (std.mem.indexOf(u8, p, c.down) != null) break i;
        } else return error.TestUnexpectedResult;
        try testing.expect(down > 0);
        try testing.expectEqualStrings("Page.captureScreenshot", trail.methods.items[down - 1]);
        try testing.expectEqualStrings(frame_params, trail.params.items[down - 1]);
    }
}

fn w9b3r3DialogOnPress(method: []const u8, params: []const u8) Reply {
    // 누름을 받자 페이지가 대화상자를 띄웠다 — sidecar 는 그 호출을 곧 끝내고(.dialog → failed), 놓기는 대화상자가 답해질 때까지 거절한다.
    if (std.mem.indexOf(u8, params, "\"keyDown\"") != null or std.mem.indexOf(u8, params, "mousePressed") != null) return .{ .failed = dialog_reason };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .not_sent = dialog_reason };
    return happyPage(method, params);
}

test "W9b③ 적대 리뷰 3 회차: 누른 뒤 페이지가 대화상자를 띄우면 떼기를 보내고 「눌렀다 — 대화상자」 로 답한다(실패로 답하면 다시 해 두 번 제출)" {
    const cases = [_]struct { kind: Kind, arg: []const u8, up: []const u8 }{
        .{ .kind = .press, .arg = "{\"key\":\"Enter\"}", .up = "\"keyUp\"" },
        .{ .kind = .press, .arg = "{\"key\":\"Enter\",\"selector\":\"#e\"}", .up = "\"keyUp\"" },
        .{ .kind = .click, .arg = "{\"selector\":\"#b\"}", .up = "mouseReleased" },
    };
    for (cases, 0..) |c, n| {
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, c.kind, c.arg, 840 + n);
        defer op.deinit(testing.allocator);
        const r = try drive(&op, &w9b3r3DialogOnPress, &trail);
        defer testing.allocator.free(r.result);
        try testing.expectEqual(Status.success, r.status);
        try testing.expect(std.mem.indexOf(u8, r.result, "\"dialog\":true") != null);
        var ups: usize = 0;
        for (trail.params.items) |p| if (std.mem.indexOf(u8, p, c.up) != null) {
            ups += 1;
        };
        try testing.expectEqual(@as(usize, 1), ups);
    }
}

fn w9b3r3DialogOnInsert(method: []const u8, params: []const u8) Reply {
    // 글을 넣자 페이지가 대화상자를 띄웠다(oninput 의 alert) — 다시 읽기·놓기는 대화상자 동안 답하지 않는다.
    if (std.mem.eql(u8, method, "Input.insertText")) return .{ .failed = dialog_reason };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .not_sent = dialog_reason };
    if (std.mem.eql(u8, method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, params, "function(want,bh,bn)") != null) return .{ .not_sent = dialog_reason };
    return editorPage(method, params);
}

test "W9b③ 적대 리뷰 3 회차: 글을 넣은 뒤 대화상자가 뜨면 다시 읽지 않고 「갔다 + 대화상자」 로 답한다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"x\"}", 850);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &w9b3r3DialogOnInsert, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expect(std.mem.indexOf(u8, r.result, "\"dialog\":true") != null);
    for (trail.params.items) |p| try testing.expect(std.mem.indexOf(u8, p, "function(want,bh,bn)") == null); // 다시 읽기를 보내지 않았다
}

fn w9b3r4InsertNotSent(method: []const u8, params: []const u8) Reply {
    // 고르기의 답과 대화상자가 같은 tick 에 왔다 — 넣기는 대화상자로 거절(확실히 보내지 않았다).
    if (std.mem.eql(u8, method, "Input.insertText")) return .{ .not_sent = dialog_reason };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .not_sent = dialog_reason };
    return editorPage(method, params);
}

test "W9b③ 적대 리뷰 4 회차: 넣기를 보내지 못했으면(대화상자가 같은 tick 에 왔다) 「갔다 + dialog」 가 아니라 실패" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"x\"}", 851);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &w9b3r4InsertNotSent, &trail);
    defer testing.allocator.free(r.result);
    try testing.expect(r.status != .success);
}

fn w9b3r4DeleteNotSent(method: []const u8, params: []const u8) Reply {
    if (std.mem.indexOf(u8, params, "\"keyDown\",\"key\":\"Delete\"") != null) return .{ .not_sent = busy_reason };
    return editorPage(method, params);
}

test "W9b③ 적대 리뷰 4 회차: 빈 글 type 의 Delete 를 보내지 못해도 쥔 묶음은 놓는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .type_text, "{\"selector\":\"#e\",\"text\":\"\"}", 852);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &w9b3r4DeleteNotSent, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.failed, r.status);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
}

test "W9b③ 적대 리뷰 4 회차: 로케이터로 누른 뒤 대화상자가 뜨면 matched 와 dialog 를 함께 싣는다" {
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .click, "{\"locator\":{\"role\":\"button\",\"name\":\"Save\",\"exact\":true}}", 853);
    defer op.deinit(testing.allocator);
    const r = try drive(&op, &w9b3r4RoleDialog, &trail);
    defer testing.allocator.free(r.result);
    try testing.expectEqual(Status.success, r.status);
    try testing.expect(std.mem.indexOf(u8, r.result, "\"matched\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.result, "\"dialog\":true") != null);
}

fn w9b3r4RoleDialog(method: []const u8, params: []const u8) Reply {
    if (std.mem.indexOf(u8, params, "mousePressed") != null) return .{ .failed = dialog_reason };
    if (std.mem.eql(u8, method, "Runtime.releaseObjectGroup")) return .{ .not_sent = dialog_reason };
    return rolePage(method, params);
}

test "W9c②: 대화상자로 막힌 실패의 글은 maru browser handle-dialog 를 가리킨다 — 답해도 되면 에이전트가, 아니면 사용자가(표지 상수는 그대로 비교된다)" {
    for ([_][]const u8{ dialog_reason, family_dialog_reason, web_cdp_page.leave_page_reason, web_cdp_exec.paused_at_dialog }) |r| {
        try testing.expect(std.mem.indexOf(u8, r, "maru browser handle-dialog") != null);
        try testing.expect(std.mem.indexOf(u8, r, "otherwise the user") != null);
    }
}

// ── W9c③: 업로드(browser.upload) — 로케이터 → 모달 전 확인 → 멈춤(모달) → 승인 뒤 다시 찾기 → 같은 문서·같은 요소 → 넣기 → 같은 objectId 로 읽기 ──
// 이 시험들은 DevTools 의 답을 흉내 내 차례만 본다(실제 CEF 의 성질 — objectId 가 문서와 함께 죽는다·조용한 실패 — 은 계획의 실측과 스모크
// `w9c-upload` 가 본다). 모달·사본은 앱(app_host_abi)의 시험이 본다.

/// 흉내 페이지의 상태 — 승인 뒤 다른 문서(loaderId)·다른 요소(backendNodeId)·넣기 오류·읽기 결과를 고른다.
const UpPage = struct {
    var post: bool = false;
    var loader_post: []const u8 = "L1";
    /// 승인 뒤 두 번째 프레임 트리(확인과 넣기 사이)의 loaderId.
    var loader_again: []const u8 = "L1";
    var backend_post: i64 = 9;
    var check: []const u8 = "ok";
    var set_error: ?[]const u8 = null;
    var verify: []const u8 = "ok";
    /// 2 회차: 읽기(verify)·넣기의 답을 통째로 바꾼다(넣은 뒤 페이지가 옮겨 가 context 가 죽었다·시한 등).
    var verify_reply: ?Reply = null;
    var set_reply: ?Reply = null;
    var trees: usize = 0;
    /// 이 메서드를 한 번 「자리 없음」 으로 못 보낸 것으로 답한다(적대 리뷰 1 회차 R10).
    var busy_once: ?[]const u8 = null;

    fn reset() void {
        busy_once = null;
        post = false;
        loader_post = "L1";
        loader_again = "L1";
        backend_post = 9;
        check = "ok";
        set_error = null;
        verify = "ok";
        verify_reply = null;
        set_reply = null;
        trees = 0;
    }

    fn answer(method: []const u8, params: []const u8) Reply {
        if (busy_once) |m| if (std.mem.eql(u8, m, method)) {
            busy_once = null;
            return .{ .not_sent = busy_reason };
        };
        if (std.mem.eql(u8, method, "DOM.describeNode")) return .{ .ok = if (post and backend_post != 9) "{\"node\":{\"backendNodeId\":11}}" else "{\"node\":{\"backendNodeId\":9}}" };
        if (std.mem.eql(u8, method, "Page.getFrameTree")) {
            if (post) trees += 1;
            const loader = if (!post) "L1" else if (trees == 1) loader_post else loader_again;
            return .{ .ok = if (std.mem.eql(u8, loader, "L1"))
                "{\"frameTree\":{\"frame\":{\"id\":\"F1\",\"loaderId\":\"L1\",\"securityOrigin\":\"https://a.test\"}}}"
            else
                "{\"frameTree\":{\"frame\":{\"id\":\"F1\",\"loaderId\":\"L2\",\"securityOrigin\":\"https://b.test\"}}}" };
        }
        if (std.mem.eql(u8, method, "DOM.setFileInputFiles")) {
            if (set_reply) |r| return r;
            if (set_error) |e| return .{ .cdp_error = e };
            return .{ .ok = "{}" };
        }
        if (std.mem.eql(u8, method, "Runtime.callFunctionOn")) {
            if (std.mem.indexOf(u8, params, "function(names") != null) {
                if (verify_reply) |r| return r;
                inline for (.{ "ok", "removed", "mismatch", "dropped", "unseen" }) |v|
                    if (std.mem.eql(u8, verify, v)) return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"" ++ v ++ "\"}}" };
                return .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"mismatch\"}}" };
            }
            return .{ .ok = if (std.mem.eql(u8, check, "ok")) "{\"result\":{\"type\":\"string\",\"value\":\"ok\"}}" else if (std.mem.eql(u8, check, "disabled")) "{\"result\":{\"type\":\"string\",\"value\":\"disabled\"}}" else if (std.mem.eql(u8, check, "directory")) "{\"result\":{\"type\":\"string\",\"value\":\"directory\"}}" else if (std.mem.eql(u8, check, "single")) "{\"result\":{\"type\":\"string\",\"value\":\"single\"}}" else if (std.mem.eql(u8, check, "frame")) "{\"result\":{\"type\":\"string\",\"value\":\"frame\"}}" else "{\"result\":{\"type\":\"string\",\"value\":\"not file\"}}" };
        }
        return happyPage(method, params);
    }
};

/// 업로드 차례를 모달(`confirm`)이나 끝까지 돌린다. 끝나면 답 뒤의 정리 호출(떼기·놓기 — 앱이 요청과 묶지 않고 보낸다)도 `trail` 끝에 붙인다.
fn driveUpload(op: *Op, first: Step, trail: *Trail) !Step {
    var step = first;
    while (true) switch (step) {
        .call => |c| {
            try trail.methods.append(testing.allocator, c.method);
            try trail.params.append(testing.allocator, c.params);
            step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
        },
        .done => {
            try drainUploadCleanup(op, trail);
            return step;
        },
        .confirm => return step,
        .sleep => return error.TestUnexpectedResult,
    };
}

/// 끝난 업로드의 정리 호출을 `trail` 에 붙인다(그 수는 `trail.cleanup`). 정리 호출은 차례에 답을 먹이지 않는다(답은 버린다).
fn drainUploadCleanup(op: *Op, trail: *Trail) !void {
    while (try op.takeUploadCleanup(testing.allocator)) |c| {
        try trail.methods.append(testing.allocator, c.call.method);
        try trail.params.append(testing.allocator, c.call.params);
        trail.cleanup += 1;
    }
}

const up_staged = [_]web_cdp_upload.Staged{ .{ .path = "/stage/7/42/0/a.txt", .name = "a.txt", .size = 3 }, .{ .path = "/stage/7/42/1/b.txt", .name = "b.txt", .size = 5 } };

test "W9c③: 업로드 — 찾기 → 프레임 트리·격리 world·노드·확인 → 놓고 멈춤(출처만) → 승인 뒤 다시 찾아 같은 문서·요소 → 넣기 → 같은 objectId 로 읽기 → 놓기" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\",\"/b.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    defer testing.allocator.free(paused.confirm.origin);
    try testing.expectEqualStrings("https://a.test", paused.confirm.origin);
    const pre = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(pre.len, trail.methods.items.len);
    for (pre, trail.methods.items) |w, g| try testing.expectEqualStrings(w, g);
    // 확인 함수는 넣을 파일 수(2 — multiple 이어야 한다)를 받는다. 페이지를 움직이는 호출은 없다(스크롤·입력).
    try testing.expect(std.mem.indexOf(u8, trail.params.items[6], "\"arguments\":[{\"value\":2}]") != null);
    try testing.expect(!op.committed());
    trail.reset();
    UpPage.post = true;
    const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, &up_staged), &trail);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.success, end.done.status);
    try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3},{\"name\":\"b.txt\",\"size\":5}],\"kept\":true,\"navigated\":false,\"dialog\":false}", end.done.result);
    const post = [_][]const u8{ "DOM.getDocument", "DOM.querySelector", "DOM.describeNode", "Page.getFrameTree", "Page.createIsolatedWorld", "DOM.resolveNode", "Runtime.callFunctionOn", "Page.getFrameTree", "DOM.setFileInputFiles", "Runtime.callFunctionOn", "Runtime.releaseObjectGroup" };
    try testing.expectEqual(post.len, trail.methods.items.len);
    for (post, trail.methods.items) |w, g| try testing.expectEqualStrings(w, g);
    // 넣기는 사본의 경로를 objectId 로(backendNodeId 가 아니다 — 다른 문서에서 다시 쓰였다, 실측 g2).
    try testing.expectEqualStrings("{\"files\":[\"/stage/7/42/0/a.txt\",\"/stage/7/42/1/b.txt\"],\"objectId\":\"o-1\"}", trail.params.items[8]);
    // 읽기는 같은 objectId 로 이름·크기를.
    try testing.expect(std.mem.indexOf(u8, trail.params.items[9], "\"objectId\":\"o-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[9], "[\"a.txt\",\"b.txt\"]") != null);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[9], "[3,5]") != null);
    try testing.expect(op.upload.?.given);
}

test "W9c③: 승인 뒤 다른 문서(loaderId)·다른 요소(backendNodeId)·확인과 넣기 사이의 이동이면 넣지 않고 「page changed」 — 쥔 것은 놓는다" {
    const Case = struct { loader_post: []const u8 = "L1", loader_again: []const u8 = "L1", backend_post: i64 = 9, released: bool };
    for ([_]Case{
        .{ .loader_post = "L2", .released = false }, // 승인한 문서가 아니다 — 아무것도 쥐기 전
        .{ .backend_post = 11, .released = false }, // 로케이터가 다른 요소를 찾았다(노드를 바꿔 끼웠다 — loaderId 는 그대로, 실측 f)
        .{ .loader_again = "L2", .released = true }, // 확인 뒤 넣기 전에 옮겼다 — 잡은 objectId 를 놓는다
    }) |c| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        trail.reset();
        UpPage.post = true;
        UpPage.loader_post = c.loader_post;
        UpPage.loader_again = c.loader_again;
        UpPage.backend_post = c.backend_post;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(Status.failed, end.done.status);
        try testing.expectEqualStrings(web_cdp_upload.page_changed_reason, end.done.result);
        try testing.expectEqual(@as(usize, 0), trail.count("DOM.setFileInputFiles"));
        try testing.expectEqual(@as(usize, if (c.released) 1 else 0), trail.count("Runtime.releaseObjectGroup"));
        try testing.expect(!op.upload.?.given); // 사본은 페이지에 가지 않았다 — 앱이 곧 지운다
    }
}

test "W9c③: 넣기가 「Cannot find context」(문서가 바뀌었다)면 page changed, 읽기가 떨어진 노드·다른 목록이면 그 이유 — 모두 놓는다" {
    const Case = struct { set_error: ?[]const u8 = null, verify: []const u8 = "ok", want: []const u8, given: bool };
    for ([_]Case{
        .{ .set_error = "{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}", .want = web_cdp_upload.page_changed_reason, .given = false },
        .{ .verify = "removed", .want = web_cdp_upload.removed_after_reason, .given = true },
        .{ .verify = "mismatch", .want = web_cdp_upload.mismatch_reason, .given = true },
    }) |c| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        // ref 는 찾기를 건너뛴다 — 곧 프레임 트리부터.
        try testing.expectEqualStrings("Page.getFrameTree", trail.methods.items[0]);
        trail.reset();
        UpPage.post = true;
        UpPage.set_error = c.set_error;
        UpPage.verify = c.verify;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(Status.failed, end.done.status);
        try testing.expectEqualStrings(c.want, end.done.result);
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
        try testing.expectEqual(c.given, op.upload.?.given);
    }
}

test "W9c③: 꺼진 칸·폴더 칸·한 파일 칸에 여럿·파일 칸이 아님·다른 frame 은 모달 전에 거절(놓고 끝 — 멈추지 않는다), 없는 요소는 실패" {
    const Case = struct { check: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .check = "disabled", .want = web_cdp_upload.disabled_reason },
        .{ .check = "directory", .want = web_cdp_upload.directory_reason },
        .{ .check = "single", .want = web_cdp_upload.single_reason },
        .{ .check = "not file", .want = web_cdp_upload.not_file_input_reason },
        .{ .check = "frame", .want = web_cdp_upload.frame_reason },
    }) |c| {
        UpPage.reset();
        UpPage.check = c.check;
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\",\"/b.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const end = try driveUpload(&op, try op.start(testing.allocator), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(Status.failed, end.done.status);
        try testing.expectEqualStrings(c.want, end.done.result);
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    // 없는 요소 — click 은 {ok:false} 성공이지만 업로드는 넣을 곳이 없다: 실패.
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#none\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const end = try driveUpload(&op, try op.start(testing.allocator), &trail);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.failed, end.done.status);
    try testing.expectEqualStrings(web_cdp_upload.not_found_reason, end.done.result);
    // 모르는 ref 도.
    var op2 = try Op.init(testing.allocator, .upload, "{\"ref\":\"zz\",\"files\":[\"/a.txt\"]}", 42);
    defer op2.deinit(testing.allocator);
    const end2 = try op2.start(testing.allocator);
    defer testing.allocator.free(end2.done.result);
    try testing.expectEqualStrings(web_cdp_upload.not_found_reason, end2.done.result);
    // 파일 수가 틀린 인자(0 개·11 개·없음)는 시작하지 않는다(L2 가 막지만 엔진도).
    for ([_][]const u8{ "{\"selector\":\"#f\",\"files\":[]}", "{\"selector\":\"#f\"}", "{\"selector\":\"#f\",\"files\":[1,2,3,4,5,6,7,8,9,10,11]}" }) |bad|
        try testing.expectError(error.InvalidArg, Op.init(testing.allocator, .upload, bad, 1));
}

test "W9c③: 철회 — 확인·두 번째 프레임 트리·넣기 앞이면 놓고 「cancelled」(넣지 않는다), 넣은 뒤의 읽기·놓기는 committed, 넣기 앞에서만 에이전트 시각" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    var step = try op.resumeUpload(testing.allocator, up_staged[0..1]);
    // 넣기 직전까지 몬다.
    while (!op.uploadSetting()) {
        try testing.expect(!op.committed());
        const c = step.call;
        defer testing.allocator.free(c.params);
        step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
    }
    try testing.expectEqualStrings("DOM.setFileInputFiles", step.call.method);
    try testing.expect(!op.committed()); // 넣기 자체는 철회되면 보내지 않는다
    testing.allocator.free(step.call.params);
    // 곧 「cancelled」 로 끝내고(4 회차 L1 — 정리를 기다리지 않는다), 승인 뒤 확인이 단 듣는 이 떼기(적대 리뷰 2 회차)와 놓기는 답 뒤의 정리로 —
    // 떼기가 먼저.
    const end = (try op.cancel(testing.allocator)).?;
    defer testing.allocator.free(end.done.result);
    try testing.expectEqualStrings("the request was cancelled", end.done.result);
    try testing.expect(!op.upload.?.given);
    const disarm = (try op.takeUploadCleanup(testing.allocator)).?;
    try testing.expectEqualStrings("Runtime.callFunctionOn", disarm.call.method);
    try testing.expect(std.mem.indexOf(u8, disarm.call.params, "removeEventListener") != null);
    testing.allocator.free(disarm.call.params);
    const rel = (try op.takeUploadCleanup(testing.allocator)).?;
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", rel.call.method);
    testing.allocator.free(rel.call.params);
    try testing.expect(try op.takeUploadCleanup(testing.allocator) == null);
}

// ── W9c③ 적대 리뷰 1 회차 ──

/// 업로드 차례를 끝까지 — 「잠깐 뒤」(sleep)면 깨워 잇는다(잔 횟수를 센다).
fn driveUploadSleeping(op: *Op, first: Step, trail: *Trail, sleeps: *usize) !Step {
    var step = first;
    while (true) switch (step) {
        .call => |c| {
            try trail.methods.append(testing.allocator, c.method);
            try trail.params.append(testing.allocator, c.params);
            step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
        },
        .sleep => |ms| {
            try testing.expectEqual(kick_retry_ms, ms);
            sleeps.* += 1;
            step = try op.wake(testing.allocator);
        },
        .done => {
            try drainUploadCleanup(op, trail);
            return step;
        },
        .confirm => return step,
    };
}

test "W9c③ 적대 리뷰 1 회차 재현 R9: 페이지가 change 에서 칸을 비워도(받은 뒤 지운다) 넣을 때 본 목록이 맞으면 성공 — kept:false, 승인 뒤 확인은 maru 의 격리 world 에 듣는 이를 단다" {
    const Case = struct { verify: []const u8, status: Status, want: []const u8 };
    for ([_]Case{
        .{ .verify = "dropped", .status = .success, .want = "{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":false,\"dialog\":false}" },
        .{ .verify = "ok", .status = .success, .want = "{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":true,\"navigated\":false,\"dialog\":false}" },
        .{ .verify = "unseen", .status = .failed, .want = web_cdp_upload.unseen_reason },
    }) |c| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        // 모달 전 확인은 듣는 이를 달지 않는다(페이지에 아무것도 넣지 않는다).
        try testing.expect(std.mem.indexOf(u8, trail.params.items[3], "\"arguments\":[{\"value\":1}]") != null);
        trail.reset();
        UpPage.post = true;
        UpPage.verify = c.verify;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(c.status, end.done.status);
        try testing.expectEqualStrings(c.want, end.done.result);
        // 승인 뒤 확인(넣기 앞)은 듣는 이를 단다 — 두 번째 인자 true.
        var armed = false;
        for (trail.methods.items, trail.params.items) |m, prm| if (std.mem.eql(u8, m, "Runtime.callFunctionOn") and std.mem.indexOf(u8, prm, "\"arguments\":[{\"value\":1},{\"value\":true},") != null) {
            armed = true;
        };
        try testing.expect(armed);
    }
}

test "W9c③ 적대 리뷰 1 회차 재현 R10: 승인 뒤 DevTools 자리가 다 차 못 보낸 호출(다시 찾기·넣기)은 잠깐 뒤 그대로 다시 보낸다 — 「retry shortly」 로 승인을 버리지 않는다" {
    for ([_][]const u8{ "DOM.getDocument", "DOM.setFileInputFiles", "Page.createIsolatedWorld" }) |busy_method| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        trail.reset();
        UpPage.post = true;
        UpPage.busy_once = busy_method;
        var sleeps: usize = 0;
        const end = try driveUploadSleeping(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail, &sleeps);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(Status.success, end.done.status);
        try testing.expectEqual(@as(usize, 1), sleeps);
        try testing.expectEqual(@as(usize, 2), trail.count(busy_method)); // 못 보낸 것과 다시 보낸 것
        // 넣기는 한 번만 갔다(못 보낸 것은 가지 않았다) — 사본이 두 번 들어가지 않는다.
        try testing.expect(op.upload.?.given);
    }
}

// ── W9c③ 적대 리뷰 2 회차 ──
// 실제 CEF 154 실측(판정자 탐침 v2·v3, 3/3 씩): change 처리기가 `location.href=` 로 옮기는 칸에 `DOM.setFileInputFiles` → `{}`(그 처리기가 파일을
// 받고 돌았다) → 곧 보낸 읽기(`Runtime.callFunctionOn`, 같은 objectId)는 Chromium 이 확정까지 붙잡았다가 「Cannot find context with specified id」.
// 앱이 이동을 먼저 보았으면 읽기를 보내지 않고 `uncommittedReply` 의 「…then try again」. 고치기 전에는 둘 다 실패였다 — 에이전트는 「실패」 를
// 보고 다시 불러 모달이 또 뜨고 두 번 올라갔다(1 회차 MED-2 와 같은 갈래). 넣기가 `{}` 로 끝난 뒤의 「문서가 사라졌다」 는 성공에
// `kept:false`·`navigated:true` 다 — 다시 올리라고 하지 않는다. 듣는 이는 문서와 함께 사라졌다(떼는 호출을 보내지 않는다).
test "W9c③ 적대 리뷰 2 회차 재현 V1: 넣은 뒤 페이지가 곧 옮겨 가 읽기가 「Cannot find context」·「loading a new page」 면 성공에 kept:false·navigated:true — 다시 올리라고 하지 않는다" {
    const cases = [_]Reply{
        .{ .cdp_error = "{\"code\":-32000,\"message\":\"Cannot find context with specified id\"}" },
        .{ .cdp_error = "{\"code\":-32000,\"message\":\"Could not find object with given id\"}" },
        // 앱이 확정되지 않은 이동 중의 호출을 대신 답하는 글(app_host_abi.uncommittedReply — web_cdp_ops.loading_reason): 「then try again」.
        .{ .not_sent = loading_reason },
    };
    for (cases) |reply| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        trail.reset();
        UpPage.post = true;
        UpPage.verify_reply = reply;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(@as(usize, 1), trail.count("DOM.setFileInputFiles"));
        try testing.expect(op.upload.?.given); // 사본은 페이지에 갔다
        try testing.expect(std.mem.indexOf(u8, end.done.result, "Cannot find context") == null);
        try testing.expect(std.mem.indexOf(u8, end.done.result, "try again") == null);
        try testing.expectEqual(Status.success, end.done.status);
        try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":true,\"dialog\":false}", end.done.result);
        // 승인 뒤 callFunctionOn 은 확인·읽기 둘뿐(떼는 호출 없음), 그리고 놓기.
        try testing.expectEqual(@as(usize, 2), trail.count("Runtime.callFunctionOn"));
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
    // 넣기 앞(확인과 넣기 사이)의 「loading」 은 그대로 실패다 — 넣지 않았다(given 거짓).
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    UpPage.set_reply = .{ .not_sent = loading_reason };
    const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.failed, end.done.status);
    try testing.expect(!op.upload.?.given);
}

// 승인 뒤 확인이 그 칸에 단 듣는 이(격리 world)는 읽기만 뗐다 — 철회·넣기 오류·읽기를 못 보낸 끝에서는 문서가 죽을 때까지 남았다(nit-E).
// 떼는 호출은 놓기 앞에 한 번, best effort. 페이지가 답하지 않는 끝(시한)·탭이 사라진 끝·문서가 바뀐 끝은 보내지 않는다.
test "W9c③ 적대 리뷰 2 회차 재현 E1: 읽기를 못 한 끝(넣기 오류·읽기를 못 보냄)은 놓기 앞에서 듣는 이를 뗀다 — 시한·다른 문서·넣기 전 확인 실패는 떼지 않는다" {
    const Case = struct { set_reply: ?Reply = null, verify_reply: ?Reply = null, loader_again: []const u8 = "L1", check: []const u8 = "ok", disarm: bool, status: Status, release: bool = true };
    for ([_]Case{
        .{ .set_reply = .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" }, .disarm = true, .status = .failed },
        .{ .verify_reply = .{ .not_sent = dialog_reason }, .disarm = true, .status = .success }, // 3 회차 D1: 넣기는 갔다 — 성공에 dialog:true
        .{ .verify_reply = .{ .cdp_error = "{\"code\":-32000,\"message\":\"boom\"}" }, .disarm = true, .status = .failed },
        .{ .set_reply = .{ .timed_out = "DevTools did not answer in time" }, .disarm = false, .status = .success, .release = false }, // 4 회차 L1: 보낸 넣기의 시한 — 「넣었다」(navigated), 붙잡힐 정리는 없다
        .{ .set_reply = .{ .failed = "the tab closed or its page crashed" }, .disarm = false, .status = .failed },
        .{ .loader_again = "L2", .disarm = false, .status = .failed },
        .{ .check = "disabled", .disarm = false, .status = .failed },
        .{ .disarm = false, .status = .success },
    }) |c| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        trail.reset();
        UpPage.post = true;
        UpPage.set_reply = c.set_reply;
        UpPage.verify_reply = c.verify_reply;
        UpPage.loader_again = c.loader_again;
        UpPage.check = c.check;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(c.status, end.done.status);
        var disarms: usize = 0;
        for (trail.methods.items, trail.params.items) |m, prm| if (std.mem.eql(u8, m, "Runtime.callFunctionOn") and std.mem.indexOf(u8, prm, "function(key)") != null) {
            disarms += 1;
            try testing.expect(std.mem.indexOf(u8, prm, "\"objectId\":\"o-1\"") != null);
            try testing.expect(std.mem.indexOf(u8, prm, "\"value\":\"maru-w9c-upload-42\"") != null);
        };
        try testing.expectEqual(@as(usize, if (c.disarm) 1 else 0), disarms);
        // 떼기 뒤에 놓는다 — 놓기가 마지막. 둘 다 답 뒤의 정리다(4 회차 L1).
        if (c.release) {
            try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
            try testing.expectEqual(@as(usize, if (c.disarm) 2 else 1), trail.cleanup);
        } else try testing.expectEqual(@as(usize, 0), trail.count("Runtime.releaseObjectGroup"));
    }
}

// ── W9c③ 적대 리뷰 3 회차 ──
// 실측(CEF 154 판정자 탐침 review_w9c3_r3/probe d_a·d_c·d_p·d_ac·bu·dt2, 3/3 씩): change 처리기가 alert·confirm·prompt 를 띄우거나(같은 차례) 떠나기
// 확인이 뜨면 `DOM.setFileInputFiles` 의 답은 대화상자가 답해질 때까지 붙잡힌다 — 처리기는 그 전에 파일을 받았다(`got 1`). 앱은 대화상자가 오는
// 순간 그 탭의 호출을 `.failed = dialog_reason` 으로 끝낸다(web_osr `failDevtools(.dialog)`). 고치기 전에는 업로드가 「실패」 로 답했고, 에이전트는
// 대화상자에 답한 뒤 다시 올렸다(모달이 또 뜨고 두 번 올라간다 — 2 회차 MED-A 와 같은 갈래). change 처리기가 `setTimeout(alert)` 이면 넣기의 답(`{}`)
// 뒤 곧 보낸 읽기가 붙잡혀 같은 실패였다(dt2). 넣기를 보낸 뒤의 대화상자는 성공에 `dialog:true` — 듣는 이 떼기는 대화상자가 사라진 뒤로 미룬다.
// 이미 떠 있어 넣기를 **보내지 못한** 것은 그대로 실패다(W9b③ 4 회차의 교훈 — 보내지 않은 것을 「갔다」 고 하지 않는다).
test "W9c③ 적대 리뷰 3 회차 재현 D1: 넣기·읽기가 대화상자로 끝나거나 대화상자로 읽기를 못 보내면(페이지는 파일을 받았다) 성공에 kept:false·dialog:true — 넣기를 못 보낸 것은 실패" {
    const Case = struct { set_reply: ?Reply = null, verify_reply: ?Reply = null, status: Status, given: bool };
    for ([_]Case{
        .{ .set_reply = .{ .failed = dialog_reason }, .status = .success, .given = true }, // change 처리기의 alert — 넣기의 답이 붙잡혔다
        .{ .verify_reply = .{ .failed = dialog_reason }, .status = .success, .given = true }, // change 처리기의 setTimeout(alert) — 읽기가 붙잡혔다
        .{ .verify_reply = .{ .not_sent = dialog_reason }, .status = .success, .given = true }, // 넣기 뒤 대화상자가 먼저 와 읽기를 못 보냈다
        .{ .set_reply = .{ .not_sent = dialog_reason }, .status = .failed, .given = false }, // 이미 떠 있어 넣기를 보내지 못했다 — 아무것도 안 갔다
    }) |c| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
        defer op.deinit(testing.allocator);
        const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
        testing.allocator.free(paused.confirm.origin);
        trail.reset();
        UpPage.post = true;
        UpPage.set_reply = c.set_reply;
        UpPage.verify_reply = c.verify_reply;
        const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
        defer testing.allocator.free(end.done.result);
        try testing.expectEqual(c.given, op.upload.?.given); // 갔으면 사본은 앱이 남긴다
        if (end.done.status != c.status) std.debug.print("D1: upload answered {s}: {s}\n", .{ @tagName(end.done.status), end.done.result });
        try testing.expectEqual(c.status, end.done.status);
        if (c.status == .success)
            try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":false,\"dialog\":true}", end.done.result)
        else
            try testing.expectEqualStrings(dialog_reason, end.done.result);
        // 듣는 이는 뗀다 — 떼기와 놓기는 답 뒤의 정리다(4 회차 L1 — web_osr 의 미룬 줄이 대화상자가 사라진 뒤 떼기부터 보낸다). 놓기가 마지막.
        try testing.expectEqual(@as(usize, 2), trail.cleanup);
        var disarms: usize = 0;
        for (trail.methods.items, trail.params.items) |m, prm| if (std.mem.eql(u8, m, "Runtime.callFunctionOn") and std.mem.indexOf(u8, prm, "function(key)") != null) {
            disarms += 1;
        };
        try testing.expectEqual(@as(usize, 1), disarms);
        try testing.expectEqualStrings("Runtime.releaseObjectGroup", trail.methods.items[trail.methods.items.len - 1]);
    }
}

// 실측(slow_sl): change 처리기가 응답이 40 초 걸리는 주소로 옮기면 넣기는 `{}`, 곧 보낸 읽기는 확정까지 붙잡혀 35 초에 host 가 버렸다(expired) — 앱에서는
// 그 전에 요청 시한(승인 뒤 30 초 — `uploadResume`)이나 DevTools 시한(30 초)이 먼저 와 맨 `timeout` 이었다(given 참 — 받았는데 실패, 2 회차가 남긴 틈).
// 업로드 차례 몫: 넣기가 `{}` 로 끝난 뒤 읽기가 시한이면 성공에 kept:false·navigated:true — 놓기는 보내지 않는다(그것도 붙잡혀 요청 시한을 넘긴다).
// 읽기의 시한을 줄이고 요청 시한을 그 뒤로 두는 앱 몫은 app_host_abi 의 시험이 본다.
test "W9c③ 적대 리뷰 3 회차 재현 T1: 넣기가 끝난 뒤 읽기가 시한이면 성공에 kept:false·navigated:true — 맨 timeout(다시 하라는 뜻)이 아니고, 붙잡힐 놓기를 보내지 않는다" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    trail.reset();
    UpPage.post = true;
    UpPage.verify_reply = .{ .timed_out = "DevTools did not answer in time" };
    const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
    defer testing.allocator.free(end.done.result);
    try testing.expect(op.upload.?.given);
    if (end.done.status != .success) std.debug.print("T1: upload answered {s}: {s}\n", .{ @tagName(end.done.status), end.done.result });
    try testing.expectEqual(Status.success, end.done.status);
    try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":true,\"dialog\":false}", end.done.result);
    // 읽기가 마지막 호출이다 — 답하지 않는 페이지에 떼기·놓기를 더 보내지 않는다.
    try testing.expectEqualStrings("Runtime.callFunctionOn", trail.methods.items[trail.methods.items.len - 1]);
    try testing.expect(std.mem.indexOf(u8, trail.params.items[trail.params.items.len - 1], "function(names") != null);
}

test "W9c③ 적대 리뷰 3 회차: uploadVerifying 은 넣은 뒤 읽기를 보내기 직전에만 참이다(앱이 그 호출의 시한을 줄인다)" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    var step = try op.resumeUpload(testing.allocator, up_staged[0..1]);
    var verifying: usize = 0;
    while (step == .call) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        const is_verify = std.mem.eql(u8, c.method, "Runtime.callFunctionOn") and std.mem.indexOf(u8, c.params, "function(names") != null;
        try testing.expectEqual(is_verify, op.uploadVerifying());
        if (is_verify) verifying += 1;
        step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
    }
    defer testing.allocator.free(step.done.result);
    try testing.expectEqual(@as(usize, 1), verifying);
    try testing.expectEqual(Status.success, step.done.status);
}

// ── W9c③ 적대 리뷰 4 회차 ──
// 실측(CEF 154 판정자 탐침 review_w9c3_r4/probe bb·busyset): 놓기(`Runtime.releaseObjectGroup`)도 페이지의 주 스레드에서 돈다 — 읽기가 「ok」 로 답한
// 뒤 페이지가 바쁘면 놓기가 15 초 넘게 붙잡혔고, 요청이 그 답을 기다리는 동안 요청 시한이 와 정해진 성공 대신 맨 -32004 였다. change 처리기가 30 초 넘게
// 동기로 돌면 넣기 자체가 붙잡혔다(처리기는 파일을 받았다). 차례 몫: 답이 정해지면 곧 `done`(정리는 `takeUploadCleanup` 으로 답 뒤에), 보낸 넣기의
// 시한은 「넣었다」, 요청 시한의 답(`uploadLateSuccess`)은 넣기를 실제로 보낸 뒤에만. 앱 몫(미룬 줄·요청 시한)은 app_host_abi 의 L1·L1b 가 본다.
test "W9c③ 적대 리뷰 4 회차 L1: 읽기가 ok 면 곧 성공(놓기는 답 뒤의 정리) · 보낸 넣기의 시한은 navigated · 요청 시한의 답은 넣기를 보낸 뒤에만" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 42);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    try testing.expect(try op.uploadLateSuccess(testing.allocator) == null); // 모달 전 — 아무것도 넣지 않았다
    UpPage.post = true;
    var step = try op.resumeUpload(testing.allocator, up_staged[0..1]);
    while (!op.uploadSetting()) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
    }
    // 넣기를 보내기 전(자리 없음으로 잠들었을 수 있다) — 요청 시한은 맨 시한이다.
    try testing.expect(try op.uploadLateSuccess(testing.allocator) == null);
    op.uploadSent(); // 앱이 넣기를 보냈다
    {
        const late = (try op.uploadLateSuccess(testing.allocator)).?;
        defer testing.allocator.free(late);
        try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":true,\"dialog\":false}", late);
    }
    // 넣기 `{}` → 읽기 → 「ok」: 곧 성공이다 — 그 사이 놓기 호출이 없다(정리로 넘긴다).
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .ok = "{}" });
    try testing.expect(op.uploadVerifying());
    testing.allocator.free(step.call.params);
    const end = try op.feed(testing.allocator, .{ .ok = "{\"result\":{\"type\":\"string\",\"value\":\"ok\"}}" });
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.success, end.done.status);
    try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":true,\"navigated\":false,\"dialog\":false}", end.done.result);
    // 정리는 놓기 하나(읽기가 듣는 이를 뗐다), 한 번만.
    const rel = (try op.takeUploadCleanup(testing.allocator)).?;
    defer testing.allocator.free(rel.call.params);
    try testing.expectEqualStrings("Runtime.releaseObjectGroup", rel.call.method);
    try testing.expectEqualStrings("{\"objectGroup\":\"maru-w9b-42\"}", rel.call.params);
    try testing.expect(try op.takeUploadCleanup(testing.allocator) == null);

    // 보낸 넣기 자체가 시한 — 「넣었다」(navigated), 사본은 남기고(given) 붙잡힐 정리는 없다.
    UpPage.reset();
    trail.reset();
    var op2 = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 43);
    defer op2.deinit(testing.allocator);
    const paused2 = try driveUpload(&op2, try op2.start(testing.allocator), &trail);
    testing.allocator.free(paused2.confirm.origin);
    trail.reset();
    UpPage.post = true;
    UpPage.set_reply = .{ .timed_out = "DevTools did not answer in time" };
    const end2 = try driveUpload(&op2, try op2.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
    defer testing.allocator.free(end2.done.result);
    try testing.expectEqual(Status.success, end2.done.status);
    try testing.expectEqualStrings("{\"origin\":\"https://a.test\",\"files\":[{\"name\":\"a.txt\",\"size\":3}],\"kept\":false,\"navigated\":true,\"dialog\":false}", end2.done.result);
    try testing.expect(op2.upload.?.given);
    try testing.expectEqual(@as(usize, 0), trail.cleanup);
    try testing.expectEqualStrings("DOM.setFileInputFiles", trail.methods.items[trail.methods.items.len - 1]);
}

// ── W9c③ 적대 리뷰 5 회차 ──
// `set_sent` 는 앱이 넣기를 sidecar 로 보낸 직후 켜고 다시 끄지 않는다. sidecar 가 그 호출을 `busy` 로 돌려주면(`cdpReply` — `.busy` 는 「확실히 보내지
// 않았다」 의 `busy_reason`) 업로드는 잠깐 뒤 그대로 다시 보내는데(1 회차 LOW-7), 그 사이(최대 45×100 ms) 요청 시한이 오면 `uploadLateSuccess` 가
// 「넣었다」(navigated:true)로 답한다 — 넣기는 페이지에 간 적이 없다. 다시 보내기도 끝내 자리가 없으면 op 은 `given` 거짓으로 실패해 사본까지 지운다.
// (sidecar 와 앱의 자리 상한이 같고 앱이 버린 자리를 더 오래 세므로 보통은 오지 않는 답이다 — nit.)
test "W9c③ 적대 리뷰 5 회차 재현 S1: sidecar 가 보낸 넣기를 busy 로 돌려주면(확실히 안 갔다) 요청 시한의 답은 「넣었다」 가 아니어야 한다" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 44);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    var step = try op.resumeUpload(testing.allocator, up_staged[0..1]);
    while (!op.uploadSetting()) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
    }
    op.uploadSent(); // 앱이 넣기를 sidecar 로 보냈다
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .not_sent = busy_reason }); // sidecar 가 busy 로 돌려줬다 — 넣기는 가지 않았다
    try testing.expect(step == .sleep);
    const late = try op.uploadLateSuccess(testing.allocator);
    defer if (late) |l| testing.allocator.free(l);
    // 다시 보내도 끝내 자리가 없다(앱 쪽 Busy — 앱은 `uploadSent` 를 부르지 않는다) — 실패하고 사본은 「안 갔다」 로 지워진다.
    var rounds: usize = 0;
    while (step == .sleep and rounds < 100) : (rounds += 1) {
        const again = try op.wake(testing.allocator);
        testing.allocator.free(again.call.params);
        step = try op.feed(testing.allocator, .{ .not_sent = busy_reason });
    }
    defer if (step == .done) testing.allocator.free(step.done.result);
    try testing.expect(step == .done and step.done.status == .failed);
    try testing.expect(!op.upload.?.given);
    if (late) |l| {
        std.debug.print("S1: the set was refused by the sidecar (busy) and then never sent, but a request deadline in between would answer {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
}

test "W9c③ 적대 리뷰 5 회차 S1: busy 로 돌아온 넣기를 다시 보내면(앱이 다시 적는다) 그 뒤의 요청 시한은 다시 「넣었다」 다" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"ref\":\"n9\",\"files\":[\"/a.txt\"]}", 45);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    var step = try op.resumeUpload(testing.allocator, up_staged[0..1]);
    while (!op.uploadSetting()) {
        const c = step.call;
        defer testing.allocator.free(c.params);
        step = try op.feed(testing.allocator, UpPage.answer(c.method, c.params));
    }
    op.uploadSent();
    testing.allocator.free(step.call.params);
    step = try op.feed(testing.allocator, .{ .not_sent = busy_reason });
    try testing.expect(step == .sleep);
    try testing.expect((try op.uploadLateSuccess(testing.allocator)) == null);
    // 잠깐 뒤 같은 넣기를 다시 — 이번에는 나갔다.
    const again = try op.wake(testing.allocator);
    defer testing.allocator.free(again.call.params);
    try testing.expectEqualStrings("DOM.setFileInputFiles", again.call.method);
    try testing.expect(op.uploadSetting());
    op.uploadSent();
    const late = (try op.uploadLateSuccess(testing.allocator)) orelse return error.TestExpectedLateSuccess;
    defer testing.allocator.free(late);
    try testing.expect(std.mem.indexOf(u8, late, "\"navigated\":true") != null);
}

// ── W9c③ 적대 리뷰 5 회차 변이(전 기능) — 살아남은 변이를 잡는 시험 ──
// OPworld: 시험 페이지는 `DOM.resolveNode` 의 인자를 보지 않아, 칸의 objectId 를 주 world(context 0 — 페이지가 그 칸의 getter·듣는 이를 고칠 수
// 있는 곳)에서 잡는 변이가 살아남았다.
test "W9c③ 적대 리뷰 5 회차 변이 OPworld: 칸의 objectId 는 maru 의 격리 world 에서 잡는다 — 모달 전·승인 뒤의 DOM.resolveNode 가 createIsolatedWorld 가 준 context 를 싣는다" {
    UpPage.reset();
    var trail: Trail = .{};
    defer trail.deinit();
    var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\"]}", 47);
    defer op.deinit(testing.allocator);
    const paused = try driveUpload(&op, try op.start(testing.allocator), &trail);
    testing.allocator.free(paused.confirm.origin);
    UpPage.post = true;
    const end = try driveUpload(&op, try op.resumeUpload(testing.allocator, up_staged[0..1]), &trail);
    defer testing.allocator.free(end.done.result);
    try testing.expectEqual(Status.success, end.done.status);
    var resolves: usize = 0;
    for (trail.methods.items, trail.params.items) |m, prm| if (std.mem.eql(u8, m, "DOM.resolveNode")) {
        resolves += 1;
        try testing.expect(std.mem.indexOf(u8, prm, "\"executionContextId\":7") != null); // happyPage 의 createIsolatedWorld 가 준 번호
    };
    try testing.expectEqual(@as(usize, 2), resolves);
}

// OPbusypre: 승인 뒤의 「자리 없음」 은 잠깐 뒤 다시 보내지만(1 회차 R10) 모달 전은 그대로 실패다(아직 아무도 승인하지 않았다 — 에이전트가 다시
// 부르면 된다). 그 갈림을 보는 시험이 없어 모달 전에도 다시 보내는 변이가 살아남았다.
test "W9c③ 적대 리뷰 5 회차 변이 OPbusypre: 모달 전에 자리가 없어 못 보낸 업로드 호출은 다시 보내지 않고 「retry shortly」 로 곧 끝낸다" {
    for ([_][]const u8{ "Page.createIsolatedWorld", "DOM.resolveNode" }) |busy_method| {
        UpPage.reset();
        var trail: Trail = .{};
        defer trail.deinit();
        var op = try Op.init(testing.allocator, .upload, "{\"selector\":\"#f\",\"files\":[\"/a.txt\"]}", 48);
        defer op.deinit(testing.allocator);
        UpPage.busy_once = busy_method;
        var sleeps: usize = 0;
        const end = try driveUploadSleeping(&op, try op.start(testing.allocator), &trail, &sleeps);
        defer if (end == .done) testing.allocator.free(end.done.result);
        try testing.expect(end == .done);
        try testing.expectEqual(@as(usize, 0), sleeps);
        try testing.expectEqual(Status.failed, end.done.status);
        try testing.expectEqualStrings(busy_reason, end.done.result);
        try testing.expectEqual(@as(usize, 1), trail.count(busy_method));
    }
}
