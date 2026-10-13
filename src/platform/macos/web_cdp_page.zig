//! Chromium(OSR) 탭의 페이지 op(W9a — WebKit 탭에 있던 `browser.*` 를 Chromium 으로): navigate·getUrl·screenshot. `web_cdp_ops.Op` 가 이 종류를
//! 여기로 넘긴다(같은 `Step`·`Reply` — 보내기·받기·완료는 `app_host_abi`). 계획과 실측은 docs/plans/web-osr-backend.md 「W9a」.
//!
//! - navigate: 이동은 DevTools 가 아니라 sidecar wire 의 navigate 다(open 과 같은 길 — 부른 쪽이 `web_osr.agentNavigate` 로 보낸 뒤
//!   시작한다). 여기서는 끝을 기다린다 — 부른 쪽이 깨울 때마다 `nav` 에 지금 상태를 넣는다(`web_osr.AgentNav`).
//! - getUrl: maru 가 아는 주소(`url_changed`) — DevTools 를 부르지 않는다. 같은 탭의 앞선 op(navigate 등) 뒤에 답하려고 차례에 선다.
//! - screenshot: `Page.getLayoutMetrics` → `Page.captureScreenshot`(PNG). rect 는 WebKit 과 같은 **보기 좌표**(CSS px)다 — clip 은 문서
//!   좌표라 `cssLayoutViewport.pageX/pageY` 를 더한다(오른쪽에서 왼쪽으로 쓰는 페이지에서 `cssVisualViewport.pageX` 는 음수라 하얀 그림이
//!   나왔다 — 계획 공격 2·3 회차 실측). 보이는 영역 밖은 자른다. `captureBeyondViewport` 는 쓰지 않는다(페이지에 resize 가 두 번 갔다).

const std = @import("std");
const ops = @import("web_cdp_ops.zig");

const Step = ops.Step;
const Reply = ops.Reply;
const Status = ops.Status;

pub const Kind = enum { navigate, get_url, screenshot };

/// navigate 가 첫 불러오기를 기다리는 시한(요청을 받은 때부터) — 요청의 시한(30 초, `browser_op_timeout_ns`) 안에 `loaded:false` 로
/// 답하게 남긴다.
pub const navigate_wait_ms: i64 = 25_000;
/// navigate 의 끝을 보는 간격.
pub const navigate_poll_ms: u32 = 50;

/// 스크린샷 rect·출력 폭의 상한(CSS px) — WebKit 의 `maxSnapshotPt`(8000 pt)와 같은 뜻(거대 rect·scale 이 픽셀 버퍼를 터뜨리지 않게).
pub const max_snapshot_css: f64 = 8000;

pub const leave_page_reason = "the page asks before leaving (unsaved input) — the user decides in that tab; the navigation continues if they agree";
pub const outside_reason = "the rect is outside the visible part of the page";
pub const too_large_reason = "the screenshot is too large — use a smaller rect or scale";

