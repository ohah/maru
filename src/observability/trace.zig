//! `maru.trace.v1` 셸 의미 이벤트 직렬화 + 역파싱. 같은 도메인 데이터(`types.ShellEvent`)를 텍스트 trace로
//! 굳혀, 오프라인 분석·회귀 fixture·replay가 GUI 없이 명령 라이프사이클을 본다(관측 가능성 원칙 — 임시
//! 포맷을 따로 두지 않는다). 스키마 단일 출처는 docs/trace-replay.md. snapshot 직렬화와 같은 규칙: 첫 줄은
//! bare 토큰(`schema=` 접두어 없음), 이후 `key=val` 라인.
//!
//! **writer**(`renderShellEvents`/`writeEvent`)와 **reader**(`parseShellEvents`)가 짝을 이뤄 round-trip한다 —
//! parse(render(events, cwd))가 원 events와 cwd_changed 경로를 복원한다. 라이브 레코딩(`MARU_TRACE` 게이트)과
//! trace를 코어에 다시 먹이는 replay 재적용(base kind output/input/resize)은 후속(docs/trace-replay.md §후속).
//!
//! 이벤트 이름은 trace-replay.md 토큰과 1:1: prompt_start→shell.prompt-start,
//! input_start→shell.prompt-end(입력 시작=프롬프트 끝), command_start→shell.command-start,
//! command_end→shell.command-end, cwd_changed→shell.cwd-changed.

const std = @import("std");
const terminal = @import("../terminal.zig");
const text_escape = @import("../text_escape.zig"); // 따옴표 값 escape/unescape 단일 출처(workspace/snapshot과 공유)
const writeEscaped = text_escape.writeEscaped;

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

// ── reader (역파싱) ───────────────────────────────────────────────────────────────────────────────────────

pub const ParseError = error{ BadHeader, BadLine } || std.mem.Allocator.Error;

/// 파싱된 이벤트 한 개 — 원 이벤트(POD union) + 라인 메타(index·surface_id) + cwd_changed의 unescape된 경로.
/// cwd는 allocator 소유(그 외 이벤트는 null). writer가 POD ShellEvent엔 cwd를 안 싣지만(currentCwd()가 권위),
/// reader는 trace 라인에 적힌 값을 복원해 여기 실어 준다(라인만으로 cwd를 되찾게).
pub const ParsedEvent = struct {
    index: usize,
    surface_id: u32,
    event: terminal.types.ShellEvent,
    cwd: ?[]const u8 = null,
};

/// `maru.trace.v1` 텍스트를 이벤트 스트림으로 되읽는다(renderShellEvents의 역연산). round-trip:
/// parseShellEvents(renderShellEvents(events, cwd))가 원 events와 cwd_changed 경로를 복원한다. 반환 슬라이스와
/// 각 cwd 문자열은 allocator 소유 — freeParsedEvents로 해제한다. 헤더가 틀리면 BadHeader, 라인이 깨지면 BadLine.
pub fn parseShellEvents(allocator: std.mem.Allocator, text: []const u8) ParseError![]ParsedEvent {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadHeader;
    if (!std.mem.eql(u8, first, header)) return error.BadHeader;

    var list: std.ArrayList(ParsedEvent) = .empty;
    errdefer {
        for (list.items) |e| if (e.cwd) |c| allocator.free(c);
        list.deinit(allocator);
    }
    while (lines.next()) |line| {
        if (line.len == 0) continue; // 마지막 개행 뒤 빈 줄 skip
        try list.append(allocator, try parseEventLine(allocator, line));
    }
    return list.toOwnedSlice(allocator);
}

/// parseShellEvents 결과를 해제한다(각 cwd 문자열 + 슬라이스). 반드시 짝으로 부른다.
pub fn freeParsedEvents(allocator: std.mem.Allocator, events: []const ParsedEvent) void {
    for (events) |e| if (e.cwd) |c| allocator.free(c);
    allocator.free(events);
}

