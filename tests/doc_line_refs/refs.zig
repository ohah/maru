const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

// 이 테스트는 문서가 코드를 **좌표로** 지목한 자리(`` `심볼`(파일.zig:1234) ``)가 아직 그 심볼을
// 가리키는지 본다. `check-doc-links`가 문서 **사이**의 참조를 지키는 것과 짝이고, 이쪽은 문서에서
// **코드로** 나가는 참조를 지킨다.
//
// **왜 필요한가.** 좌표는 사람이 손으로 관리하는데 코드는 계속 자란다. 2026-08-29 전수 대조에서
// 41건이 어긋나 있었고, 가장 크게 벌어진 `termRect`는 문서가 app_session.zig:2335라 했지만 실제
// 정의는 6246행이었다(3,911줄 차이). 원인의 대부분은 `app_session.zig` 분해였다 — 함수가
// `app_session/*.zig`로 옮겨졌는데 좌표는 옛 파일·옛 줄에 남았다. **그리고 그 41건을 고친 그날
// `termRect`가 다시 49줄 밀렸다**(다른 PR이 같은 파일을 늘렸다). 사람이 따라갈 수 있는 종류가
// 아니다.
//
// **오탐이 이 게이트의 본체다.** 넓게 잡으면 이 저장소에서는 곧바로 1,500건이 나오는데 대부분
// 거짓이다 — 문서가 "옛 `X`가 들고 있던"처럼 **사라진 것을 일부러 적고**, `UIAccessibilityElement`
// 같은 외부 API를 인용하고, 비교 대상인 Ghostty의 파일 경로를 적기 때문이다. 그래서 이 게이트는
// **판정할 수 있는 것만 판정한다**:
//
//   ⑴ 백틱 심볼과 좌표가 **같은 문장 안에서 붙어 있어야** 한다(사이 40바이트 이내).
//   ⑵ 파일명이 저장소에서 **유일하게** 풀려야 한다. 같은 basename이 여럿이면 어느 것을 뜻하는지
//      문서만으로 알 수 없다.
//   ⑶ 그 파일에서 심볼의 **정의가 정확히 하나** 발견돼야 한다. 0개면 이름이 바뀌었거나 외부
//      심볼이고, 2개 이상이면 어느 것을 가리키는지 모호하다. 둘 다 이 게이트가 답할 수 없다.
//
// 셋을 모두 통과한 인용만 좌표를 검사한다. 판정 못 할 것을 조용히 지나가는 것은 links.zig가
// "번호 절 체계가 없는 문서로의 §N은 판정하지 않는다"로 세운 규율과 같다 — 오탐을 내느니 침묵한다.
//
// **허용 오차 ±25줄.** 좌표는 대개 정의 줄을 짚지만 그 근처(문서주석 첫 줄, 구조체 필드가 있는
// 본문 등)를 짚기도 한다. 이 저장소의 함수는 문서주석이 길어 정의와 그 주석 머리가 20줄 넘게
// 떨어지는 일이 흔하다. 좁히면 멀쩡한 인용이 잡히고, 넓히면 진짜 밀림을 놓친다 — 실측한 41건은
// 최소 40줄에서 3,911줄까지 벌어져 있었으므로 이 폭에서 하나도 새지 않는다.

const tolerance = 25;

/// 문서 하나에서 뽑은 인용 하나.
const Citation = struct {
    doc: []const u8,
    doc_line: usize,
    symbol: []const u8,
    file_ref: []const u8,
    cited_line: usize,
};

