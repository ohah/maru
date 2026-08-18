// 이 테스트는 **번역 표에 아무도 안 쓰는 키가 남지 않게** 한다(docs/i18n.md §7).
//
// **무엇을 증명하나.** `src/i18n.zig` 의 `Table` 필드 중 제품·테스트 어디에서도 참조되지 않는 것이
// 없다. 표는 두 언어를 나란히 두는 자리이고, 그 두 벌은 `Table` 에 기본값이 없다는 규칙 덕분에 서로
// 어긋날 수 없다 — 그러나 **둘 다 아무도 안 읽는 문장**이 되는 것까지는 그 규칙이 막지 못한다.
//
// **왜 게이트가 필요한가 — 실제로 15개가 쌓여 있었다.** 2026-08-18 전수 조사에서 `color_*` 다섯,
// `lbl_*` 셋, `scm_show_all`·`scm_agent`·`common_none`·`upd_available`·`exit_normal`·
// `sb_awaiting_input`, 그리고 `git_local_check` 이 참조 0이었다. 마지막 것이 이 게이트가 필요한
// 이유를 가장 잘 보여준다 — 자동 치환이 셸 스크립트 본문에 `maru.i18n.t(.git_local_check)` 를 **글자
// 그대로** 써 넣었고, 그 사고를 되돌리자 키만 남았다. 즉 고아 키는 "안 쓰는 문장"이 아니라 **되돌린
// 작업의 잔해**이거나 **옮기다 만 자리**라서, 다음 사람이 그것을 살아 있는 계약으로 오해한다.
// 번역 대상이 늘 때마다 한국어 문장을 하나 더 손보게 만드는 비용도 그대로 남는다.
//
// **규칙**: `Table` 의 모든 필드는 `src/**`(i18n.zig 제외)·`tests/**` 중 어딘가에서 `.<key>` 로
// 참조되어야 한다. 하나라도 없으면 실패하고, 이름을 전부 출력한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - 참조가 **테스트에만** 있는 키는 통과한다. 그 구분까지 세우면 "먼저 키를 넣고 화면을 붙이는" 정상
//     순서가 막힌다. 대신 그런 키는 §7 의 리터럴 게이트가 화면 쪽에서 따로 본다.
//   - `.key` 라는 **글자**만 본다. 같은 이름의 필드가 다른 struct 에 있으면 그 참조를 오인해 고아를
//     놓친다. 표의 키 이름이 접두어로 영역을 나누는 관례(`set_`·`scm_`·`cfg_`)라 실제로 겹칠 일은
//     드물고, 놓치는 방향이라 **없는 위반을 만들어 내지는 않는다**.
//   - 반대로 키를 **지워야 하는데 안 지운 것**만 잡고, 문장의 내용이 낡았는지는 못 본다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// 표 파일. 여기서 키를 읽고, 참조를 셀 때는 **제외**한다(정의 자체가 참조로 잡히면 전부 통과한다).
const table_path = "src/i18n.zig";

/// `src/i18n.zig` 의 `Table` 필드 이름을 순서대로 읽는다.
///
/// 파싱이 아니라 토큰 스캔이다 — `Table` 은 `pub const Table = struct { ... };` 한 덩어리이고 필드는
/// 전부 `이름: [:0]const u8,` 꼴이라 이 좁은 모양만 본다. 모양이 달라지면 키를 **덜** 읽어 고아를
/// 놓치므로, 키가 하나도 안 잡히면 실패로 처리해 스캐너가 조용히 눈머는 것을 막는다.
fn tableKeys(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const begin = std.mem.indexOf(u8, source, "pub const Table = struct {") orelse
        return error.TableNotFound;
    const rest = source[begin..];
    const end = std.mem.indexOf(u8, rest, "\n};") orelse return error.TableNotTerminated;
    const body = rest[0..end];

    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        // 줄 끝 주석을 먼저 뗀다. 안 떼면 `key: [:0]const u8, // 설명` 이 모양에 안 맞아 **그 키만
        // 조용히 안 세어진다** — `NoKeysFound` 는 전부 못 읽었을 때만 막지 일부 누락은 못 막는다.
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        const trimmed = std.mem.trim(u8, code, " \t\r");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r"), "[:0]const u8,")) continue;
        const name = trimmed[0..colon];
        if (name.len == 0) continue;
        try keys.append(allocator, name);
    }
    if (keys.items.len == 0) return error.NoKeysFound;
    return keys.toOwnedSlice(allocator);
}

