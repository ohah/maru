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
// **규칙**: `Table` 의 모든 필드는 `src/**`·`tests/**` 중 어딘가에서 `.<key>` 로
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

/// 표 파일. 여기서 키를 읽는다.
///
/// **참조를 셀 때 이 파일을 빼면 안 된다** — 표 안에도 진짜 소비자가 있다(`preferenceLabel` 이
/// `.set_language_auto` 를 쓰고, 그것이 그 키의 **유일한** 참조다). 빼면 그 키가 가짜 고아가 된다.
/// 정의가 참조로 잡히는 문제는 파일을 빼서가 아니라 **파서가 enum 리터럴과 struct 초기화 필드를
/// 구별해서** 풀린다.
const table_path = "src/i18n.zig";

/// `src/i18n.zig` 의 `Table` 필드 이름을 순서대로 읽는다.
///
/// 파싱이 아니라 토큰 스캔이다 — `Table` 은 `const Table = struct { ... };` 한 덩어리이고 필드는
/// 전부 `이름: [:0]const u8,` 꼴이라 이 좁은 모양만 본다. 모양이 달라지면 키를 **덜** 읽어 고아를
/// 놓치므로, 키가 하나도 안 잡히면 실패로 처리해 스캐너가 조용히 눈머는 것을 막는다.
///
/// **가시성은 안 본다.** 처음에는 `pub const Table` 을 찾았는데, 그 `pub` 은 밖에서 쓸 이유가 없어
/// 나중에 닫혔고 이 게이트가 `TableNotFound` 로 죽었다. 더 나쁜 것은 `en`/`ko` 쪽이었다 — 그것도
/// `pub const` 로 찾고 있었고 먼저 닫혔는데, 못 찾으면 **덩어리를 안 빼고 그냥 지나가서** 표의 선언이
/// 전부 "참조" 로 세어졌다. 즉 고아가 하나도 안 잡히는 상태로 **조용히** 초록이었다.
fn tableKeys(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    const begin = std.mem.indexOf(u8, source, table_struct_head) orelse
        return error.TableNotFound;
    const rest = source[begin + table_struct_head.len ..];
    // **끝은 중괄호 짝으로 찾는다.** `"\n};"` 를 찾으면 `Table` 안에 중첩 컨테이너가 있고 그 닫는 `};` 가
    // 0 열에 오는 순간 키 읽기가 **거기서 잘린다** — `NoKeysFound` 는 전부 잃었을 때만 막지 일부 누락은
    // 못 막는다. 같은 파일이 덩어리 건너뛰기에서 이미 이 교훈을 얻었는데 이 함수만 옛 방식이었다.
    const end = matchingBraceEnd(rest) orelse return error.TableNotTerminated;
    const body = rest[0 .. end - 1];

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

/// 소스에서 **enum 리터럴**(`.key`)의 이름을 모은다.
///
/// **문자열이 아니라 파서에게 묻는다.** 앞 판들은 `.key` 를 문자열로 찾고 "앞이 `.` 인가", "뒤가
/// 식별자인가", "그 다음이 `=` 인가" 를 손으로 봤는데, 그때마다 다음 철자가 남았다 — 마지막에는
/// `.key` 와 `=` 사이에 **개행**만 끼면 표 사본이 다시 모든 키를 "참조" 로 만들었다(521 필드 사본으로
/// 실측했고 네 게이트가 전부 초록이었다). Zig 파서는 `.key`(enum 리터럴)와 `.key = x`(struct 초기화의
/// 필드 이름)를 **다른 노드**로 준다. 그것이 이 판정이 찾던 구조다.
///
/// 부수 효과로 주석·문자열 안의 `.key` 도 자동으로 빠진다 — 주석 떼는 전처리가 필요 없다.
///
/// **인정하는 한계.** `std.EnumArray(i18n.Key, T).init(.{ .some_key = … })` 는 문법상 필드 이름이라
/// 참조로 안 세어진다. 그 키에 다른 참조가 없으면 **고아가 아닌데 고아로 찍힌다** — 시끄러운 쪽이므로
/// 사람이 보고 판정한다. 오늘 그런 자리는 없다.
fn collectEnumLiterals(allocator: std.mem.Allocator, source: [:0]const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.SourceHasParseErrors;

    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .enum_literal) continue;
        const name_token = tree.nodes.items(.main_token)[i];
        try out.put(allocator, tree.tokenSlice(name_token), {});
    }
}

