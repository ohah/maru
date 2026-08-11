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
//   C. `foo.md §4.2`처럼 **절 번호로 가리킨 참조**가 그 문서에 실재하는가. 같은 분할에서 이 종류도
//      12건 깨졌다 — 절이 다른 파일로 가면 번호만 쓴 참조는 어느 문서를 뜻하는지조차 흐려진다.
//
// C의 판정 형식을 좁히는 데 대부분의 노력이 들었다. 처음 넓게 잡았을 때 21건 중 19건이 오탐이었고,
// 원인은 전부 "절을 다는 형식이 문서마다 다르다"였다. 지금은 셋을 모두 절 정의로 인정하고
// (`## 3.` 헤딩, `**9.5.1 — …**` 볼드 문단, `7. **(§9.7) …**` 목록 라벨), 참조 쪽은 파일명 **바로 뒤**에
// 붙은 §만 본다. 사이에 문장이 끼면 "그 문서가 소유하고, 그 안의 §N은…" 같은 진입점 참조라 대상이 다르다.
//
// **번호 절 체계가 없는 문서로의 `§N`은 판정하지 않는다.** architecture.md·project-rules.md처럼 제목만
// 쓰는 문서를 `§211`로 가리키는 곳이 있는데, 실측하면 그건 절이 아니라 **줄 번호를 §로 쓴 표기 오용**이다
// (`architecture.md §192`가 실제 192행과 일치했다). 이 게이트가 다룰 종류가 아니라 조용히 지나간다.

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

/// 절 번호 참조 쪽의 같은 목록. 여기도 **비우는 것이 목표다**.
const known_broken_sections = [_]struct { from: []const u8, doc: []const u8, sec: []const u8, why: []const u8 }{
    .{
        .from = "src/session/dock_panel.zig",
        .doc = "docs/editor-surface.md",
        .sec = "10.10",
        // editor-surface.md가 개정되며 §10이 `10.A 결정됨`/`10.B 남음`으로 바뀌어 이 번호가 사라졌다.
        // 내용("diff 본문의 비교 기준")은 지금 §3.5 섹션 모델과 §6 bounded diff API에 걸쳐 있어 어느
        // 한 절로 단정할 수 없다. 그 문서를 아는 사람이 대상을 정하면 여기서 지운다.
        .why = "editor-surface.md 개정으로 사라진 번호 — 대체 절 미정",
    },
    .{
        .from = "tests/macos_editor_smoke.swift",
        .doc = "docs/editor-surface.md",
        .sec = "10.6",
        // 같은 개정으로 사라졌다. 내용은 "큰 응답 파싱 비용의 상한 근거"다.
        .why = "editor-surface.md 개정으로 사라진 번호 — 대체 절 미정",
    },
};

fn isKnownBrokenSection(from: []const u8, doc: []const u8, sec: []const u8) bool {
    for (known_broken_sections) |k| {
        if (std.mem.eql(u8, k.from, from) and std.mem.eql(u8, k.doc, doc) and std.mem.eql(u8, k.sec, sec)) return true;
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

/// 줄이 절을 **정의**하면 그 번호. 문서마다 절을 다는 형식이 셋이라 모두 인정한다 —
/// 하나라도 빠뜨리면 멀쩡한 참조가 위반으로 잡힌다(실측: 헤딩만 보면 오탐 17건).
///
///   `## 3. 문서 모델 계약`            헤딩
///   `**9.5.1 — 연결 I/O 모델**`        볼드 문단(헤딩을 더 쪼개지 않고 번호만 다는 문서)
///   `7. **(§9.7) 아이콘은 …**`         번호 목록 안의 절 라벨
fn sectionDefinedBy(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "#")) {
        var h: usize = 0;
        while (h < t.len and t[h] == '#') h += 1;
        if (h < 2 or h > 6 or h >= t.len or t[h] != ' ') return null;
        return leadingNumber(std.mem.trimStart(u8, t[h..], " "), &.{ '.', ' ' });
    }
    if (std.mem.startsWith(u8, t, "**")) {
        return leadingNumber(t[2..], &.{ ' ', '-', 0xE2 }); // 0xE2 = '—'/'–'의 첫 바이트
    }
    // `7. **(§9.7) …`  — 목록 번호를 건너뛰고 괄호 안 절 라벨을 읽는다.
    const paren = std.mem.indexOf(u8, t, "(§") orelse return null;
    if (leadingNumber(t, &.{'.'}) == null) return null; // 목록 항목이 아니면 본문 속 참조다
    if (paren > 8) return null; // 줄 머리 근처의 라벨만
    return leadingNumber(t[paren + 3 ..], &.{')'}); // "(§" 2바이트 + '§'가 2바이트 더
}

