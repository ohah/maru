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
extern fn tree_sitter_json() *const c.TSLanguage;
extern fn tree_sitter_markdown() *const c.TSLanguage;
extern fn tree_sitter_javascript() *const c.TSLanguage;
extern fn tree_sitter_typescript() *const c.TSLanguage;
extern fn tree_sitter_tsx() *const c.TSLanguage;
extern fn tree_sitter_c() *const c.TSLanguage;
extern fn tree_sitter_cpp() *const c.TSLanguage;
extern fn tree_sitter_python() *const c.TSLanguage;
extern fn tree_sitter_go() *const c.TSLanguage;
extern fn tree_sitter_rust() *const c.TSLanguage;
extern fn tree_sitter_java() *const c.TSLanguage;
extern fn tree_sitter_ruby() *const c.TSLanguage;
extern fn tree_sitter_php() *const c.TSLanguage;
extern fn tree_sitter_kotlin() *const c.TSLanguage;
extern fn tree_sitter_bash() *const c.TSLanguage;
extern fn tree_sitter_css() *const c.TSLanguage;
extern fn tree_sitter_html() *const c.TSLanguage;

/// 하이라이트 쿼리 — **grammar가 소유한다**(빌드가 익명 import로 꽂는다. `build.zig`의 grammar 표가
/// 같은 이름을 쓴다 — 둘이 갈리면 컴파일이 죽는다).
const zig_highlights = @embedFile("zig_highlights_scm");
const json_highlights = @embedFile("json_highlights_scm");
const markdown_highlights = @embedFile("markdown_highlights_scm");
const javascript_highlights = @embedFile("javascript_highlights_scm");
const typescript_highlights = @embedFile("typescript_highlights_scm");
const tsx_highlights = @embedFile("tsx_highlights_scm");
const c_highlights = @embedFile("c_highlights_scm");
const cpp_highlights = @embedFile("cpp_highlights_scm");
const python_highlights = @embedFile("python_highlights_scm");
const go_highlights = @embedFile("go_highlights_scm");
const rust_highlights = @embedFile("rust_highlights_scm");
const java_highlights = @embedFile("java_highlights_scm");
const ruby_highlights = @embedFile("ruby_highlights_scm");
const php_highlights = @embedFile("php_highlights_scm");
const kotlin_highlights = @embedFile("kotlin_highlights_scm");
const bash_highlights = @embedFile("bash_highlights_scm");
const css_highlights = @embedFile("css_highlights_scm");
const html_highlights = @embedFile("html_highlights_scm");

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
pub const Language = enum { zig, json, markdown, javascript, typescript, tsx, c, cpp, python, go, rust, java, ruby, php, kotlin, bash, css, html, other };

/// 한 언어를 파싱하는 데 필요한 것 전부 — grammar 진입점 · 그 쿼리 캐시 칸 · 쿼리 원문.
const Slot = struct {
    language: *const c.TSLanguage,
    query_cell: *std.atomic.Value(?*c.TSQuery),
    scm: []const u8,
    /// 접을 노드 종류(§4.1f). 비면 그 언어는 구문 접힘이 없다.
    fold_kinds: []const []const u8 = &.{},
    /// 심볼로 볼 노드 종류(§7.5). 비면 그 언어는 심볼 목록이 없다.
    symbol_kinds: []const []const u8 = &.{},
};

/// **지원 언어의 관문은 이 함수 하나다.** 처음에는 grammar를 고르는 `switch`와 쿼리 캐시를 고르는
/// `switch`가 따로 있었는데, 적대적 검증이 그 둘이 **서로 가려 준다**는 것을 보였다 — 앞 관문을
/// 열어 `.other`도 zig grammar로 파도록 뒤집었는데 뒤 관문이 막아 판정자가 **아무 차이도 못 봤다**
/// (뮤턴트 생존). 규칙이 두 곳에 있으면 갈리고, 갈려도 안 보인다. 늘리는 자리도 여기 하나다.
fn slotFor(lang: Language) ?Slot {
    inline for (grammar_table, 0..) |g, i| {
        if (g.lang == lang) return .{ .language = g.get(), .query_cell = &query_cells[i], .scm = g.scm, .fold_kinds = g.fold_kinds, .symbol_kinds = g.symbol_kinds };
    }
    return null;
}

/// 번들 grammar 표. **목록의 단일 출처는 `docs/plans/native-editor.md`**이고, 여기와 `build.zig`의
/// 표가 그것을 따른다(셋이 갈리면 그 언어만 조용히 무색이 되거나 컴파일이 죽는다).
const GrammarEntry = struct {
    lang: Language,
    get: *const fn () callconv(.c) *const c.TSLanguage,
    scm: []const u8,
    /// **접을 노드 종류**(§4.1f — 언어별 목록이고 우리가 소유한다). 비어 있으면 그 언어는 구문
    /// 접힘이 없고 들여쓰기 층이 그대로 산다.
    ///
    /// **"두 줄 이상 노드를 다 접는" 규칙은 실측이 반박했다** — markdown 에서 화살표의 76%가
    /// 목록 항목·문단이었다(§4.1f 표). 코드에서 잘 맞는 규칙이 산문에서 망가진다.
    fold_kinds: []const []const u8 = &.{},
    /// **심볼로 볼 노드 종류**(native-editor-ui.md §7.5 — "이 파일 안에 무엇이 있나"). 비어 있으면
    /// 그 언어는 심볼 목록이 없다.
    ///
    /// **접힘 종류와 다른 목록이다.** 접힘은 *"접으면 뭐가 줄어드나"* 를 묻고 심볼은 *"이름이 붙은
    /// 것이 무엇인가"* 를 묻는다 — 블록은 접히지만 심볼이 아니고, 한 줄짜리 선언은 심볼이지만
    /// 접히지 않는다. 한 목록으로 겸하면 둘 중 하나가 늘 틀린다.
    symbol_kinds: []const []const u8 = &.{},
};

// 종류 이름은 grammar 가 정한다(`ts_node_type`). 아래는 **접었을 때 의미가 있는 것**만 골랐고,
// 언어마다 이름이 다르므로 겹치는 것도 각자 적는다 — 공통 집합을 만들면 한 언어의 개명이 다른
// 언어를 조용히 바꾼다.
const brace_block = [_][]const u8{ "block", "compound_statement", "statement_block", "declaration_list", "field_declaration_list", "class_body", "enum_body", "switch_body", "argument_list", "arguments", "parameter_list", "formal_parameters", "initializer_list", "array", "object" };