/// 표를 알아보는 머리. `tableKeys` 가 `Table` 본문을 찾는 데 쓴다.
///
/// **정의를 오려 내는 전처리는 없다.** 앞 판들은 `en`/`ko` 값 블록까지 문자열로 찾아 지웠는데, 그
/// 블록이 만드는 `.key = "…"` 는 파서가 보면 **struct 초기화의 필드 이름**이지 enum 리터럴이 아니다.
/// 참조를 파서에게 물으면 그 자리는 애초에 참조로 안 세어진다 — 오려 내는 기계(머리 찾기·끝 찾기·과잉
/// 삼킴 방어·사본 검사)가 통째로 필요 없어졌고, 그 기계가 다섯 라운드에 걸쳐 낸 구멍도 함께 사라졌다.
const table_struct_head = "const Table = struct {";
/// 머리 바로 뒤(`{` 안)에서 시작해 **짝이 맞는 닫는 중괄호 다음 자리**를 돌려준다.
///
/// 문자열·문자 리터럴·주석 안의 중괄호는 세지 않는다 — 표 값에 `{` 가 든 한국어 문구가 있으면 짝이
/// 어긋난다. 짝을 못 맞추면 `null` 이고, 호출자가 그것을 **실패로** 다룬다.
fn matchingBraceEnd(body: []const u8) ?usize {
    var depth: usize = 1;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '"' => {
                i += 1;
                while (i < body.len and body[i] != '"') : (i += 1) {
                    if (body[i] == '\\') i += 1;
                }
            },
            '\'' => {
                i += 1;
                while (i < body.len and body[i] != '\'') : (i += 1) {
                    if (body[i] == '\\') i += 1;
                }
            },
            '\\' => {
                // **여러 줄 문자열(`\\`)은 줄 끝까지 통째로 건너뛴다.** 앞 판은 이 경우가 없어 값 안의
                // `}` 하나가 덩어리를 **일찍 끊고**(뒤가 참조로 세어진다), `{` 하나가 **늦게 끊고**,
                // `'` 하나가 짝을 통째로 잃게 했다. 형제 함수(`fieldNameIsLiteral`)는 같은 철자에서 이미
                // 한 번 당했는데 이 함수에 그 교훈이 안 넘어왔다.
                if (i + 1 < body.len and body[i + 1] == '\\') {
                    while (i < body.len and body[i] != '\n') : (i += 1) {}
                }
            },
            '/' => {
                if (i + 1 < body.len and body[i + 1] == '/') {
                    while (i < body.len and body[i] != '\n') : (i += 1) {}
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// `roots` 아래 `.zig` 를 전부 훑어 **enum 리터럴 이름의 집합**을 만든다.
fn collectReferences(allocator: std.mem.Allocator, roots: []const []const u8, out: *std.StringHashMapUnmanaged(void), arena: *std.ArrayList([:0]u8)) !void {
    var scanned: usize = 0;
    var saw_table = false;
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            // **심링크도 훑는다.** `.file` 만 받으면 심링크된 `.zig` 가 통째로 안 보인다.
            // **`.zig` 가 아닌 심링크는 실패시킨다.** walker 는 디렉터리 심링크에 안 들어가므로 그 안은
            // **통째로 안 보이고 `scanned` 도 안 올라간다** — 눈이 먼 것을 통과로 읽는 것이다. 앞 판은
            // 심링크된 **파일**만 받아들이고 디렉터리는 그대로 뒀는데, 형제 게이트에는 이 실패 모드를
            // 이미 짜 두었으면서 여기만 반쪽이었다. 조용히 안 보느니 시끄럽게 막는다.
            if (entry.kind == .sym_link and !std.mem.endsWith(u8, entry.basename, ".zig")) {
                std.debug.print(
                    "{s}/{s}: `.zig` 가 아닌 심링크다 — 그 안은 통째로 안 보인다. 실제 디렉터리로 두어라.\n",
                    .{ root, entry.path },
                );
                return error.TestUnexpectedResult;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            if (std.mem.eql(u8, path, table_path)) saw_table = true;

            // **읽기 실패에도 진단을 붙인다.** `try` 로 두면 파일 하나가 테스트를 끝내고 그 뒤 파일은
            // 아무것도 검사되지 않은 채 실패가 stdlib 버그처럼 보인다.
            const source = dir.readFileAllocOptions(
                std.testing.io,
                entry.path,
                allocator,
                .limited(8 * 1024 * 1024),
                .of(u8),
                0,
            ) catch |err| {
                std.debug.print(
                    "{s}: 읽지 못했다({s}) — 이 파일은 검사되지 않았다.\n" ++
                        "  흔한 원인: 8 MiB 상한 초과, 깨진 심링크, 디렉터리를 가리키는 `.zig` 심링크.\n",
                    .{ path, @errorName(err) },
                );
                return err;
            };
            errdefer allocator.free(source);
            try arena.append(allocator, source);

            scanned += 1;
            // **파싱 실패를 삼키지 않는다.** 삼키면 그 파일의 참조가 통째로 사라져 **고아가 아닌 키를
            // 고아로 만든다** — 시끄러운 쪽이지만 원인이 안 보인다.
            collectEnumLiterals(allocator, source, out) catch |err| {
                std.debug.print("{s}: 참조를 못 읽었다({s}) — 이 파일은 검사되지 않았다.\n", .{ path, @errorName(err) });
                return err;
            };
        }
    }
    if (scanned == 0) {
        std.debug.print("훑은 `.zig` 파일이 0 개다 — 스캐너가 눈이 멀었다. cwd 가 저장소 루트라야 돈다.\n", .{});
        return error.TestUnexpectedResult;
    }
    if (!saw_table) {
        std.debug.print("{s} 를 못 만났다 — 표가 옮겨졌거나 스캐너가 그 파일을 건너뛰었다.\n", .{table_path});
        return error.TestUnexpectedResult;
    }
}

test "번역 표에 아무도 안 쓰는 키가 없다 (i18n 계약 §7)" {
    const allocator = std.testing.allocator;

    const table_src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, table_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(table_src);
    const keys = try tableKeys(allocator, table_src);
    defer allocator.free(keys);

    // 참조 이름은 소스 버퍼를 가리키므로 그 버퍼들을 판정이 끝날 때까지 살려 둔다.
    var arena: std.ArrayList([:0]u8) = .empty;
    defer {
        for (arena.items) |buf| allocator.free(buf);
        arena.deinit(allocator);
    }
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(allocator);
    try collectReferences(allocator, &.{ "src", "tests" }, &refs, &arena);

    var orphans: std.ArrayList([]const u8) = .empty;
    defer orphans.deinit(allocator);
    for (keys) |key| {
        if (!refs.contains(key)) try orphans.append(allocator, key);
    }

    if (orphans.items.len != 0) {
        std.debug.print("\n참조 0인 번역 키 {d}개 — 지우거나, 쓰는 자리를 붙여라:\n", .{orphans.items.len});
        for (orphans.items) |k| std.debug.print("  .{s}\n", .{k});
    }
    try std.testing.expectEqual(@as(usize, 0), orphans.items.len);
}

/// 셀프 테스트용 — 한 소스에서 그 키가 enum 리터럴로 나오는가.
fn referencedIn(allocator: std.mem.Allocator, source: [:0]const u8, key: []const u8) !bool {
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(allocator);
    try collectEnumLiterals(allocator, source, &refs);
    return refs.contains(key);
}

// 스캐너가 **정말로 보고 있는지**를 스캐너 자신으로 확인한다. 위 테스트는 위반이 없을 때 통과하는데,
// 스캐너가 눈이 멀어도 똑같이 통과하기 때문이다(키를 0개 읽거나 참조를 늘 참으로 보면).
test "스캐너는 고아를 실제로 구분한다" {
    const allocator = std.testing.allocator;
    const source =
        \\const Table = struct {
        \\    used_key: [:0]const u8,
        \\    orphan_key: [:0]const u8,
        \\    not_a_key: u32,
        \\};
    ;
    const keys = try tableKeys(allocator, source);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len); // `not_a_key` 는 문자열 필드가 아니다

    const consumer = "pub const x = i18n.t(.used_key); // orphan_key 는 주석에만 있고 .used_key_extra 는 다른 키다";
    try std.testing.expect(try referencedIn(allocator, consumer, "used_key"));
    try std.testing.expect(!try referencedIn(allocator, consumer, "orphan_key"));

    // `.foo` 로 시작하는 더 긴 키가 짧은 키의 참조로 오인되지 않는다.
    try std.testing.expect(!try referencedIn(allocator, "pub const y = i18n.t(.used_key_extra);", "used_key"));
    // 필드 접근(`self.used_key`)은 enum 리터럴 참조가 아니다.
    try std.testing.expect(!try referencedIn(allocator, "pub fn f(self: S) u8 { return self.used_key; }", "used_key"));
    // **struct 초기화의 필드 이름도 참조가 아니다** — 표 사본이 만드는 것이 이 모양이다.
    // 개행이 끼어도 같다(앞 판은 공백·탭만 건너뛰어 이 형태에 뚫렸다).
    try std.testing.expect(!try referencedIn(allocator,
        \\pub const v: S = .{ .used_key = "x" };
        \\pub const w: S = .{
        \\    .used_key
        \\        = "x",
        \\};
    , "used_key"));
    // 문자열 안의 `.key` 도 참조가 아니다.
    try std.testing.expect(!try referencedIn(allocator, "pub const s = \"i18n.t(.used_key)\";", "used_key"));
}

// 표의 **정의**가 참조로 세어지면 모든 키가 자기 선언에 걸려 통과하고, 위 테스트는 아무 말 없이
// 초록이 된다. 파서가 그 둘을 구별하는지 여기서 못 박는다.
test "표의 정의는 참조가 아니고, 같은 파일의 진짜 소비자는 참조다" {
    const allocator = std.testing.allocator;
    const source =
        \\const Table = struct {
        \\    lonely: [:0]const u8,
        \\    spoken: [:0]const u8,
        \\};
        \\const en: Table = .{
        \\    .lonely = "x",
        \\    .spoken = "y",
        \\};
        \\const ko: Table = .{
        \\    .lonely = "x",
        \\    .spoken = "y",
        \\};
        \\pub fn label() [:0]const u8 {
        \\    return t(.spoken);
        \\}
    ;
    try std.testing.expect(try referencedIn(allocator, source, "spoken"));
    try std.testing.expect(!try referencedIn(allocator, source, "lonely"));
}

// 주석 안의 `.key` 를 참조로 세면 이 게이트는 자기 존재 이유로 든 사고 — 자동 치환이 doc comment 에
// `maru.i18n.t(.git_local_check)` 를 글자 그대로 써 넣은 것 — 을 **그 사고가 살아 있는 동안에는 못 잡고**
// 되돌린 뒤에야 잡는다. 순서가 거꾸로다. 파서는 주석을 토큰으로 주지 않으므로 그 구분이 공짜다.
test "주석 속 참조는 안 세고, 줄 끝 주석이 붙은 키도 읽는다" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try referencedIn(allocator,
        \\// 예전에는 .commented 를 여기 적어 두었다
        \\pub const x = 1;
    , "commented"));

    const with_trailing =
        \\const Table = struct {
        \\    plain: [:0]const u8,
        \\    noted: [:0]const u8, // 설명이 붙은 키
        \\};
    ;
    const keys = try tableKeys(allocator, with_trailing);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
}
