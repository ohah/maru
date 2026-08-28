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

/// `session/editor/language.zig`의 열거와 **같은 축**을 쓰되, 이 모듈은 maru를 못 들여오므로
/// (모듈이 다르다) 필요한 것만 다시 적는다. 값을 늘릴 때 두 곳이 갈리지 않게 **호출자가 옮긴다**.
pub const Language = enum { zig, other };

/// 한 언어를 파싱하는 데 필요한 것 전부 — grammar 진입점 · 그 쿼리 캐시 칸 · 쿼리 원문.
const Slot = struct {
    language: *const c.TSLanguage,
    query_cell: *std.atomic.Value(?*c.TSQuery),
    scm: []const u8,
};

/// **지원 언어의 관문은 이 함수 하나다.** 처음에는 grammar를 고르는 `switch`와 쿼리 캐시를 고르는
/// `switch`가 따로 있었는데, 적대적 검증이 그 둘이 **서로 가려 준다**는 것을 보였다 — 앞 관문을
/// 열어 `.other`도 zig grammar로 파도록 뒤집었는데 뒤 관문이 막아 판정자가 **아무 차이도 못 봤다**
/// (뮤턴트 생존). 규칙이 두 곳에 있으면 갈리고, 갈려도 안 보인다. 늘리는 자리도 여기 하나다.
fn slotFor(lang: Language) ?Slot {
    return switch (lang) {
        .zig => .{ .language = tree_sitter_zig(), .query_cell = &zig_query, .scm = zig_highlights },
        .other => null,
    };
}

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

