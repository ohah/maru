const std = @import("std");
const terminal = @import("../terminal.zig");

pub const ProcessState = enum {
    starting,
    running,
    exited,
};

pub const RestorableSurfaceMetadata = struct {
    id: u64,
    title: []const u8,
    cwd: ?[]const u8,
    command: ?[]const u8,
    size: terminal.Size,
    process_state: ProcessState,
    env: []const []const u8 = &.{},
};

/// 원격 host runtime의 화면 소스 계약(P3-e2e-2c). `Surface`가 로컬 `TerminalCore` 대신 이걸로 화면을 읽을 수 있게 한다 —
/// 렌더는 로컬/원격을 모르게 `surface.renderSnapshot()`/`lockCore`만 부른다(docs/persistent-session-host.md §8 중립 DTO).
/// 구현은 platform 계층(session_host의 `RemoteScreen` = 조립기+CellGrid)이 제공해 주입한다(session→platform 역참조 회피 —
/// `session/`은 이 vtable만 안다). `render_snapshot`이 돌려주는 snapshot은 소스 메모리를 alias하므로 caller가 `lock`/
/// `unlock` 안에서 읽고 복사한다(로컬 `core_mutex` 계약과 동형).
pub const ScreenSource = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render_snapshot: *const fn (ctx: *anyopaque) terminal.RenderSnapshot,
        lock: *const fn (ctx: *anyopaque, io: std.Io) void,
        unlock: *const fn (ctx: *anyopaque, io: std.Io) void,
    };
};