/// `text` 앞머리의 `1`·`2.3`·`9.5.1` 형태 번호. 뒤에 `stops` 중 하나가 와야 한다.
fn leadingNumber(text: []const u8, stops: []const u8) ?[]const u8 {
    var i: usize = 0;
    var seen_digit = false;
    while (i < text.len) : (i += 1) {
        if (std.ascii.isDigit(text[i])) {
            seen_digit = true;
            continue;
        }
        if (text[i] == '.' and seen_digit and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) continue;
        break;
    }
    if (!seen_digit or i == 0) return null;
    const num = std.mem.trimEnd(u8, text[0..i], ".");
    if (num.len == 0) return null;
    if (i >= text.len) return num; // 줄 끝
    for (stops) |s| if (text[i] == s) return num;
    return null;
}

/// 문서가 소유한 절 번호. `3.2`를 정의하면 부모 `3`도 참조를 받는다.
fn collectSections(arena: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_fence = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        const num = sectionDefinedBy(line) orelse continue;
        try set.put(try arena.dupe(u8, num), {});
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, num, i, '.')) |dot| {
            try set.put(try arena.dupe(u8, num[0..dot]), {});
            i = dot + 1;
        }
    }
    return set;
}

/// 절 번호 참조(`foo.md §4.2`). 파일명 **바로 뒤**에 붙은 것만 본다.
const SectionRef = struct { path: []const u8, sec: []const u8, line: usize };

/// 파일명과 § 사이에 허용하는 것: 링크 닫기 `)`, 백틱, 공백, 중점(`·`). 그 이상 끼면
/// "이 문서가 소유하고, 그 안의 §N은…" 같은 **진입점 참조**라 대상이 다르다(실측 오탐의 절반).
///
/// **절이 이어지면 전부 모은다.** `foo.md §2·§6·§10`은 셋 다 같은 문서를 가리키므로, 첫 절만 보면
/// 뒤쪽이 조용히 어긋난다 — 웹 패널 분할에서 실제로 `§2`가 유효해 통과한 자리에 `§10`이 죽어 있었다.
/// 구분자(`·`·`,`) 없이 다른 토큰이 오면 거기서 멈춘다(`§10 4e-3.`의 `4e-3`을 절로 오인하지 않게).
fn collectChainedSections(arena: std.mem.Allocator, line: []const u8, md_end: usize, out: *std.ArrayList([]const u8)) !void {
    const stops = [_]u8{ ' ', ')', ',', '.', '·', 0xEA, 0xC2, 0xEB, 0xEC, 0xED };

    // ① 파일명 뒤에서 첫 `§`를 찾는다.
    var i = md_end;
    var gap: usize = 0;
    var found = false;
    while (i < line.len and gap < 4) {
        const c = line[i];
        if (c == ')' or c == '`') {
            i += 1;
            continue; // 구분자는 간격으로 세지 않는다
        }
        if (c == ' ') {
            i += 1;
            gap += 1;
            continue;
        }
        if (c == 0xC2 and i + 1 < line.len and line[i + 1] == 0xB7) { // '·'
            i += 2;
            gap += 1;
            continue;
        }
        if (c == 0xC2 and i + 1 < line.len and line[i + 1] == 0xA7) { // '§'
            i += 2;
            found = true;
            break;
        }
        return;
    }
    if (!found) return;

    // ② `§N` 하나를 읽고, 뒤에 `·§`/`,§`가 이어지는 동안 반복한다.
    while (true) {
        const num = leadingNumber(line[i..], &stops) orelse return;
        try out.append(arena, num);
        i += num.len;

        var j = i;
        var saw_sep = false;
        while (j < line.len) {
            if (line[j] == ' ') {
                j += 1;
                continue;
            }
            if (line[j] == ',') {
                saw_sep = true;
                j += 1;
                continue;
            }
            if (line[j] == 0xC2 and j + 1 < line.len and line[j + 1] == 0xB7) { // '·'
                saw_sep = true;
                j += 2;
                continue;
            }
            break;
        }
        if (!saw_sep) return;
        if (j + 1 < line.len and line[j] == 0xC2 and line[j + 1] == 0xA7) { // '§'
            i = j + 2;
            continue;
        }
        return;
    }
}

