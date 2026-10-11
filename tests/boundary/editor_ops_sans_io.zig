// **편집기 순수 판정 폴더(`src/session/editor/ops/`)가 OS 를 안 부른다**는 계약을 강제한다
// (docs/plans/app-session-portability.md §1.5 — L4 에서 옮긴 편집 판정의 울타리).
//
// **왜 필요한가.** session 경계(`tests/boundary/imports.zig`)는 `app`·`platform`·`pty`·`chrome` import 를 막지만
// `std.c`·`std.Io` 는 막지 않는다. 옮긴 편집 판정이 「OS 없이 다른 호스트에서도 돈다」는 이동의 목적을 지키려면
// 그 둘을 이 폴더에서만큼은 막아야 한다. 기존 L2 파일에는 OS 를 쓰는 것이 섞여 있어(`backup.zig` 의 `std.Io`,
// `edit_doc.zig` 의 `std.c`) 폴더 `session/editor` 를 통째로 훑을 수 없다 — 그래서 옮긴 코드는 **전용 하위 폴더**에
// 두고 이 판정자가 **그 폴더를 직접 훑는다**(등록 목록이 없어 새 파일이 자동으로 규칙을 받는다 — `ssh_sans_io` 가
// 등록 개수 방식이 가짜였던 실측을 적어 둔 그 이유).
//
// **꼴은 `ssh_sans_io` 다** — std 는 허용 목록, `@cImport`·`@extern`·`extern`·`asm` 은 막는다. **다른 것은 import 규칙
// 하나다.** ssh 층은 형제 파일만 읽지만 편집 판정은 `delta`·`line_index`·`selection`(위 폴더)과 `terminal` 의 대소문자
// 표를 읽어야 한다. 그래서 상대 import 를 **이 파일 자리에서 풀어** `src/session/` 아래이거나 `src/terminal.zig`·
// `src/terminal/` 아래일 때만 받는다. `root`·`builtin`·모듈 이름(`maru` 등)은 `.zig` 가 아니라 막힌다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - import 한 파일 **안**은 안 본다. `../backup.zig` 를 읽으면 그 파일의 `std.Io` 가 이 폴더로 들어온다. 허용한 자리
//     (`src/session/`·`src/terminal/`)가 넓은 것은 옮긴 판정이 실제로 그 파일들을 읽어서다 — 좁히려면 읽는 파일마다
//     목록이 필요하고, 그 목록이 이 판정자가 피하려는 등록 방식이다.
//   - 허용한 std 이름 **안**에서 순수하지 않은 것을 부르는 것은 못 본다. 여는 줄마다 이유를 적는 것이 방어다.
const std = @import("std");
const posixWalk = @import("posix_walk.zig").posixWalk;

const ops_dir = "src/session/editor/ops";

/// 편집 판정이 만져도 되는 `std` 네임스페이스. **전부 순수 계산이다.** 늘릴 때는 **왜 순수한지**를 같이 적는다.
const pure_std = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "mem", .why = "바이트 비교·자르기·정렬 헬퍼. OS 없음." },
    .{ .name = "math", .why = "정수 한계·포화 연산. OS 없음." },
    .{ .name = "fmt", .why = "할당자에 문자열 조립(`allocPrint`). 출력이 아니다." },
    .{ .name = "testing", .why = "단언 헬퍼. test 블록에서만 쓰이고 OS 를 안 부른다." },
    .{ .name = "ArrayList", .why = "동적 배열. 할당자는 인자로 받는다." },
    .{ .name = "sort", .why = "비교 함수(`asc`). OS 없음." },
    .{ .name = "unicode", .why = "UTF-8 디코드·인코드(대소문자 변환). OS 없음." },
};

const std_binding = "std";

const Violation = struct {
    path: []u8,
    what: []u8,

    fn deinit(self: Violation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.what);
    }
};

fn addViolation(allocator: std.mem.Allocator, out: *std.ArrayList(Violation), path: []const u8, comptime fmt: []const u8, args: anytype) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const what = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(what);
    try out.append(allocator, .{ .path = owned_path, .what = what });
}