test "문서가 좌표로 지목한 심볼이 아직 그 자리에 있다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const docs = try collectDocPaths(arena);
    const index = try buildCodeIndex(arena);

    var violations: usize = 0;
    var judged: usize = 0;
    for (docs) |doc| {
        const text = try readFile(arena, doc);
        var cites: std.ArrayList(Citation) = .empty;
        try collectCitations(arena, doc, text, &cites);
        for (cites.items) |c| {
            const path = resolveCodePath(index, c.file_ref) orelse continue; // ⑵
            const src = readFile(arena, path) catch continue;
            const def = soleDefinitionLine(src, c.symbol) orelse continue; // ⑶
            judged += 1;
            const delta = if (def > c.cited_line) def - c.cited_line else c.cited_line - def;
            if (delta <= tolerance) continue;
            std.debug.print(
                "{s}:{d}: `{s}`({s}:{d}) — 그 심볼의 정의는 {s}:{d} 이다({d}줄 차이)\n",
                .{ c.doc, c.doc_line, c.symbol, c.file_ref, c.cited_line, path, def, delta },
            );
            violations += 1;
        }
    }
    if (violations > 0) {
        std.debug.print(
            "\n좌표를 실제 정의 줄로 고치거나, 심볼이 옮겨 다니는 자리면 `(파일.zig:줄)`에서 줄을 떼고\n" ++
                "파일과 심볼 이름만 남긴다 — 그러면 grep 한 번이고 다시 썩지 않는다.\n",
            .{},
        );
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
    // **대조군**: 위 단언이 공허하지 않은지 본다. 세 관문을 좁히다 보면 판정이 0건이 되는데도
    // 초록이 되는 상태에 닿기 쉽다(실제로 유일성 조건을 처음 넣었을 때 후보가 확 줄었다).
    //
    // **실측 8건이므로 8로 못 박는다**(build.zig의 `--maru-expect-tests`와 같은 규율). 하한을 넉넉히
    // 낮춰 두면 인용이 조용히 사라져도 초록이라, 게이트가 지키는 범위가 줄어든 것을 아무도 모른다.
    // 숫자가 틀렸다고 나오면 먼저 **어느 인용이 사라졌는지** 확인하고, 정당한 증감일 때만 갱신한다.
    //
    // 8건은 문서가 가진 좌표 전부가 아니다 — 세 관문을 통과한 것만이다(문서가 심볼 없이 좌표만 적거나
    // 심볼의 정의가 여럿이면 판정하지 않는다). 관문을 넓히는 것은 후속이며, 넓힐 때마다 오탐이 0인지를
    // 먼저 확인한다.
    try std.testing.expectEqual(@as(usize, 8), judged);
}

test "대조군: 심어 둔 밀림을 실제로 잡는다" {
    // 판정 로직 자체를 본다. 위 테스트는 저장소가 깨끗하면 늘 초록이라, 검사기가 통째로 망가져도
    // 그 사실을 알려 주지 못한다.
    const src =
        \\const a = 1;
        \\
        \\pub fn termRect(self: *const AppSession) SplitRect {
        \\    return self.rect;
        \\}
        \\
    ;
    const def = soleDefinitionLine(src, "termRect").?;
    try std.testing.expectEqual(@as(usize, 3), def);
    // 인용이 그 자리를 짚으면 통과, 멀리 떨어지면 위반이다.
    try std.testing.expect(def + tolerance >= 20 and 20 - def <= tolerance);
    try std.testing.expect(2335 - def > tolerance);
}

test "판정 못 할 것은 판정하지 않는다" {
    // 정의가 없으면(이름이 바뀌었거나 외부 심볼) null.
    try std.testing.expect(soleDefinitionLine("const a = 1;\n", "UIAccessibilityElement") == null);
    // 정의가 둘이면 어느 것을 가리키는지 모르므로 null.
    const twice =
        \\pub fn attach(a: u8) void {}
        \\pub fn attach(b: u16) void {}
        \\
    ;
    try std.testing.expect(soleDefinitionLine(twice, "attach") == null);
    // 하나면 그 줄.
    try std.testing.expectEqual(@as(?usize, 1), soleDefinitionLine("pub fn attach(a: u8) void {}\n", "attach"));
}

test "인용 수집: 심볼과 좌표가 붙어 있는 것만 본다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cites: std.ArrayList(Citation) = .empty;
    try collectCitations(arena, "d.md", "`termRect`(app_session.zig:2335)는 …\n", &cites);
    try std.testing.expectEqual(@as(usize, 1), cites.items.len);
    try std.testing.expectEqualStrings("termRect", cites.items[0].symbol);
    try std.testing.expectEqualStrings("app_session.zig", cites.items[0].file_ref);
    try std.testing.expectEqual(@as(usize, 2335), cites.items[0].cited_line);

    // 사이가 멀면 그 좌표는 그 심볼의 것이 아니다.
    cites.clearRetainingCapacity();
    const far = "`termRect`는 폭 inset 선례가 있고 파생 호출처가 자동 추종한다. 자세한 것은 web.zig:206 을 본다.\n";
    try collectCitations(arena, "d.md", far, &cites);
    try std.testing.expectEqual(@as(usize, 0), cites.items.len);

    // 좌표가 없으면 수집하지 않는다.
    cites.clearRetainingCapacity();
    try collectCitations(arena, "d.md", "`termRect`(app_session.zig)는 …\n", &cites);
    try std.testing.expectEqual(@as(usize, 0), cites.items.len);

    // 줄 번호는 문서 안의 위치를 정확히 센다.
    cites.clearRetainingCapacity();
    try collectCitations(arena, "d.md", "첫 줄\n둘째 줄\n`foo`(a.zig:10)\n", &cites);
    try std.testing.expectEqual(@as(usize, 3), cites.items[0].doc_line);
}

