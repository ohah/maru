//! 웹 OSR sidecar 관리(W3b, docs/plans/web-osr-backend.md) — 앱 하나에 `maru-web-host` 하나. 창들이 나눠 쓴다.
//!
//! **Zig 가 직접 띄운다**(사용자 결정 2026-09-24 — `lsp_process.zig` 선례): fork·execve 로 띄우고, 비차단 파이프를 창
//! tick 에서 비운다. Mermaid helper 는 Swift 가 띄우는데 그 이유(Security.framework 서명 검증)는 배포(W7) 때 필요하다.
//!
//! **켜는 법**: 설정 `browser.engine = chromium`(W4d — `maru-chromium` 설치가 있어야 한다, 앱을 다시 시작해야 적용)
//! 또는 개발용 `MARU_WEB_OSR_DIR=<설치 디렉터리>`(`zig build web-sidecar` 의 `zig-out/web-sidecar` — 환경변수가 먼저).
//!
//! 수명: 첫 OSR 탭이 보이면 띄우고, 마지막 브라우저가 파괴되면 내린다. 죽으면 다시 띄워 살아 있던 탭을 다시 만든다 —
//! 60 초 안에 세 번 죽으면 멈추고 안내한다(Mermaid 와 같은 예산). 같은 프로필을 다른 maru 가 쓰면(`profile_in_use`)
//! 다시 띄우지 않는다. **메인 스레드 전용**(창 tick 과 ABI 가 모두 메인).

const std = @import("std");
const maru = @import("maru");
const lsp_process = @import("lsp_process.zig");
const ring_receiver = @import("web_sidecar/ring_receiver.zig");
const iosurface = @import("web_sidecar/iosurface.zig");

const ws = maru.session.web_sidecar;
const plan = maru.session.web_osr_plan;
const mailbox = ws.mailbox;

/// 링 하나(W3c): 받은 IOSurface 셋·제어 페이지와, View 가 보는 세대·mailbox 워드.
pub const AppRing = struct {
    generation: u32,
    control: *mailbox.Control,
    width: u32,
    height: u32,
    ring: ring_receiver.Ring,

    fn release(self: AppRing) void {
        self.ring.release();
    }
};

const RingView = maru.session.web_osr_view.View(AppRing);

/// 그릴 front 하나(창 좌표는 호출자가 안다).
pub const Front = struct {
    surface: iosurface.Ref,
    width: u32,
    height: u32,
};
const Message = ws.message.Message;
const FailureCode = ws.message.FailureCode;

pub const State = enum { off, starting, running, failed };

/// 창이 사용자에게 보일 안내. 표시 문구는 창이 i18n 으로 만든다(여기는 코드만).
pub const Notice = enum { gpu_unavailable, profile_in_use, start_failed, crashed_repeatedly };

pub const NavUpdate = struct {
    surface_id: u64,
    url: []const u8,
    can_go_back: bool,
    can_go_forward: bool,
};

const restart_window_ms: i64 = 60_000;
const restart_budget = 3;
const handshake_timeout_ms: i64 = 15_000;
const shutdown_wait_ms: i64 = 3_000;

const Surface = struct {
    record: plan.Record,
    /// sidecar 가 이 브라우저를 만들었다고 답했다(그 전 명령은 CEF 가 모르는 id 라 보내지 않고 쥔다).
    created: bool = false,
    /// 마지막으로 이동시킨 주소 — sidecar 가 다시 뜨면 이 주소로 되살린다. 이동을 CEF 가 끝내면 `url` 이 된다.
    last_url: ?[]u8 = null,
    url: ?[]u8 = null,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    nav_dirty: bool = false,
    gpu_notice_pending: bool = false,
    /// 보일 링 고르기(W3c) — 새 링의 첫 프레임까지 옛 장, GPU 소비자 규칙.
    view: RingView = .{},
    /// 마지막으로 이 front 를 그린 창(AppSession 주소). 프레임 세대는 창마다 따로 세므로 다른 창의 세대와 비교하지 않는다.
    drawn_by: usize = 0,
    /// 페이지가 원하는 커서(W4b). sidecar 는 같은 커서를 다시 보내지 않으므로 maru 가 기억한다 — 포인터가 나갔다 다시
    /// 들어와도 이 값을 쓴다. 세대는 바뀔 때마다 올라, 창이 hover 중인 탭의 커서가 바뀐 것을 안다.
    cursor: ws.message.WebCursor = .arrow,
    cursor_generation: u32 = 0,
    /// 키 포커스를 줘야 하는가(W4c — 창이 정한 키 대상). sidecar 가 다시 떠 브라우저를 새로 만들면 이 값으로 되살린다.
    focused: bool = false,
    /// 포커스를 준 창(AppSession 주소) — 탭이 다른 창으로 옮긴 뒤 옛 창의 늦은 「포커스 놓기」가 새 창의 포커스를 덮지 않게.
    focus_owner: usize = 0,
    /// 페이지에 조합이 열려 있다고 보는가(W4c). maru 가 보낸 조합 메시지로 세고, 페이지가 조합을 끝내는 자리(이동·포커스
    /// 잃음·브라우저 재생성)에서 푼다. **조합이 없을 때의 조합 취소는 선택한 글을 지운다**(Chromium — 판정자
    /// `input-ime-cancel-idle`) — 그래서 취소는 이 값이 참일 때만 보낸다. CEF 는 조합이 끝날 때 알려 주지 않는다(실측).
    composing: bool = false,
    /// 마지막 IME 조합 사각형(view DIP — `ime_range`). 후보창 위치(`firstRect`)에 쓴다.
    ime_bounds: ?ws.message.Rect = null,
    /// 답을 기다리는 대화상자·파일 선택(W5a)·권한 요청(W5b) — 온 차례대로.
    dialogs: std.ArrayList(Dialog) = .empty,
};

pub const Cursor = struct { cursor: ws.message.WebCursor, generation: u32 };

/// 답을 기다리는 JS 대화상자·파일 선택(W5a)·권한 요청(W5b) — C6. 글은 복사해 쥔다(sidecar 가 보낸 frame 은 곧 사라진다).
pub const DialogKind = enum(u32) {
    alert = 0,
    confirm = 1,
    prompt = 2,
    before_unload = 3,
    file_open = 10,
    file_open_multiple = 11,
    file_open_folder = 12,
    file_save = 13,
    permission = 20,

    pub fn isFile(self: DialogKind) bool {
        return @intFromEnum(self) >= 10 and @intFromEnum(self) <= 13;
    }
};

pub const Dialog = struct {
    /// maru 가 매기는 번호(프로세스 전체에서 한 번씩) — 창·Swift 는 이것으로 짝을 찾는다. sidecar 의 요청 번호는 sidecar 가
    /// 다시 뜨면 1 부터 다시 매겨 옛 창의 늦은 답이 새 요청에 붙을 수 있다(적대 검증).
    token: u64,
    request: ws.message.RequestId,
    kind: DialogKind,
    origin: []u8,
    message: []u8,
    /// `prompt` 의 기본 글, 파일 선택이면 처음 고를 경로.
    default_text: []u8,
    /// 파일 선택이 받을 형식(`image/*,.png`).
    accept: []u8,
    /// 이 페이지가 이동 없이 두 번째 이상 띄운 대화상자 — 「더 띄우지 못하게」를 보인다.
    offer_suppress: bool = false,
    /// 권한 요청(W5b)이 청한 종류 — 둘 중 하나만 찬다(`ws.message.PermissionRequest`).
    permission_kinds: u32 = 0,
    permission_media: u8 = 0,
    /// 띄운 창(AppSession 주소) — 0 이면 아직 안 띄웠다.
    shown_by: usize = 0,

    fn free(self: Dialog, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.message);
        gpa.free(self.default_text);
        gpa.free(self.accept);
    }
};

/// 한 브라우저가 동시에 기다리게 하는 상한. JS 대화상자는 페이지가 멈춰 하나씩이고 파일 선택도 하나씩이라 넉넉하다 —
/// 넘으면 곧바로 취소로 답한다(sidecar 가 쥔 콜백이 쌓이지 않게).
const max_dialogs_per_surface = 4;
var next_dialog_token: u64 = 1;

