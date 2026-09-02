//! `TerminalRuntimeRegistry` — host 측 runtime 소유 표와 controller/observer capability state machine(§9, §4).
//!
//! 이 파일은 runtime **하나당** 누가 controller이고 누가 observer인지, 각 subscription이 어떤 capability를 갖는지,
//! resize를 언제 적용/무시하는지를 결정하는 **순수 state machine**이다. 실제 `TerminalCore`/`LivePtySession` 소유와
//! `TIOCSWINSZ`/core resize 적용은 이 결정을 받아 host server(P3-d)가 수행한다 — 그래야 state machine을 실 PTY 없이
//! non-macOS에서 TDD하고, 실 runtime 배선을 platform 경계에 가둘 수 있다(layering-and-portability.md). 그 연결점으로
//! `RuntimeEntry.runtime`(opaque `*anyopaque`) 슬롯을 두어 server가 실 runtime handle을 실어 두고 조회한다.
//!
//! 핵심 규칙(§9):
//!   - runtime당 controller 1명(`input`+`resize`) + observer N명(`observe`만). `terminate`는 attach로 암묵 부여하지
//!     않는다(별도 auth + `runtime end` 확인).
//!   - `--take-over`만 기존 controller를 revoke하고 원자적으로 이전한다. controller가 그냥 끊기면 자동 승격하지 않는다.
//!   - resize는 controller만, controller별 last `client_sequence` 이하는 재적용하지 않는다. 실제 크기가 바뀔 때만
//!     `resize_generation`을 올리고 `runtime.resized`를 broadcast한다. client가 0명이어도 마지막 검증 크기를 유지한다.

const std = @import("std");
const builtin = @import("builtin");
const subscription_identity = @import("subscription_identity.zig");
const resize_wire = @import("resize_wire.zig");
const upgrade_limits = @import("upgrade_limits.zig");

/// runtime 하나를 가리키는 opaque 128-bit 상관키(§4). wire는 big-endian 16바이트지만 registry 내부는 비교·해시가
/// 쉬운 u128로 다룬다(server가 wire ↔ u128 변환). 의미를 비트에 인코딩하지 않고 재사용하지 않는다.
pub const RuntimeId = u128;

/// Registry 내부의 daemon-global subscription scalar. Wire-local stream id를 이 타입에 직접 전달하지 못하게 public
/// product API는 `subscription_identity.SubscriptionId`만 받고, 이 raw scalar API는 이 파일의 state-machine tests 전용이다.
const StreamId = u64;

/// capability 비트(§9). `is_controller` boolean 하나로 굳히지 않고 비트로 표현해 향후 여러 writable stream 같은
/// 확장을 wire 변경 없이 수용한다. `terminate`는 attach가 부여하지 않는다(별도 경로).
pub const Capability = struct {
    pub const observe: u8 = 1 << 0;
    pub const input: u8 = 1 << 1;
    pub const resize: u8 = 1 << 2;
    pub const terminate: u8 = 1 << 3;

    pub fn has(caps: u8, cap: u8) bool {
        return caps & cap != 0;
    }
};

/// 새 subscription의 attach 모드(§8 CLI·GUI). `controller`는 controller가 없으면 획득하고 있으면 observer로
/// 강등된다. 기존 observer의 승격은 이 API에 섞지 않고 prepared controller transition만 사용한다.
pub const AttachMode = enum { observer, controller };

/// attach 결과. `granted`는 이 subscription이 실제로 받은 capability다. `controller_busy`는 controller를 요청했으나
/// 이미 controller가 있어 observer로 강등됐음을 뜻한다(GUI가 read-only banner 표시).
const AttachOutcome = struct {
    granted: u8,
    controller_busy: bool = false,
};

pub const SubscriptionAttachOutcome = struct {
    granted: u8,
    controller_busy: bool = false,
};

pub const DetachOutcome = struct {
    was_controller: bool,
    was_observer: bool,
};

pub const ControllerTransitionKind = enum { takeover, release };

/// One owner-turn capability transition token. Preparation may reserve observer capacity but does
/// not mutate semantic state. Commit revalidates every exact identity/epoch and then performs only
/// infallible array mutations, so a cross-connection owner can first reserve both control frames.
pub const PreparedControllerTransition = struct {
    runtime_id: RuntimeId,
    target: subscription_identity.SubscriptionId,
    expected_controller: ?subscription_identity.SubscriptionId,
    expected_generation: u64,
    next_generation: u64,
    kind: ControllerTransitionKind,
    /// Release keeps the controller attached as an observer. Its replacement list is prepared off
    /// to the side so a failed cross-fd publish can free it and leave allocator state/semantics
    /// untouched; commit swaps it without allocation.
    release_observers: ?[]ObserverSlot = null,
    consumed: bool = false,
};

pub const ControllerTransitionOutcome = struct {
    revoked_controller: ?subscription_identity.SubscriptionId,
    controller_generation: u64,
};

/// resize 요청 판정(§9). `.stale`은 controller별 last sequence 이하라 무시(다른 output/client에 관측되지 않음).
/// `.applied`는 server가 실제 `TerminalCore`+PTY에 적용해야 하며, `changed`가 true일 때만 크기가 실제로 바뀌어
/// `resize_generation`이 올라가고 `runtime.resized`를 broadcast한다.
/// 조정이 실제로 적용된 결과(S11-6). `changed` 가 true 일 때만 `resize_generation` 이 올라가고
/// `runtime.resized` 를 알린다 — controller resize 와 같은 규율이다.
pub const ViewportApplied = struct {
    cols: u16,
    rows: u16,
    resize_generation: u64,
    changed: bool,
};

pub const ResizeOutcome = union(enum) {
    stale,
    applied: struct {
        cols: u16,
        rows: u16,
        resize_generation: u64,
        changed: bool,
    },
};

/// Backend 적용 전 registry mutation을 보류하는 owner-turn token. 생성 뒤 같은 single owner turn에서 backend를
/// 적용하고 `commitPreparedResize`로 소비하므로, backend 실패는 canonical size/sequence/generation/ledger를 바꾸지 않는다.
pub const PreparedResize = union(enum) {
    stale,
    ready: struct {
        runtime_id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
        changed: bool,
        old_cells: usize,
        new_cells: usize,
        expected_cols: u16,
        expected_rows: u16,
        expected_resize_generation: u64,
        expected_controller_generation: u64,
        expected_controller_sequence: u64,
        expected_resize_seq_seen: bool,
        consumed: bool = false,
    },

    pub fn preview(self: *const PreparedResize) ResizeOutcome {
        return switch (self.*) {
            .stale => .stale,
            .ready => |ready| .{ .applied = .{
                .cols = ready.cols,
                .rows = ready.rows,
                .resize_generation = ready.expected_resize_generation +
                    @intFromBool(ready.changed),
                .changed = ready.changed,
            } },
        };
    }
};

pub const RegistryError = error{
    RuntimeNotFound,
    DuplicateRuntime,
    InvalidRuntimeId,
    /// 같은 stream이 이미 이 runtime에 attach돼 있다(중복 subscription).
    AlreadyAttached,
    /// resize/input을 controller 아닌 stream이 요청했다.
    NotController,
    NotObserver,
    StaleControllerTransition,
    ControllerGenerationExhausted,
    ResizeGenerationExhausted,
    StalePreparedResize,
    /// membership generation을 더 올릴 수 없어 새 complete inventory authority를 만들 수 없다.
    MembershipGenerationExhausted,
    InvalidGridSize,
    RuntimeLimitReached,
    AggregateGridLimitReached,
    OutOfMemory,
};

/// grid 크기 정책. u16 필드 각각만 검증하면 same-UID 외부 client가 65535×65535 cells를 요청해 host heap을
/// 소진할 수 있으므로 canonical 곱을 registry mutation 전에 제한한다.
pub const min_cols: u16 = 2;
pub const min_rows: u16 = 1;
pub const max_grid_cells: usize = 1024 * 1024;
/// 하나의 same-UID client가 작은 runtime을 반복 spawn해 PTY/FD/heap을 무제한 점유하지 못하게 하는 daemon 전역 상한.
pub const max_live_runtimes: usize = upgrade_limits.max_runtime_count;
/// 개별 runtime 상한과 별개인 daemon 전역 canonical grid 원장 상한.
pub const max_aggregate_grid_cells: usize = 4 * 1024 * 1024;

pub const Limits = struct {
    max_live_runtimes: usize = max_live_runtimes,
    max_aggregate_grid_cells: usize = max_aggregate_grid_cells,
};

pub const GridSize = struct { cols: u16, rows: u16 };

fn clampCols(c: u16) u16 {
    return if (c < min_cols) min_cols else c;
}
fn clampRows(r: u16) u16 {
    return if (r < min_rows) min_rows else r;
}

pub fn gridSizeAllowed(cols: u16, rows: u16) bool {
    return @as(usize, clampCols(cols)) * @as(usize, clampRows(rows)) <= max_grid_cells;
}

/// 선언이 세션을 이 아래로는 못 줄인다(S11-6). 1열로 접어 세션을 못 쓰게 만드는 것을 막는다.
/// **정상 client 는 안 막는다** — 실측으로 가장 작은 정상 선언이 21열(좁은 폰 320pt·`font.size`
/// 상한 40)이라 그 아래로 잡았다.
pub const viewport_floor_cols: u16 = 10;

/// 판정자가 상한을 만들 수 있게 낸다.
pub const resize_wire_max_counter: u64 = resize_wire.max_counter;

/// 선언들이 요구하는 세션 열. **선언이 하나도 없으면 `null`** — 그때는 이 기능이 없던 때와
/// 완전히 같다(기준도 안 잡는다).
///
/// **괄호 순서가 계약이다**: `min(기준, max(바닥, 가장 작은 선언))`. 바깥이 `min(기준, …)` 이라
/// 결과가 기준을 절대 넘지 않는다 — 「줄이기만 한다」가 그렇게 지켜진다. 뒤집어 적으면
/// (`max(바닥, min(기준, 선언))`) **기준이 바닥보다 작을 때 세션을 늘린다**: `min_cols` 가 2 라
/// 2열 세션은 실재하고, 거기에 폰이 붙으면 없던 8열이 생긴다.
pub fn reconciledViewportCols(slots: []const ObserverSlot, baseline: u16) ?u16 {
    var smallest: ?u16 = null;
    for (slots) |slot| {
        const view = slot.declared orelse continue;
        smallest = if (smallest) |current| @min(current, view.cols) else view.cols;
    }
    const want = smallest orelse return null;
    return @min(baseline, @max(viewport_floor_cols, want));
}

