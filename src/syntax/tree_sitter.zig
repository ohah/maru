//! **구문 트리 1층**(native-editor-visual-mapping.md §5.3) — tree-sitter C 런타임 바인딩.
//!
//! **왜 `maru` 모듈이 아닌가.** 이 파일은 성질상 L2(문서 내용만의 함수)지만 **C를 링크한다**.
//! wasm·mobile 빌드가 `src/maru.zig`를 같은 root로 쓰므로 거기 매달면 그 둘이 깨진다
//! (`check-wasm-sync`가 게이트다). 그래서 `syntax`라는 **자기 모듈**로 서고, C도 그 모듈에만 붙는다.
//!
//! **아직 어느 산출물에도 링크되지 않는다.** `@import("syntax")`하는 제품 코드가 없어서고, provider가
//! 서는 N4가 그것을 붙일 자리다(`build.zig`의 해당 블록이 근거를 갖는다). 지금 이 파일을 돌리는 것은
//! 이 모듈을 뿌리로 하는 판정자 실행 하나뿐이다 — `editor_judges.zig`로는 **못 끌어온다**(모듈이
//! 달라 `zig test`가 안 싣는다).
//!
//! **파서를 신뢰 입력으로 다루지 않는다**(§5.3). grammar는 제3자 C이고 문서 내용은 적대적일 수
//! 있다(§3.8) — 크기 상한을 두고, 실패는 **무색**으로 떨어진다(§5: *"grammar가 없으면 무색"*).
//! 그래서 이 모듈의 모든 진입점은 실패를 오류가 아니라 **빈 결과**로 돌려준다.
//!
//! **쿼리 predicate는 평가하지 않는다 — 한 범위에 캡처가 여럿 붙는다.** grammar의 `highlights.scm`은
//! Neovim 관례를 따라 `#lua-match?` 같은 **호스트가 평가하는** 서술을 쓰는데(tree-sitter는 그것을
//! 검사하지 않고 그대로 넘긴다), 우리는 평가기를 두지 않으므로 그 패턴이 **조건 없이** 걸린다.
//! 실측: `// hello` 한 줄에 `comment`·`spell`·`comment.documentation` 셋이 붙는다(`comment.documentation`
//! 패턴의 `^//!` 조건이 안 걸러진 결과다). 소비처가 캡처→색을 **다대일**로 사상하므로(§5.3) 셋이
//! 같은 `comment`로 접히면 화면은 옳다 — 구분이 필요해지면 그때 평가기를 세운다.

const std = @import("std");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

/// grammar가 내보내는 진입점. `parser.c`가 이 이름으로 정의한다.
extern fn tree_sitter_zig() *const c.TSLanguage;

/// grammar의 하이라이트 쿼리 — **grammar가 소유한다**(빌드가 익명 import로 꽂는다).
const zig_highlights = @embedFile("zig_highlights_scm");

/// **파싱 상한**(§5.3 — "파싱 대상 크기·시간 상한"). 이 크기를 넘는 문서는 무색이다.
///
/// 4 MiB는 §3.0의 큰 파일 축소 임계와 같은 자리에서 고른 값이다. 넘는 문서에서 색을 포기하는 것은
/// **기능 상실이 아니라 저하 동작**이다 — 그 크기의 파일은 애초에 읽기용이다.
pub const max_parse_bytes: usize = 4 * 1024 * 1024;

/// 색을 입힐 한 조각. `start`/`end`는 **문서 byte offset**이다(§3.1 단일 위치 축).
pub const Span = struct {
    start: u32,
    end: u32,
    /// 쿼리가 붙인 capture 이름(`keyword`·`string`·`comment` …). 색으로의 사상은 **소비처**가
    /// 한다 — 이 모듈은 grammar가 말한 것을 그대로 옮긴다.
    ///
    /// **쿼리가 소유하는 문자열을 가리킨다**(`.scm` 원문이 아니다 — tree-sitter가 자기 표에 복사해
    /// 둔다). 그 쿼리는 프로세스 수명 동안 사는 캐시라 이 슬라이스도 그만큼 산다(`queryFor` 참고).
    capture: []const u8,
};

/// 이 언어를 우리가 파싱할 수 있는가. 없으면 무색이다(자체 lexer fallback을 두지 않는다 — §5.3).
pub fn languageFor(lang: Language) ?*const c.TSLanguage {
    return switch (lang) {
        .zig => tree_sitter_zig(),
        else => null,
    };
}

/// `session/editor/language.zig`의 열거와 **같은 축**을 쓰되, 이 모듈은 maru를 못 들여오므로
/// (모듈이 다르다) 필요한 것만 다시 적는다. 값을 늘릴 때 두 곳이 갈리지 않게 **호출자가 옮긴다**.
pub const Language = enum { zig, other };

/// 언어별 하이라이트 쿼리 — **프로세스 수명 동안 한 번만 만든다.** 두 가지가 이것을 요구한다:
///
///  1. **캡처 이름이 쿼리 안에 있다.** `ts_query_capture_name_for_id`가 주는 포인터는 `.scm` 원문이
///     아니라 **쿼리 객체의 문자열 표**를 가리킨다. 쿼리를 `highlights` 안에서 지우면 돌려준
///     `Span.capture`가 전부 **매달린 포인터**가 된다 — 실측으로 그랬고, byte 범위는 다 맞는데
///     캡처 이름만 해제된 메모리로 나왔다(`SYN1`이 그것을 잡는다).
///  2. **만드는 것이 비싸다.** `ts_query_new`는 `.scm` 300여 줄을 통째로 파싱한다. 호출마다 하면
///     §2.1이 렌더 루프에서 떼어내려는 바로 그 비용을 매 프레임 다시 낸다.
///
/// 해제 시점을 두지 않는다 — grammar 수만큼(§5.3 번들 언어는 **명시 목록**이다)이고 프로그램이
/// 끝날 때 OS가 걷는다. tree-sitter는 자기 allocator(기본 `malloc`)를 쓰므로 `std.testing.allocator`의
/// 누수 검사 대상이 아니다.
var zig_query: std.atomic.Value(?*c.TSQuery) = .init(null);