var gpa_ref: ?std.mem.Allocator = null;
var state: State = .off;
var process: ?lsp_process.Process = null;
/// shutdown 을 보내고 끝나기를 기다리는 옛 sidecar(마지막 탭을 닫았다). tick 이 거두고, 기한을 넘으면 죽인다 — 탭을 닫는
/// 메인 스레드를 막지 않는다(처음엔 최대 3 초 막았다 — 적대 검증).
var retiring: ?lsp_process.Process = null;
var retiring_since_ms: i64 = 0;
var decoder: ws.stream.StreamingDecoder = .init(.to_maru);
var inbox: std.ArrayList(u8) = .empty;
var outbox_pending: std.ArrayList(u8) = .empty; // handshake 전 명령(인코딩된 frame)
var surfaces: std.AutoArrayHashMapUnmanaged(u64, Surface) = .empty;
var hello_nonce: u64 = 0;
var started_ms: i64 = 0;
var failures: [restart_budget]?i64 = @splat(null);
/// 띄울 때마다 오른다 — 파이프를 비우는 도중 sidecar 가 죽어 다시 띄우면(받은 바이트를 지운다) 비우던 쪽이 멈춘다.
var process_generation: u64 = 0;
var failure_head: usize = 0;
var notice_queue: std.ArrayList(Notice) = .empty;
/// 픽셀 링을 받는 mach port(W3c). sidecar 가 바뀌어도 하나를 계속 쓴다 — 기대 pid 와 pid 버전 고정만 새로 한다.
var receiver: ?ring_receiver.Receiver = null;
/// 받은 링 알림 중 거절한 수(관측점 — 이름은 비밀이 아니라 아무나 넣을 수 있다).
var rejected_rings: u64 = 0;
var latched: ?Notice = null;

/// 엔진 결정(W4d — 프로세스에 한 번, 재시작 후 적용). 첫 창이 설정을 읽은 뒤 `decide` 로 정한다. 개발용 환경변수
/// `MARU_WEB_OSR_DIR` 가 먼저고, 아니면 설정 `browser.engine = chromium` 이고 `maru-chromium` 이 설치돼 있을 때 켠다.
var decided: ?bool = null;
/// 결정할 때 설정이 청한 값(chromium 이면 true) — 설정이 바뀌면 「재시작하면 적용」을 한 번 알린다.
var requested_chromium: bool = false;
var last_change_notice: ?bool = null;
var install_notice_pending = false;
var install_buf: [512]u8 = undefined;
var install_len: usize = 0;

/// `maru-chromium` formula 설치 위치 후보(`$(brew --prefix)/opt/maru-chromium/libexec` — 계획 문서 「배포·배치」).
/// `HOMEBREW_PREFIX` 가 있으면 그 prefix 를 먼저 본다(brew shellenv 가 세운다 — 스모크도 이것으로 가짜 설치를 가리킨다).
const install_candidates = [_][]const u8{
    "/opt/homebrew",
    "/usr/local",
};

/// 엔진 결정 규칙(순수 — 시험한다): 개발용 환경변수가 먼저, 설정이 chromium 을 청하고 설치가 있으면 그 설치, 청했는데
/// 설치가 없으면 WebKit + 안내.
pub const Decision = struct { chromium: bool, dir: ?[]const u8 = null, not_installed: bool = false };

pub fn decideFrom(config_wants_chromium: bool, env_dir: ?[]const u8, installed_dir: ?[]const u8) Decision {
    if (env_dir) |dir| return .{ .chromium = true, .dir = dir };
    if (!config_wants_chromium) return .{ .chromium = false };
    if (installed_dir) |dir| return .{ .chromium = true, .dir = dir };
    return .{ .chromium = false, .not_installed = true };
}

/// 첫 창이 설정을 읽은 뒤 부른다(두 번째부터는 무동작).
pub fn decide(config_wants_chromium: bool) void {
    if (decided != null) return;
    requested_chromium = config_wants_chromium;
    const env = envDir();
    const d = decideFrom(config_wants_chromium, env, if (config_wants_chromium) findInstall() else null);
    // 환경변수 경로는 복사하지 않는다(`installDir` 가 그대로 읽는다 — 길이 제한 없이). 설치 경로는 findInstall 이 상한 안에서 만든다.
    if (env == null) if (d.dir) |dir| setInstall(dir);
    decided = d.chromium;
    install_notice_pending = d.not_installed; // 청했는데 설치가 없다 — 한 번 안내하고 WebKit 으로
    const log = std.log.scoped(.web_osr);
    if (d.not_installed) log.warn("browser.engine = chromium but maru-chromium is not installed — using WebKit", .{});
    if (d.chromium) log.info("browser engine: chromium ({s})", .{installDir() orelse "?"});
}

test "engine decision: env first, then an installed maru-chromium, else WebKit with a notice" {
    try std.testing.expectEqual(Decision{ .chromium = true, .dir = "/dev/build" }, decideFrom(false, "/dev/build", null));
    try std.testing.expectEqual(Decision{ .chromium = false }, decideFrom(false, null, "/opt/homebrew/opt/maru-chromium/libexec"));
    const installed = decideFrom(true, null, "/opt/homebrew/opt/maru-chromium/libexec");
    try std.testing.expect(installed.chromium and !installed.not_installed);
    try std.testing.expectEqualStrings("/opt/homebrew/opt/maru-chromium/libexec", installed.dir.?);
    try std.testing.expectEqual(Decision{ .chromium = false, .not_installed = true }, decideFrom(true, null, null));
}

test "the engine is latched by the first decision (restart-only)" {
    const saved = .{ decided, requested_chromium, install_notice_pending };
    defer {
        decided = saved[0];
        requested_chromium = saved[1];
        install_notice_pending = saved[2];
    }
    if (envDir() != null) return error.SkipZigTest; // 개발용 환경변수가 걸린 셸이면 결정이 달라진다
    decided = null;
    decide(false);
    try std.testing.expect(!enabled());
    decide(true); // 두 번째 창 — 무동작
    try std.testing.expect(!enabled());
    try std.testing.expect(!requested_chromium);
}

test "engine change notice fires once per new value and resets when the setting returns" {
    const saved_decided = decided;
    const saved_requested = requested_chromium;
    const saved_last = last_change_notice;
    defer {
        decided = saved_decided;
        requested_chromium = saved_requested;
        last_change_notice = saved_last;
    }
    decided = false;
    requested_chromium = false;
    last_change_notice = null;
    try std.testing.expect(!engineChangeNeedsNotice(false));
    try std.testing.expect(engineChangeNeedsNotice(true));
    try std.testing.expect(!engineChangeNeedsNotice(true)); // 같은 값 — 다시 안 알린다
    try std.testing.expect(!engineChangeNeedsNotice(false)); // 되돌림 — 적용 중인 값과 같다
    try std.testing.expect(engineChangeNeedsNotice(true)); // 다시 바꾸면 다시 알린다
    // 청했지만 설치가 없어 WebKit 인 상태에서 webkit 으로 되돌림 — 바뀌는 것이 없다.
    decided = false;
    requested_chromium = true;
    last_change_notice = null;
    try std.testing.expect(!engineChangeNeedsNotice(false));
}

/// 설정의 엔진이 바뀌었다(파일 reload·설정 화면). 적용 중인 결정과 다르면 한 번 true — 「재시작하면 적용」 안내.
pub fn engineChangeNeedsNotice(config_wants_chromium: bool) bool {
    const effective = decided orelse return false;
    // 청했지만 설치가 없어 이미 WebKit 인데 webkit 으로 되돌렸다 — 바뀌는 것이 없다.
    if (config_wants_chromium == requested_chromium or (!effective and !config_wants_chromium)) {
        last_change_notice = null;
        return false;
    }
    if (last_change_notice == config_wants_chromium) return false;
    last_change_notice = config_wants_chromium;
    return true;
}

