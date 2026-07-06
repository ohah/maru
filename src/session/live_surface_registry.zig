//! LiveSurfaceRegistry — 앱 전역 live surface **런타임 소유자**(주소 안정 heap). M2(docs/window-surface-mobility.md §3·§8 M2a).
//!
//! `WindowGraph`(M1)가 "어떤 window/pane 위치에 어떤 surface_ref가 보이는지"의 **순수 배치**만 든다면,
//! `LiveSurfaceRegistry`는 그 surface들의 **라이브 런타임**(PTY reader/pump·TerminalCore·후일 web panel/WKWebView 핸들)을
//! **소유**한다(§3). 소유가 window 밖(앱 전역 registry)에 있으므로, `WindowGraph`가 surface를 pane/workspace/window 간
//! 재배치해도(surface_id는 불변) 런타임 인스턴스는 **재시작·재생성되지 않는다** — registry는 surface_id로 keyed돼 있어
//! 이동이 registry를 건드리지 않는다. 이것이 M2의 핵심 불변식이다(§8·§9 "이동은 surface runtime을 재시작하지 않는다").
//!
//! **주소 안정성(reader thread 계약)**: `LivePtySession`은 embedded `reader` 필드를 들고, reader thread가 `&rt.reader`를
//! 잡아 실행되므로 그 값은 start 후 **절대 이동하면 안 된다**(src/app/live_pty.zig init 불변식). 현재 production은
//! heap-pin `*Term` 안에 `live_pty`를 inline으로 둬 이 주소를 고정한다. registry가 소유자가 되면 **같은 메커니즘**으로
//! 고정한다 — 각 런타임을 `allocator.create(Rt)`로 **개별 heap 슬롯**에 두고 entries 배열엔 `*Rt` 포인터만 담는다.
//! entries ArrayList가 realloc돼도 옮겨지는 건 `Entry`(포인터 값)뿐이고 `*Rt`가 가리키는 런타임 본체는 안 움직인다.
//!
//! **레이어(§3·§57)**: 이 파일은 런타임 부착 타입 `Rt`로 generic화한 **L2 골격**이다(`session_model.Model(Rt)`·
//! `SplitTree(Leaf)` 선례). 골격은 PTY/WKWebView 핸들을 모른 채 소유·수명만 관리한다. §57이 registry를 "L4 platform"
//! 이라 한 것은 실제 `LivePtySession`/WKWebView 핸들로 **인스턴스화**한 registry를 가리킨다 — `Model(TermRuntime)`을
//! platform이 인스턴스화하는 것과 같은 분리. 그 production 배선(Term-inline 소유 → registry 소유)은 M2b다(§8 M2b).
//!
//! **범위(M2a, 이 골격만)**: 소유(create)·조회(findBySurface)·수명(remove·deinit)·generation 보존·주소 안정성 +
//! `WindowGraph` 이동 결합 정합. **범위 밖**: production `app_session` 배선(M2b), Surface/TerminalCore를 Term 밖으로
//! 빼는 대수술(M3+), generation **증가/respawn 정책 신규 도입**(M1 후속 — 여기선 §3의 키 필드로 **보존**만 하고
//! 증가시키지 않는다), web runtime 합류(Phase 4). 기존 `src/app/live_pty_registry.zig`는 **비소유** close-index
//! (surface_id→live PTY 포인터, close command 라우팅용, 현재 smoke/test 전용)로 별개 역할이다 — 소유자(이 파일)와
//! 상보적이라 통합/재배선은 M2b가 한다.
//!
//! **스레드**: 메인 스레드 전용(세션 트리·surface_id.zig 계약과 동일). L2 순수라 런타임 assert 대신 주석으로 고정한다.

const std = @import("std");

