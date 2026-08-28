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
    highlightsInRange(allocator, lang, source, .{ .start = 0, .end = @intCast(@min(source.len, max_parse_bytes)) }, out);
}

/// 한 번의 편집. 행·열(0-based)까지 채워야 증분 파싱이 이득을 낸다.
pub const Point = struct { row: u32, column: u32 };
pub const Edit = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,
};

/// 문서에서 **byte 범위 하나만** 색을 모은다. 파싱은 문서 전체를 하고(문맥이 있어야 트리가 맞다)
/// 쿼리만 그 범위로 좁힌다.
///
/// **왜 나누는가 — 비용이 거기 있다.** 실측(`ReleaseFast`, 154KB 소스): 전체 문서에 쿼리를 돌리면
/// 11ms인데, 그 대부분이 파싱이 아니라 **쿼리 실행**이다. 편집기는 화면에 보이는 수십 줄만 그리므로
/// 그 범위만 물으면 같은 그림을 훨씬 싸게 얻는다. §5.3이 LSP 층에 *"보이는 범위만 요청한다"*고
/// 정한 것과 **같은 논리**이고, 이유도 같다 — 화면 밖 결과는 소비되지 않는다.
///
/// `range`가 문서를 넘으면 잘린다. `end <= start`면 빈 목록이다.
pub const Range = struct { start: u32, end: u32 };

pub fn highlightsInRange(
    allocator: std.mem.Allocator,
    lang: Language,
    source: []const u8,
    range: Range,
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

    collect(allocator, tree, query, source, range, out);
}