/// 설정은 chromium 을 청했는데 설치가 없어 WebKit 으로 열었다 — 한 번.
pub fn takeInstallNotice() bool {
    const v = install_notice_pending;
    install_notice_pending = false;
    return v;
}

/// OSR 백엔드가 켜져 있는가. 결정 전(첫 창 설정 전)에는 개발용 환경변수만 본다.
pub fn enabled() bool {
    return decided orelse (envDir() != null);
}

fn envDir() ?[]const u8 {
    const dir = std.c.getenv("MARU_WEB_OSR_DIR") orelse return null;
    const s = std.mem.span(dir);
    return if (s.len == 0) null else s;
}

fn findInstall() ?[]const u8 {
    const S = struct {
        var dir_buf: [512]u8 = undefined;
    };
    var path_buf: [600]u8 = undefined;
    const env_prefix: ?[]const u8 = if (std.c.getenv("HOMEBREW_PREFIX")) |p| std.mem.span(p) else null;
    const prefixes = [_]?[]const u8{ env_prefix, install_candidates[0], install_candidates[1] };
    for (prefixes) |maybe| {
        const prefix = maybe orelse continue;
        if (prefix.len == 0) continue;
        const dir = std.fmt.bufPrint(&S.dir_buf, "{s}/opt/maru-chromium/libexec", .{prefix}) catch continue;
        const host = std.fmt.bufPrintZ(&path_buf, "{s}/maru-web-host", .{dir}) catch continue;
        if (std.c.access(host, std.c.X_OK) == 0) return dir;
    }
    return null;
}

fn setInstall(dir: []const u8) void {
    const n = @min(dir.len, install_buf.len);
    @memcpy(install_buf[0..n], dir[0..n]);
    install_len = n;
}

pub fn currentState() State {
    return state;
}

/// 이 surface 를 OSR 이 들고 있는가(control-plane 이 「이 엔진은 아직 지원하지 않는다」로 답할 때).
pub fn owns(surface_id: u64) bool {
    return surfaces.contains(surface_id);
}

/// 창 배치 하나를 맞춘다(창 tick 의 web 전이 계산에서, OSR 대상 탭마다).
pub fn ensure(gpa: std.mem.Allocator, layout: plan.Layout, scale_milli: u32, now_ms: i64) void {
    gpa_ref = gpa;
    var commands: std.ArrayList(plan.Command) = .empty;
    defer commands.deinit(gpa);
    const existing = surfaces.getPtr(layout.surface_id);
    const fresh = (plan.reconcile(if (existing) |s| &s.record else null, layout, scale_milli, &commands, gpa) catch return) orelse null;
    if (fresh) |record| {
        surfaces.put(gpa, layout.surface_id, .{ .record = record }) catch return;
        // 판정자 전용(`MARU_WEB_OSR_TEST_URL`): 새 탭을 이 주소로 연다 — 스모크가 sidecar 까지의 경로(띄우기·handshake·
        // 생성·이동)를 시험 서버가 받은 요청으로 확인한다. 제품 사용자가 켤 이유는 없다.
        if (std.c.getenv("MARU_WEB_OSR_TEST_URL")) |test_url| navigate(gpa, layout.surface_id, std.mem.span(test_url));
    }
    if (commands.items.len == 0) return;
    if (latched != null) return; // 멈췄다 — 새로 띄우지 않는다
    if (state == .off) start(gpa, now_ms);
    for (commands.items) |command| {
        // 이 크기로 그리라고 보냈다 — 다른 크기 링(크기 변경 전환 프레임)에서는 꺼내지 않는다(W3c).
        switch (command) {
            .create => |c| if (surfaces.getPtr(c.browser)) |s| s.view.expect(pixels(c.size.width, c.size.scale), pixels(c.size.height, c.size.scale)),
            .resize => |c| if (surfaces.getPtr(c.browser)) |s| s.view.expect(pixels(c.size.width, c.size.scale), pixels(c.size.height, c.size.scale)),
            .set_hidden => {},
        }
        sendCommand(gpa, command);
    }
}

/// DIP × scale — CEF 가 그 크기로 그린 장의 픽셀 수(반올림).
fn pixels(dip: u32, scale: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(dip)) * scale));
}

/// 이동(주소창·복원·링크). 아직 만들어지지 않았으면 만든 뒤 보낸다.
pub fn navigate(gpa: std.mem.Allocator, surface_id: u64, url: []const u8) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const owned = gpa.dupe(u8, url) catch return;
    if (s.last_url) |old| gpa.free(old);
    s.last_url = owned;
    if (s.created) send(gpa, .{ .navigate = .{ .browser = surface_id, .url = url } });
}

pub fn navAction(gpa: std.mem.Allocator, surface_id: u64, action: ws.message.NavActionKind) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (s.created) send(gpa, .{ .nav_action = .{ .browser = surface_id, .action = action } });
}

/// 입력(W4b·W4c — 라우팅은 창이 정했다). 만들어졌고 sidecar 가 돌 때만 보낸다 — 입력은 쥐었다가 늦게 보낼 것이 아니다(첫
/// 프레임 전 입력은 렌더러도 버린다 — W4a 실측). 보냈으면 true.
pub fn sendInput(gpa: std.mem.Allocator, message: Message) bool {
    const browser: u64 = switch (message) {
        .mouse => |m| m.browser,
        .wheel => |m| m.browser,
        .key => |m| m.browser,
        .capture_lost, .ime_cancel_composition => |b| b,
        .ime_set_composition => |m| m.browser,
        .ime_commit_text => |m| m.browser,
        .ime_finish_composing => |m| m.browser,
        .edit_command => |m| m.browser,
        else => return false,
    };
    const s = surfaces.getPtr(browser) orelse return false;
    if (!s.created or state != .running) return false;
    switch (message) {
        .ime_set_composition => |m| {
            if (!s.composing) s.ime_bounds = null; // 새 조합 — 옛 사각형을 쓰지 않는다
            s.composing = m.text.len > 0;
        },
        .ime_commit_text, .ime_finish_composing => s.composing = false,
        .ime_cancel_composition => {
            if (!s.composing) return false; // 조합이 없으면 취소는 선택을 지운다 — 보내지 않는다
            s.composing = false;
        },
        else => {},
    }
    send(gpa, message);
    return true;
}

/// 페이지에 조합이 열려 있다고 보는가.
pub fn composing(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    return s.composing;
}

/// 키 포커스(W4c). 원하는 값을 기억하고 만들어졌으면 곧바로 보낸다 — 만들어지기 전이거나 sidecar 가 다시 떠도
/// `browser_created` 에서 되살린다(안 그러면 새 브라우저는 포커스 없이 키를 버린다).
pub fn setFocus(gpa: std.mem.Allocator, surface_id: u64, value: bool, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    if (value) {
        s.focus_owner = window;
    } else {
        if (s.focus_owner != window) return; // 다른 창이 이미 포커스를 가져갔다
        s.focus_owner = 0;
        s.composing = false; // 포커스를 잃으면 Chromium 이 조합을 확정한다
    }
    s.focused = value;
    if (s.created and state == .running) send(gpa, .{ .set_focus = .{ .browser = surface_id, .value = value } });
}

/// 마지막 IME 조합 사각형(view DIP). 없으면 null.
pub fn imeBounds(surface_id: u64) ?ws.message.Rect {
    const s = surfaces.getPtr(surface_id) orelse return null;
    return s.ime_bounds;
}

/// 이 탭이 원하는 커서와 그 세대(없는 탭이면 null).
pub fn cursor(surface_id: u64) ?Cursor {
    const s = surfaces.getPtr(surface_id) orelse return null;
    return .{ .cursor = s.cursor, .generation = s.cursor_generation };
}

