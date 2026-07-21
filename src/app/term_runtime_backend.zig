//! TermRuntimeBackend — terminal runtime(PTY + 셸 프로세스)의 수명·입출력·관측을 GUI layout에서
//! 분리하는 vtable 계약(docs/persistent-session-host.md §13 P2).
//!
//! 왜 필요한가: 지금까지 GUI layout(`Model(TermRuntime).Term`의 `rt.live_pty`)은 `*app.LivePtySession`을
//! **직접 포인터로** 들고 spawn/attach/pump/close/foreground 관측을 그 위에서 불렀다. 이 직접 결합은
//! "GUI가 프로세스 경계를 안다"는 뜻이라, 앱 프로세스 밖(`maru-sessiond`)에 runtime을 두는 P3 이후로 갈 수
//! 없다. 이 계약은 그 결합을 **opaque `RuntimeHandle` + vtable** 하나로 바꾼다 — GUI는 handle과 이 계약만
//! 쥐고, 실제 runtime이 in-process인지 원격 host인지 모른다.
//!
//! 계약 형태(vtable): 기존 `runtime.PtyIo`(ctx + fn 포인터)와 **같은 관용구**다. `ctx`는 backend 구현
//! 인스턴스를, `vtable`은 그 구현의 함수 표를 가리킨다. P2 현재 유일한 구현은 in-process adapter
//! (`in_process_term_backend.zig` — 기존 `LiveSurfaceRegistry` + `LivePtySession` + `SurfaceRuntime`을 감쌈)이고,
//! P3의 `maru-sessiond` backend가 **같은 계약 뒤에** 들어온다(계약은 이 파일, transport는 별도 — 한 파일에
//! GUI layout 정책과 session-host transport를 섞지 않는다, docs/project-structure.md).
//!
//! 레이어: `src/app`(L4)이라 pty/session/terminal을 자유롭게 import한다(tests/boundary/imports.zig는 app에
//! forbidden 규칙을 두지 않는다). GUI layout(`session_model.Term`)은 이 계약 타입만 알고 `LivePtySession`을
//! 모른다 — 그것이 P2의 seam 목표다.
//!
//! 스레드: 모든 계약 호출은 메인 스레드 전용이다(surface_id·세션 트리·createTerm/destroyTerm 계약과 동일).
//! reader 스레드는 backend 내부에서 core에 직접 쓰고(setProcessing) 이 계약 표면을 건드리지 않는다.

