//! `maru mcp` **러너**(W9f) — 표준 입력의 JSON-RPC 줄을 [`mcp.zig`](../mcp.zig)에 넘기고, 도구 호출은 `maru browser` 러너를 그대로
//! 돌려 그 출력을 도구 결과로 돌려준다. **표준 출력에는 MCP 메시지만 쓴다**(줄 하나에 메시지 하나 — stdio transport) — CLI 의 출력·
//! 안내(인스턴스 없음 등)는 버퍼로 받아 도구 결과 글에 싣는다. 표준 입력이 닫히면 끝난다.
//!
//! 요청은 하나씩 처리한다(앞 호출이 끝나야 다음 줄을 읽는다 — 같은 탭의 op 은 앱에서도 하나씩이다). 컨트롤 소켓 연결은 호출마다
//! 새로 맺는다 — pane 신원(1g)이 연결마다 이 프로세스의 조상 사슬로 정해진다.
const std = @import("std");
const mcp = @import("../mcp.zig");
const browser_run = @import("../browser/run.zig");
const browser = @import("../browser.zig");

/// 한 줄 상한 — 넘는 줄은 버리고 오류로 답한다(끝없는 입력에 메모리를 쓰지 않게). 가장 큰 정상 인자는 type 의 글·exec 의 식이다.
pub const max_line_bytes: usize = 4 * 1024 * 1024;

const SliceArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    pub fn next(self: *SliceArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var reader: browser_run.LineReader = .{ .max = max_line_bytes };
    defer reader.deinit(allocator);
    while (try reader.next(allocator)) |item| switch (item) {
        .too_long => try writeLine(stdout, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"message too large\"}}"),
        .line => |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len > 0) try handle(io, allocator, line, stdout, stderr);
        },
    };
}

fn handle(io: std.Io, allocator: std.mem.Allocator, line: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    switch (try mcp.handleLine(allocator, arena_state.allocator(), line)) {
        .none => {},
        .reply => |r| {
            defer allocator.free(r);
            try writeLine(stdout, r);
        },
        .call => |c| {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var err: std.Io.Writer.Allocating = .init(allocator);
            defer err.deinit();
            // 인자를 먼저 본다 — CLI 의 도움말 전체 대신 이유 한 줄로 답한다.
            _ = browser.parse(c.argv) catch |e| {
                const msg = try std.fmt.allocPrint(allocator, "error: {s}\n", .{browser_run.usageReason(e)});
                defer allocator.free(msg);
                const r = try mcp.toolResult(allocator, c.id, msg, true);
                defer allocator.free(r);
                return writeLine(stdout, r);
            };
            var args: SliceArgs = .{ .items = c.argv };
            var failed = false;
            browser_run.run(io, allocator, &args, &out.writer, &err.writer) catch |e| {
                failed = true;
                if (err.written().len == 0 and out.written().len == 0) err.writer.print("error: {s}\n", .{@errorName(e)}) catch {};
            };
            if (!failed and mcp.returnsImage(c.tool)) {
                const r = try mcp.imageResult(allocator, c.id, out.written());
                defer allocator.free(r);
                return writeLine(stdout, r);
            }
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(allocator);
            try text.appendSlice(allocator, out.written());
            try text.appendSlice(allocator, err.written());
            const r = try mcp.toolResult(allocator, c.id, text.items, failed);
            defer allocator.free(r);
            try writeLine(stdout, r);
        },
    }
}

fn writeLine(stdout: *std.Io.Writer, bytes: []const u8) !void {
    try stdout.writeAll(bytes);
    try stdout.writeAll("\n");
    try stdout.flush();
}