fn queryFor(lang: Language, language: *const c.TSLanguage) ?*c.TSQuery {
    const cell = switch (lang) {
        .zig => &zig_query,
        .other => return null,
    };
    if (cell.load(.acquire)) |cached| return cached;

    var err_offset: u32 = 0;
    var err_type: c.TSQueryError = 0;
    const built = c.ts_query_new(
        language,
        zig_highlights.ptr,
        @intCast(zig_highlights.len),
        &err_offset,
        &err_type,
    ) orelse return null; // 쿼리가 grammar와 안 맞으면 무색 — 죽지 않는다

    // **경쟁하면 진 쪽이 자기 것을 버린다.** 둘 다 같은 `.scm`으로 만든 같은 내용이라 어느 쪽이
    // 남아도 결과가 같다. 락을 두지 않는 이유다(`pty/windows.zig`가 같은 판단을 적어 두었다).
    if (cell.cmpxchgStrong(null, built, .release, .acquire)) |winner| {
        c.ts_query_delete(built);
        return winner;
    }
    return built;
}

/// 문서 전체의 하이라이트 조각을 모은다. **실패는 빈 목록이다** — 파서가 죽어도 편집기는 산다.
///
/// 반환한 `Span.capture`는 위 쿼리 캐시가 소유하므로 따로 해제하지 않는다.
pub fn highlights(
    allocator: std.mem.Allocator,
    lang: Language,
    source: []const u8,
    out: *std.ArrayList(Span),
) void {
    out.clearRetainingCapacity();
    if (source.len == 0 or source.len > max_parse_bytes) return;
    const language = languageFor(lang) orelse return;

    const parser = c.ts_parser_new() orelse return;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, language)) return; // ABI 세대가 다르면 여기서 걸린다

    const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return;
    defer c.ts_tree_delete(tree);

    const query = queryFor(lang, language) orelse return;

    const cursor = c.ts_query_cursor_new() orelse return;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

    var match: c.TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (c.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        if (capture_index >= match.capture_count) continue;
        const cap = match.captures[capture_index];
        const start = c.ts_node_start_byte(cap.node);
        const end = c.ts_node_end_byte(cap.node);
        if (end <= start) continue;

        var name_len: u32 = 0;
        const name_ptr = c.ts_query_capture_name_for_id(query, cap.index, &name_len) orelse continue;
        out.append(allocator, .{
            .start = start,
            .end = end,
            .capture = name_ptr[0..name_len],
        }) catch return; // OOM이면 여기까지가 색이다 — 그린 것은 맞는 색이다
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────

test "SYN1 zig 소스에서 키워드·문자열·주석이 갈린다 (§5.3)" {
    // **이 판정자가 배선 전체를 잰다**: C 링크 · grammar 진입점 · 쿼리 로드 · capture 이름.
    // 하나만 어긋나도 빈 목록이 나오므로, "비지 않았다"만으로도 많은 것이 확인된다 — 그래서
    // 그 위에 **무엇이 어디에 붙었는지**까지 잰다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const src =
        \\// hello
        \\const x = "abc";
        \\
    ;
    highlights(allocator, .zig, src, &spans);
    try std.testing.expect(spans.items.len > 0);

    var saw_comment = false;
    var saw_keyword = false;
    var saw_string = false;
    for (spans.items) |s| {
        const text = src[s.start..s.end];
        if (std.mem.indexOf(u8, s.capture, "comment") != null and std.mem.eql(u8, text, "// hello")) saw_comment = true;
        if (std.mem.indexOf(u8, s.capture, "keyword") != null and std.mem.eql(u8, text, "const")) saw_keyword = true;
        if (std.mem.indexOf(u8, s.capture, "string") != null and std.mem.indexOf(u8, text, "abc") != null) saw_string = true;
    }
    try std.testing.expect(saw_comment);
    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_string);
}

test "SYN2 모르는 언어와 상한 넘는 문서는 무색이다 — 죽지 않는다 (§5.3)" {
    // §5가 *"grammar가 없으면 무색"*이라고 정했다. 자체 lexer fallback을 두지 않는 대신 **빈
    // 목록**으로 떨어지고, 그 위 층은 색 없이 그대로 그린다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    highlights(allocator, .other, "const x = 1;", &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);

    highlights(allocator, .zig, "", &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);

    // 상한을 넘는 문서는 **파싱 자체를 안 한다**(§5.3 — 파서를 신뢰 입력으로 다루지 않는다).
    const big = try allocator.alloc(u8, max_parse_bytes + 1);
    defer allocator.free(big);
    @memset(big, ' ');
    highlights(allocator, .zig, big, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "SYN3 깨진 소스도 트리를 낸다 — 편집 중은 늘 불완전하다 (§5.3)" {
    // §5.3의 채택 근거 중 하나가 *"문법이 깨져도 트리가 나온다"*이고, **편집 중인 코드는 항상
    // 불완전**하므로 그 성질이 필수다. 여기서 빈 목록이 나오면 타이핑하는 동안 색이 사라진다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    highlights(allocator, .zig, "const x = \"unterminated", &spans);
    try std.testing.expect(spans.items.len > 0);
}