const std = @import("std");
const terminal = @import("../terminal.zig");
const pty = @import("../pty.zig");
const surface_mod = @import("../session/surface.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const core_command = @import("../session/core_command.zig");

/// terminal runtime 하나를 가리키는 opaque 상관키. **의미를 비트에 인코딩하지 않는다.**
///
/// P2 in-process backend에서는 앱 전역 `SurfaceIdAllocator`가 발급한 `surface_id`(=`pty_id`)를 그대로 값으로
/// 쓴다 — 이미 `SurfaceRuntime`/`LiveSurfaceRegistry`가 surface_id 키드라 매핑이 1:1이다. 하지만 GUI는 이 값을
/// surface_id로 **해석하면 안 되고** backend에 되돌려 주는 불투명 handle로만 다뤄야 한다. P3에서 host가 발급하는
/// `runtime_id`(host process를 건너는 128-bit opaque)로 승격될 자리라, 지금 u64 별칭으로 그 경계를 미리 긋는다
/// (docs/persistent-session-host.md §4 `runtime_id`).
pub const RuntimeHandle = u64;

/// 새 terminal runtime을 만들 때 필요한 입력. `handle`은 caller(GUI)가 앱 전역 allocator에서 발급해 넘긴다 —
/// backend가 발급하지 않는 이유는 in-process에서 handle이 곧 surface_id이고, surface_id 발급은 GUI layout(창 트리
/// 정책)의 책임이기 때문이다(P3 host backend는 host가 발급한 runtime_id를 이 자리에 다시 매핑한다).
pub const SpawnParams = struct {
    handle: RuntimeHandle,
    /// 셸/argv/cwd/env/login 등 프로세스 스펙. `pane_id`는 caller가 handle과 같은 값으로 채운다(control-plane self selector).
    request: pty.SpawnRequest,
    /// 초기 grid 크기. `request.size`와 별도로 받는다 — createTerm이 창 레이아웃에서 계산한 pane 크기를 쓰기 때문.
    size: terminal.Size,
    /// PTY→core 출력 이벤트 큐 용량(bounded).
    queue_capacity: usize,
};

/// backend 구현이 채워 넣는 함수 표. 모든 함수의 첫 인자는 `ctx`(구현 인스턴스)다. 에러는 `anyerror`로 둔다 —
/// in-process는 `RuntimeError || Thread.SpawnError || 프로세스 spawn 오류`, 원격 host는 transport 오류라 구현마다
/// 에러 집합이 달라서, vtable 고정 시그니처는 `anyerror`가 유일하게 맞는 선택이다(PtyIo도 `anyerror`를 쓴다).
pub const VTable = struct {
    /// terminal runtime(PTY + 셸)을 만든다. 반환값은 그 runtime에 붙은 **복구 가능한 `Surface`**(그리드/스크롤백/
    /// 메타)의 안정 포인터다 — GUI는 이 포인터를 `Term.surface`로 참조만 하고(소유는 backend), config 설정(스크롤백
    /// arena/palette 등)을 여기에 적용한다. live PTY handle은 반환하지 않는다(그것이 seam 목표). 아직 `attach`
    /// 전이라 output 처리는 시작되지 않는다.
    spawn: *const fn (ctx: *anyopaque, params: SpawnParams) anyerror!*surface_mod.Surface,

    /// runtime의 PTY를 그 surface에 연결해 output 처리를 시작한다. `process_in_reader=true`(interactive 셸)면
    /// reader가 output을 코어에 직접 반영하고 메인 입력을 write 큐로 라우팅한다(docs/io-render-threading.md PR3).
    attach: *const fn (ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink,

    /// 이 runtime의 이벤트 펌프. 호출자(frame loop)가 `drainAvailable`로 output/exit를 surface에 반영한다.
    pump: *const fn (ctx: *anyopaque, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump,

    /// 이미 terminal input으로 분류된 bytes를 runtime PTY로 보낸다(keybinding 해석 없음 — app/config 책임).
    write_input: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void,

    /// 지금 쓸 수 있는 만큼만 쓰고 쓴 길이를 돌려준다(paste가 UI tick을 동결시키지 않게). 0=다음 tick 재시도.
    write_input_nonblocking: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize,

    /// 메인발 코어 mutate(스크롤/선택/IME 등)를 reader 스레드로 위임한다(docs/io-render-threading.md §9 Phase 3).
    enqueue_core_command: *const fn (ctx: *anyopaque, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void,

    /// grid 크기를 바꾼다 — 코어 resize와 PTY winsize(`TIOCSWINSZ`)를 한 user action으로 함께 적용한다.
    resize: *const fn (ctx: *anyopaque, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void,

    /// runtime routing을 끊고(late output 거부) PTY/자식/reader를 종료한다. 멱등 — 실제 탭/창 close의 수명 경계.
    close_and_detach: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// PTY/자식/reader를 종료하되 runtime routing detach는 하지 않는다(routing이 이미 없는 조기 실패/앱 종료 경로).
    close: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// exit/read_error 관측 후 reader join + 큐 close로 마무리한다. `close`와 달리 "이미 종료가 관측된" 경로용.
    finish_after_termination: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// runtime의 소유 슬롯(surface + live PTY 번들)을 해제한다. `close_and_detach`/`close`로 종료를 끝낸 뒤 부른다.
    /// 이 호출 뒤 handle과 `spawn`이 돌려준 surface 포인터는 무효다(dangling — 이후 접근 금지).
    remove: *const fn (ctx: *anyopaque, handle: RuntimeHandle) void,

    /// 포그라운드 process group id(agent observer용). runtime이 없거나 PTY가 없으면 null. 관통 관측이지 제어가 아니다.
    foreground_process_group: *const fn (ctx: *anyopaque, handle: RuntimeHandle) ?i32,

    /// 포그라운드 프로세스 이름들을 `out`에 채우고 채운 개수를 돌려준다(agent kind 분류용). 고정 버퍼라 alloc 없음.
    foreground_process_names: *const fn (ctx: *anyopaque, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize,
};

/// GUI layout이 terminal runtime을 다루는 유일한 표면. `ctx`+`vtable`로 in-process/원격 host 구현을 같은 계약
/// 뒤에 둔다. 값 타입(포인터 두 개)이라 복사가 싸고 `Term`이 직접 들거나 `AppSession`이 하나 들고 handle로 라우팅해도 된다.
pub const TermRuntimeBackend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn spawn(self: TermRuntimeBackend, params: SpawnParams) anyerror!*surface_mod.Surface {
        return self.vtable.spawn(self.ctx, params);
    }

    pub fn attach(self: TermRuntimeBackend, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink {
        return self.vtable.attach(self.ctx, handle, process_in_reader);
    }

    pub fn pump(self: TermRuntimeBackend, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump {
        return self.vtable.pump(self.ctx, handle);
    }

    pub fn writeInput(self: TermRuntimeBackend, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        return self.vtable.write_input(self.ctx, handle, bytes);
    }

    pub fn writeInputNonBlocking(self: TermRuntimeBackend, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        return self.vtable.write_input_nonblocking(self.ctx, handle, bytes);
    }

    pub fn enqueueCoreCommand(self: TermRuntimeBackend, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void {
        return self.vtable.enqueue_core_command(self.ctx, handle, cmd, io);
    }

    pub fn resize(self: TermRuntimeBackend, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void {
        return self.vtable.resize(self.ctx, handle, size, io);
    }

    pub fn closeAndDetach(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.close_and_detach(self.ctx, handle);
    }

    pub fn close(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.close(self.ctx, handle);
    }

    pub fn finishAfterTermination(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.finish_after_termination(self.ctx, handle);
    }

    pub fn remove(self: TermRuntimeBackend, handle: RuntimeHandle) void {
        self.vtable.remove(self.ctx, handle);
    }

    pub fn foregroundProcessGroup(self: TermRuntimeBackend, handle: RuntimeHandle) ?i32 {
        return self.vtable.foreground_process_group(self.ctx, handle);
    }

    pub fn foregroundProcessNames(self: TermRuntimeBackend, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize {
        return self.vtable.foreground_process_names(self.ctx, handle, out);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Fake backend + 계약 단위 테스트
//
// 이 테스트들이 증명하는 것(그리고 터미널에서 왜 중요한가): P2 seam의 핵심 약속은 "GUI가 `*LivePtySession`을
// 직접 들지 않고 `TermRuntimeBackend` 계약 + opaque handle만으로 terminal runtime 하나의 수명 전체(spawn →
// attach → input/resize → terminate)를 몰고, detach 뒤에는 죽은 runtime으로 가는 입력이 거부된다"는 것이다.
// 이 계약이 실제 PTY 없이도 성립함을 fake backend로 고정한다 — 실 PTY(macOS) 경로는 in-process adapter의 별도
// 통합 테스트가 검증하고, 여기서는 순수 Zig로 계약 표면(라우팅·수명·late-event)만 본다.
//
// fake는 실제 `SurfaceRuntime`을 재사용해 라우팅을 진짜로 검증한다(빈 목킹이 아니다). PTY만 `FakeBackendPty`
// (writes 기록 더블)로 대체한다.
// ─────────────────────────────────────────────────────────────────────────────

/// fake backend 안에서 한 runtime을 대신하는 최소 상태. 실제 PTY 대신 입력 bytes를 기록하고, output 이벤트 큐
/// 하나를 소유해 `pump`가 유효한 `RuntimeEventPump`를 돌려줄 수 있게 한다.
const FakeBackendRuntime = struct {
    surface: *surface_mod.Surface,
    writes: std.ArrayList(u8) = .empty,
    resized_to: ?terminal.Size = null,
    attached: bool = false,
    detached: bool = false,
    closed: bool = false,

    fn writeInput(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *FakeBackendRuntime = @ptrCast(@alignCast(ctx));
        try self.writes.appendSlice(std.testing.allocator, bytes);
    }

    fn resizeIo(ctx: *anyopaque, size: terminal.Size) anyerror!void {
        const self: *FakeBackendRuntime = @ptrCast(@alignCast(ctx));
        self.resized_to = size;
    }

    fn ptyIo(self: *FakeBackendRuntime) runtime_mod.PtyIo {
        return .{ .ctx = self, .write_input = writeInput, .resize_fn = resizeIo };
    }
};

/// 테스트 전용 in-memory backend. 계약 vtable을 실제 `SurfaceRuntime` 라우팅 + `FakeBackendRuntime` PTY 더블로
/// 구현한다. handle → runtime 매핑은 작은 선형 리스트(테스트 규모라 충분).
const FakeTermBackend = struct {
    allocator: std.mem.Allocator,
    runtime: runtime_mod.SurfaceRuntime,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { handle: RuntimeHandle, rt: *FakeBackendRuntime };

    const vtable = VTable{
        .spawn = spawn,
        .attach = attach,
        .pump = pump,
        .write_input = writeInput,
        .write_input_nonblocking = writeInputNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .resize = resize,
        .close_and_detach = closeAndDetach,
        .close = close,
        .finish_after_termination = finishAfterTermination,
        .remove = remove,
        .foreground_process_group = foregroundProcessGroup,
        .foreground_process_names = foregroundProcessNames,
    };

    fn init(allocator: std.mem.Allocator) FakeTermBackend {
        return .{ .allocator = allocator, .runtime = runtime_mod.SurfaceRuntime.init(allocator) };
    }

    fn deinit(self: *FakeTermBackend) void {
        for (self.entries.items) |e| {
            e.rt.writes.deinit(self.allocator);
            e.rt.surface.deinit();
            self.allocator.destroy(e.rt.surface);
            self.allocator.destroy(e.rt);
        }
        self.entries.deinit(self.allocator);
        self.runtime.deinit();
    }

    fn backend(self: *FakeTermBackend) TermRuntimeBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn find(self: *FakeTermBackend, handle: RuntimeHandle) ?*FakeBackendRuntime {
        for (self.entries.items) |e| if (e.handle == handle) return e.rt;
        return null;
    }

    fn spawn(ctx: *anyopaque, params: SpawnParams) anyerror!*surface_mod.Surface {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const surface = try self.allocator.create(surface_mod.Surface);
        errdefer self.allocator.destroy(surface);
        surface.* = try surface_mod.Surface.init(self.allocator, params.handle, params.size);
        errdefer surface.deinit();
        const rt = try self.allocator.create(FakeBackendRuntime);
        errdefer self.allocator.destroy(rt);
        rt.* = .{ .surface = surface };
        try self.entries.append(self.allocator, .{ .handle = params.handle, .rt = rt });
        return surface;
    }

    fn attach(ctx: *anyopaque, handle: RuntimeHandle, process_in_reader: bool) anyerror!runtime_mod.RuntimeLink {
        _ = process_in_reader;
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        const rt = self.find(handle) orelse return error.UnknownSurface;
        const link = try self.runtime.attach(rt.surface, handle, rt.ptyIo());
        rt.attached = true;
        return link;
    }

    fn pump(ctx: *anyopaque, handle: RuntimeHandle) anyerror!runtime_pump.RuntimeEventPump {
        _ = ctx;
        _ = handle;
        // fake는 실제 이벤트 큐를 돌리지 않는다(계약 표면 검증용). pump 형태를 갖추는 실 drain 검증은 실 PTY를
        // 쓰는 in-process adapter 통합 테스트가 맡는다. 이 계약 테스트는 spawn/attach/input/resize/terminate만 본다.
        return error.Unsupported;
    }

    fn writeInput(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInput(handle, .{ .bytes = bytes });
    }

    fn writeInputNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.writeInputNonBlocking(handle, bytes);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, cmd: core_command.CoreCommand, io: std.Io) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.enqueueCoreCommand(handle, cmd, io);
    }

    fn resize(ctx: *anyopaque, handle: RuntimeHandle, size: terminal.Size, io: std.Io) anyerror!void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        return self.runtime.resize(handle, size, io);
    }

    fn closeAndDetach(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| {
            self.runtime.detachSurface(handle);
            rt.detached = true;
            rt.closed = true;
        }
    }

    fn close(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| rt.closed = true;
    }

    fn finishAfterTermination(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle)) |rt| rt.closed = true;
    }

    fn remove(ctx: *anyopaque, handle: RuntimeHandle) void {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        for (self.entries.items, 0..) |e, i| {
            if (e.handle == handle) {
                e.rt.writes.deinit(self.allocator);
                e.rt.surface.deinit();
                self.allocator.destroy(e.rt.surface);
                self.allocator.destroy(e.rt);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    fn foregroundProcessGroup(ctx: *anyopaque, handle: RuntimeHandle) ?i32 {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        // fake는 프로세스가 없으니 handle이 살아 있으면 고정 pgid, 없으면 null을 돌려 관측 계약의 유무 분기를 검증한다.
        return if (self.find(handle) != null) @as(i32, 4242) else null;
    }

    fn foregroundProcessNames(ctx: *anyopaque, handle: RuntimeHandle, out: []pty.types.ForegroundProcessName) usize {
        const self: *FakeTermBackend = @ptrCast(@alignCast(ctx));
        if (self.find(handle) == null or out.len == 0) return 0;
        out[0] = .{ .pid = 1, .len = 0 };
        return 1;
    }
};

test "term runtime backend: fake drives spawn/attach/input/resize through the contract only" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    // spawn: GUI는 handle과 반환된 *Surface만 받는다(*LivePtySession 없음).
    const surface = try be.spawn(.{
        .handle = 7,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 20, .rows = 4 },
        .queue_capacity = 8,
    });
    try std.testing.expectEqual(@as(u64, 7), surface.id);

    // attach: routing이 계약을 통해 붙는다.
    _ = try be.attach(7, false);

    // input: handle로 보낸 bytes가 그 runtime의 PTY 더블에 도달한다.
    try be.writeInput(7, "echo hi\n");
    const rt = fake.find(7).?;
    try std.testing.expectEqualStrings("echo hi\n", rt.writes.items);

    // resize: 코어와 PTY(더블) 둘 다 계약을 통해 갱신된다.
    try be.resize(7, .{ .cols = 40, .rows = 10 }, std.testing.io);
    try std.testing.expectEqual(@as(u16, 40), surface.core.size.cols);
    try std.testing.expect(rt.resized_to != null);
    try std.testing.expectEqual(@as(u16, 40), rt.resized_to.?.cols);

    // 관측: 살아 있는 handle은 pgid/이름을 돌려준다(관통 관측 계약).
    try std.testing.expectEqual(@as(?i32, 4242), be.foregroundProcessGroup(7));
    var names: [4]pty.types.ForegroundProcessName = undefined;
    try std.testing.expectEqual(@as(usize, 1), be.foregroundProcessNames(7, &names));
}

test "term runtime backend: closeAndDetach through the contract rejects late input" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    _ = try be.spawn(.{
        .handle = 3,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 10, .rows = 3 },
        .queue_capacity = 4,
    });
    _ = try be.attach(3, false);
    try be.writeInput(3, "before");

    // terminate: routing을 끊는다. 이후 같은 handle로 온 입력은 살아 있는 다른 surface로 새지 않고 거부된다.
    be.closeAndDetach(3);
    try std.testing.expectError(error.UnknownSurface, be.writeInput(3, "late"));

    // 죽은 handle의 관측은 null/0(없음)을 돌려준다.
    try std.testing.expectEqual(@as(?i32, null), be.foregroundProcessGroup(999));
}

test "term runtime backend: unknown handle attach is rejected, not routed to another runtime" {
    const allocator = std.testing.allocator;
    var fake = FakeTermBackend.init(allocator);
    defer fake.deinit();
    const be = fake.backend();

    _ = try be.spawn(.{
        .handle = 1,
        .request = .{ .command = "/bin/sh" },
        .size = .{ .cols = 8, .rows = 2 },
        .queue_capacity = 2,
    });
    // 존재하지 않는 handle을 attach하면 다른 runtime에 잘못 붙지 않고 거부된다.
    try std.testing.expectError(error.UnknownSurface, be.attach(2, false));
}
