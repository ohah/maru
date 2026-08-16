const std = @import("std");
const observability = @import("../observability.zig");
const pty = @import("../pty.zig");
const terminal = @import("../terminal.zig");
const live_pty_mod = @import("live_pty.zig");
const runtime_mod = @import("runtime.zig");
const runtime_pump = @import("runtime_pump.zig");
const artifact_io = @import("artifact_io.zig");
const fixture_script = @import("fixture_script.zig");
const surface_mod = @import("../session/surface.zig");

pub const default_artifact_dir = "zig-out/maru-demo";

/// 제목·cwd·완료 세 줄을 낸다. cmd의 `&`는 명령 구분자이고 인자 없는 `cd`는 현재 디렉터리를 찍는다
/// (POSIX `pwd`). 규칙은 [fixture_script.zig](fixture_script.zig)가 단일 출처다.
const host_demo_command = fixture_script.oneShot(
    @import("builtin").os.tag,
    "printf 'maru headless demo\\n'; pwd; printf 'demo complete\\n'",
    "echo maru headless demo& cd& echo demo complete",
);

pub const DemoConfig = struct {
    artifact_dir: []const u8 = default_artifact_dir,
    size: terminal.Size = .{ .cols = 80, .rows = 12 },
    command: []const u8 = host_demo_command.command,
    args: []const []const u8 = host_demo_command.args,
};