// ── 수집 ──────────────────────────────────────────────────────────────────────

/// `` `심볼` `` 뒤 40바이트 안에 `파일.zig:1234`가 오는 자리만 인용으로 본다.
fn collectCitations(
    arena: std.mem.Allocator,
    doc: []const u8,
    text: []const u8,
    out: *std.ArrayList(Citation),
) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '`') continue;
        const sym_start = i + 1;
        const sym_end = std.mem.indexOfScalarPos(u8, text, sym_start, '`') orelse break;
        i = sym_end;
        const raw = text[sym_start..sym_end];
        if (raw.len < 3 or raw.len > 64) continue;
        if (std.mem.indexOfAny(u8, raw, " \t\n(){}[]<>,;\"'") != null) continue;
        // `web_panel_layout.PanelKind`처럼 한정된 이름은 마지막 조각이 정의 이름이다.
        const symbol = if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| raw[dot + 1 ..] else raw;
        if (symbol.len < 3) continue;
        if (!isIdentifier(symbol)) continue;

        const window_end = @min(text.len, sym_end + 1 + 40);
        const window = text[sym_end + 1 .. window_end];
        const found = findFileLine(window) orelse continue;
        try out.append(arena, .{
            .doc = doc,
            .doc_line = std.mem.count(u8, text[0..sym_start], "\n") + 1,
            .symbol = symbol,
            .file_ref = found.file,
            .cited_line = found.line,
        });
    }
}

const FileLine = struct { file: []const u8, line: usize };

/// 창 안에서 첫 `…파일.zig:1234` / `…파일.swift:1234`를 찾는다. 확장자 앞의 경로 조각은 그대로 둔다
/// (`app_session/tab.zig:1323`처럼 디렉터리까지 적는 인용이 많다).
fn findFileLine(window: []const u8) ?FileLine {
    const exts = [_][]const u8{ ".zig:", ".swift:" };
    var best: ?FileLine = null;
    for (exts) |ext| {
        const at = std.mem.indexOf(u8, window, ext) orelse continue;
        // 파일 이름의 시작으로 되짚는다.
        var s = at;
        while (s > 0) : (s -= 1) {
            const c = window[s - 1];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-') continue;
            break;
        }
        const name_end = at + ext.len - 1; // ':' 앞까지가 파일 이름
        if (name_end <= s) continue;
        var p = at + ext.len;
        var num: usize = 0;
        var digits: usize = 0;
        while (p < window.len and std.ascii.isDigit(window[p])) : (p += 1) {
            num = num * 10 + (window[p] - '0');
            digits += 1;
        }
        if (digits == 0 or digits > 7) continue;
        const cand: FileLine = .{ .file = window[s..name_end], .line = num };
        if (best == null or s < std.mem.indexOf(u8, window, best.?.file).?) best = cand;
    }
    return best;
}

fn isIdentifier(s: []const u8) bool {
    for (s, 0..) |c, k| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        _ = k;
        return false;
    }
    return !std.ascii.isDigit(s[0]);
}

// ── 코드 인덱스 ───────────────────────────────────────────────────────────────

const CodeIndex = struct {
    /// basename → 저장소 기준 경로. 같은 basename이 여럿이면 빈 슬라이스를 넣어 **모호**로 표시한다.
    by_base: std.StringHashMapUnmanaged([]const u8),
    /// `app_session/tab.zig`처럼 꼬리 경로로 적은 인용을 풀기 위한 전체 목록.
    all: [][]const u8,
};

