//! 파일 패널에서 고른 선택을 터미널 CLI에 붙여넣을 페이로드로 조립한다(docs/send-selection-to-agent.md).
//!
//! **이 모듈이 안전 계약을 소유한다.** 터미널에 쓰는 바이트는 셸의 표준 입력이라 개행이 섞이면 그 자리에서
//! 실행된다. 문서 인용에는 임의 텍스트가 들어올 수 있으므로 ⑴ 페이로드 끝에 개행을 붙이지 않고, ⑵ bracketed
//! paste가 꺼진 대상에는 여러 줄을 보내지 않으며, ⑶ 인용을 상한으로 자른다.
//!
//! DOM·AppKit 비의존 순수 로직이라 헤드리스로 전수 검증한다(L2 중립).

const std = @import("std");

/// 인용 상한. 넘으면 자르고 생략 표시를 붙인다. 상한이 없으면 큰 문서를 통째로 붙여넣어 대상 프롬프트가 마비된다.
pub const max_quote_lines: usize = 64;
pub const max_quote_bytes: usize = 8 * 1024;

pub const Selection = struct {
    /// 트리 루트 기준 상대 경로(루트 밖이면 절대 경로). native가 핀 경로에서 파생한다 — web은 지정할 수 없다.
    path: []const u8,
    /// 1-based 닫힌 구간.
    start_line: u32,
    end_line: u32,
    /// 사용자가 고른 원문. 이스케이프하지 않는다 — 셸이 해석할 자리가 아니라 에이전트 프롬프트에 놓기 때문이다.
    text: []const u8,
};

pub const Options = struct {
    /// 대상이 bracketed paste를 켜 두었는가. 꺼져 있으면 여러 줄을 보내지 않는다(중간 개행이 실행 트리거가 된다).
    bracketed_paste: bool,
};

/// `@경로:시작-끝` 한 줄을 쓴다. 한 줄 선택이면 범위를 접는다.
fn writeReference(writer: *std.Io.Writer, sel: Selection) !void {
    if (sel.start_line == sel.end_line) {
        try writer.print("@{s}:{d}", .{ sel.path, sel.start_line });
    } else {
        try writer.print("@{s}:{d}-{d}", .{ sel.path, sel.start_line, sel.end_line });
    }
}

/// 선택 텍스트를 `> ` 인용으로 감싸 쓴다. 상한을 넘으면 자르고 생략 줄을 붙인다.
/// 반환값은 생략된 줄 수(0이면 전량 포함).
fn writeQuote(writer: *std.Io.Writer, text: []const u8) !usize {
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |_| total += 1;

    var written_lines: usize = 0;
    var written_bytes: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // 바이트 상한은 줄 단위로 끊는다 — UTF-8 중간에서 자르면 깨진 글자가 나간다.
        if (written_lines >= max_quote_lines or written_bytes + line.len > max_quote_bytes) break;
        try writer.writeAll("\n> ");
        try writer.writeAll(line);
        written_lines += 1;
        written_bytes += line.len;
    }
    return total - written_lines;
}

/// 페이로드를 조립해 `out`에 쓴다. 반환은 쓴 바이트 수(버퍼 부족이면 null — fail-closed).
///
/// **끝에 개행을 붙이지 않는다.** 사용자가 프롬프트를 보고 직접 Enter를 눌러야 전송된다.
pub fn build(sel: Selection, options: Options, out: []u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    writeReference(&writer, sel) catch return null;
    // bracketed paste가 꺼진 대상에는 인용을 붙이지 않는다. 안전한 축약(경로 참조 한 줄)이 가능한데 여러 줄
    // 개행을 흘려보낼 이유가 없다. 참조만으로도 에이전트가 그 파일 그 줄을 열 수 있다.
    if (options.bracketed_paste and sel.text.len > 0) {
        const omitted = writeQuote(&writer, sel.text) catch return null;
        if (omitted > 0) writer.print("\n> …({d}줄 생략)", .{omitted}) catch return null;
    }
    return writer.buffered();
}

const testing = std.testing;