const Token = struct { tag: std.zig.Token.Tag, text: []const u8 };

fn tokenize(allocator: std.mem.Allocator, text: [:0]const u8) !std.ArrayList(Token) {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(text);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try list.append(allocator, .{ .tag = token.tag, .text = text[token.loc.start..token.loc.end] });
    }
    return list;
}

fn eq(tokens: []const Token, i: usize, want: []const u8) bool {
    return i < tokens.len and std.mem.eql(u8, tokens[i].text, want);
}

/// `rel` 을 `file` 의 폴더에서 풀어 저장소 상대 경로로 낸다(`..`·`.` 만 처리 — 절대 경로·빈 조각은 실패).
fn resolve(buf: []u8, file: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0 or rel[0] == '/') return null;
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    var dir_it = std.mem.splitScalar(u8, file, '/');
    while (dir_it.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    if (n == 0) return null;
    n -= 1; // 파일 이름을 뺀다
    var rel_it = std.mem.splitScalar(u8, rel, '/');
    while (rel_it.next()) |p| {
        if (p.len == 0) return null;
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (n == 0) return null; // 저장소 밖
            n -= 1;
            continue;
        }
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    var w: usize = 0;
    for (parts[0..n], 0..) |p, i| {
        if (i > 0) {
            if (w >= buf.len) return null;
            buf[w] = '/';
            w += 1;
        }
        if (w + p.len > buf.len) return null;
        @memcpy(buf[w .. w + p.len], p);
        w += p.len;
    }
    return buf[0..w];
}

fn importAllowed(file: []const u8, name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".zig")) return false; // root·builtin·모듈 이름
    var buf: [512]u8 = undefined;
    const at = resolve(&buf, file, name) orelse return false;
    return std.mem.startsWith(u8, at, "src/session/") or
        std.mem.eql(u8, at, "src/terminal.zig") or
        std.mem.startsWith(u8, at, "src/terminal/");
}

fn scan(allocator: std.mem.Allocator, text: [:0]const u8, path: []const u8, out: *std.ArrayList(Violation)) !void {
    var tokens = try tokenize(allocator, text);
    defer tokens.deinit(allocator);
    const t = tokens.items;

    for (t, 0..) |token, i| {
        if (token.tag == .builtin and
            (std.mem.eql(u8, token.text, "@cImport") or std.mem.eql(u8, token.text, "@extern")))
        {
            try addViolation(allocator, out, path, "{s}", .{token.text});
            continue;
        }
        if (token.tag == .keyword_asm) {
            try addViolation(allocator, out, path, "asm (시스템 콜을 직접 친다)", .{});
            continue;
        }
        if (token.tag == .keyword_extern and !eq(t, i + 1, "struct") and !eq(t, i + 1, "union")) {
            try addViolation(allocator, out, path, "extern 선언(링커에게 심볼을 직접 달라고 한다)", .{});
            continue;
        }
        if (token.tag == .builtin and std.mem.eql(u8, token.text, "@import") and
            eq(t, i + 1, "(") and i + 2 < t.len and t[i + 2].tag == .string_literal)
        {
            const quoted = t[i + 2].text;
            if (std.mem.eql(u8, quoted, "\"std\"")) {
                const bound_properly = i >= 2 and eq(t, i - 1, "=") and eq(t, i - 2, std_binding);
                if (!bound_properly) try addViolation(allocator, out, path, "@import(\"std\") 를 `const {s} = …;` 밖에서 쓴다", .{std_binding});
            } else {
                const name = std.mem.trim(u8, quoted, "\"");
                if (!importAllowed(path, name)) {
                    try addViolation(allocator, out, path, "`{s}` 는 src/session·src/terminal 밖이다(검사 밖이 된다)", .{name});
                }
            }
            continue;
        }

        if (token.tag != .identifier or !std.mem.eql(u8, token.text, std_binding)) continue;
        if (i > 0 and eq(t, i - 1, ".")) continue;
        if (eq(t, i + 1, "=")) continue;
        if (!eq(t, i + 1, ".") or i + 2 >= t.len or t[i + 2].tag != .identifier) {
            try addViolation(allocator, out, path, "`{s}` 를 네임스페이스 접근 없이 쓴다(별칭·값 전달)", .{std_binding});
            continue;
        }
        const member = t[i + 2].text;
        var allowed = false;
        for (pure_std) |p| {
            if (std.mem.eql(u8, member, p.name)) allowed = true;
        }
        if (!allowed) try addViolation(allocator, out, path, "std.{s}", .{member});
    }
}