/// client 가 «자기가 그릴 수 있는 격자» 로 알린 크기(S11-6). 창 크기가 아니라 **그리는 격자**다 —
/// 창 폭으로 선언하면 세션이 client 가 못 그리는 열까지 갖게 되어 리사이즈를 하고도 오른쪽이 잘린다.
pub const Viewport = struct {
    cols: u16,
    rows: u16,
};

/// 붙어 있는 observer 하나.
///
/// **선언을 이 슬롯이 든다 — 전역 표에 id 로 넣지 않는다.** client 가 `SIGKILL` 로 죽거나 전파가
/// 끊겨 채널이 반쯤 닫혀도, 슬롯이 사라질 때 선언도 함께 사라져야 한다. 전역 표면 그 세션은
/// 영영 작은 채로 남는다(S11-6). 그래서 `observers` 는 `StreamId` 가 아니라 이 구조체를 든다 —
/// 평행 배열로 두면 controller release 가 배열을 통째로 갈아 끼우는 자리에서 조용히 어긋난다.
pub const ObserverSlot = struct {
    stream: StreamId,
    /// `null` 은 **「선언한 적이 없다」**다. 「0 을 선언했다」와 겹쳐 쓰지 않는다 — 선언이 하나도
    /// 없으면 host 는 아무것도 안 바꾸고 기준 크기도 안 잡는다.
    declared: ?Viewport = null,
};

/// 선언 상태가 바뀐 뒤 세션이 어떤 열이어야 하는가.
pub const ViewportPlan = union(enum) {
    /// 바꿀 것이 없다 — 선언이 없거나, 이미 그 크기다.
    unchanged,
    /// 이 열로 바꾼다. **행은 안 건드린다.**
    resize_cols: u16,
};

/// `declareViewport` 의 결과. **버림과 무변화를 가른다** — 「한쪽만 0 이라 버렸다」를 「같은 값이라
/// 아무것도 안 했다」로 접으면 client 는 자기 선언이 통했는지 모른다.
pub const DeclareViewportOutcome = enum {
    /// 새 값이 슬롯에 들어갔다.
    declared,
    /// 선언을 거뒀다(둘 다 0). 이 슬롯은 이제 크기에 영향을 안 준다.
    withdrawn,
    /// 직전과 같아 아무것도 안 했다. **리사이즈 폭풍을 여기서 접는다.**
    unchanged,
    /// 한쪽만 0 이라 버렸다. 슬롯은 그대로다.
    invalid,
};

fn hasAnyDeclaration(slots: []const ObserverSlot) bool {
    for (slots) |slot| if (slot.declared != null) return true;
    return false;
}

fn planViewportForEntry(entry: *RuntimeEntry) ViewportPlan {
    const declared = hasAnyDeclaration(entry.observers.items);
    if (entry.viewport_baseline_cols) |baseline| {
        // **마지막 선언이 사라졌다** — 기준으로 돌리고 기준을 놓는다.
        if (!declared) {
            entry.viewport_baseline_cols = null;
            return if (baseline == entry.cols) .unchanged else .{ .resize_cols = baseline };
        }
        const want = reconciledViewportCols(entry.observers.items, baseline).?;
        return if (want == entry.cols) .unchanged else .{ .resize_cols = want };
    }
    // 선언이 하나도 없었고 지금도 없다 — 이 기능이 없던 때와 같다(기준도 안 잡는다).
    if (!declared) return .unchanged;
    // **첫 선언이다** — 지금 크기가 「폰이 없었으면 이랬을 크기」다.
    entry.viewport_baseline_cols = entry.cols;
    const want = reconciledViewportCols(entry.observers.items, entry.cols).?;
    return if (want == entry.cols) .unchanged else .{ .resize_cols = want };
}

fn sameObserverStreams(a: []const ObserverSlot, b: []const ObserverSlot) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.stream != y.stream) return false;
    return true;
}