test "reference collapses a single-line range and keeps the closed interval otherwise" {
    var buf: [256]u8 = undefined;
    const one = build(
        .{ .path = "docs/a.md", .start_line = 12, .end_line = 12, .text = "" },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expectEqualStrings("@docs/a.md:12", one);

    var buf2: [256]u8 = undefined;
    const many = build(
        .{ .path = "docs/a.md", .start_line = 12, .end_line = 20, .text = "" },
        .{ .bracketed_paste = true },
        &buf2,
    ).?;
    try testing.expectEqualStrings("@docs/a.md:12-20", many);
}

test "payload never ends with a newline" {
    // 안전 계약의 핵심이다 — 끝의 개행 하나가 곧 실행 트리거다. 인용 유무·절단 여부와 무관하게 성립해야 한다.
    var buf: [8192]u8 = undefined;
    const cases = [_]Selection{
        .{ .path = "a.md", .start_line = 1, .end_line = 1, .text = "" },
        .{ .path = "a.md", .start_line = 1, .end_line = 2, .text = "첫 줄\n둘째 줄" },
        .{ .path = "a.md", .start_line = 1, .end_line = 2, .text = "끝에 개행이 있는 선택\n" },
    };
    for (cases) |sel| {
        inline for (.{ true, false }) |bracketed| {
            const payload = build(sel, .{ .bracketed_paste = bracketed }, &buf).?;
            try testing.expect(payload.len > 0);
            try testing.expect(payload[payload.len - 1] != '\n');
        }
    }
}

test "quote is included only when the target keeps bracketed paste on" {
    var buf: [1024]u8 = undefined;
    const sel: Selection = .{ .path = "a.md", .start_line = 3, .end_line = 4, .text = "하나\n둘" };

    const with_quote = build(sel, .{ .bracketed_paste = true }, &buf).?;
    try testing.expectEqualStrings("@a.md:3-4\n> 하나\n> 둘", with_quote);

    // 꺼진 대상: 여러 줄을 흘리지 않고 참조 한 줄로 축약한다.
    var buf2: [1024]u8 = undefined;
    const reference_only = build(sel, .{ .bracketed_paste = false }, &buf2).?;
    try testing.expectEqualStrings("@a.md:3-4", reference_only);
    try testing.expect(std.mem.indexOfScalar(u8, reference_only, '\n') == null);
}

test "quote truncates at the line cap and says how much was dropped" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..max_quote_lines + 10) |i| {
        if (i > 0) try text.append(testing.allocator, '\n');
        var line_buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "line{d}", .{i});
        try text.appendSlice(testing.allocator, line);
    }
    var buf: [16 * 1024]u8 = undefined;
    const payload = build(
        .{ .path = "a.md", .start_line = 1, .end_line = @intCast(max_quote_lines + 10), .text = text.items },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expect(std.mem.indexOf(u8, payload, "…(10줄 생략)") != null);
    // 마지막 포함 줄은 상한 직전이고, 그 다음 줄은 들어가지 않았다.
    try testing.expect(std.mem.indexOf(u8, payload, "> line63") != null);
    try testing.expect(std.mem.indexOf(u8, payload, "> line64") == null);
    try testing.expect(payload[payload.len - 1] != '\n');
}

test "quote truncates on the byte cap without splitting a line" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 한 줄이 1 KiB인 줄을 여러 개 — 줄 수 상한보다 바이트 상한이 먼저 걸린다.
    for (0..12) |i| {
        if (i > 0) try text.append(testing.allocator, '\n');
        try text.appendNTimes(testing.allocator, 'x', 1024);
    }
    var buf: [32 * 1024]u8 = undefined;
    const payload = build(
        .{ .path = "a.md", .start_line = 1, .end_line = 12, .text = text.items },
        .{ .bracketed_paste = true },
        &buf,
    ).?;
    try testing.expect(std.mem.indexOf(u8, payload, "줄 생략)") != null);
    // 잘린 자리는 항상 줄 경계다 — 인용 줄은 전부 온전한 1 KiB다(UTF-8 중간 절단이 없다).
    var lines = std.mem.splitSequence(u8, payload, "\n> ");
    _ = lines.next(); // 참조 줄
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "…")) break;
        try testing.expectEqual(@as(usize, 1024), line.len);
    }
}

test "build fails closed when the buffer cannot hold the reference" {
    var tiny: [4]u8 = undefined;
    try testing.expect(build(
        .{ .path = "very/long/path.md", .start_line = 1, .end_line = 2, .text = "x" },
        .{ .bracketed_paste = true },
        &tiny,
    ) == null);
}