/// 런타임 소유 registry 생성자 — 런타임 부착 타입 `Rt`로 parametrize한다(`session_model.Model(Rt)` 선례).
/// platform이 실제 `LivePtySession`(+ 후일 web runtime)으로 인스턴스화한다(M2b). `Rt`는 자기 자원을 스스로 정리하는
/// `deinit(*Rt) void`를 제공해야 한다(`LivePtySession.deinit` 계약과 동일 — reader join·fd/queue 해제를 자체 소유).
pub fn LiveSurfaceRegistry(comptime Rt: type) type {
    return struct {
        const Self = @This();

        /// register/remove 실패. `SurfaceAlreadyRegistered`=같은 surface_id 중복(M0a 비재사용 계약 위반).
        /// `SurfaceNotRegistered`=없는 surface 제거/조회. 할당 실패는 create의 heap 확보에서만 날 수 있다.
        pub const Error = error{ SurfaceAlreadyRegistered, SurfaceNotRegistered } || std.mem.Allocator.Error;

        /// registry entry. `runtime`은 registry가 소유하는 heap 슬롯(`allocator.create(Rt)`) — 주소 안정.
        /// 키는 `surface_id`(전역 유일·비재사용, M0a)이고 `generation`은 §3의 보조 키 필드(respawn 구분용, M2a는 보존만).
        pub const Entry = struct {
            surface_id: u64,
            generation: u64,
            runtime: *Rt,
        };

        allocator: std.mem.Allocator,
        /// 소유 런타임 목록. `Entry`(포인터 값)만 realloc로 이동하고 `*Rt` 본체는 절대 안 움직인다(주소 안정).
        entries: std.ArrayList(Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// registry가 소유한 모든 런타임을 teardown(`Rt.deinit`)하고 heap 슬롯을 해제한 뒤 entries 배열을 정리한다.
        /// 계약: create로 받은 슬롯은 registry teardown 전에 caller가 in-place init을 마친 상태여야 한다
        /// (uninit 슬롯에 deinit=UB — production의 init-실패 errdefer 경로 처리는 M2b가 배선하며 정한다).
        pub fn deinit(self: *Self) void {
            for (self.entries.items) |entry| {
                entry.runtime.deinit();
                self.allocator.destroy(entry.runtime);
            }
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        /// surface_id로 런타임을 **heap 슬롯에 개별 할당해 소유**하고, caller가 in-place로 init할 안정 `*Rt`를 돌려준다
        /// (`var live: LivePtySession = undefined; live.init(&live, ...)`와 같은 결 — 반환 포인터에 대고 init).
        /// 반환 포인터는 registry가 소유하는 동안 절대 이동하지 않으므로 reader thread가 `&rt.reader`를 잡아도 안전하다.
        /// 중복 surface_id는 거부한다(M0a 비재사용 — 하나의 surface가 두 런타임에 매핑되는 구조적 버그 차단).
        /// generation은 §3의 키 필드로 그대로 저장한다(M2a는 보존만, 증가 정책 없음).
        pub fn create(self: *Self, surface_id: u64, generation: u64) Error!*Rt {
            if (self.indexOf(surface_id) != null) return error.SurfaceAlreadyRegistered;
            const rt = try self.allocator.create(Rt);
            errdefer self.allocator.destroy(rt);
            // append(fallible)가 실패하면 errdefer가 rt를 해제한다 — 슬롯 유실/leak 없이 registry 불변.
            try self.entries.append(self.allocator, .{
                .surface_id = surface_id,
                .generation = generation,
                .runtime = rt,
            });
            return rt;
        }

        /// surface_id에 소유된 런타임 `*Rt`(안정 포인터). 없으면 null. **이동 후에도 같은 surface_id면 같은 포인터**를
        /// 돌려준다 — registry는 surface_id로 keyed돼 있어 `WindowGraph` 재배치가 이 매핑을 건드리지 않는다(M2 불변식).
        pub fn findBySurface(self: *const Self, surface_id: u64) ?*Rt {
            if (self.indexOf(surface_id)) |i| return self.entries.items[i].runtime;
            return null;
        }

        /// surface_id의 generation(§3 보조 키). 없으면 null. 이동은 이 값을 보존한다(respawn만 증가 — M1 후속 범위).
        pub fn generationOf(self: *const Self, surface_id: u64) ?u64 {
            if (self.indexOf(surface_id)) |i| return self.entries.items[i].generation;
            return null;
        }

        /// 소유 중인 런타임 수.
        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// surface를 registry에서 제거하고 소유 런타임을 teardown(`Rt.deinit`)·해제한다. surface close 경로가 부른다
        /// (`WindowGraph`에서 surface_ref가 사라질 때 L4 coordinator가 호출). 없는 surface면 `SurfaceNotRegistered`.
        /// 다른 엔트리의 `*Rt` 포인터는 orderedRemove가 `Entry` 값만 옮기므로 불변이다(런타임 본체는 안 움직임).
        pub fn remove(self: *Self, surface_id: u64) Error!void {
            const idx = self.indexOf(surface_id) orelse return error.SurfaceNotRegistered;
            const entry = self.entries.orderedRemove(idx);
            entry.runtime.deinit();
            self.allocator.destroy(entry.runtime);
        }

        fn indexOf(self: *const Self, surface_id: u64) ?usize {
            for (self.entries.items, 0..) |entry, i| {
                if (entry.surface_id == surface_id) return i;
            }
            return null;
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════════════════════════════════
//   테스트 — 헤드리스. 실제 PTY/Swift 없이 fake 런타임으로 소유·수명·주소 안정성·이동 identity 보존을 못박는다.
//   fake 런타임은 `LivePtySession`(PTY-side identity=pty_id·embedded reader=reader_pin)과 `Surface`의
//   `TerminalCore`(scrollback 상태)를 한 번들로 흉내낸다 — M2 registry가 그 번들을 소유하기 때문이다(§3).
// ══════════════════════════════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

/// 테스트용 fake surface 런타임 — registry가 소유·수명 관리하는 대상. 실제 `LivePtySession`+`Surface`(TerminalCore)를
/// 흉내낸다: `pty_id`=identity, `reader_pin`=reader thread가 잡을 embedded 필드(주소 불변이어야 함), `scrollback`=
/// TerminalCore 상태(이동이 보존해야 함), `inits`=이 인스턴스가 제자리 init된 횟수(정상이면 1 — 재시작=별 인스턴스).
const FakeRuntime = struct {
    allocator: std.mem.Allocator = undefined,
    pty_id: u64 = 0,
    reader_pin: u32 = 0,
    scrollback: std.ArrayList([]const u8) = .empty,
    inits: u32 = 0,

    fn init(self: *FakeRuntime, allocator: std.mem.Allocator, pty_id: u64) void {
        self.* = .{ .allocator = allocator, .pty_id = pty_id, .inits = 1 };
    }

    fn push(self: *FakeRuntime, line: []const u8) !void {
        try self.scrollback.append(self.allocator, line);
    }

    fn deinit(self: *FakeRuntime) void {
        self.scrollback.deinit(self.allocator);
        self.* = undefined;
    }
};

const Registry = LiveSurfaceRegistry(FakeRuntime);

/// create + 즉시 in-place init하는 테스트 헬퍼(production createTerm 패턴 — 슬롯 확보 후 그 자리에 init).
fn spawn(reg: *Registry, allocator: std.mem.Allocator, surface_id: u64, generation: u64, pty_id: u64) !*FakeRuntime {
    const rt = try reg.create(surface_id, generation);
    rt.init(allocator, pty_id);
    return rt;
}

test "create/findBySurface/count: 단일 소유 happy path" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 0), reg.count());
    const rt = try spawn(&reg, allocator, 100, 0, 100);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqual(rt, reg.findBySurface(100).?); // 같은 포인터
    try testing.expectEqual(@as(u64, 100), reg.findBySurface(100).?.pty_id);
    try testing.expectEqual(@as(u32, 1), rt.inits); // 정확히 한 번 init
    try testing.expect(reg.findBySurface(999) == null); // 없는 surface
}

// ── 주소 안정성(reader thread 계약, headline red→green) ────────────────────────────────────────────────────
// entries ArrayList가 realloc돼도 먼저 등록한 런타임의 `*Rt`가 불변이어야 reader thread가 잡는 `&rt.reader`
// (여기선 `&rt.reader_pin`)가 안 흔들린다. 구현이 런타임을 heap 슬롯이 아니라 배열에 by-value로 두면 이 단언이
// 실패한다(realloc가 본체를 옮김) — 그 회귀를 이 테스트가 잡는다는 게 non-vacuous의 증거다.
test "주소 안정성: ArrayList realloc에도 소유 런타임 *Rt·embedded 필드 주소가 불변" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const first = try spawn(&reg, allocator, 1, 0, 1);
    try first.push("scrollback line A");
    const pin_addr = &first.reader_pin; // reader thread가 잡을 embedded 필드 주소

    // 많은 surface를 더 등록해 entries 배열의 realloc을 강제한다(초기 cap을 확실히 넘긴다).
    var i: u64 = 2;
    while (i <= 64) : (i += 1) _ = try spawn(&reg, allocator, i, 0, i);

    // realloc가 여러 번 일어난 뒤에도: 같은 `*Rt`, 같은 embedded 주소, scrollback 상태 보존.
    try testing.expectEqual(first, reg.findBySurface(1).?);
    try testing.expectEqual(pin_addr, &reg.findBySurface(1).?.reader_pin);
    try testing.expectEqual(@as(usize, 1), first.scrollback.items.len);
    try testing.expectEqualStrings("scrollback line A", first.scrollback.items[0]);
    try testing.expectEqual(@as(usize, 64), reg.count());
}

test "중복 등록 거부: 같은 surface_id 두 번째 create는 SurfaceAlreadyRegistered + 기존 인스턴스 불변" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    const rt = try spawn(&reg, allocator, 7, 0, 7);
    try rt.push("keep me");
    try testing.expectError(error.SurfaceAlreadyRegistered, reg.create(7, 1));
    // 거부는 기존 소유를 건드리지 않는다(포인터·상태·count 불변).
    try testing.expectEqual(rt, reg.findBySurface(7).?);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqualStrings("keep me", reg.findBySurface(7).?.scrollback.items[0]);
}

