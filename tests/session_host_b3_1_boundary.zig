const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "B3-1 RPC authority remains leaf-owned while B3-3 opens only registry execution transitions" {
    const allocator = std.testing.allocator;
    const leaf_path = "src/platform/macos/session_host/rpc_response_authority.zig";
    const registry_path = "src/platform/macos/session_host/attachment_cleanup_registry.zig";
    const leaf = try readSource(allocator, leaf_path);
    defer allocator.free(leaf);
    const registry = try readSource(allocator, registry_path);
    defer allocator.free(registry);
    const leaf_product = productPrefix(leaf);
    const registry_product = productPrefix(registry);

    // B3-3 adds only the builtin test-mode gate for its destructive epoch-exhaustion fixture.
    try std.testing.expectEqual(@as(usize, 4), count(leaf_product, "@import(\""));
    inline for (.{
        "@import(\"std\")",
        "@import(\"generation_attachment_contract.zig\")",
        "@import(\"external_owner_seal.zig\")",
    }) |allowed| try std.testing.expectEqual(@as(usize, 1), count(leaf_product, allowed));
    inline for (.{
        "client.zig",
        "client_slot.zig",
        "generation_transport.zig",
        "executed_response.zig",
        "socket",
        "Allocator",
        "RemoteRuntime",
        "reconnect",
    }) |forbidden| try std.testing.expectEqual(@as(usize, 0), countCodeTokens(leaf_product, forbidden));
    inline for (.{
        "pub fn reserveExecuting(",
        "pub fn rollbackExecuting(",
        "pub fn settleExecutingTerminal(",
    }) |public_transition| try std.testing.expectEqual(
        @as(usize, 1),
        count(leaf_product, public_transition),
    );
    inline for (.{ "publish", "borrow", "beginRelease", "finishReusable" }) |private_name| {
        const public_decl = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{private_name});
        defer allocator.free(public_decl);
        try std.testing.expectEqual(@as(usize, 0), count(leaf_product, public_decl));
        const private_decl = try std.fmt.allocPrint(allocator, "fn {s}(", .{private_name});
        defer allocator.free(private_decl);
        try std.testing.expectEqual(@as(usize, 1), count(leaf_product, private_decl));
    }

    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "@import(\"rpc_response_authority.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "rpc_response_authority: rpc_response_authority.Authority = .{}"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        count(registry_product, "identity: ?contract.BindingIdentity"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, ".rpc_response_authority.initInPlace(self.incarnation, identity)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(
            registry_product,
            "entry.rpc_response_authority.settledExactFor(registry_incarnation, identity)",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "entry.rpc_response_authority.pristineExact()"),
    );
    inline for (.{
        ".rpc_response_authority.reserveExecuting(",
        ".rpc_response_authority.rollbackExecuting(",
        ".rpc_response_authority.settleExecutingTerminal(",
    }) |b3_3_transition| try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, b3_3_transition),
    );
    inline for (.{
        ".rpc_response_authority.publish(",
        ".rpc_response_authority.borrow(",
        ".rpc_response_authority.beginRelease(",
        ".rpc_response_authority.finishReusable(",
    }) |future_transition| try std.testing.expectEqual(
        @as(usize, 0),
        count(registry_product, future_transition),
    );

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        if (std.mem.eql(u8, path, leaf_path) or std.mem.eql(u8, path, registry_path)) continue;
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        const expected: usize = if (std.mem.eql(
            u8,
            path,
            "src/platform/macos/session_host/client_slot.zig",
        )) 20 else if (std.mem.eql(
            u8,
            path,
            "src/platform/macos/session_host/rpc_executed_response.zig",
        )) 1 else 0;
        try std.testing.expectEqual(expected, count(source, "rpc_response_authority"));
    }
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
    );
}

fn productPrefix(source: []const u8) []const u8 {
    return source[0 .. std.mem.indexOf(u8, source, "\ntest \"") orelse source.len];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

// The source contract is identifier/import oriented. Comments deliberately explain the forbidden
// dependencies, so quoted prose is ignored for the handful of token names checked above.
fn countCodeTokens(source: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        result += count(code, needle);
    }
    return result;
}

// ── 경로 구분자 정규화 (호스트 이식) ─────────────────────────────────────────────────────────────
// `std.Io.Dir.Walker`의 `entry.path`는 **호스트 native 구분자**를 쓴다 — Windows에서는 `platform\macos\x.zig`.
// 이 파일의 스캐너들은 그 경로를 `"platform/macos/x.zig"` 같은 **`/` 리터럴과 비교**하므로, 그대로 두면 제외
// 목록과 매칭이 조용히 전부 빗나간다(실측: 제외됐어야 할 파일이 집계에 섞여 boundary 카운트가 부풀었다 —
// 컴파일도 통과하고 macOS CI도 초록인 채로 Windows에서만 틀렸다). 그래서 walker를 감싸 경로를 `/`로 정규화한다.
// POSIX 호스트에서는 native 구분자가 이미 `/`라 `next`가 std walker를 그대로 통과시킨다(무동작·무비용).
const PosixWalker = struct {
    inner: std.Io.Dir.Walker,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn next(self: *PosixWalker, io: std.Io) !?std.Io.Dir.Walker.Entry {
        var entry = (try self.inner.next(io)) orelse return null;
        if (std.fs.path.sep == '/') return entry;
        // 잘라내면 "제외 목록에 없는 경로"로 조용히 바뀌어 게이트가 거짓 초록이 된다 — 시끄럽게 실패시킨다.
        if (entry.path.len >= self.path_buf.len) return error.NameTooLong;
        for (entry.path, 0..) |byte, i|
            self.path_buf[i] = if (byte == std.fs.path.sep) '/' else byte;
        self.path_buf[entry.path.len] = 0;
        entry.path = self.path_buf[0..entry.path.len :0];
        return entry;
    }

    fn deinit(self: *PosixWalker) void {
        self.inner.deinit();
    }
};

fn posixWalk(dir: std.Io.Dir, allocator: std.mem.Allocator) !PosixWalker {
    return .{ .inner = try dir.walk(allocator) };
}