pub const Op = struct {
    kind: Kind,
    stage: enum { start, metrics, capture, waiting } = .start,
    /// 부른 쪽이 넣는 지금 시각(start·wake 전에).
    now_ms: i64 = 0,
    /// navigate — 끝을 기다리는 시각(부른 쪽이 요청을 받은 때 + `navigate_wait_ms`)과 지금 상태(부른 쪽이 wake 전에 넣는다 — 탭이
    /// 사라졌으면 null).
    deadline_ms: i64 = 0,
    nav: ?NavState = null,
    /// navigate — 이동할 주소(소유). getUrl — 부른 쪽이 start 전에 넣는 지금 주소(빌림).
    target: ?[]u8 = null,
    url: []const u8 = "",
    /// screenshot — 보기 좌표의 rect(x, y, width, height)와 출력 배율.
    rect: ?[4]f64 = null,
    scale: ?f64 = null,

    pub const NavState = struct { done: bool = false, loaded: bool = false, before_unload: bool = false };

    pub fn deinit(self: *Op, gpa: std.mem.Allocator) void {
        if (self.target) |t| gpa.free(t);
        self.* = undefined;
    }

    /// `arg` 는 L2 가 만든 op.arg — navigate 는 주소(JSON 이 아니다), screenshot 은 `{rect?:{x,y,width,height}, scale?}`(형식은 L2 가 봤다).
    pub fn init(gpa: std.mem.Allocator, kind: Kind, arg: []const u8) !Op {
        var op: Op = .{ .kind = kind };
        switch (kind) {
            .navigate => {
                if (!navigableUrl(arg)) return error.InvalidUrl;
                op.target = try gpa.dupe(u8, arg);
            },
            .get_url => {},
            .screenshot => {
                if (arg.len == 0) return op;
                const parsed = std.json.parseFromSlice(std.json.Value, gpa, arg, .{}) catch return error.InvalidArg;
                defer parsed.deinit();
                if (parsed.value != .object) return error.InvalidArg;
                const o = parsed.value.object;
                if (o.get("rect")) |r| {
                    if (r != .object) return error.InvalidArg;
                    var v: [4]f64 = undefined;
                    for ([_][]const u8{ "x", "y", "width", "height" }, 0..) |k, i| v[i] = number(r.object.get(k) orelse return error.InvalidArg) orelse return error.InvalidArg;
                    if (!(v[2] > 0 and v[3] > 0)) return error.InvalidArg;
                    op.rect = v;
                }
                if (o.get("scale")) |sc| {
                    const f = number(sc) orelse return error.InvalidArg;
                    if (!(f > 0) or !std.math.isFinite(f)) return error.InvalidArg;
                    op.scale = f;
                }
            },
        }
        return op;
    }

    pub fn committed(_: *const Op) bool {
        return false;
    }

    pub fn start(self: *Op, gpa: std.mem.Allocator) !Step {
        switch (self.kind) {
            .navigate => {
                self.stage = .waiting;
                return .{ .sleep = navigate_poll_ms };
            },
            .get_url => return done(gpa, .success, self.url),
            .screenshot => {
                self.stage = .metrics;
                return .{ .call = .{ .method = "Page.getLayoutMetrics", .params = try gpa.dupe(u8, "{}") } };
            },
        }
    }

    pub fn wake(self: *Op, gpa: std.mem.Allocator) !Step {
        const st = self.nav orelse return done(gpa, .failed, "the tab closed");
        if (st.before_unload) return done(gpa, .failed, leave_page_reason);
        if (st.done) return done(gpa, .success, if (st.loaded) "true" else "false");
        if (self.now_ms >= self.deadline_ms) return done(gpa, .success, "false");
        return .{ .sleep = navigate_poll_ms };
    }

    pub fn feed(self: *Op, gpa: std.mem.Allocator, reply: Reply) !Step {
        const body = switch (reply) {
            .ok => |b| b,
            .cdp_error => |e| return done(gpa, .failed, cdpMessage(e)),
            .failed => |why| return done(gpa, .failed, if (std.mem.eql(u8, why, ops.result_too_large)) too_large_reason else why),
            .timed_out => |why| return done(gpa, .timeout, why),
            .not_sent => |why| return done(gpa, .failed, why),
        };
        switch (self.stage) {
            .metrics => {
                const clip = self.clipFrom(gpa, body) catch |e| return done(gpa, .failed, switch (e) {
                    error.Outside => outside_reason,
                    else => "the page size could not be read",
                });
                self.stage = .capture;
                const params = if (clip) |c|
                    try std.fmt.allocPrint(gpa, "{{\"format\":\"png\",\"clip\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},\"scale\":{d}}}}}", .{ c[0], c[1], c[2], c[3], c[4] })
                else
                    try gpa.dupe(u8, "{\"format\":\"png\"}");
                return .{ .call = .{ .method = "Page.captureScreenshot", .params = params } };
            },
            .capture => return pngFrom(gpa, body),
            .start, .waiting => return done(gpa, .failed, "internal DevTools request error"),
        }
    }

    /// 문서 좌표의 clip(x, y, width, height, scale) — rect 도 scale 도 없으면 null(보이는 화면 그대로 — 스크롤바 포함, WebKit 과 같다).
    fn clipFrom(self: *const Op, gpa: std.mem.Allocator, metrics: []const u8) !?[5]f64 {
        if (self.rect == null and self.scale == null) return null;
        const Viewport = struct { pageX: f64, pageY: f64, clientWidth: f64, clientHeight: f64 };
        const parsed = try std.json.parseFromSlice(struct { cssLayoutViewport: Viewport }, gpa, metrics, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const vp = parsed.value.cssLayoutViewport;
        if (!(vp.clientWidth > 0 and vp.clientHeight > 0)) return error.NoViewport;
        const r = self.rect orelse [4]f64{ 0, 0, vp.clientWidth, vp.clientHeight };
        // WebKit 처럼 rect 를 먼저 상한으로 접고(그 폭이 출력 배율의 기준), 보이는 영역과 겹친 곳만 찍는다.
        const cw = @min(r[2], max_snapshot_css);
        const ch = @min(r[3], max_snapshot_css);
        const x0 = @max(r[0], 0);
        const y0 = @max(r[1], 0);
        const x1 = @min(r[0] + cw, vp.clientWidth);
        const y1 = @min(r[1] + ch, vp.clientHeight);
        if (!(x1 > x0 and y1 > y0)) return error.Outside;
        const scale = if (self.scale) |s| @min(cw * s, max_snapshot_css) / cw else 1;
        return .{ x0 + vp.pageX, y0 + vp.pageY, x1 - x0, y1 - y0, scale };
    }
};

/// navigate 가 받는 주소 — http·https 와 about:blank 만(W9a 작성자 선택: `javascript:`·`file:`·`chrome:`·`data:` 는 페이지 밖의 힘이다).
pub fn navigableUrl(url: []const u8) bool {
    if (std.mem.eql(u8, url, "about:blank")) return true;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    if (!(std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))) return false;
    // 호스트가 있어야 한다(`http:foo` 는 Chromium 이 고쳐 읽는다 — 받지 않는다).
    return std.mem.startsWith(u8, url[colon..], "://") and url.len > colon + 3;
}