/// `.<key>` 참조가 `haystack` 에 있는가. 앞 글자가 식별자면 `.foo_bar` 안의 `.bar` 같은 오인이 되므로
/// 뒤 경계만이 아니라 **`.` 바로 앞이 식별자 문자가 아닌 것**까지 본다.
fn referenced(haystack: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, key)) |at| {
        i = at + 1;
        if (at == 0) continue;
        if (haystack[at - 1] != '.') continue;
        if (at >= 2 and isIdentChar(haystack[at - 2])) continue; // `x.key` 필드 접근이 아니라 `.key` enum 리터럴만
        const after = at + key.len;
        if (after < haystack.len and isIdentChar(haystack[after])) continue;
        return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// 줄 주석을 뗀 소스를 붙인다.
///
/// **주석 속 `.key` 는 참조가 아니다.** 이 구분이 없으면 이 게이트는 자기 존재 이유로 든 사고 —
/// 자동 치환이 셸 스크립트 본문과 doc comment 에 `maru.i18n.t(.git_local_check)` 를 글자 그대로 써
/// 넣은 것 — 을 **그 사고가 살아 있는 동안에는 못 잡고** 되돌린 뒤에야 잡는다. 순서가 거꾸로다.
///
/// 문자열 리터럴 안의 `//` 도 함께 잘리므로 소비자 쪽 참조를 **덜** 세는 쪽으로 틀릴 수 있다. 그 방향의
/// 오류는 "고아가 아닌데 고아라고 말한다"라서 사람이 즉시 본다 — 반대 방향(놓치는 것)보다 낫다.
fn appendWithoutComments(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, code);
        try out.append(allocator, '\n');
    }
}

/// 표 파일에서 **정의 세 덩어리**(`Table` struct 와 `en`/`ko` 값)를 뺀 나머지를 붙인다. 그 덩어리
/// 안의 이름은 참조가 아니라 선언이라, 세면 고아가 전부 사라진다.
fn appendWithoutDefinitions(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8) !void {
    const blocks = [_][]const u8{
        "pub const Table = struct {",
        "pub const en: Table = .{",
        "pub const ko: Table = .{",
    };
    var rest = source;
    outer: while (rest.len > 0) {
        // 가장 먼저 나오는 정의 덩어리를 찾아 그 앞까지 담고, 덩어리는 통째로 건너뛴다.
        var best: ?usize = null;
        var best_head: []const u8 = "";
        for (blocks) |head| {
            const at = std.mem.indexOf(u8, rest, head) orelse continue;
            if (best == null or at < best.?) {
                best = at;
                best_head = head;
            }
        }
        const at = best orelse break :outer;
        try appendWithoutComments(allocator, out, rest[0..at]);
        const body = rest[at + best_head.len ..];
        const close = std.mem.indexOf(u8, body, "\n};") orelse break :outer;
        rest = body[close + 3 ..];
    }
    try appendWithoutComments(allocator, out, rest);
}