// `Surface`는 [Facade 계약](../../docs/facade-contracts.md)의 단일 출처 이름을 따른다.
// 하나의 사용 가능한 terminal surface(TerminalCore + metadata)를 나타낸다.
// live PtySession handle은 여기 저장하지 않는다. 장차 SurfaceRuntime이
// Surface와 PtySession을 연결하면, workspace restore는 live process handle 없이
// 복구 가능한 metadata만 저장할 수 있다.
// 이 타입은 자신이 tab인지 split인지 window인지 모른다. 그 결정은 상위 app/platform layer가 한다.
pub const Surface = struct {
    id: u64,
    // 자동 제목 — 셸/프로그램이 정하는 값(정적 기본 또는 장차 OSC 0/2). custom_name이 없을 때 표시 폴백.
    title: []const u8 = "shell",
    // 사용자 지정 이름(rename) — 사용자가 직접 붙인 이름. 표시 라벨은 custom_name이 비어있지 않으면 title보다
    // 우선한다(app.label.pick 단일 해석). null=없음. 사용자 입력/복원에서 온 owned 문자열이라 소유자(여기선
    // platform AppSession)가 teardown에서 해제한다(title은 정적/borrowed라 해제 안 함). 단일 출처:
    // docs/workspace-restore.md "사용자 지정 이름(custom_name)과 자동 제목".
    custom_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
    process_state: ProcessState = .starting,
    core: terminal.TerminalCore,
    // 코어 접근을 보호하는 락. 현재는 메인 스레드만 코어를 만져 무경합이지만, I/O–렌더 스레딩
    // 분리(docs/io-render-threading.md)에서 PTY 처리(core.write+응답)가 I/O 스레드로 이동하면
    // 렌더 스레드의 snapshot 읽기와 경합한다. 그 계약을 지금 형식화한다. **attach 이후 Surface를
    // 이동/복사하면 안 된다**(락을 잡는 코드가 포인터를 들고 있음 — reader 포인터 불변식과 동일).
    core_mutex: std.Io.Mutex = .init,
    // 원격 host runtime backing(P3-e2e-2c). null이면 로컬 `core`가 화면 소스다(현행). 설정되면 렌더/락이 이 원격 소스로
    // 갈린다(host의 snapshot/delta를 조립한 화면). 이때 로컬 `core`는 unused placeholder다(원격 runtime의 input/resize/
    // metadata는 backend·host query로 가고 이 core를 만지지 않는다). 소유는 caller(주입한 쪽) — Surface.deinit은 안 건드린다.
    remote: ?ScreenSource = null,

    pub fn init(allocator: std.mem.Allocator, id: u64, size: terminal.Size) !Surface {
        return .{
            .id = id,
            .core = try terminal.TerminalCore.init(allocator, size),
        };
    }

    pub fn deinit(self: *Surface) void {
        self.core.deinit();
    }

    /// core_mutex 취득 — **모든 메인 스레드 코어 접근은 이 래퍼로 잡는다**(직접 `core_mutex.lockUncancelable`
    /// 금지, check-boundaries가 강제). 재진입(락 보유 중 같은 락 재취득 = self-deadlock)을 lock 전에
    /// 디버그 panic으로 노출한다(docs/io-render-threading.md §6-5). reader는 Surface가 없어 같은
    /// owner를 core.owner_dbg.lock으로 직접 공유한다(단일 출처).
    pub fn lockCore(self: *Surface, io: std.Io) void {
        if (self.remote) |r| {
            r.vtable.lock(r.ctx, io); // 원격 backing이면 그 소스의 락(render↔delta-apply 직렬화). 로컬 core는 미사용.
            return;
        }
        self.core.owner_dbg.lock(&self.core_mutex, io);
    }

    pub fn unlockCore(self: *Surface, io: std.Io) void {
        if (self.remote) |r| {
            r.vtable.unlock(r.ctx, io);
            return;
        }
        self.core.owner_dbg.unlock(&self.core_mutex, io);
    }

    /// 렌더 draw 경로의 **화면 소스 단일 접근점**(SSOT — docs/persistent-session-host.md §8 "중립 screen DTO"). 지금은
    /// 로컬 `TerminalCore`(뷰포트 합성 포함)에 위임한다. 원격 host runtime backing이 붙는 후속(P3-e2e-2c)에서 이 accessor가
    /// 원격 화면 모델(조립기 → cells)로 갈린다 — GUI 렌더 코드는 로컬/원격을 모르게 `surface.renderSnapshot()`만 부른다.
    /// 반환 snapshot은 화면 소스 메모리를 alias하므로 caller가 `lockCore`/`unlockCore` 안에서 읽고 복사해야 한다(현행
    /// 계약 그대로, docs/io-render-threading.md — snapshot 슬라이스는 lock 밖으로 새면 안 됨).
    pub fn renderSnapshot(self: *Surface) terminal.RenderSnapshot {
        if (self.remote) |r| return r.vtable.render_snapshot(r.ctx); // 원격 backing이면 조립된 화면(cells)을 준다.
        return self.core.renderSnapshot();
    }

    pub fn restorableMetadata(self: *const Surface) RestorableSurfaceMetadata {
        // env는 allowlist/redaction 정책이 정해질 때까지 저장하지 않는다.
        // workspace restore가 민감한 환경변수를 실수로 기록하지 않도록 비워 둔다.
        return .{
            .id = self.id,
            .title = self.title,
            .cwd = self.cwd,
            .command = self.command,
            .size = self.core.size,
            .process_state = self.process_state,
            .env = &.{},
        };
    }
};

test "surface metadata excludes live process handles and environment by default" {
    var surface = try Surface.init(std.testing.allocator, 7, .{ .cols = 100, .rows = 30 });
    defer surface.deinit();
    surface.title = "app shell";
    surface.cwd = "/tmp/maru";
    surface.command = "/bin/zsh";
    surface.process_state = .running;

    const metadata = surface.restorableMetadata();
    try std.testing.expectEqual(@as(u64, 7), metadata.id);
    try std.testing.expectEqualStrings("app shell", metadata.title);
    try std.testing.expectEqualStrings("/tmp/maru", metadata.cwd.?);
    try std.testing.expectEqualStrings("/bin/zsh", metadata.command.?);
    try std.testing.expectEqual(terminal.Size{ .cols = 100, .rows = 30 }, metadata.size);
    try std.testing.expectEqual(ProcessState.running, metadata.process_state);
    try std.testing.expectEqual(@as(usize, 0), metadata.env.len);
}