/// `{"data":"<base64>"}` → PNG 바이트.
fn pngFrom(gpa: std.mem.Allocator, body: []const u8) !Step {
    const parsed = std.json.parseFromSlice(struct { data: []const u8 }, gpa, body, .{ .ignore_unknown_fields = true }) catch return done(gpa, .failed, "the screenshot could not be read");
    defer parsed.deinit();
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(parsed.value.data) catch return done(gpa, .failed, "the screenshot could not be read");
    const png = try gpa.alloc(u8, n);
    errdefer gpa.free(png);
    dec.decode(png, parsed.value.data) catch {
        gpa.free(png);
        return done(gpa, .failed, "the screenshot could not be read");
    };
    return .{ .done = .{ .status = .success, .result = png } };
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        else => null,
    };
}

/// CDP 오류 `{"code":…,"message":"…"}` 의 message(없으면 그대로).
fn cdpMessage(e: []const u8) []const u8 {
    const key = "\"message\":\"";
    const at = std.mem.indexOf(u8, e, key) orelse return e;
    const rest = e[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return e;
    return rest[0..end];
}

fn done(gpa: std.mem.Allocator, status: Status, result: []const u8) !Step {
    return .{ .done = .{ .status = status, .result = try gpa.dupe(u8, result) } };
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectDone(step: Step, status: Status, result: []const u8) !void {
    try testing.expect(step == .done);
    defer testing.allocator.free(step.done.result);
    try testing.expectEqual(status, step.done.status);
    try testing.expectEqualStrings(result, step.done.result);
}

test "W9a navigate: http·https·about:blank 만 받는다" {
    for ([_][]const u8{ "https://example.com/", "http://127.0.0.1:8080/a?b", "HTTPS://x.test", "about:blank" }) |u| try testing.expect(navigableUrl(u));
    for ([_][]const u8{ "javascript:alert(1)", "file:///etc/passwd", "chrome://settings", "data:text/html,x", "about:srcdoc", "http:foo", "https://", "ftp://x", "" }) |u| try testing.expect(!navigableUrl(u));
    try testing.expectError(error.InvalidUrl, Op.init(testing.allocator, .navigate, "javascript:1"));
}

test "W9a navigate: 끝·떠나기 확인·탭 닫힘·시한" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .navigate, "https://a.test/");
    defer op.deinit(gpa);
    try testing.expectEqualStrings("https://a.test/", op.target.?);
    op.deadline_ms = 1000;
    try testing.expectEqual(@as(u32, navigate_poll_ms), (try op.start(gpa)).sleep);
    op.nav = .{};
    op.now_ms = 10;
    try testing.expect((try op.wake(gpa)) == .sleep);
    op.nav = .{ .done = true, .loaded = true };
    try expectDone(try op.wake(gpa), .success, "true");
    op.nav = .{ .done = true, .loaded = false };
    try expectDone(try op.wake(gpa), .success, "false");
    op.nav = .{ .before_unload = true };
    try expectDone(try op.wake(gpa), .failed, leave_page_reason);
    op.nav = null;
    try expectDone(try op.wake(gpa), .failed, "the tab closed");
    op.nav = .{};
    op.now_ms = 1000;
    try expectDone(try op.wake(gpa), .success, "false");
}