test "없는 surface 제거: SurfaceNotRegistered(빈 registry + 미등록 id 둘 다)" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    try testing.expectError(error.SurfaceNotRegistered, reg.remove(1)); // 빈 registry
    _ = try spawn(&reg, allocator, 10, 0, 10);
    try testing.expectError(error.SurfaceNotRegistered, reg.remove(11)); // 등록된 것과 다른 id
    try testing.expectEqual(@as(usize, 1), reg.count()); // 실패가 기존을 안 건드림
}

test "close 제거: remove는 매핑을 지우고 런타임을 teardown, 타 엔트리는 불변" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    _ = try spawn(&reg, allocator, 1, 0, 1);
    const keep = try spawn(&reg, allocator, 2, 0, 2);
    try keep.push("survivor");
    _ = try spawn(&reg, allocator, 3, 0, 3);

    try reg.remove(1);
    try testing.expect(reg.findBySurface(1) == null); // 닫힌 surface는 조회 안 됨
    try testing.expectEqual(@as(usize, 2), reg.count());
    // 남은 엔트리(2·3)는 포인터·상태 불변(orderedRemove가 Entry 값만 옮김, 런타임 본체는 그대로).
    try testing.expectEqual(keep, reg.findBySurface(2).?);
    try testing.expectEqualStrings("survivor", reg.findBySurface(2).?.scrollback.items[0]);
    try testing.expect(reg.findBySurface(3) != null);
}