/// runtime 하나의 소유·구독·크기 상태. `runtime`은 server가 실 `LivePtySession`/`TerminalCore` handle을 실어 두는
/// opaque 슬롯이다(state machine은 이 값을 해석하지 않는다).
pub const RuntimeEntry = struct {
    id: RuntimeId,
    /// 마지막으로 검증된 canonical PTY 크기. client가 0명이어도 유지된다(§9).
    cols: u16,
    rows: u16,
    resize_generation: u64 = 0,
    /// Authority event epoch. It changes once per committed takeover/release and lets clients reject
    /// delayed revocation/success events from a previous controller lifetime.
    controller_generation: u64 = 0,
    controller: ?StreamId = null,
    /// controller가 마지막으로 적용한 client_sequence. controller가 바뀌면(takeover/재attach) 0으로 리셋한다.
    controller_sequence: u64 = 0,
    /// 현재 controller가 resize sequence를 한 번이라도 적용했는가. `controller_sequence==0`을 "아직 없음"과 "마지막이
    /// 0"이라는 두 의미로 겹쳐 쓰지 않기 위한 명시 sentinel이다 — 그래야 seq 0을 유효한 첫 값으로 받되 seq 0 재전송은
    /// stale로 막는다. controller가 바뀌면(controller/takeover 획득) `controller_sequence`와 함께 false로 리셋한다.
    resize_seq_seen: bool = false,
    observers: std.ArrayListUnmanaged(ObserverSlot) = .empty,
    /// 「폰이 없었으면 이랬을 열」(S11-6). **선언이 하나라도 있는 동안에만** 값이 있다.
    ///
    /// controller 로 잡지 않는 이유: 맥 앱이 먼저 꺼지고 keep-alive 로 세션만 살아 있으면
    /// controller 가 **없다**. 그 상태에서 폰이 붙었다 떨어지면 되돌릴 대상이 없어 **세션이 폰
    /// 크기로 영영 굳는다**. 그래서 첫 선언이 들어온 순간의 크기를 여기 적고, 마지막 선언이
    /// 사라질 때 그 값으로 돌린다. controller 가 스스로 크기를 바꾸면 이 값을 **갱신**한다 —
    /// 기준은 그 순간의 값을 강제하는 것이 아니라 「폰이 없었으면」을 뜻하기 때문이다.
    viewport_baseline_cols: ?u16 = null,
    /// 선언 상태가 바뀌어 **다음 serve tick 에 조정해야 한다**. 여기에 모아 두는 이유가 곧
    /// 「폭풍을 합친다」다 — 한 tick 안에 선언이 여럿 와도 리사이즈는 한 번이다.
    viewport_dirty: bool = false,
    /// server가 실 runtime handle을 실어 두는 opaque 슬롯. state machine은 미해석.
    runtime: ?*anyopaque = null,

    fn isAttached(self: *const RuntimeEntry, stream: StreamId) bool {
        if (self.controller == stream) return true;
        for (self.observers.items) |o| if (o.stream == stream) return true;
        return false;
    }

    fn hasObserver(self: *const RuntimeEntry, stream: StreamId) bool {
        for (self.observers.items) |observer| if (observer.stream == stream) return true;
        return false;
    }

    fn removeObserver(self: *RuntimeEntry, stream: StreamId) bool {
        for (self.observers.items, 0..) |o, i| {
            if (o.stream == stream) {
                _ = self.observers.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

/// host의 모든 runtime을 소유하는 표. runtime_id 키드. 소유는 caller(register/unregister/deinit).
pub const TerminalRuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(RuntimeId, *RuntimeEntry) = .empty,
    /// `entries`에 publish된 canonical grid만 센다. pending backend allocation은 owner가 `canRegister`로 먼저 검증하며,
    /// register 실패는 이 값을 바꾸지 않는다.
    live_grid_cells: usize = 0,
    /// `viewport_dirty` 인 entry 수. tick 이 **0 이면 표를 훑지도 않는다**.
    viewport_dirty_count: usize = 0,
    limits: Limits = .{},
    /// 0은 wire의 "첫 page에서 generation 미지정" sentinel이라 실제 complete snapshot은 1부터 시작한다.
    membership_generation: u64 = 1,
    membership_generation_exhausted: bool = false,

    pub fn init(allocator: std.mem.Allocator) TerminalRuntimeRegistry {
        return .{ .allocator = allocator };
    }

    /// Large protocol-only fixtures may raise limits, but all registry operations still obey one internally consistent ledger.
    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) TerminalRuntimeRegistry {
        if (!builtin.is_test) @compileError("initWithLimits is test-only");
        std.debug.assert(limits.max_live_runtimes > 0);
        std.debug.assert(limits.max_aggregate_grid_cells > 0);
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *TerminalRuntimeRegistry) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            entry_ptr.*.observers.deinit(self.allocator);
            self.allocator.destroy(entry_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// runtime을 등록한다(server가 실 spawn 후). 초기 크기는 clamp된다. 같은 id가 이미 있으면 DuplicateRuntime.
    /// 반환된 포인터는 안정 heap 슬롯이라 server가 `runtime`에 실 handle을 실을 수 있다.
    pub fn register(self: *TerminalRuntimeRegistry, id: RuntimeId, cols: u16, rows: u16) RegistryError!*RuntimeEntry {
        return self.registerExact(id, cols, rows, 0, null);
    }

    /// backend/PTY를 만들기 전에 daemon 전역 예산을 확인한다. 실제 publish 시 `registerExact`가 같은 조건을 다시
    /// 확인하므로 이 함수는 allocation 방지 preflight이고 원장의 mutation 권위는 register 하나뿐이다.
    pub fn canRegister(self: *const TerminalRuntimeRegistry, cols: u16, rows: u16) RegistryError!void {
        if (!gridSizeAllowed(cols, rows)) return error.InvalidGridSize;
        if (self.entries.count() >= self.limits.max_live_runtimes) return error.RuntimeLimitReached;
        const cells = gridCells(cols, rows);
        if (self.live_grid_cells > self.limits.max_aggregate_grid_cells or
            cells > self.limits.max_aggregate_grid_cells - self.live_grid_cells)
            return error.AggregateGridLimitReached;
    }

    /// Exec restore처럼 전량 publish하거나 전량 버리는 graph는 첫 surface/reader/PTY adoption allocation 전에 합계를
    /// 한 번 검증한다. 개별 register도 같은 한도를 다시 확인해 mutation 권위를 이 registry에 유지한다.
    pub fn canRegisterBatch(self: *const TerminalRuntimeRegistry, sizes: []const GridSize) RegistryError!void {
        if (sizes.len > self.limits.max_live_runtimes -| self.entries.count())
            return error.RuntimeLimitReached;
        var added_cells: usize = 0;
        for (sizes) |size| {
            if (!gridSizeAllowed(size.cols, size.rows)) return error.InvalidGridSize;
            added_cells = std.math.add(usize, added_cells, gridCells(size.cols, size.rows)) catch
                return error.AggregateGridLimitReached;
        }
        if (self.live_grid_cells > self.limits.max_aggregate_grid_cells or
            added_cells > self.limits.max_aggregate_grid_cells - self.live_grid_cells)
            return error.AggregateGridLimitReached;
    }

    /// Exec-restore graph가 decoded resize generation과 opaque live handle을
    /// 한 번에 publish한다. 연결-local controller/observer/sequence는
    /// RuntimeEntry 기본값으로 재구성되어 부분 entry가 관찰되지 않는다.
    pub fn registerRestored(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        cols: u16,
        rows: u16,
        resize_generation: u64,
        runtime: *anyopaque,
    ) RegistryError!*RuntimeEntry {
        if (resize_generation > resize_wire.max_counter)
            return error.ResizeGenerationExhausted;
        return self.registerExact(id, cols, rows, resize_generation, runtime);
    }

    fn registerExact(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        cols: u16,
        rows: u16,
        resize_generation: u64,
        runtime: ?*anyopaque,
    ) RegistryError!*RuntimeEntry {
        if (id == 0) return error.InvalidRuntimeId;
        try self.canRegister(cols, rows);
        if (self.membership_generation_exhausted or self.membership_generation == std.math.maxInt(u64))
            return error.MembershipGenerationExhausted;
        if (self.entries.contains(id)) return error.DuplicateRuntime;
        const entry = self.allocator.create(RuntimeEntry) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .id = id,
            .cols = clampCols(cols),
            .rows = clampRows(rows),
            .resize_generation = resize_generation,
            .runtime = runtime,
        };
        self.entries.put(self.allocator, id, entry) catch return error.OutOfMemory;
        self.live_grid_cells += gridCells(cols, rows);
        self.membership_generation += 1;
        return entry;
    }

    /// runtime을 제거한다(terminate 후). 모든 구독은 이미 detach됐다고 가정한다 — 남은 observer/controller는 버려진다.
    pub fn unregister(self: *TerminalRuntimeRegistry, id: RuntimeId) void {
        if (self.entries.fetchRemove(id)) |kv| {
            self.live_grid_cells -= gridCells(kv.value.cols, kv.value.rows);
            kv.value.observers.deinit(self.allocator);
            self.allocator.destroy(kv.value);
            if (self.membership_generation == std.math.maxInt(u64)) {
                // Runtime teardown은 되돌릴 수 없으므로 계속하되 이후 inventory authority 발행을 영구 fail-close한다.
                self.membership_generation_exhausted = true;
            } else {
                self.membership_generation += 1;
            }
        }
    }

    pub fn membershipGeneration(self: *const TerminalRuntimeRegistry) RegistryError!u64 {
        if (self.membership_generation_exhausted) return error.MembershipGenerationExhausted;
        return self.membership_generation;
    }

    /// same-PID exec handoff가 source의 logical membership authority를 exact 복원한다. decoded runtime을 registerRestored로
    /// 조립하는 동안 생긴 임시 증가값은 새 logical membership 변화가 아니므로 complete graph publish 직전에 덮는다.
    pub fn restoreMembershipGeneration(self: *TerminalRuntimeRegistry, generation: u64) RegistryError!void {
        if (generation == 0 or self.membership_generation_exhausted)
            return error.MembershipGenerationExhausted;
        self.membership_generation = generation;
    }

    pub fn get(self: *TerminalRuntimeRegistry, id: RuntimeId) ?*RuntimeEntry {
        return self.entries.get(id);
    }

    pub fn count(self: *const TerminalRuntimeRegistry) usize {
        return self.entries.count();
    }

    pub fn liveGridCells(self: *const TerminalRuntimeRegistry) usize {
        return self.live_grid_cells;
    }

    /// Upgrade eligibility는 connection 수가 아니라 실제 runtime subscriptions가 0인지 판정한다. Controller와 observer를
    /// 같은 attachment 단위로 세어 여러 Window/CLI/SSH attach 중 하나라도 남으면 migration을 미룬다.
    pub fn attachmentCount(self: *const TerminalRuntimeRegistry) usize {
        var total: usize = 0;
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            if (entry.controller != null) total += 1;
            total += entry.observers.items.len;
        }
        return total;
    }

    /// 한 subscription을 runtime에 붙인다(§8·§9). 모드별로 controller/observer capability를 결정한다.
    fn attach(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId, mode: AttachMode) RegistryError!AttachOutcome {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.isAttached(stream)) return error.AlreadyAttached;

        switch (mode) {
            .observer => {
                try appendObserver(self.allocator, entry, stream);
                return .{ .granted = Capability.observe };
            },
            .controller => {
                if (entry.controller == null) {
                    const next_generation = std.math.add(
                        u64,
                        entry.controller_generation,
                        1,
                    ) catch return error.ControllerGenerationExhausted;
                    entry.controller = stream;
                    entry.controller_sequence = 0; // 새 controller — sequence 창을 새로 연다.
                    entry.resize_seq_seen = false;
                    entry.controller_generation = next_generation;
                    return .{ .granted = Capability.observe | Capability.input | Capability.resize };
                }
                // 이미 controller가 있으면 조용히 빼앗지 않고 observer로 강등한다(§8).
                try appendObserver(self.allocator, entry, stream);
                return .{ .granted = Capability.observe, .controller_busy = true };
            },
        }
    }

    /// subscription을 뗀다(detach/EOF/crash). controller가 끊겨도 자동 승격하지 않는다(§9). runtime은 유지된다.
    fn detach(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId) RegistryError!DetachOutcome {
        // **선언을 들고 있던 슬롯이 사라지면 다시 계산해야 한다** — 마지막 하나였다면 기준으로
        // 돌아가는 자리가 바로 여기다. 선언이 없던 슬롯이면 조정 결과가 그대로라 세우지 않는다.
        if (self.entries.get(id)) |entry| {
            for (entry.observers.items) |slot|
                if (slot.stream == stream and slot.declared != null) {
                    self.markViewportDirty(entry);
                    break;
                };
        }
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.controller == stream) {
            entry.controller = null; // release. 자동 승격 없음.
            return .{ .was_controller = true, .was_observer = false };
        }
        const was_observer = entry.removeObserver(stream);
        return .{ .was_controller = false, .was_observer = was_observer };
    }

    /// 이 subscription의 현재 capability를 계산한다.
    fn capabilitiesOf(self: *TerminalRuntimeRegistry, id: RuntimeId, stream: StreamId) u8 {
        const entry = self.entries.get(id) orelse return 0;
        if (entry.controller == stream) return Capability.observe | Capability.input | Capability.resize;
        for (entry.observers.items) |o| if (o.stream == stream) return Capability.observe;
        return 0;
    }

    /// controller가 요청한 resize를 판정한다(§9). stale sequence는 무시하고, 새 sequence면 clamp 후 크기 변화를
    /// 계산한다. 실제 크기가 바뀌면 `resize_generation`을 올린다. **실 core/PTY 적용은 server가 이 결과로 수행**한다.
    fn prepareResize(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        stream: StreamId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
    ) RegistryError!PreparedResize {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.controller != stream) return error.NotController;
        if (entry.resize_seq_seen and client_sequence <= entry.controller_sequence) {
            return .stale; // controller별 last sequence 이하 — 재적용하지 않는다(seq 0도 첫 적용 뒤엔 stale).
        }
        const new_cols = clampCols(cols);
        const new_rows = clampRows(rows);
        if (!gridSizeAllowed(new_cols, new_rows)) return error.InvalidGridSize;
        const old_cells = gridCells(entry.cols, entry.rows);
        const new_cells = gridCells(new_cols, new_rows);
        const cells_without_entry = self.live_grid_cells - old_cells;
        if (cells_without_entry > self.limits.max_aggregate_grid_cells or
            new_cells > self.limits.max_aggregate_grid_cells - cells_without_entry)
            return error.AggregateGridLimitReached;
        if (new_cols != entry.cols or new_rows != entry.rows)
            if (entry.resize_generation == resize_wire.max_counter)
                return error.ResizeGenerationExhausted;
        return .{ .ready = .{
            .runtime_id = id,
            .subscription = .{ .value = stream },
            .cols = new_cols,
            .rows = new_rows,
            .client_sequence = client_sequence,
            .changed = new_cols != entry.cols or new_rows != entry.rows,
            .old_cells = old_cells,
            .new_cells = new_cells,
            .expected_cols = entry.cols,
            .expected_rows = entry.rows,
            .expected_resize_generation = entry.resize_generation,
            .expected_controller_generation = entry.controller_generation,
            .expected_controller_sequence = entry.controller_sequence,
            .expected_resize_seq_seen = entry.resize_seq_seen,
        } };
    }

    /// `prepareResize`와 같은 owner turn에서 backend 성공 뒤 호출한다. 외부 dispatch가 끼어들 수 없는 single-owner
    /// 계약이므로 token의 entry는 여전히 canonical entry이며 이 단계에는 allocation/syscall/error가 없다.
    pub fn validatePreparedResize(
        self: *TerminalRuntimeRegistry,
        prepared: *const PreparedResize,
    ) RegistryError!void {
        const ready = switch (prepared.*) {
            .stale => return,
            .ready => |*value| value,
        };
        if (ready.consumed) return error.StalePreparedResize;
        const entry = self.entries.get(ready.runtime_id) orelse
            return error.StalePreparedResize;
        if (entry.controller != ready.subscription.value or
            entry.cols != ready.expected_cols or
            entry.rows != ready.expected_rows or
            entry.resize_generation != ready.expected_resize_generation or
            entry.controller_generation != ready.expected_controller_generation or
            entry.controller_sequence != ready.expected_controller_sequence or
            entry.resize_seq_seen != ready.expected_resize_seq_seen)
            return error.StalePreparedResize;
        if (self.live_grid_cells < ready.old_cells)
            return error.StalePreparedResize;
        const cells_without_entry = self.live_grid_cells - ready.old_cells;
        if (cells_without_entry > self.limits.max_aggregate_grid_cells or
            ready.new_cells > self.limits.max_aggregate_grid_cells - cells_without_entry)
            return error.AggregateGridLimitReached;
    }

    fn commitPreparedResize(
        self: *TerminalRuntimeRegistry,
        prepared: *PreparedResize,
    ) RegistryError!ResizeOutcome {
        try self.validatePreparedResize(prepared);
        const ready = switch (prepared.*) {
            .stale => return .stale,
            .ready => |*value| value,
        };
        const entry = self.entries.get(ready.runtime_id) orelse
            return error.StalePreparedResize;
        ready.consumed = true;
        entry.resize_seq_seen = true;
        entry.controller_sequence = ready.client_sequence;
        if (ready.changed) {
            entry.cols = ready.cols;
            entry.rows = ready.rows;
            entry.resize_generation += 1;
            // **controller 의 리사이즈는 기준을 갱신한다**(S11-6). 기준은 「폰이 없었으면 이랬을
            // 크기」이지 「폰이 붙기 전 그 순간의 값」을 강제하는 것이 아니다 — 사용자가 맥 창을
            // 조절했으면 그쪽이 이긴다. 선언이 없으면 기준 자체가 없으므로 아무 일도 안 한다.
            //
            // 여기서 **깎지 않는다**: `PreparedResize` 는 기대값이 봉인돼 있어 커밋 때 값을 바꾸면
            // 그 계약이 깨진다. 대신 caller 가 이어서 `planViewport` 를 물어 한 번 더 줄인다.
            if (entry.viewport_baseline_cols != null) {
                entry.viewport_baseline_cols = ready.cols;
                // 기준이 바뀌었으니 다음 tick 에 다시 줄인다.
                self.markViewportDirty(entry);
            }
            self.live_grid_cells =
                self.live_grid_cells - ready.old_cells + ready.new_cells;
        }
        return .{ .applied = .{
            .cols = ready.cols,
            .rows = ready.rows,
            .resize_generation = entry.resize_generation,
            .changed = ready.changed,
        } };
    }

    fn resize(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        stream: StreamId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
    ) RegistryError!ResizeOutcome {
        var prepared = try self.prepareResize(id, stream, cols, rows, client_sequence);
        return try self.commitPreparedResize(&prepared);
    }

    pub fn attachSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        mode: AttachMode,
    ) RegistryError!SubscriptionAttachOutcome {
        const outcome = try self.attach(id, subscription.value, mode);
        return .{
            .granted = outcome.granted,
            .controller_busy = outcome.controller_busy,
        };
    }

    pub fn detachSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
    ) RegistryError!DetachOutcome {
        return self.detach(id, subscription.value);
    }

    /// Failed product attach is not a published controller lease. The same owner turn may restore
    /// the immediately preceding epoch only when exact subscription and generation still match.
    pub fn rollbackControllerAttach(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        acquired_generation: u64,
    ) bool {
        const entry = self.entries.get(id) orelse return false;
        if (acquired_generation == 0 or
            entry.controller != subscription.value or
            entry.controller_generation != acquired_generation) return false;
        entry.controller = null;
        entry.controller_sequence = 0;
        entry.resize_seq_seen = false;
        entry.controller_generation = acquired_generation - 1;
        return true;
    }

    pub fn capabilitiesOfSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
    ) u8 {
        return self.capabilitiesOf(id, subscription.value);
    }

    pub fn controllerGeneration(self: *const TerminalRuntimeRegistry, id: RuntimeId) RegistryError!u64 {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        return entry.controller_generation;
    }

    pub fn prepareControllerTakeover(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        target: subscription_identity.SubscriptionId,
    ) RegistryError!PreparedControllerTransition {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (!entry.hasObserver(target.value)) return error.NotObserver;
        const next_generation = std.math.add(
            u64,
            entry.controller_generation,
            1,
        ) catch return error.ControllerGenerationExhausted;
        return .{
            .runtime_id = id,
            .target = target,
            .expected_controller = if (entry.controller) |controller|
                .{ .value = controller }
            else
                null,
            .expected_generation = entry.controller_generation,
            .next_generation = next_generation,
            .kind = .takeover,
        };
    }

    pub fn prepareControllerRelease(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        target: subscription_identity.SubscriptionId,
    ) RegistryError!PreparedControllerTransition {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        if (entry.controller != target.value) return error.NotController;
        const next_generation = std.math.add(
            u64,
            entry.controller_generation,
            1,
        ) catch return error.ControllerGenerationExhausted;
        const replacement = self.allocator.alloc(
            ObserverSlot,
            entry.observers.items.len + 1,
        ) catch return error.OutOfMemory;
        @memcpy(replacement[0..entry.observers.items.len], entry.observers.items);
        // **물러나는 controller 는 선언 없이 observer 가 된다.** controller 는 제 크기를 스스로
        // 정하는 쪽이라 「선언」이라는 개념이 없다 — 여기서 뭔가를 실으면 그것이 곧 자기 자신을
        // 좁히는 선언이 된다.
        replacement[replacement.len - 1] = .{ .stream = target.value };
        return .{
            .runtime_id = id,
            .target = target,
            .expected_controller = target,
            .expected_generation = entry.controller_generation,
            .next_generation = next_generation,
            .kind = .release,
            .release_observers = replacement,
        };
    }

    pub fn discardControllerTransition(
        self: *TerminalRuntimeRegistry,
        prepared: *PreparedControllerTransition,
    ) void {
        if (prepared.release_observers) |replacement|
            self.allocator.free(replacement);
        prepared.release_observers = null;
        prepared.consumed = true;
    }

    /// The daemon owner calls this only after every authority-critical control frame has passed one
    /// all-or-none queue preflight. Exact identity and generation checks make a delayed token inert.
    pub fn validateControllerTransition(
        self: *TerminalRuntimeRegistry,
        prepared: *const PreparedControllerTransition,
    ) RegistryError!void {
        if (prepared.consumed) return error.StaleControllerTransition;
        const entry = self.entries.get(prepared.runtime_id) orelse
            return error.StaleControllerTransition;
        const current_controller = if (entry.controller) |controller|
            subscription_identity.SubscriptionId{ .value = controller }
        else
            null;
        if (!optionalSubscriptionEqual(
            current_controller,
            prepared.expected_controller,
        ) or
            entry.controller_generation != prepared.expected_generation or
            prepared.next_generation != prepared.expected_generation + 1)
            return error.StaleControllerTransition;
        switch (prepared.kind) {
            .takeover => {
                if (prepared.release_observers != null or
                    !entry.hasObserver(prepared.target.value))
                    return error.StaleControllerTransition;
            },
            .release => {
                const replacement = prepared.release_observers orelse
                    return error.StaleControllerTransition;
                if (entry.controller != prepared.target.value or
                    replacement.len != entry.observers.items.len + 1 or
                    replacement[replacement.len - 1].stream != prepared.target.value)
                    return error.StaleControllerTransition;
                // **신원만 견준다 — 선언은 안 본다.** 준비와 커밋 사이에 어떤 observer 가 제
                // 뷰포트를 알려 왔다고 해서 controller 인수인계가 무효가 되면 안 된다. 이 검사가
                // 지키는 것은 「그 사이에 붙거나 떨어진 자가 있는가」다.
                if (!sameObserverStreams(
                    replacement[0..entry.observers.items.len],
                    entry.observers.items,
                )) return error.StaleControllerTransition;
            },
        }
    }

    pub fn commitControllerTransition(
        self: *TerminalRuntimeRegistry,
        prepared: *PreparedControllerTransition,
    ) RegistryError!ControllerTransitionOutcome {
        try self.validateControllerTransition(prepared);
        const entry = self.entries.get(prepared.runtime_id).?;

        switch (prepared.kind) {
            .takeover => {
                // **controller 가 되면 그 자의 선언이 사라진다.** controller 는 제 크기를 스스로
                // 정하므로 알릴 대상이 없다 — 슬롯이 없어지니 선언도 함께 없어진다(S11-6 의 수명
                // 규칙 그대로다).
                const removed = entry.removeObserver(prepared.target.value);
                std.debug.assert(removed);
                if (entry.controller) |old|
                    entry.observers.appendAssumeCapacity(.{ .stream = old });
                entry.controller = prepared.target.value;
            },
            .release => {
                if (entry.controller != prepared.target.value)
                    return error.StaleControllerTransition;
                const replacement = prepared.release_observers orelse
                    return error.StaleControllerTransition;
                entry.observers.deinit(self.allocator);
                entry.observers = .{
                    .items = replacement,
                    .capacity = replacement.len,
                };
                prepared.release_observers = null;
                entry.controller = null;
            },
        }
        entry.controller_sequence = 0;
        entry.resize_seq_seen = false;
        entry.controller_generation = prepared.next_generation;
        prepared.consumed = true;
        return .{
            .revoked_controller = prepared.expected_controller,
            .controller_generation = prepared.next_generation,
        };
    }

    /// Controller/sequence/budget prepare, fallible backend apply, infallible canonical commit을 한 API call에 가둔다.
    /// Prepared token은 registry 밖으로 나가지 않아 복사 재commit이나 future owner interleaving을 만들 수 없다.
    pub fn resizeSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
        apply_ctx: *anyopaque,
        apply: *const fn (ctx: *anyopaque, runtime_id: RuntimeId, cols: u16, rows: u16) anyerror!void,
    ) anyerror!ResizeOutcome {
        var prepared = try self.prepareResize(id, subscription.value, cols, rows, client_sequence);
        switch (prepared) {
            .stale => {},
            .ready => |ready| if (ready.changed)
                try apply(apply_ctx, id, ready.cols, ready.rows),
        }
        return try self.commitPreparedResize(&prepared);
    }

    /// Owner-level response/event admission 전에 canonical state나 backend를 바꾸지 않는 resize token을 만든다.
    pub fn prepareResizeSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        cols: u16,
        rows: u16,
        client_sequence: u64,
    ) RegistryError!PreparedResize {
        return self.prepareResize(id, subscription.value, cols, rows, client_sequence);
    }

    /// 같은 owner dispatch turn의 all-or-none admission과 backend 적용이 성공한 뒤에만 호출한다.
    pub fn commitResizeSubscription(
        self: *TerminalRuntimeRegistry,
        prepared: *PreparedResize,
    ) RegistryError!ResizeOutcome {
        return self.commitPreparedResize(prepared);
    }

    /// 뷰포트 선언을 그 observer 슬롯에 적는다(S11-6). **크기는 여기서 안 바꾼다** — 무엇을 할지는
    /// 조정 규칙이 정하고, 이 함수는 「누가 무엇을 알렸나」만 든다.
    pub fn declareViewportSubscription(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        subscription: subscription_identity.SubscriptionId,
        cols: u16,
        rows: u16,
    ) RegistryError!DeclareViewportOutcome {
        return self.declareViewport(id, subscription.value, cols, rows);
    }

    fn declareViewport(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        stream: StreamId,
        cols: u16,
        rows: u16,
    ) RegistryError!DeclareViewportOutcome {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        // **선언할 수 있는 것은 붙어 있는 observer 뿐이다.** controller 도 여기서 걸린다 —
        // `attach` 가 controller 를 `observers` 에 넣지 않으므로 이 루프가 못 찾는다. 자기 크기를
        // 스스로 정하는 쪽이라 알릴 대상도 없다. 따로 가드를 두지 않는다(변이 검사에서 그 가드가
        // 닿지 않는 코드임을 확인했다 — 2026-09-01).
        const slot = blk: {
            for (entry.observers.items) |*o| if (o.stream == stream) break :blk o;
            return error.NotObserver;
        };

        // **한쪽만 0 인 것은 버린다.** 「폭이 0 인 화면」은 뜻이 없고, 조용히 반쪽만 받으면 그
        // client 는 자기가 뭘 요청했는지 모른다. 버리되 끊지는 않는다.
        if ((cols == 0) != (rows == 0)) return .invalid;

        // 둘 다 0 이면 **선언을 거둔다** — 붙어 있되 크기에 영향을 안 준다.
        const next: ?Viewport = if (cols == 0) null else .{ .cols = cols, .rows = rows };
        const before = slot.declared;
        slot.declared = next;

        if (before == null and next == null) return .unchanged;
        if (before) |b| if (next) |n| {
            if (b.cols == n.cols and b.rows == n.rows) return .unchanged;
        };
        // 값이 실제로 달라졌을 때만 다음 tick 에 조정한다 — 같은 값이면 위에서 이미 돌아갔다.
        self.markViewportDirty(entry);
        return if (next == null) .withdrawn else .declared;
    }

    fn markViewportDirty(self: *TerminalRuntimeRegistry, entry: *RuntimeEntry) void {
        if (entry.viewport_dirty) return;
        entry.viewport_dirty = true;
        self.viewport_dirty_count += 1;
    }

    /// 조정할 것이 있는가. tick 이 매번 표를 훑지 않게 한다.
    pub fn viewportDirty(self: *const TerminalRuntimeRegistry) bool {
        return self.viewport_dirty_count != 0;
    }

    /// 조정할 runtime 하나를 꺼낸다(플래그를 내린다). 없으면 `null`.
    pub fn takeDirtyViewport(self: *TerminalRuntimeRegistry) ?RuntimeId {
        if (self.viewport_dirty_count == 0) return null;
        var it = self.entries.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (!entry.viewport_dirty) continue;
            entry.viewport_dirty = false;
            self.viewport_dirty_count -= 1;
            return entry.id;
        }
        // 세는 값과 표가 어긋났다 — 세는 값을 표에 맞춘다.
        self.viewport_dirty_count = 0;
        return null;
    }

    /// 조정 결과를 실제로 적용한다. **caller 가 PTY 를 먼저 바꾸고 나서 부른다.**
    ///
    /// controller 의 resize 경로(`commitPreparedResize`)와 **일부러 갈랐다**: 이것은 client 의
    /// 요청이 아니라 host 의 결정이라 `controller_sequence`·`resize_seq_seen` 을 건드리면 안 된다.
    /// 그 둘을 건드리면 다음 진짜 controller resize 가 stale 로 막힌다. 기준 크기도 안 건드린다 —
    /// 기준은 「폰이 없었으면」이고 이 변경은 폰 때문이다.
    /// 조정을 적용할 수 있는지 **PTY 를 건드리기 전에** 본다.
    ///
    /// caller 가 `ops.resize` 를 먼저 부르고 나서 커밋이 실패하면 **PTY 와 registry 가 갈린다** —
    /// 「PTY 먼저」 규율이 지키려던 것을 정확히 뒤집는다. 실제로 생길 수 있는 경우가 하나 있다:
    /// `resize_generation` 이 상한에 닿은 세션(줄이는 방향이라 격자 상한은 못 넘는다). 그래서
    /// 같은 조건을 같은 순서로 보는 함수를 하나 두고, 적용도 이것을 먼저 부른다.
    pub fn viewportColsApplicable(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        cols: u16,
    ) RegistryError!void {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        const new_cols = clampCols(cols);
        if (!gridSizeAllowed(new_cols, entry.rows)) return error.InvalidGridSize;
        if (new_cols == entry.cols) return;
        const old_cells = gridCells(entry.cols, entry.rows);
        const new_cells = gridCells(new_cols, entry.rows);
        const cells_without_entry = self.live_grid_cells - old_cells;
        if (cells_without_entry > self.limits.max_aggregate_grid_cells or
            new_cells > self.limits.max_aggregate_grid_cells - cells_without_entry)
            return error.AggregateGridLimitReached;
        if (entry.resize_generation == resize_wire.max_counter)
            return error.ResizeGenerationExhausted;
    }

    pub fn applyViewportCols(
        self: *TerminalRuntimeRegistry,
        id: RuntimeId,
        cols: u16,
    ) RegistryError!ViewportApplied {
        try self.viewportColsApplicable(id, cols);
        const entry = self.entries.get(id).?;
        const new_cols = clampCols(cols);
        if (new_cols == entry.cols) return .{
            .cols = entry.cols,
            .rows = entry.rows,
            .resize_generation = entry.resize_generation,
            .changed = false,
        };
        const old_cells = gridCells(entry.cols, entry.rows);
        const new_cells = gridCells(new_cols, entry.rows);
        entry.cols = new_cols;
        entry.resize_generation += 1;
        self.live_grid_cells = self.live_grid_cells - old_cells + new_cells;
        return .{
            .cols = entry.cols,
            .rows = entry.rows,
            .resize_generation = entry.resize_generation,
            .changed = true,
        };
    }

    /// 선언 상태가 바뀐 뒤(선언·거둠·detach·controller 리사이즈) 세션이 어떤 열이어야 하는지
    /// 정하고 **기준 크기의 수명을 소유한다**. 크기를 실제로 바꾸는 것은 caller 다 — PTY 와
    /// registry 가 따로 놀면 안 되므로 여기서 `entry.cols` 를 건드리지 않는다.
    pub fn planViewport(self: *TerminalRuntimeRegistry, id: RuntimeId) RegistryError!ViewportPlan {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        return planViewportForEntry(entry);
    }

    /// 지금 붙어 있는 observer 들의 슬롯. `runtime get` 이 「누가 무엇을 선언했나」를 싣는다.
    pub fn observerSlots(self: *TerminalRuntimeRegistry, id: RuntimeId) RegistryError![]const ObserverSlot {
        const entry = self.entries.get(id) orelse return error.RuntimeNotFound;
        return entry.observers.items;
    }

    fn appendObserver(allocator: std.mem.Allocator, entry: *RuntimeEntry, stream: StreamId) RegistryError!void {
        entry.observers.append(allocator, .{ .stream = stream }) catch return error.OutOfMemory;
    }
};