fn collectSectionRefs(arena: std.mem.Allocator, text: []const u8) ![]SectionRef {
    var refs: std.ArrayList(SectionRef) = .empty;
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
        // 절 소유 표와 그 설명문은 `§N 다음에 파일명`이라 짝이 반대다 — 판정 대상이 아니다.
        if (std.mem.indexOf(u8, line, "절 번호는 파일을 넘어 이어진다") != null) continue;
        if (std.mem.indexOf(u8, line, "처럼 절 번호로 가리키므로") != null) continue;

        var i: usize = 0;
        while (std.mem.indexOfPos(u8, line, i, ".md")) |md| {
            const end = md + 3;
            i = end;
            var secs: std.ArrayList([]const u8) = .empty;
            try collectChainedSections(arena, line, end, &secs);
            if (secs.items.len == 0) continue;
            // 파일명 앞으로 되짚어 경로를 뽑는다(`[라벨](docs/a.md)` 의 경로 부분, 또는 평문 `docs/a.md`).
            var s = md;
            while (s > 0) {
                const c = line[s - 1];
                const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '/' or c == '-' or c == '_';
                if (!ok) break;
                s -= 1;
            }
            if (s == md) continue;
            for (secs.items) |sec| {
                try refs.append(arena, .{ .path = line[s..end], .sec = sec, .line = line_no });
            }
        }
    }
    return refs.items;
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

/// 절 참조를 쓰는 쪽: 문서뿐 아니라 소스 주석도 `docs/foo.md §4.2`로 계약을 가리킨다.
fn collectRefSourcePaths(arena: std.mem.Allocator) ![][]const u8 {
    var paths = try std.ArrayList([]const u8).initCapacity(arena, 64);
    for (try collectDocPaths(arena)) |p| try paths.append(arena, p);
    try paths.append(arena, try arena.dupe(u8, "build.zig"));

    for ([_][]const u8{ "src", "tests", "tools" }) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            const ok = std.mem.endsWith(u8, entry.path, ".zig") or
                std.mem.endsWith(u8, entry.path, ".m") or
                std.mem.endsWith(u8, entry.path, ".swift");
            if (!ok) continue;
            try paths.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, entry.path }));
        }
    }
    return paths.items;
}

