//! 턴 링 영속화의 **배선**(AT7 조각 3 — 계약 [§6.4](../../../../docs/agent-turn-changes.md)): 언제 쓰고(봉인·`markFiles`
//! 뒤), 언제 읽고(그 세션이 처음 말할 때 · 창을 열 때 «최근 세션»), 되살린 링의 tree 가 아직 있는지(비동기 git 러너의
//! `submitTreeCheck`), 언제 치우나(시작 때 7일 sweep). 저장소 규율은 `turn_store`, 바이트 모양은 `turn_persist`.
//!
//! **테스트에서는 기본으로 안 쓴다.** 판정자가 개발자의 `~/.cache/maru/turn-rings` 를 채우면 안 된다 — `test_allow_provider_writes`
//! 와 같은 게이트(`test_allow`).
const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const AppSession = @import("../app_session.zig").AppSession;
const turn_store = @import("turn_store.zig");
const git_ops = @import("git.zig");
const scm_dock_ops = @import("scm_dock.zig");
const git_backend_mod = @import("../git_backend.zig");
const turn_snapshot = maru.session.turn_snapshot;

pub var test_allow = false;

fn enabled() bool {
    return !builtin.is_test or test_allow;
}

/// `<cache>/` — `turn_store` 가 그 아래 `turn-rings/` 를 붙인다. 테스트는 `test_base` 로 격리한다.
pub var test_base: ?[]const u8 = null;

fn baseAlloc(self: *AppSession, a: std.mem.Allocator) ?[]const u8 {
    if (test_base) |b| return a.dupe(u8, b) catch null;
    _ = self;
    return AppSession.sessionCacheBase(a);
}

/// 그 세션의 링을 디스크에 쓴다 — 봉인 tick 과 `markFiles` 뒤에. 실패는 조용히(다음 봉인이 다시 쓴다) — 화면이 멈추면 안 된다.
pub fn persist(self: *AppSession, session_id: []const u8) void {
    if (!enabled()) return;
    if (session_id.len == 0) return;
    const entry = self.turn_rings.entry(session_id) orelse return;
    if (entry.ring.len == 0) return; // 빈 링은 적을 것이 없다(파일을 만들지 않는다)
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = baseAlloc(self, arena) orelse return;
    var refs: [turn_snapshot.capacity]maru.session.turn_persist.SealedRef = undefined;
    var n: usize = 0;
    var back: usize = 0;
    while (entry.ring.nth(back)) |snap| : (back += 1) {
        if (snap.capture_id == 0) continue;
        const turn = self.turn_captures.sealedTurn(snap.capture_id) orelse continue;
        refs[n] = .{ .id = snap.capture_id, .turn = turn };
        n += 1;
    }
    turn_store.save(self.io, self.allocator, base, entry, refs[0..n]) catch |err| {
        std.log.scoped(.agent).debug("turn ring persist failed: {s} ({s})", .{ session_id, @errorName(err) });
    };
}

/// tree 존재 확인이 걸린 세션(한 번에 하나 — 복원은 드물다). 결과가 오면 `expire` 하거나 그대로 둔다.
pub const PendingCheck = struct {
    id: [turn_snapshot.max_session_id_len]u8 = undefined,
    len: usize = 0,
    submitted: bool = false,
    /// 낼 때의 링 머리(가장 최근 tree). 답이 왔을 때 링이 그대로인지 보는 잣대 — 그 사이 저장소가 바뀌어 링이 비었거나 새 턴이
    /// 쌓였으면 그 답은 **옛 링에 대한 것**이라 적용하지 않고 다시 묻는다(적대적 3회차 R3b: 옛 저장소의 tree 를 새 저장소에 물어
    /// «없다» 가 오면 멀쩡한 새 링을 접었다).
    latest: [turn_snapshot.max_oid_len]u8 = undefined,
    latest_len: usize = 0,

    pub fn sessionId(self: *const PendingCheck) []const u8 {
        return self.id[0..self.len];
    }

    pub fn latestOid(self: *const PendingCheck) []const u8 {
        return self.latest[0..self.latest_len];
    }
};

/// 디스크에 그 세션의 기록이 있으면 링·사본을 되살린다. 이미 메모리에 있으면 아무것도 안 한다. 되살렸으면 tree 확인을 건다.
/// 돌려주는 값: 되살렸는가.
pub fn maybeRestore(self: *AppSession, session_id: []const u8) bool {
    if (!enabled()) return false;
    if (session_id.len == 0 or self.turn_rings.find(session_id) != null) return false;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = baseAlloc(self, arena) orelse return false;
    var m = turn_store.load(self.io, self.allocator, base, session_id) orelse return false;
    defer m.deinit(self.allocator);
    const entry = turn_store.restore(self.io, self.allocator, base, &m, &self.turn_captures) orelse return false;
    if (!self.turn_rings.adopt(entry)) {
        // 그 사이 생겼다(경합) — 들인 사본은 다음 sweep 이 도달성으로 걷는다.
        return false;
    }
    // tree 가 아직 있는지는 git 에 묻는다(§6.3). 결과가 올 때까지는 보인다 — 없으면 그때 통째로 접는다.
    queueTreeCheck(self, session_id);
    self.metal_dirty = true;
    return true;
}