/// 쿼리 커서를 돌려 조각을 모은다. **`highlightsInRange`와 `Provider`가 같은 함수를 쓴다** —
/// 둘이 각자 걷으면 범위 처리·폭 0 규칙이 갈리고, 그 어긋남은 화면에만 나타난다.
fn collect(
    allocator: std.mem.Allocator,
    tree: *c.TSTree,
    query: *c.TSQuery,
    source: []const u8,
    range: Range,
    out: *std.ArrayList(Span),
) void {
    const cursor = c.ts_query_cursor_new() orelse return;
    defer c.ts_query_cursor_delete(cursor);

    // **범위를 exec 전에 건다** — `api.h`가 그렇게 요구한다. `end`가 0이면 헤더가 그것을
    // `UINT32_MAX`(무제한)로 읽으므로, 빈 범위는 여기 오기 전에 걸러야 한다.
    const hi = @min(range.end, @as(u32, @intCast(source.len)));
    if (hi <= range.start) return;
    _ = c.ts_query_cursor_set_byte_range(cursor, range.start, hi);
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

// ── provider(§5.3) ─────────────────────────────────────────────────────────────

/// **트리를 들고 있는** 하이라이트 제공자. 한 문서에 하나다.
///
/// **왜 함수 하나로 안 되는가 — 실측이 그렇게 말했다.** `highlightsInRange`는 부를 때마다 문서를
/// 다시 판다. 154KB 소스에서 전체 쿼리가 10ms, 창으로 좁히면 5ms인데 **그 5ms가 파싱이다**
/// (`ReleaseFast`). 창으로 좁히는 것만으로는 스크롤이 매번 5ms를 낸다 — 스크롤은 편집보다 잦다.
/// 트리를 살려 두면 스크롤은 쿼리만 내고 파싱은 **문서가 바뀔 때만** 든다.
///
/// **증분 파싱(`onEdit`)은 아직 없다.** `setSource`가 전체를 다시 판다 — 그래서 편집 한 번의 값이
/// 위 5ms다. 그것을 지우는 것이 §5.3이 말한 증분 파싱이고 다음 슬라이스다. 지금 구조는 그때
/// `ts_tree_edit` + 옛 트리를 넘기는 것으로 **이 자리만** 바뀐다.
pub const Provider = struct {
    parser: *c.TSParser,
    tree: ?*c.TSTree = null,
    slot: Slot,

    /// 문서 하나를 맡는다. **§5.3의 `init(문서 bytes, 언어)` 그대로다** — 언어만 받고 내용을
    /// 나중에 넣는 형태였다가 계약에 맞췄다(이름과 인자가 계약과 갈리면 문서를 읽고 코드를 찾는
    /// 사람이 두 번 헤맨다).
    ///
    /// grammar가 없으면 `null` — 그 문서는 무색이다(§5).
    pub fn init(source: []const u8, lang: Language) ?Provider {
        const slot = slotFor(lang) orelse return null;
        const parser = c.ts_parser_new() orelse return null;
        if (!c.ts_parser_set_language(parser, slot.language)) {
            c.ts_parser_delete(parser);
            return null;
        }
        var self: Provider = .{ .parser = parser, .slot = slot };
        self.setSource(source);
        return self;
    }

    pub fn deinit(self: *Provider) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        c.ts_parser_delete(self.parser);
        self.* = undefined;
    }

    /// 문서 내용이 **통째로** 바뀌었다(디스크에서 다시 읽기 등) — 전체를 다시 판다.
    ///
    /// **편집에는 `onEdit`을 쓴다.** 실측으로 81배 차이가 난다(154KB에서 5.3ms 대 65µs) —
    /// §5.3이 *"통지가 없으면 증분 파싱이 성립하지 않아 매번 전체 재파싱이 된다"*고 적은 그 자리다.
    ///
    /// **상한을 넘으면 트리를 버린다**(그 뒤 질의는 빈 목록이다).
    pub fn setSource(self: *Provider, source: []const u8) void {
        if (self.tree) |t| {
            c.ts_tree_delete(t);
            self.tree = null;
        }
        if (source.len == 0 or source.len > max_parse_bytes) return;
        self.tree = c.ts_parser_parse_string(self.parser, null, source.ptr, @intCast(source.len));
    }

    /// 편집 하나를 알린 뒤 **증분으로** 다시 판다. `source`는 **바뀐 뒤**의 내용이다.
    ///
    /// **행·열을 반드시 채워야 한다.** 처음에는 *"byte offset만으로도 된다"*고 적고 0을 넘겼는데,
    /// 실측이 그것을 반증했다 — 그렇게 하면 증분이 전체 재파싱보다 **더 느리다**(154KB에서 9.8ms
    /// 대 5ms, 618KB에서 30ms 대 21ms). tree-sitter가 어긋난 위치를 되맞추느라 더 일한다.
    pub fn onEdit(self: *Provider, source: []const u8, e: Edit) void {
        const old_tree = self.tree orelse {
            self.setSource(source);
            return;
        };
        if (source.len == 0 or source.len > max_parse_bytes) {
            c.ts_tree_delete(old_tree);
            self.tree = null;
            return;
        }
        var edit: c.TSInputEdit = .{
            .start_byte = e.start_byte,
            .old_end_byte = e.old_end_byte,
            .new_end_byte = e.new_end_byte,
            .start_point = .{ .row = e.start_point.row, .column = e.start_point.column },
            .old_end_point = .{ .row = e.old_end_point.row, .column = e.old_end_point.column },
            .new_end_point = .{ .row = e.new_end_point.row, .column = e.new_end_point.column },
        };
        c.ts_tree_edit(old_tree, &edit);
        const next = c.ts_parser_parse_string(self.parser, old_tree, source.ptr, @intCast(source.len));
        c.ts_tree_delete(old_tree);
        self.tree = next;
    }

    /// 이 byte 범위의 색 조각. **트리가 없으면 빈 목록**이다 — 실패는 늘 무색으로 떨어진다(§5).
    pub fn spansForRange(
        self: *Provider,
        allocator: std.mem.Allocator,
        source: []const u8,
        range: Range,
        out: *std.ArrayList(Span),
    ) void {
        out.clearRetainingCapacity();
        const tree = self.tree orelse return;
        const query = queryFor(self.slot) orelse return;
        collect(allocator, tree, query, source, range, out);
    }
};

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

// ── 누수 판정(§5.3 — provider가 C 메모리를 쥔다) ────────────────────────────────

/// 지금 살아 있는 tree-sitter 할당 수. 아래 판정자만 쓴다.
var live_allocs: isize = 0;

