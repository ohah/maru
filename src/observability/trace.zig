//! `maru.trace.v1` 셸 의미 이벤트 직렬화 + 역파싱. 같은 도메인 데이터(`types.ShellEvent`)를 텍스트 trace로
//! 굳혀, 오프라인 분석·회귀 fixture·replay가 GUI 없이 명령 라이프사이클을 본다(관측 가능성 원칙 — 임시
//! 포맷을 따로 두지 않는다). 스키마 단일 출처는 docs/trace-replay.md. snapshot 직렬화와 같은 규칙: 첫 줄은
//! bare 토큰(`schema=` 접두어 없음), 이후 `key=val` 라인.
//!
//! **writer**(shell: `renderShellEvents`/`writeEvent`, base kind: `writeOutputEvent`/`writeResizeEvent`/…)와
//! **reader**(`parseEvents`)가 짝을 이뤄 round-trip한다. shell.* 는 OSC 133/7에서 파생된 semantic 인덱스이고,
//! base kind(output/input/resize/process-exit)가 replay의 권위 데이터다 — `observability/replay.zig`가 output을
//! 재생하면 파서가 화면·셸 이벤트·cwd를 전부 재도출한다. 라이브 레코딩(`MARU_TRACE` 게이트)은 후속(문서 §후속).
//!
//! 이벤트 이름은 trace-replay.md 토큰과 1:1: prompt_start→shell.prompt-start,
//! input_start→shell.prompt-end(입력 시작=프롬프트 끝), command_start→shell.command-start,
//! command_end→shell.command-end, cwd_changed→shell.cwd-changed.

const std = @import("std");
const terminal = @import("../terminal.zig");
const text_escape = @import("../text_escape.zig"); // 따옴표 값 escape/unescape 단일 출처(workspace/snapshot과 공유)
const redact = @import("../redact.zig"); // 민감정보 판정 단일 출처(중립 leaf)
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
    surface_id: u64,
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
    surface_id: u64,
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

// ── base kind writer (재생의 권위 데이터 — SurfaceRuntime runtime event 1:1) ──────────────────────────────────
// shell.* 이벤트는 output에서 파생되는 semantic 인덱스이고, 아래 output/resize/input/process-exit이 **재생의 권위
// 데이터**다. output 바이트를 재생하면 파서가 화면·셸 이벤트·cwd를 전부 재도출한다(docs/trace-replay.md). 라이브
// 레코더(MARU_TRACE, 후속)는 같은 헤더 뒤에 이 함수들로 한 줄씩 append한다(index를 누적 카운터로 넘김).

/// trace 헤더 한 줄. 라이브 레코더가 첫 이벤트 전에 한 번 쓴다.
pub fn writeHeader(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{header});
}

/// `event <i> output surface=<s> bytes="<escaped>"` — 원시 PTY 출력. bytes는 따옴표 값 escape(개행/CR/Tab/`\`/`"`),
/// 그 외 바이트(ESC·제어·UTF-8)는 그대로. 재생이 이 바이트를 core.write로 흘려 화면을 정확히 재구성한다.
pub fn writeOutputEvent(writer: *std.Io.Writer, index: usize, surface_id: u64, bytes: []const u8) !void {
    try writer.print("event {d} output surface={d} bytes=\"", .{ index, surface_id });
    try writeEscaped(writer, bytes);
    try writer.writeAll("\"\n");
}

/// `event <i> input surface=<s> bytes="<escaped>"` — 사용자 입력(재생 화면엔 직접 영향 없음 — child로 감; 기록·분석용).
pub fn writeInputEvent(writer: *std.Io.Writer, index: usize, surface_id: u64, bytes: []const u8) !void {
    try writer.print("event {d} input surface={d} bytes=\"", .{ index, surface_id });
    try writeEscaped(writer, bytes);
    try writer.writeAll("\"\n");
}

/// `event <i> resize surface=<s> cols=<c> rows=<r>` — 터미널 크기 변경. 재생이 core.resize로 적용해 reflow까지 재구성.
pub fn writeResizeEvent(writer: *std.Io.Writer, index: usize, surface_id: u64, cols: u16, rows: u16) !void {
    try writer.print("event {d} resize surface={d} cols={d} rows={d}\n", .{ index, surface_id, cols, rows });
}

/// `event <i> process-exit surface=<s> code=<n>` — child 종료(RuntimePtyEvent.exited 1:1). code 없으면 `code=none`.
pub fn writeProcessExitEvent(writer: *std.Io.Writer, index: usize, surface_id: u64, code: ?i32) !void {
    if (code) |c| {
        try writer.print("event {d} process-exit surface={d} code={d}\n", .{ index, surface_id, c });
    } else {
        try writer.print("event {d} process-exit surface={d} code=none\n", .{ index, surface_id });
    }
}

