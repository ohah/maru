//! `maru.trace.v1` **replay 재적용** — reader(`trace.parseEvents`)가 되읽은 이벤트를 fresh `TerminalCore`에 다시
//! 먹여 상태를 재현한다. 핵심 규율(docs/trace-replay.md): **public 경로로만** 재현한다 — private parser storage를
//! 직접 만지지 않고 실제 파서(`core.write`)/`core.resize`를 거친다. 그래야 재현이 파서 경로까지 검증한다(재적용이
//! 파서 버그도 드러낸다).
//!
//! **한 번에 한 surface**: 멀티 surface trace(탭/split은 MARU_TRACE가 한 파일에 모든 surface를 섞어 기록)를 한
//! core에 통째로 먹이면 화면이 뒤섞이므로, `replayEvents`는 target surface(첫 output의 surface) 하나만 재구성한다.
//! 다른 pane은 `replayEventsForSurface(core, events, surface_id)`로 각각 재생한다(멀티 core 관리는 호출자 몫).
//!
//! **두 모드**:
//!  1. **화면 replay**(권위) — trace에 `output`/`resize` 이벤트가 있으면 output 바이트를 `core.write`로, resize를
//!     `core.resize`로 흘린다. output이 OSC 133/7·텍스트·SGR을 다 담으므로 파서가 **화면·셸 이벤트·cwd를 전부
//!     재도출**한다(byte-for-byte). 이때 shell.* 이벤트는 output에서 파생되므로 재발행하지 않는다(중복 방지).
//!  2. **semantic replay**(fallback) — output 이벤트가 없는 **shell-only trace**(reader가 `renderShellEvents`로 만든
//!     semantic 인덱스 — MARU_TRACE 라이브 레코딩은 이걸 안 냄)는 각 shell.* 를 해당 OSC로 **재발행**하고(행 좌표는
//!     CUP로 커서를 먼저 두어 재현), cwd_changed는 OSC 7로 재발행한다. 라이브 캡처엔 안 쓰이지만 shell-only trace를
//!     다루는 유일한 경로라 유지한다.
//!
//! trace는 이제 attach 시점에 초기 grid 크기를 첫 resize 이벤트로 기록하므로(runtime.attach), replay가 그걸 먼저
//! 적용해 코어를 원 크기로 맞춘 뒤 output을 먹인다. 호출자가 주는 초기 size는 그 첫 resize 전까지의 TerminalCore.init
//! 값(보통 곧 덮어써짐). semantic replay면 rows가 최대 이벤트 행+1 이상이어야 CUP가 clamp되지 않는다.

const std = @import("std");
const terminal = @import("../terminal.zig");
const trace = @import("trace.zig");

pub const ReplayError = trace.ParseError || error{WriteFailed};

/// trace 텍스트를 파싱해 fresh `TerminalCore`에 재적용하고 그 core를 돌려준다(호출자가 `snapshot()`/`dumpUtf8()` 후
/// `deinit()`). output 이벤트가 있으면 화면까지 정확히 재구성된다.
pub fn replayTrace(allocator: std.mem.Allocator, text: []const u8, size: terminal.Size) !terminal.TerminalCore {
    const events = try trace.parseEvents(allocator, text);
    defer trace.freeParsedEvents(allocator, events);
    var core = try terminal.TerminalCore.init(allocator, size);
    errdefer core.deinit();
    try replayEvents(&core, events);
    return core;
}

/// 파싱된 이벤트를 순서대로 core에 재적용한다. 멀티 surface trace(탭/split은 한 파일에 모든 surface가 섞임)를 한
/// core에 통째로 먹이면 화면이 뒤섞이므로, **한 surface만** 재구성한다 — 첫 output(없으면 첫 이벤트)의 surface를
/// target으로 잡는다. 다른 pane은 `replayEventsForSurface`에 그 surface_id를 줘 각각 재생한다(멀티 core는 호출자 몫).
pub fn replayEvents(core: *terminal.TerminalCore, events: []const trace.ParsedEvent) !void {
    const target = targetSurface(events) orelse return; // 이벤트 없음 — no-op
    try replayEventsForSurface(core, events, target);
}

/// 특정 surface의 이벤트만 골라 core에 재적용한다(멀티 surface trace에서 pane별 재생). has_output도 그 surface
/// 기준으로 본다(그 surface에 output이 있으면 화면 replay, 없으면 semantic fallback).
pub fn replayEventsForSurface(core: *terminal.TerminalCore, events: []const trace.ParsedEvent, surface_id: u64) !void {
    const has_output = for (events) |pe| {
        if (pe.surface_id == surface_id and pe.event == .output) break true;
    } else false;
    for (events) |pe| {
        if (pe.surface_id != surface_id) continue;
        try replayOne(core, pe, has_output);
    }
}