const grammar_table = [_]GrammarEntry{
    .{ .lang = .zig, .get = tree_sitter_zig, .scm = zig_highlights, .fold_kinds = &.{ "block", "switch_expression", "initializer_list", "asm_expression", "multiline_string", "if_statement", "while_statement", "for_statement", "if_expression", "else_clause", "for_expression", "container_declaration", "function_declaration", "variable_declaration", "test_declaration", "labeled_statement", "switch_case", "struct_declaration", "enum_declaration" }, .symbol_kinds = &.{ "function_declaration", "test_declaration", "variable_declaration" } },
    .{ .lang = .json, .get = tree_sitter_json, .scm = json_highlights, .fold_kinds = &.{ "object", "array" }, .symbol_kinds = &.{} },
    // **markdown 은 심볼 목록이 비어 있다.** `section` 에는 이름 노드가 없고(제목 글자는 `inline`
    // 자식이다) 식별자 기반 명명 규칙과 다르다 — 넣어 두면 "지원하는 척" 하면서 목록이 늘 빈다.
    // 제목을 이름으로 뽑는 것은 별도 슬라이스다(§7.5 의 아웃라인이 산문까지 덮을 때).
    .{ .lang = .markdown, .get = tree_sitter_markdown, .scm = markdown_highlights, .fold_kinds = &.{ "section", "list", "fenced_code_block", "pipe_table", "block_quote" }, .symbol_kinds = &.{} },
    .{ .lang = .javascript, .get = tree_sitter_javascript, .scm = javascript_highlights, .fold_kinds = &brace_block, .symbol_kinds = &.{ "function_declaration", "generator_function_declaration", "class_declaration", "method_definition" } },
    // **상속을 우리가 잇는다.** Neovim 이 `; inherits: javascript` 로 잇는 그 구조인데 tree-sitter
    // 자체에는 그 기능이 없다 — 쿼리 파일이 그냥 텍스트다. 안 이으면 TypeScript 파일에서 문자열·주석
    // 같은 **JS 층 색이 통째로 빠진다**(ts 쿼리는 35줄이고 js 는 204줄이다).
    //
    // **기본을 앞에 둔다** — 겹치는 범위는 `collect`가 마지막 캡처를 택하므로(§5.3 겹침 규칙),
    // 언어 고유 패턴이 뒤에 와야 기본을 이긴다.
    .{ .lang = .typescript, .get = tree_sitter_typescript, .scm = javascript_highlights ++ "\n" ++ typescript_highlights, .fold_kinds = &brace_block, .symbol_kinds = &.{ "function_declaration", "class_declaration", "method_definition", "interface_declaration", "type_alias_declaration", "enum_declaration" } },
    .{ .lang = .tsx, .get = tree_sitter_tsx, .scm = javascript_highlights ++ "\n" ++ tsx_highlights, .fold_kinds = &brace_block, .symbol_kinds = &.{ "function_declaration", "class_declaration", "method_definition", "interface_declaration", "type_alias_declaration", "enum_declaration" } },
    .{ .lang = .c, .get = tree_sitter_c, .scm = c_highlights, .fold_kinds = &brace_block, .symbol_kinds = &.{ "function_definition", "struct_specifier", "enum_specifier", "type_definition" } },
    // C++ 도 같다(`; inherits: c` — cpp 쿼리는 70줄이고 c 는 81줄이다). 안 이으면 `int main(void)`
    // 같은 C 층 구문이 무색이라 **파일 대부분이 색을 잃는다**(`SYN18`이 그것을 잡았다).
    .{ .lang = .cpp, .get = tree_sitter_cpp, .scm = c_highlights ++ "\n" ++ cpp_highlights, .fold_kinds = &brace_block, .symbol_kinds = &.{ "function_definition", "class_specifier", "struct_specifier", "enum_specifier", "namespace_definition" } },
    .{ .lang = .python, .get = tree_sitter_python, .scm = python_highlights, .fold_kinds = &.{ "block", "dictionary", "list", "set", "tuple", "argument_list", "parameters" }, .symbol_kinds = &.{ "function_definition", "class_definition" } },
    .{ .lang = .go, .get = tree_sitter_go, .scm = go_highlights, .fold_kinds = &.{ "block", "field_declaration_list", "composite_literal", "argument_list", "parameter_list", "literal_value", "expression_switch_statement", "type_switch_statement", "const_declaration", "var_declaration", "import_declaration" }, .symbol_kinds = &.{ "function_declaration", "method_declaration", "type_declaration" } },
    .{ .lang = .rust, .get = tree_sitter_rust, .scm = rust_highlights, .fold_kinds = &.{ "block", "declaration_list", "field_declaration_list", "arguments", "parameters", "match_block", "use_list", "token_tree" }, .symbol_kinds = &.{ "function_item", "struct_item", "enum_item", "trait_item", "impl_item", "mod_item" } },
    .{ .lang = .java, .get = tree_sitter_java, .scm = java_highlights, .fold_kinds = &.{ "block", "class_body", "enum_body", "interface_body", "argument_list", "formal_parameters", "array_initializer", "switch_block" }, .symbol_kinds = &.{ "class_declaration", "interface_declaration", "enum_declaration", "method_declaration", "constructor_declaration" } },
    .{ .lang = .ruby, .get = tree_sitter_ruby, .scm = ruby_highlights, .fold_kinds = &.{ "body_statement", "do_block", "block", "hash", "array", "argument_list", "then", "else" }, .symbol_kinds = &.{ "method", "singleton_method", "class", "module" } },
    .{ .lang = .php, .get = tree_sitter_php, .scm = php_highlights, .fold_kinds = &.{ "compound_statement", "declaration_list", "array_creation_expression", "arguments", "formal_parameters", "switch_block", "enum_declaration_list" }, .symbol_kinds = &.{ "function_definition", "method_declaration", "class_declaration", "interface_declaration", "trait_declaration" } },
    .{ .lang = .kotlin, .get = tree_sitter_kotlin, .scm = kotlin_highlights, .fold_kinds = &.{ "class_body", "function_body", "control_structure_body", "statements", "value_arguments", "function_value_parameters", "when_expression", "lambda_literal" }, .symbol_kinds = &.{ "function_declaration", "class_declaration", "object_declaration" } },
    .{ .lang = .bash, .get = tree_sitter_bash, .scm = bash_highlights, .fold_kinds = &.{ "compound_statement", "do_group", "if_statement", "case_statement", "function_definition", "subshell" }, .symbol_kinds = &.{"function_definition"} },
    .{ .lang = .css, .get = tree_sitter_css, .scm = css_highlights, .fold_kinds = &.{ "block", "keyframe_block_list", "declaration" }, .symbol_kinds = &.{} },
    .{ .lang = .html, .get = tree_sitter_html, .scm = html_highlights, .fold_kinds = &.{ "element", "script_element", "style_element" }, .symbol_kinds = &.{} },
};