/// Term 이 사라졌다 — 브라우저를 파괴한다. 마지막이면 sidecar 도 내린다.
pub fn destroy(gpa: std.mem.Allocator, surface_id: u64) void {
    var kv = surfaces.fetchSwapRemove(surface_id) orelse return;
    // Term 이 사라졌다 — 다음 프레임부터 그리지 않는다. 이미 GPU 에 올라간 장은 renderer 캐시의 텍스처가 IOSurface 를
    // 쥐고 있어 여기서 놓아도 안전하다.
    for (kv.value.view.clear()) |ring| if (ring) |r| r.release();
    freeSurface(gpa, &kv.value);
    if (state == .running or state == .starting) send(gpa, .{ .destroy_browser = surface_id });
    if (surfaces.count() == 0) retire(gpa, monotonicNow());
}

/// 창 tick 마다 부른다 — 파이프를 비우고 알림을 적용하고, 죽었으면 다시 띄운다. 여러 창이 불러도 값싸다.
pub fn pump(gpa: std.mem.Allocator, now_ms: i64) void {
    gpa_ref = gpa;
    reapRetiring(gpa, now_ms);
    const generation = process_generation;
    const p = if (process) |*p| p else return;
    _ = lsp_process.flush(p, gpa) catch {};
    const read = lsp_process.readInto(p, gpa, &inbox, 256 * 1024) catch .eof;
    drainInbox(gpa, now_ms);
    receiveRings();
    // 비우는 사이 sidecar 가 끝났거나(`profile_in_use` 로 멈춤) 다시 떴다 — 위의 `read`·`p` 는 옛 프로세스의 것이다.
    // 처음엔 그대로 이어가 옛 EOF 로 새 sidecar 를 또 죽은 것으로 세거나, 비운 optional 을 읽었다(적대 점검).
    if (process == null or process_generation != generation) return;
    if (read == .eof or lsp_process.reapIfExited(&process.?)) return crashed(gpa, now_ms);
    if (state == .starting and now_ms - started_ms > handshake_timeout_ms) {
        lsp_process.kill(&process.?, .KILL);
        return crashed(gpa, now_ms);
    }
}

/// 이 surface 에 새 프레임이 있으면 front 로 삼는다(W3c). `completed_generation` 은 그 창에서 GPU 가 끝낸 마지막
/// 프레임 세대다 — 지금 front 를 그린 프레임이 안 끝났으면 꺼내지 않는다. 새 프레임이면 true(창을 다시 그린다).
pub fn pollFrame(surface_id: u64, completed_generation: u64, window: usize) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    // 다른 창이 마지막으로 그렸다(탭이 창을 옮겼다) — 그 창의 세대는 이 창의 완료 세대와 셈이 달라 영영 끝나지 않은 것으로
    // 보인다. 옛 창은 이제 이 탭을 그리지 않으니 막지 않는다.
    const completed = if (s.drawn_by == 0 or s.drawn_by == window) completed_generation else std.math.maxInt(u64);
    const polled = s.view.poll(completed);
    for (polled.retired) |ring| if (ring) |r| r.release();
    if (polled.corrupt) rejected_rings += 1;
    return polled.new_frame;
}

/// 지금 그릴 front(첫 프레임 전이면 null).
pub fn front(surface_id: u64) ?Front {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (!s.view.has_frame) return null;
    const shown = s.view.shown orelse return null;
    return .{ .surface = shown.ring.surfaces[s.view.front], .width = shown.ring.width, .height = shown.ring.height };
}

/// 이 프레임(세대)이 그 surface 의 front 를 그렸다.
pub fn drew(surface_id: u64, frame_generation: u64, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    s.view.drew(frame_generation);
    s.drawn_by = window;
}

/// 이 surface 의 새 주소·탐색 상태(있으면 한 번). 창이 자기 surface 에만 부른다.
pub fn takeNavUpdate(surface_id: u64) ?NavUpdate {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (!s.nav_dirty) return null;
    s.nav_dirty = false;
    return .{ .surface_id = surface_id, .url = s.url orelse "", .can_go_back = s.can_go_back, .can_go_forward = s.can_go_forward };
}

/// 이 surface 에 GPU 불가 안내가 걸려 있는가(한 번).
pub fn takeGpuNotice(surface_id: u64) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    defer s.gpu_notice_pending = false;
    return s.gpu_notice_pending;
}

/// 앱 전체 안내(한 창이 한 번 보인다).
pub fn takeNotice() ?Notice {
    if (notice_queue.items.len == 0) return null;
    return notice_queue.orderedRemove(0);
}

/// 앱 종료 — shutdown 을 보내고 잠시 기다린 뒤 남았으면 죽인다. sidecar 는 부모(maru)가 사라지면 스스로도 끝난다.
pub fn shutdownForExit() void {
    const gpa = gpa_ref orelse return;
    stop(gpa);
    if (retiring) |*old| {
        // 앱이 끝난다 — 물러나던 sidecar 도 기한 안에 거둔다(앱 종료는 기다려도 된다).
        var waited: i64 = 0;
        while (waited < shutdown_wait_ms and !lsp_process.reapIfExited(old)) : (waited += 20) sleepMs(20);
        if (waited >= shutdown_wait_ms) {
            lsp_process.kill(old, .KILL);
            lsp_process.reapBlocking(old);
        }
        old.deinit(gpa);
        retiring = null;
    }
    var it = surfaces.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.view.clear()) |ring| if (ring) |r| r.release();
        freeSurface(gpa, entry.value_ptr);
    }
    surfaces.deinit(gpa);
    if (receiver) |*r| r.close();
    receiver = null;
    surfaces = .empty;
    inbox.deinit(gpa);
    inbox = .empty;
    outbox_pending.deinit(gpa);
    outbox_pending = .empty;
    notice_queue.deinit(gpa);
    notice_queue = .empty;
}

// ── 대화상자·파일 선택(W5a) ────────────────────────────────────────────────────────────────────────────
//
// 창은 자기 창에서 **키보드 초점을 가진** Chromium 탭의 요청만 띄운다(뒤쪽 탭·초점 없는 pane 의 대화상자는 초점이 올 때까지
// 기다린다 — 페이지는 그동안 멈춰 있다). 한 창에 하나씩 — sheet 는 창 전체를 막는다.

/// 요청을 적는다. 모르는 브라우저(파괴 경합)·상한·메모리 부족이면 false — 호출자가 곧바로 기본값으로 답한다.
fn queueDialog(gpa: std.mem.Allocator, browser: u64, request: ws.message.RequestId, kind: DialogKind, origin: []const u8, message_text: []const u8, default_text: []const u8, accept: []const u8, offer_suppress: bool) bool {
    const s = surfaces.getPtr(browser) orelse return false;
    if (s.dialogs.items.len >= max_dialogs_per_surface) return false;
    const origin_owned = gpa.dupe(u8, origin) catch return false;
    const message_owned = gpa.dupe(u8, message_text) catch {
        gpa.free(origin_owned);
        return false;
    };
    const default_owned = gpa.dupe(u8, default_text) catch {
        gpa.free(origin_owned);
        gpa.free(message_owned);
        return false;
    };
    const accept_owned = gpa.dupe(u8, accept) catch {
        gpa.free(origin_owned);
        gpa.free(message_owned);
        gpa.free(default_owned);
        return false;
    };
    const dialog: Dialog = .{ .token = next_dialog_token, .request = request, .kind = kind, .origin = origin_owned, .message = message_owned, .default_text = default_owned, .accept = accept_owned, .offer_suppress = offer_suppress };
    next_dialog_token += 1;
    s.dialogs.append(gpa, dialog) catch {
        dialog.free(gpa);
        return false;
    };
    return true;
}

/// 권한 요청(W5b)을 적는다 — 대화상자와 같은 대기열·상한·토큰.
fn queuePermission(gpa: std.mem.Allocator, v: ws.message.PermissionRequest) bool {
    if (!queueDialog(gpa, v.browser, v.request, .permission, v.origin, "", "", "", false)) return false;
    const s = surfaces.getPtr(v.browser).?;
    const d = &s.dialogs.items[s.dialogs.items.len - 1];
    d.permission_kinds = v.kinds;
    d.permission_media = v.media;
    return true;
}