fn countingMalloc(n: usize) callconv(.c) ?*anyopaque {
    const p = std.c.malloc(n);
    if (p != null) live_allocs += 1;
    return p;
}
fn countingCalloc(n: usize, sz: usize) callconv(.c) ?*anyopaque {
    const p = std.c.calloc(n, sz);
    if (p != null) live_allocs += 1;
    return p;
}
fn countingRealloc(ptr: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque {
    // **`realloc(NULL, n)`은 `malloc`이다** — 그때만 살아 있는 수가 는다. 기존 블록을 옮기는
    // 경우는 하나가 하나로 바뀌므로 수가 그대로다.
    const grew = (ptr == null);
    const p = std.c.realloc(ptr, n);
    if (grew and p != null) live_allocs += 1;
    return p;
}
fn countingFree(ptr: ?*anyopaque) callconv(.c) void {
    // `free(NULL)`은 아무것도 안 한다 — 세면 수가 음수로 샌다.
    if (ptr != null) live_allocs -= 1;
    std.c.free(ptr);
}

test "SYN10 Provider 가 C 메모리를 안 남긴다 — 열고 고치고 닫으면 0으로 돌아온다" {
    // **파서와 트리는 tree-sitter의 `malloc`에서 온다.** `std.testing.allocator`의 누수 검사는
    // 그것을 못 본다 — 이 모듈에서 진짜로 샐 수 있는 곳이 정확히 거기다(`deinit`을 빼먹거나,
    // `setSource`가 옛 트리를 안 지우거나, `onEdit`이 실패 경로에서 놓치거나).
    //
    // **쿼리 캐시를 먼저 데운다.** 그것은 프로세스 수명이라 일부러 안 지운다 — 계수 안에 넣으면
    // 절대 0으로 안 돌아오고, 그러면 이 판정자가 늘 빨갛거나(쓸모없거나) 기준을 헐겁게 잡아야
    // 한다. 데운 뒤부터 세면 **provider가 쥐는 것만** 남는다.
    const allocator = std.testing.allocator;
    var warm: std.ArrayList(Span) = .empty;
    defer warm.deinit(allocator);
    highlights(allocator, .zig, "const x = 1;", &warm);
    try std.testing.expect(warm.items.len > 0); // 데우기가 실제로 돌았다

    c.ts_set_allocator(countingMalloc, countingCalloc, countingRealloc, countingFree);
    defer c.ts_set_allocator(null, null, null, null);

    live_allocs = 0;
    {
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(allocator);

        const src1 = "const x = 1;\npub fn f() void {}\n";
        var prov = Provider.init(src1, .zig) orelse return error.NoProvider;
        prov.spansForRange(allocator, src1, .{ .start = 0, .end = src1.len }, &spans);
        try std.testing.expect(spans.items.len > 0);

        // 여러 번 고친다 — 옛 트리를 매번 놓는지 본다.
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            prov.setSource(src1);
            prov.onEdit(src1, .{
                .start_byte = 6,
                .old_end_byte = 6,
                .new_end_byte = 6,
                .start_point = .{ .row = 0, .column = 6 },
                .old_end_point = .{ .row = 0, .column = 6 },
                .new_end_point = .{ .row = 0, .column = 6 },
            });
        }
        // 상한을 넘는 문서로 트리를 버리는 경로도 지난다.
        const big = try allocator.alloc(u8, max_parse_bytes + 1);
        defer allocator.free(big);
        @memset(big, ' ');
        prov.setSource(big);

        prov.deinit();
    }
    try std.testing.expectEqual(@as(isize, 0), live_allocs);
}

// ── 창·증분 판정(§5.3 — 보이는 범위만 · 통지가 있어야 증분이 성립한다) ──────────────

