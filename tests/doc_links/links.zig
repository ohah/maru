const std = @import("std");

// 이 테스트는 **문서 사이 참조가 실제로 도달하는가**를 막는다. 문서를 여러 파일로 가르는 작업에서
// 조용히 깨지는 두 가지를 잡는다.
//
//   A. 상대 링크의 **대상 파일**이 실재하는가. (`](scroll-view.md)`처럼 파일명이 바뀐 뒤 인덱스가
//      안 따라오면 링크가 죽는다 — AGENTS.md에서 실제로 2건 발견됐다.)
//   B. `#앵커`가 그 문서의 **헤딩에서 실제로 생성되는가**. 이게 A보다 중요하다 — 문서를 가르면
//      파일은 그대로 있고 절만 다른 파일로 옮겨가므로, A만 보는 검사는 통과하는데 링크는 죽는다.
//      실측: 계약 문서 분할에서 이 종류로만 8건이 깨졌고 A는 0건이었다.
//
// **절 번호 참조(`foo.md §4.2`)는 아직 게이트가 아니다.** 같은 분할에서 그 종류도 12건 깨졌지만,
// 판정에 오탐이 많아(같은 줄에서 `§` 뒤에 파일명이 오는 표기, 동명 파일 `docs/x.md`↔`docs/plans/x.md`,
// `**9.5.1 — …**`처럼 헤딩이 아닌 볼드 문단 번호) 좁은 형식을 먼저 정해야 하고, 기존 위반도
// 30건 넘게 남아 있다. 게이트로 올리는 것은 그 정리와 함께 별도 슬라이스로 한다.

/// GitHub이 헤딩에서 앵커를 만드는 규칙. 소문자화 → 영숫자·`-`·`_`·공백·문자(한글 등)만 남김 → 공백을 하이픈으로.
///
/// **공백은 하나씩 하이픈이 된다.** `\s+`로 합치면 `## a (b) + c`의 기호를 지운 자리에 남는 공백 2개가
/// 하이픈 1개가 되어, 실제 앵커 `a-b--c`와 어긋난다(이 규칙을 처음 틀렸을 때 멀쩡한 링크 10건이
/// 깨진 것으로 보고됐다). 그래서 여기서는 공백을 **압축하지 않는다**.
fn slugify(arena: std.mem.Allocator, heading: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, heading.len);

    // 인라인 마크업은 앵커에 남지 않는다: `code`·**bold**·[label](url)의 표시 텍스트만 살린다.
    var cleaned = try std.ArrayList(u8).initCapacity(arena, heading.len);
    var i: usize = 0;
    while (i < heading.len) {
        const c = heading[i];
        if (c == '`' or c == '*' or c == '[' or c == ']') {
            i += 1;
            continue;
        }
        // `](...)`의 URL 부분은 통째로 버린다. `]`는 위에서 이미 소비됐다.
        if (c == '(' and cleaned.items.len > 0 and i > 0 and heading[i - 1] == ']') {
            while (i < heading.len and heading[i] != ')') i += 1;
            if (i < heading.len) i += 1;
            continue;
        }
        try cleaned.append(arena, c);
        i += 1;
    }

    const trimmed = std.mem.trim(u8, cleaned.items, " \t");
    var view = std.unicode.Utf8View.init(trimmed) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ' or cp == '\t') {
            try out.append(arena, '-');
            continue;
        }
        if (cp < 128) {
            const b: u8 = @intCast(cp);
            if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_') {
                try out.append(arena, std.ascii.toLower(b));
            }
            continue;
        }
        // 비-ASCII는 **문자만** 남긴다. 한글·CJK는 앵커에 그대로 들어가지만 `—`·`·`·`→` 같은
        // 기호는 GitHub이 지운다. 문서가 한국어라 이 둘을 가르지 않으면 앵커가 통째로 어긋난다.
        if (isWordCodepoint(cp)) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try out.appendSlice(arena, buf[0..n]);
        }
    }
    return std.mem.trim(u8, out.items, "-");
}

/// 앵커에 남는 비-ASCII 문자인가(한글 자모·완성형, CJK 통합 한자, 일본어 가나).
fn isWordCodepoint(cp: u21) bool {
    return (cp >= 0xAC00 and cp <= 0xD7A3) or // 한글 완성형
        (cp >= 0x1100 and cp <= 0x11FF) or // 한글 자모
        (cp >= 0x3130 and cp <= 0x318F) or // 호환 자모
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK 통합 한자
        (cp >= 0x3040 and cp <= 0x30FF); // 가나
}