const metrics_scrolled = "{\"cssLayoutViewport\":{\"pageX\":0,\"pageY\":1200,\"clientWidth\":625,\"clientHeight\":400},\"cssVisualViewport\":{\"pageX\":0,\"pageY\":1200,\"clientWidth\":625,\"clientHeight\":400}}";
const metrics_rtl = "{\"cssLayoutViewport\":{\"pageX\":788,\"pageY\":0,\"clientWidth\":625,\"clientHeight\":400},\"cssVisualViewport\":{\"pageX\":-3587.5,\"pageY\":0,\"clientWidth\":625,\"clientHeight\":400}}";

fn shotParams(arg: []const u8, metrics: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .screenshot, arg);
    defer op.deinit(gpa);
    const first = try op.start(gpa);
    gpa.free(first.call.params);
    try testing.expectEqualStrings("Page.getLayoutMetrics", first.call.method);
    const next = try op.feed(gpa, .{ .ok = metrics });
    if (next == .done) {
        defer gpa.free(next.done.result);
        return gpa.dupe(u8, next.done.result);
    }
    try testing.expectEqualStrings("Page.captureScreenshot", next.call.method);
    return next.call.params;
}

test "W9a screenshot: rect 는 보기 좌표 — 스크롤(세로·오른쪽에서 왼쪽)을 cssLayoutViewport 로 더하고 보이는 영역으로 자른다" {
    const gpa = testing.allocator;
    {
        const p = try shotParams("", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\"}", p);
    }
    {
        const p = try shotParams("{\"rect\":{\"x\":10,\"y\":20,\"width\":100,\"height\":50}}", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\",\"clip\":{\"x\":10,\"y\":1220,\"width\":100,\"height\":50,\"scale\":1}}", p);
    }
    {
        // RTL — cssVisualViewport.pageX(음수)가 아니라 cssLayoutViewport.pageX(실측: 하얀 그림이 나왔다).
        const p = try shotParams("{\"rect\":{\"x\":0,\"y\":0,\"width\":100,\"height\":100}}", metrics_rtl);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\",\"clip\":{\"x\":788,\"y\":0,\"width\":100,\"height\":100,\"scale\":1}}", p);
    }
    {
        // 화면을 넘는 rect 는 보이는 곳만, 출력 배율은 WebKit 처럼 접기 전 rect 폭 기준.
        const p = try shotParams("{\"rect\":{\"x\":600,\"y\":-10,\"width\":100,\"height\":30},\"scale\":2}", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\",\"clip\":{\"x\":600,\"y\":1200,\"width\":25,\"height\":20,\"scale\":2}}", p);
    }
    {
        // scale 만 — 보이는 영역 전체(스크롤바 제외)를 그 배율로.
        const p = try shotParams("{\"scale\":0.5}", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\",\"clip\":{\"x\":0,\"y\":1200,\"width\":625,\"height\":400,\"scale\":0.5}}", p);
    }
    {
        // 출력 폭 상한(8000) — rect 폭 × scale 을 접는다.
        const p = try shotParams("{\"rect\":{\"x\":0,\"y\":0,\"width\":500,\"height\":10},\"scale\":40}", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings("{\"format\":\"png\",\"clip\":{\"x\":0,\"y\":1200,\"width\":500,\"height\":10,\"scale\":16}}", p);
    }
    {
        const p = try shotParams("{\"rect\":{\"x\":700,\"y\":0,\"width\":10,\"height\":10}}", metrics_scrolled);
        defer gpa.free(p);
        try testing.expectEqualStrings(outside_reason, p);
    }
}

test "W9a screenshot: 그림을 풀어 PNG 바이트로, 너무 크면 rect·scale 을 줄이라고" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .screenshot, "");
    defer op.deinit(gpa);
    gpa.free((try op.start(gpa)).call.params);
    gpa.free((try op.feed(gpa, .{ .ok = metrics_scrolled })).call.params);
    const png = try op.feed(gpa, .{ .ok = "{\"data\":\"iVBORw0KGgo=\"}" });
    defer gpa.free(png.done.result);
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png.done.result);
    try expectDone(try op.feed(gpa, .{ .failed = ops.result_too_large }), .failed, too_large_reason);
    try expectDone(try op.feed(gpa, .{ .ok = "{\"data\":\"***\"}" }), .failed, "the screenshot could not be read");
}

test "W9a getUrl: 부른 쪽이 넣은 지금 주소" {
    const gpa = testing.allocator;
    var op = try Op.init(gpa, .get_url, "");
    defer op.deinit(gpa);
    op.url = "https://a.test/x";
    try expectDone(try op.start(gpa), .success, "https://a.test/x");
}