/// 화면 재구성 대상 surface — 첫 output 이벤트의 surface(화면 본문이 있는 것). output이 없으면(semantic-only
/// trace) 첫 이벤트의 surface. 이벤트가 없으면 null.
pub fn targetSurface(events: []const trace.ParsedEvent) ?u64 {
    for (events) |pe| if (pe.event == .output) return pe.surface_id;
    if (events.len > 0) return events[0].surface_id;
    return null;
}

fn replayOne(core: *terminal.TerminalCore, pe: trace.ParsedEvent, has_output: bool) !void {
    switch (pe.event) {
        // ── base kind: 재생의 권위 ──
        .output => |bytes| try core.write(bytes), // 원시 출력 → 파서가 화면·셸·cwd 재도출
        .resize => |size| core.resize(size.cols, size.rows) catch return error.WriteFailed,
        .input => {}, // 사용자 입력은 child로 갔던 것 — 화면 상태엔 직접 영향 없음(child 출력이 output으로 옴)
        .process_exit => {}, // 메타데이터(화면 상태 아님)
        // ── shell.* : output이 있으면 파생이라 skip, 없으면 OSC 재발행(semantic replay) ──
        .prompt_start => |row| if (!has_output) {
            try cursorTo(core, row);
            try core.write("\x1b]133;A\x1b\\");
        },
        .input_start => |row| if (!has_output) {
            try cursorTo(core, row);
            try core.write("\x1b]133;B\x07");
        },
        .command_start => |row| if (!has_output) {
            try cursorTo(core, row);
            try core.write("\x1b]133;C\x07");
        },
        .command_end => |ce| if (!has_output) {
            try cursorTo(core, ce.row);
            var buf: [40]u8 = undefined;
            const seq = if (ce.exit) |code|
                std.fmt.bufPrint(&buf, "\x1b]133;D;{d}\x07", .{code}) catch return error.WriteFailed
            else
                "\x1b]133;D\x07";
            try core.write(seq);
        },
        .cwd_changed => |cwd| if (!has_output) try replayCwd(core, cwd),
    }
}

/// CUP(cursor position)로 커서를 (row, 0)에 둔다 — 다음 OSC 133이 그 행에 이벤트를 기록하게(원 행 재구성). 1-based.
fn cursorTo(core: *terminal.TerminalCore, row: u16) !void {
    var buf: [24]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{@as(u32, row) + 1}) catch return error.WriteFailed;
    try core.write(seq);
}

/// cwd를 OSC 7(`file://<host>/<percent-encoded path>`)로 재발행해 파서가 cwd를 복원하게 한다. reader가 준 경로는
/// **decode된 원문**이라, dispatchCwd(osc.zig)의 percent-decode와 대칭이 되게 다시 percent-encode한다(unreserved와
/// '/'는 그대로, 나머지 바이트는 `%XX`). host는 비워도(첫 '/'가 경계) 파서가 path만 취한다.
fn replayCwd(core: *terminal.TerminalCore, cwd: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(core.allocator);
    buf.appendSlice(core.allocator, "\x1b]7;file://") catch return error.WriteFailed;
    if (cwd.len == 0 or cwd[0] != '/') buf.append(core.allocator, '/') catch return error.WriteFailed; // host/path 경계 보장(절대경로 '/' 시작)
    for (cwd) |b| {
        if (isUnreservedOrSlash(b)) {
            buf.append(core.allocator, b) catch return error.WriteFailed;
        } else {
            var hex: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&hex, "%{X:0>2}", .{b}) catch unreachable;
            buf.appendSlice(core.allocator, s) catch return error.WriteFailed;
        }
    }
    buf.append(core.allocator, 0x07) catch return error.WriteFailed; // BEL 종료
    try core.write(buf.items);
}