/// 아직 고칠 수 없는 기존 위반. **비우는 것이 목표다** — 새 항목을 더할 때는 왜 지금 못 고치는지와
/// 무엇이 해소 조건인지를 함께 적는다.
const known_broken = [_]struct { from: []const u8, target: []const u8, why: []const u8 }{
    .{
        .from = "docs/implementation-plan.md",
        .target = "persistent-session-host.md#c3-3b-event-settlement와-비동기-close-계약",
        // 대상 문서가 활발히 편집 중이고 그 절 제목이 아직 확정되지 않았다(현재 그 이름의 헤딩이 없다).
        // 세션 호스트 작업이 C3-3b 절을 확정할 때 이 링크를 그 제목으로 맞추고 여기서 지운다.
        .why = "persistent-session-host.md의 C3-3b 절 제목 미확정",
    },
};

fn isKnownBroken(from: []const u8, target: []const u8) bool {
    for (known_broken) |k| {
        if (std.mem.eql(u8, k.from, from) and std.mem.eql(u8, k.target, target)) return true;
    }
    return false;
}

/// 한 문서가 소유한 앵커 집합.
fn collectAnchors(arena: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_fence = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue; // 코드블록 안의 `#`은 헤딩이 아니다
        if (line.len == 0 or line[0] != '#') continue;
        var h: usize = 0;
        while (h < line.len and line[h] == '#') h += 1;
        if (h > 6 or h >= line.len or line[h] != ' ') continue;
        const slug = try slugify(arena, line[h + 1 ..]);
        if (slug.len == 0) continue;
        try set.put(slug, {});
    }
    return set;
}

/// 마크다운 링크 대상(`](...)`)을 훑는다. 코드블록 안은 건너뛴다.
const LinkRef = struct { path: []const u8, anchor: []const u8, line: usize };

fn collectLinks(arena: std.mem.Allocator, text: []const u8) ![]LinkRef {
    var refs: std.ArrayList(LinkRef) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var in_fence = false;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, "](")) |open| {
            i = open + 2;
            const close = std.mem.indexOfScalarPos(u8, line, i, ')') orelse break;
            const target = line[i..close];
            i = close + 1;
            if (target.len == 0) continue;
            if (std.mem.startsWith(u8, target, "http://") or
                std.mem.startsWith(u8, target, "https://") or
                std.mem.startsWith(u8, target, "mailto:") or
                target[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, target, ' ') != null) continue; // 링크가 아니라 산문
            const hash = std.mem.indexOfScalar(u8, target, '#');
            const path = if (hash) |h| target[0..h] else target;
            const anchor = if (hash) |h| target[h + 1 ..] else "";
            if (!std.mem.endsWith(u8, path, ".md")) continue; // 이 게이트는 문서 간 참조만 본다
            try refs.append(arena, .{ .path = path, .anchor = anchor, .line = line_no });
        }
    }
    return refs.items;
}

/// 검사 대상 문서: `docs/` 전체 + 루트 인덱스. 명시 목록으로 두면 새 문서를 빠뜨려 게이트가
/// 조용히 통과하므로 디렉터리는 재귀로 훑는다(config-docs 게이트와 같은 규율).
fn collectDocPaths(arena: std.mem.Allocator) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(arena, try arena.dupe(u8, "AGENTS.md"));
    try paths.append(arena, try arena.dupe(u8, "terminal-strategy.md"));

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "docs", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        try paths.append(arena, try std.fmt.allocPrint(arena, "docs/{s}", .{entry.path}));
    }
    return paths.items;
}

/// `from`(저장소 기준 경로)에서 상대 `target`을 푼 저장소 기준 경로.
fn resolveRelative(arena: std.mem.Allocator, from: []const u8, target: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = try std.fs.path.join(arena, &.{ dir, target });
    // `a/../b` 정규화. std.fs.path.resolve는 절대경로를 만들므로 직접 접는다.
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(arena, p);
    }
    return std.mem.join(arena, "/", parts.items);
}