fn removeDialog(gpa: std.mem.Allocator, s: *Surface, token: u64) void {
    for (s.dialogs.items, 0..) |d, i| if (d.token == token) {
        d.free(gpa);
        _ = s.dialogs.orderedRemove(i);
        return;
    };
}

/// 그 탭에서 다음에 띄울 요청(아직 아무 창도 안 띄운 첫 요청). 앞 요청이 떠 있으면 null — 한 탭은 하나씩.
pub fn nextDialog(surface_id: u64) ?*const Dialog {
    const s = surfaces.getPtr(surface_id) orelse return null;
    if (s.dialogs.items.len == 0) return null;
    const first = &s.dialogs.items[0];
    return if (first.shown_by == 0) first else null;
}

pub fn markDialogShown(surface_id: u64, token: u64, window: usize) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    for (s.dialogs.items) |*d| if (d.token == token) {
        d.shown_by = window;
        return;
    };
}

/// 그 요청이 아직 답을 기다리는가 — 창은 떠 있는 요청이 사라지면(이동·닫힘·sidecar 재시작) 창을 닫는다.
pub fn dialogPending(surface_id: u64, token: u64) ?*const Dialog {
    const s = surfaces.getPtr(surface_id) orelse return null;
    for (s.dialogs.items) |*d| if (d.token == token) return d;
    return null;
}

/// JS 대화상자의 답. 요청이 없으면(이미 사라졌다) 무동작. `suppress` 면 그 페이지가 이동할 때까지 대화상자를 더 띄우지 못한다.
pub fn replyDialog(gpa: std.mem.Allocator, surface_id: u64, token: u64, accept: bool, text: []const u8, suppress: bool) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (d.kind.isFile() or d.kind == .permission) return;
    const request = d.request;
    // 답 글은 대화상자 글 규칙(상한·제어 문자)에 맞게 다듬는다 — 글자 경계에서 자르고 줄바꿈·탭 밖의 제어 문자는 공백으로
    // (통째로 버리면 긴 답이 빈 답이 된다 — 적대 검증).
    var buf: [ws.wire.max_text_bytes]u8 = undefined;
    const clamped = ws.text.clampUtf8(text, buf.len);
    @memcpy(buf[0..clamped.len], clamped);
    ws.text.replaceControlKeepLines(buf[0..clamped.len]);
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .dialog_reply = .{ .browser = surface_id, .request = request, .accept = accept, .text = buf[0..clamped.len], .suppress = suppress } });
}

/// 파일 선택의 경로 하나(여러 개면 여러 번). 경로 규칙을 못 지나면 버린다.
pub fn fileDialogPath(gpa: std.mem.Allocator, surface_id: u64, token: u64, path: []const u8) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (!d.kind.isFile()) return;
    ws.fields.checkPath(path) catch return;
    if (s.created) send(gpa, .{ .file_dialog_path = .{ .browser = surface_id, .request = d.request, .path = path } });
}

pub fn replyFileDialog(gpa: std.mem.Allocator, surface_id: u64, token: u64, accept: bool) void {
    const s = surfaces.getPtr(surface_id) orelse return;
    const d = dialogPending(surface_id, token) orelse return;
    if (!d.kind.isFile()) return;
    const request = d.request;
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .file_dialog_reply = .{ .browser = surface_id, .request = request, .accept = accept } });
}

/// 권한 요청의 답(W5b). 허용·차단은 Chromium 이 출처별로 기억하고(프롬프트 — 미디어는 기억하지 않는다), 닫기·못 물음은
/// 기억하지 않는다. 답했으면 true — 권한 요청이 아니거나 이미 사라졌으면(이동·닫힘) false.
pub fn replyPermission(gpa: std.mem.Allocator, surface_id: u64, token: u64, result: ws.message.PermissionResult) bool {
    const s = surfaces.getPtr(surface_id) orelse return false;
    const d = dialogPending(surface_id, token) orelse return false;
    if (d.kind != .permission) return false;
    const request = d.request;
    removeDialog(gpa, s, token);
    if (s.created) send(gpa, .{ .permission_reply = .{ .browser = surface_id, .request = request, .result = result } });
    return true;
}

/// 창이 닫힌다 — 그 창이 띄운 요청은 취소로 답한다(다른 창이 다시 띄우지 않는다 — 탭도 그 창과 함께 사라진다).
pub fn cancelDialogsShownBy(gpa: std.mem.Allocator, window: usize) void {
    for (surfaces.keys(), surfaces.values()) |surface_id, *s| {
        var i: usize = 0;
        while (i < s.dialogs.items.len) {
            const d = s.dialogs.items[i];
            if (d.shown_by != window) {
                i += 1;
                continue;
            }
            // 권한은 「못 물음」 — 차단은 Chromium 이 그 사이트에 기억하고 닫기는 embargo 를 쌓는다(사용자가 고르지 않았다).
            if (d.kind.isFile()) replyFileDialog(gpa, surface_id, d.token, false) else if (d.kind == .permission) {
                _ = replyPermission(gpa, surface_id, d.token, .ignore);
            } else replyDialog(gpa, surface_id, d.token, d.kind == .before_unload, "", false);
        }
    }
}

// ── 안 ─────────────────────────────────────────────────────────────────────────────────────────────

fn freeSurface(gpa: std.mem.Allocator, s: *Surface) void {
    if (s.last_url) |u| gpa.free(u);
    if (s.url) |u| gpa.free(u);
    s.last_url = null;
    s.url = null;
    dropDialogs(gpa, s);
    s.dialogs.deinit(gpa);
}

/// 답을 기다리던 요청을 모두 버린다 — 답을 보내지 않는다(sidecar 가 죽었거나 브라우저가 사라져 콜백이 없다). 떠 있던
/// 창은 그 창의 tick 이 요청이 사라진 것을 보고 닫는다.
fn dropDialogs(gpa: std.mem.Allocator, s: *Surface) void {
    for (s.dialogs.items) |d| d.free(gpa);
    s.dialogs.clearRetainingCapacity();
}

fn installDir() ?[]const u8 {
    if (install_len > 0) return install_buf[0..install_len];
    return envDir();
}

/// `~/Library/Application Support/maru/web/<번들 ID>/profile` — 개발 빌드와 설치본이 갈리게(C7).
fn profileDir(buf: []u8) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    var id_buf: [256]u8 = undefined;
    const bundle = bundleIdentifier(&id_buf) orelse "dev.maru.unbundled";
    return std.fmt.bufPrint(buf, "{s}/Library/Application Support/maru/web/{s}/profile", .{ std.mem.span(home), bundle }) catch null;
}

extern "c" fn CFBundleGetMainBundle() ?*anyopaque;
extern "c" fn CFBundleGetIdentifier(bundle: *anyopaque) ?*anyopaque;
extern "c" fn CFStringGetCString(string: *anyopaque, buffer: [*]u8, size: isize, encoding: u32) u8;

fn bundleIdentifier(buf: []u8) ?[]const u8 {
    const bundle = CFBundleGetMainBundle() orelse return null;
    const id = CFBundleGetIdentifier(bundle) orelse return null;
    if (CFStringGetCString(id, buf.ptr, @intCast(buf.len), 0x0800_0100) == 0) return null; // kCFStringEncodingUTF8
    const s = std.mem.sliceTo(buf, 0);
    // 경로 조각으로 쓰므로 번들 ID 문자(영숫자·점·하이픈)만 받는다.
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
    return if (s.len == 0) null else s;
}