// ── reader (역파싱) ───────────────────────────────────────────────────────────────────────────────────────

pub const ParseError = error{ BadHeader, BadLine } || std.mem.Allocator.Error;

/// 파싱된 이벤트의 payload. shell.* 는 OSC 133/7에서 파생된 **semantic 인덱스**(output이 있으면 재생 시 파서가
/// 재도출)이고, base kind(output/input/resize/process_exit)가 **재생의 권위 데이터**다. 소유 문자열(cwd·output·
/// input)은 allocator 소유 — freeParsedEvents로 해제한다.
pub const Event = union(enum) {
    prompt_start: u16,
    input_start: u16,
    command_start: u16,
    command_end: terminal.types.ShellEvent.CommandEnd,
    cwd_changed: []const u8, // shell.cwd-changed의 unescape된 경로(owned) — writer가 currentCwd()로 적은 값
    output: []const u8, // 원시 PTY 출력 바이트(owned, unescape됨) — 재생의 권위
    input: []const u8, // 사용자 입력 바이트(owned)
    resize: terminal.Size,
    process_exit: ?i32, // child 종료코드(code=none이면 null)
};

/// 파싱된 이벤트 한 개 — 라인 메타(index·surface_id) + payload.
pub const ParsedEvent = struct {
    index: usize,
    surface_id: u64,
    event: Event,
};

/// `maru.trace.v1` 텍스트를 이벤트 스트림으로 되읽는다(writer의 역연산). shell.* + base kind 전부 처리한다.
/// round-trip: render→parse가 원 이벤트(+ 소유 문자열)를 복원한다. 반환 슬라이스와 소유 문자열은 allocator 소유 —
/// freeParsedEvents로 해제한다. 헤더가 틀리면 BadHeader, 라인이 깨지면 BadLine.
pub fn parseEvents(allocator: std.mem.Allocator, text_in: []const u8) ParseError![]ParsedEvent {
    // 증분 레코딩(MARU_TRACE)은 이벤트마다 flush하지만, 크래시·I/O 에러가 마지막 이벤트를 반쯤 쓴 채 끊을 수 있다.
    // 그런 **개행으로 안 끝난 잘린 마지막 줄**은 떨궈, 디스크에 남은 완전한 앞부분은 그대로 재생되게 한다(정상 trace는
    // 매 이벤트가 '\n'으로 끝나므로 no-op). 중간 줄은 여전히 '\n'으로 끝나 엄격히 검증된다.
    const text = if (text_in.len > 0 and text_in[text_in.len - 1] != '\n')
        text_in[0 .. (std.mem.lastIndexOfScalar(u8, text_in, '\n') orelse return error.BadHeader) + 1]
    else
        text_in;

    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return error.BadHeader;
    if (!std.mem.eql(u8, first, header)) return error.BadHeader;

    var list: std.ArrayList(ParsedEvent) = .empty;
    errdefer {
        for (list.items) |e| freeEvent(allocator, e.event);
        list.deinit(allocator);
    }
    while (lines.next()) |line| {
        if (line.len == 0) continue; // 마지막 개행 뒤 빈 줄 skip
        const ev = try parseEventLine(allocator, line);
        // append가 OOM하면 ev는 아직 list.items에 없어 errdefer가 못 잡는다 — 방금 파싱한 소유 문자열을 여기서 회수.
        list.append(allocator, ev) catch |e| {
            freeEvent(allocator, ev.event);
            return e;
        };
    }
    return list.toOwnedSlice(allocator);
}

/// parseEvents 결과를 해제한다(소유 문자열 + 슬라이스). 반드시 짝으로 부른다.
pub fn freeParsedEvents(allocator: std.mem.Allocator, events: []const ParsedEvent) void {
    for (events) |e| freeEvent(allocator, e.event);
    allocator.free(events);
}

fn freeEvent(allocator: std.mem.Allocator, event: Event) void {
    switch (event) {
        .cwd_changed, .output, .input => |s| allocator.free(s),
        else => {},
    }
}

// ── fixture redaction 가드 (커밋 전) ─────────────────────────────────────────────────────────────────────────