/// RFC 3986 unreserved(ALPHA/DIGIT/-._~) + path separator '/'. 그 외 바이트는 percent-encode 대상.
fn isUnreservedOrSlash(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or
        b == '-' or b == '.' or b == '_' or b == '~' or b == '/';
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

// 화면 replay는 replay의 완성형 — 핵심 검증: 원 세션에 흘린 output 바이트를 trace로 굳혔다가 fresh core에 재생하면
// 화면(dumpUtf8)이 **byte-for-byte** 동일하게, 셸 이벤트·cwd까지 파서가 재도출한다. output이 권위라 shell.* 재발행
// 없이도(오히려 skip해야) 전부 복원된다.
test "화면 replay: output/resize trace를 재생하면 화면·셸이벤트·cwd가 byte-for-byte 재구성된다" {
    const a = std.testing.allocator;

    // 원 세션: 실제 바이트 스트림(텍스트·SGR·OSC 133/7·resize)을 core에 흘리며, 동시에 trace로 기록.
    var src = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 2 });
    defer src.deinit();
    var rec: std.Io.Writer.Allocating = .init(a);
    defer rec.deinit();
    try trace.writeHeader(&rec.writer);

    const chunks = [_][]const u8{
        "\x1b]133;A\x1b\\", // prompt start
        "\x1b]7;file://h/srv\x07", // cwd → /srv
        "hi \x1b[1mbold\x1b[0m\r\n", // 텍스트 + SGR + 개행
        "\x1b]133;D;0\x07", // command end
    };
    var idx: usize = 0;
    for (chunks) |c| {
        try src.write(c);
        try trace.writeOutputEvent(&rec.writer, idx, 1, c);
        idx += 1;
    }
    // 중간 resize도 기록·적용.
    try src.resize(10, 3);
    try trace.writeResizeEvent(&rec.writer, idx, 1, 10, 3);

    // 재생: trace를 fresh core에 재적용.
    var replayed = try replayTrace(a, rec.written(), .{ .cols = 8, .rows = 2 });
    defer replayed.deinit();

    // 화면이 byte-for-byte 동일.
    const src_screen = try src.dumpUtf8(a);
    defer a.free(src_screen);
    const rep_screen = try replayed.dumpUtf8(a);
    defer a.free(rep_screen);
    try std.testing.expectEqualStrings(src_screen, rep_screen);

    // 파서가 output에서 셸 이벤트·cwd를 재도출(shell.* 재발행 없이).
    try std.testing.expectEqualStrings("/srv", replayed.currentCwd());
    const rep_events = replayed.shellEvents();
    const src_events = src.shellEvents();
    try std.testing.expectEqual(src_events.len, rep_events.len);
    for (src_events, rep_events) |s, r| try std.testing.expect(std.meta.eql(s, r));

    // 크기도 재구성(resize 재적용).
    try std.testing.expectEqual(@as(u16, 10), replayed.snapshot().size.cols);
    try std.testing.expectEqual(@as(u16, 3), replayed.snapshot().size.rows);
}

test "화면 replay 결정성: 같은 output trace를 두 번 재생하면 같은 snapshot" {
    const a = std.testing.allocator;
    const text =
        "maru.trace.v1\n" ++
        "event 0 output surface=1 bytes=\"AB\\r\\nCD\"\n"; // "AB" + CR/LF + "CD" (escape 복원)
    var r1 = try replayTrace(a, text, .{ .cols = 6, .rows = 3 });
    defer r1.deinit();
    var r2 = try replayTrace(a, text, .{ .cols = 6, .rows = 3 });
    defer r2.deinit();
    const s1 = try @import("snapshot.zig").renderTerminalSnapshot(a, r1.snapshot());
    defer a.free(s1);
    const s2 = try @import("snapshot.zig").renderTerminalSnapshot(a, r2.snapshot());
    defer a.free(s2);
    try std.testing.expectEqualStrings(s1, s2);
}

// semantic replay(fallback) — output 없는 shell-only trace는 shell.* 를 OSC로 재발행해 이벤트 스트림·행·cwd를 재현.
test "semantic replay(fallback): shell-only trace를 재생하면 셸 이벤트·행·cwd 재구성" {
    const a = std.testing.allocator;
    var src = try terminal.TerminalCore.init(a, .{ .cols = 8, .rows = 3 });
    defer src.deinit();
    try src.write("\x1b]133;A\x1b\\");
    try src.write("\x1b]133;B\x07ls\r\n");
    try src.write("\x1b]133;C\x07out\r\n");
    try src.write("\x1b]7;file://h/tmp\x07");
    try src.write("\x1b]133;D;0\x07");

    const text = try trace.renderShellEvents(a, 1, src.shellEvents(), src.currentCwd());
    defer a.free(text);

    var replayed = try replayTrace(a, text, .{ .cols = 8, .rows = 3 });
    defer replayed.deinit();

    const src_events = src.shellEvents();
    const rep_events = replayed.shellEvents();
    try std.testing.expectEqual(src_events.len, rep_events.len);
    for (src_events, rep_events) |s, r| try std.testing.expect(std.meta.eql(s, r));
    try std.testing.expectEqualStrings("/tmp", replayed.currentCwd());
}

test "semantic replay cwd percent-encode: 공백·비-unreserved 경로도 재발행→파싱으로 복원" {
    const a = std.testing.allocator;
    const events = [_]terminal.types.ShellEvent{.cwd_changed};
    const text = try trace.renderShellEvents(a, 1, &events, "/my dir/a%b");
    defer a.free(text);
    var replayed = try replayTrace(a, text, .{ .cols = 4, .rows = 1 });
    defer replayed.deinit();
    try std.testing.expectEqualStrings("/my dir/a%b", replayed.currentCwd()); // 공백→%20, %→%25 왕복
}