fn mkdirs(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        const z: [*:0]const u8 = @ptrCast(&buf);
        // 프로필과 그 위(maru/web/<번들 ID>)는 소유자 전용 — sidecar 가 프로필 권한을 검사한다(0700).
        if (std.c.mkdir(z, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return false;
    }
    return true;
}

fn start(gpa: std.mem.Allocator, now_ms: i64) void {
    const dir = installDir() orelse return fail(.start_failed);
    var host_buf: [std.fs.max_path_bytes]u8 = undefined;
    const host_path = std.fmt.bufPrint(&host_buf, "{s}/maru-web-host", .{dir}) catch return fail(.start_failed);
    var profile_buf: [std.fs.max_path_bytes]u8 = undefined;
    const profile = profileDir(&profile_buf) orelse return fail(.start_failed);
    if (!mkdirs(profile)) return fail(.start_failed);
    var arg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const arg = std.fmt.bufPrint(&arg_buf, "--profile-dir={s}", .{profile}) catch return fail(.start_failed);
    if (receiver == null) receiver = ring_receiver.Receiver.open() catch return fail(.start_failed);
    const spawned = lsp_process.spawn(gpa, host_path, &.{arg}, dir) catch return fail(.start_failed);
    process = spawned;
    // 새 sidecar 의 pid 만 받는다. pid 버전은 그 첫 알림에서 다시 고정한다(옛 sidecar 의 고정값은 버린다).
    receiver.?.expected_pid = spawned.pid;
    receiver.?.pinned_pid_version = null;
    decoder = .init(.to_maru);
    inbox.clearRetainingCapacity();
    state = .starting;
    started_ms = now_ms;
    process_generation += 1;
    arc4random_buf(@ptrCast(&hello_nonce), @sizeOf(u64));
    var frame: [ws.wire.max_frame_bytes]u8 = undefined;
    const len = ws.codec.encode(.{ .hello = .{ .instance = @intCast(std.c.getpid()), .nonce = hello_nonce } }, &frame) catch return fail(.start_failed);
    if (!(lsp_process.write(&process.?, gpa, frame[0..len]) catch false)) return crashed(gpa, now_ms);
}

fn monotonicNow() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// 마지막 브라우저가 사라졌다 — shutdown 을 보내고 기다리지 않는다(`reapRetiring` 이 거둔다). 이미 물러나는 옛
/// sidecar 가 있으면 그것은 바로 죽인다(둘을 쌓지 않는다).
fn retire(gpa: std.mem.Allocator, now_ms: i64) void {
    var p = process orelse {
        state = .off;
        return;
    };
    if (retiring) |*old| {
        lsp_process.kill(old, .KILL);
        lsp_process.reapBlocking(old);
        old.deinit(gpa);
    }
    var frame: [64]u8 = undefined;
    if (ws.codec.encode(.shutdown, &frame)) |len| {
        _ = lsp_process.write(&p, gpa, frame[0..len]) catch false;
    } else |_| {}
    retiring = p;
    retiring_since_ms = now_ms;
    process = null;
    state = .off;
    outbox_pending.clearRetainingCapacity();
}

fn reapRetiring(gpa: std.mem.Allocator, now_ms: i64) void {
    const p = if (retiring) |*p| p else return;
    _ = lsp_process.flush(p, gpa) catch {};
    if (!lsp_process.reapIfExited(p)) {
        if (now_ms - retiring_since_ms < shutdown_wait_ms) return;
        lsp_process.kill(p, .KILL);
        lsp_process.reapBlocking(p);
    }
    p.deinit(gpa);
    retiring = null;
}

fn stop(gpa: std.mem.Allocator) void {
    var p = process orelse {
        state = .off;
        return;
    };
    var frame: [64]u8 = undefined;
    if (ws.codec.encode(.shutdown, &frame)) |len| {
        _ = lsp_process.write(&p, gpa, frame[0..len]) catch false;
        _ = lsp_process.flush(&p, gpa) catch false;
    } else |_| {}
    // sidecar 는 열린 브라우저를 닫고 끝난다(감시견 10 초). 앱이 그만큼 멈추지 않게 짧게만 기다린 뒤 죽인다.
    var waited: i64 = 0;
    while (waited < shutdown_wait_ms and !lsp_process.reapIfExited(&p)) : (waited += 20) sleepMs(20);
    if (waited >= shutdown_wait_ms) {
        lsp_process.kill(&p, .KILL);
        lsp_process.reapBlocking(&p);
    }
    p.deinit(gpa);
    process = null;
    state = .off;
    outbox_pending.clearRetainingCapacity();
    var it = surfaces.iterator();
    while (it.next()) |entry| entry.value_ptr.created = false;
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;
extern "c" fn nanosleep(rqtp: *const std.c.timespec, rmtp: ?*std.c.timespec) c_int;

fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = nanosleep(&ts, null);
}

fn fail(notice: Notice) void {
    state = .failed;
    latched = notice;
    notice_queue.append(gpa_ref orelse return, notice) catch {};
}

/// sidecar 가 죽었다 — 예산 안이면 다시 띄워 살아 있던 브라우저를 되살린다.
fn crashed(gpa: std.mem.Allocator, now_ms: i64) void {
    if (process) |*p| {
        _ = lsp_process.reapIfExited(p);
        p.deinit(gpa);
    }
    process = null;
    state = .off;
    outbox_pending.clearRetainingCapacity();
    failures[failure_head] = now_ms;
    failure_head = (failure_head + 1) % restart_budget;
    var recent: usize = 0;
    for (failures) |at| {
        const t = at orelse continue;
        if (now_ms - t < restart_window_ms) recent += 1;
    }
    // 죽은 sidecar 가 쥐던 대화상자 콜백은 사라졌다 — 기다리던 요청을 버린다(떠 있는 창은 그 창이 닫는다).
    for (surfaces.values()) |*s| dropDialogs(gpa, s);
    if (recent >= restart_budget) return fail(.crashed_repeatedly);
    if (surfaces.count() == 0) return;
    // 모든 브라우저를 처음부터 다시 만든다(기록을 「안 만들어짐」으로 돌리고 create 를 다시 보낸다).
    start(gpa, now_ms);
    var it = surfaces.iterator();
    while (it.next()) |entry| {
        const s = entry.value_ptr;
        s.created = false;
        sendCommand(gpa, .{ .create = .{ .browser = entry.key_ptr.*, .size = s.record.size, .hidden = s.record.hidden } });
    }
}

/// 받는 port 에 쌓인 링 알림을 모두 받아 그 브라우저의 View 에 넘긴다. 모르는 브라우저의 링은 바로 놓는다.
fn receiveRings() void {
    const r = if (receiver) |*r| r else return;
    var budget: usize = 64; // 한 tick 에 받는 상한 — 누가 넘치게 넣어도 tick 이 붙잡히지 않게
    while (budget > 0) : (budget -= 1) {
        const received = (r.receive(0) catch return) orelse return;
        switch (received) {
            .rejected => rejected_rings += 1,
            .ring => |ring| {
                const app_ring: AppRing = .{ .generation = ring.generation, .control = @ptrFromInt(ring.control_address), .width = ring.width, .height = ring.height, .ring = ring };
                const s = surfaces.getPtr(ring.browser) orelse {
                    app_ring.release();
                    continue;
                };
                if (s.view.adopt(app_ring)) |never_drawn| never_drawn.release();
            },
        }
    }
}

fn sendCommand(gpa: std.mem.Allocator, command: plan.Command) void {
    switch (command) {
        .create => |c| send(gpa, .{ .create_browser = .{ .browser = c.browser, .size = c.size, .hidden = c.hidden, .url = "about:blank" } }),
        .resize => |c| send(gpa, .{ .resize = .{ .browser = c.browser, .size = c.size } }),
        .set_hidden => |c| send(gpa, .{ .set_hidden = .{ .browser = c.browser, .value = c.value } }),
    }
}

/// 보낸다 — handshake 전이면 쥐었다가 hello_ack 에 보낸다.
fn send(gpa: std.mem.Allocator, message: Message) void {
    var frame: [ws.wire.max_frame_bytes]u8 = undefined;
    const len = ws.codec.encode(message, &frame) catch return; // maru 가 만든 값이 codec 규칙을 어기면 보내지 않는다
    switch (state) {
        .starting => outbox_pending.appendSlice(gpa, frame[0..len]) catch {},
        .running => if (process) |*p| {
            _ = lsp_process.write(p, gpa, frame[0..len]) catch false;
        },
        .off, .failed => {},
    }
}

/// 받은 바이트를 decoder 에 넣고 frame 을 적용한다. decoder 는 가장 큰 frame 하나만큼만 받으므로(W1a) frame 을 비우며
/// 조금씩 넣는다. 적용 중 채널이 끝나거나 다시 띄워지면(`process_generation`) 곧바로 멈춘다 — 그때 inbox 는 비워졌다.
fn drainInbox(gpa: std.mem.Allocator, now_ms: i64) void {
    const generation = process_generation;
    var consumed: usize = 0;
    while (true) {
        while (decoder.next() catch return protocolBroken(gpa, now_ms)) |message| {
            apply(gpa, message, now_ms);
            if (process == null or process_generation != generation) return;
        }
        if (consumed == inbox.items.len) break;
        const fed = decoder.feed(inbox.items[consumed..]) catch return protocolBroken(gpa, now_ms);
        if (fed == 0) return protocolBroken(gpa, now_ms); // frame 을 비웠는데 한 바이트도 못 넣는다 — 불변식이 깨졌다
        consumed += fed;
    }
    inbox.clearRetainingCapacity();
}

fn protocolBroken(gpa: std.mem.Allocator, now_ms: i64) void {
    if (process) |*p| lsp_process.kill(p, .KILL);
    crashed(gpa, now_ms);
}

fn apply(gpa: std.mem.Allocator, message: Message, now_ms: i64) void {
    switch (message) {
        .hello_ack => |ack| {
            if (state != .starting or ack.nonce != hello_nonce) return protocolBroken(gpa, now_ms);
            state = .running;
            // 받는 port 이름과 토큰은 제어 채널로만 건넨다(C3). 브라우저 생성보다 먼저 — 첫 그리기부터 링을 알린다.
            if (receiver) |*r| send(gpa, .{ .frame_channel = .{ .service = r.serviceName(), .token = r.token } });
            if (process) |*p| _ = lsp_process.write(p, gpa, outbox_pending.items) catch false;
            outbox_pending.clearRetainingCapacity();
        },
        .browser_created => |id| if (surfaces.getPtr(id)) |s| {
            s.created = true;
            if (s.last_url) |u| send(gpa, .{ .navigate = .{ .browser = id, .url = u } });
            if (s.focused) send(gpa, .{ .set_focus = .{ .browser = id, .value = true } });
            s.composing = false;
        },
        .browser_closed => {},
        .url_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            const owned = gpa.dupe(u8, v.url) catch return;
            if (s.url) |old| gpa.free(old);
            s.url = owned;
            s.nav_dirty = true;
            // 다른 사이트로 옮기면 Chromium 이 렌더러를 바꾸고 새 렌더러는 포커스를 모른다 — 키는 닿아도 페이지 `focus`
            // 가 안 오고 입력기 조합이 버려졌다(W4c 실측). 포커스를 줘야 하는 탭이면 다시 준다.
            if (s.focused and s.created) send(gpa, .{ .set_focus = .{ .browser = v.browser, .value = true } });
            s.composing = false; // 이동하면 페이지의 조합은 사라진다
        },
        .nav_state => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.can_go_back = v.can_go_back;
            s.can_go_forward = v.can_go_forward;
            s.nav_dirty = true;
        },
        .failure => |f| switch (f.code) {
            .gpu_unavailable => if (surfaces.getPtr(f.browser)) |s| {
                s.gpu_notice_pending = true;
            },
            .profile_in_use => {
                // 다른 maru 가 같은 프로필을 쓴다 — 다시 띄워도 같다. 멈추고 안내한다.
                if (process) |*p| {
                    lsp_process.kill(p, .KILL);
                    lsp_process.reapBlocking(p);
                    p.deinit(gpa);
                }
                process = null;
                fail(.profile_in_use);
            },
            .cef_initialize_failed, .protocol_violation => protocolBroken(gpa, now_ms),
            .browser_create_failed, .unknown_browser, .duplicate_browser, .frame_channel_failed => {},
        },
        .title_changed, .load_finished, .renderer_gone => {},
        .cursor_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.cursor = v.cursor;
            s.cursor_generation +%= 1;
        },
        .ime_range => |v| if (surfaces.getPtr(v.browser)) |s| {
            s.ime_bounds = v.bounds;
        },
        .js_dialog => |v| {
            const kind: DialogKind = switch (v.kind) {
                .alert => .alert,
                .confirm => .confirm,
                .prompt => .prompt,
                .before_unload => .before_unload,
            };
            if (!queueDialog(gpa, v.browser, v.request, kind, v.origin, v.message, v.default_text, "", v.offer_suppress))
                send(gpa, .{ .dialog_reply = .{ .browser = v.browser, .request = v.request, .accept = kind == .before_unload } });
        },
        .file_dialog => |v| {
            const kind: DialogKind = switch (v.mode) {
                .open => .file_open,
                .open_multiple => .file_open_multiple,
                .open_folder => .file_open_folder,
                .save => .file_save,
            };
            if (!queueDialog(gpa, v.browser, v.request, kind, "", v.title, v.default_path, v.accept, false))
                send(gpa, .{ .file_dialog_reply = .{ .browser = v.browser, .request = v.request, .accept = false } });
        },
        // 받지 못하면(상한·모르는 탭) 「못 물음」으로 답한다 — 차단은 Chromium 이 기억하고 닫기는 embargo 를 쌓는다.
        .permission_request => |v| if (!queuePermission(gpa, v))
            send(gpa, .{ .permission_reply = .{ .browser = v.browser, .request = v.request, .result = .ignore } }),
        .dialog_closed => |v| if (surfaces.getPtr(v.browser)) |s| {
            for (s.dialogs.items) |d| if (d.request == v.request) {
                removeDialog(gpa, s, d.token);
                break;
            };
        },
        // 방향이 다른 tag 는 decoder 가 이미 거절했다.
        .hello, .create_browser, .destroy_browser, .resize, .set_hidden, .set_focus, .navigate, .shutdown, .frame_channel, .nav_action, .mouse, .wheel, .key, .ime_set_composition, .ime_commit_text, .ime_finish_composing, .ime_cancel_composition, .edit_command, .capture_lost, .dialog_reply, .file_dialog_path, .file_dialog_reply, .permission_reply => unreachable,
    }
}

