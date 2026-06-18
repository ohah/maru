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

    pub fn init(allocator: std.mem.Allocator, id: u64, size: terminal.Size) !Surface {
        return .{
            .id = id,
            .core = try terminal.TerminalCore.init(allocator, size),
        };
    }

    pub fn deinit(self: *Surface) void {
        self.core.deinit();
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