/// `event <index> <kind> surface=<id> <payload>` 한 줄을 ParsedEvent로. cwd-changed 값은 공백/따옴표를 담을 수
/// 있어 토크나이저가 아니라 원문에서 따옴표 범위를 잘라 unescape한다(그 외 필드는 공백 토큰).
fn parseEventLine(allocator: std.mem.Allocator, line: []const u8) ParseError!ParsedEvent {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    if (!eqTok(it.next(), "event")) return error.BadLine;
    const index = parseUintTok(it.next(), usize) orelse return error.BadLine;
    const kind = it.next() orelse return error.BadLine;
    const surface_id = parseKeyUint(it.next(), "surface", u32) orelse return error.BadLine;

    if (std.mem.eql(u8, kind, "shell.prompt-start")) {
        return .{ .index = index, .surface_id = surface_id, .event = .{ .prompt_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine } };
    } else if (std.mem.eql(u8, kind, "shell.prompt-end")) {
        return .{ .index = index, .surface_id = surface_id, .event = .{ .input_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine } };
    } else if (std.mem.eql(u8, kind, "shell.command-start")) {
        return .{ .index = index, .surface_id = surface_id, .event = .{ .command_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine } };
    } else if (std.mem.eql(u8, kind, "shell.command-end")) {
        const row = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine;
        const exit_tok = it.next() orelse return error.BadLine;
        if (!std.mem.startsWith(u8, exit_tok, "exit=")) return error.BadLine;
        const exit_s = exit_tok["exit=".len..];
        const exit: ?i16 = if (std.mem.eql(u8, exit_s, "none")) null else (std.fmt.parseInt(i16, exit_s, 10) catch return error.BadLine);
        return .{ .index = index, .surface_id = surface_id, .event = .{ .command_end = .{ .row = row, .exit = exit } } };
    } else if (std.mem.eql(u8, kind, "shell.cwd-changed")) {
        const raw = extractQuoted(line, "cwd") orelse return error.BadLine;
        return .{ .index = index, .surface_id = surface_id, .event = .cwd_changed, .cwd = try text_escape.unescapeAlloc(allocator, raw) };
    }
    return error.BadLine; // 알 수 없는 kind
}

fn eqTok(tok: ?[]const u8, expected: []const u8) bool {
    return tok != null and std.mem.eql(u8, tok.?, expected);
}

fn parseUintTok(tok: ?[]const u8, comptime T: type) ?T {
    const t = tok orelse return null;
    return std.fmt.parseInt(T, t, 10) catch null;
}

/// `key=<uint>` 토큰에서 uint를 파싱(prefix 불일치·비숫자면 null).
fn parseKeyUint(tok: ?[]const u8, comptime key: []const u8, comptime T: type) ?T {
    const t = tok orelse return null;
    const prefix = key ++ "=";
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    return std.fmt.parseInt(T, t[prefix.len..], 10) catch null;
}

/// line에서 `<key>="..."`의 따옴표 안 escape 내용(미해제)을 돌려준다. 닫는 `"`는 escape되지 않은 것만 인정한다
/// (`\"`를 건너뛰어 값 안의 따옴표를 종료로 오판하지 않게 — writeEscaped가 값의 `"`를 `\"`로 냈으므로 대칭).
fn extractQuoted(line: []const u8, comptime key: []const u8) ?[]const u8 {
    const marker = key ++ "=\"";
    const open = std.mem.indexOf(u8, line, marker) orelse return null;
    const start = open + marker.len;
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1; // escape된 다음 문자 skip(닫는 " 오판 방지)
            continue;
        }
        if (line[i] == '"') return line[start..i];
    }
    return null; // 닫는 따옴표 없음(손상)
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

