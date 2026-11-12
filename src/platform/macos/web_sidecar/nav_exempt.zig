//! 사람의 누름 예외 표(W9d④ Q2 — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」 §8). CEF 를 모른다 — 시각·번호·주소의 해시는 호출자가
//! 준다(CEF SDK 없이 기본 test 에서 돈다). 잠금은 `shared.lock`(IO 스레드의 처리기 고르기와 UI 스레드가 함께 쓴다 — 막기·가짜의 잠금과 함께
//! 쥐지 않는다).
//!
//! 처리기 고르기가 보는 예외는 둘이다(`Exempt`):
//!   - **사용자 이동(D2 — 막기·가짜 둘 다)**: 막기 표(`net_block_table` 의 토큰 — W9d③ 의 2–20 회 검증 고침이 모두 거기 있다: 몸짓의 갈래,
//!     거두기, 떠나기 확인의 멈춤, 시계 시작, speculation 번호 0)가 답한다. W9d④ 는 처음에 그 토큰을 이 파일로 떼어 냈지만(§13 P2-1 — 막기 규칙이
//!     없는 탭에서는 소비하지 않았다), main 위로 옮기며 토큰은 막기 표에 두고 소비만 규칙과 무관하게 했다(`net_block_table.consumeExempt` —
//!     「W9d④ main 위로 옮김」).
//!   - **사람의 누름(Q2 — 가짜만, 사용자 탭의 규칙만)**: 이 표. 사용자 결정 Q2(2026-10-21 「사용자 탭은 진짜로」) — 사람이 누른 링크·폼으로
//!     시작한 이동의 주 문서는 사용자 탭의 가짜 규칙이 바꾸지 않는다. sidecar 는 maru 가 보낸 사람 입력(마우스 누름·뗌·키·IME 확정 — 에이전트의
//!     DevTools 입력은 maru 를 지나지 않는다)의 시각을 탭마다 적고, 렌더러가 시작한 주 프레임 이동(`on_before_browse` 의 사용자 몸짓)이 그 뒤
//!     창 안이면 「사람」 으로 묶는다(사용자 이동 토큰이 그 이동을 이미 가져갔으면 묶지 않는다 — 사용자 이동이 이긴다). 가르지 못할 때는 사람
//!     쪽으로(진짜 문서 — 안전한 쪽).
//!
//! 시험이 증명하는 것: 사람 입력 창(몸짓이 있어야, 창 밖이면 아님, 사용자 이동이 이긴다), 첫 홉에서 번호를 예외로(리다이렉트 홉은 같은 번호로),
//! 번호 0(speculation)은 묶음을 쓰지 않는다, 하위 프레임·리다이렉트 홉은 묶지 않는다, 예외 아닌 새 이동은 남은 묶음을 지운다, 브라우저를 잊으면
//! 지운다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const msg = protocol.message;
const BrowserId = msg.BrowserId;

/// maru 가 보낸 사람 입력 중 **몸짓**·**그 탭을 쓴 것** — 규칙은 maru 와 함께 쓰는 `protocol.human_use` 하나다(W9e② 적대 검증 12 회차: maru 도
/// 보내는 순간 같은 가름으로 조건을 푼다). 몸짓은 그 뒤 창 안의 렌더러 이동을 사람의 것으로 묶는 데만 쓴다.
pub const gestureOf = protocol.human_use.gestureOf;
pub const humanUseOf = protocol.human_use.useOf;

/// 탭 자리 — sidecar 의 브라우저 상한과 같다.
pub const capacity = @import("registry.zig").capacity;
/// 묶인 주소의 시한 — 보통 수 ms 안에 쓰인다. 넉넉히 두되 남지 않게(막기 표의 `url_token_ms` 와 같다).
pub const bound_ms: i64 = 5_000;
/// 사람 입력 뒤 렌더러가 시작한 이동을 사람의 것으로 보는 창 — Chromium 의 일시 사용자 활성화(transient activation) 수명과 같다(5 초: 그
/// 안의 `setTimeout` 이동도 몸짓을 싣는다). 사람·에이전트를 가르지 못하면 사람 쪽(진짜 문서)이다.
pub const human_window_ms: i64 = 5_000;

/// 처리기 고르기가 보는 답 — `user` 는 막기·가짜 둘 다 지나가고(막기 표의 D2), `human` 은 사용자 탭의 가짜 규칙만 지나간다(이 표의 Q2).
pub const Exempt = struct {
    user: bool = false,
    human: bool = false,
};

