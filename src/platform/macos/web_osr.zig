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

const ws = maru.session.web_sidecar;
const plan = maru.session.web_osr_plan;
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
};

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
    for (commands.items) |command| sendCommand(gpa, command);
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

/// Term 이 사라졌다 — 브라우저를 파괴한다. 마지막이면 sidecar 도 내린다.
pub fn destroy(gpa: std.mem.Allocator, surface_id: u64) void {
    var kv = surfaces.fetchSwapRemove(surface_id) orelse return;
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
    // 비우는 사이 sidecar 가 끝났거나(`profile_in_use` 로 멈춤) 다시 떴다 — 위의 `read`·`p` 는 옛 프로세스의 것이다.
    // 처음엔 그대로 이어가 옛 EOF 로 새 sidecar 를 또 죽은 것으로 세거나, 비운 optional 을 읽었다(적대 점검).
    if (process == null or process_generation != generation) return;
    if (read == .eof or lsp_process.reapIfExited(&process.?)) return crashed(gpa, now_ms);
    if (state == .starting and now_ms - started_ms > handshake_timeout_ms) {
        lsp_process.kill(&process.?, .KILL);
        return crashed(gpa, now_ms);
    }
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
    while (it.next()) |entry| freeSurface(gpa, entry.value_ptr);
    surfaces.deinit(gpa);
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
    const spawned = lsp_process.spawn(gpa, host_path, &.{arg}, dir) catch return fail(.start_failed);
    process = spawned;
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
        // 방향이 다른 tag 는 decoder 가 이미 거절했다.
        .hello, .create_browser, .destroy_browser, .resize, .set_hidden, .set_focus, .navigate, .shutdown, .frame_channel, .nav_action => unreachable,
    }
}