test "빈 registry: 모든 조회가 null/err, count 0" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    try testing.expectEqual(@as(usize, 0), reg.count());
    try testing.expect(reg.findBySurface(1) == null);
    try testing.expect(reg.generationOf(1) == null);
    try testing.expectError(error.SurfaceNotRegistered, reg.remove(1));
}

test "다중 등록 + 중간 제거: 나머지 엔트리의 포인터·generation이 흔들리지 않는다" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // 5개 등록, 각기 다른 generation.
    var ptrs: [5]*FakeRuntime = undefined;
    const gens: [5]u64 = .{ 10, 11, 12, 13, 14 };
    for (0..5) |k| ptrs[k] = try spawn(&reg, allocator, @as(u64, k + 1), gens[k], @as(u64, (k + 1) * 100));

    // 가운데(surface 3, index 2)를 제거.
    try reg.remove(3);
    try testing.expectEqual(@as(usize, 4), reg.count());
    try testing.expect(reg.findBySurface(3) == null);

    // 남은 넷은 포인터·pty_id·generation 전부 불변.
    const survivors = [_]struct { sid: u64, k: usize }{
        .{ .sid = 1, .k = 0 }, .{ .sid = 2, .k = 1 }, .{ .sid = 4, .k = 3 }, .{ .sid = 5, .k = 4 },
    };
    for (survivors) |s| {
        try testing.expectEqual(ptrs[s.k], reg.findBySurface(s.sid).?);
        try testing.expectEqual(@as(u64, (s.k + 1) * 100), reg.findBySurface(s.sid).?.pty_id);
        try testing.expectEqual(gens[s.k], reg.generationOf(s.sid).?);
    }
}

