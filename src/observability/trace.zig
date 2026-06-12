//! `maru.trace.v1` 셸 의미 이벤트 직렬화. 같은 도메인 데이터(`types.ShellEvent`)를 텍스트 trace로
//! 굳혀, 오프라인 분석·회귀 fixture·(후속) replay가 GUI 없이 명령 라이프사이클을 본다(관측 가능성
//! 원칙 — 임시 포맷을 따로 두지 않는다). 스키마 단일 출처는 docs/trace-replay.md. snapshot 직렬화와
//! 같은 규칙: 첫 줄은 bare 토큰(`schema=` 접두어 없음), 이후 `key=val` 라인. 이 PR(B2)은 writer만
//! 둔다 — reader/replay(B3)는 trace를 재생할 필요가 생길 때 추가한다(snapshot.zig와 같은 선례).
//!
//! 이벤트 이름은 trace-replay.md 토큰과 1:1: prompt_start→shell.prompt-start,
//! input_start→shell.prompt-end(입력 시작=프롬프트 끝), command_start→shell.command-start,
//! command_end→shell.command-end, cwd_changed→shell.cwd-changed.

const std = @import("std");
const terminal = @import("../terminal.zig");

pub const header = "maru.trace.v1";

/// 헤더 + 이벤트 전부를 새 문자열로 직렬화한다(호출자 소유). `surface_id`는 다중 surface trace에서
/// 이벤트를 surface별로 가르기 위함(현재 단일 surface라 보통 1). 이벤트 인덱스는 0부터 매긴다.
///
/// `cwd`는 직렬화 시점의 현재 cwd다 — `ShellEvent.cwd_changed`는 값을 안 들고(POD) `currentCwd()`가
/// 권위라(docs/trace-replay.md), cwd_changed 라인에 이 값을 적는다. 한 batch에 cwd_changed가 둘이면
/// 둘 다 현재 cwd로 적힌다(한 프레임 내 연속 cd — 드물고 문서화된 한계).
pub fn renderShellEvents(
    allocator: std.mem.Allocator,
    surface_id: u32,
    events: []const terminal.types.ShellEvent,
    cwd: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}\n", .{header});
    for (events, 0..) |event, i| try writeEvent(&out.writer, i, surface_id, event, cwd);
    return out.toOwnedSlice();
}

/// 이벤트 한 줄: `event <index> <kind> surface=<id> [payload]`. live 레코더(후속)는 같은 헤더 뒤에
/// 이 함수로 한 줄씩 append하면 된다(인덱스를 누적 카운터로 넘김).
pub fn writeEvent(
    writer: *std.Io.Writer,
    index: usize,
    surface_id: u32,
    event: terminal.types.ShellEvent,
    cwd: []const u8,
) !void {
    switch (event) {
        .prompt_start => |row| try writer.print("event {d} shell.prompt-start surface={d} row={d}\n", .{ index, surface_id, row }),
        .input_start => |row| try writer.print("event {d} shell.prompt-end surface={d} row={d}\n", .{ index, surface_id, row }),
        .command_start => |row| try writer.print("event {d} shell.command-start surface={d} row={d}\n", .{ index, surface_id, row }),
        .command_end => |ce| {
            try writer.print("event {d} shell.command-end surface={d} row={d} exit=", .{ index, surface_id, ce.row });
            if (ce.exit) |code| {
                try writer.print("{d}\n", .{code});
            } else {
                try writer.writeAll("none\n"); // 명세상 D는 code 없이도 온다
            }
        },
        .cwd_changed => {
            try writer.print("event {d} shell.cwd-changed surface={d} cwd=\"", .{ index, surface_id });
            try writeEscaped(writer, cwd);
            try writer.writeAll("\"\n");
        },
    }
}

/// 따옴표로 감싼 cwd 안의 특수문자를 escape한다(`\` `"`·개행/CR/Tab). path에 공백·따옴표가 섞여도
/// 한 줄·한 토큰으로 안전하게 보관된다(snapshot의 codepoint escape와 같은 규칙). reader(B3)가
/// 같은 규칙으로 unescape한다.
fn writeEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| switch (b) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(b),
    };
}

// trace는 명령 라이프사이클을 GUI 없이 파일로 굳힌 산출물이다 — 핵심 검증: 실제 OSC 133/7을 먹인
// core의 이벤트 스트림이 정확한 maru.trace.v1 라인으로 직렬화되는가(같은 도메인 데이터를 텍스트로).
test "trace serializes a shell command cycle as maru.trace.v1 lines" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();

    try core.write("\x1b]133;A\x1b\\"); // prompt start, row 0
    try core.write("\x1b]133;B\x07ls\r\n"); // input start row 0, 명령 + 개행 → row 1
    try core.write("\x1b]133;C\x07out\r\n"); // output start row 1 → row 2
    try core.write("\x1b]7;file://h/tmp\x07"); // cwd 변경
    try core.write("\x1b]133;D;0\x07"); // 명령 끝, exit 0

    const text = try renderShellEvents(std.testing.allocator, 1, core.shellEvents(), core.currentCwd());
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "maru.trace.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "event 0 shell.prompt-start surface=1 row=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "event 1 shell.prompt-end surface=1 row=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "event 2 shell.command-start surface=1 row=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "event 3 shell.cwd-changed surface=1 cwd=\"/tmp\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "event 4 shell.command-end surface=1 row=2 exit=0\n") != null);
}

test "trace serializes failing and absent exit codes, escapes cwd special chars" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();

    try core.write("\x1b]133;D;130\x07"); // SIGINT(130) 실패
    const t1 = try renderShellEvents(std.testing.allocator, 1, core.shellEvents(), "");
    defer std.testing.allocator.free(t1);
    try std.testing.expect(std.mem.indexOf(u8, t1, "event 0 shell.command-end surface=1 row=0 exit=130\n") != null);

    core.clearShellEvents();
    try core.write("\x1b]133;D\x07"); // code 없는 D → exit=none
    const t2 = try renderShellEvents(std.testing.allocator, 1, core.shellEvents(), "");
    defer std.testing.allocator.free(t2);
    try std.testing.expect(std.mem.indexOf(u8, t2, "exit=none\n") != null);

    // cwd escape: 공백·따옴표·개행이 한 줄·한 토큰으로 안전하게 보관돼야 한다.
    const events = [_]terminal.types.ShellEvent{.cwd_changed};
    const t3 = try renderShellEvents(std.testing.allocator, 2, &events, "a \"b\"\n");
    defer std.testing.allocator.free(t3);
    try std.testing.expect(std.mem.indexOf(u8, t3, "event 0 shell.cwd-changed surface=2 cwd=\"a \\\"b\\\"\\n\"\n") != null);
}