pub const DemoResult = struct {
    screen: []u8,
    snapshot: []u8,
    summary: []u8,

    pub fn deinit(self: *DemoResult, allocator: std.mem.Allocator) void {
        allocator.free(self.screen);
        allocator.free(self.snapshot);
        allocator.free(self.summary);
        self.* = undefined;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, config: DemoConfig) !DemoResult {
    // 이 데모는 GUI를 만들기 전에 실제 프로세스 출력이 Maru의 런타임 경계를
    // 끝까지 통과하는지 확인하기 위한 작은 앱이다. 테스트 fixture가 아니라
    // 실제 PTY를 쓰기 때문에, 나중에 창이 붙어도 같은 실패 지점을 추적할 수 있다.
    var live_pty: live_pty_mod.LivePtySession = undefined;
    try live_pty.init(io, allocator, 10, .{
        .command = config.command,
        .args = config.args,
        .size = config.size,
    }, 32);
    defer live_pty.deinit();

    var surface = try surface_mod.Surface.init(allocator, 1, config.size);
    defer surface.deinit();
    surface.title = "headless demo";
    surface.command = config.command;

    var runtime = runtime_mod.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try live_pty.attachSurface(&runtime, &surface, false); // headless demo — 리더 처리 끔(큐-드레인)

    // window loop가 아직 없으므로 pump가 종료 이벤트까지 직접 기다린다. 이 경로가
    // 안정적이어야 이후 macOS app host가 같은 queue/runtime 계약을 frame loop에서
    // 소비할 수 있다.
    var pump = live_pty.pump(&runtime);
    const drain_summary = try pump.drainBlockingUntilTermination();

    live_pty.finishAfterTermination();

    const screen = try surface.core.dumpUtf8(allocator);
    errdefer allocator.free(screen);

    const snapshot = try observability.snapshot.renderTerminalSnapshot(allocator, surface.core.snapshot());
    errdefer allocator.free(snapshot);

    const summary = try renderSummary(allocator, config, drain_summary, surface.process_state);
    errdefer allocator.free(summary);

    try writeArtifacts(io, allocator, config.artifact_dir, .{
        .screen = screen,
        .snapshot = snapshot,
        .summary = summary,
    });

    return .{
        .screen = screen,
        .snapshot = snapshot,
        .summary = summary,
    };
}

const ArtifactPayload = struct {
    screen: []const u8,
    snapshot: []const u8,
    summary: []const u8,
};

fn writeArtifacts(
    io: std.Io,
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    payload: ArtifactPayload,
) !void {
    // Demo artifact도 테스트 artifact와 같은 성격이다. 눈으로 실행 결과를 보되,
    // 실패했을 때 화면 텍스트와 구조화 snapshot을 파일로 남겨 원인을 좁힌다.
    // 세 파일이 같은 디렉터리를 공유하므로 부모 디렉터리는 여기서 한 번만 만든다.
    try ensureDir(io, artifact_dir);

    const screen_path = try std.fmt.allocPrint(allocator, "{s}/headless-pty.screen.txt", .{artifact_dir});
    defer allocator.free(screen_path);
    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/headless-pty.snapshot.txt", .{artifact_dir});
    defer allocator.free(snapshot_path);
    const summary_path = try std.fmt.allocPrint(allocator, "{s}/headless-pty.summary.txt", .{artifact_dir});
    defer allocator.free(summary_path);

    try writeTextWithFinalNewline(io, allocator, screen_path, payload.screen);
    try writeText(io, snapshot_path, payload.snapshot);
    try writeText(io, summary_path, payload.summary);
}

fn renderSummary(
    allocator: std.mem.Allocator,
    config: DemoConfig,
    drain_summary: runtime_pump.DrainSummary,
    process_state: surface_mod.ProcessState,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    const writer = &output.writer;
    try writer.writeAll("maru.headless-demo.v1\n");
    try writer.print("artifact_dir={s}\n", .{config.artifact_dir});
    try writer.print("command={s}\n", .{config.command});
    try writer.print("args.len={d}\n", .{config.args.len});
    try writer.print("size.cols={d}\n", .{config.size.cols});
    try writer.print("size.rows={d}\n", .{config.size.rows});
    try writer.print("output_events={d}\n", .{drain_summary.output_events});
    try writer.print("exit_events={d}\n", .{drain_summary.exit_events});
    try writer.print("process_state={s}\n", .{@tagName(process_state)});
    try writer.writeAll("termination=");
    try writeTermination(writer, drain_summary.ended);
    try writer.writeByte('\n');

    return output.toOwnedSlice();
}

const writeTermination = runtime_pump.writeTermination;
const writeExitStatus = runtime_pump.writeExitStatus;
const writeText = artifact_io.writeText;
const writeTextWithFinalNewline = artifact_io.writeTextWithFinalNewline;
const ensureDir = artifact_io.ensureDir;

// 데모 산출물을 OS별로 다르게 읽지 않으려면 **두 갈래가 같은 세 줄을** 내야 한다. 스크립트 문법은
// 달라도 그 안의 문구는 같다는 것을 여기서 못박는다(fixture_script는 형태만 검사한다).
test "데모 fixture: 두 갈래가 같은 세 줄을 낸다" {
    for ([_]std.Target.Os.Tag{ .windows, .macos, .linux }) |os| {
        const script = fixture_script.oneShot(
            os,
            "printf 'maru headless demo\\n'; pwd; printf 'demo complete\\n'",
            "echo maru headless demo& cd& echo demo complete",
        ).args[1];
        try std.testing.expect(std.mem.indexOf(u8, script, "maru headless demo") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "demo complete") != null);
    }
}

test "headless demo summary records the runnable vertical slice" {
    const summary = try renderSummary(
        std.testing.allocator,
        .{ .artifact_dir = "zig-out/test-demo", .size = .{ .cols = 10, .rows = 3 } },
        .{
            .output_events = 2,
            .exit_events = 1,
            .ended = .{ .exited = .{ .exited = 0 } },
        },
        .exited,
    );
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "maru.headless-demo.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "artifact_dir=zig-out/test-demo\n") != null);
    // 설정한 size와 event 카운트가 실제로 summary에 기록되는지 확인한다. 이 값들을
    // assert하지 않으면 잘못된 size/count가 찍혀도 테스트가 통과해 버린다.
    try std.testing.expect(std.mem.indexOf(u8, summary, "size.cols=10\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "size.rows=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "output_events=2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "exit_events=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "termination=exited(code=0)\n") != null);
}