pub const Tab = struct {
    used: bool = false,
    cef_id: c_int = 0,
    browser: BrowserId = 0,
    /// 마지막 사람 입력 + 창.
    human_until: i64 = 0,
    /// `on_before_browse` 가 「사람」 으로 묶은 이동 주소(정규 꼴 해시) — IO 의 고르기가 첫 홉에서 소비한다.
    bound_url: u64 = 0,
    bound_until: i64 = 0,
    /// 예외로 둔 요청 번호(그 이동의 모든 홉).
    exempt_request: u64 = 0,
};

pub const Table = struct {
    tabs: [capacity]Tab = @splat(.{}),

    fn find(self: *Table, cef_id: c_int) ?*Tab {
        for (&self.tabs) |*t| if (t.used and t.cef_id == cef_id) return t;
        return null;
    }

    fn ensure(self: *Table, browser: BrowserId, cef_id: c_int) ?*Tab {
        if (self.find(cef_id)) |t| {
            if (browser != 0) t.browser = browser;
            return t;
        }
        for (&self.tabs) |*t| if (!t.used) {
            t.* = .{ .used = true, .cef_id = cef_id, .browser = browser };
            return t;
        };
        return null;
    }

    /// maru 가 보낸 사람 입력(마우스 누름·뗌·키·IME 확정) — 창을 연다.
    pub fn humanInput(self: *Table, browser: BrowserId, cef_id: c_int, now_ms: i64) void {
        const t = self.ensure(browser, cef_id) orelse return;
        t.human_until = now_ms + human_window_ms;
    }

    /// `on_before_browse`(주 프레임만 — 하위 프레임은 부르지 않는다) — 사람의 이동이면 그 주소에 묶고 참. 리다이렉트 홉은 묶지 않는다(탭 길은 요청
    /// 번호로 이미 예외다). `user_gesture` — CEF 가 준 사용자 몸짓(렌더러가 시작한 이동의 링크 누름·폼 제출). `user` — 막기 표의 D2 토큰이 이
    /// 이동을 가져갔다(사용자 이동이 이긴다 — 사람으로 묶지 않는다). 예외 아닌 새 이동은 남은 묶음을 지운다(그 이동이 대신한다).
    pub fn beforeBrowse(self: *Table, browser: BrowserId, cef_id: c_int, is_redirect: bool, user_gesture: bool, user: bool, url_canon: u64, now_ms: i64) bool {
        if (is_redirect) return false;
        const t = self.ensure(browser, cef_id) orelse return false;
        const human = !user and user_gesture and now_ms < t.human_until;
        if (human) {
            t.bound_url = url_canon;
            t.bound_until = now_ms + bound_ms;
        } else t.bound_url = 0;
        return human;
    }

    /// IO 의 처리기 고르기(주 프레임 이동의 요청만): 이미 예외인 번호면 참, 묶인 주소의 첫 홉이면 번호를 예외로 두고 참. 번호 0(speculation)은
    /// 묶음을 쓰지도 예외를 받지도 않는다(막기 표의 20 회 검증 A N6 과 같다 — 미리 불러오기가 묶음을 먼저 가져가면 사람의 진짜 이동이 가짜가 된다).
    pub fn consume(self: *Table, cef_id: c_int, request: u64, url_canon: u64, now_ms: i64) bool {
        if (request == 0) return false;
        const t = self.find(cef_id) orelse return false;
        if (request == t.exempt_request) return true;
        if (t.bound_url != 0 and t.bound_url == url_canon and now_ms < t.bound_until) {
            t.exempt_request = request;
            t.bound_url = 0;
            return true;
        }
        return false;
    }

    /// 브라우저가 닫혔다.
    pub fn forget(self: *Table, cef_id: c_int) void {
        if (self.find(cef_id)) |t| t.* = .{};
    }
};

/// 프로세스에 하나 — 잠금과 표(blocking.zig 가 CEF 사건을 넘긴다).
pub const Shared = struct {
    lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    table: Table = .{},

    pub fn acquire(self: *Shared) *Table {
        _ = std.c.pthread_mutex_lock(&self.lock);
        return &self.table;
    }

    pub fn release(self: *Shared) void {
        _ = std.c.pthread_mutex_unlock(&self.lock);
    }
};