fn optionalSubscriptionEqual(
    a: ?subscription_identity.SubscriptionId,
    b: ?subscription_identity.SubscriptionId,
) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.value == b.?.value;
}

fn gridCells(cols: u16, rows: u16) usize {
    return @as(usize, clampCols(cols)) * @as(usize, clampRows(rows));
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 여러 client가 한 runtime을 관찰하되 입력·resize는 정확히
// 한 명(controller)만 해야 — 두 사람이 같은 셸에 동시에 타이핑하거나 서로 크기를 다투는 일이 없다. controller 획득/
// 강등/takeover/release, capability 부여, stale resize 무시, clamp, client 0에서 크기 유지를 순수 state machine으로
// 고정한다. 실 PTY 없이 non-macOS에서 controller 정책 회귀를 잡는다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "registry: register/get/duplicate and count" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(0xAABB, 80, 24);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expect(reg.get(0xAABB) != null);
    try testing.expectError(error.DuplicateRuntime, reg.register(0xAABB, 80, 24));
    // 초기 크기 clamp: cols=0 → 2, rows=0 → 1.
    const e = try reg.register(0xCCDD, 0, 0);
    try testing.expectEqual(min_cols, e.cols);
    try testing.expectEqual(min_rows, e.rows);
}

test "registry: live grid cap rejects oversized register and resize before mutation" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const exact_cols: u16 = 4096;
    const exact_rows: u16 = 256;
    try testing.expectEqual(max_grid_cells, @as(usize, exact_cols) * exact_rows);
    const entry = try registry.register(1, exact_cols, exact_rows);
    _ = try registry.attach(1, 10, .controller);

    try testing.expectError(
        error.InvalidGridSize,
        registry.register(2, exact_cols + 1, exact_rows),
    );
    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expectError(
        error.InvalidGridSize,
        registry.resize(1, 10, exact_cols + 1, exact_rows, 7),
    );
    try testing.expectEqual(exact_cols, entry.cols);
    try testing.expectEqual(exact_rows, entry.rows);
    try testing.expect(!entry.resize_seq_seen);
}