test "generation 보존·조회: create 시 값 저장, 이후 조회로 그대로 반환(증가 없음)" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    _ = try spawn(&reg, allocator, 42, 7, 42);
    try testing.expectEqual(@as(u64, 7), reg.generationOf(42).?);
    // 다른 surface를 더 등록해도(realloc) 원래 generation 불변.
    _ = try spawn(&reg, allocator, 43, 99, 43);
    try testing.expectEqual(@as(u64, 7), reg.generationOf(42).?);
    try testing.expectEqual(@as(u64, 99), reg.generationOf(43).?);
}

test "create OOM: append 실패 시 errdefer가 슬롯을 해제해 leak·유실 없이 registry 불변" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    defer reg.deinit();

    // 빈 registry에 create: allocator.create(Rt)=alloc#0(통과), 첫 append가 반드시 alloc#1(빈 리스트라 확정)→OOM.
    // create의 errdefer가 rt를 해제하므로 leak이 없어야 한다(있으면 testing.allocator가 실패시킨다).
    var fail = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    reg.allocator = fail.allocator();
    try testing.expectError(error.OutOfMemory, reg.create(2, 0));
    reg.allocator = allocator; // deinit 복구

    try testing.expectEqual(@as(usize, 0), reg.count()); // 부분 상태 없음
    try testing.expect(reg.findBySurface(2) == null);
}

test "deinit: 여러 소유 런타임을 누수 없이 teardown(testing.allocator가 검증)" {
    const allocator = testing.allocator;
    var reg = Registry.init(allocator);
    var i: u64 = 1;
    while (i <= 6) : (i += 1) {
        const rt = try spawn(&reg, allocator, i, 0, i);
        try rt.push("line1");
        try rt.push("line2"); // scrollback heap 버퍼 — deinit이 놓치면 leak
    }
    reg.deinit(); // 각 런타임 deinit(scrollback free) + 슬롯 free + entries free. leak이면 testing.allocator 실패.
}

// ── WindowGraph(M1) 결합: 재배치가 런타임 identity를 보존한다(재시작 0) ─────────────────────────────────────
// M2의 핵심 불변식. 그래프가 surface_ref를 창 간 옮겨도 surface_id는 불변이라 registry 매핑이 그대로고,
// 따라서 런타임 인스턴스(포인터)·TerminalCore 상태(scrollback)가 보존되며 재init(재시작)이 일어나지 않는다.