// reader는 writer의 역연산 — 핵심 검증: 실제 이벤트 스트림을 직렬화한 텍스트를 되읽으면 원 이벤트(태그+payload)와
// cwd 경로가 그대로 복원된다(round-trip). 관측 가능성 원칙: writer/reader가 같은 도메인 데이터를 공유해 fixture·
// replay가 GUI 없이 명령 라이프사이클을 되살린다.
test "trace round-trip: parseShellEvents(renderShellEvents(...))가 원 이벤트·cwd를 복원한다" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b]133;A\x1b\\"); // prompt start row 0
    try core.write("\x1b]133;B\x07ls\r\n"); // input start row 0 → row 1
    try core.write("\x1b]133;C\x07out\r\n"); // command start row 1 → row 2
    try core.write("\x1b]7;file://h/tmp\x07"); // cwd 변경
    try core.write("\x1b]133;D;0\x07"); // 명령 끝 exit 0

    const cwd = core.currentCwd();
    const events = core.shellEvents();
    const text = try renderShellEvents(std.testing.allocator, 1, events, cwd);
    defer std.testing.allocator.free(text);

    const parsed = try parseShellEvents(std.testing.allocator, text);
    defer freeParsedEvents(std.testing.allocator, parsed);

    try std.testing.expectEqual(events.len, parsed.len);
    for (events, parsed, 0..) |ev, pe, i| {
        try std.testing.expectEqual(i, pe.index);
        try std.testing.expectEqual(@as(u32, 1), pe.surface_id);
        try std.testing.expect(std.meta.eql(ev, pe.event)); // union 태그 + payload 동일
        if (ev == .cwd_changed) try std.testing.expectEqualStrings(cwd, pe.cwd.?); // cwd 경로 복원
    }
}

test "trace reader: 헤더/라인 검증 — 잘못된 헤더·깨진 라인은 error, exit=none·cwd escape 복원" {
    const a = std.testing.allocator;
    // 헤더 틀림 → BadHeader.
    try std.testing.expectError(error.BadHeader, parseShellEvents(a, "not-a-trace\n"));
    // 깨진 라인(kind/surface 없음) → BadLine.
    try std.testing.expectError(error.BadLine, parseShellEvents(a, "maru.trace.v1\nevent 0\n"));
    try std.testing.expectError(error.BadLine, parseShellEvents(a, "maru.trace.v1\nevent 0 shell.prompt-start row=1\n")); // surface= 누락

    // exit=none 복원(code 없는 D).
    {
        const parsed = try parseShellEvents(a, "maru.trace.v1\nevent 0 shell.command-end surface=1 row=2 exit=none\n");
        defer freeParsedEvents(a, parsed);
        try std.testing.expectEqual(@as(usize, 1), parsed.len);
        try std.testing.expect(parsed[0].event == .command_end);
        try std.testing.expectEqual(@as(?i16, null), parsed[0].event.command_end.exit);
        try std.testing.expectEqual(@as(u16, 2), parsed[0].event.command_end.row);
    }
    // 실패 exit(130) 복원.
    {
        const parsed = try parseShellEvents(a, "maru.trace.v1\nevent 3 shell.command-end surface=1 row=0 exit=130\n");
        defer freeParsedEvents(a, parsed);
        try std.testing.expectEqual(@as(?i16, 130), parsed[0].event.command_end.exit);
        try std.testing.expectEqual(@as(usize, 3), parsed[0].index);
    }
    // cwd escape 복원(공백·따옴표·개행이 섞인 경로가 원문으로).
    {
        const events = [_]terminal.types.ShellEvent{.cwd_changed};
        const text = try renderShellEvents(a, 2, &events, "a \"b\"\n/c");
        defer a.free(text);
        const parsed = try parseShellEvents(a, text);
        defer freeParsedEvents(a, parsed);
        try std.testing.expect(parsed[0].event == .cwd_changed);
        try std.testing.expectEqualStrings("a \"b\"\n/c", parsed[0].cwd.?);
    }
}