/// 시험용 — 쌓인 frame(handshake 전 outbox)을 풀어 돌려준다.
fn sentFrames(out: []Message) usize {
    var n: usize = 0;
    var rest = outbox_pending.items;
    while (rest.len >= 4 and n < out.len) {
        const len = 4 + std.mem.readInt(u32, rest[0..4], .big);
        out[n] = ws.codec.decodeExact(rest[0..len]) catch unreachable;
        n += 1;
        rest = rest[len..];
    }
    return n;
}

test "dialogs queue per tab, show one at a time, and each answer goes out exactly once" {
    const gpa = std.testing.allocator;
    state = .starting; // 보낸 frame 을 outbox 에 쌓게(sidecar 없이)
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .alert, .origin = "https://a.b", .message = "하나" } }, 0);
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 2, .kind = .prompt, .origin = "", .message = "둘", .default_text = "기본" } }, 0);
    const first = nextDialog(7).?;
    try std.testing.expectEqual(@as(u32, 1), first.request);
    const first_token = first.token;
    // 떠 있는 동안 다음 요청은 나오지 않는다(한 탭에 하나씩).
    markDialogShown(7, first_token, 11);
    try std.testing.expect(nextDialog(7) == null);
    replyDialog(gpa, 7, first_token, true, "", false);
    replyDialog(gpa, 7, first_token, true, "", false); // 두 번째 답은 무동작
    const second = nextDialog(7).?;
    const second_token = second.token;
    try std.testing.expect(second_token != first_token);
    try std.testing.expectEqual(DialogKind.prompt, second.kind);
    try std.testing.expectEqualStrings("기본", second.default_text);
    // 페이지가 옮겨 가 요청이 사라지면 답을 보내지 않는다.
    apply(gpa, .{ .dialog_closed = .{ .browser = 7, .request = 2 } }, 0);
    try std.testing.expect(dialogPending(7, second_token) == null);
    // 상한을 넘은 요청은 곧바로 기본값으로 답한다(떠나기 확인은 떠나기).
    for (3..7) |r| apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = @intCast(r), .kind = .confirm, .origin = "", .message = "" } }, 0);
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 9, .kind = .before_unload, .origin = "", .message = "" } }, 0);
    for (surfaces.getPtr(7).?.dialogs.items) |d| try std.testing.expect(d.request != 9);
    // 모르는 탭의 요청도 곧바로 답한다(sidecar 가 콜백을 쥔 채 남지 않게).
    apply(gpa, .{ .file_dialog = .{ .browser = 99, .request = 10, .mode = .open } }, 0);
    // 창이 닫히면 그 창이 띄운 요청만 취소로 답한다.
    const third = nextDialog(7).?.token;
    const fourth = surfaces.getPtr(7).?.dialogs.items[1].token;
    markDialogShown(7, third, 11);
    cancelDialogsShownBy(gpa, 11);
    try std.testing.expect(dialogPending(7, third) == null);
    try std.testing.expect(dialogPending(7, fourth) != null);

    var frames: [16]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(frames[0].dialog_reply.request == 1 and frames[0].dialog_reply.accept);
    try std.testing.expect(frames[1].dialog_reply.request == 9 and frames[1].dialog_reply.accept);
    try std.testing.expect(frames[2].file_dialog_reply.request == 10 and !frames[2].file_dialog_reply.accept);
    try std.testing.expect(frames[3].dialog_reply.request == 3 and !frames[3].dialog_reply.accept);
}