pub var shared: Shared = .{};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d④ Q2: 사람 입력 창 — 몸짓이 있는 렌더러 이동이 창 안이면 사람, 몸짓이 없거나 창 밖이면 아님, 사용자 이동 토큰이 이긴다, 리다이렉트 홉은 번호로" {
    var t: Table = .{};
    try testing.expect(!t.beforeBrowse(7, 70, false, true, false, 1, 100)); // 사람 입력이 없었다 — 에이전트의 DevTools 누름
    t.humanInput(7, 70, 1000);
    try testing.expect(!t.beforeBrowse(7, 70, false, false, false, 1, 1001)); // 몸짓 없는 이동(페이지가 스스로)
    try testing.expect(t.beforeBrowse(7, 70, false, true, false, 2, 1002));
    try testing.expect(t.consume(70, 40, 2, 1003));
    try testing.expect(t.consume(70, 40, 3, 1004)); // 같은 번호의 다음 홉
    try testing.expect(!t.beforeBrowse(7, 70, false, true, false, 4, 1000 + human_window_ms)); // 창 밖
    t.humanInput(7, 70, 9000);
    try testing.expect(!t.beforeBrowse(7, 70, false, true, true, 5, 9001)); // 사용자가 친 주소(막기 표의 토큰이 가져갔다) — 사람으로 묶지 않는다
    try testing.expect(!t.consume(70, 41, 5, 9002));
}

test "W9d④ 변이: 묶음의 시한, 소비한 묶음은 다음 요청에 다시 쓰지 않는다, 예외 아닌 이동은 남은 묶음을 지운다, 리다이렉트 홉은 묶지 않는다, 잊기" {
    var t: Table = .{};
    t.humanInput(7, 70, 1000);
    try testing.expect(t.beforeBrowse(7, 70, false, true, false, 9, 1001));
    try testing.expect(!t.consume(70, 3, 9, 1001 + bound_ms)); // 묶은 주소의 시한
    // 묶음은 첫 홉 하나 — 같은 주소의 다른 요청(번호가 다르다)은 예외가 아니다.
    t.humanInput(7, 70, 2000);
    _ = t.beforeBrowse(7, 70, false, true, false, 9, 2001);
    try testing.expect(t.consume(70, 55, 9, 2002));
    try testing.expect(!t.consume(70, 56, 9, 2003));
    try testing.expect(t.consume(70, 55, 10, 2004)); // 그 사이 다른 요청이 와도 첫 이동의 리다이렉트 홉은 그대로 예외
    // 사람 이동이 묶였지만 소비되지 않았다(취소) — 이어진 에이전트의 같은 주소 이동(몸짓 없음)은 그 묶음을 쓰지 않는다.
    t.humanInput(7, 70, 3000);
    try testing.expect(t.beforeBrowse(7, 70, false, true, false, 4, 3001));
    try testing.expect(!t.beforeBrowse(7, 70, false, false, false, 4, 3002));
    try testing.expect(!t.consume(70, 60, 4, 3003));
    // 리다이렉트 홉은 사람 창으로 묶지 않는다.
    t.humanInput(7, 70, 4000);
    try testing.expect(!t.beforeBrowse(7, 70, true, true, false, 6, 4001));
    // 번호 0(speculation)은 묶음을 쓰지 않는다 — 진짜 이동 요청이 쓴다.
    try testing.expect(t.beforeBrowse(7, 70, false, true, false, 6, 4002));
    try testing.expect(!t.consume(70, 0, 6, 4003));
    try testing.expect(t.consume(70, 61, 6, 4004));
    // 잊기.
    t.humanInput(7, 70, 5000);
    t.forget(70);
    try testing.expect(!t.beforeBrowse(7, 70, false, true, false, 7, 5001));
}

test "W9e② A3-1: 몸짓은 누름·뗌·키(뗌 제외)·IME 확정만, 탭을 쓴 것은 굴림·IME 조합·끝내기·편집 명령·놓음까지 — 옮김·떠남·끌기 들어옴/위/나감·키 뗌은 아니다" {
    const p: msg.Point = .{ .x = 1, .y = 1 };
    const both = [_]msg.Message{
        .{ .mouse = .{ .browser = 3, .kind = .down, .point = p } },
        .{ .mouse = .{ .browser = 3, .kind = .up, .point = p } },
        .{ .key = .{ .browser = 3, .kind = .raw_down } },
        .{ .key = .{ .browser = 3, .kind = .char, .character = 'a' } },
        .{ .ime_commit_text = .{ .browser = 3, .text = "한" } },
    };
    for (both) |m| {
        try std.testing.expectEqual(@as(?BrowserId, 3), gestureOf(m));
        try std.testing.expectEqual(@as(?BrowserId, 3), humanUseOf(m));
    }
    const use_only = [_]msg.Message{
        .{ .wheel = .{ .browser = 4, .point = p, .delta_x = 0, .delta_y = -120 } },
        .{ .ime_set_composition = .{ .browser = 4, .text = "한" } },
        .{ .ime_finish_composing = .{ .browser = 4, .value = true } },
        .{ .edit_command = .{ .browser = 4, .command = .paste } },
        .{ .drag_target = .{ .browser = 4, .kind = .drop, .point = p } },
    };
    for (use_only) |m| {
        try std.testing.expectEqual(@as(?BrowserId, null), gestureOf(m));
        try std.testing.expectEqual(@as(?BrowserId, 4), humanUseOf(m));
    }
    const neither = [_]msg.Message{
        .{ .mouse = .{ .browser = 5, .kind = .move, .point = p } },
        .{ .mouse = .{ .browser = 5, .kind = .leave, .point = p } },
        .{ .key = .{ .browser = 5, .kind = .up } },
        .{ .drag_target = .{ .browser = 5, .kind = .enter, .point = p } },
        .{ .drag_target = .{ .browser = 5, .kind = .over, .point = p } },
        .{ .drag_target = .{ .browser = 5, .kind = .leave } },
        .{ .set_focus = .{ .browser = 5, .value = true } },
        .{ .capture_lost = 5 },
    };
    for (neither) |m| {
        try std.testing.expectEqual(@as(?BrowserId, null), gestureOf(m));
        try std.testing.expectEqual(@as(?BrowserId, null), humanUseOf(m));
    }
}