fn readZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 22));
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

test "편집기 순수 판정 폴더는 OS 를 안 부른다 (sans-io)" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList(Violation) = .empty;
    defer {
        for (violations.items) |v| v.deinit(allocator);
        violations.deinit(allocator);
    }
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, ops_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    var files: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ops_dir, entry.path });
        defer allocator.free(path);
        const text = try readZ(allocator, path);
        defer allocator.free(text);
        try scan(allocator, text, path, &violations);
        files += 1;
    }
    for (violations.items) |v| std.debug.print("sans-io 위반: {s} — {s}. 편집 판정은 bytes 만 다룬다(이식 계획 §1.5).\n", .{ v.path, v.what });
    if (violations.items.len != 0) {
        std.debug.print("\n지금 허용된 std 는 이것뿐이다:\n", .{});
        for (pure_std) |p| std.debug.print("  std.{s} — {s}\n", .{ p.name, p.why });
        std.debug.print("정말 필요하면 tests/boundary/editor_ops_sans_io.zig 의 `pure_std` 에 **왜 순수한지와 함께** 올린다.\n", .{});
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 0 개 파일을 보고 「위반 0」이라는 거짓 초록을 막는다(경로 오타·파일 이동).
    try std.testing.expect(files >= 1);
}

// ── 판정자가 힘이 있는지 ────────────────────────────────────────────────────

fn countViolations(comptime src: [:0]const u8) !usize {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Violation) = .empty;
    defer {
        for (out.items) |v| v.deinit(allocator);
        out.deinit(allocator);
    }
    try scan(allocator, src, "src/session/editor/ops/x.zig", &out);
    return out.items.len;
}

test "판정자는 OS 진입점과 우회를 잡는다" {
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const f = try std.Io.Dir.cwd().openFile(\"/etc/hosts\", .{});"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("_ = std.c.clock_gettime(0, &ts);"));
    try std.testing.expectEqual(@as(usize, 4), try countViolations("_ = std.fs; _ = std.time; _ = std.Thread; _ = std.posix;"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const c = @cImport(@cInclude(\"x.h\"));"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("pub extern \"c\" fn getenv(n: [*:0]const u8) ?[*:0]u8;"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("pub fn f() void { asm volatile (\"svc #0\"); }"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const s = @import(\"std\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const S = std;"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const r = @import(\"root\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const b = @import(\"builtin\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const m = @import(\"maru\");"));
    // 허용 자리 밖 — platform·app·chrome·저장소 밖.
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const p = @import(\"../../../platform/macos/x.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const a = @import(\"../../../app.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const c = @import(\"../../../chrome.zig\");"));
    try std.testing.expectEqual(@as(usize, 1), try countViolations("const o = @import(\"../../../../../etc/x.zig\");"));
}

test "판정자는 허용한 import·순수한 std·주석을 오탐하지 않는다" {
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const std = @import("std");
        \\const delta = @import("../delta.zig");
        \\const sel = @import("../selection.zig");
        \\const lsp = @import("../../lsp/rpc.zig");
        \\const case = @import("../../../terminal/selection.zig");
        \\const term = @import("../../../terminal.zig");
        \\const sib = @import("other.zig");
        \\var list: std.ArrayList(u8) = .empty;
        \\std.mem.sort(usize, xs, {}, std.sort.asc(usize));
        \\var v = std.unicode.Utf8View.init(s) catch unreachable;
        \\const t = try std.fmt.allocPrint(a, "{s}", .{x});
        \\// std.Io 는 여기 없다.
        \\const msg = "std.c 는 L4 의 것이다";
        \\const S = extern struct { a: u32 };
    ));
}