test "registry: daemon runtime count exact cap and cap plus one are transactional" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();

    var id: u128 = 1;
    while (id <= max_live_runtimes) : (id += 1) {
        _ = try registry.register(id, min_cols, min_rows);
    }
    try testing.expectEqual(max_live_runtimes, registry.count());
    try testing.expectEqual(max_live_runtimes * min_cols * min_rows, registry.liveGridCells());

    try testing.expectError(
        error.RuntimeLimitReached,
        registry.register(id, min_cols, min_rows),
    );
    try testing.expectEqual(max_live_runtimes, registry.count());
    try testing.expectEqual(max_live_runtimes * min_cols * min_rows, registry.liveGridCells());

    registry.unregister(1);
    _ = try registry.register(id, min_cols, min_rows);
    try testing.expectEqual(max_live_runtimes, registry.count());
    try testing.expectEqual(max_live_runtimes * min_cols * min_rows, registry.liveGridCells());
}

test "registry: daemon aggregate grid exact cap resize rollback and release" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();

    const max_cols: u16 = 4096;
    const max_rows: u16 = 256;
    _ = try registry.register(1, max_cols, max_rows);
    _ = try registry.register(2, max_cols, max_rows);
    _ = try registry.register(3, max_cols, max_rows);
    _ = try registry.register(4, max_cols - 1, max_rows);
    _ = try registry.register(5, 254, 1);
    const small = try registry.register(6, min_cols, min_rows);
    _ = try registry.attach(6, 60, .controller);
    try testing.expectEqual(max_aggregate_grid_cells, registry.liveGridCells());

    try testing.expectError(
        error.AggregateGridLimitReached,
        registry.register(7, min_cols, min_rows),
    );
    try testing.expectError(
        error.AggregateGridLimitReached,
        registry.resize(6, 60, min_cols + 1, min_rows, 1),
    );
    try testing.expectEqual(min_cols, small.cols);
    try testing.expectEqual(min_rows, small.rows);
    try testing.expect(!small.resize_seq_seen);
    try testing.expectEqual(@as(u64, 0), small.resize_generation);
    try testing.expectEqual(max_aggregate_grid_cells, registry.liveGridCells());

    registry.unregister(1);
    try testing.expectEqual(max_aggregate_grid_cells - max_grid_cells, registry.liveGridCells());
    const resized = try registry.resize(6, 60, min_cols + 1, min_rows, 1);
    try testing.expect(resized.applied.changed);
    try testing.expectEqual(
        max_aggregate_grid_cells - max_grid_cells + 1,
        registry.liveGridCells(),
    );
}