fn queryFor(slot: Slot) ?*c.TSQuery {
    if (slot.query_cell.load(.acquire)) |cached| return cached;

    var err_offset: u32 = 0;
    var err_type: c.TSQueryError = 0;
    const built = c.ts_query_new(
        slot.language,
        slot.scm.ptr,
        @intCast(slot.scm.len),
        &err_offset,
        &err_type,
    ) orelse return null; // 쿼리가 grammar와 안 맞으면 무색 — 죽지 않는다

    // **경쟁하면 진 쪽이 자기 것을 버린다.** 둘 다 같은 `.scm`으로 만든 같은 내용이라 어느 쪽이
    // 남아도 결과가 같다. 락을 두지 않는 이유다(`pty/windows.zig`가 같은 판단을 적어 두었다).
    if (slot.query_cell.cmpxchgStrong(null, built, .release, .acquire)) |winner| {
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
    const slot = slotFor(lang) orelse return;

    const parser = c.ts_parser_new() orelse return;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, slot.language)) return; // ABI 세대가 다르면 여기서 걸린다

    const tree = c.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return;
    defer c.ts_tree_delete(tree);

    const query = queryFor(slot) orelse return;

    const cursor = c.ts_query_cursor_new() orelse return;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, query, c.ts_tree_root_node(tree));

    var match: c.TSQueryMatch = undefined;
    var capture_index: u32 = 0;
    while (c.ts_query_cursor_next_capture(cursor, &match, &capture_index)) {
        // `capture_index`의 범위를 검사하지 않는다 — `api.h`가 *"its index within the match's
        // capture list"*라고 **계약으로** 못박는다. 검사를 넣어 뒀다가 적대적 검증에서 지웠다:
        // 지워도 어떤 판정자도 달라지지 않는 **죽은 가드**였고, 죽은 가드는 "여기서 뭔가 어긋날
        // 수 있다"는 거짓 신호를 남긴다.
        const cap = match.captures[capture_index];
        const start = c.ts_node_start_byte(cap.node);
        const end = c.ts_node_end_byte(cap.node);
        // **폭 0 캡처는 버린다.** 칠할 것이 없는데 span만 늘면 소비처가 빈 칸을 그린다.
        // 번들 grammar에서는 아직 한 번도 안 나왔다(실측: 절단 210가지 + 불균형 6개, 캡처
        // 13,430개 중 0개) — 그래서 **이 줄을 지워도 판정자가 안 죽는다**. 그럼에도 남기는 것은
        // tree-sitter의 MISSING 노드가 원리상 폭 0이고 grammar를 늘릴 때 캡처될 수 있어서다.
        // 이 줄이 지키는 불변식(`start < end`)은 `SYN6`가 전수로 잰다.
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

    // **상한은 같은 내용으로 양쪽을 재야 잰 것이 된다.** 처음에는 공백만 채운 4MiB로 "빈 목록"을
    // 확인했는데, 그것은 **아무것도 안 재는 판정**이었다 — 공백은 상한을 지우고 파싱해도 캡처가
    // 0개다(실측). 적대적 검증에서 상한 검사를 통째로 지운 뮤턴트가 그대로 살아남았다.
    //
    // 그래서 **한 버퍼의 길이만 바꿔** 두 번 부른다. 내용이 같으므로 결과가 갈리는 이유는 상한
    // 하나뿐이다. 경계를 `max_parse_bytes` **정확히**로 잡는 것도 그래서다 — `>`를 `>=`로 바꾼
    // 뮤턴트는 이 칸에서만 죽는다(그것도 실제로 살아남았었다).
    const big = try allocator.alloc(u8, max_parse_bytes + 1);
    defer allocator.free(big);
    @memset(big, ' ');
    const seed = "const x = 1;\n";
    @memcpy(big[0..seed.len], seed);

    highlights(allocator, .zig, big[0..max_parse_bytes], &spans);
    try std.testing.expect(spans.items.len > 0); // 딱 상한까지는 판다

    highlights(allocator, .zig, big, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len); // 한 byte 넘으면 안 판다
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

test "SYN4 호출마다 이전 결과를 지운다 — 색이 쌓이지 않는다" {
    // `highlights`는 호출자의 목록을 **덮어쓰는** 계약이다. 안 지우면 편집기가 프레임마다 부를 때
    // 색이 누적돼 옛 offset이 새 문서 위에 남는다 — 편집으로 글자가 밀리면 엉뚱한 곳이 칠해진다.
    //
    // **앞의 판정자들은 이것을 못 잰다.** 전부 "빈 목록이 나온다"를 확인하는데, 빈 결과는 지우든
    // 안 지우든 같아 보인다(적대적 검증에서 `clearRetainingCapacity` 제거 뮤턴트가 살아남았다).
    // 그래서 **색이 나오는 문서 다음에 무색 문서**를 넣는 순서가 이 판정의 전부다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    highlights(allocator, .zig, "const x = 1;", &spans);
    try std.testing.expect(spans.items.len > 0);

    highlights(allocator, .other, "const x = 1;", &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "SYN5 캡처 이름은 프로세스 수명 캐시가 소유한다 — 호출이 달라도 같은 주소다" {
    // 이 모듈이 쿼리를 캐시하는 **이유 자체**를 잰다. `Span.capture`는 쿼리 객체 안의 문자열을
    // 가리키므로, 쿼리를 호출마다 새로 만들면 ⑴ 지우는 판은 매달린 포인터가 되고(그 결함이 실제로
    // 있었다 — `SYN1`이 잡는다) ⑵ 안 지우는 판은 새 지만 매번 다른 주소를 준다.
    //
    // ⑵는 값 비교로는 안 보인다 — 이름 문자열은 어느 쪽이든 `keyword`로 같다. **주소가 같은지**를
    // 봐야 "한 쿼리를 재사용했다"가 확인된다(캐시를 끈 뮤턴트가 값 비교만으로는 살아남았다).
    const allocator = std.testing.allocator;
    var first: std.ArrayList(Span) = .empty;
    defer first.deinit(allocator);
    var second: std.ArrayList(Span) = .empty;
    defer second.deinit(allocator);

    highlights(allocator, .zig, "const x = 1;", &first);
    highlights(allocator, .zig, "const y = 2;", &second);
    try std.testing.expect(first.items.len > 0);
    try std.testing.expect(second.items.len > 0);

    // 같은 소스 모양이라 첫 캡처는 둘 다 `const`의 것이다 — 그 이름이 같은 주소여야 한다.
    try std.testing.expectEqualStrings(first.items[0].capture, second.items[0].capture);
    try std.testing.expectEqual(first.items[0].capture.ptr, second.items[0].capture.ptr);

    // 첫 호출의 슬라이스가 **두 번째 호출 뒤에도** 읽힌다 — 매달린 포인터였다면 여기서 무너진다.
    try std.testing.expect(first.items[0].capture.len > 0);
}

test "SYN6 어디서 잘라도 span 불변식이 선다 — start < end 이고 문서 안이다" {
    // **편집 중인 코드는 항상 불완전**하므로(§5.3) 잘린 상태가 정상 입력이다. 그 전 구간에서
    // `Span`이 문서 밖을 가리키거나 폭이 0이면 소비처가 슬라이스를 넘기거나 빈 칸을 그린다.
    //
    // 한 자리를 찍어 보는 대신 **모든 절단 위치를 전수로** 판다. 이 판정자가 없으면 폭 0 가드와
    // 범위 계산은 "아무도 안 재는 줄"로 남는다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const full =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    const s = struct { x: u32 = 1 };
        \\    if (s.x == 1) { std.debug.print("hi", .{}); }
        \\    const arr = [_]u8{ 1, 2, 3 };
        \\}
    ;

    var seen: usize = 0;
    var cut: usize = 0;
    while (cut <= full.len) : (cut += 1) {
        const src = full[0..cut];
        highlights(allocator, .zig, src, &spans);
        for (spans.items) |sp| {
            seen += 1;
            try std.testing.expect(sp.start < sp.end);
            try std.testing.expect(sp.end <= src.len);
            try std.testing.expect(sp.capture.len > 0);
        }
    }
    // 전수로 돌았는데 캡처가 하나도 안 나왔다면 이 판정자는 **항진명제**다 — 그것부터 막는다.
    try std.testing.expect(seen > 0);
}

test "SYN7 적대적 바이트가 와도 살아서 무색이거나 성한 span 을 낸다 (§3.8·§5.3)" {
    // §5.3이 *"파서를 신뢰 입력으로 다루지 않는다"*고 정했고 §3.8이 문서 내용이 적대적일 수 있다고
    // 했다. 앞의 판정자들은 전부 **정상 코드나 그것을 자른 것**만 먹인다 — 파일은 텍스트가 아닐
    // 수도 있고, 편집기는 그것도 연다.
    //
    // 재는 것은 둘이다: **죽지 않는다**(패닉·UB 없이 돌아온다)와 **성한 것만 낸다**(무색이거나
    // 문서 안의 폭 있는 span). tree-sitter가 무엇을 캡처하든 그 둘이 서면 위 층은 안전하다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    // 한 줄 20만 자 — §3.8의 "초장문 줄" 축.
    const long_line = try allocator.alloc(u8, 200 * 1024);
    defer allocator.free(long_line);
    @memset(long_line, 'a');

    // 5,000겹 중첩 — 파서 스택을 민다.
    const deep = try allocator.alloc(u8, 10_000);
    defer allocator.free(deep);
    @memset(deep[0..5_000], '(');
    @memset(deep[5_000..], ')');

    const hostile = [_][]const u8{
        "\xff\xfe\xfd", // UTF-8 이 아닌 바이트
        "const x = \"\x00\x01\x02\";", // NUL 을 품은 문자열
        "\xed\xa0\x80", // 짝 없는 서로게이트의 UTF-8 인코딩
        "\xc3", // 잘린 다중바이트 시퀀스
        "// \xe2\x80\xae 역방향 재정의", // §3.8 위험 문자
        long_line,
        deep,
        "\n\n\n\n\n",
    };

    for (hostile, 0..) |src, i| {
        highlights(allocator, .zig, src, &spans); // 여기서 죽으면 판정 자체가 안 끝난다
        for (spans.items) |sp| {
            std.testing.expect(sp.start < sp.end) catch |e| {
                std.debug.print("적대적 입력 #{d} 에서 폭 0/역순 span\n", .{i});
                return e;
            };
            std.testing.expect(sp.end <= src.len) catch |e| {
                std.debug.print("적대적 입력 #{d} 에서 문서 밖 span\n", .{i});
                return e;
            };
            try std.testing.expect(sp.capture.len > 0);
        }
    }
}

test "SYN8 문서의 마지막 byte 까지 판다 — 개행으로 끝나지 않는 파일" {
    // **앞의 판정자들은 이 구멍을 원리적으로 못 본다.** 그것들의 소스가 전부 개행으로 끝나서,
    // 파싱 길이를 한 byte 줄여도(마지막 `\n`만 잃는다) 캡처가 하나도 안 달라진다 — 적대적 검증에서
    // `source.len - 1`로 파는 뮤턴트가 그대로 살아남았다.
    //
    // 개행 없이 끝나는 파일은 흔하고(마지막 `}`가 곧 끝이다), 그 한 byte가 안 칠해지면 화면에서
    // 바로 보인다. 그래서 **끝에 닿는 span이 실제로 있는지**를 잰다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const src = "const x = 1;"; // 개행 없음 — 마지막 byte 는 `;`
    highlights(allocator, .zig, src, &spans);
    try std.testing.expect(spans.items.len > 0);

    var touches_end = false;
    for (spans.items) |sp| {
        if (sp.end == src.len) touches_end = true;
    }
    try std.testing.expect(touches_end);
}

test "SYN9 캡처 목록이 정확히 이것이다 — 순서·범위·이름까지 (골든)" {
    // **앞의 판정자들은 "있다"만 본다.** `SYN1`이 세 종류를 텍스트로 대조하지만 나머지는 안 보고,
    // 개수도 안 센다. 적대적 검증에서 그 틈으로 둘이 빠져나갔다: 같은 캡처를 **두 번** 담는
    // 뮤턴트와, 노드 대신 **부모의 범위**를 쓰는 뮤턴트(span이 통째로 넓어진다). 둘 다 화면에서는
    // 잘못 칠해지는데 판정자는 초록이었다.
    //
    // 그래서 작은 소스 하나의 **캡처 목록 전체**를 박는다. grammar 버전이 `build.zig.zon`에 고정돼
    // 있으므로 이 목록이 흔들리는 것은 **grammar를 올렸다는 뜻**이고, 그때는 색 사상을 다시 봐야
    // 한다 — 깨지는 것이 이 판정자의 일이다.
    //
    // `x` 하나에 넷이 붙는 것은 **머리말이 적어 둔 predicate 미평가**의 귀결이다. 그것이 여기
    // 박혀 있으므로, 나중에 평가기를 세우면 이 목록이 줄면서 그 변화가 눈에 띈다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const src = "const x = 1;";
    highlights(allocator, .zig, src, &spans);

    const expected = [_]Span{
        .{ .start = 0, .end = 5, .capture = "keyword" },
        .{ .start = 6, .end = 7, .capture = "variable" },
        .{ .start = 6, .end = 7, .capture = "type" },
        .{ .start = 6, .end = 7, .capture = "constant" },
        .{ .start = 6, .end = 7, .capture = "variable.builtin" },
        .{ .start = 8, .end = 9, .capture = "operator" },
        .{ .start = 10, .end = 11, .capture = "number" },
        .{ .start = 11, .end = 12, .capture = "punctuation.delimiter" },
    };

    try std.testing.expectEqual(expected.len, spans.items.len);
    for (expected, spans.items) |want, got| {
        try std.testing.expectEqual(want.start, got.start);
        try std.testing.expectEqual(want.end, got.end);
        try std.testing.expectEqualStrings(want.capture, got.capture);
    }
}