test "permission requests share the dialog queue: one answer each, other answers cannot close them, a closing window dismisses" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 1, .origin = "https://meet.example", .media = 0b11 } }, 0);
    const asked = nextDialog(7).?;
    try std.testing.expectEqual(DialogKind.permission, asked.kind);
    try std.testing.expectEqual(@as(u8, 0b11), asked.permission_media);
    try std.testing.expectEqualStrings("https://meet.example", asked.origin);
    const token = asked.token;
    // JS 대화상자·파일 선택의 답은 권한 요청을 닫지 못한다.
    replyDialog(gpa, 7, token, true, "", false);
    replyFileDialog(gpa, 7, token, true);
    try std.testing.expect(dialogPending(7, token) != null);
    try std.testing.expect(replyPermission(gpa, 7, token, .accept));
    try std.testing.expect(!replyPermission(gpa, 7, token, .deny)); // 두 번째 답은 무동작
    try std.testing.expect(dialogPending(7, token) == null);
    // 권한 답은 대화상자를 닫지 못한다.
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 2, .kind = .confirm, .origin = "", .message = "" } }, 0);
    const confirm = nextDialog(7).?.token;
    try std.testing.expect(!replyPermission(gpa, 7, confirm, .accept));
    try std.testing.expect(dialogPending(7, confirm) != null);
    replyDialog(gpa, 7, confirm, false, "", false);
    // 창이 닫히면 그 창이 띄운 권한 요청은 「못 물음」으로(차단은 기억되고 닫기는 embargo 를 쌓는다), 상한을 넘은 요청·모르는
    // 탭도 「못 물음」으로.
    apply(gpa, .{ .permission_request = .{ .browser = 7, .request = 3, .origin = "", .kinds = ws.message.PermissionKind.notifications.bit() } }, 0);
    const notif = nextDialog(7).?;
    try std.testing.expectEqual(ws.message.PermissionKind.notifications.bit(), notif.permission_kinds);
    markDialogShown(7, notif.token, 11);
    cancelDialogsShownBy(gpa, 11);
    for (4..9) |r| apply(gpa, .{ .permission_request = .{ .browser = 7, .request = @intCast(r), .origin = "", .kinds = 1 } }, 0);
    apply(gpa, .{ .permission_request = .{ .browser = 99, .request = 10, .origin = "", .kinds = 1 } }, 0);
    // 페이지가 옮겨 가 요청이 사라지면 답을 보내지 않는다.
    apply(gpa, .{ .dialog_closed = .{ .browser = 7, .request = 4 } }, 0);

    var frames: [16]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(frames[0].permission_reply.request == 1 and frames[0].permission_reply.result == .accept);
    try std.testing.expect(frames[1].dialog_reply.request == 2 and !frames[1].dialog_reply.accept);
    try std.testing.expect(frames[2].permission_reply.request == 3 and frames[2].permission_reply.result == .ignore);
    try std.testing.expect(frames[3].permission_reply.request == 8 and frames[3].permission_reply.result == .ignore);
    try std.testing.expect(frames[4].permission_reply.request == 10 and frames[4].permission_reply.result == .ignore);
    try std.testing.expectEqual(@as(usize, 3), surfaces.getPtr(7).?.dialogs.items.len);
}

test "file chooser answers: bad paths are dropped, a JS answer cannot close a file request, crash drops everything" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .file_dialog = .{ .browser = 7, .request = 5, .mode = .open_multiple, .accept = ".png" } }, 0);
    const file = nextDialog(7).?;
    try std.testing.expectEqualStrings(".png", file.accept);
    const token = file.token;
    fileDialogPath(gpa, 7, token, "relative/a.png"); // 절대 경로가 아니다 — 버린다
    fileDialogPath(gpa, 7, token, "/a\nb"); // 제어 문자 — 버린다
    fileDialogPath(gpa, 7, token, "/tmp/a.png");
    replyDialog(gpa, 7, token, true, "", false); // JS 답은 파일 요청을 닫지 못한다
    try std.testing.expect(dialogPending(7, token) != null);
    replyFileDialog(gpa, 7, token, true);
    try std.testing.expect(dialogPending(7, token) == null);
    var frames: [8]Message = undefined;
    const n = sentFrames(&frames);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("/tmp/a.png", frames[0].file_dialog_path.path);
    try std.testing.expect(frames[1].file_dialog_reply.accept);
    // sidecar 가 죽으면 기다리던 요청은 답 없이 사라진다(콜백이 없다).
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 6, .kind = .alert, .origin = "", .message = "" } }, 0);
    const dropped = nextDialog(7).?.token;
    for (surfaces.values()) |*s| dropDialogs(gpa, s);
    try std.testing.expect(dialogPending(7, dropped) == null);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
    // 다시 뜬 sidecar 가 같은 요청 번호(6)로 새 요청을 보내도 옛 토큰의 답은 붙지 않는다.
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 6, .kind = .confirm, .origin = "", .message = "" } }, 0);
    replyDialog(gpa, 7, dropped, true, "", false);
    try std.testing.expect(nextDialog(7) != null);
    try std.testing.expectEqual(@as(usize, 2), sentFrames(&frames));
}

test "a prompt answer is trimmed to the dialog text rules instead of being dropped, and suppress rides along" {
    const gpa = std.testing.allocator;
    state = .starting;
    defer {
        for (surfaces.values()) |*s| freeSurface(gpa, s);
        surfaces.deinit(gpa);
        surfaces = .empty;
        outbox_pending.deinit(gpa);
        outbox_pending = .empty;
        state = .off;
    }
    try surfaces.put(gpa, 7, .{ .record = .{ .surface_id = 7, .size = .{ .width = 10, .height = 10, .scale = 1 }, .hidden = false }, .created = true });
    apply(gpa, .{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .prompt, .origin = "", .message = "", .offer_suppress = true } }, 0);
    const d = nextDialog(7).?;
    try std.testing.expect(d.offer_suppress);
    const long = "가" ** 2000; // 6000 바이트 — 상한(4 KiB)을 넘는다
    replyDialog(gpa, 7, d.token, true, long ++ "\x1b", true);
    var frames: [2]Message = undefined;
    try std.testing.expectEqual(@as(usize, 1), sentFrames(&frames));
    const r = frames[0].dialog_reply;
    try std.testing.expect(r.accept and r.suppress);
    try std.testing.expect(r.text.len > 4000 and r.text.len <= ws.wire.max_text_bytes);
    try std.testing.expect(std.mem.startsWith(u8, r.text, "가가가"));
}