test "registry: restore batch aggregate preflight is all or nothing" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    const exact = [_]GridSize{
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4096, .rows = 256 },
    };
    try registry.canRegisterBatch(&exact);
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expectEqual(@as(usize, 0), registry.liveGridCells());

    var cap_plus_one = [_]GridSize{
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4096, .rows = 256 },
        .{ .cols = 4095, .rows = 256 },
        .{ .cols = 255, .rows = 1 },
        .{ .cols = 2, .rows = 1 },
    };
    try testing.expectError(
        error.AggregateGridLimitReached,
        registry.canRegisterBatch(&cap_plus_one),
    );
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expectEqual(@as(usize, 0), registry.liveGridCells());
}

test "registry: membership generation changes only after a published membership mutation" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    try testing.expectEqual(@as(u64, 1), try registry.membershipGeneration());
    try testing.expectError(error.InvalidRuntimeId, registry.register(0, 80, 24));
    _ = try registry.register(1, 80, 24);
    try testing.expectEqual(@as(u64, 2), try registry.membershipGeneration());
    try testing.expectError(error.DuplicateRuntime, registry.register(1, 80, 24));
    try testing.expectEqual(@as(u64, 2), try registry.membershipGeneration());
    registry.unregister(2);
    try testing.expectEqual(@as(u64, 2), try registry.membershipGeneration());
    registry.unregister(1);
    try testing.expectEqual(@as(u64, 3), try registry.membershipGeneration());
}

test "registry: membership generation exhaustion blocks publish but never blocks teardown" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    registry.membership_generation = std.math.maxInt(u64) - 1;
    _ = try registry.register(1, 80, 24);
    try testing.expectEqual(std.math.maxInt(u64), try registry.membershipGeneration());
    try testing.expectError(error.MembershipGenerationExhausted, registry.register(2, 80, 24));
    registry.unregister(1);
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expectError(error.MembershipGenerationExhausted, registry.membershipGeneration());
    try testing.expectError(error.MembershipGenerationExhausted, registry.register(3, 80, 24));
}

test "registry: first controller gets input+resize, extra controller is demoted to observer" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);

    const a = try reg.attach(1, 100, .controller);
    try testing.expect(Capability.has(a.granted, Capability.input) and Capability.has(a.granted, Capability.resize));
    try testing.expect(!a.controller_busy);
    try testing.expectEqual(@as(u64, 1), reg.get(1).?.controller_generation);

    // 두 번째 controller 요청 → 조용히 빼앗지 않고 observer로 강등(controller_busy).
    const b = try reg.attach(1, 200, .controller);
    try testing.expect(b.controller_busy);
    try testing.expectEqual(@as(u8, Capability.observe), b.granted);
    try testing.expectEqual(@as(u8, Capability.observe), reg.capabilitiesOf(1, 200));
    try testing.expect(Capability.has(reg.capabilitiesOf(1, 100), Capability.input));
    try testing.expectEqual(@as(u64, 1), reg.get(1).?.controller_generation);
}

test "registry: an exhausted empty controller lease refuses reacquire without mutation" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const observer = subscription_identity.SubscriptionId{ .value = 200 };
    _ = try reg.attachSubscription(1, observer, .observer);
    reg.get(1).?.controller_generation = std.math.maxInt(u64);
    try testing.expectError(
        error.ControllerGenerationExhausted,
        reg.attachSubscription(
            1,
            .{ .value = 100 },
            .controller,
        ),
    );
    try testing.expect(reg.get(1).?.controller == null);
    try testing.expectEqual(
        Capability.observe,
        reg.capabilitiesOfSubscription(1, observer),
    );
}

test "registry: observers only observe; terminate is never granted by attach" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const o = try reg.attach(1, 300, .observer);
    try testing.expectEqual(@as(u8, Capability.observe), o.granted);
    try testing.expect(!Capability.has(o.granted, Capability.input));
    try testing.expect(!Capability.has(o.granted, Capability.terminate));
    // 같은 stream 재attach는 거부(중복 subscription).
    try testing.expectError(error.AlreadyAttached, reg.attach(1, 300, .observer));
}

test "registry: prepared controller takeover does not mutate before infallible commit" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const old = subscription_identity.SubscriptionId{ .value = 100 };
    const next = subscription_identity.SubscriptionId{ .value = 200 };
    _ = try reg.attachSubscription(1, old, .controller);
    _ = try reg.attachSubscription(1, next, .observer);

    var prepared = try reg.prepareControllerTakeover(1, next);
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, old),
        Capability.input,
    ));
    try testing.expect(!Capability.has(
        reg.capabilitiesOfSubscription(1, next),
        Capability.input,
    ));

    const committed = try reg.commitControllerTransition(&prepared);
    try testing.expectEqual(old, committed.revoked_controller.?);
    try testing.expectEqual(@as(u64, 2), committed.controller_generation);
    try testing.expect(!Capability.has(
        reg.capabilitiesOfSubscription(1, old),
        Capability.input,
    ));
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, next),
        Capability.input,
    ));
}

test "registry: stale prepared takeover cannot revoke a replacement controller" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const old = subscription_identity.SubscriptionId{ .value = 100 };
    const next = subscription_identity.SubscriptionId{ .value = 200 };
    const replacement = subscription_identity.SubscriptionId{ .value = 300 };
    _ = try reg.attachSubscription(1, old, .controller);
    _ = try reg.attachSubscription(1, next, .observer);
    var prepared = try reg.prepareControllerTakeover(1, next);

    _ = try reg.detachSubscription(1, old);
    _ = try reg.attachSubscription(1, replacement, .controller);
    try testing.expectError(
        error.StaleControllerTransition,
        reg.commitControllerTransition(&prepared),
    );
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, replacement),
        Capability.input,
    ));
    try testing.expect(!Capability.has(
        reg.capabilitiesOfSubscription(1, next),
        Capability.input,
    ));
}

test "registry: prepared release demotes controller without promoting observers" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const controller = subscription_identity.SubscriptionId{ .value = 100 };
    const observer = subscription_identity.SubscriptionId{ .value = 200 };
    _ = try reg.attachSubscription(1, controller, .controller);
    _ = try reg.attachSubscription(1, observer, .observer);

    var prepared = try reg.prepareControllerRelease(1, controller);
    const committed = try reg.commitControllerTransition(&prepared);
    try testing.expectEqual(controller, committed.revoked_controller.?);
    try testing.expectEqual(@as(u64, 2), committed.controller_generation);
    try testing.expectEqual(
        Capability.observe,
        reg.capabilitiesOfSubscription(1, controller),
    );
    try testing.expectEqual(
        Capability.observe,
        reg.capabilitiesOfSubscription(1, observer),
    );
    try testing.expect(prepared.consumed);
    try testing.expect(prepared.release_observers == null);
    try testing.expectError(
        error.StaleControllerTransition,
        reg.commitControllerTransition(&prepared),
    );
    reg.discardControllerTransition(&prepared);
}

test "registry: release prepare OOM preserves controller and generation" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const controller = subscription_identity.SubscriptionId{ .value = 100 };
    _ = try reg.attachSubscription(1, controller, .controller);
    var failing = std.testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = 0 },
    );
    reg.allocator = failing.allocator();
    try testing.expectError(
        error.OutOfMemory,
        reg.prepareControllerRelease(1, controller),
    );
    reg.allocator = testing.allocator;
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, controller),
        Capability.input,
    ));
    try testing.expectEqual(@as(u64, 1), reg.get(1).?.controller_generation);
}

test "registry: observer acquires an empty controller and stale self takeover is inert" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const observer = subscription_identity.SubscriptionId{ .value = 100 };
    _ = try reg.attachSubscription(1, observer, .observer);
    var prepared = try reg.prepareControllerTakeover(1, observer);
    const committed = try reg.commitControllerTransition(&prepared);
    try testing.expect(committed.revoked_controller == null);
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, observer),
        Capability.input,
    ));
    try testing.expectError(
        error.NotObserver,
        reg.prepareControllerTakeover(1, observer),
    );
    try testing.expectEqual(@as(u64, 1), reg.get(1).?.controller_generation);
}

test "registry: controller generation exhaustion leaves authority unchanged" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    const controller = subscription_identity.SubscriptionId{ .value = 100 };
    const observer = subscription_identity.SubscriptionId{ .value = 200 };
    _ = try reg.attachSubscription(1, controller, .controller);
    _ = try reg.attachSubscription(1, observer, .observer);
    reg.get(1).?.controller_generation = std.math.maxInt(u64);
    try testing.expectError(
        error.ControllerGenerationExhausted,
        reg.prepareControllerTakeover(1, observer),
    );
    try testing.expect(Capability.has(
        reg.capabilitiesOfSubscription(1, controller),
        Capability.input,
    ));
    try testing.expectEqual(
        Capability.observe,
        reg.capabilitiesOfSubscription(1, observer),
    );
}

test "registry: controller detach releases without auto-promoting an observer" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.attach(1, 200, .observer);

    const d = try reg.detach(1, 100);
    try testing.expect(d.was_controller);
    // observer 200은 자동 승격되지 않는다 — 여전히 observe만.
    try testing.expectEqual(@as(u8, Capability.observe), reg.capabilitiesOf(1, 200));
    try testing.expectEqual(@as(u8, 0), reg.capabilitiesOf(1, 100)); // detach됨
    // observer detach.
    const d2 = try reg.detach(1, 200);
    try testing.expect(d2.was_observer and !d2.was_controller);
}