test "WindowGraph cross-window 이동: 소유 런타임 identity·scrollback 보존, 재시작 0회" {
    const window_graph = @import("window_graph.zig");
    const allocator = testing.allocator;

    var reg = Registry.init(allocator);
    defer reg.deinit();
    var g = window_graph.WindowGraph.init(allocator);
    defer g.deinit();

    // window0에 surface S=500(이동 대상) + 501(resident — 이동 후 win0가 empty-정리로 사라지지 않게 남겨둠).
    // window1엔 빈 pane(수신처). registry는 이동 대상 500의 런타임만 소유(포인터 P, scrollback 2줄).
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws1);
    try g.addSurface(p0, 500); // index 0 = 이동 대상
    try g.addSurface(p0, 501); // resident

    const p_before = try spawn(&reg, allocator, 500, 3, 500);
    try p_before.push("history 1");
    try p_before.push("history 2");

    // window0 → window1로 surface 500 이동(cross-window). 그래프만 바뀌고 registry는 안 건드린다.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 });
    _ = p1;

    // 이동 후: 같은 런타임 포인터(재생성 아님), scrollback 보존, inits==1(재시작 없음), generation 보존.
    const p_after = reg.findBySurface(500).?;
    try testing.expectEqual(p_before, p_after);
    try testing.expectEqual(@as(u32, 1), p_after.inits); // 제자리 재init 없음 = 재시작 0
    try testing.expectEqual(@as(usize, 2), p_after.scrollback.items.len);
    try testing.expectEqualStrings("history 1", p_after.scrollback.items[0]);
    try testing.expectEqualStrings("history 2", p_after.scrollback.items[1]);
    try testing.expectEqual(@as(u64, 3), reg.generationOf(500).?); // 이동은 generation 안 올림

    // 그래프 배치는 실제로 500이 window1로 옮겨졌다(비-vacuous: 이동이 진짜 일어남). win0엔 resident 501만 남는다.
    var buf0: [4]u64 = undefined;
    var buf1: [4]u64 = undefined;
    const w0_ids = try g.collectWindowSurfaceIds(0, &buf0);
    try testing.expectEqual(@as(usize, 1), w0_ids.len);
    try testing.expectEqual(@as(u64, 501), w0_ids[0]);
    const w1_ids = try g.collectWindowSurfaceIds(1, &buf1);
    try testing.expectEqual(@as(usize, 1), w1_ids.len);
    try testing.expectEqual(@as(u64, 500), w1_ids[0]);
}

test "WindowGraph 왕복 이동: A→B→A 이후에도 같은 런타임 인스턴스·상태" {
    const window_graph = @import("window_graph.zig");
    const allocator = testing.allocator;

    var reg = Registry.init(allocator);
    defer reg.deinit();
    var g = window_graph.WindowGraph.init(allocator);
    defer g.deinit();

    // 각 창에 resident surface를 둬서 왕복 내내 두 창이 비지 않게 한다(empty-정리로 창이 사라지면 포인터 재사용 불가).
    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws1);
    try g.addSurface(p0, 900); // 이동 대상(win0 index 0)
    try g.addSurface(p0, 901); // win0 resident
    try g.addSurface(p1, 902); // win1 resident

    const p = try spawn(&reg, allocator, 900, 0, 900);
    try p.push("stable");

    // A(win0)→B(win1): win0 index 0(=900)을 win1 pane 0으로. win0엔 901 남아 창 유지.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 });
    try testing.expectEqual(p, reg.findBySurface(900).?); // 여전히 같은 인스턴스

    // B→A로 되돌린다: win1엔 이제 {902, 900} — 900은 index 1. 그걸 win0 pane 0으로.
    try g.moveSurface(.{ .win = 1, .ws = 0, .pane = 0, .surface = 1 }, .{ .win = 0, .ws = 0, .pane = 0 });

    // 왕복 후에도 동일 포인터·상태·재시작 0.
    const back = reg.findBySurface(900).?;
    try testing.expectEqual(p, back);
    try testing.expectEqual(@as(u32, 1), back.inits);
    try testing.expectEqualStrings("stable", back.scrollback.items[0]);
    // 그래프상 900은 win0로 복귀(win0={901,900}, win1={902}).
    var buf: [4]u64 = undefined;
    const w0_ids = try g.collectWindowSurfaceIds(0, &buf);
    try testing.expectEqual(@as(usize, 2), w0_ids.len);
    try testing.expectEqual(@as(u64, 900), w0_ids[1]); // 되돌아온 900이 마지막(append 순)
}