fn queueTreeCheck(self: *AppSession, session_id: []const u8) void {
    if (session_id.len > turn_snapshot.max_session_id_len) return;
    for (&self.turn_tree_checks) |*c| {
        if (c.len != 0 and std.mem.eql(u8, c.sessionId(), session_id)) return;
    }
    for (&self.turn_tree_checks) |*c| {
        if (c.len != 0) continue;
        @memcpy(c.id[0..session_id.len], session_id);
        c.len = session_id.len;
        c.submitted = false;
        return;
    }
    // 자리가 없다(동시에 8 세션이 되살아나는 일은 없다) — 확인 없이 둔다. 못 읽는 tree 는 목록 읽기가 실패로 적는다.
}

/// 매 tick: 걸린 확인을 하나 내고, 온 결과를 적용한다. git 러너의 다른 결과와 같은 자리에서 부른다.
pub fn pump(self: *AppSession) void {
    if (!enabled()) return;
    const backend: *git_backend_mod.Backend = if (self.git_backend) |*b| b else return;
    while (backend.takeTreeCheckResult()) |res| {
        const sid = res.sessionId();
        var stale_answer = false;
        for (&self.turn_tree_checks) |*c| {
            if (c.len == 0 or !std.mem.eql(u8, c.sessionId(), sid)) continue;
            const now_latest: []const u8 = if (self.turn_rings.find(sid)) |r| (if (r.latest()) |l| l.oid() else "") else "";
            if (!std.mem.eql(u8, now_latest, c.latestOid())) {
                // 링이 그 사이 바뀌었다 — 이 답은 옛 링의 것. 지금 링으로 다시 묻는다(비었으면 물을 것도 없다).
                stale_answer = true;
                if (now_latest.len == 0) c.* = .{} else c.submitted = false;
            } else c.* = .{};
        }
        if (res.ok or stale_answer) continue;
        // **하나라도 없다** → 세션 통째로(사용자 결정). 화면은 «오래되어 사라졌다» 로 말한다.
        self.turn_rings.expire(sid);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        if (baseAlloc(self, arena_state.allocator())) |base| turn_store.discardSession(self.io, self.allocator, base, sid);
        git_ops.sweepTurnCaptures(self);
        self.metal_dirty = true;
    }
    for (&self.turn_tree_checks) |*c| {
        if (c.len == 0 or c.submitted) continue;
        const sid = c.sessionId();
        const ring = self.turn_rings.find(sid) orelse {
            c.* = .{};
            continue;
        };
        var trees_buf: [turn_snapshot.capacity * (turn_snapshot.max_oid_len + 1)]u8 = undefined;
        var w: std.Io.Writer = .fixed(&trees_buf);
        var back: usize = 0;
        while (ring.nth(back)) |snap| : (back += 1) {
            if (back != 0) w.writeByte(' ') catch break;
            w.writeAll(snap.oid()) catch break;
        }
        const trees = w.buffered();
        if (trees.len == 0) {
            c.* = .{};
            continue;
        }
        const latest = ring.latest().?.oid();
        @memcpy(c.latest[0..latest.len], latest);
        c.latest_len = latest.len;
        var ctl_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = switch (scm_dock_ops.turnReadTarget(self, sid, &ctl_buf)) {
            .read => |t| t,
            // 갈 데가 없다(원격 소켓 없음·로컬 링 + 원격 목록) — 다음 tick 에 다시. 되살린 링은 그동안 보인다.
            .unavailable => continue,
        };
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const git_exe = if (target.remote != null) maru.session.git_command.remote_git_exe else git_backend_mod.locate(&exe_buf) orelse continue;
        if (backend.submitTreeCheck(git_exe, target.repo, trees, sid, target.remote)) {
            c.submitted = true;
            return; // 슬롯 하나 — 다음 것은 결과가 온 뒤
        }
    }
}

/// 창을 열 때: «최근 세션» 을 미리 되살리고(첫 이벤트 전에도 에이전트 탭이 서게), 7일 넘은 디렉터리를 치운다.
pub fn onWindowRestored(self: *AppSession) void {
    if (!enabled()) return;
    if (self.last_agent_session) |sid| _ = maybeRestore(self, sid);
    if (self.turn_rings_swept) return;
    self.turn_rings_swept = true;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const base = baseAlloc(self, arena_state.allocator()) orelse return;
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
    _ = turn_store.sweepStale(self.io, base, now_s);
}