test "문서 링크 정합성: 대상 파일과 절 앵커가 실재한다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const paths = try collectDocPaths(arena);

    // 문서별 본문과 앵커 집합을 미리 만든다(같은 문서를 여러 번 읽지 않는다).
    var anchors = std.StringHashMap(std.StringHashMap(void)).init(arena);
    var texts = std.StringHashMap([]const u8).init(arena);
    const cwd = std.Io.Dir.cwd();
    for (paths) |p| {
        const text = try cwd.readFileAlloc(std.testing.io, p, arena, .limited(8 * 1024 * 1024));
        try texts.put(p, text);
        try anchors.put(p, try collectAnchors(arena, text));
    }

    var violations: usize = 0;
    for (paths) |from| {
        const refs = try collectLinks(arena, texts.get(from).?);
        for (refs) |ref| {
            const resolved = try resolveRelative(arena, from, ref.path);
            const target_anchors = anchors.get(resolved) orelse {
                // 대상이 검사 범위 밖(예: 저장소 밖 경로)이면 파일 존재만 본다.
                cwd.access(std.testing.io, resolved, .{}) catch {
                    std.debug.print(
                        "{s}:{d}: 링크 대상 파일이 없다 — {s}\n",
                        .{ from, ref.line, ref.path },
                    );
                    violations += 1;
                };
                continue;
            };
            if (ref.anchor.len == 0) continue;
            if (target_anchors.contains(ref.anchor)) continue;
            if (isKnownBroken(from, try std.fmt.allocPrint(arena, "{s}#{s}", .{ ref.path, ref.anchor }))) continue;
            std.debug.print(
                "{s}:{d}: 절 앵커가 대상 문서에 없다 — {s}#{s}\n",
                .{ from, ref.line, ref.path, ref.anchor },
            );
            violations += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

// 판정 함수 자체의 단위 테스트 — slug 규칙이 조용히 느슨해지면 게이트가 통과만 하는 껍데기가 된다.
test "slug 규칙: 실제 헤딩으로 경계를 고정" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 기본: 소문자화 + 공백→하이픈.
    try std.testing.expectEqualStrings("1-확정-결정", try slugify(arena, "1. 확정 결정"));

    // 기호를 지운 자리의 공백은 **압축하지 않는다** — 하이픈이 둘 남는다.
    try std.testing.expectEqualStrings(
        "connectionincident-진단-artifact",
        try slugify(arena, "ConnectionIncident 진단 artifact"),
    );
    try std.testing.expectEqualStrings("plugin--wasm", try slugify(arena, "Plugin / Wasm"));
    try std.testing.expectEqualStrings(
        "51-도크트리-포맷-현행--레거시-읽기-경로",
        try slugify(arena, "5.1 도크·트리 포맷 (현행) + 레거시 읽기 경로"),
    );

    // 인라인 마크업은 표시 텍스트만 남는다.
    try std.testing.expectEqualStrings("browser--wkwebview-제어", try slugify(arena, "`browser.*` — WKWebView 제어"));

    // 비-ASCII 기호(`—`·`·`)는 지우고 한글은 남긴다.
    try std.testing.expectEqualStrings("탭split레이아웃", try slugify(arena, "탭·split·레이아웃"));
}

test "링크 수집: 코드블록과 외부 URL은 대상이 아니다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refs = try collectLinks(arena,
        \\[문서](a.md#절-하나)와 [외부](https://example.com/b.md)
        \\```
        \\[코드 안](never.md)
        \\```
        \\[상대](../c.md)
    );
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("a.md", refs[0].path);
    try std.testing.expectEqualStrings("절-하나", refs[0].anchor);
    try std.testing.expectEqualStrings("../c.md", refs[1].path);
}

test "상대 경로 해석: plans/ 하위에서 ../ 가 docs/ 로 올라간다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "docs/native-editor.md",
        try resolveRelative(arena, "docs/plans/native-editor.md", "../native-editor.md"),
    );
    try std.testing.expectEqualStrings(
        "docs/plans/scroll-area.md",
        try resolveRelative(arena, "docs/implementation-plan.md", "plans/scroll-area.md"),
    );
    try std.testing.expectEqualStrings(
        "docs/file-panel.md",
        try resolveRelative(arena, "AGENTS.md", "docs/file-panel.md"),
    );
}