/// trace의 output/input/cwd 값에 민감 데이터가 있는지. **핵심**: output 바이트는 PTY read 경계로 이벤트마다 쪼개져
/// 있어(`API_TOKEN`과 `=값`이 서로 다른 event에 걸칠 수 있음), 직렬화 텍스트를 그대로 스캔하면 놓친다(code-review
/// [12]). 그래서 output을 **경계 없이 연속으로 재조립·unescape**해 원래 터미널 바이트 스트림을 복원한 뒤 스캔한다
/// (split secret 재결합). input/cwd 값은 각각 스캔. trace가 아니면(파싱 불가) raw 텍스트를 스캔(안전 폴백).
pub fn traceHasSensitiveContent(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!bool {
    const events = parseEvents(allocator, text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return redact.hasSensitiveContent(text), // trace가 아니면 raw 스캔
    };
    defer freeParsedEvents(allocator, events);

    var stream: std.ArrayList(u8) = .empty; // 연속 output(경계 없이 — split secret 재결합)
    defer stream.deinit(allocator);
    for (events) |pe| switch (pe.event) {
        .output => |s| try stream.appendSlice(allocator, s),
        .input, .cwd_changed => |s| if (redact.hasSensitiveContent(s)) return true,
        else => {},
    };
    return redact.hasSensitiveContent(stream.items);
}

/// trace를 **커밋용 fixture로 저장하기 전 가드**. 민감 데이터가 있으면 SensitiveContent로 거부(deny-by-default —
/// docs/project-rules.md, docs/trace-replay.md). redact.guardFixture(plain 텍스트용)와 달리 output을 재조립해 스캔한다.
pub fn guardFixture(allocator: std.mem.Allocator, text: []const u8) (std.mem.Allocator.Error || redact.FixtureError)!void {
    if (try traceHasSensitiveContent(allocator, text)) return error.SensitiveContent;
}

/// `event <index> <kind> surface=<id> <payload>` 한 줄을 ParsedEvent로. 따옴표 값(cwd/bytes)은 공백/따옴표를 담을 수
/// 있어 토크나이저가 아니라 원문에서 따옴표 범위를 잘라 unescape한다(그 외 필드는 공백 토큰).
fn parseEventLine(allocator: std.mem.Allocator, line: []const u8) ParseError!ParsedEvent {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    if (!eqTok(it.next(), "event")) return error.BadLine;
    const index = parseUintTok(it.next(), usize) orelse return error.BadLine;
    const kind = it.next() orelse return error.BadLine;
    const surface_id = parseKeyUint(it.next(), "surface", u64) orelse return error.BadLine;

    const event: Event = if (std.mem.eql(u8, kind, "shell.prompt-start"))
        .{ .prompt_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine }
    else if (std.mem.eql(u8, kind, "shell.prompt-end"))
        .{ .input_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine }
    else if (std.mem.eql(u8, kind, "shell.command-start"))
        .{ .command_start = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine }
    else if (std.mem.eql(u8, kind, "shell.command-end")) blk: {
        const row = parseKeyUint(it.next(), "row", u16) orelse return error.BadLine;
        const exit_tok = it.next() orelse return error.BadLine;
        if (!std.mem.startsWith(u8, exit_tok, "exit=")) return error.BadLine;
        const exit_s = exit_tok["exit=".len..];
        const exit: ?i16 = if (std.mem.eql(u8, exit_s, "none")) null else (std.fmt.parseInt(i16, exit_s, 10) catch return error.BadLine);
        break :blk .{ .command_end = .{ .row = row, .exit = exit } };
    } else if (std.mem.eql(u8, kind, "shell.cwd-changed"))
        .{ .cwd_changed = try text_escape.unescapeAlloc(allocator, extractQuoted(line, "cwd") orelse return error.BadLine) }
    else if (std.mem.eql(u8, kind, "output"))
        .{ .output = try text_escape.unescapeAlloc(allocator, extractQuoted(line, "bytes") orelse return error.BadLine) }
    else if (std.mem.eql(u8, kind, "input"))
        .{ .input = try text_escape.unescapeAlloc(allocator, extractQuoted(line, "bytes") orelse return error.BadLine) }
    else if (std.mem.eql(u8, kind, "resize")) blk: {
        const cols = parseKeyUint(it.next(), "cols", u16) orelse return error.BadLine;
        const rows = parseKeyUint(it.next(), "rows", u16) orelse return error.BadLine;
        break :blk .{ .resize = .{ .cols = cols, .rows = rows } };
    } else if (std.mem.eql(u8, kind, "process-exit")) blk: {
        const code_tok = it.next() orelse return error.BadLine;
        if (!std.mem.startsWith(u8, code_tok, "code=")) return error.BadLine;
        const code_s = code_tok["code=".len..];
        const code: ?i32 = if (std.mem.eql(u8, code_s, "none")) null else (std.fmt.parseInt(i32, code_s, 10) catch return error.BadLine);
        break :blk .{ .process_exit = code };
    } else return error.BadLine; // 알 수 없는 kind

    return .{ .index = index, .surface_id = surface_id, .event = event };
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
test "trace round-trip: parseEvents(renderShellEvents(...))가 원 이벤트·cwd를 복원한다" {
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

    const parsed = try parseEvents(std.testing.allocator, text);
    defer freeParsedEvents(std.testing.allocator, parsed);

    try std.testing.expectEqual(events.len, parsed.len);
    // ShellEvent(원)와 Event(파싱)를 태그+payload로 대조. cwd_changed는 POD void↔경로 문자열이라 별도 비교.
    for (events, parsed, 0..) |ev, pe, i| {
        try std.testing.expectEqual(i, pe.index);
        try std.testing.expectEqual(@as(u64, 1), pe.surface_id);
        switch (ev) {
            .prompt_start => |r| try std.testing.expect(pe.event == .prompt_start and pe.event.prompt_start == r),
            .input_start => |r| try std.testing.expect(pe.event == .input_start and pe.event.input_start == r),
            .command_start => |r| try std.testing.expect(pe.event == .command_start and pe.event.command_start == r),
            .command_end => |ce| try std.testing.expect(pe.event == .command_end and std.meta.eql(pe.event.command_end, ce)),
            .cwd_changed => {
                try std.testing.expect(pe.event == .cwd_changed);
                try std.testing.expectEqualStrings(cwd, pe.event.cwd_changed); // cwd 경로 복원
            },
        }
    }
}

test "trace reader: 크래시로 잘린 마지막 줄(개행 없음)은 관대 처리 — 앞부분은 파싱된다" {
    const a = std.testing.allocator;
    // 증분 레코딩이 두 번째 이벤트를 반쯤 쓴 채 끊긴 모양(마지막 줄 개행 없음).
    const truncated = "maru.trace.v1\nevent 0 output surface=1 bytes=\"hi\\r\\n\"\nevent 1 resize surf";
    const parsed = try parseEvents(a, truncated);
    defer freeParsedEvents(a, parsed);
    try std.testing.expectEqual(@as(usize, 1), parsed.len); // 완전한 event 0만, 잘린 event 1은 떨어짐
    try std.testing.expect(parsed[0].event == .output);
    // 중간 줄이 깨진 건(개행 뒤) 여전히 엄격히 실패.
    try std.testing.expectError(error.BadLine, parseEvents(a, "maru.trace.v1\nevent 0 bogus\nevent 1 resize surface=1 cols=8 rows=2\n"));
}

test "trace reader: 헤더/라인 검증 — 잘못된 헤더·깨진 라인은 error, exit=none·cwd escape 복원" {
    const a = std.testing.allocator;
    // 헤더 틀림 → BadHeader.
    try std.testing.expectError(error.BadHeader, parseEvents(a, "not-a-trace\n"));
    // 깨진 라인(kind/surface 없음) → BadLine.
    try std.testing.expectError(error.BadLine, parseEvents(a, "maru.trace.v1\nevent 0\n"));
    try std.testing.expectError(error.BadLine, parseEvents(a, "maru.trace.v1\nevent 0 shell.prompt-start row=1\n")); // surface= 누락

    // exit=none 복원(code 없는 D).
    {
        const parsed = try parseEvents(a, "maru.trace.v1\nevent 0 shell.command-end surface=1 row=2 exit=none\n");
        defer freeParsedEvents(a, parsed);
        try std.testing.expectEqual(@as(usize, 1), parsed.len);
        try std.testing.expect(parsed[0].event == .command_end);
        try std.testing.expectEqual(@as(?i16, null), parsed[0].event.command_end.exit);
        try std.testing.expectEqual(@as(u16, 2), parsed[0].event.command_end.row);
    }
    // 실패 exit(130) 복원.
    {
        const parsed = try parseEvents(a, "maru.trace.v1\nevent 3 shell.command-end surface=1 row=0 exit=130\n");
        defer freeParsedEvents(a, parsed);
        try std.testing.expectEqual(@as(?i16, 130), parsed[0].event.command_end.exit);
        try std.testing.expectEqual(@as(usize, 3), parsed[0].index);
    }
    // cwd escape 복원(공백·따옴표·개행이 섞인 경로가 원문으로).
    {
        const events = [_]terminal.types.ShellEvent{.cwd_changed};
        const text = try renderShellEvents(a, 2, &events, "a \"b\"\n/c");
        defer a.free(text);
        const parsed = try parseEvents(a, text);
        defer freeParsedEvents(a, parsed);
        try std.testing.expect(parsed[0].event == .cwd_changed);
        try std.testing.expectEqualStrings("a \"b\"\n/c", parsed[0].event.cwd_changed);
    }
}

// base kind는 재생의 권위 데이터 — 핵심 검증: output/resize/input/process-exit writer가 낸 라인을 parseEvents가
// 원 payload(원시 바이트·크기·종료코드)로 되읽는다(round-trip). output 바이트는 ESC·제어·개행이 섞여도 escape
// 왕복으로 무손실 복원돼야 재생이 화면을 정확히 재구성한다.
test "trace base kind round-trip: output/resize/input/process-exit writer↔parseEvents" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeHeader(&out.writer);
    try writeOutputEvent(&out.writer, 0, 1, "hi\x1b[31m!\r\n"); // ESC·CR·LF 섞인 출력
    try writeResizeEvent(&out.writer, 1, 1, 120, 40);
    try writeInputEvent(&out.writer, 2, 1, "ls\r");
    try writeProcessExitEvent(&out.writer, 3, 1, 0);
    try writeProcessExitEvent(&out.writer, 4, 1, null); // code=none

    const parsed = try parseEvents(a, out.written());
    defer freeParsedEvents(a, parsed);

    try std.testing.expectEqual(@as(usize, 5), parsed.len);
    try std.testing.expect(parsed[0].event == .output);
    try std.testing.expectEqualStrings("hi\x1b[31m!\r\n", parsed[0].event.output); // 무손실 복원
    try std.testing.expect(parsed[1].event == .resize);
    try std.testing.expectEqual(@as(u16, 120), parsed[1].event.resize.cols);
    try std.testing.expectEqual(@as(u16, 40), parsed[1].event.resize.rows);
    try std.testing.expect(parsed[2].event == .input);
    try std.testing.expectEqualStrings("ls\r", parsed[2].event.input);
    try std.testing.expect(parsed[3].event == .process_exit);
    try std.testing.expectEqual(@as(?i32, 0), parsed[3].event.process_exit);
    try std.testing.expectEqual(@as(?i32, null), parsed[4].event.process_exit);
}

// OOM 경로 누수 회귀: 소유 문자열(output/input/cwd)을 든 이벤트를 파싱하는 도중 어느 할당이 실패해도, 방금
// 파싱한 문자열과 list 전체가 새지 않아야 한다(list.append 실패 시 errdefer가 못 잡는 갭 — code-review 회귀).
test "parseEvents: 모든 할당 실패 지점에서 누수 없음" {
    const text = "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"hi\\r\\nthere\"\n" ++
        "event 1 shell.cwd-changed surface=1 cwd=\"/tmp/proj\"\n" ++
        "event 2 input surface=1 bytes=\"ls\\r\"\n" ++
        "event 3 resize surface=1 cols=8 rows=2\n";
    const Runner = struct {
        fn run(a: std.mem.Allocator, t: []const u8) !void {
            const parsed = try parseEvents(a, t);
            freeParsedEvents(a, parsed);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Runner.run, .{text});
}

// fixture 가드는 output을 재조립해 스캔해야 한다 — 핵심 회귀(code-review [12]): 비밀이 PTY read 경계로 두 output
// 이벤트에 쪼개져도(`...API_TOKEN` / `=secret...`) 연속 재결합 후 잡아야 한다. per-event 직렬화 텍스트 스캔은 놓친다.
test "guardFixture: read 경계로 쪼개진 비밀도 재조립해 잡는다" {
    const a = std.testing.allocator;
    // API_TOKEN 과 =값이 서로 다른 output 이벤트에 걸침.
    const split =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"$ export API_TOKEN\"\n" ++
        "event 1 output surface=1 bytes=\"=ghp_realsecret\\r\\n\"\n";
    try std.testing.expectError(error.SensitiveContent, guardFixture(a, split));

    // cwd 값에 든 비밀도.
    const cwd_secret =
        "maru.trace.v1\n" ++
        "event 0 shell.cwd-changed surface=1 cwd=\"/home/u/SECRET_KEY=abc\"\n";
    try std.testing.expectError(error.SensitiveContent, guardFixture(a, cwd_secret));

    // clean trace는 통과.
    const clean =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"$ ls -la /home/user\\r\\n\"\n" ++
        "event 1 resize surface=1 cols=80 rows=24\n";
    try guardFixture(a, clean);
}