test "SYN11 빈 범위는 빈 목록이다 — end=0 을 무제한으로 읽지 않는다" {
    // **헤더의 함정을 고정한다.** `ts_query_cursor_set_byte_range`는 `end`가 0이면 그것을
    // `UINT32_MAX`(무제한)로 읽는다. 그래서 빈 범위를 그대로 넘기면 **문서 전체**가 돌아온다 —
    // 화면에는 "왜 이렇게 느리지" 말고는 증상이 없고, 색은 오히려 더 많이 나온다.
    // `collect`의 `hi <= range.start` 거르기가 그 자리이고, 이 판정자가 그것을 지킨다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const src =
        \\const x = "abc"; // c
        \\pub fn f() void {}
        \\
    ;
    // 먼저 이 문서에 색이 **있다**는 것부터 — 아래 0이 "원래 없음"이 아니라 "범위가 걸렀음"이어야 한다.
    highlights(allocator, .zig, src, &spans);
    try std.testing.expect(spans.items.len > 0);

    highlightsInRange(allocator, .zig, src, .{ .start = 0, .end = 0 }, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);

    highlightsInRange(allocator, .zig, src, .{ .start = 5, .end = 5 }, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);

    // 뒤집힌 범위도 같다.
    highlightsInRange(allocator, .zig, src, .{ .start = 10, .end = 3 }, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "SYN12 창 밖은 안 칠한다 — 범위 뒤에서 시작하는 조각이 없다" {
    // 편집기는 보이는 수십 줄만 그린다(§5.3). 창을 무시하고 문서 전체를 질의해도 **화면은 같아
    // 보인다** — 소비처가 창 밖을 안 그리기 때문이다. 그래서 이 회귀는 성능으로만 나타나고,
    // 색을 보는 판정자로는 안 잡힌다. 여기서 범위 계약 자체를 잰다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const src =
        \\const a = 1;
        \\const b = "second line string";
        \\const c = "third line string";
        \\
    ;
    const first_line_end: u32 = @intCast(std.mem.indexOfScalar(u8, src, '\n').? + 1);
    const second_line_end: u32 = @intCast(std.mem.indexOfScalarPos(u8, src, first_line_end, '\n').? + 1);

    // ⑴ 위쪽 경계. 창 **뒤에서 시작하는** 조각은 창 밖이다(걸치는 것은 허용한다 — 창 안에서
    //    시작해 넘어갈 수 있다).
    highlightsInRange(allocator, .zig, src, .{ .start = 0, .end = first_line_end }, &spans);
    try std.testing.expect(spans.items.len > 0); // 창 안에는 색이 있다
    for (spans.items) |sp| {
        try std.testing.expect(sp.start < first_line_end);
    }

    // ⑵ **아래쪽 경계도 잰다.** 위만 재면 하한을 0으로 바꾸는 회귀가 그대로 지나간다 — 실제로
    //    그 뮤턴트가 ⑴만 있을 때 살아남았다. 창은 두 끝이 다 있어야 창이다.
    highlightsInRange(allocator, .zig, src, .{ .start = first_line_end, .end = second_line_end }, &spans);
    try std.testing.expect(spans.items.len > 0);
    for (spans.items) |sp| {
        try std.testing.expect(sp.end > first_line_end);
        try std.testing.expect(sp.start < second_line_end);
    }
}

/// 지금까지의 tree-sitter 할당 **횟수**(누적). `live_allocs`와 달리 free로 줄지 않는다 — 재사용을
/// 재는 자다. 아래 판정자만 쓴다.
var total_allocs: usize = 0;

fn totalMalloc(n: usize) callconv(.c) ?*anyopaque {
    total_allocs += 1;
    return std.c.malloc(n);
}
fn totalCalloc(n: usize, sz: usize) callconv(.c) ?*anyopaque {
    total_allocs += 1;
    return std.c.calloc(n, sz);
}
fn totalRealloc(p: ?*anyopaque, n: usize) callconv(.c) ?*anyopaque {
    total_allocs += 1;
    return std.c.realloc(p, n);
}
fn totalFree(p: ?*anyopaque) callconv(.c) void {
    std.c.free(p);
}

test "SYN13 onEdit 이 옛 트리를 실제로 재사용한다 — 전체 재파싱의 1/4 미만으로 판다" {
    // **문서가 주장하는 81배를 지키는 자리다.** `setSource`의 주석과 §5.3이 *"통지가 없으면 매번
    // 전체 재파싱"*이라고 적었는데, 그 배선이 끊겨도 **색은 똑같이 나온다** — 판정자도 골든도
    // 통과한다. 실제로 5회차 뮤턴트 실험에서 옛 트리를 안 넘기는 변경이 모든 게이트를 지나갔다.
    //
    // **시간이 아니라 할당 횟수로 잰다.** 시간은 기계와 부하를 타서 CI에서 흔들리지만, 재사용
    // 여부는 tree-sitter가 새로 만드는 subtree 수에 그대로 나타난다.
    //
    // 실측(이 문서, 약 14KB): 전체 8706 · 정상 증분 614(7%) · 옛 트리 미전달 8704(99%) ·
    // 편집 지점을 0으로 4656(53%). 7%와 53% 사이가 넓어 **25%**를 경계로 잡는다.
    const allocator = std.testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try buf.appendSlice(allocator, "pub fn f() void { const s = \"abc\"; _ = s; } // c\n");
    }
    const src1 = try allocator.dupe(u8, buf.items);
    defer allocator.free(src1);

    // 한가운데 한 글자를 넣는다.
    const at: u32 = @intCast(src1.len / 2);
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(allocator);
    try edited.appendSlice(allocator, src1[0..at]);
    try edited.append(allocator, ' ');
    try edited.appendSlice(allocator, src1[at..]);
    const src2 = edited.items;

    var row: u32 = 0;
    var col: u32 = 0;
    for (src1[0..at]) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }

    // 쿼리 캐시를 먼저 데운다(SYN10과 같은 이유 — 계수에 섞이면 기준이 흐려진다).
    var warm: std.ArrayList(Span) = .empty;
    defer warm.deinit(allocator);
    highlights(allocator, .zig, "const x = 1;", &warm);
    try std.testing.expect(warm.items.len > 0);

    c.ts_set_allocator(totalMalloc, totalCalloc, totalRealloc, totalFree);
    defer c.ts_set_allocator(null, null, null, null);

    var prov = Provider.init(src1, .zig) orelse return error.NoProvider;
    defer prov.deinit();

    total_allocs = 0;
    prov.setSource(src2);
    const full = total_allocs;
    try std.testing.expect(full > 0); // 계수 훅이 실제로 걸렸다

    prov.setSource(src1);
    total_allocs = 0;
    prov.onEdit(src2, .{
        .start_byte = at,
        .old_end_byte = at,
        .new_end_byte = at + 1,
        .start_point = .{ .row = row, .column = col },
        .old_end_point = .{ .row = row, .column = col },
        .new_end_point = .{ .row = row, .column = col + 1 },
    });
    const incremental = total_allocs;

    try std.testing.expect(incremental * 4 < full);
}