test "절 번호 참조: 파일명 뒤의 §N이 그 문서에 실재한다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.Io.Dir.cwd();

    // 문서별 절 번호 집합. **비어 있으면 그 문서는 번호 절 체계를 안 쓴다** — architecture.md·
    // project-rules.md처럼 제목만 있는 문서로의 `§N`은 절 참조가 아니라 표기 오용(줄 번호를 §로
    // 쓴 것이 실제로 있다)이라, 이 게이트가 다룰 종류가 아니므로 판정하지 않는다.
    var sections = std.StringHashMap(std.StringHashMap(void)).init(arena);
    for (try collectDocPaths(arena)) |p| {
        const text = try cwd.readFileAlloc(std.testing.io, p, arena, .limited(8 * 1024 * 1024));
        try sections.put(p, try collectSections(arena, text));
    }

    var violations: usize = 0;
    for (try collectRefSourcePaths(arena)) |from| {
        const text = cwd.readFileAlloc(std.testing.io, from, arena, .limited(8 * 1024 * 1024)) catch continue;
        for (try collectSectionRefs(arena, text)) |ref| {
            // 문서끼리는 상대 경로지만 **소스 주석은 저장소 루트 기준**(`docs/plans/foo.md`)을 쓴다.
            // 셋을 순서대로 시도하고, 실제로 맞은 경로를 이후 판정(등재 조회)에 그대로 쓴다.
            // basename 폴백을 먼저 두면 `docs/plans/x.md`가 동명인 `docs/x.md`로 잘못 풀린다(실측).
            var doc = try resolveRelative(arena, from, ref.path);
            var owned = sections.get(doc);
            if (owned == null and sections.get(ref.path) != null) {
                doc = ref.path; // 루트 기준 경로를 그대로 쓴 참조
                owned = sections.get(doc);
            }
            if (owned == null) {
                doc = try std.fmt.allocPrint(arena, "docs/{s}", .{std.fs.path.basename(ref.path)});
                owned = sections.get(doc);
            }
            const secs = owned orelse continue;
            if (secs.count() == 0) continue; // 번호 절 체계가 없는 문서
            if (secs.contains(ref.sec)) continue;
            if (isKnownBrokenSection(from, doc, ref.sec)) continue;
            std.debug.print(
                "{s}:{d}: 절이 그 문서에 없다 — {s} §{s}\n",
                .{ from, ref.line, ref.path, ref.sec },
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

test "절 정의 형식: 헤딩·볼드 문단·목록 라벨을 모두 인정한다" {
    try std.testing.expectEqualStrings("3", sectionDefinedBy("## 3. 문서 모델 계약").?);
    try std.testing.expectEqualStrings("9.5.1", sectionDefinedBy("**9.5.1 — 연결 I/O 모델**").?);
    try std.testing.expectEqualStrings("9.7", sectionDefinedBy("7. **(§9.7) 아이콘은 이름이 단일 출처**").?);
    try std.testing.expectEqualStrings("2.1", sectionDefinedBy("### 2.1 웹 스택").?);

    // 본문 속 참조는 절 **정의**가 아니다. (예시에 실재 문서명을 쓰지 않는다 — 아래 절 참조 게이트가
    // 이 파일도 훑으므로, 실재 문서를 쓰면 단위 테스트 입력이 진짜 참조로 잡힌다.)
    try std.testing.expect(sectionDefinedBy("계약은 example-doc.md §7이 소유한다") == null);
    try std.testing.expect(sectionDefinedBy("# 문서 제목") == null); // h1은 절 번호 체계가 아니다
    try std.testing.expect(sectionDefinedBy("- 일반 목록 항목") == null);

    // 부모 절 파생: `3.2`를 정의하면 `3`도 참조를 받는다.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var secs = try collectSections(arena_state.allocator(), "### 9.5.1 연결\n## 4. transport\n");
    try std.testing.expect(secs.contains("9.5.1"));
    try std.testing.expect(secs.contains("9.5"));
    try std.testing.expect(secs.contains("9"));
    try std.testing.expect(secs.contains("4"));
}

test "절 참조 수집: 파일명 바로 뒤만 보고 진입점 참조는 거른다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const refs = try collectSectionRefs(arena,
        \\계약은 [문서](docs/a.md) §4.2가 소유한다.
        \\`docs/b.md` §3 도 같은 형식이다.
        \\평문 docs/c.md §2.1 도 본다.
        \\[진입점](docs/d.md)이 단일 출처이며, 그 문서 §7이 적는다.
        \\> **절 번호는 파일을 넘어 이어진다.** §2 [레이어](docs/e.md) · §3 [모델](docs/f.md)
    );
    try std.testing.expectEqual(@as(usize, 3), refs.len);
    try std.testing.expectEqualStrings("4.2", refs[0].sec);
    try std.testing.expectEqualStrings("3", refs[1].sec);
    try std.testing.expectEqualStrings("2.1", refs[2].sec);
}

test "절 참조 수집: 이어지는 절을 모두 모으고 구분자가 끊기면 멈춘다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `·`로 이어지면 셋 다 같은 문서를 가리킨다.
    const chain = try collectSectionRefs(arena, "모델은 docs/a.md §2·§6·§10 4e-3이 정한다.");
    try std.testing.expectEqual(@as(usize, 3), chain.len);
    try std.testing.expectEqualStrings("2", chain[0].sec);
    try std.testing.expectEqualStrings("6", chain[1].sec);
    try std.testing.expectEqualStrings("10", chain[2].sec);

    // **`§10` 뒤의 `4e-3`은 절이 아니다** — 구분자 없이 다른 토큰이 오면 거기서 끝난다.
    // 이 경계가 없으면 본문 숫자를 절로 오인해 오탐이 쏟아진다.
    for (chain) |r| try std.testing.expect(!std.mem.eql(u8, r.sec, "3"));

    // 쉼표와 소수점 절 번호도 같은 규칙.
    const commas = try collectSectionRefs(arena, "`docs/b.md` §13.3, §13.6.1, §13.8 참고.");
    try std.testing.expectEqual(@as(usize, 3), commas.len);
    try std.testing.expectEqualStrings("13.6.1", commas[1].sec);

    // 단일 절은 그대로 하나.
    const one = try collectSectionRefs(arena, "[문서](docs/c.md) §4.2가 소유한다.");
    try std.testing.expectEqual(@as(usize, 1), one.len);
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