test "W9e②: 사람이 건드린 것 — 쓴 것에 더해 사람의 이동(멈춤·에이전트 이동은 아니다)·사람의 답(v20c N3 — 에이전트·자동 답은 아니다), 쓴 것은 몸짓을 품는다" {
    const touched = [_]msg.Message{
        .{ .mouse = .{ .browser = 3, .kind = .down, .point = .{ .x = 1, .y = 1 } } },
        .{ .key = .{ .browser = 3, .kind = .raw_down, .native_key_code = 0 } },
        .{ .wheel = .{ .browser = 3, .point = .{ .x = 1, .y = 1 }, .delta_x = 0, .delta_y = 3 } },
        .{ .edit_command = .{ .browser = 3, .command = .paste } },
        .{ .navigate = .{ .browser = 3, .url = "https://a.test/", .user = true } },
        .{ .nav_action = .{ .browser = 3, .action = .back, .user = true } },
        .{ .nav_action = .{ .browser = 3, .action = .reload, .user = true } },
        .{ .dialog_reply = .{ .browser = 3, .request = 1, .accept = true, .text = "typed", .user = true } },
        .{ .file_dialog_reply = .{ .browser = 3, .request = 1, .accept = true, .user = true } },
        .{ .permission_reply = .{ .browser = 3, .request = 1, .result = .accept, .user = true } },
        .{ .datalist_pick = .{ .browser = 3, .list = 1, .index = 0 } },
        .{ .web_notification_click = .{ .browser = 3, .notification = 1 } },
    };
    for (touched) |m| try std.testing.expectEqual(@as(?BrowserId, 3), protocol.human_use.touchOf(m));
    const not_touched = [_]msg.Message{
        .{ .mouse = .{ .browser = 3, .kind = .move, .point = .{ .x = 1, .y = 1 } } },
        .{ .key = .{ .browser = 3, .kind = .up, .native_key_code = 0 } },
        .{ .navigate = .{ .browser = 3, .url = "https://a.test/", .user = false } },
        .{ .nav_action = .{ .browser = 3, .action = .stop, .user = true } },
        .{ .nav_action = .{ .browser = 3, .action = .back, .user = false } },
        .{ .capture_lost = 3 },
        .{ .dialog_reply = .{ .browser = 3, .request = 1, .accept = true, .text = "agent" } },
        .{ .file_dialog_reply = .{ .browser = 3, .request = 1, .accept = false } },
        .{ .permission_reply = .{ .browser = 3, .request = 1, .result = .ignore } },
    };
    for (not_touched) |m| try std.testing.expectEqual(@as(?BrowserId, null), protocol.human_use.touchOf(m));
    // 이동은 trace·조건의 「건드림」 이지만 몸짓·쓴 것은 아니다(nav_exempt 의 사람 창은 이동을 몸짓으로 치지 않는다).
    try std.testing.expectEqual(@as(?BrowserId, null), protocol.human_use.useOf(.{ .navigate = .{ .browser = 3, .url = "https://a.test/", .user = true } }));
    // 사람의 답도 trace·조건의 「건드림」 일 뿐 몸짓이 아니다(그 뒤 창 안 이동의 사람 묶기는 예전 그대로 — W9d④).
    try std.testing.expectEqual(@as(?BrowserId, null), gestureOf(.{ .dialog_reply = .{ .browser = 3, .request = 1, .accept = true, .user = true } }));
}