test "registry: resize applies only for controller, bumps generation only on real change" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.attach(1, 200, .observer);

    // observer는 resize 불가.
    try testing.expectError(error.NotController, reg.resize(1, 200, 100, 30, 1));

    // controller resize → applied, changed, generation 1.
    const r1 = try reg.resize(1, 100, 100, 30, 1);
    try testing.expectEqual(@as(u16, 100), r1.applied.cols);
    try testing.expect(r1.applied.changed);
    try testing.expectEqual(@as(u64, 1), r1.applied.resize_generation);

    // 같은 크기 재요청(새 sequence) → applied이지만 changed=false, generation 유지.
    const r2 = try reg.resize(1, 100, 100, 30, 2);
    try testing.expect(!r2.applied.changed);
    try testing.expectEqual(@as(u64, 1), r2.applied.resize_generation);

    // stale sequence(<= last) → 무시.
    try testing.expectEqual(ResizeOutcome.stale, try reg.resize(1, 100, 50, 10, 2));

    // clamp: cols=1 → 2, rows=0 → 1.
    const r3 = try reg.resize(1, 100, 1, 0, 3);
    try testing.expectEqual(min_cols, r3.applied.cols);
    try testing.expectEqual(min_rows, r3.applied.rows);
}

test "registry: sequence 0 is a valid first resize but a replayed 0 is stale" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);

    // client_sequence=0을 첫 resize로 쓰는 client도 정상 적용된다(0이 sentinel과 겹치지 않음).
    const r0 = try reg.resize(1, 100, 100, 30, 0);
    try testing.expect(r0.applied.changed);
    // 같은 seq=0 재전송(중복/재생)은 stale로 무시되고, 첫 적용 크기를 되돌리지 못한다.
    try testing.expectEqual(ResizeOutcome.stale, try reg.resize(1, 100, 120, 40, 0));
    const e = reg.get(1).?;
    try testing.expectEqual(@as(u16, 100), e.cols);
    try testing.expectEqual(@as(u16, 30), e.rows);
    // 다음 유효 sequence(1)는 적용된다.
    const r1 = try reg.resize(1, 100, 120, 40, 1);
    try testing.expect(r1.applied.changed);
    // takeover한 새 controller는 sequence 창이 리셋돼 다시 seq=0을 받아들인다.
    _ = try reg.attach(1, 200, .observer);
    var prepared = try reg.prepareControllerTakeover(1, .{ .value = 200 });
    _ = try reg.commitControllerTransition(&prepared);
    const r2 = try reg.resize(1, 200, 90, 20, 0);
    try testing.expect(r2.applied.changed);
}

test "registry: resize generation exhaustion leaves size sequence and ledger unchanged" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    entry.resize_generation = resize_wire.max_counter;
    const before_cells = reg.liveGridCells();
    try testing.expectError(
        error.ResizeGenerationExhausted,
        reg.prepareResizeSubscription(
            1,
            .{ .value = 100 },
            100,
            30,
            1,
        ),
    );
    try testing.expectEqual(@as(u16, 80), entry.cols);
    try testing.expect(!entry.resize_seq_seen);
    try testing.expectEqual(@as(u64, 0), entry.controller_sequence);
    try testing.expectEqual(before_cells, reg.liveGridCells());
}

test "registry: prepared resize cannot commit twice or after authority changes" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    var prepared = try reg.prepareResizeSubscription(
        1,
        .{ .value = 100 },
        100,
        30,
        1,
    );
    var stale_copy = prepared;
    _ = try reg.commitResizeSubscription(&prepared);
    try testing.expectError(
        error.StalePreparedResize,
        reg.commitResizeSubscription(&prepared),
    );
    try testing.expectError(
        error.StalePreparedResize,
        reg.commitResizeSubscription(&stale_copy),
    );

    _ = try reg.attach(1, 200, .observer);
    var before_takeover = try reg.prepareResizeSubscription(
        1,
        .{ .value = 100 },
        120,
        40,
        2,
    );
    var takeover = try reg.prepareControllerTakeover(1, .{ .value = 200 });
    _ = try reg.commitControllerTransition(&takeover);
    try testing.expectError(
        error.StalePreparedResize,
        reg.validatePreparedResize(&before_takeover),
    );

    // Returning authority to the original subscription cannot revive a token from an older
    // controller generation even when size/sequence fields happen to match again.
    var reg_aba = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg_aba.deinit();
    _ = try reg_aba.register(2, 80, 24);
    _ = try reg_aba.attach(2, 300, .controller);
    _ = try reg_aba.attach(2, 400, .observer);
    var before_aba = try reg_aba.prepareResizeSubscription(
        2,
        .{ .value = 300 },
        100,
        30,
        1,
    );
    var to_second = try reg_aba.prepareControllerTakeover(2, .{ .value = 400 });
    _ = try reg_aba.commitControllerTransition(&to_second);
    var back_to_first = try reg_aba.prepareControllerTakeover(2, .{ .value = 300 });
    _ = try reg_aba.commitControllerTransition(&back_to_first);
    try testing.expectError(
        error.StalePreparedResize,
        reg_aba.validatePreparedResize(&before_aba),
    );
}

test "registry: prepared resize applies a delta without overwriting sibling ledger changes" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    var prepared = try reg.prepareResizeSubscription(
        1,
        .{ .value = 100 },
        100,
        30,
        1,
    );
    _ = try reg.register(2, 40, 10);
    _ = try reg.commitResizeSubscription(&prepared);
    try testing.expectEqual(
        @as(usize, 100 * 30 + 40 * 10),
        reg.liveGridCells(),
    );
}

test "registry: canonical size survives all clients detaching (client 0)" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 100, .controller);
    _ = try reg.resize(1, 100, 132, 43, 1);
    _ = try reg.detach(1, 100); // client 0
    const e = reg.get(1).?;
    try testing.expectEqual(@as(u16, 132), e.cols);
    try testing.expectEqual(@as(u16, 43), e.rows);
    // 재attach한 새 controller는 sequence 창이 리셋돼 첫 resize가 stale로 막히지 않는다.
    _ = try reg.attach(1, 300, .controller);
    const r = try reg.resize(1, 300, 100, 30, 1);
    try testing.expect(r.applied.changed);
}

test "registry: server can stash an opaque runtime handle on the entry" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    var fake_runtime: u32 = 7;
    const e = try reg.register(1, 80, 24);
    e.runtime = &fake_runtime; // server가 실 LivePtySession/TerminalCore handle을 여기 싣는다(state machine 미해석).
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&fake_runtime)), reg.get(1).?.runtime.?);
}

test "registry: restored registration publishes generation and handle atomically" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var fake_runtime: u32 = 9;
    const entry = try registry.registerRestored(0xAA, 120, 40, 77, &fake_runtime);
    try testing.expectEqual(@as(u64, 77), entry.resize_generation);
    try testing.expectEqual(@as(?StreamId, null), entry.controller);
    try testing.expectEqual(@as(usize, 0), entry.observers.items.len);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&fake_runtime)), entry.runtime.?);
}

test "registry: restored generation is bounded by the JSON wire counter" {
    var registry = TerminalRuntimeRegistry.init(testing.allocator);
    defer registry.deinit();
    var fake_runtime: u32 = 9;
    _ = try registry.registerRestored(
        0xAA,
        120,
        40,
        resize_wire.max_counter,
        &fake_runtime,
    );
    try testing.expectError(
        error.ResizeGenerationExhausted,
        registry.registerRestored(
            0xBB,
            120,
            40,
            resize_wire.max_counter + 1,
            &fake_runtime,
        ),
    );
    try testing.expect(registry.get(0xBB) == null);
}

test "S11-6 선언은 슬롯이 든다 — 채널이 닫히면 선언도 사라진다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 7, .observer);

    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 7, 50, 37));
    const declared = (try reg.observerSlots(1))[0].declared.?;
    try testing.expectEqual(@as(u16, 50), declared.cols);
    try testing.expectEqual(@as(u16, 37), declared.rows);

    // **폰이 죽거나 전파가 끊겨 채널이 닫힌다.** 이때 선언이 어딘가에 남으면 그 세션은 영영 작은
    // 채로 굳는다 — 전역 표로 두지 않고 슬롯에 실은 이유가 이것이다.
    _ = try reg.detach(1, 7);
    try testing.expectEqual(@as(usize, 0), (try reg.observerSlots(1)).len);

    // 같은 stream id 가 다시 붙어도 **남의(옛) 선언을 물려받지 않는다**.
    _ = try reg.attach(1, 7, .observer);
    try testing.expectEqual(@as(?Viewport, null), (try reg.observerSlots(1))[0].declared);
}

test "S11-6 거둠·버림·무변화를 가른다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 7, .observer);

    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 7, 50, 37));
    // **폭풍을 여기서 접는다** — 회전 애니메이션·폰트 슬라이더가 같은 값을 연달아 보낸다.
    try testing.expectEqual(DeclareViewportOutcome.unchanged, try reg.declareViewport(1, 7, 50, 37));
    // 한 축만 달라도 새 선언이다.
    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 7, 50, 40));

    // **한쪽만 0 은 버린다 — 그리고 슬롯은 그대로다.** 조용히 반쪽만 받으면 그 client 는 자기가
    // 뭘 요청했는지 모른다.
    try testing.expectEqual(DeclareViewportOutcome.invalid, try reg.declareViewport(1, 7, 0, 40));
    try testing.expectEqual(DeclareViewportOutcome.invalid, try reg.declareViewport(1, 7, 50, 0));
    try testing.expectEqual(@as(u16, 50), (try reg.observerSlots(1))[0].declared.?.cols);
    try testing.expectEqual(@as(u16, 40), (try reg.observerSlots(1))[0].declared.?.rows);

    // 둘 다 0 이면 거둔다 — 붙어 있되 크기에 영향을 안 준다.
    try testing.expectEqual(DeclareViewportOutcome.withdrawn, try reg.declareViewport(1, 7, 0, 0));
    try testing.expectEqual(@as(?Viewport, null), (try reg.observerSlots(1))[0].declared);
    // 거둔 뒤 또 거두는 것은 아무 일도 아니다.
    try testing.expectEqual(DeclareViewportOutcome.unchanged, try reg.declareViewport(1, 7, 0, 0));
}

test "S11-6 선언할 수 있는 것은 붙어 있는 observer 뿐이다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 11, .controller);
    _ = try reg.attach(1, 7, .observer);

    // **controller 는 선언하지 않는다** — 제 크기를 스스로 정하는 쪽이라 알릴 대상이 없다.
    try testing.expectError(error.NotObserver, reg.declareViewport(1, 11, 50, 37));
    // 안 붙은 자도 못 한다.
    try testing.expectError(error.NotObserver, reg.declareViewport(1, 99, 50, 37));
    try testing.expectError(error.RuntimeNotFound, reg.declareViewport(2, 7, 50, 37));
}