/// 쿼리 캐시 칸 — 표와 **같은 색인**이다. 언어마다 하나이고 프로세스 수명이다(아래 `queryFor`).
var query_cells = [_]std.atomic.Value(?*c.TSQuery){.init(null)} ** grammar_table.len;

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
    /// **마지막 파싱에 실제로 준 예산.** 판정자가 「이 문서를 연 경로가 예산을 걸었는가」를
    /// **시간 없이** 물을 수 있어야 한다 — 그 질문을 「4ms 안에 못 끝냈다」로 재면 답이 기계
    /// 속도에 달리고, 빠른 기계에서 그 단언이 거짓이 된다(`ES21`·`ES22` 가 그랬다).
    /// `0` 은 「취소 안 함」이라는 뜻이다(`onProgress` 참조) — 상한 없음과 구별된다.
    budget_ns: u64 = 0,

    /// 문서 하나를 맡는다. **§5.3의 `init(문서 bytes, 언어)` 그대로다** — 언어만 받고 내용을
    /// 나중에 넣는 형태였다가 계약에 맞췄다(이름과 인자가 계약과 갈리면 문서를 읽고 코드를 찾는
    /// 사람이 두 번 헤맨다).
    ///
    /// grammar가 없으면 `null` — 그 문서는 무색이다(§5).
    pub fn init(source: []const u8, lang: Language, budget_ns: u64) ?Provider {
        const slot = slotFor(lang) orelse return null;
        const parser = c.ts_parser_new() orelse return null;
        if (!c.ts_parser_set_language(parser, slot.language)) {
            c.ts_parser_delete(parser);
            return null;
        }
        var self: Provider = .{ .parser = parser, .slot = slot };
        _ = self.setSourceBudgeted(source, budget_ns);
        return self;
    }

    pub fn deinit(self: *Provider) void {
        if (self.tree) |t| c.ts_tree_delete(t);
        c.ts_parser_delete(self.parser);
        self.* = undefined;
    }

    /// 한 번의 파싱이 **끝났는가**. `pending`이면 다음 프레임에 같은 인자로 다시 부른다 —
    /// tree-sitter가 **멈춘 자리부터 재개**한다(§2.1a · `ts_parser_reset` 계약).
    pub const ParseStatus = enum { done, pending };

    /// 예산을 든 파싱. 끊기면 **옛 트리를 그대로 둔다** — 그래야 그 사이 프레임이 직전 색으로 그린다
    /// (§2.1a의 저하 규율, 랩 계수의 `RowCache.hold`와 같은 모양).
    ///
    /// **`ts_parser_parse_string`을 못 쓴다.** 옵션을 받는 진입점은 `ts_parser_parse_with_options`
    /// 하나이고 그것은 `TSInput`(콜백)만 받는다 — 문자열 변형이 없다. 그래서 슬라이스를 한 번에
    /// 돌려주는 reader를 얹는다(조각내지 않는다 — 우리 버퍼는 이미 연속이다).
    fn parseBudgeted(self: *Provider, source: []const u8, old_tree: ?*c.TSTree, budget_ns: u64) ParseStatus {
        self.budget_ns = budget_ns;
        var ctx: ParseCtx = .{ .source = source, .deadline_ns = monotonicNs() + budget_ns, .budget_ns = budget_ns };
        const input: c.TSInput = .{
            .payload = &ctx,
            .read = readSlice,
            .encoding = c.TSInputEncodingUTF8,
            .decode = null,
        };
        const opts: c.TSParseOptions = .{ .payload = &ctx, .progress_callback = onProgress };
        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);
        if (next) |t| {
            if (self.tree) |old| {
                if (old != t) c.ts_tree_delete(old);
            }
            self.tree = t;
            return .done;
        }
        // **끊겼다.** 옛 트리는 그대로 두고(위 규율) 다음 프레임에 재개한다. 파서가 자기 안에
        // 진행 상태를 들고 있으므로 우리가 더 들 것은 "아직 끝나지 않았다" 하나다.
        return .pending;
    }

    const ParseCtx = struct {
        source: []const u8,
        deadline_ns: u64,
        budget_ns: u64,
    };

    /// 슬라이스를 통째로 돌려주는 reader. 끝을 넘으면 길이 0 — tree-sitter가 그것을 EOF로 읽는다.
    fn readSlice(payload: ?*anyopaque, byte_index: u32, _: c.TSPoint, bytes_read: [*c]u32) callconv(.c) [*c]const u8 {
        const ctx: *ParseCtx = @ptrCast(@alignCast(payload.?));
        if (byte_index >= ctx.source.len) {
            bytes_read.* = 0;
            return null;
        }
        bytes_read.* = @intCast(ctx.source.len - byte_index);
        return @ptrCast(ctx.source.ptr + byte_index);
    }

    /// 예산이 찼으면 `true` — tree-sitter가 파싱을 끊는다.
    ///
    /// **예산이 0이면 안 끊는다.** 0은 "예산 없음"이고(호출자가 동기 파싱을 원한다), 그때 이 콜백이
    /// 늘 참이면 파싱이 영영 안 끝난다.
    fn onProgress(state: [*c]c.TSParseState) callconv(.c) bool {
        const st = state orelse return false;
        const ctx: *ParseCtx = @ptrCast(@alignCast(st.*.payload.?));
        if (ctx.budget_ns == 0) return false;
        return monotonicNs() >= ctx.deadline_ns;
    }

    fn monotonicNs() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    /// 문서 내용이 **통째로** 바뀌었다(디스크에서 다시 읽기 등) — 전체를 다시 판다.
    ///
    /// **편집에는 `onEdit`을 쓴다.** 실측으로 81배 차이가 난다(154KB에서 5.3ms 대 65µs) —
    /// §5.3이 *"통지가 없으면 증분 파싱이 성립하지 않아 매번 전체 재파싱이 된다"*고 적은 그 자리다.
    ///
    /// **상한을 넘으면 트리를 버린다**(그 뒤 질의는 빈 목록이다).
    pub fn setSource(self: *Provider, source: []const u8) void {
        _ = self.setSourceBudgeted(source, 0);
    }

    /// 예산을 든 전체 파싱(§2.1a). `pending`이면 **같은 `source`로 다음 프레임에 다시 부른다**.
    ///
    /// **옛 트리는 시작할 때 버린다** — 내용이 통째로 바뀌었으므로 그것으로 그리면 다른 문서의 색이다.
    /// 그래서 이 경로가 pending인 동안은 **무색**이다(§5의 저하).
    pub fn setSourceBudgeted(self: *Provider, source: []const u8, budget_ns: u64) ParseStatus {
        if (self.tree) |t| {
            c.ts_tree_delete(t);
            self.tree = null;
        }
        if (source.len == 0 or source.len > max_parse_bytes) return .done;
        return self.parseBudgeted(source, null, budget_ns);
    }

    /// 편집 하나를 알린 뒤 **증분으로** 다시 판다. `source`는 **바뀐 뒤**의 내용이다.
    ///
    /// **행·열을 반드시 채워야 한다.** 처음에는 *"byte offset만으로도 된다"*고 적고 0을 넘겼는데,
    /// 실측이 그것을 반증했다 — 그렇게 하면 증분이 전체 재파싱보다 **더 느리다**(154KB에서 9.8ms
    /// 대 5ms, 618KB에서 30ms 대 21ms). tree-sitter가 어긋난 위치를 되맞추느라 더 일한다.
    pub fn onEdit(self: *Provider, source: []const u8, e: Edit) void {
        self.onEditBudgeted(source, e, 0);
    }

    /// 예산을 든 증분 파싱(§2.1a). 끊기면 **옛 트리로 계속 그린다** — 편집 전 색이지만 무색보다 낫고,
    /// 다음 프레임에 재개한다.
    pub fn onEditBudgeted(self: *Provider, source: []const u8, e: Edit, budget_ns: u64) void {
        const old_tree = self.tree orelse {
            _ = self.setSourceBudgeted(source, budget_ns);
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
        _ = self.parseBudgeted(source, old_tree, budget_ns);
    }

    /// 판 문서의 줄 수(트리 뿌리의 끝 행 + 1). **트리가 없으면 0**이다.
    ///
    /// 소비처가 *"내가 그리는 줄과 같은 문서인가"* 를 싸게 확인하는 자리다 — 접힘 범위를 구문 층으로
    /// 덮을 때 그 둘이 갈려 있으면 엉뚱한 줄에 화살표가 선다.
    pub fn lineCount(self: *Provider) usize {
        const tree = self.tree orelse return 0;
        return @as(usize, c.ts_node_end_point(c.ts_tree_root_node(tree)).row) + 1;
    }

    /// 문서 안 심볼 하나(native-editor-ui.md §7.5 — "이 파일 안에 무엇이 있나").
    ///
    /// **이름을 문자열로 복사하지 않는다** — 소스의 byte 범위만 든다. 호출자가 그 문서를 이미 들고
    /// 있으므로 자르면 되고, 복사하면 편집마다 그 문자열의 수명을 따로 관리해야 한다.
    pub const Symbol = struct {
        /// 이름의 byte 범위(`source[name_start..name_end]`).
        name_start: u32,
        name_end: u32,
        /// 심볼 **전체**의 byte 범위. 커서가 이 안에 있으면 그 심볼 안이다(체인 조회).
        start: u32,
        end: u32,
        /// 시작 줄(0-based) — 목록이 줄 번호를 보여 준다.
        start_row: u32,
        /// 중첩 깊이(0부터). 트리 모양을 그리는 데 쓴다.
        depth: u16,
        /// grammar 가 부른 노드 이름(`function_declaration` 등). 아이콘·분류에 쓴다 — 우리 어휘로
        /// 접는 것은 소비처의 몫이다(캡처→역할과 같은 규율).
        kind: []const u8,
    };

    /// 문서의 심볼을 **문서 순서**로 모은다. 없으면 빈 목록이다(§5의 저하).
    ///
    /// **정규식으로 긁지 않는다**(§7.5) — 언어마다 틀리고, 틀린 목록은 *"이 파일에 뭐가 있나"* 라는
    /// 질문에 **조용히 거짓말**을 한다. grammar 가 없으면 목록이 비는 것이 옳은 답이다.
    ///
    /// **이름은 `name` 필드에서 꺼낸다.** tree-sitter grammar 는 선언 노드에 그 필드를 두는 것이
    /// 관례다. 없으면 그 심볼은 **건너뛴다** — 이름 없는 항목을 목록에 넣으면 사용자가 고를 수 없다.
    pub fn symbols(self: *Provider, allocator: std.mem.Allocator, out: *std.ArrayList(Symbol)) void {
        out.clearRetainingCapacity();
        const tree = self.tree orelse return;
        const kinds = self.slot.symbol_kinds;
        if (kinds.len == 0) return;

        var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
        defer c.ts_tree_cursor_delete(&cursor);

        // 깊이는 **심볼 사이의** 중첩이다(노드 깊이가 아니다) — 클래스 안 메서드가 1이어야지, 그
        // 사이에 낀 `class_body` 같은 노드까지 세면 언어마다 숫자가 달라진다.
        var stack: [64]u32 = undefined; // 열린 심볼의 끝 offset
        var depth: usize = 0;

        while (true) {
            const node = c.ts_tree_cursor_current_node(&cursor);
            const sb = c.ts_node_start_byte(node);
            const eb = c.ts_node_end_byte(node);
            while (depth > 0 and stack[depth - 1] <= sb) depth -= 1;

            if (hasKind(kinds, c.ts_node_type(node)) and isSymbolWorthy(node)) {
                const name_node = symbolNameNode(node);
                if (!c.ts_node_is_null(name_node)) {
                    out.append(allocator, .{
                        .name_start = c.ts_node_start_byte(name_node),
                        .name_end = c.ts_node_end_byte(name_node),
                        .start = sb,
                        .end = eb,
                        .start_row = c.ts_node_start_point(node).row,
                        .depth = @intCast(@min(depth, std.math.maxInt(u16))),
                        .kind = std.mem.span(c.ts_node_type(node)),
                    }) catch return;
                    if (depth < stack.len) {
                        stack[depth] = eb;
                        depth += 1;
                    }
                }
            }

            if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) return;
            }
        }
    }

    /// 종류가 맞아도 **목록에 넣을 값인가**. §7.5 가 심볼로 부른 것은 *"함수·클래스·메서드·테스트
    /// 블록"* 이지 지역 변수가 아니다.
    ///
    /// **실측이 이 문을 낳았다.** zig 의 `variable_declaration` 을 종류 목록에 넣었더니 `_ = self;`
    /// 까지 심볼이 됐다(이름이 `_` 인 심볼이 체인의 가장 깊은 항목이 됐다). 그런데 그 종류를 통째로
    /// 빼면 `pub const Widget = struct {...}` — zig 에서 **타입을 선언하는 유일한 형태** — 가 사라진다.
    ///
    /// 그래서 **값이 컨테이너일 때만** 심볼로 본다. 그것이 §7.5 의 "클래스" 에 해당하는 자리다.
    fn isSymbolWorthy(node: c.TSNode) bool {
        const kind = std.mem.span(c.ts_node_type(node));
        if (!std.mem.eql(u8, kind, "variable_declaration")) return true;

        const count = c.ts_node_named_child_count(node);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const child_kind = std.mem.span(c.ts_node_type(c.ts_node_named_child(node, i)));
            inline for (.{ "struct_declaration", "enum_declaration", "union_declaration", "opaque_declaration", "error_set_declaration" }) |container| {
                if (std.mem.eql(u8, child_kind, container)) return true;
            }
        }
        return false;
    }

    /// 심볼의 **이름 노드**를 찾는다. 없으면 null 노드.
    ///
    /// **`name` 필드가 정본이지만 모든 grammar 가 달지는 않는다** — 실측: zig 는 `function_declaration`
    /// 에는 달고 `test_declaration`·`variable_declaration` 에는 안 단다(이름이 그냥 자식이다).
    /// 그래서 필드를 먼저 보고, 없으면 **이름처럼 생긴 첫 자식**을 쓴다.
    ///
    /// 목록을 넓게 두지 않는 이유: 아무 자식이나 이름으로 쓰면 `pub`·`const` 같은 키워드나 값이
    /// 이름 자리에 온다 — 사용자가 고를 수 없는 항목이 목록에 섞인다.
    fn symbolNameNode(node: c.TSNode) c.TSNode {
        const field = c.ts_node_child_by_field_name(node, "name", 4);
        if (!c.ts_node_is_null(field)) return field;

        // **C 계열은 이름이 `declarator` 사슬 안에 있다** — `function_definition → declarator
        // (function_declarator) → declarator (identifier)`. 실측으로 확인했고, 이 사슬이 없으면 C·C++ 가
        // 심볼 0개가 된다(`SYN25` 가 그것을 잡았다). 포인터 반환처럼 사슬이 더 깊은 판도 있어 반복한다.
        var decl = c.ts_node_child_by_field_name(node, "declarator", 10);
        var hops: usize = 0;
        while (!c.ts_node_is_null(decl) and hops < 8) : (hops += 1) {
            const kind = std.mem.span(c.ts_node_type(decl));
            if (std.mem.endsWith(u8, kind, "identifier")) return decl;
            decl = c.ts_node_child_by_field_name(decl, "declarator", 10);
        }

        const count = c.ts_node_named_child_count(node);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const child = c.ts_node_named_child(node, i);
            const kind = std.mem.span(c.ts_node_type(child));
            if (std.mem.endsWith(u8, kind, "identifier")) return child;
            // zig `test "이름"` 처럼 문자열이 이름인 판. **따옴표를 뺀 안쪽**을 쓴다 — 목록에 따옴표가
            // 보이면 그것은 이름이 아니라 리터럴이다.
            if (std.mem.eql(u8, kind, "string")) {
                const inner_count = c.ts_node_named_child_count(child);
                if (inner_count > 0) {
                    const inner = c.ts_node_named_child(child, 0);
                    if (std.mem.eql(u8, std.mem.span(c.ts_node_type(inner)), "string_content")) return inner;
                }
                return child;
            }
        }
        return c.ts_node_named_child(node, count); // 범위를 넘는 색인 = null 노드
    }

    /// 커서 offset 을 품는 심볼 체인 — **루트부터 가장 깊은 것까지**. 담은 개수를 돌려준다.
    ///
    /// **조회이지 저장이 아니다**(§7.5). 체인을 따로 캐시하면 편집과 파싱 두 축으로 무효화해야 하고,
    /// 그 값은 이미 문서 순서로 담긴 목록에서 싸게 나온다.
    ///
    /// **목록이 문서 순서라는 것을 쓴다.** 시작 offset 이 커서를 넘어선 뒤로는 볼 필요가 없고, 그
    /// 전까지 중 커서를 품는 것만 모으면 그것이 곧 체인이다(바깥 심볼이 먼저 나오므로 순서도 맞다).
    pub fn chainAt(list: []const Symbol, offset: u32, out: []usize) usize {
        var n: usize = 0;
        for (list, 0..) |sym, i| {
            if (sym.start > offset) break;
            if (offset < sym.end) {
                if (n >= out.len) break;
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// 접을 수 있는 **줄 범위** 하나(§4 — 접힘의 tree-sitter 층).
    pub const FoldSpan = struct {
        /// 접어도 보이는 줄(화살표가 여기 선다).
        start_row: u32,
        /// 접으면 숨는 마지막 줄(포함).
        end_row: u32,
    };

    /// 트리에서 접을 범위를 뽑는다. **없으면 빈 목록**이다(§5의 저하와 같은 규율).
    ///
    /// **쿼리를 쓰지 않는다.** grammar 열여덟 중 `queries/folds.scm` 을 가진 것은 **zig 하나뿐**이다
    /// (nvim 계열은 접힘 쿼리를 grammar 밖에서 따로 관리한다). 그 하나만 쿼리로 접으면 언어마다
    /// 동작이 갈리고, 우리가 열여섯 벌을 적어 두면 grammar 를 올릴 때마다 조용히 낡는다 — 색 쿼리를
    /// **grammar 가 소유하게** 둔 것과 같은 이유로 그 길을 안 간다.
    ///
    /// 대신 **구조로 판단한다**: 두 줄 이상에 걸친 노드가 접을 수 있는 것이다. 언어별 자료가 0이고
    /// 열여덟에 그대로 적용된다. §4가 *"들여쓰기로는 잡히지 않는 것(여러 줄 인자 목록, 배열
    /// 리터럴)이 여기서 접힌다"* 고 적은 것이 정확히 이 규칙으로 잡힌다 — 그것들이 여러 줄 노드다.
    ///
    /// **시작 줄마다 하나만 남긴다**(가장 긴 것). gutter 화살표가 줄마다 하나이므로 그 축과 같아야
    /// 하고, 안 그러면 같은 줄에 후보가 여럿이라 "이 화살표가 무엇을 접는가" 가 정해지지 않는다.
    pub fn foldSpans(self: *Provider, allocator: std.mem.Allocator, out: *std.ArrayList(FoldSpan)) void {
        out.clearRetainingCapacity();
        const tree = self.tree orelse return;

        // **접을 종류가 없으면 여기서 끝난다** — 그 언어는 들여쓰기 층이 그대로 산다(§4.1f).
        const kinds = self.slot.fold_kinds;
        if (kinds.len == 0) return;

        var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
        defer c.ts_tree_cursor_delete(&cursor);

        // 시작 줄 → 그 줄에서 가장 멀리 가는 끝 줄.
        var best: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer best.deinit(allocator);

        // 깊이 우선으로 전부 훑는다. 재귀 대신 커서를 쓰는 이유는 **깊이가 문서에 달렸기** 때문이다 —
        // 중첩이 깊은 파일에서 스택이 터지면 그것은 편집기가 죽는 것이다(§5.3의 "적대적일 수 있다").
        while (true) {
            const node = c.ts_tree_cursor_current_node(&cursor);
            const sp = c.ts_node_start_point(node);
            const ep = c.ts_node_end_point(node);
            if (ep.row > sp.row and hasKind(kinds, c.ts_node_type(node))) {
                const gop = best.getOrPut(allocator, sp.row) catch return;
                if (!gop.found_existing or gop.value_ptr.* < ep.row) gop.value_ptr.* = ep.row;
            }

            if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) return sortInto(allocator, &best, out);
            }
        }
    }

    fn hasKind(kinds: []const []const u8, raw: [*c]const u8) bool {
        const name = std.mem.span(raw);
        for (kinds) |k| {
            if (std.mem.eql(u8, k, name)) return true;
        }
        return false;
    }

    /// 시작 줄 오름차순으로 담는다 — 소비처(접힘 층)가 그 순서를 전제한다.
    fn sortInto(
        allocator: std.mem.Allocator,
        best: *std.AutoHashMapUnmanaged(u32, u32),
        out: *std.ArrayList(FoldSpan),
    ) void {
        out.ensureTotalCapacity(allocator, best.count()) catch return;
        var it = best.iterator();
        while (it.next()) |e| out.appendAssumeCapacity(.{ .start_row = e.key_ptr.*, .end_row = e.value_ptr.* });
        std.mem.sort(FoldSpan, out.items, {}, struct {
            fn lt(_: void, a: FoldSpan, b: FoldSpan) bool {
                return a.start_row < b.start_row;
            }
        }.lt);
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
        var prov = Provider.init(src1, .zig, 0) orelse return error.NoProvider;
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

    var prov = Provider.init(src1, .zig, 0) orelse return error.NoProvider;
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

    var prov = Provider.init(before, .zig, 0) orelse return error.NoProvider;
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

// ── 예산 판정(§2.1a — 끊고 재개한다) ────────────────────────────────────────────

/// 판정자용 큰 문서. 내용이 조밀할수록 파싱이 비싸므로(§2.1a의 실측 근거 ⑵) 조밀하게 만든다.
fn denseSource(allocator: std.mem.Allocator, lines: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < lines) : (i += 1) {
        try buf.appendSlice(allocator, "pub fn f() void { const s = \"abc\"; _ = s; } // c\n");
    }
    return buf.toOwnedSlice(allocator);
}

test "SYN15 예산이 파싱을 끊는다 — 그리고 재개해서 끝난다" {
    // **§2.1a의 심장이다.** 예산이 안 끊으면 큰 파일이 프레임을 통째로 먹고, 재개가 안 되면
    // 색이 영영 안 온다. 둘 다 화면에만 나타나는 종류라 값으로 못박는다.
    const allocator = std.testing.allocator;
    const src = try denseSource(allocator, 3000);
    defer allocator.free(src);

    var warm: std.ArrayList(Span) = .empty;
    defer warm.deinit(allocator);
    highlights(allocator, .zig, "const x = 1;", &warm);

    var prov = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();

    // 1µs 예산 — 이 크기에서는 반드시 끊긴다.
    var status = prov.setSourceBudgeted(src, 1_000);
    try std.testing.expectEqual(Provider.ParseStatus.pending, status);
    try std.testing.expect(prov.tree == null); // 끊긴 동안은 트리가 없다 → 무색(§5)

    // 재개한다. **같은 인자로 다시 부르는 것**이 계약이다(ts_parser_reset 주석).
    var rounds: usize = 0;
    while (status == .pending and rounds < 10_000) : (rounds += 1) {
        status = prov.setSourceBudgeted(src, 1_000);
    }
    try std.testing.expectEqual(Provider.ParseStatus.done, status);
    try std.testing.expect(rounds > 0); // 한 번에 안 끝났다 = 실제로 나뉘었다
    try std.testing.expect(prov.tree != null);
}

test "SYN16 나눠 판 결과가 한 번에 판 것과 같다 — 재개가 트리를 바꾸지 않는다" {
    // **이것이 §2.1a의 전제다.** 헤더는 재개를 약속하지만, 이어 판 결과가 한 번에 판 것과 다르면
    // 예산에 따라 색이 달라진다 — 기계와 부하에 따라 화면이 달라진다는 뜻이고 그건 못 쓴다.
    const allocator = std.testing.allocator;
    const src = try denseSource(allocator, 1200);
    defer allocator.free(src);

    var whole: std.ArrayList(Span) = .empty;
    defer whole.deinit(allocator);
    var split: std.ArrayList(Span) = .empty;
    defer split.deinit(allocator);

    var a = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer a.deinit();
    try std.testing.expectEqual(Provider.ParseStatus.done, a.setSourceBudgeted(src, 0)); // 예산 없음 = 한 번에
    a.spansForRange(allocator, src, .{ .start = 0, .end = @intCast(src.len) }, &whole);
    try std.testing.expect(whole.items.len > 0);

    var b = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer b.deinit();
    var status = Provider.ParseStatus.pending;
    var rounds: usize = 0;
    while (status == .pending and rounds < 100_000) : (rounds += 1) {
        status = b.setSourceBudgeted(src, 1_000);
    }
    try std.testing.expectEqual(Provider.ParseStatus.done, status);
    try std.testing.expect(rounds > 1); // 실제로 나뉘었다
    b.spansForRange(allocator, src, .{ .start = 0, .end = @intCast(src.len) }, &split);

    try std.testing.expectEqual(whole.items.len, split.items.len);
    for (whole.items, split.items) |w, sp| {
        try std.testing.expectEqual(w.start, sp.start);
        try std.testing.expectEqual(w.end, sp.end);
        try std.testing.expectEqualStrings(w.capture, sp.capture);
    }
}

test "SYN17 예산 0은 안 끊는다 — 기존 동기 경로가 그대로다" {
    // `setSource`·`onEdit`(예산 없는 얼굴)이 지금까지대로 한 번에 끝나야 한다. 이 판정자가 없으면
    // 예산 장치가 동기 경로까지 끊어 버리는 회귀가 조용히 지나간다.
    const allocator = std.testing.allocator;
    const src = try denseSource(allocator, 800);
    defer allocator.free(src);

    var prov = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    try std.testing.expectEqual(Provider.ParseStatus.done, prov.setSourceBudgeted(src, 0));
    try std.testing.expect(prov.tree != null);

    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    prov.spansForRange(allocator, src, .{ .start = 0, .end = 200 }, &spans);
    try std.testing.expect(spans.items.len > 0);
}

test "SYN18 번들한 grammar 열여덟이 전부 실제로 색을 낸다" {
    // **링크만 되고 파싱이 안 되면 그 언어만 조용히 무색이다.** grammar 진입점 이름이 틀렸거나
    // 쿼리가 grammar와 안 맞으면(버전 어긋남) 정확히 그렇게 된다 — 화면에만 나타난다.
    // 표에 든 **모든** 언어를 한 줄씩 태워 그 자리를 막는다.
    const allocator = std.testing.allocator;
    const samples = [_]struct { lang: Language, src: []const u8 }{
        .{ .lang = .zig, .src = "const x = \"a\"; // c\n" },
        .{ .lang = .json, .src = "{\"a\": 1, \"b\": \"s\"}\n" },
        .{ .lang = .markdown, .src = "# 제목\n\n본문 `코드`\n" },
        .{ .lang = .javascript, .src = "const x = 'a'; // c\n" },
        .{ .lang = .typescript, .src = "const x: string = 'a'; // c\n" },
        .{ .lang = .tsx, .src = "const A = () => <div/>; // c\n" },
        .{ .lang = .c, .src = "int main(void) { return 0; } // c\n" },
        .{ .lang = .cpp, .src = "#include <vector>\nint main() { return 0; }\n" },
        .{ .lang = .python, .src = "def f(x):\n    return \"a\"  # c\n" },
        .{ .lang = .go, .src = "package main\nfunc main() { _ = \"a\" }\n" },
        .{ .lang = .rust, .src = "fn main() { let x = \"a\"; } // c\n" },
        .{ .lang = .java, .src = "class A { void f() { String s = \"a\"; } }\n" },
        .{ .lang = .ruby, .src = "def f\n  x = \"a\" # c\nend\n" },
        .{ .lang = .php, .src = "<?php\n$x = \"a\"; // c\n" },
        .{ .lang = .kotlin, .src = "fun main() { val x = \"a\" } // c\n" },
        .{ .lang = .bash, .src = "x=\"a\" # c\necho $x\n" },
        .{ .lang = .css, .src = "a { color: #fff; } /* c */\n" },
        .{ .lang = .html, .src = "<div class=\"a\">t</div>\n" },
    };
    // 표에 든 언어 수와 샘플 수가 같아야 한다 — grammar를 늘리고 샘플을 안 더하면 그 언어가 안 돈다.
    try std.testing.expectEqual(grammar_table.len, samples.len);

    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(allocator);
    var failed: usize = 0;
    for (samples) |s| {
        highlights(allocator, s.lang, s.src, &spans);
        if (spans.items.len == 0) {
            std.debug.print("grammar '{s}'가 색을 하나도 못 냈다 — 진입점·쿼리를 확인하라\n", .{@tagName(s.lang)});
            failed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "SYN19 구문 접힘이 들여쓰기가 못 잡는 것을 잡는다 (§4)" {
    // §4: *"들여쓰기로는 잡히지 않는 것(여러 줄 인자 목록, 배열 리터럴)이 여기서 접힌다"*.
    // **그 문장을 값으로 고정한다** — 구조 규칙(여러 줄 노드)이 실제로 그 둘을 잡는지 본다.
    const allocator = std.testing.allocator;
    const src =
        \\const items = .{
        \\    1,
        \\    2,
        \\};
        \\pub fn f(
        \\    a: u32,
        \\    b: u32,
        \\) void {
        \\    _ = a;
        \\}
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer spans.deinit(allocator);
    prov.foldSpans(allocator, &spans);

    // ⑴ 배열 리터럴(0행에서 시작해 3행까지)
    var literal = false;
    // ⑵ 여러 줄 인자 목록(4행에서 시작)
    var arg_list = false;
    for (spans.items) |sp| {
        if (sp.start_row == 0 and sp.end_row >= 3) literal = true;
        if (sp.start_row == 4 and sp.end_row >= 7) arg_list = true;
    }
    if (!literal or !arg_list) {
        std.debug.print("접힘 범위 {d}개: ", .{spans.items.len});
        for (spans.items) |sp| std.debug.print("{d}-{d} ", .{ sp.start_row, sp.end_row });
        std.debug.print("\n", .{});
    }
    try std.testing.expect(literal);
    try std.testing.expect(arg_list);

    // ⑶ **시작 줄마다 하나만** — gutter 화살표가 줄마다 하나다.
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);
    for (spans.items) |sp| {
        const gop = try seen.getOrPut(allocator, sp.start_row);
        try std.testing.expect(!gop.found_existing);
    }

    // ⑷ 시작 줄 오름차순(소비처가 전제한다)
    var prev: u32 = 0;
    for (spans.items) |sp| {
        try std.testing.expect(sp.start_row >= prev);
        prev = sp.start_row;
    }
}

test "SYN20 트리가 없으면 빈 목록이다 — 실패는 저하다 (§5)" {
    const allocator = std.testing.allocator;
    var prov = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer spans.deinit(allocator);
    prov.foldSpans(allocator, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "SYN21 언어마다 접을 것이 있는 표본에서 범위가 나온다 — 종류 이름이 낡으면 여기서 깨진다" {
    // **종류 목록은 우리가 소유한다**(§4.1f). grammar 가 노드 이름을 바꾸면 그 언어에서 범위가
    // **0이 되는데 아무 데도 안 나타난다** — 화살표가 조용히 사라질 뿐이다. 그 그물이 이것이다.
    //
    // 표본은 "접을 것이 분명히 있는" 모양으로 골랐다(함수 몸통·객체·절).
    const allocator = std.testing.allocator;
    const samples = [_]struct { lang: Language, src: []const u8 }{
        .{ .lang = .zig, .src = "pub fn f() void {\n    const a = 1;\n    _ = a;\n}\n" },
        .{ .lang = .json, .src = "{\n  \"a\": 1,\n  \"b\": 2\n}\n" },
        .{ .lang = .markdown, .src = "# 제목\n\n본문\n\n## 다음\n\n본문\n" },
        .{ .lang = .javascript, .src = "function f() {\n  let a = 1;\n  return a;\n}\n" },
        .{ .lang = .typescript, .src = "function f(): number {\n  let a = 1;\n  return a;\n}\n" },
        .{ .lang = .tsx, .src = "function f() {\n  const a = 1;\n  return a;\n}\n" },
        .{ .lang = .c, .src = "int f(void) {\n  int a = 1;\n  return a;\n}\n" },
        .{ .lang = .cpp, .src = "int f() {\n  int a = 1;\n  return a;\n}\n" },
        .{ .lang = .python, .src = "def f():\n    a = 1\n    return a\n" },
        .{ .lang = .go, .src = "package m\n\nfunc f() int {\n\ta := 1\n\treturn a\n}\n" },
        .{ .lang = .rust, .src = "fn f() -> i32 {\n    let a = 1;\n    a\n}\n" },
        .{ .lang = .java, .src = "class A {\n  int f() {\n    return 1;\n  }\n}\n" },
        .{ .lang = .ruby, .src = "def f\n  a = 1\n  a\nend\n" },
        .{ .lang = .php, .src = "<?php\nfunction f() {\n  $a = 1;\n  return $a;\n}\n" },
        .{ .lang = .kotlin, .src = "fun f(): Int {\n    val a = 1\n    return a\n}\n" },
        .{ .lang = .bash, .src = "f() {\n  a=1\n  echo $a\n}\n" },
        .{ .lang = .css, .src = "a {\n  color: red;\n  display: block;\n}\n" },
        .{ .lang = .html, .src = "<div>\n  <p>t</p>\n</div>\n" },
    };
    try std.testing.expectEqual(grammar_table.len, samples.len);

    var spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer spans.deinit(allocator);
    var empty: usize = 0;
    for (samples) |s| {
        var prov = Provider.init(s.src, s.lang, 0) orelse {
            std.debug.print("provider 없음: {s}\n", .{@tagName(s.lang)});
            empty += 1;
            continue;
        };
        defer prov.deinit();
        prov.foldSpans(allocator, &spans);
        if (spans.items.len == 0) {
            std.debug.print("'{s}' 에서 접을 범위가 0 — 종류 이름을 확인하라\n", .{@tagName(s.lang)});
            empty += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), empty);
}

test "SYN22 산문은 과하게 접지 않는다 — 문단·목록 항목에 화살표가 안 선다" {
    // **실측이 이 판정자를 낳았다**(§4.1f): "두 줄 이상 노드를 다 접는" 규칙에서 markdown 화살표의
    // 76%가 `list_item`·`paragraph` 였다. 종류 목록이 그것을 거른다.
    const allocator = std.testing.allocator;
    const src =
        \\# 제목
        \\
        \\여러 줄에
        \\걸친 문단이다.
        \\
        \\- 항목 하나가
        \\  두 줄이다
        \\- 항목 둘도
        \\  두 줄이다
        \\
    ;
    var prov = Provider.init(src, .markdown, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer spans.deinit(allocator);
    prov.foldSpans(allocator, &spans);

    // **문단(2행)과 두 번째 목록 항목(7행)에는 화살표가 없어야 한다.**
    //
    // 5행은 첫 목록 항목이자 **목록 전체가 시작하는 자리**다 — 항목만 접는 것과 목록을 접는 것을
    // 시작 줄로는 못 가른다(같은 줄에서 시작한다). 그래서 그 줄은 "있으면 안 된다" 가 아니라
    // **"목록 끝까지 덮는가"** 로 본다. 항목 하나만 접으면 6행에서 끝난다.
    var list_end: ?u32 = null;
    for (spans.items) |sp| {
        if (sp.start_row == 2 or sp.start_row == 7) {
            std.debug.print("산문에 화살표가 섰다: {d}행\n", .{sp.start_row});
            return error.ProseFolded;
        }
        if (sp.start_row == 5) list_end = sp.end_row;
    }
    if (list_end) |e| try std.testing.expect(e >= 8); // 항목이 아니라 목록 전체다
    // 그리고 **절**은 접힌다 — 아무것도 안 접으면 기능이 없는 것이다.
    try std.testing.expect(spans.items.len > 0);
}

test "SYN23 심볼 목록이 문서 순서로 서고 이름·범위·깊이가 맞는다 (§7.5)" {
    // §7.5: *"심볼 목록은 하나, 표시는 여럿"* — 그 하나가 이것이다. breadcrumb·오버레이·아웃라인이
    // 각자 심볼을 구하지 않으므로, 이 목록이 틀리면 셋이 함께 틀린다.
    const allocator = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\
        \\pub fn outer() void {
        \\    inner();
        \\}
        \\
        \\test "이름 있는 테스트" {
        \\    try inner();
        \\}
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var list: std.ArrayList(Provider.Symbol) = .empty;
    defer list.deinit(allocator);
    prov.symbols(allocator, &list);

    try std.testing.expect(list.items.len >= 2);

    // 문서 순서 — 소비처가 이분 탐색·체인 조회에서 그것을 전제한다.
    var prev: u32 = 0;
    for (list.items) |sym| {
        try std.testing.expect(sym.start >= prev);
        prev = sym.start;
        // 범위가 뒤집히지 않는다.
        try std.testing.expect(sym.end > sym.start);
        // 이름이 심볼 범위 안에 있다.
        try std.testing.expect(sym.name_start >= sym.start and sym.name_end <= sym.end);
        try std.testing.expect(sym.name_end > sym.name_start);
    }

    // 이름이 실제로 그 글자다 — byte 범위만 들고 다니므로 그 계약이 깨지면 목록이 엉뚱한 글자를 낸다.
    var found_outer = false;
    for (list.items) |sym| {
        if (std.mem.eql(u8, src[sym.name_start..sym.name_end], "outer")) found_outer = true;
    }
    if (!found_outer) {
        std.debug.print("심볼 {d}개: ", .{list.items.len});
        for (list.items) |sym| std.debug.print("{s}({s}) ", .{ src[sym.name_start..sym.name_end], sym.kind });
        std.debug.print("\n", .{});
    }
    try std.testing.expect(found_outer);

    // **깊이를 정확히 못박는다.** "0 이상" 같은 느슨한 성질은 깊이를 통째로 0으로 만들어도(SM3),
    // 깊이 스택을 안 닫아 단조 증가시켜도(SM8) 통과한다 — 둘 다 breadcrumb 을 망가뜨리는데.
    // 여기 둘은 **형제**이므로 **둘 다 0** 이어야 한다.
    for (list.items) |sym| {
        try std.testing.expectEqual(@as(u16, 0), sym.depth);
    }
}

test "SYN24 커서가 어느 심볼 안에 있는지 조회한다 — 체인은 바깥부터다 (§7.5)" {
    // §7.5: *"체인은 커서 offset 을 품는 가장 깊은 심볼부터 루트까지이며 편집마다 다시 구한다"* —
    // **조회이지 저장이 아니다**. 그 성질을 값으로 고정한다.
    const allocator = std.testing.allocator;
    // **커서 뒤에 형제 심볼이 있어야 한다.** 이것이 없으면 `chainAt` 이 offset 을 지나서도 계속
    // 훑는 결함(break 제거)이 **표본상 구별되지 않는다** — 실제로 뮤테이션에서 살아남았다.
    const src =
        \\pub const Widget = struct {
        \\    pub fn draw(self: Widget) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\pub fn after() void {}
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var list: std.ArrayList(Provider.Symbol) = .empty;
    defer list.deinit(allocator);
    prov.symbols(allocator, &list);
    try std.testing.expect(list.items.len >= 2);

    // `_ = self;` 안쪽 offset — 바깥(Widget)과 안쪽(draw) 둘 다 품는다.
    const inside = @as(u32, @intCast(std.mem.indexOf(u8, src, "_ = self").?));
    var chain: [8]usize = undefined;
    const n = Provider.chainAt(list.items, inside, &chain);
    try std.testing.expect(n >= 2);

    // **체인은 정확히 둘이다** — `after` 는 커서보다 뒤에서 시작하므로 들어오면 안 된다.
    try std.testing.expectEqual(@as(usize, 2), n);

    // 체인의 모든 항목이 실제로 커서를 품는다.
    for (chain[0..n]) |ci| {
        try std.testing.expect(list.items[ci].start <= inside and inside < list.items[ci].end);
    }

    // **바깥부터다** — breadcrumb 이 `Widget > draw` 순으로 그린다. 깊이도 정확히 본다.
    try std.testing.expectEqual(@as(u16, 0), list.items[chain[0]].depth);
    try std.testing.expectEqual(@as(u16, 1), list.items[chain[1]].depth);
    try std.testing.expectEqualStrings("Widget", src[list.items[chain[0]].name_start..list.items[chain[0]].name_end]);
    try std.testing.expectEqualStrings("draw", src[list.items[chain[n - 1]].name_start..list.items[chain[n - 1]].name_end]);

    // **형제는 자기 자리에서만 잡힌다** — `after` 안에서는 체인이 그것 하나다.
    const in_after = @as(u32, @intCast(std.mem.indexOf(u8, src, "after() void").?));
    const m = Provider.chainAt(list.items, in_after, &chain);
    try std.testing.expectEqual(@as(usize, 1), m);
    try std.testing.expectEqualStrings("after", src[list.items[chain[0]].name_start..list.items[chain[0]].name_end]);

    // 어느 심볼에도 안 든 자리(문서 맨 끝)는 빈 체인이다.
    try std.testing.expectEqual(@as(usize, 0), Provider.chainAt(list.items, @intCast(src.len), &chain));
}

test "SYN25 심볼 종류 목록이 실재하는 노드 이름이다 — 언어마다 하나 이상 나온다" {
    // **종류 이름이 낡으면 그 언어만 조용히 목록이 빈다.** `SYN21`(접힘)과 같은 그물이고, 같은
    // 이유로 필요하다 — grammar 를 올릴 때 이름이 바뀌면 화면에서만 드러난다.
    //
    // 목록이 **일부러 빈** 언어(json·css·html·markdown)는 여기서 뺀다 — 그 사실은 표의 주석이 갖는다.
    const allocator = std.testing.allocator;
    const samples = [_]struct { lang: Language, src: []const u8, want: []const u8 }{
        .{ .lang = .zig, .src = "pub fn f() void {}\n", .want = "f" },
        .{ .lang = .javascript, .src = "function f() {}\n", .want = "f" },
        .{ .lang = .typescript, .src = "function f(): void {}\n", .want = "f" },
        .{ .lang = .tsx, .src = "function f() {}\n", .want = "f" },
        .{ .lang = .c, .src = "int f(void) { return 0; }\n", .want = "f" },
        .{ .lang = .cpp, .src = "int f() { return 0; }\n", .want = "f" },
        .{ .lang = .python, .src = "def f():\n    pass\n", .want = "f" },
        .{ .lang = .go, .src = "package m\nfunc f() {}\n", .want = "f" },
        .{ .lang = .rust, .src = "fn f() {}\n", .want = "f" },
        .{ .lang = .java, .src = "class A { void f() {} }\n", .want = "A" },
        .{ .lang = .ruby, .src = "def f\nend\n", .want = "f" },
        .{ .lang = .php, .src = "<?php\nfunction f() {}\n", .want = "f" },
        .{ .lang = .kotlin, .src = "fun f() {}\n", .want = "f" },
        .{ .lang = .bash, .src = "f() {\n  echo 1\n}\n", .want = "f" },
    };
    // **표본이 없는 언어는 종류를 선언할 수 없다.** 이것이 없으면 "종류는 적어 뒀는데 목록은 늘
    // 비는" 상태가 조용히 산다 — markdown 의 `section` 이 정확히 그랬다(이름 노드가 없다). 뮤테이션에서
    // 그것을 되살렸는데 아무 판정자도 안 죽었다. 선언과 실제를 잇는 것은 이 한 줄이다.
    for (grammar_table) |slot| {
        if (slot.symbol_kinds.len == 0) continue;
        var covered = false;
        for (samples) |s| {
            if (s.lang == slot.lang) covered = true;
        }
        if (!covered) {
            std.debug.print("'{s}' 가 심볼 종류를 선언했는데 표본이 없다 — 목록이 늘 비어도 아무도 모른다\n", .{@tagName(slot.lang)});
            return error.SymbolKindsWithoutSample;
        }
    }

    var list: std.ArrayList(Provider.Symbol) = .empty;
    defer list.deinit(allocator);
    var bad: usize = 0;
    for (samples) |s| {
        var prov = Provider.init(s.src, s.lang, 0) orelse {
            std.debug.print("provider 없음: {s}\n", .{@tagName(s.lang)});
            bad += 1;
            continue;
        };
        defer prov.deinit();
        prov.symbols(allocator, &list);
        var found = false;
        for (list.items) |sym| {
            if (std.mem.eql(u8, s.src[sym.name_start..sym.name_end], s.want)) found = true;
        }
        if (!found) {
            std.debug.print("'{s}' 에서 심볼 '{s}' 를 못 찾았다 (심볼 {d}개) — 종류 이름을 확인하라\n", .{ @tagName(s.lang), s.want, list.items.len });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "SYN26 예산에 끊긴 전체 파싱 동안 심볼 목록은 비어 있다 — 반쯤 판 트리로 답하지 않는다" {
    // **이 성질은 검사가 아니라 구조가 준다** — `setSourceBudgeted` 가 시작할 때 옛 트리를 버리므로
    // pending 동안 트리가 없고, `symbols()` 는 트리가 없으면 빈 목록을 낸다. 구조가 바뀌면(예: 옛
    // 트리를 살려 두도록) 이 판정자가 죽는다. 그때 문서(§7.5)도 같이 고쳐야 한다.
    const allocator = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(allocator);
    var i: usize = 0;
    while (i < 400) : (i += 1) try src.print(allocator, "pub fn f{d}() void {{ _ = {d}; }}\n", .{ i, i });

    var prov = Provider.init("", .zig, 0) orelse return error.SkipZigTest;
    defer prov.deinit();

    var list: std.ArrayList(Provider.Symbol) = .empty;
    defer list.deinit(allocator);

    // 1ns 예산 = 사실상 첫 콜백에서 끊긴다.
    var status = prov.setSourceBudgeted(src.items, 1);
    if (status == .done) return error.SkipZigTest; // 너무 빨라 못 끊었다 — 이 판정자가 잴 것이 없다

    prov.symbols(allocator, &list);
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), Provider.chainAt(list.items, 0, &.{}));

    // 다 끝나면 목록이 돌아온다 — "영영 빈다" 가 아니라 "끝날 때까지 빈다" 임을 못박는다.
    var rounds: usize = 0;
    while (status == .pending and rounds < 100_000) : (rounds += 1) {
        status = prov.setSourceBudgeted(src.items, 0);
    }
    try std.testing.expectEqual(Provider.ParseStatus.done, status);
    prov.symbols(allocator, &list);
    try std.testing.expectEqual(@as(usize, 400), list.items.len);
}

test "SYN27 이름 없는 노드는 심볼이 아니다 — zig 익명 test 블록이 목록에 안 든다" {
    // **이름 없는 심볼은 심볼이 아니다**(§7.5) — 목록의 항목은 이름을 가져야 클릭할 수 있다.
    // 그 규율은 `symbolNameNode` 가 null 을 내면 건너뛰는 한 줄인데, **표본에 이름 없는 노드가
    // 없으면 그 줄을 지워도 아무 판정자가 안 죽는다**(뮤테이션에서 실제로 살아남았다).
    // zig 의 익명 `test { }` 가 그 모양이다 — `test_declaration` 인데 이름 문자열이 없다.
    const allocator = std.testing.allocator;
    const src =
        \\test {
        \\    _ = 1;
        \\}
        \\
        \\test "이름 있다" {
        \\    _ = 2;
        \\}
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var list: std.ArrayList(Provider.Symbol) = .empty;
    defer list.deinit(allocator);
    prov.symbols(allocator, &list);

    // 이름 있는 것 하나만 남는다.
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("이름 있다", src[list.items[0].name_start..list.items[0].name_end]);

    // 그리고 **어느 항목도 빈 이름을 갖지 않는다** — 범위가 [0,0) 인 유령이 끼면 여기서 죽는다.
    for (list.items) |sym| {
        try std.testing.expect(sym.name_end > sym.name_start);
        try std.testing.expect(sym.name_start >= sym.start);
    }

    // 익명 블록 안에서는 체인이 비어 있다 — 심볼이 아니므로.
    const in_anon = @as(u32, @intCast(std.mem.indexOf(u8, src, "_ = 1").?));
    var chain: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), Provider.chainAt(list.items, in_anon, &chain));
}