test "WindowGraph 다중 surface 이동: 하나를 옮겨도 두 런타임 모두 identity·상태 보존" {
    const window_graph = @import("window_graph.zig");
    const allocator = testing.allocator;

    var reg = Registry.init(allocator);
    defer reg.deinit();
    var g = window_graph.WindowGraph.init(allocator);
    defer g.deinit();

    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws1);
    try g.addSurface(p0, 10);
    try g.addSurface(p0, 20); // win0 = {10, 20}
    try g.addSurface(p1, 30); // win1 = {30}

    const r10 = try spawn(&reg, allocator, 10, 0, 10);
    const r20 = try spawn(&reg, allocator, 20, 0, 20);
    const r30 = try spawn(&reg, allocator, 30, 0, 30);
    try r10.push("ten");
    try r20.push("twenty");
    try r30.push("thirty");

    // surface 20(win0 index 1)을 win1로 옮긴다. 나머지(10·30)는 무관해야 한다.
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 1 }, .{ .win = 1, .ws = 0, .pane = 0 });

    try testing.expectEqual(r10, reg.findBySurface(10).?);
    try testing.expectEqual(r20, reg.findBySurface(20).?);
    try testing.expectEqual(r30, reg.findBySurface(30).?);
    try testing.expectEqualStrings("ten", reg.findBySurface(10).?.scrollback.items[0]);
    try testing.expectEqualStrings("twenty", reg.findBySurface(20).?.scrollback.items[0]);
    try testing.expectEqualStrings("thirty", reg.findBySurface(30).?.scrollback.items[0]);
    // 셋 다 재시작 0.
    try testing.expectEqual(@as(u32, 1), reg.findBySurface(10).?.inits);
    try testing.expectEqual(@as(u32, 1), reg.findBySurface(20).?.inits);
    try testing.expectEqual(@as(u32, 1), reg.findBySurface(30).?.inits);
}

test "WindowGraph 이동 후 close: 이동한 surface를 registry에서 제거하면 나머지 불변" {
    const window_graph = @import("window_graph.zig");
    const allocator = testing.allocator;

    var reg = Registry.init(allocator);
    defer reg.deinit();
    var g = window_graph.WindowGraph.init(allocator);
    defer g.deinit();

    const w0 = try g.addWindow(1, .normal);
    const w1 = try g.addWindow(2, .normal);
    const ws0 = try g.addWorkspace(w0, .{});
    const ws1 = try g.addWorkspace(w1, .{});
    const p0 = try g.addPane(ws0);
    const p1 = try g.addPane(ws1);
    try g.addSurface(p0, 1);
    try g.addSurface(p1, 2);

    _ = try spawn(&reg, allocator, 1, 0, 1);
    const keep = try spawn(&reg, allocator, 2, 0, 2);
    try keep.push("keep");

    // surface 1을 win1로 이동한 뒤 그 surface를 close(registry.remove).
    try g.moveSurface(.{ .win = 0, .ws = 0, .pane = 0, .surface = 0 }, .{ .win = 1, .ws = 0, .pane = 0 });
    try reg.remove(1);

    try testing.expect(reg.findBySurface(1) == null);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqual(keep, reg.findBySurface(2).?); // 다른 런타임은 온전
    try testing.expectEqualStrings("keep", reg.findBySurface(2).?.scrollback.items[0]);
}