test "S11-6 controller 인수인계가 남의 선언을 안 건드린다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 11, .controller);
    _ = try reg.attach(1, 7, .observer);
    _ = try reg.attach(1, 8, .observer);
    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 7, 50, 37));
    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 8, 44, 30));

    // controller 가 물러난다 — observer 배열이 통째로 갈아 끼워지는 자리다. 선언이 평행 배열에
    // 있었다면 여기서 조용히 어긋난다.
    const sub = subscription_identity.SubscriptionId{ .value = 11 };
    var prepared = try reg.prepareControllerRelease(1, sub);
    _ = try reg.commitControllerTransition(&prepared);

    const slots = try reg.observerSlots(1);
    try testing.expectEqual(@as(usize, 3), slots.len);
    for (slots) |slot| switch (slot.stream) {
        7 => try testing.expectEqual(@as(u16, 50), slot.declared.?.cols),
        8 => try testing.expectEqual(@as(u16, 44), slot.declared.?.cols),
        // **물러난 controller 는 선언 없이 들어온다.** 여기서 뭔가 실리면 그것이 곧 자기 자신을
        // 좁히는 선언이 된다.
        11 => try testing.expectEqual(@as(?Viewport, null), slot.declared),
        else => return error.UnexpectedObserver,
    };
}

test "S11-6 준비와 커밋 사이에 온 선언은 인수인계를 무효로 만들지 않는다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    _ = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 11, .controller);
    _ = try reg.attach(1, 7, .observer);

    const sub = subscription_identity.SubscriptionId{ .value = 11 };
    var prepared = try reg.prepareControllerRelease(1, sub);

    // **그 사이에 폰이 회전한다.** 이 검증이 지키는 것은 「붙거나 떨어진 자가 있는가」이지
    // 「누가 무엇을 알렸는가」가 아니다 — 선언까지 견주면 화면 한 번 돌린 것이 controller
    // 인수인계를 깨뜨린다.
    try testing.expectEqual(DeclareViewportOutcome.declared, try reg.declareViewport(1, 7, 50, 37));

    _ = try reg.commitControllerTransition(&prepared);
    try testing.expectEqual(@as(?StreamId, null), reg.get(1).?.controller);
    try testing.expectEqual(@as(usize, 2), (try reg.observerSlots(1)).len);
}

test "S11-6 조정: 선언이 없으면 아무것도 안 바꾼다" {
    // **기준도 안 잡는다** — 이 기능이 없던 때와 완전히 같아야 한다.
    try testing.expectEqual(@as(?u16, null), reconciledViewportCols(&.{}, 80));
    const silent = [_]ObserverSlot{ .{ .stream = 1 }, .{ .stream = 2 } };
    try testing.expectEqual(@as(?u16, null), reconciledViewportCols(&silent, 80));
}

test "S11-6 조정: 가장 작은 선언을 따르되 기준을 넘지 않는다" {
    const one = [_]ObserverSlot{.{ .stream = 1, .declared = .{ .cols = 50, .rows = 37 } }};
    try testing.expectEqual(@as(?u16, 50), reconciledViewportCols(&one, 80));

    // 여럿이면 가장 작은 것.
    const many = [_]ObserverSlot{
        .{ .stream = 1, .declared = .{ .cols = 50, .rows = 37 } },
        .{ .stream = 2 },
        .{ .stream = 3, .declared = .{ .cols = 44, .rows = 30 } },
    };
    try testing.expectEqual(@as(?u16, 44), reconciledViewportCols(&many, 80));

    // **줄이기만 한다** — 폰이 자기보다 큰 값을 불러 맥 창을 늘리지 못한다.
    const wide = [_]ObserverSlot{.{ .stream = 1, .declared = .{ .cols = 200, .rows = 60 } }};
    try testing.expectEqual(@as(?u16, 80), reconciledViewportCols(&wide, 80));
}

test "S11-6 조정: 바닥이 있고, 그 바닥이 세션을 «늘리지» 않는다" {
    // 바닥 아래로는 안 줄인다 — 1열로 접어 세션을 못 쓰게 만드는 것을 막는다.
    const tiny = [_]ObserverSlot{.{ .stream = 1, .declared = .{ .cols = 1, .rows = 1 } }};
    try testing.expectEqual(@as(?u16, viewport_floor_cols), reconciledViewportCols(&tiny, 80));

    // **여기가 괄호 순서가 걸리는 자리다.** `min_cols` 가 2 라 2열 세션은 실재한다. 뒤집어 적으면
    // (`max(바닥, min(기준, 선언))`) 폰이 붙는 것만으로 **없던 8열이 생긴다**.
    try testing.expectEqual(@as(?u16, 2), reconciledViewportCols(&tiny, 2));
    const phone = [_]ObserverSlot{.{ .stream = 1, .declared = .{ .cols = 50, .rows = 37 } }};
    try testing.expectEqual(@as(?u16, 2), reconciledViewportCols(&phone, 2));
    // 기준이 바닥과 같으면 그대로.
    try testing.expectEqual(@as(?u16, 10), reconciledViewportCols(&phone, 10));
}

test "S11-6 기준: 첫 선언에 기억하고, 마지막 선언이 사라지면 그리로 돌아온다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 7, .observer);

    // 선언 전에는 기준을 안 잡는다 — 이 기능이 없던 때와 같다.
    try testing.expectEqual(ViewportPlan.unchanged, try reg.planViewport(1));
    try testing.expectEqual(@as(?u16, null), entry.viewport_baseline_cols);

    // **첫 선언**: 지금 크기가 기준이 되고, 세션은 선언한 열로 줄어야 한다.
    _ = try reg.declareViewport(1, 7, 50, 37);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 50 }, try reg.planViewport(1));
    try testing.expectEqual(@as(?u16, 80), entry.viewport_baseline_cols);

    // caller 가 적용했다고 하자.
    entry.cols = 50;
    try testing.expectEqual(ViewportPlan.unchanged, try reg.planViewport(1));

    // **마지막 선언이 사라지면 기준으로 돌아온다.** 여기가 「폰 크기로 영영 굳는다」를 막는 자리다.
    _ = try reg.detach(1, 7);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 80 }, try reg.planViewport(1));
    // 돌아왔으면 기준도 놓는다 — 다음 폰이 붙을 때 그때 크기를 새로 기억해야 한다.
    try testing.expectEqual(@as(?u16, null), entry.viewport_baseline_cols);
}

test "S11-6 기준: controller 가 없어도 되돌아온다 — headless keep-alive" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    // **controller 가 없다** — 맥 앱이 꺼지고 세션만 살아 있는 모양.
    try testing.expectEqual(@as(?StreamId, null), entry.controller);
    _ = try reg.attach(1, 7, .observer);
    _ = try reg.declareViewport(1, 7, 50, 37);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 50 }, try reg.planViewport(1));
    entry.cols = 50;

    _ = try reg.detach(1, 7);
    // controller 로 기준을 잡았다면 여기서 돌아갈 데가 없어 50 열로 굳었을 것이다.
    try testing.expectEqual(ViewportPlan{ .resize_cols = 80 }, try reg.planViewport(1));
}

test "S11-6 기준: 거둠도 마지막 선언이 사라진 것과 같다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 7, .observer);
    _ = try reg.declareViewport(1, 7, 50, 37);
    _ = try reg.planViewport(1);
    entry.cols = 50;

    // 붙어 있되 선언만 거둔다(둘 다 0).
    try testing.expectEqual(DeclareViewportOutcome.withdrawn, try reg.declareViewport(1, 7, 0, 0));
    try testing.expectEqual(ViewportPlan{ .resize_cols = 80 }, try reg.planViewport(1));
    try testing.expectEqual(@as(?u16, null), entry.viewport_baseline_cols);
}

test "S11-6 기준: 둘이 붙었다 하나만 떨어지면 남은 쪽을 따른다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 7, .observer);
    _ = try reg.attach(1, 8, .observer);
    _ = try reg.declareViewport(1, 7, 50, 37);
    _ = try reg.declareViewport(1, 8, 44, 30);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 44 }, try reg.planViewport(1));
    entry.cols = 44;

    // 작은 쪽이 떠나면 큰 쪽으로 **넓어진다** — 기준까지는 되돌릴 수 있다.
    _ = try reg.detach(1, 8);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 50 }, try reg.planViewport(1));
    // 아직 선언이 남아 있으니 기준은 유지된다.
    try testing.expectEqual(@as(?u16, 80), entry.viewport_baseline_cols);
}

test "S11-6 기준: controller 가 창을 조절하면 그쪽이 이긴다 — 기준이 갱신된다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 11, .controller);
    _ = try reg.attach(1, 7, .observer);
    _ = try reg.declareViewport(1, 7, 50, 37);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 50 }, try reg.planViewport(1));
    entry.cols = 50; // caller 가 적용했다.
    try testing.expectEqual(@as(?u16, 80), entry.viewport_baseline_cols);

    // 사용자가 맥 창을 넓힌다(controller 리사이즈).
    const sub = subscription_identity.SubscriptionId{ .value = 11 };
    var prepared = try reg.prepareResizeSubscription(1, sub, 100, 24, 1);
    _ = try reg.commitResizeSubscription(&prepared);
    // **기준이 갱신된다** — 「폰이 없었으면 100 열이었을 것」이다.
    try testing.expectEqual(@as(?u16, 100), entry.viewport_baseline_cols);

    // 그래도 폰이 붙어 있는 동안은 폰을 따른다 — caller 가 한 번 더 줄인다.
    try testing.expectEqual(ViewportPlan{ .resize_cols = 50 }, try reg.planViewport(1));
    entry.cols = 50;

    // 폰이 떠나면 **갱신된** 기준으로 돌아온다(80 이 아니라 100).
    _ = try reg.detach(1, 7);
    try testing.expectEqual(ViewportPlan{ .resize_cols = 100 }, try reg.planViewport(1));
}

test "S11-6 기준: 선언이 없으면 controller 리사이즈가 기준을 만들지 않는다" {
    var reg = TerminalRuntimeRegistry.init(testing.allocator);
    defer reg.deinit();
    const entry = try reg.register(1, 80, 24);
    _ = try reg.attach(1, 11, .controller);
    const sub = subscription_identity.SubscriptionId{ .value = 11 };
    var prepared = try reg.prepareResizeSubscription(1, sub, 100, 24, 1);
    _ = try reg.commitResizeSubscription(&prepared);
    // 이 기능이 없던 때와 같아야 한다.
    try testing.expectEqual(@as(?u16, null), entry.viewport_baseline_cols);
    try testing.expectEqual(ViewportPlan.unchanged, try reg.planViewport(1));
}
