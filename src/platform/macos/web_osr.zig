//! 웹 OSR sidecar 관리(W3b, docs/plans/web-osr-backend.md) — 앱 하나에 `maru-web-host` 하나. 창들이 나눠 쓴다.
//!
//! **Zig 가 직접 띄운다**(사용자 결정 2026-09-24 — `lsp_process.zig` 선례): fork·execve 로 띄우고, 비차단 파이프를 창
//! tick 에서 비운다. Mermaid helper 는 Swift 가 띄우는데 그 이유(Security.framework 서명 검증)는 배포(W7) 때 필요하다.
//!
//! **켜는 법(W4 전까지 개발용)**: `MARU_WEB_OSR_DIR=<설치 디렉터리>` — `maru-web-host`·helper·프레임워크가 있는 곳
//! (`zig build web-sidecar` 의 `zig-out/web-sidecar`). 설정 키는 입력까지 되는 W4 에서 연다(사용자 결정).
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
};

pub const Cursor = struct { cursor: ws.message.WebCursor, generation: u32 };

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

/// OSR 백엔드가 켜져 있는가(개발용 환경변수).
pub fn enabled() bool {
    const dir = std.c.getenv("MARU_WEB_OSR_DIR") orelse return false;
    return std.mem.span(dir).len > 0;
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

/// 입력(W4b — 라우팅은 창이 정했다). 만들어졌고 sidecar 가 돌 때만 보낸다 — 입력은 쥐었다가 늦게 보낼 것이 아니다(첫 프레임
/// 전 입력은 렌더러도 버린다 — W4a 실측).
pub fn sendInput(gpa: std.mem.Allocator, message: Message) void {
    const browser: u64 = switch (message) {
        .mouse => |m| m.browser,
        .wheel => |m| m.browser,
        .key => |m| m.browser,
        .capture_lost => |b| b,
        else => return,
    };
    const s = surfaces.getPtr(browser) orelse return;
    if (!s.created or state != .running) return;
    send(gpa, message);
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

// ── 안 ─────────────────────────────────────────────────────────────────────────────────────────────

fn freeSurface(gpa: std.mem.Allocator, s: *Surface) void {
    if (s.last_url) |u| gpa.free(u);
    if (s.url) |u| gpa.free(u);
    s.last_url = null;
    s.url = null;
}

fn installDir() ?[]const u8 {
    const dir = std.c.getenv("MARU_WEB_OSR_DIR") orelse return null;
    const s = std.mem.span(dir);
    return if (s.len == 0) null else s;
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
        },
        .browser_closed => {},
        .url_changed => |v| if (surfaces.getPtr(v.browser)) |s| {
            const owned = gpa.dupe(u8, v.url) catch return;
            if (s.url) |old| gpa.free(old);
            s.url = owned;
            s.nav_dirty = true;
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
        // IME 후보창 위치는 키보드 라우팅(W4c)이 쓴다 — 그때까지 버린다.
        .ime_range => {},
        // 방향이 다른 tag 는 decoder 가 이미 거절했다.
        .hello, .create_browser, .destroy_browser, .resize, .set_hidden, .set_focus, .navigate, .shutdown, .frame_channel, .nav_action, .mouse, .wheel, .key, .ime_set_composition, .ime_commit_text, .ime_finish_composing, .ime_cancel_composition, .edit_command, .capture_lost => unreachable,
    }
}