test "SYN14 편집 뒤 색이 새 내용을 따른다 — 통지 없이는 옛 트리가 그대로 살아남는다" {
    // SYN13은 **얼마나 일했는지**를 잰다. 통지 자체를 빼면 tree-sitter는 옛 트리를 그대로
    // 유효하다고 믿어 **일을 거의 안 하고** 옛 색을 돌려주므로, 그 경로는 SYN13을 오히려
    // 통과한다. 그래서 **결과**를 보는 자가 따로 있어야 한다.
    const allocator = std.testing.allocator;
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);

    const before = "const a = 1;\nzzz\n";
    const after = "const a = 1;\n// zzz\n";
    const line2: u32 = @intCast(std.mem.indexOfScalar(u8, before, '\n').? + 1);

    var prov = Provider.init(before, .zig) orelse return error.NoProvider;
    defer prov.deinit();

    prov.spansForRange(allocator, before, .{ .start = 0, .end = @intCast(before.len) }, &spans);
    try std.testing.expect(!hasCaptureAt(spans.items, "comment", line2));

    prov.onEdit(after, .{
        .start_byte = line2,
        .old_end_byte = line2,
        .new_end_byte = line2 + 3, // "// "
        .start_point = .{ .row = 1, .column = 0 },
        .old_end_point = .{ .row = 1, .column = 0 },
        .new_end_point = .{ .row = 1, .column = 3 },
    });

    prov.spansForRange(allocator, after, .{ .start = 0, .end = @intCast(after.len) }, &spans);
    try std.testing.expect(hasCaptureAt(spans.items, "comment", line2));
}

fn hasCaptureAt(spans: []const Span, comptime prefix: []const u8, at: u32) bool {
    for (spans) |sp| {
        if (sp.start == at and std.mem.startsWith(u8, sp.capture, prefix)) return true;
    }
    return false;
}