/// `roots` 아래 `.zig` 를 전부 이어 붙인 하나의 버퍼. 파일마다 다시 훑지 않으려는 것뿐이다.
fn readAllSources(allocator: std.mem.Allocator, roots: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
            defer allocator.free(source);
            // 표 파일도 **읽되 정의 세 덩어리는 뺀다** — 이 파일 안에도 진짜 소비자가 있다
            // (`preferenceLabel` 이 `.set_language_auto` 를 쓴다). 정의를 안 빼면 모든 키가
            // 자기 선언에 걸려 통과하므로, 파일째 빼는 대신 덩어리만 뺀다.
            if (std.mem.endsWith(u8, entry.basename, "i18n.zig"))
                try appendWithoutDefinitions(allocator, &out, source)
            else
                try appendWithoutComments(allocator, &out, source);
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

test "번역 표에 아무도 안 쓰는 키가 없다 (i18n 계약 §7)" {
    const allocator = std.testing.allocator;

    const table_src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, table_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(table_src);
    const keys = try tableKeys(allocator, table_src);
    defer allocator.free(keys);

    const sources = try readAllSources(allocator, &.{ "src", "tests" });
    defer allocator.free(sources);

    var orphans: std.ArrayList([]const u8) = .empty;
    defer orphans.deinit(allocator);
    for (keys) |key| {
        if (!referenced(sources, key)) try orphans.append(allocator, key);
    }

    if (orphans.items.len != 0) {
        std.debug.print("\n참조 0인 번역 키 {d}개 — 지우거나, 쓰는 자리를 붙여라:\n", .{orphans.items.len});
        for (orphans.items) |k| std.debug.print("  .{s}\n", .{k});
    }
    try std.testing.expectEqual(@as(usize, 0), orphans.items.len);
}

// 스캐너가 **정말로 보고 있는지**를 스캐너 자신으로 확인한다. 위 테스트는 위반이 없을 때 통과하는데,
// 스캐너가 눈이 멀어도 똑같이 통과하기 때문이다(키를 0개 읽거나 참조를 늘 참으로 보면).
test "스캐너는 고아를 실제로 구분한다" {
    const allocator = std.testing.allocator;
    const source =
        \\pub const Table = struct {
        \\    used_key: [:0]const u8,
        \\    orphan_key: [:0]const u8,
        \\    not_a_key: u32,
        \\};
    ;
    const keys = try tableKeys(allocator, source);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len); // `not_a_key` 는 문자열 필드가 아니다

    const consumer = "const x = i18n.t(.used_key); // orphan_key 는 주석에만 있고 .used_key_extra 는 다른 키다";
    try std.testing.expect(referenced(consumer, "used_key"));
    try std.testing.expect(!referenced(consumer, "orphan_key"));

    // `.foo` 로 시작하는 더 긴 키가 짧은 키의 참조로 오인되지 않는다.
    try std.testing.expect(!referenced("i18n.t(.used_key_extra)", "used_key"));
    // 필드 접근(`self.used_key`)은 enum 리터럴 참조가 아니다.
    try std.testing.expect(!referenced("const v = self.used_key;", "used_key"));
}

// `appendWithoutDefinitions` 는 **덜 지우는 쪽으로 실패하면 조용하다** — 정의가 남으면 모든 키가 자기
// 선언에 걸려 통과하고, 위 테스트는 아무 말 없이 초록이 된다. 그래서 여기서 따로 못 박는다.
test "스캐너는 표 정의부를 빼고, 같은 파일의 진짜 소비자는 남긴다" {
    const allocator = std.testing.allocator;
    const source =
        \\pub const Table = struct {
        \\    lonely: [:0]const u8,
        \\    spoken: [:0]const u8,
        \\};
        \\pub const en: Table = .{
        \\    .lonely = "x",
        \\    .spoken = "y",
        \\};
        \\pub const ko: Table = .{
        \\    .lonely = "x",
        \\    .spoken = "y",
        \\};
        \\pub fn label() [:0]const u8 {
        \\    return t(.spoken);
        \\}
    ;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendWithoutDefinitions(allocator, &out, source);

    // 정의 세 덩어리가 빠졌으니 `.lonely` 는 어디에도 안 남는다.
    try std.testing.expect(!referenced(out.items, "lonely"));
    // 같은 파일 안의 진짜 소비자(`preferenceLabel` 같은 자리)는 살아 남는다.
    try std.testing.expect(referenced(out.items, "spoken"));
}

// 위 두 자기검사가 다루지 못한 두 눈멂을 따로 못 박는다. 둘 다 **덜 보는 쪽**이라 조용하다.
test "스캐너는 줄 끝 주석이 붙은 키도 세고, 주석 속 참조는 안 센다" {
    const allocator = std.testing.allocator;

    // (a) 트레일링 주석이 붙어도 키다. 예전에는 이 줄이 모양에 안 맞아 **그 키만** 안 세어졌고,
    //     `NoKeysFound` 는 전부 못 읽었을 때만 막으므로 아무 말 없이 통과했다.
    const source =
        \\pub const Table = struct {
        \\    plain: [:0]const u8,
        \\    commented: [:0]const u8, // 이 줄도 키다
        \\};
    ;
    const keys = try tableKeys(allocator, source);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);

    // (b) 주석 안의 `.key` 는 참조가 아니다. 이 구분이 없으면 게이트가 **사고가 살아 있는 동안** 못
    //     잡고 되돌린 뒤에야 잡는다 — 순서가 거꾸로다.
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(allocator);
    try appendWithoutComments(allocator, &stripped, "// 예전에는 .commented 를 여기 적어 두었다\nconst x = 1;");
    try std.testing.expect(!referenced(stripped.items, "commented"));
}