fn buildCodeIndex(arena: std.mem.Allocator) !CodeIndex {
    var by_base: std.StringHashMapUnmanaged([]const u8) = .empty;
    var all: std.ArrayList([]const u8) = .empty;

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, arena);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        const is_code = std.mem.endsWith(u8, entry.path, ".zig") or std.mem.endsWith(u8, entry.path, ".swift");
        if (!is_code) continue;
        const path = try std.fmt.allocPrint(arena, "src/{s}", .{entry.path});
        try all.append(arena, path);
        const base = std.fs.path.basename(path);
        const gop = try by_base.getOrPut(arena, base);
        if (gop.found_existing) {
            gop.value_ptr.* = ""; // 모호 — 이 basename으로는 판정하지 않는다
        } else {
            gop.value_ptr.* = path;
        }
    }
    return .{ .by_base = by_base, .all = all.items };
}

/// 인용이 적은 파일 표기를 저장소 경로로 푼다. 유일하게 풀리지 않으면 `null`.
fn resolveCodePath(index: CodeIndex, ref: []const u8) ?[]const u8 {
    // 꼬리 경로 매칭이 우선이다 — `app_session/tab.zig`는 basename이 모호해도 유일하게 풀린다.
    if (std.mem.indexOfScalar(u8, ref, '/') != null) {
        var hit: ?[]const u8 = null;
        for (index.all) |p| {
            if (!std.mem.endsWith(u8, p, ref)) continue;
            if (p.len > ref.len and p[p.len - ref.len - 1] != '/') continue;
            if (hit != null) return null; // 둘 이상 — 모호
            hit = p;
        }
        return hit;
    }
    const found = index.by_base.get(std.fs.path.basename(ref)) orelse return null;
    return if (found.len == 0) null else found;
}

// ── 정의 찾기 ─────────────────────────────────────────────────────────────────

/// `src` 안에서 `sym`을 **정의하는** 줄이 정확히 하나면 그 줄 번호(1-based), 아니면 `null`.
fn soleDefinitionLine(src: []const u8, sym: []const u8) ?usize {
    var found: ?usize = null;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, sym) == null) continue;
        if (!definesSymbol(line, sym)) continue;
        if (found != null) return null; // 둘 이상 — 어느 것을 가리키는지 모른다
        found = line_no;
    }
    return found;
}

/// 이 줄이 `sym`을 정의하는가. Zig의 `fn`·`const`·`var`·구조체 필드와 Swift의 `func`·`class`를 본다.
fn definesSymbol(line: []const u8, sym: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "//")) return false; // 주석 안의 서술은 정의가 아니다
    if (keywordThen(t, "fn ", sym, "(")) return true;
    if (keywordThen(t, "pub fn ", sym, "(")) return true;
    if (keywordThen(t, "func ", sym, "(")) return true;
    if (keywordThen(t, "class ", sym, " ")) return true;
    for ([_][]const u8{ "const ", "var ", "pub const ", "pub var " }) |kw| {
        if (keywordThen(t, kw, sym, "=") or keywordThen(t, kw, sym, ":")) return true;
    }
    // 구조체 필드: 줄 머리가 곧 이름이고 뒤에 `:`가 온다.
    if (std.mem.startsWith(u8, t, sym)) {
        const rest = std.mem.trimStart(u8, t[sym.len..], " ");
        if (rest.len > 1 and rest[0] == ':' and rest[1] != ':') return true;
    }
    return false;
}

/// `t`가 `kw`로 시작하고 그 뒤 이름이 정확히 `sym`이며 이어서 `after`가 오는가.
fn keywordThen(t: []const u8, kw: []const u8, sym: []const u8, after: []const u8) bool {
    if (!std.mem.startsWith(u8, t, kw)) return false;
    const rest = std.mem.trimStart(u8, t[kw.len..], " ");
    if (!std.mem.startsWith(u8, rest, sym)) return false;
    const tail = std.mem.trimStart(u8, rest[sym.len..], " ");
    return std.mem.startsWith(u8, tail, after);
}

// ── 입력 ──────────────────────────────────────────────────────────────────────

fn readFile(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(64 << 20));
}

/// 검사 대상 문서: `docs/` 전체 + 루트 인덱스. 명시 목록으로 두면 새 문서를 빠뜨려 게이트가
/// 조용히 통과하므로 디렉터리는 재귀로 훑는다(doc-links 게이트와 같은 규율).
fn collectDocPaths(arena: std.mem.Allocator) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(arena, try arena.dupe(u8, "AGENTS.md"));
    try paths.append(arena, try arena.dupe(u8, "terminal-strategy.md"));

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "docs", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, arena);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        try paths.append(arena, try std.fmt.allocPrint(arena, "docs/{s}", .{entry.path}));
    }
    return paths.items;
}
