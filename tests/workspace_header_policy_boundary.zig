//! workspace 저장 헤더가 **`maru.workspace.v1` 하나로 남는지** 못 박는다(docs/workspace-restore.md 「헤더 정책」).
//!
//! ## 무엇이 있었나
//!
//! 2026-07-08 사용자 결정(845c98459): v2 하드 브레이크는 과설계로 기각 — NO 헤더 bump · NO v1 reject · NO 마이그레이션.
//! 2026-10-04 d097ee4f2 가 커밋 메시지에 한 줄 언급도 없이 헤더를 v2 로 올리고 v1 을 `BadHeader` 로 거절했다. 그 빌드를
//! 설치한 사용자는 매 실행 빈 창을 봤고(host 에는 세션 34 개가 살아 있었다) 헤더 한 줄을 손으로 고쳐서야 돌아왔다.
//!
//! 값 판정(fixture 둘을 읽고 v1 로 다시 쓰는가)은 `src/session/workspace.zig` 의 `workspace header policy` 테스트가
//! `zig build test` 에서 잰다. 여기서는 PR 필수 잡이 매번 도는 자리에서 **헤더 상수·C define·parser 입구·반대 단언이
//! 없는지**를 글자로 잰다 — 다시 올리려면 이 파일과 문서의 정책부터 사용자와 바꿔야 한다.

const std = @import("std");

const workspace_path = "src/session/workspace.zig";
const abi_header_path = "src/platform/macos/app_host_abi.h";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectCount(haystack: []const u8, needle: []const u8, want: usize, what: []const u8) !void {
    const n = countAll(haystack, needle);
    if (n != want) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — {d} 번이어야 한다\n", .{ what, needle, n, want });
        return error.PolicyChanged;
    }
}

/// `fn <name>(` 부터 다음 `fn ` 앞까지. 주석은 이미 지워졌다.
fn fnBody(src: []const u8, comptime name: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, src, "fn " ++ name ++ "(") orelse return error.FunctionMissing;
    const end = std.mem.indexOfPos(u8, src, at + 3, " fn ") orelse src.len;
    return src[at..end];
}

test "workspace 저장 헤더는 v1 이고 옛 v2 는 읽기만 한다" {
    const a = std.testing.allocator;
    const raw = try read(a, workspace_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // ① writer 헤더. 다른 값으로 바꾸면 여기서 멈춘다.
    try expectCount(src, "pub const header = \"maru.workspace.v1\";", 1, "writer 헤더");
    // ② 읽기 별칭. v2 를 빼면 2026-10-04~05 에 저장된 파일이 다시 통째로 거절된다.
    try expectCount(src, "pub const legacy_read_headers = [_][]const u8{\"maru.workspace.v2\"};", 1, "읽기 전용 옛 헤더");
    // ③ parser 입구는 별칭까지 보는 판정 하나를 지난다 — `header` 하나와만 비교하면 별칭이 죽은 코드가 된다.
    const parse_body = try fnBody(src, "parse");
    try expectCount(parse_body, "if (!isReadableHeader(head)) return error.BadHeader;", 1, "parse 의 헤더 입구");
    try expectCount(parse_body, "std.mem.eql(u8, head, header)", 0, "parse 의 v1 전용 비교");
    // ④ 반대 단언이 돌아오지 않는다 — d097 은 「v1 은 BadHeader 여야 한다」를 테스트로 박아 결정을 뒤집었다.
    try expectCount(src, "expectError(error.BadHeader, parse(a, \"maru.workspace.v1", 0, "v1 거절 단언");
    try expectCount(src, "expectError(error.BadHeader, parse(std.testing.allocator, \"maru.workspace.v1", 0, "v1 거절 단언");
}

test "Swift·C 쪽 workspace 헤더 define 도 v1 이다" {
    const a = std.testing.allocator;
    const raw = try read(a, abi_header_path);
    defer a.free(raw);
    // Swift 는 이 define 으로 헤더를 쓴다 — Zig 상수와 갈라지면 저장본을 자기가 못 읽는다.
    try expectCount(raw, "#define MARU_WORKSPACE_HEADER \"maru.workspace.v1\"", 1, "MARU_WORKSPACE_HEADER");
}
