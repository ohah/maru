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
    /// 언어 — 괄호 색 규칙(§5.1d `bracketRuleFor`)이 가른다.
    lang: Language = .other,
    /// **글이 괄호를 담는 언어인가**(visual-mapping §5.1b ⓑ). 참이면 긴 잎(HTML `text`) 속 괄호 글자를 그 잎 안에서 짝짓는다. 거짓이면 긴 잎
    /// 속 괄호는 문자열·주석에 적힌 글자다(코드 괄호는 늘 자기 토큰이다). **마크다운은 거짓이다** — 블록 grammar 가 본문·목록·코드 펜스의
    /// 괄호를 이름 없는 토큰으로 낸다(실측 `SYN45`), 그래서 ⓐ 갈래가 잡는다.
    prose_brackets: bool = false,
};

/// **지원 언어의 관문은 이 함수 하나다.** 처음에는 grammar를 고르는 `switch`와 쿼리 캐시를 고르는
/// `switch`가 따로 있었는데, 적대적 검증이 그 둘이 **서로 가려 준다**는 것을 보였다 — 앞 관문을
/// 열어 `.other`도 zig grammar로 파도록 뒤집었는데 뒤 관문이 막아 판정자가 **아무 차이도 못 봤다**
/// (뮤턴트 생존). 규칙이 두 곳에 있으면 갈리고, 갈려도 안 보인다. 늘리는 자리도 여기 하나다.
fn slotFor(lang: Language) ?Slot {
    inline for (grammar_table, 0..) |g, i| {
        if (g.lang == lang) return .{ .language = g.get(), .query_cell = &query_cells[i], .scm = g.scm, .fold_kinds = g.fold_kinds, .symbol_kinds = g.symbol_kinds, .prose_brackets = g.prose_brackets, .lang = lang };
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
    /// 글이 괄호를 담는 언어(§5.1b ⓑ) — `Slot.prose_brackets` 로 옮겨진다.
    prose_brackets: bool = false,
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
    .{ .lang = .html, .get = tree_sitter_html, .scm = html_highlights, .fold_kinds = &.{ "element", "script_element", "style_element" }, .symbol_kinds = &.{}, .prose_brackets = true },
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
    /// **트리 세대** — 트리가 바뀔 때마다(파싱이 끝나거나 버릴 때) 는다. 트리에서 파생한 것을 들고 있는 쪽(괄호 목록 §5.1d)이 「내가 본 트리가
    /// 지금 트리인가 · 파싱을 하나 놓쳤는가」를 이 수 하나로 가른다 — 놓친 채 부분만 고치면 목록이 조용히 틀린다.
    tree_gen: u64 = 0,
    /// 마지막 파싱이 **옛 트리와 달라진 범위**(`ts_tree_get_changed_ranges` — 새 트리 좌표). 증분 파싱이 끝날 때 채운다. `changed_all` 이면
    /// 범위를 모른다(처음 · 통째 파싱 · 넘침 · 읽기 전에 또 팠다).
    changed: [max_changed]ByteRange = undefined,
    changed_len: u8 = 0,
    changed_all: bool = true,
    /// 마지막 `nextOpenBracket`·`nextOpenBrackets` 가 지난 노드 수 — 판정자(`SYN50`)가 **걸음 수로** 비용을 잰다(시간은 CI 에서 흔들린다).
    next_open_visits: u32 = 0,
    /// 형제 짝짓기(`pairAmongChildren`)가 지난 자식 수의 누계 — 판정자(`BRP8`·`SYN51`)가 커서가 많은 점프의 비용을 걸음 수로 잰다.
    sibling_visits: u64 = 0,
    /// **한 번의 점프 동안만** 선다(`PairMemo` — 커서마다 같은 부모의 형제를 다시 짝짓지 않게). 평소에는 `null` 이다.
    memo: ?*PairMemo = null,

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
            if (old_tree) |ot| self.noteChanged(ot, t) else self.changed_all = true;
            if (self.tree) |old| {
                if (old != t) c.ts_tree_delete(old);
            }
            self.tree = t;
            self.tree_gen += 1;
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

    /// 단조 시계. **`std.c.clock_gettime` 을 쓰면 안 된다** — POSIX 전용이라 Windows 에서는 이 중립
    /// 파일이 **컴파일조차 안 되고**, 그러면 그 호스트에서 syntax 회귀를 볼 방법이 사라진다(§2m.108).
    ///
    /// **io 를 호출자에게 받지 않는다.** 이 저장소의 규칙은 「I/O 는 호출자가 준 `io` 로 한다」인데
    /// 시계 읽기는 I/O 가 아니다 — std 구현이 그것을 그대로 말한다(`Io/Threaded.zig`의 `now`가
    /// `userdata` 를 받자마자 `_ = t;` 로 버리고 `nowWindows`/`nowPosix` 로 간다, 0.16 실측).
    /// 즉 어느 인스턴스로 읽어도 같은 값이고 공유 상태를 안 건드린다. 그 한 줄을 위해 `open` 의
    /// 서명을 바꾸면 호출자 수십 자리가 따라 바뀐다(`app_session/editor.zig` 실측).
    ///
    /// **`awake` 는 옛 시계와 「같은」 것이 아니다** — macOS 에서만 갈린다(`Io/Threaded.clockToPosix`):
    ///
    /// | | 옛 `std.c.clock_gettime(.MONOTONIC)` | `.awake` |
    /// |---|---|---|
    /// | Linux | `CLOCK_MONOTONIC` | `CLOCK_MONOTONIC` (같다) |
    /// | macOS | `CLOCK_MONOTONIC` — **잠든 시간을 센다** | `CLOCK_UPTIME_RAW` — **안 센다** |
    ///
    /// (Darwin 의 MONOTONIC 계열이 잠든 동안 흐른다는 것은 std 자신의 분류가 말한다 — 그 함수가
    /// `.boot`「잠든 동안도 흐른다」쪽에 Darwin `MONOTONIC_RAW` 를 넣는다.)
    ///
    /// **이 자리에는 `awake` 가 맞다.** 재려는 것이 「이 파싱이 CPU 를 얼마나 썼나」라서다 — 옛 시계면
    /// 파싱 도중에 기계가 잠들었다 깨는 순간 예산이 통째로 날아가 트리를 버린다. 다만 **바뀐 것은
    /// 바뀐 것이라** 여기 적어 둔다(4ms 예산에서 실제로 걸릴 일은 아니다).
    fn monotonicNs() u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    }

    /// 문서 내용이 **통째로** 바뀌었다(디스크에서 다시 읽기 등) — 전체를 다시 판다.
    ///
    /// **편집에는 `onEdit`을 쓴다.** 실측으로 81배 차이가 난다(154KB에서 5.3ms 대 65µs) —
    /// §5.3이 *"통지가 없으면 증분 파싱이 성립하지 않아 매번 전체 재파싱이 된다"*고 적은 그 자리다.
    ///
    /// **상한을 넘으면 트리를 버린다**(그 뒤 질의는 빈 목록이다).
    ///
    /// **끊긴 파싱을 먼저 버린다**(§2.1a 계약 — *"재개 도중 문서가 바뀌면 `ts_parser_reset`"*). 이 입구는 **새 내용**을
    /// 들고 오는데, 여는 파싱이 예산에 끊겨 있으면 파서가 그 반쯤 판 상태를 **이 원문에 이어 판다** — 이미 읽은 앞부분이
    /// 길이가 바뀌게 달라졌으면 byte 위치가 어긋나 트리가 틀린다(오류 노드가 서고 노드가 엉뚱한 byte 를 가리킨다 — `SYN41`).
    /// **`setSourceBudgeted` 에는 넣지 않는다**: 이어 파는 방법이 바로 그 함수를 **같은 인자로 다시 부르기**라서, 거기서
    /// 버리면 큰 파일은 프레임마다 처음부터 다시 파다 영영 안 끝난다(`SYN15` 의 재개 루프가 그 변이를 잡는다).
    pub fn setSource(self: *Provider, source: []const u8) void {
        c.ts_parser_reset(self.parser);
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
            self.tree_gen += 1;
        }
        self.changed_all = true;
        if (source.len == 0 or source.len > max_parse_bytes) return .done;
        return self.parseBudgeted(source, null, budget_ns);
    }

    /// 편집 하나를 알린 뒤 **증분으로** 다시 판다. `source`는 **바뀐 뒤**의 내용이다.
    ///
    /// **행·열을 반드시 채워야 한다.** 처음에는 *"byte offset만으로도 된다"*고 적고 0을 넘겼는데,
    /// 실측이 그것을 반증했다 — 그렇게 하면 증분이 전체 재파싱보다 **더 느리다**(154KB에서 9.8ms
    /// 대 5ms, 618KB에서 30ms 대 21ms). tree-sitter가 어긋난 위치를 되맞추느라 더 일한다.
    /// 달라진 범위의 칸 수 — 넘치면 `changed_all`(다 다시 훑는다 — 틀린 것보다 느린 것이 낫다).
    pub const max_changed: usize = 16;

    /// 증분 파싱이 끝났다 — 옛 트리(편집을 먹인)와 새 트리의 달라진 범위를 **새로** 적는다(앞의 것은 버린다). 소비처가 그 사이 파싱을 놓쳤는지는
    /// 범위가 아니라 **세대**(`tree_gen` 이 하나 넘게 뛰었다)로 가른다 — 처음엔 「안 읽은 것이 남아 있으면 모름」으로 적었는데, 여는 파싱이 세운
    /// 「모름」이 아무도 안 읽어 남아 **편집 첫 번째가 늘 처음부터**였다(큰 문서에서 처음 훑기가 스무 프레임 넘게 걸려, 그동안 치면 색이 영영 안
    /// 돌아왔다 — `BRPERF` 실측 `partials=0` · 적대적 검증 전 벤치).
    fn noteChanged(self: *Provider, old: *c.TSTree, new: *c.TSTree) void {
        self.changed_all = false;
        self.changed_len = 0;
        var count: u32 = 0;
        const ranges = c.ts_tree_get_changed_ranges(old, new, &count);
        // **tree-sitter 의 할당기로 푼다** — API 주석은 「`malloc` 이니 `free` 로」라지만 구현(`get_changed_ranges.c`)은 `array_push` → `ts_realloc`
        // 이라 `ts_set_allocator` 로 바꾼 할당기에서 온다(`SYN10` 이 그 할당기로 센다). 공개 심볼 `ts_current_free` 가 그 짝이다(`alloc.h`).
        defer if (ranges != null) ts_current_free(@ptrCast(ranges));
        if (count > max_changed) {
            self.changed_all = true;
            return;
        }
        for (0..count) |k| self.changed[k] = .{ .start = ranges[k].start_byte, .end = ranges[k].end_byte };
        self.changed_len = @intCast(count);
    }

    /// 달라진 범위를 읽고 비운다. `null` 이면 모른다(다 다시).
    pub fn takeChanged(self: *Provider, out: *[max_changed]ByteRange) ?[]const ByteRange {
        defer {
            self.changed_len = 0;
            self.changed_all = false;
        }
        if (self.changed_all) return null;
        @memcpy(out[0..self.changed_len], self.changed[0..self.changed_len]);
        return out[0..self.changed_len];
    }

    pub fn onEdit(self: *Provider, source: []const u8, e: Edit) void {
        self.onEditBudgeted(source, e, 0);
    }

    /// 예산을 든 증분 파싱(§2.1a). 끊기면 **옛 트리로 계속 그린다** — 편집 전 색이지만 무색보다 낫고,
    /// 다음 프레임에 재개한다.
    ///
    /// **끊긴 파싱을 먼저 버린다**(`setSource` 와 같은 이유 — 편집은 언제나 새 내용이다). 제품이 밟는 자리는 「옛 트리 없음」
    /// 갈래다: 여는 파싱이 끊긴 채로 백업 복원이 문서 전체를 갈아 끼운다. 예산을 든 증분이 끊긴 뒤 다음 편집이 오는 경우도
    /// 같다(반쯤 판 것은 **편집 전** 내용이다) — 둘 다 `SYN41` 이 잰다.
    pub fn onEditBudgeted(self: *Provider, source: []const u8, e: Edit, budget_ns: u64) void {
        c.ts_parser_reset(self.parser);
        const old_tree = self.tree orelse {
            _ = self.setSourceBudgeted(source, budget_ns);
            return;
        };
        if (source.len == 0 or source.len > max_parse_bytes) {
            c.ts_tree_delete(old_tree);
            self.tree = null;
            self.tree_gen += 1;
            self.changed_all = true;
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

    /// 선택 확장의 한 단계(tooling §8.2q) — 문서 절대 byte `[start, end)`.
    pub const ByteRange = struct { start: u32, end: u32 };

    /// 한 caret 이 쌓을 수 있는 조상 범위의 상한(§8.2q). 깊은 트리(수천 단 중첩)에서 한 번의 키가 끝없이 걷지 않게.
    pub const max_enclosing: usize = 256;

    /// **`[lo, hi)` 를 품는 노드부터 뿌리까지**, 안쪽부터 바깥 순서로(tooling §8.2q — 구조 기반 선택 확장의 1층).
    /// 같은 범위의 노드가 겹치면(부모가 자식과 같은 byte 를 덮는다) 한 번만 낸다. 트리가 없으면 빈 목록.
    ///
    /// **byte 로만 읽는다** — 행·열(`ts_node_start_point`)은 쓰지 않는다: 편집 통지가 옛 끝의 행·열을 근사로 넘기므로
    /// (`editor_syntax.onEditSpan`) 점 좌표는 편집 뒤에 어긋날 수 있다. byte 는 정확하다.
    pub fn enclosingRanges(self: *Provider, allocator: std.mem.Allocator, lo: u32, hi: u32, out: *std.ArrayList(ByteRange)) error{OutOfMemory}!void {
        out.clearRetainingCapacity();
        const tree = self.tree orelse return;
        const root = c.ts_tree_root_node(tree);
        var node = c.ts_node_descendant_for_byte_range(root, lo, hi);
        while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
            const s = c.ts_node_start_byte(node);
            const e = c.ts_node_end_byte(node);
            if (s > lo or e < hi) continue; // 조상이면 품는다 — 어긋나면 그 단은 버린다(방어 · 적대적 1회차 T3: 등가)
            if (out.items.len > 0) {
                const last = out.items[out.items.len - 1];
                if (last.start == s and last.end == e) continue;
            }
            try out.append(allocator, .{ .start = s, .end = e });
            if (out.items.len >= max_enclosing) break;
        }
    }

    /// 괄호 한 쌍(visual-mapping §5.1b) — 두 괄호 **글자**의 문서 절대 byte(`open < close`).
    pub const BracketPair = struct { open: u32, close: u32 };

    /// 형제 하나에서 짝지을 수 있는 괄호의 깊이 상한(종류마다). 형제 목록 안의 중첩은 보통 몇 단이고(안쪽 쌍은 자식 노드로 내려간다),
    /// 넘치면 그 쌍을 못 찾은 것으로 친다 — 틀린 쌍을 내는 것보다 낫다.
    pub const max_sibling_depth: usize = 64;

    /// **byte `i` 의 글자가 괄호 토큰이면 그 짝**(§5.1b ⓐ). 괄호 토큰 = 이름 없는 잎이고 그 글자들 안의 괄호가 **정확히 하나**(`(` 도, Bash
    /// `$(` 도 — Zig `.{`·Rust `#[` 는 grammar 가 두 토큰으로 낸다, 실측). 짝은 **같은 부모의 형제**에서 같은 종류를 깊이로 센다 — 문자열·주석 속 글자는 긴 잎의 일부라 여기서 `null` 이다.
    /// 트리가 없으면 `null`. `source` 는 트리를 만든 그 내용이어야 한다.
    pub fn bracketTokenPair(self: *Provider, source: []const u8, i: u32) ?BracketPair {
        const tree = self.tree orelse return null;
        if (i >= source.len) return null;
        const node = c.ts_node_descendant_for_byte_range(c.ts_tree_root_node(tree), i, i + 1);
        const tok = tokenBracket(node, source) orelse return null;
        // **오늘 등가다**(적대적 2회차 T4): 이 검사가 없어도 아래 짝짓기가 **물은 byte 가 괄호인 쌍만** 돌려주므로(`.token` 갈래) `$(` 의 `$`
        // 에서 물으면 결국 `null` 이다. 두는 이유는 뜻이다 — 「이 글자가 괄호인가」를 여기서 답하고, 짝짓기의 비교에 기대지 않는다.
        if (tok.at != i) return null; // 토큰이 이 글자를 덮지만 그 괄호는 다른 자리다(방어 — 한 토큰에 괄호는 하나뿐)
        const parent = c.ts_node_parent(node);
        if (c.ts_node_is_null(parent)) return null;
        return self.pairAmong(parent, source, .{ .token = i });
    }

    /// **byte `i` 의 글자가 여는 괄호 토큰인가**(§5.1b ⓐ — 짝은 안 본다). 「다음 여는 괄호」(`nextOpenBracket`)의 **정의**다 — 제품은 이것을
    /// 글자마다 부르지 않는다(느리다 — 그 함수 주석). 판정자(`SYN44`·`SYN50`)가 쓴다. 트리가 없으면 `false`.
    pub fn isOpenBracketToken(self: *Provider, source: []const u8, i: u32) bool {
        const tree = self.tree orelse return false;
        // (범위 가드는 **등가**다 — 적대적 1회차 J13: 문서 밖 byte 로 물으면 트리가 루트를 돌려주고, 루트는 잎이 아니라 괄호 토큰이 아니다. 뜻으로 둔다.)
        if (i >= source.len) return false;
        const node = c.ts_node_descendant_for_byte_range(c.ts_tree_root_node(tree), i, i + 1);
        const tok = tokenBracket(node, source) orelse return false;
        return tok.at == i and tok.open;
    }

    /// **byte `i`(또는 caret `i` 가 그 안에 선) 글 잎**(§5.1b ⓑ)의 범위 — 글이 괄호를 담는 언어(`prose_brackets`)의 글 잎(`isProseLeaf`).
    /// 짝·감싸는 쌍은 호출자가 이 범위 **안에서만** 글자 훑기로 찾는다. 그 밖이면 `null`.
    pub fn proseLeafAt(self: *Provider, i: u32) ?ByteRange {
        const node = self.proseNodeAt(i) orelse return null;
        return .{ .start = c.ts_node_start_byte(node), .end = c.ts_node_end_byte(node) };
    }

    /// byte `i` 가 **다음 여는 괄호**(문서 모델 §3.9c ③)로 칠 수 있는 글 잎 속인가 — 글 잎 중 `raw_text` 는 뺀다(`isProseText`). 판정자
    /// (`SYN50`)가 `nextOpenBracket` 의 정의로 쓴다.
    pub fn isProseTextAt(self: *Provider, i: u32) bool {
        const node = self.proseNodeAt(i) orelse return false;
        return isProseText(node);
    }

    fn proseNodeAt(self: *Provider, i: u32) ?c.TSNode {
        if (!self.slot.prose_brackets) return null;
        const tree = self.tree orelse return null;
        const node = c.ts_node_descendant_for_byte_range(c.ts_tree_root_node(tree), i, i + 1);
        if (!self.isProseLeaf(node)) return null;
        const s = c.ts_node_start_byte(node);
        const e = c.ts_node_end_byte(node);
        if (!(s <= i and i < e)) return null;
        return node;
    }

    /// 글 잎인가(§5.1b ⓑ) — 글이 괄호를 담는 언어의 **`comment` 가 아닌 이름 있는 잎**(HTML: `text`·`attribute_value`·`attribute_name`·
    /// `raw_text`(`<script>`·`<style>` 본문) 등). `comment` 속 괄호는 괄호가 아니다(VS Code 도 `<!--` 부터 주석 토큰이다). 이름 있는 잎을
    /// 종류로 좁히지 않는 것은 **속성 이름** 때문이다 — Angular `(click)` 은 `attribute_name` 잎이고 VS Code 는 그 괄호를 짝짓는다(`[value]` 의 `[]` 는
    /// VS Code HTML 괄호가 아니다 — 우리는 짝짓는다: 알려진 차이, 문서 모델 §3.9c)
    /// (적대적 3회차: 2회차에 `text`·`attribute_value`·`raw_text` 로 좁혔다가 `(click)` 강조·점프를 잃었다). 이름 없는 잎(`<`·`>`·`=`·`"`)은
    /// 구두점이라 글이 아니다.
    fn isProseLeaf(self: *Provider, node: c.TSNode) bool {
        if (!self.slot.prose_brackets) return false;
        if (c.ts_node_is_null(node) or c.ts_node_child_count(node) != 0 or !c.ts_node_is_named(node)) return false;
        return !std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), "comment");
    }

    /// 글 잎 중 **다음 여는 괄호로 칠 글**인가 — `raw_text`(스크립트·스타일 본문)는 뺀다. 짝·감싸는 쌍은 **보이는** 판정이라(상자가 선다)
    /// 스크립트 속 글자 훑기에 속아도 사용자가 알지만, 다음 여는 괄호는 **안 보이는** 판정이라 스크립트 문자열 속 `"("` 로 데려가면 왜 거기
    /// 왔는지 모른다(문서 모델 §3.9c — 트리가 없으면 감싸는 쌍을 안 찾는 것과 같은 이유 · 적대적 1회차).
    fn isProseText(node: c.TSNode) bool {
        return !std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), "raw_text");
    }

    /// **`pos` 이후 첫 여는 괄호**(문서 모델 §3.9c ③ — VS Code `findNextBracket`)의 byte. 괄호 토큰(§5.1b ⓐ)의 여는 괄호이거나 글 잎(ⓑ)
    /// 속 여는 괄호 글자다 — 짝은 안 본다(안 닫힌 것도 친다). 없거나 트리가 없으면 `null`.
    ///
    /// **트리 커서로 잎을 문서 순서로 한 번 걷는다** — `pos` 앞에서 끝난 가지는 통째로 건너뛰고, 문자열·주석은 잎 하나라 한 걸음이다. 처음엔
    /// 여는 괄호 **글자**마다 루트에서 내려가 물었는데(`isOpenBracketToken`), 한 번 내려갈 때마다 형제를 줄줄이 훑어 최상위 주석 2 만 줄 뒤의
    /// `(` 46 만 개에서 **44 초** 걸렸다(ReleaseFast 실측 — 적대적 1회차). 답은 그 정의와 같다(`SYN50` 이 모든 자리에서 잰다).
    pub fn nextOpenBracket(self: *Provider, source: []const u8, pos: u32) ?u32 {
        var out = [1]?u32{null};
        self.nextOpenBrackets(source, &.{pos}, &out);
        return out[0];
    }

    /// **여러 caret 의 「다음 여는 괄호」를 한 번의 걷기로**(문서 모델 §3.9c — 커서가 많은 점프). `positions` 는 **오름차순**이고 `out` 은 같은 길이다.
    /// 가장 앞 caret 에서 시작해 여는 괄호를 문서 순서로 만날 때마다 그 앞에 선 caret 들에게 그 자리를 준다 — 답은 caret 마다 따로 걸은 것과 같다
    /// (`SYN51`). 커서마다 따로 걸으면 최상위 형제를 caret 수만큼 다시 지난다.
    pub fn nextOpenBrackets(self: *Provider, source: []const u8, positions: []const u32, out: []?u32) void {
        self.next_open_visits = 0;
        @memset(out, null);
        const tree = self.tree orelse return;
        var qi: usize = 0;
        // (등가 — 적대적 2회차 K10: 문서 끝의 caret 은 caret 뒤에서 끝나는 노드가 없어 걷기가 어차피 답을 못 준다. 한 바퀴를 안 돌려고 둔다.)
        while (qi < positions.len and positions[qi] >= source.len) qi += 1;
        if (qi == positions.len) return;
        const pos = positions[qi];
        var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(tree));
        defer c.ts_tree_cursor_delete(&cursor);
        while (true) {
            const node = c.ts_tree_cursor_current_node(&cursor);
            self.next_open_visits +|= 1;
            if (c.ts_node_end_byte(node) > pos) {
                if (c.ts_node_child_count(node) == 0) {
                    // 이 잎의 여는 괄호를 차례로 — 괄호 토큰은 하나, 글 잎은 여럿일 수 있다
                    var from = pos;
                    while (self.leafOpenFrom(node, source, from)) |at| {
                        while (qi < positions.len and positions[qi] <= at) : (qi += 1) {
                            if (positions[qi] < source.len) out[qi] = at;
                        }
                        if (qi == positions.len) return;
                        from = at + 1;
                    }
                } else if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            }
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) return;
            }
        }
    }

    /// 잎 `node` 에서 `pos` 이후 첫 여는 괄호 — 괄호 토큰이면 그 괄호(여는 것만), 글 잎이면 그 안의 여는 괄호 글자.
    fn leafOpenFrom(self: *Provider, node: c.TSNode, source: []const u8, pos: u32) ?u32 {
        if (tokenBracket(node, source)) |t| return if (t.open and t.at >= pos) t.at else null;
        if (!self.isProseLeaf(node) or !isProseText(node)) return null;
        const e = @min(c.ts_node_end_byte(node), @as(u32, @intCast(source.len)));
        var k = @max(c.ts_node_start_byte(node), pos);
        while (k < e) : (k += 1) {
            if (source[k] == '(' or source[k] == '[' or source[k] == '{') return k;
        }
        return null;
    }

    /// **caret `pos` 를 품는 가장 안쪽 괄호 토큰 쌍**(§5.1b — VS Code `findEnclosingBrackets`). caret 이 든 가장 깊은 노드부터 조상으로 올라가며
    /// 형제 괄호 쌍 중 `open < pos ≤ close` 인 것을 찾는다(여는 괄호 바로 앞·닫는 괄호 바로 뒤는 품지 않는다). 한 층 안에서는 **처음 닫히는** 품는
    /// 쌍이 가장 안쪽이다 — 형제 쌍은 서로 겹치지 않거나 포개진다. 트리가 없거나 없으면 `null`.
    pub fn enclosingBracketTokens(self: *Provider, source: []const u8, pos: u32) ?BracketPair {
        const tree = self.tree orelse return null;
        var node = c.ts_node_descendant_for_byte_range(c.ts_tree_root_node(tree), pos, pos);
        var steps: usize = 0;
        while (!c.ts_node_is_null(node) and steps < max_enclosing) : ({
            node = c.ts_node_parent(node);
            steps += 1;
        }) {
            if (c.ts_node_child_count(node) == 0) continue;
            if (self.pairAmong(node, source, .{ .enclosing = pos })) |p| return p;
        }
        return null;
    }

    /// 괄호 토큰 하나 — 그 괄호 글자의 자리와 종류(`([{` 의 색인)·방향.
    const TokenBracket = struct { at: u32, kind: u2, open: bool };

    /// `node` 가 괄호 토큰이면 그 괄호(§5.1b ⓐ). 이름 없는 잎 · 폭 1~3 · 괄호 글자 정확히 하나.
    fn tokenBracket(node: c.TSNode, source: []const u8) ?TokenBracket {
        if (c.ts_node_is_null(node)) return null;
        if (c.ts_node_child_count(node) != 0 or c.ts_node_is_named(node)) return null;
        const s = c.ts_node_start_byte(node);
        const e = c.ts_node_end_byte(node);
        // 폭 0(`MISSING` — 오류 복구가 끼운 없는 토큰)은 짝이 아니다. 긴 이름 없는 잎(키워드 등)은 괄호를 안 담는다.
        if (e <= s or e - s > 3 or e > source.len) return null;
        var found: ?TokenBracket = null;
        for (source[s..e], 0..) |ch, k| {
            const b = bracketOf(ch) orelse continue;
            if (found != null) return null; // 둘 이상(`((` 등) — 어느 괄호인지 못 정한다
            found = .{ .at = s + @as(u32, @intCast(k)), .kind = b.kind, .open = b.open };
        }
        return found;
    }

    fn bracketOf(ch: u8) ?struct { kind: u2, open: bool } {
        return switch (ch) {
            '(' => .{ .kind = 0, .open = true },
            ')' => .{ .kind = 0, .open = false },
            '[' => .{ .kind = 1, .open = true },
            ']' => .{ .kind = 1, .open = false },
            '{' => .{ .kind = 2, .open = true },
            '}' => .{ .kind = 2, .open = false },
            else => null,
        };
    }

    /// **한 번의 점프 동안 부모마다 형제 괄호 쌍을 한 번만 짝짓는다**(문서 모델 §3.9c — 커서가 많은 점프). 커서마다 `pairAmongChildren` 을 다시
    /// 부르면 같은 부모(수만 원소 배열)의 자식을 커서 수만큼 다시 지나 곱으로 붙었다(적대적 3회차 — 커서 1 만 = 12 s). 답은 메모 없이 짝지은 것과
    /// 같다(`SYN51`). 부르는 쪽이 `Provider.memo` 에 세우고 끝나면 거둔다 — 트리가 바뀌면 옛 노드를 가리키므로 한 번의 점프보다 오래 두지 않는다.
    pub const PairMemo = struct {
        allocator: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(Key, Sibling) = .empty,

        const Key = struct { id: usize, start: u32 };
        /// 한 부모의 형제 쌍 — `pairs` 는 **닫히는 순서**(`pairAmongChildren` 이 완성하는 순서), `by_bracket` 은 괄호 자리 → 쌍 색인.
        const Sibling = struct {
            pairs: []BracketPair,
            by_bracket: std.AutoHashMapUnmanaged(u32, u32),
        };

        pub fn init(allocator: std.mem.Allocator) PairMemo {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *PairMemo) void {
            var it = self.map.valueIterator();
            while (it.next()) |sib| {
                self.allocator.free(sib.pairs);
                sib.by_bracket.deinit(self.allocator);
            }
            self.map.deinit(self.allocator);
            self.* = undefined;
        }
    };

    /// 형제 짝짓기 — 메모가 서 있으면 그 부모의 쌍을 한 번 짝지어 두고 거기서 답한다. 메모가 없거나 할당이 실패하면 곧바로 짝짓는다(답은 같다).
    fn pairAmong(self: *Provider, parent: c.TSNode, source: []const u8, want: Want) ?BracketPair {
        const memo = self.memo orelse return self.pairAmongChildren(parent, source, want);
        const sib = self.siblingsOf(memo, parent, source) catch return self.pairAmongChildren(parent, source, want);
        switch (want) {
            .token => |t| {
                const k = sib.by_bracket.get(t) orelse return null;
                return sib.pairs[k];
            },
            // 닫히는 순서에서 **처음으로** 품는 쌍 — 닫는 자리가 `pos` 이상인 첫 쌍부터 본다(그 앞 쌍은 `pos` 전에 닫혀 품을 수 없다).
            .enclosing => |pos| {
                var lo: usize = 0;
                var hi: usize = sib.pairs.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (sib.pairs[mid].close < pos) lo = mid + 1 else hi = mid;
                }
                for (sib.pairs[lo..]) |p| {
                    if (p.open < pos and pos <= p.close) return p;
                }
                return null;
            },
        }
    }

    fn siblingsOf(self: *Provider, memo: *PairMemo, parent: c.TSNode, source: []const u8) !*const PairMemo.Sibling {
        const key: PairMemo.Key = .{ .id = @intFromPtr(parent.id), .start = c.ts_node_start_byte(parent) };
        const gop = try memo.map.getOrPut(memo.allocator, key);
        if (gop.found_existing) return gop.value_ptr;
        errdefer memo.map.removeByPtr(gop.key_ptr);
        var pairs: std.ArrayList(BracketPair) = .empty;
        errdefer pairs.deinit(memo.allocator);
        try self.collectSiblingPairs(parent, source, memo.allocator, &pairs);
        var by: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        errdefer by.deinit(memo.allocator);
        for (pairs.items, 0..) |p, k| {
            try by.put(memo.allocator, p.open, @intCast(k));
            try by.put(memo.allocator, p.close, @intCast(k));
        }
        gop.value_ptr.* = .{ .pairs = try pairs.toOwnedSlice(memo.allocator), .by_bracket = by };
        return gop.value_ptr;
    }

    const Want = union(enum) { token: u32, enclosing: u32 };

    /// `parent` 의 자식들을 앞에서부터 한 번 지나며 괄호 토큰을 종류별 스택으로 짝짓는다. 커서로 걷는다 — `ts_node_prev_sibling` 은 부모부터
    /// 다시 세므로 큰 형제 목록(수만 원소 JSON 배열)에서 곱으로 붙는다.
    fn pairAmongChildren(self: *Provider, parent: c.TSNode, source: []const u8, want: Want) ?BracketPair {
        var found: ?BracketPair = null;
        self.walkSiblingPairs(parent, source, want, &found, null) catch {};
        return found;
    }

    /// 메모용 — `parent` 의 형제 쌍을 **전부** 닫히는 순서로 모은다(`pairAmongChildren` 과 같은 걷기).
    fn collectSiblingPairs(self: *Provider, parent: c.TSNode, source: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList(BracketPair)) !void {
        var unused: ?BracketPair = null;
        try self.walkSiblingPairs(parent, source, null, &unused, .{ .allocator = allocator, .list = out });
    }

    const PairSink = struct { allocator: std.mem.Allocator, list: *std.ArrayList(BracketPair) };

    /// 형제를 앞에서부터 한 번 지나며 괄호 토큰을 종류별 스택으로 짝짓는다. `want` 가 있으면 그 답에서 멈추고(`found`), `sink` 가 있으면 완성된 쌍을
    /// 모두 모은다 — 메모와 곧바로 짝짓기가 **같은 걷기**를 쓴다(답이 갈릴 자리가 없게).
    fn walkSiblingPairs(self: *Provider, parent: c.TSNode, source: []const u8, want: ?Want, found: *?BracketPair, sink: ?PairSink) !void {
        var cursor = c.ts_tree_cursor_new(parent);
        defer c.ts_tree_cursor_delete(&cursor);
        if (!c.ts_tree_cursor_goto_first_child(&cursor)) return;
        var stacks: [3][max_sibling_depth]u32 = undefined;
        var depth = [3]usize{ 0, 0, 0 };
        // 스택이 넘친 종류는 그 뒤로 짝을 믿을 수 없다 — 그 종류는 더 짝짓지 않는다.
        var overflow = [3]bool{ false, false, false };
        while (true) {
            const child = c.ts_tree_cursor_current_node(&cursor);
            self.sibling_visits +|= 1;
            if (tokenBracket(child, source)) |b| {
                const k: usize = b.kind;
                if (!overflow[k]) {
                    if (b.open) {
                        if (depth[k] == max_sibling_depth) {
                            overflow[k] = true;
                        } else {
                            stacks[k][depth[k]] = b.at;
                            depth[k] += 1;
                        }
                    } else if (depth[k] > 0) {
                        depth[k] -= 1;
                        const pair: BracketPair = .{ .open = stacks[k][depth[k]], .close = b.at };
                        if (sink) |sk| try sk.list.append(sk.allocator, pair);
                        if (want) |w| switch (w) {
                            .token => |t| if (pair.open == t or pair.close == t) {
                                found.* = pair;
                                return;
                            },
                            // **처음 완성된 「품는 쌍」이 가장 안쪽이다** — 쌍은 닫히는 순서로 완성되고, caret 을 품는 쌍들은 서로 포개지므로 안쪽이
                            // 먼저 닫힌다(나란한 두 쌍은 둘 다 caret 을 품을 수 없다). 처음엔 「여는 자리가 가장 뒤인 것」을 골랐는데 적대적 2회차
                            // (T13b)가 첫 것을 남겨도 같은 답임을 보였고, 이유가 위 한 줄이라 줄였다.
                            .enclosing => |pos| if (pair.open < pos and pos <= pair.close) {
                                found.* = pair;
                                return;
                            },
                        };
                    }
                }
            }
            if (!c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
        }
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
    /// **할당 실패는 «보고»한다 — 빈 목록으로 떨어뜨리지 않는다.** 색(`spansForRange`)은 실패를
    /// 무색으로 저하시켜도 되지만(§5 — 다음 프레임이 다시 칠한다) 접힘은 다르다: 부르는 쪽이
    /// 빈 목록을 「접을 것이 없다」로 읽고 **다시 세지 않도록 래치**하므로, 일시적 실패가 그 문서의
    /// 구문 접힘을 **영영** 없앤다(적대적 검증 2026-09-10 — 첫 할당을 실패시켜 실측했다).
    /// 그래서 이 함수의 빈 목록은 **언제나 「접을 것이 없다」**이고, 못 센 것은 오류로 나온다.
    /// 트리의 구문 오류 하나(§5.4 첫 출처). `missing` 이면 `end == start + 1`(없는 토큰은 폭이 없어 한 byte 를 준다) 이고
    /// `expected` 가 그 토큰의 이름이다(문법이 소유하는 정적 문자열).
    pub const SyntaxError = struct {
        start: u32,
        end: u32,
        missing: bool,
        expected: []const u8,
    };

    /// 구문 오류 상한(§5.4) — 통째로 깨진 파일이 수천 개를 내면 그 뒤는 뜻이 없다.
    pub const max_syntax_errors: usize = 512;

    /// **구문 오류를 뽑는다**(§5.4): `ERROR` 노드(가장 바깥 것 하나 — 안쪽은 접는다)와 `MISSING` 노드. 트리가 없으면(파싱이 끊긴
    /// 프레임) 아무것도 안 하고 `false` — 호출자는 직전 목록을 유지한다. 순서는 문서 순(트리 순회가 그렇다).
    pub fn syntaxErrors(self: *Provider, allocator: std.mem.Allocator, out: *std.ArrayList(SyntaxError)) error{OutOfMemory}!bool {
        // 트리가 없을 때 `out` 을 **건드리지 않는다** — 그래서 반환값이 `true` 여도 호출자가 보는 목록은 같다(적대적 1회차 A11,
        // 등가). `false` 를 주는 이유는 뜻이다: 「이 프레임은 새로 센 것이 아니다」.
        const tree = self.tree orelse return false;
        out.clearRetainingCapacity();
        const root = c.ts_tree_root_node(tree);
        if (!c.ts_node_has_error(root)) return true; // 오류 없는 트리는 순회할 것도 없다 — 결과에는 등가(5회차 E6), 비용의 길

        var cursor = c.ts_tree_cursor_new(root);
        defer c.ts_tree_cursor_delete(&cursor);
        while (true) {
            const node = c.ts_tree_cursor_current_node(&cursor);
            var descend = true;
            // **뿌리는 진단이 아니다.** 문서가 통째로 안 풀리면 tree-sitter 는 뿌리 자체를 `ERROR` 로 낸다 — 그것을 하나로 접으면
            // 파일 전체에 밑줄이 간다(제품 캡처에서 실측: 함수 셋 중 하나가 깨졌는데 스무 줄이 전부 빨갰다). 뿌리는 늘 내려간다.
            const is_root = c.ts_node_eq(node, root);
            if (is_root) {
                // 아래로
            } else if (c.ts_node_is_missing(node)) {
                const sb = c.ts_node_start_byte(node);
                try out.append(allocator, .{ .start = sb, .end = sb + 1, .missing = true, .expected = std.mem.span(c.ts_node_type(node)) });
                descend = false;
            } else if (c.ts_node_is_error(node)) {
                try out.append(allocator, .{ .start = c.ts_node_start_byte(node), .end = c.ts_node_end_byte(node), .missing = false, .expected = "" });
                descend = false; // 안쪽 오류는 바깥 것에 접는다
            } else if (!c.ts_node_has_error(node)) {
                // 아래에 오류가 없는 가지는 안 내려간다 — 큰 파일에서 순회 비용을 오류 근처로 좁힌다. **결과에는 등가**다(적대적
                // 5회차 E2: 내려가도 오류가 없어 아무것도 안 더한다) — 걸음 수만 다르다.
                descend = false;
            }
            if (out.items.len >= max_syntax_errors) return true;
            if (descend and c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) return true;
            }
        }
    }

    pub fn foldSpans(self: *Provider, allocator: std.mem.Allocator, out: *std.ArrayList(FoldSpan)) error{OutOfMemory}!void {
        out.clearRetainingCapacity();
        const tree = self.tree orelse return;

        // **접을 종류가 없으면 여기서 끝난다** — 그 언어는 들여쓰기 층이 그대로 산다(§4.1f).
        //
        // **「없음」은 오류가 아니다** — 위 `tree == null` 과 같은 부류다(`SYN20`). 그리고 이 갈래를
        // 오류로 바꾼 변이는 **살아남는 것이 정상이다**(적대적 검증 Y4b): 번들한 열여덟이 전부
        // 종류를 갖고 있어 오늘 닿지 않는다. 그 상태를 지키는 것은 `SYN21` 이다 — 종류 없는 언어를
        // 더하면 그 판정자가 먼저 깨진다.
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
                const gop = try best.getOrPut(allocator, sp.row);
                // **비교를 지우고 「첫 후보만」으로 바꾼 변이는 살아남는 것이 정상이다**
                // (적대적 검증 Y8e): 이 순회가 **전위**라 조상을 먼저 보고, 같은 줄에서
                // 시작하는 두 여러-줄 노드는 **반드시 조상–자손**이다(형제라면 앞 형제가 그
                // 줄에서 끝나야 하고 그러면 한 줄짜리라 후보가 아니다). 조상의 끝 줄이 늘
                // 자손 이상이므로 「첫 후보」와 「가장 긴 것」이 같은 답이다. 그래도 «가장
                // 긴 것»으로 적는 이유는 뜻이다 — 순회 방식이 바뀌어도(질의 기반 등) 규칙이
                // 그대로 서고, 그때 이 줄을 다시 생각할 필요가 없다.
                if (!gop.found_existing or gop.value_ptr.* < ep.row) gop.value_ptr.* = ep.row;
            }

            if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) return try sortInto(allocator, &best, out);
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
    ) error{OutOfMemory}!void {
        try out.ensureTotalCapacity(allocator, best.count());
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

/// tree-sitter 가 지금 쓰는 해제 함수(`lib/src/alloc.h` 의 `TS_PUBLIC` 심볼) — 라이브러리가 할당해 넘긴 배열을 같은 할당기로 돌려준다.
extern var ts_current_free: *const fn (?*anyopaque) callconv(.c) void;

/// 괄호 목록의 괄호 하나(visual-mapping §5.1d) — 문서 절대 byte · 칠할 폭 · 짝 종류. 짝·단계는 여기서 모른다(`maru.session.editor.bracket_colors`).
pub const BracketLeaf = struct {
    start: u32,
    /// 칠하는 byte 수 — 대개 1.
    len: u8 = 1,
    /// 짝을 맞추는 닫는 괄호의 종류(`)`0 `]`1 `}`2). 여는 괄호면 기대하는 닫는 괄호.
    close_kind: u8,
    /// 여는 괄호 문자열의 종류(`(`0 `[`1 `{`2) — 독립 풀이 이것으로 센다.
    open_kind: u8 = 0,
    open: bool,
    /// 색칠 쌍인가(`colorizedBracketPairs`).
    colorized: bool = true,
};

/// **문서 전체 괄호 목록**(visual-mapping §5.1d — 위치 오름차순). 여는 괄호의 유효 여부가 문서 뒤쪽에 달려 있어 창이 아니라 문서 전체를 든다.
///
/// 트리 전체를 훑는 값이 크다 — 실측(ReleaseFast): 4 MB Zig 36 ms · 4 MB C 49 ms. 그래서 ① 처음 목록은 **예산을 든 훑기**로 여러 프레임에
/// 나눠 만들고(`step`) ② 편집은 **위치를 밀고**(`shift`) ③ 다시 판 트리의 **달라진 범위만** 다시 훑는다(`refresh`). 파싱을 하나라도 놓치면
/// (`Provider.tree_gen` 이 하나 넘게 뛰었다) 부분만 고치지 않고 처음부터 다시 만든다 — 조용히 틀리는 것보다 느린 것이 낫다.
pub const BracketIndex = struct {
    leaves: std.ArrayList(BracketLeaf) = .empty,
    /// 목록이 `synced_gen` 세대 트리와 맞는가.
    ready: bool = false,
    synced_gen: u64 = 0,
    /// 예산을 든 처음 훑기 — **트리 사본과 글 사본 위를** 걷는다(`ts_tree_copy` 는 참조 계수라 싸다). 훑는 동안 편집이 와도 버리지 않는다:
    /// 처음엔 편집마다 훑기를 다시 시작해, 큰 문서(4 MB 에 20~28 프레임)에서 그보다 빨리 계속 치면 색이 영영 안 돌아왔다(새 눈 리뷰가 짚었다).
    /// 지금은 편집을 `walk_edits` 에 쌓고 「다시 봐야 할 범위」(편집 범위 ∪ 달라진 범위 — 뒤 편집으로 계속 민다)를 `walk_dirty` 에 모았다가,
    /// 다 훑으면 모은 괄호를 편집들에 통과시켜 옮기고(걸친 것은 버린다) 그 범위만 지금 트리에서 다시 훑는다.
    walking: bool = false,
    cursor: c.TSTreeCursor = undefined,
    walk_tree: ?*c.TSTree = null,
    walk_text: []u8 = &.{},
    /// 글 사본을 잡은 할당기(버릴 때 같은 것으로 — `invalidate` 가 할당기 없이 불리는 자리가 있다: `reparse`).
    walk_alloc: ?std.mem.Allocator = null,
    walk_edits: std.ArrayList(EditRec) = .empty,
    walk_dirty: std.ArrayList(Provider.ByteRange) = .empty,
    /// 훑는 동안 달라진 범위를 모르게 됐다(통째 파싱 · 넘침 · 파싱을 놓쳤다) — 다 훑어도 못 쓴다, 처음부터.
    walk_dirty_all: bool = false,
    /// 훑는 동안 마지막으로 본 트리 세대(놓침을 가른다).
    walk_seen_gen: u64 = 0,
    /// 관측 — 처음부터 만든 횟수 · 부분만 고친 횟수(판정자가 「증분으로 갔나」를 시간 없이 묻는다).
    rebuilds: u64 = 0,
    partials: u64 = 0,
    /// 목록의 판 — 바뀔 때마다(민다 · 고친다 · 다 만들었다 · 버린다) 는다. 판정(짝·단계)을 든 쪽이 「내 판정이 이 목록의 것인가」를 가른다.
    version: u64 = 0,

    /// 편집 한 번이 다시 훑을 범위의 상한(byte) — 넘으면(블록 주석을 열어 문서 끝까지 바뀌었다) 부분 고침 대신 예산을 든 처음 훑기로 넘긴다.
    pub const partial_limit: u32 = 256 * 1024;

    pub const EditRec = struct { start: u32, old_end: u32, new_end: u32 };

    pub fn deinit(self: *BracketIndex, allocator: std.mem.Allocator) void {
        self.stopWalk();
        self.leaves.deinit(allocator);
        self.walk_edits.deinit(allocator);
        self.walk_dirty.deinit(allocator);
        self.* = .{};
    }

    fn stopWalk(self: *BracketIndex) void {
        if (self.walking) c.ts_tree_cursor_delete(&self.cursor);
        if (self.walk_tree) |t| c.ts_tree_delete(t);
        if (self.walk_alloc) |a| a.free(self.walk_text);
        self.walk_alloc = null;
        self.walk_tree = null;
        self.walk_text = &.{};
        self.walk_edits.clearRetainingCapacity();
        self.walk_dirty.clearRetainingCapacity();
        self.walk_dirty_all = false;
        self.walking = false;
    }

    /// 목록을 버린다 — 다음 `step` 이 처음부터 만든다.
    pub fn invalidate(self: *BracketIndex) void {
        self.stopWalk();
        self.ready = false;
        self.version += 1;
    }

    /// 편집 — 위치를 민다(`[start, old_end)` 가 `[start, new_end)` 가 됐다). 그 범위에 걸친 괄호는 버린다 — 다시 판 트리에서 `refresh` 가 채운다.
    /// 처음 훑기 도중이면 편집을 쌓고 다시 볼 범위를 민다(위 `walking`).
    pub fn shift(self: *BracketIndex, allocator: std.mem.Allocator, start: u32, old_end: u32, new_end: u32) void {
        if (self.walking) {
            self.walk_edits.append(allocator, .{ .start = start, .old_end = old_end, .new_end = new_end }) catch return self.invalidate();
            for (self.walk_dirty.items) |*r| r.* = shiftRange(r.*, start, old_end, new_end);
            return;
        }
        if (!self.ready) return;
        shiftLeaves(&self.leaves, start, old_end, new_end);
        self.version += 1;
    }

    fn shiftLeaves(leaves: *std.ArrayList(BracketLeaf), start: u32, old_end: u32, new_end: u32) void {
        const items = leaves.items;
        var w: usize = 0;
        for (items) |l| {
            const end = l.start + l.len;
            if (end <= start) {
                items[w] = l;
            } else if (l.start >= old_end) {
                var m = l;
                m.start = l.start - old_end + new_end;
                items[w] = m;
            } else continue; // 편집 범위에 걸쳤다 — 버린다
            w += 1;
        }
        leaves.items.len = w;
    }

    /// 범위를 편집 하나에 통과시킨다 — 앞이면 그대로, 뒤면 민다, 걸치면 편집 범위까지 넓힌다. 걸칠 때 넓히지 않아도 판정자에서 드러나지 않는다
    /// (적대적 2회차 N04 생존) — 뒤 편집이 자기 편집 범위와 달라진 범위를 따로 더하기 때문이다. 넓히는 것이 뜻이다: 범위는 편집을 지나도 같은
    /// 글을 덮어야 한다.
    fn shiftRange(r: Provider.ByteRange, start: u32, old_end: u32, new_end: u32) Provider.ByteRange {
        if (r.end < start) return r;
        if (r.start > old_end) return .{ .start = r.start - old_end + new_end, .end = r.end - old_end + new_end };
        return .{ .start = @min(r.start, start), .end = if (r.end > old_end) r.end - old_end + new_end else new_end };
    }

    /// 다시 판 트리에 맞춘다 — **편집 직후**(`Provider.onEdit` 다음)에 부른다. `edited` 는 편집 뒤 좌표의 바뀐 글자 범위(`[start, new_end)`).
    pub fn refresh(self: *BracketIndex, allocator: std.mem.Allocator, prov: *Provider, source: []const u8, edited: Provider.ByteRange) error{OutOfMemory}!void {
        var buf: [Provider.max_changed]Provider.ByteRange = undefined;
        const changed = prov.takeChanged(&buf);
        if (self.walking) {
            // 다 훑은 뒤에 다시 볼 범위로 모은다(좌표는 지금 트리 — 뒤 편집이 `shift` 에서 민다). 세대 검사는 제품에서 닿지 않는 방어다(적대적
            // 2회차 N06: 등가) — 파싱은 전부 편집 통지(`onEditSpan`)를 지나고, 범위를 모르는 다시 파기(`reparse`)는 목록을 버린다.
            if (changed == null or prov.tree_gen != self.walk_seen_gen + 1) self.walk_dirty_all = true;
            self.walk_seen_gen = prov.tree_gen;
            if (changed) |ch| for (ch) |r| try self.walk_dirty.append(allocator, r);
            try self.walk_dirty.append(allocator, edited);
            return;
        }
        if (!self.ready or prov.tree == null or prov.tree_gen != self.synced_gen + 1 or changed == null) {
            self.invalidate();
            return;
        }
        var ranges: [Provider.max_changed + 1]Provider.ByteRange = undefined;
        var n: usize = 0;
        for (changed.?) |r| {
            ranges[n] = r;
            n += 1;
        }
        ranges[n] = edited;
        n += 1;
        if (!try self.repair(allocator, prov, source, ranges[0..n])) {
            self.invalidate();
            return;
        }
        self.synced_gen = prov.tree_gen;
        self.partials += 1;
        self.version += 1;
    }

    /// `ranges`(지금 트리 좌표 — 정렬 안 됐어도 된다)만 지금 트리에서 다시 훑어 목록을 고친다. 합이 상한을 넘으면 거짓(고치지 않았다).
    fn repair(self: *BracketIndex, allocator: std.mem.Allocator, prov: *Provider, source: []const u8, ranges: []Provider.ByteRange) error{OutOfMemory}!bool {
        std.mem.sort(Provider.ByteRange, ranges, {}, struct {
            fn lt(_: void, a: Provider.ByteRange, b: Provider.ByteRange) bool {
                return a.start < b.start;
            }
        }.lt);
        // **CSS 는 함수 이름이 인자 속 글을 괄호로 볼지 정한다**(`url("…")`) — `foo` 를 `url` 로 바꾸면 트리 모양은 그대로라 달라진 범위가 이름만
        // 덮는다. 그래서 둘레 선언까지 넓힌다(새 눈 리뷰가 짚었다).
        const root = c.ts_tree_root_node(prov.tree orelse return false);
        if (bracketRuleFor(prov.slot.lang).css_url_strings) {
            for (ranges) |*r| {
                var node = c.ts_node_descendant_for_byte_range(root, r.start, r.end);
                while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
                    if (typeIn(node, &.{ "declaration", "rule_set" })) {
                        r.start = @min(r.start, c.ts_node_start_byte(node));
                        r.end = @max(r.end, c.ts_node_end_byte(node));
                        break;
                    }
                }
            }
            std.mem.sort(Provider.ByteRange, ranges, {}, struct {
                fn lt(_: void, a: Provider.ByteRange, b: Provider.ByteRange) bool {
                    return a.start < b.start;
                }
            }.lt);
        }
        var merged: usize = 0;
        for (ranges) |r| {
            if (merged > 0 and r.start <= ranges[merged - 1].end) {
                ranges[merged - 1].end = @max(ranges[merged - 1].end, r.end);
            } else {
                ranges[merged] = r;
                merged += 1;
            }
        }
        var total: u64 = 0;
        for (ranges[0..merged]) |r| total += r.end -| r.start;
        if (total > partial_limit) return false;
        var fresh: std.ArrayList(BracketLeaf) = .empty;
        defer fresh.deinit(allocator);
        // 뒤에서부터 고친다 — 앞 범위를 고쳐도 뒤 범위의 목록 자리가 안 흔들리게.
        var k = merged;
        while (k > 0) {
            k -= 1;
            const r = ranges[k];
            fresh.clearRetainingCapacity();
            var cover: Provider.ByteRange = r;
            try collectLeaves(allocator, root, source, prov.slot, r, &fresh, &cover);
            const lo = lowerBound(self.leaves.items, cover.start);
            const hi = lowerBound(self.leaves.items, cover.end);
            try self.leaves.replaceRange(allocator, lo, hi - lo, fresh.items);
        }
        return true;
    }

    /// 예산을 든 처음 훑기(한 프레임 몫). 목록이 맞으면(`ready`) 곧바로 참. 트리가 없으면 거짓(아직 못 만든다).
    pub fn step(self: *BracketIndex, allocator: std.mem.Allocator, prov: *Provider, source: []const u8, budget_ns: u64) error{OutOfMemory}!bool {
        if (self.ready and self.synced_gen == prov.tree_gen) return true;
        if (self.ready) self.invalidate(); // 파싱을 놓쳤다 — 부분만 고칠 수 없다
        if (!self.walking) {
            const tree = prov.tree orelse return false;
            self.leaves.clearRetainingCapacity();
            self.walk_text = try allocator.dupe(u8, source);
            self.walk_alloc = allocator;
            self.walk_tree = c.ts_tree_copy(tree);
            self.cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(self.walk_tree.?));
            self.walking = true;
            self.walk_seen_gen = prov.tree_gen;
        }
        const deadline = if (budget_ns == 0) std.math.maxInt(u64) else Provider.monotonicNs() +| budget_ns;
        var visited: usize = 0;
        const rule = bracketRuleFor(prov.slot.lang);
        while (true) {
            const node = c.ts_tree_cursor_current_node(&self.cursor);
            if (c.ts_node_child_count(node) == 0) {
                try leafBrackets(allocator, node, self.walk_text, prov.slot, &self.leaves);
            } else if (!skips(node, rule) and c.ts_tree_cursor_goto_first_child(&self.cursor)) continue;
            while (!c.ts_tree_cursor_goto_next_sibling(&self.cursor)) {
                if (!c.ts_tree_cursor_goto_parent(&self.cursor)) return self.finishWalk(allocator, prov, source);
            }
            visited += 1;
            if (visited % 512 == 0 and Provider.monotonicNs() >= deadline) return false;
        }
    }

    /// 사본을 다 훑었다 — 모은 괄호를 훑는 동안의 편집들에 통과시켜 지금 좌표로 옮기고, 다시 볼 범위만 지금 트리에서 고친다.
    fn finishWalk(self: *BracketIndex, allocator: std.mem.Allocator, prov: *Provider, source: []const u8) error{OutOfMemory}!bool {
        const dirty_all = self.walk_dirty_all or prov.tree == null or prov.tree_gen != self.walk_seen_gen;
        for (self.walk_edits.items) |ed| shiftLeaves(&self.leaves, ed.start, ed.old_end, ed.new_end);
        const dirty = try allocator.dupe(Provider.ByteRange, self.walk_dirty.items);
        defer allocator.free(dirty);
        const had_edits = self.walk_edits.items.len > 0;
        self.stopWalk();
        if (dirty_all or !(try self.repair(allocator, prov, source, dirty))) {
            // 훑는 동안 모르게 됐거나 너무 많이 바뀌었다 — 처음부터(다음 `step`).
            self.ready = false;
            self.version += 1;
            return false;
        }
        self.ready = true;
        self.synced_gen = prov.tree_gen;
        self.rebuilds += 1;
        if (had_edits) self.partials += 1;
        self.version += 1;
        return true;
    }

    /// `leaves` 에서 `start >= at` 인 첫 자리.
    fn lowerBound(leaves: []const BracketLeaf, at: u32) usize {
        var lo: usize = 0;
        var hi: usize = leaves.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (leaves[mid].start < at) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// `node` 아래에서 `r` 에 걸친 잎의 괄호를 문서 순서로 모은다. `cover` 는 걸친 잎들까지 넓힌 범위가 된다(잎이 범위 가장자리를 넘는다).
    fn collectLeaves(allocator: std.mem.Allocator, node: c.TSNode, source: []const u8, slot: Slot, r: Provider.ByteRange, out: *std.ArrayList(BracketLeaf), cover: *Provider.ByteRange) error{OutOfMemory}!void {
        const s = c.ts_node_start_byte(node);
        const e = c.ts_node_end_byte(node);
        // 걸치는가 — 폭 0 인 편집 범위(지우기)는 그 자리를 품거나 맞닿은 노드를 본다.
        if (e < r.start or s > r.end) return;
        const skip = skips(node, bracketRuleFor(slot.lang));
        if (c.ts_node_child_count(node) == 0 or skip) {
            const overlaps = if (r.start < r.end) s < r.end and e > r.start else s <= r.start and r.start <= e;
            if (!overlaps) return;
            cover.start = @min(cover.start, s);
            cover.end = @max(cover.end, e);
            if (skip) return; // 문자열 — 안의 괄호는 글자다(범위는 넓혀 옛 괄호를 걷는다)
            return leafBrackets(allocator, node, source, slot, out);
        }
        var cursor = c.ts_tree_cursor_new(node);
        defer c.ts_tree_cursor_delete(&cursor);
        // **범위를 지나면 멈춘다** — 원소 수십만인 평평한 목록(큰 JSON 배열 · C 데이터 표)에서 편집 한 번에 뒤 형제까지 전부 도는 것을 줄인다(새 눈
        // 리뷰가 짚었다). 앞 형제를 **건너뛰는** `ts_tree_cursor_goto_first_child_for_byte` 는 쓰지 않는다 — 자식의 끝을 `position + size` 로 세어
        // 앞 공백(padding)만큼 짧게 잡아, 범위에 걸친 자식을 건너뛰었다(`SYNU2` 가 되돌리기 퍼즈에서 색이 갈려 잡았다 · `tree_cursor.c` 원문).
        // TSNode 의 `ts_node_first_child_for_byte` 는 끝을 바르게 세지만 역시 자식을 처음부터 훑는다 — 앞쪽은 어느 길이든 선형이다.
        if (!c.ts_tree_cursor_goto_first_child(&cursor)) return;
        while (true) {
            const child = c.ts_tree_cursor_current_node(&cursor);
            // `>` 와 `>=` 는 같다(적대적 2회차 N18: 등가) — 범위 끝에서 시작하는 잎은 빈 범위(지우기)에서만 걸치는데, 그 잎은 `shift` 가 이미 그대로
            // 두었다(맞닿은 잎은 버리지 않는다). 토큰이 합쳐지는 지우기는 트리 모양이 바뀌어 달라진 범위가 덮는다.
            if (c.ts_node_start_byte(child) > r.end) break;
            try collectLeaves(allocator, child, source, slot, r, out, cover);
            if (!c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
        }
    }

    /// 잎 하나의 괄호들(§5.1d). **이름 없는 잎**(구두점 토큰) 속 괄호 글자마다 — 폭 0(`MISSING`)은 없다. 이름 있는 잎(문자열·주석·식별자)은
    /// 언어 규칙이 「글」로 든 것(`text_kinds`)만 센다. 언어별 거름은 `bracketRuleFor`.
    fn leafBrackets(allocator: std.mem.Allocator, node: c.TSNode, source: []const u8, slot: Slot, out: *std.ArrayList(BracketLeaf)) error{OutOfMemory}!void {
        const rule = bracketRuleFor(slot.lang);
        if (!rule.enabled) return;
        const s = c.ts_node_start_byte(node);
        const e = c.ts_node_end_byte(node);
        if (e <= s or e > source.len) return;
        const text = source[s..e];
        if (c.ts_node_is_named(node)) {
            if (rule.jsdoc and std.mem.startsWith(u8, text, "/**") and std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), "comment")) {
                return scanJsdoc(allocator, text, s, rule, out);
            }
            if (rule.css_url_strings and cssUrlString(node, source)) return scanText(allocator, text, s, rule, out);
            if (!typeIn(node, rule.text_kinds)) return;
            if (rule.text_skip_directives.len > 0) {
                // `#error` · `#warning` 의 본문은 글자다(VS Code 가 문자열로 둔다 — 오라클). `#pragma` 는 칠한다. 부모로 가르지 않는다 — 매크로 본문의
                // 부모는 오류 복구로 `ERROR` 가 되기도 한다(fmt `core.h` 의 `#else` 속 `#define` — 말뭉치 대조가 잡았다).
                const parent = c.ts_node_parent(node);
                if (!c.ts_node_is_null(parent) and typeIn(parent, &.{"preproc_call"})) {
                    const dir = c.ts_node_child(parent, 0);
                    const ds = c.ts_node_start_byte(dir);
                    const de = c.ts_node_end_byte(dir);
                    if (de <= source.len) {
                        var name = source[ds..de];
                        while (name.len > 0 and (name[0] == '#' or name[0] == ' ' or name[0] == '\t')) name = name[1..];
                        for (rule.text_skip_directives) |d| if (std.mem.eql(u8, name, d)) return;
                    }
                }
            }
            return scanText(allocator, text, s, rule, out);
        }
        // 퍼센트 리터럴의 여닫는 글자(Ruby `%w[…]` · `%Q(…)`)는 괄호가 아니다 — VS Code 문법이 문자열 구두점으로 낸다. 여는 쪽은 `%` 로 시작하는
        // 잎이고, 닫는 쪽은 따로 된 잎이라 부모의 첫 자식으로 가른다.
        if (rule.percent_literals) {
            if (text.len >= 2 and text[0] == '%') return;
            if (text.len == 1 and (text[0] == ']' or text[0] == ')' or text[0] == '}' or text[0] == '>')) {
                const parent = c.ts_node_parent(node);
                if (!c.ts_node_is_null(parent) and c.ts_node_child_count(parent) > 0) {
                    const first = c.ts_node_child(parent, 0);
                    const fs = c.ts_node_start_byte(first);
                    if (fs < source.len and source[fs] == '%' and c.ts_node_end_byte(first) - fs >= 2) return;
                }
            }
        }
        // `${`(JavaScript 계열 템플릿 보간) — 두 글자가 한 괄호다. TypeScript 는 괄호로 두되 칠하지 않는다(`colorizedBracketPairs` 가 뺀다).
        if (rule.dollar_brace != .no and std.mem.eql(u8, text, "${")) {
            return out.append(allocator, .{ .start = s, .len = 2, .close_kind = 2, .open_kind = 3, .open = true, .colorized = rule.colorize and rule.dollar_brace == .colored });
        }
        // `<` `>` 는 정해진 부모(타입 인자·매개변수) 아래서만 괄호다 — 비교·화살표·시프트는 아니다.
        if (text.len == 1 and (text[0] == '<' or text[0] == '>')) {
            if (rule.angle_parents.len == 0) return;
            const parent = c.ts_node_parent(node);
            if (c.ts_node_is_null(parent) or !typeIn(parent, rule.angle_parents)) return;
            // 타입 단언 `<T>expr` 의 꺾쇠는 괄호가 아니다(VS Code `unbalancedBracketScopes` 의 `meta.brace.angle`).
            const grand = c.ts_node_parent(parent);
            if (!c.ts_node_is_null(grand) and typeIn(grand, &.{"type_assertion"})) return;
            return out.append(allocator, .{ .start = s, .close_kind = 3, .open_kind = 4, .open = text[0] == '<', .colorized = rule.colorize });
        }
        if (rule.no_close_paren_parents.len > 0 and text.len == 1 and text[0] == ')') {
            const parent = c.ts_node_parent(node);
            // `case` 의 `(pat)` 꼴은 여는 `(` 가 있다 — 그때는 둘이 짝이다(VS Code 도 짝으로 칠한다, 오라클 실측). `pat)` 꼴의 `)` 만 괄호가 아니다.
            if (!c.ts_node_is_null(parent) and typeIn(parent, rule.no_close_paren_parents)) {
                const first = c.ts_node_child(parent, 0);
                const fs = c.ts_node_start_byte(first);
                if (!(c.ts_node_end_byte(first) == fs + 1 and fs < source.len and source[fs] == '(')) return;
            }
        }
        for (text, 0..) |ch, k| {
            if (std.mem.indexOfScalar(u8, rule.chars, ch) == null) continue;
            const b = Provider.bracketOf(ch) orelse continue;
            try out.append(allocator, .{ .start = s + @as(u32, @intCast(k)), .close_kind = b.kind, .open_kind = b.kind, .open = b.open, .colorized = rule.colorize });
        }
    }

    /// 글 잎 속 괄호 글자. C 어휘면(매크로 본문) 문자열·문자·주석을 건너뛴다.
    fn scanText(allocator: std.mem.Allocator, text: []const u8, base: u32, rule: BracketRule, out: *std.ArrayList(BracketLeaf)) error{OutOfMemory}!void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (rule.text_c_lexer) {
                if (ch == '"' or ch == '\'') {
                    i += 1;
                    while (i < text.len and text[i] != ch) : (i += 1) {
                        if (text[i] == '\\') i += 1;
                    }
                    continue;
                }
                if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') break;
                if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) : (i += 1) {}
                    i += 1;
                    continue;
                }
            }
            if (std.mem.indexOfScalar(u8, rule.chars, ch) == null) continue;
            const b = Provider.bracketOf(ch) orelse continue;
            try out.append(allocator, .{ .start = base + @as(u32, @intCast(i)), .close_kind = b.kind, .open_kind = b.kind, .open = b.open, .colorized = rule.colorize });
        }
    }

    /// JSDoc 주석(`/**`)의 **타입 표기와 인라인 태그** 속 괄호(VS Code 가 `tokenTypes` 로 Other 로 돌린다 — 오라클 실측): 블록 태그(`@param` 등)
    /// 바로 뒤의 `{…}`, 그리고 어디서든 `{@link …}` 같은 `{@…}`. 그 안의 `()` `[]` `{}` 가 괄호다(꺾쇠는 아니다). 설명 글의 `{…}` · `(…)` 와
    /// `@example` 코드는 글자다.
    fn scanJsdoc(allocator: std.mem.Allocator, text: []const u8, base: u32, rule: BracketRule, out: *std.ArrayList(BracketLeaf)) error{OutOfMemory}!void {
        var i: usize = 0;
        var after_tag = false; // 블록 태그 이름을 막 지났다(공백만 건넜다)
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch == '@' and (i == 0 or text[i - 1] != '{')) {
                var j = i + 1;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
                // 타입을 받는 블록 태그만(VS Code `JavaScript.tmLanguage.json` `docblock` 의 `(?={)` 규칙들) — `@host {x}` 는 아니다. **앞 글자는 안
                // 본다** — 그 규칙들에 뒤돌아보기가 없어 `x@param {T}` 도 칠한다(오라클 실측 · 처음엔 앞 글자를 봤다가 적대적 2회차 N13 이 짚었다).
                after_tag = isJsdocTypeTag(text[i + 1 .. j]);
                i = j - 1;
                continue;
            }
            if (after_tag and (ch == ' ' or ch == '\t')) continue;
            const inline_tag = ch == '{' and i + 1 < text.len and text[i + 1] == '@';
            if (ch == '{' and (after_tag or inline_tag)) {
                // 짝 `}` 까지(중괄호 깊이) — 그 사이의 괄호 글자를 센다.
                var depth: usize = 0;
                var j = i;
                while (j < text.len) : (j += 1) {
                    // 꺾쇠는 그 언어가 꺾쇠를 괄호로 칠 때만(TypeScript — 오라클 실측: `{Array<string>}` 의 `<>` 를 칠한다, JavaScript 는 안).
                    if (rule.angle_parents.len > 0 and (text[j] == '<' or text[j] == '>')) {
                        try out.append(allocator, .{ .start = base + @as(u32, @intCast(j)), .close_kind = 3, .open_kind = 4, .open = text[j] == '<', .colorized = rule.colorize });
                        continue;
                    }
                    const b = Provider.bracketOf(text[j]) orelse continue;
                    try out.append(allocator, .{ .start = base + @as(u32, @intCast(j)), .close_kind = b.kind, .open_kind = b.kind, .open = b.open, .colorized = rule.colorize });
                    if (b.kind == 2) {
                        if (b.open) depth += 1 else depth -= 1;
                        if (depth == 0) break;
                    }
                }
                i = j;
            }
            after_tag = false;
        }
    }

    /// CSS `url("…")` 의 따옴표 속 글인가 — VS Code 가 `tokenTypes`(`meta.function.url string.quoted` → other)로 그 괄호를 칠한다.
    fn cssUrlString(node: c.TSNode, source: []const u8) bool {
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(node)), "string_content")) return false;
        const str = c.ts_node_parent(node);
        if (c.ts_node_is_null(str)) return false;
        const args = c.ts_node_parent(str);
        if (c.ts_node_is_null(args)) return false;
        const call = c.ts_node_parent(args);
        if (c.ts_node_is_null(call) or !std.mem.eql(u8, std.mem.span(c.ts_node_type(call)), "call_expression")) return false;
        const name = c.ts_node_child(call, 0);
        const ns = c.ts_node_start_byte(name);
        const ne = c.ts_node_end_byte(name);
        return ne <= source.len and std.ascii.eqlIgnoreCase(source[ns..ne], "url");
    }

    /// 타입 표기(`{…}`)를 받는 JSDoc 블록 태그 — VS Code JavaScript 문법 `docblock` 에서 `\s+(?={)` 로 `#jsdoctype` 을 여는 목록 그대로.
    fn isJsdocTypeTag(name: []const u8) bool {
        const tags = [_][]const u8{ "template", "typedef", "arg", "argument", "const", "constant", "member", "namespace", "param", "prop", "property", "var", "define", "enum", "exception", "export", "extends", "lends", "implements", "modifies", "private", "protected", "return", "returns", "satisfies", "suppress", "this", "throws", "type", "yield", "yields" };
        for (tags) |t| if (std.mem.eql(u8, name, t)) return true;
        return false;
    }

    /// 들어가지 않는 노드인가(문자열 — 그 안의 괄호는 글자다).
    fn skips(node: c.TSNode, rule: BracketRule) bool {
        return rule.skip_kinds.len > 0 and typeIn(node, rule.skip_kinds);
    }
};

/// 노드 종류가 목록에 있는가.
fn typeIn(node: c.TSNode, kinds: []const []const u8) bool {
    if (kinds.len == 0) return false;
    const t = std.mem.span(c.ts_node_type(node));
    for (kinds) |k| if (std.mem.eql(u8, t, k)) return true;
    return false;
}

/// 언어마다 무엇이 괄호인가(visual-mapping §5.1d 「언어별」 — VS Code 1.139 의 TextMate 문법을 돌린 오라클과 대조해 정했다).
pub const BracketRule = struct {
    /// 괄호를 세는가. Markdown 은 안 센다 — VS Code 는 짝 없는 괄호를 빨갛게 칠하지만 우리 블록 grammar 는 인라인 코드를 못 갈라 코드 속 괄호가
    /// 거짓 빨강이 된다(오라클 대조: 같음 11 · 거짓 빨강 74 — 없는 편이 낫다).
    enabled: bool = true,
    /// 이 언어의 괄호 글자(언어 설정의 `brackets`) — HTML 은 `()` `{}` 뿐(`[]` 없음), JSON 은 `[]` `{}` 뿐(`()` 없음).
    chars: []const u8 = "()[]{}",
    /// 색칠 쌍이 있는가. 없는 언어(HTML · Markdown — `colorizedBracketPairs: []`)는 **짝 없는 괄호만** 칠한다(무효는 색칠 쌍과 무관하다).
    colorize: bool = true,
    /// 들어가지 않는 노드 — 문자열이고 그 안의 보간 괄호도 글자다(Bash 큰따옴표 · PHP · Kotlin). Python f-string · Ruby `#{}` · JS 템플릿은
    /// VS Code 가 칠하므로 여기 없다.
    skip_kinds: []const []const u8 = &.{},
    /// 괄호 글자를 세는 **이름 있는 잎**(글 — JSX 본문 · HTML 본문·속성값 · C 매크로 본문 · Python f-string 의 `{{`).
    text_kinds: []const []const u8 = &.{},
    /// 이 지시어의 본문(`preproc_call` 의 글)은 세지 않는다 — C `#error` · `#warning`(VS Code 가 문자열로 둔다, 오라클 실측).
    text_skip_directives: []const []const u8 = &.{},
    /// 글 잎을 C 어휘로 훑는다(매크로 본문 — 문자열·문자·주석은 건너뛴다).
    text_c_lexer: bool = false,
    /// `${` 를 한 괄호로 — JavaScript 는 칠하고 TypeScript 는 괄호로만 둔다.
    dollar_brace: enum { no, colored, plain } = .no,
    /// `<` `>` 가 괄호인 부모(TypeScript 의 타입 인자·매개변수).
    angle_parents: []const []const u8 = &.{},
    /// JSDoc 주석의 타입 표기·인라인 태그 속 괄호를 센다(JavaScript 계열).
    jsdoc: bool = false,
    /// CSS `url("…")` 의 따옴표 속 괄호를 센다.
    css_url_strings: bool = false,
    /// 퍼센트 리터럴 구분자(`%w[`)는 괄호가 아니다(Ruby).
    percent_literals: bool = false,
    /// 이 부모의 `)` 는 괄호가 아니다(Bash `case` 패턴 — VS Code 는 package.json 의 낡은 scope 이름 탓에 이것을 튀는 괄호로 칠한다. 결함이라
    /// 따르지 않는다).
    no_close_paren_parents: []const []const u8 = &.{},
};

pub fn bracketRuleFor(lang: Language) BracketRule {
    return switch (lang) {
        .javascript => .{ .dollar_brace = .colored, .text_kinds = &.{"jsx_text"}, .jsdoc = true },
        .typescript => .{ .dollar_brace = .plain, .angle_parents = &.{ "type_arguments", "type_parameters" }, .jsdoc = true },
        .tsx => .{ .dollar_brace = .plain, .angle_parents = &.{ "type_arguments", "type_parameters" }, .text_kinds = &.{"jsx_text"}, .jsdoc = true },
        .bash => .{ .skip_kinds = &.{ "string", "heredoc_body" }, .no_close_paren_parents = &.{"case_item"} },
        .php => .{ .skip_kinds = &.{ "encapsed_string", "heredoc", "nowdoc", "shell_command_expression" } },
        .ruby => .{ .percent_literals = true },
        .kotlin => .{ .skip_kinds = &.{"string_literal"} },
        .c => .{ .text_kinds = &.{"preproc_arg"}, .text_skip_directives = &.{ "error", "warning" }, .text_c_lexer = true },
        .cpp => .{ .text_kinds = &.{"preproc_arg"}, .text_skip_directives = &.{ "error", "warning" }, .text_c_lexer = true, .skip_kinds = &.{"raw_string_literal"} },
        .python => .{ .text_kinds = &.{"escape_interpolation"} },
        .html => .{ .colorize = false, .text_kinds = &.{ "text", "attribute_value" }, .chars = "(){}" },
        .json => .{ .chars = "[]{}" },
        .css => .{ .css_url_strings = true },
        .markdown => .{ .enabled = false },
        else => .{},
    };
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

test "SYN40 구문 오류 — ERROR 는 가장 바깥 것 하나, MISSING 은 1 byte 와 기대 토큰, 깨끗한 트리는 0 (§5.4)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Provider.SyntaxError) = .empty;
    defer out.deinit(allocator);

    // 깨끗한 소스 — 아무것도 없다.
    {
        var prov = Provider.init("const a = 1;\npub fn f() void {}\n", .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(try prov.syntaxErrors(allocator, &out));
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
    // 닫는 괄호가 없다 — MISSING 하나(1 byte, 기대 토큰이 온다).
    {
        const src = "pub fn f() void {\n    const a = (1 + 2;\n    _ = a;\n}\n";
        var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(try prov.syntaxErrors(allocator, &out));
        try std.testing.expect(out.items.len >= 1);
        var missing: ?Provider.SyntaxError = null;
        for (out.items) |e| if (e.missing) {
            missing = e;
        };
        const m = missing orelse return error.NoMissing;
        try std.testing.expectEqual(m.start + 1, m.end);
        try std.testing.expect(m.expected.len > 0);
        try std.testing.expect(m.start <= src.len);
    }
    // 쓰레기 토큰 — ERROR 노드. 그 안에 무엇이 있든 **하나**다(안쪽은 접는다).
    {
        const src = "pub fn f() void {\n    @@@ ((( !!! ))) @@@\n}\n";
        var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(try prov.syntaxErrors(allocator, &out));
        var errors: usize = 0;
        var covers = false;
        for (out.items) |e| {
            if (e.missing) continue;
            errors += 1;
            try std.testing.expect(e.end > e.start);
            const at = std.mem.indexOf(u8, src, "@@@") orelse unreachable;
            if (e.start <= at and e.end > at) covers = true;
        }
        try std.testing.expect(errors >= 1);
        try std.testing.expect(covers);
        // 순서는 문서 순.
        var prev: u32 = 0;
        for (out.items) |e| {
            try std.testing.expect(e.start >= prev);
            prev = e.start;
        }
    }
    // **안쪽 ERROR 는 접힌다** — 이 소스는 ERROR 안에 ERROR 가 둘 더 겹친다(안 접으면 [0,35)·[19,33)·[28,32) 셋, 실측). 가장
    // 바깥 하나만이고 어떤 두 항목도 겹치지 않는다(적대적 1회차 A9: 위 두 픽스처는 중첩이 없어 안 보였다).
    {
        const src = "fn f( void { const a = (1 + ; @@@ }\n";
        var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(try prov.syntaxErrors(allocator, &out));
        var errors: usize = 0;
        for (out.items) |e| {
            if (!e.missing) errors += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), errors);
        for (out.items, 0..) |a, i| {
            for (out.items[i + 1 ..]) |b| try std.testing.expect(a.end <= b.start or b.end <= a.start);
        }
    }
    // **뿌리가 ERROR 여도 파일 전체가 진단이 되지 않는다** — 함수 셋 중 하나가 깨진 문서에서 tree-sitter 는 뿌리를 ERROR 로 낸다.
    // 제품 캡처에서 스무 줄이 전부 빨갰다(2026-09-17 실측). 뿌리는 늘 내려가고, 남는 것은 안쪽의 작은 범위들이다.
    {
        const src = "const std = @import(\"std\");\n\npub fn ok(a: u32) u32 {\n    return a + 1;\n}\n\npub fn broken(a: u32) u32 {\n    const b = (a + 2;\n    return b;\n}\n\npub fn garbage() void {\n    @@@ ((( !!!\n}\n\npub fn tail() void {\n    return;\n}\n";
        var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(try prov.syntaxErrors(allocator, &out));
        try std.testing.expect(out.items.len >= 2); // MISSING `)` 와 쓰레기 토큰
        for (out.items) |e| try std.testing.expect(e.end - e.start < 16); // 어느 것도 문서를 통째로 덮지 않는다
        var has_missing = false;
        for (out.items) |e| if (e.missing) {
            has_missing = true;
        };
        try std.testing.expect(has_missing);
    }
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

test "SYN29 같은 줄에서 시작하면 «가장 긴 것» 하나만 남는다 (§4.1f)" {
    // **gutter 화살표는 줄마다 하나다.** 그래서 시작 줄마다 후보가 하나여야 하고, 여럿이면
    // "이 화살표가 무엇을 접는가"가 정해지지 않는다 — 이 함수의 머리말이 그 근거를 적는다.
    // **어느 것을 남기느냐가 규칙이다**: 짧은 쪽을 남기면 화살표를 눌러도 바깥 블록이 안 접혀
    // 「접었는데 그대로」로 보인다. 판정자가 없어 그 변이가 살아남았다(적대적 검증 Y8).
    const allocator = std.testing.allocator;
    // **바깥과 안쪽이 «같은 줄에서» 시작하고 «다른 줄에서» 끝나야 두 뜻이 갈린다** — 끝이 같으면
    // 긴 쪽과 짧은 쪽의 답이 같아 픽스처가 개념을 안 가른다. 처음에 `} };` 로 닫는 세 줄짜리를
    // 썼다가 실측으로 걸렸다: 안쪽과 바깥이 **같은 줄에서 끝나** 스팬이 `(0,2)` 하나뿐이었고,
    // 「짧은 쪽을 남긴다」 변이가 그대로 살아남았다. 바깥이 안쪽보다 **더 내려가야** 한다.
    const src =
        \\const a = .{ .x = .{
        \\    1,
        \\},
        \\    .y = 2,
        \\};
        \\const b = 3;
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer spans.deinit(allocator);
    try prov.foldSpans(allocator, &spans);

    // 0행에서 시작하는 것은 **하나**이고, 그것이 **바깥**(4행까지)이다 — 안쪽은 2행에서 끝난다.
    var found: usize = 0;
    var end_row: u32 = 0;
    for (spans.items) |sp| {
        if (sp.start_row != 0) continue;
        found += 1;
        end_row = sp.end_row;
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    try std.testing.expectEqual(@as(u32, 4), end_row); // 안쪽(2행)이 아니라 바깥이다
}

test "SYN28 접힘 범위는 할당 실패를 «보고»한다 — 빈 목록으로 떨어지지 않는다 (§4·§5)" {
    // **색과 접힘은 실패의 뜻이 다르다.** 색(`spansForRange`)은 무색으로 저하돼도 다음 프레임이
    // 다시 칠하지만, 접힘은 부르는 쪽이 빈 목록을 「접을 것이 없다」로 읽고 **다시 세지 않도록
    // 래치**한다 — 그래서 실패를 삼키면 일시적 할당 실패가 그 문서의 구문 접힘을 **영영** 없앤다.
    // 실측으로 잡았다(2026-09-10 — 승격의 첫 할당을 실패시키니 접힘이 사라진 채 래치했다).
    const allocator = std.testing.allocator;
    const src =
        \\const items = .{
        \\    1,
        \\    2,
        \\};
        \\pub fn f() void {
        \\    _ = 1;
        \\}
    ;
    var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();

    // **먼저 성공했을 때의 할당 수를 센다** — 그 수가 0 이면 아래 순회가 공허하다.
    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var counted: std.ArrayList(Provider.FoldSpan) = .empty;
    try prov.foldSpans(counting.allocator(), &counted);
    const n = counting.alloc_index;
    const spans_found = counted.items.len;
    counted.deinit(counting.allocator());
    try std.testing.expect(n > 0);
    try std.testing.expect(spans_found > 0); // 픽스처가 실제로 접을 것을 준다

    // **모든 할당 자리에서 실패시켜 본다** — 빈 목록이 아니라 «오류» 가 와야 한다.
    for (0..n) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var spans: std.ArrayList(Provider.FoldSpan) = .empty;
        defer spans.deinit(failing.allocator());
        try std.testing.expectError(error.OutOfMemory, prov.foldSpans(failing.allocator(), &spans));
        try std.testing.expect(failing.has_induced_failure);
    }

    // **그리고 성공 경로는 그대로다** — 오류를 내게 만들면서 정상 답까지 바꾸면 안 된다.
    var ok_spans: std.ArrayList(Provider.FoldSpan) = .empty;
    defer ok_spans.deinit(allocator);
    try prov.foldSpans(allocator, &ok_spans);
    try std.testing.expectEqual(spans_found, ok_spans.items.len);
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
    try prov.foldSpans(allocator, &spans);

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
    try prov.foldSpans(allocator, &spans);
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
        try prov.foldSpans(allocator, &spans);
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
    try prov.foldSpans(allocator, &spans);

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

test "SYN41 끊긴 여는 파싱 뒤 문서가 바뀌면 처음부터 다시 판다 — 반쯤 판 상태를 새 문서에 이어 붙이지 않는다 (§2.1a)" {
    // **§2.1a 계약의 셋째 줄이다**: *"재개 도중 문서가 바뀌면 `ts_parser_reset` 하고 새 내용으로 다시 시작한다."*
    // 파서는 끊긴 파싱을 **자기 안에 들고 있다가** 다음 호출에서 이어 판다 — 그때 넘긴 원문이 달라도 그대로 잇는다
    // (`api.h` 의 `ts_parser_reset` 주석). 그래서 이미 읽은 앞부분이 **길이가 바뀌게** 달라지면 byte 위치가 어긋나
    // 트리가 틀린다(오류 노드가 서고 노드가 엉뚱한 byte 를 가리킨다). 백업 복원이 그 경로다 — 여는 파싱이 끊긴 채로
    // 문서 전체를 갈아 끼운다(`editor_backup.restoreFromRecord`).
    //
    // **편집은 길이를 바꿔야 한다.** 길이가 같은 변경(숫자 하나)은 위치가 안 어긋나 reset 이 없어도 같은 트리가 나온다
    // (실측 2026-09-23: 같은 길이 0/6, 삽입·삭제 9/9 틀어짐) — 그 픽스처로는 이 판정자가 늘 초록이다.
    const allocator = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(allocator);
    var i: usize = 0;
    while (i < 400) : (i += 1) try src.print(allocator, "pub fn f{d}() void {{ _ = {d}; }}\n", .{ i, i });

    var prov = Provider.init("", .zig, 0) orelse return error.SkipZigTest;
    defer prov.deinit();
    // 1ns 예산 = 첫 콜백에서 끊긴다(`SYN26` 과 같은 수법 — 기계 속도에 안 기댄다).
    if (prov.setSourceBudgeted(src.items, 1) == .done) return error.SkipZigTest;

    // 앞머리에 한 줄을 넣는다 — 이미 읽힌 범위 안이고 길이가 바뀐다.
    const memo = "// memo\n";
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(allocator);
    try edited.appendSlice(allocator, memo);
    try edited.appendSlice(allocator, src.items);
    prov.onEdit(edited.items, .{
        .start_byte = 0,
        .old_end_byte = 0,
        .new_end_byte = memo.len,
        .start_point = .{ .row = 0, .column = 0 },
        .old_end_point = .{ .row = 0, .column = 0 },
        .new_end_point = .{ .row = 1, .column = 0 },
    });

    var fresh = Provider.init(edited.items, .zig, 0) orelse return error.NoProvider;
    defer fresh.deinit();
    const got_tree = prov.tree orelse return error.NoTree; // 예산 없는 편집 경로는 끝까지 판다
    const want_tree = fresh.tree orelse return error.NoTree;
    const got_root = c.ts_tree_root_node(got_tree);
    try std.testing.expect(!c.ts_node_has_error(got_root));
    // **새로 판 트리와 모양이 같다** — 오류가 없다는 것만으로는 노드가 엉뚱한 byte 를 가리키는 틀림을 못 거른다.
    const got = c.ts_node_string(got_root);
    defer std.c.free(got);
    const want = c.ts_node_string(c.ts_tree_root_node(want_tree));
    defer std.c.free(want);
    try std.testing.expectEqualStrings(std.mem.span(want), std.mem.span(got));
    try std.testing.expectEqual(c.ts_node_start_byte(c.ts_node_child(c.ts_tree_root_node(want_tree), 0)), c.ts_node_start_byte(c.ts_node_child(got_root, 0)));

    // **통째로 다시 파는 입구(`setSource` — 범위를 모르는 편집이 `reparse` 로 온다)도 같다.** 다시 끊어 놓고 다른 원문으로 판다.
    var prov2 = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer prov2.deinit();
    if (prov2.setSourceBudgeted(src.items, 1) == .done) return error.SkipZigTest;
    prov2.setSource(edited.items);
    const got2 = c.ts_node_string(c.ts_tree_root_node(prov2.tree orelse return error.NoTree));
    defer std.c.free(got2);
    try std.testing.expectEqualStrings(std.mem.span(want), std.mem.span(got2));

    // **예산을 든 증분이 끊긴 뒤 다음 편집**(트리가 있는 갈래). 첫 편집(앞머리 `// memo`)을 1ns 로 끊으면 옛 트리가 남고
    // 파서는 그 편집의 반쯤 판 상태를 든다. 이어서 둘째 편집(앞머리에 한 줄 더)이 오면 새 내용으로 처음부터 판다.
    var prov3 = Provider.init(src.items, .zig, 0) orelse return error.NoProvider;
    defer prov3.deinit();
    const first: Edit = .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = memo.len, .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 1, .column = 0 } };
    prov3.onEditBudgeted(edited.items, first, 1);
    if (prov3.tree == null) return error.NoTree; // 끊겨도 옛 트리로 그린다(§2.1a)
    const memo2 = "// again\n";
    var edited2: std.ArrayList(u8) = .empty;
    defer edited2.deinit(allocator);
    try edited2.appendSlice(allocator, memo2);
    try edited2.appendSlice(allocator, edited.items);
    prov3.onEdit(edited2.items, .{ .start_byte = 0, .old_end_byte = 0, .new_end_byte = memo2.len, .start_point = .{ .row = 0, .column = 0 }, .old_end_point = .{ .row = 0, .column = 0 }, .new_end_point = .{ .row = 1, .column = 0 } });
    var fresh3 = Provider.init(edited2.items, .zig, 0) orelse return error.NoProvider;
    defer fresh3.deinit();
    const got3 = c.ts_node_string(c.ts_tree_root_node(prov3.tree orelse return error.NoTree));
    defer std.c.free(got3);
    const want3 = c.ts_node_string(c.ts_tree_root_node(fresh3.tree orelse return error.NoTree));
    defer std.c.free(want3);
    try std.testing.expectEqualStrings(std.mem.span(want3), std.mem.span(got3));
}

test "SYN42 조상 범위 — 안쪽부터 뿌리까지, 같은 범위는 한 번, 트리 없으면 빈 목록 (tooling §8.2q)" {
    // **되는가를 먼저 잰다**(구현 전 반증 실험): 저장소가 한 번도 안 부른 `ts_node_parent`·`ts_node_descendant_for_byte_range`
    // 로 세 언어에서 사슬이 서는지. 식별자 하나를 품는 사슬이 **그 식별자 → 식 → … → 뿌리** 로 커지는지 본다.
    const allocator = std.testing.allocator;
    const Case = struct { lang: Language, src: []const u8, expr: []const u8 };
    const cases = [_]Case{
        .{ .lang = .zig, .src = "pub fn f(a: u32) u32 {\n    return a + 1;\n}\n", .expr = "a + 1" },
        .{ .lang = .typescript, .src = "function f(a: number) {\n  return a + 1;\n}\n", .expr = "a + 1" },
        .{ .lang = .c, .src = "int f(int a) {\n  return a + 1;\n}\n", .expr = "a + 1" },
    };
    var out: std.ArrayList(Provider.ByteRange) = .empty;
    defer out.deinit(allocator);
    for (cases) |cs| {
        var prov = Provider.init(cs.src, cs.lang, 0) orelse return error.NoProvider;
        defer prov.deinit();
        const at: u32 = @intCast(std.mem.indexOf(u8, cs.src, cs.expr).?);
        try prov.enclosingRanges(allocator, at, at + 1, &out); // `a` 한 글자(식별자)
        try std.testing.expect(out.items.len >= 4); // a → a + 1 → return 문 → … → 뿌리(단 수는 문법마다 다르다)
        try std.testing.expectEqual(at, out.items[0].start);
        try std.testing.expectEqual(at + 1, out.items[0].end);
        // 안쪽부터 바깥 — 매 단계가 앞 단계를 품고 **같지 않다**.
        for (out.items[1..], 0..) |r, i| {
            const prev = out.items[i];
            try std.testing.expect(r.start <= prev.start and r.end >= prev.end);
            try std.testing.expect(!(r.start == prev.start and r.end == prev.end));
        }
        var has_expr = false; // 이항식 노드가 사슬에 있다
        for (out.items) |r| {
            if (r.start == at and r.end == at + cs.expr.len) has_expr = true;
        }
        try std.testing.expect(has_expr);
        try std.testing.expectEqual(@as(u32, 0), out.items[out.items.len - 1].start); // 마지막은 뿌리
    }
    // **부모가 자식과 같은 범위면 한 번만** — 끝 개행이 없는 문서는 뿌리와 그 선언이 같은 byte 를 덮는다. 위 세 픽스처에는 그런 쌍이 없어
    // 거름을 빼도 초록이었다(적대적 2회차 T1b) — 그 쌍이 **실제로 있는지** 먼저 단언하고 잰다.
    {
        const src = "const x = 1;";
        var prov = Provider.init(src, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        const root = c.ts_tree_root_node(prov.tree.?);
        const first = c.ts_node_child(root, 0);
        try std.testing.expectEqual(c.ts_node_start_byte(root), c.ts_node_start_byte(first));
        try std.testing.expectEqual(c.ts_node_end_byte(root), c.ts_node_end_byte(first));
        const one: u32 = @intCast(std.mem.indexOfScalar(u8, src, '1').?);
        try prov.enclosingRanges(allocator, one, one + 1, &out);
        for (out.items[1..], 0..) |r, i| try std.testing.expect(!(r.start == out.items[i].start and r.end == out.items[i].end));
        try std.testing.expectEqual(@as(u32, 0), out.items[out.items.len - 1].start);
        try std.testing.expectEqual(@as(u32, src.len), out.items[out.items.len - 1].end);
    }
    // 트리가 없으면 빈 목록(끊긴 여는 파싱 · 상한 초과 — §2.1a). 앞 내용이 남아 있어도 비운다.
    var empty = Provider.init("", .zig, 0) orelse return error.NoProvider;
    defer empty.deinit();
    try out.append(allocator, .{ .start = 9, .end = 9 });
    try empty.enclosingRanges(allocator, 0, 0, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "SYN43 조상 범위 상한 — 아주 깊은 트리에서도 max_enclosing 에서 멈춘다 (tooling §8.2q)" {
    const allocator = std.testing.allocator;
    // `(` 를 상한보다 깊게 겹친 식 — 단마다 서로 다른 범위다.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(allocator);
    try src.appendSlice(allocator, "const x = ");
    var i: usize = 0;
    while (i < Provider.max_enclosing + 50) : (i += 1) try src.append(allocator, '(');
    try src.append(allocator, '1');
    i = 0;
    while (i < Provider.max_enclosing + 50) : (i += 1) try src.append(allocator, ')');
    try src.appendSlice(allocator, ";\n");
    var prov = Provider.init(src.items, .zig, 0) orelse return error.NoProvider;
    defer prov.deinit();
    const one: u32 = @intCast(std.mem.indexOfScalar(u8, src.items, '1').?);
    var out: std.ArrayList(Provider.ByteRange) = .empty;
    defer out.deinit(allocator);
    try prov.enclosingRanges(allocator, one, one + 1, &out);
    try std.testing.expectEqual(Provider.max_enclosing, out.items.len);
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

test "SYN44 괄호 토큰의 짝·문자열 속 괄호·감싸는 쌍 — 코드 언어 열여섯 (visual-mapping §5.1b ⓐⓒ)" {
    // 표본마다 셋을 잰다: ① 호출 괄호의 짝(양쪽에서), ② 문자열 속 '(' 는 괄호 토큰이 아니고 글 잎도 아니다(ⓒ), ③ 그 문자열 속 자리를
    // 품는 가장 안쪽 쌍이 ①이다. `open` 은 끝 글자가 여는 괄호인 유일한 조각, `close` 는 첫 글자가 닫는 괄호인 유일한 조각, `inner` 는 첫
    // 글자가 문자열 속 '(' 인 유일한 조각. **Bash `$(`** 는 괄호가 다른 글자와 붙은 토큰이다 — 「한 글자 잎」만 보면 여기서 깨진다(Zig `.{` 는
    // 처음에 그런 토큰으로 알고 넣었는데 노드를 찍어 보니 `.` 과 `{` 두 토큰이었다 — 표본은 여느 `{` 로 남는다).
    const samples = [_]struct { lang: Language, src: []const u8, open: []const u8, close: []const u8, inner: []const u8 }{
        .{ .lang = .zig, .src = "const a = f(.{ \"(\", x });\n", .open = ".{", .close = "})", .inner = "(\"," },
        .{ .lang = .json, .src = "{\"k\": [\"(\", 1]}\n", .open = "[", .close = "]}", .inner = "(\"," },
        .{ .lang = .javascript, .src = "f(\"(\", [x]);\n", .open = "f(", .close = ");", .inner = "(\"," },
        .{ .lang = .typescript, .src = "f(\"(\", [x]);\n", .open = "f(", .close = ");", .inner = "(\"," },
        .{ .lang = .tsx, .src = "f(\"(\", [x]);\n", .open = "f(", .close = ");", .inner = "(\"," },
        .{ .lang = .c, .src = "int m(void) { f(\"(\", a[0]); }\n", .open = "f(", .close = "); }", .inner = "(\"," },
        .{ .lang = .cpp, .src = "int m() { f(\"(\", a[0]); }\n", .open = "f(", .close = "); }", .inner = "(\"," },
        .{ .lang = .python, .src = "f(\"(\", [x])\n", .open = "f(", .close = ")\n", .inner = "(\"," },
        .{ .lang = .go, .src = "package m\n\nfunc g() { f(\"(\", x) }\n", .open = "f(", .close = ") }", .inner = "(\"," },
        .{ .lang = .rust, .src = "fn g() { f(\"(\", [x]); }\n", .open = "f(", .close = "); }", .inner = "(\"," },
        .{ .lang = .java, .src = "class A { void g() { f(\"(\", x); } }\n", .open = "f(", .close = "); }", .inner = "(\"," },
        .{ .lang = .ruby, .src = "f(\"(\", [x])\n", .open = "f(", .close = ")\n", .inner = "(\"," },
        .{ .lang = .php, .src = "<?php f(\"(\", [$x]);\n", .open = "f(", .close = ");", .inner = "(\"," },
        .{ .lang = .kotlin, .src = "fun g() { f(\"(\", x) }\n", .open = "f(", .close = ") }", .inner = "(\"," },
        .{ .lang = .bash, .src = "echo $(printf \"(\")\n", .open = "$(", .close = ")\n", .inner = "(\")" },
        .{ .lang = .css, .src = "a { b: f(\"(\", 1); }\n", .open = "f(", .close = "); }", .inner = "(\"," },
    };
    for (samples) |s| {
        errdefer std.debug.print("SYN44 언어 {s}\n", .{@tagName(s.lang)});
        var prov = Provider.init(s.src, s.lang, 0) orelse return error.NoProvider;
        defer prov.deinit();
        const o: u32 = @intCast(std.mem.indexOf(u8, s.src, s.open).? + s.open.len - 1);
        const cl: u32 = @intCast(std.mem.indexOf(u8, s.src, s.close).?);
        const in: u32 = @intCast(std.mem.indexOf(u8, s.src, s.inner).?);
        const want: Provider.BracketPair = .{ .open = o, .close = cl };
        try std.testing.expectEqual(@as(?Provider.BracketPair, want), prov.bracketTokenPair(s.src, o));
        try std.testing.expectEqual(@as(?Provider.BracketPair, want), prov.bracketTokenPair(s.src, cl));
        // **붙은 토큰의 앞 글자는 괄호가 아니다**(`$(` 의 `$`; Zig `.{` 의 `.` 은 따로 된 토큰이라 당연히 아니다). 이 단언은 약속을 못박을 뿐
        // 적대적 T4 를 가르지는 못한다 — 그 변이는 짝짓기가 물은 byte 로 다시 거른다(T4 주석).
        if (s.open.len > 1) try std.testing.expectEqual(@as(?Provider.BracketPair, null), prov.bracketTokenPair(s.src, o - 1));
        try std.testing.expectEqual(@as(?Provider.BracketPair, null), prov.bracketTokenPair(s.src, in));
        try std.testing.expectEqual(@as(?Provider.ByteRange, null), prov.proseLeafAt(in)); // 코드 언어 — 글 잎이 없다
        try std.testing.expectEqual(@as(?Provider.BracketPair, want), prov.enclosingBracketTokens(s.src, in));
        try std.testing.expectEqual(@as(?Provider.BracketPair, want), prov.enclosingBracketTokens(s.src, in + 1));
        // **여는 괄호 토큰인가**(문서 모델 §3.9c ③ 「다음 여는 괄호」) — 여는 괄호만, 문자열 속은 아니다, 붙은 토큰의 앞 글자도 아니다
        try std.testing.expect(prov.isOpenBracketToken(s.src, o));
        try std.testing.expect(!prov.isOpenBracketToken(s.src, cl));
        try std.testing.expect(!prov.isOpenBracketToken(s.src, in));
        if (s.open.len > 1) try std.testing.expect(!prov.isOpenBracketToken(s.src, o - 1));
    }
    // **안 닫힌 여는 괄호도 토큰이다** — VS Code 가 「다음 괄호」로 친다(`x| ) (` → `(` 앞)
    {
        const src = "f(x) + g(\n";
        var prov = Provider.init(src, .javascript, 0) orelse return error.NoProvider;
        defer prov.deinit();
        try std.testing.expect(prov.isOpenBracketToken(src, 8));
        try std.testing.expect(!prov.isOpenBracketToken(src, 99)); // 범위 밖
    }
}

test "SYN45 글 속 괄호 — 마크다운은 토큰, HTML 본문은 글 잎 (visual-mapping §5.1b ⓐⓑ)" {
    // **마크다운 블록 grammar 는 괄호를 토큰으로 낸다** — 본문 `inline` · 목록 · 코드 펜스 · 코드 스팬 모두(실측). 그래서 글 잎 갈래가 필요
    // 없다. 계획은 「마크다운 본문은 긴 잎 하나」라 가정했는데 노드 사슬을 찍어 보니 `[`·`]`·`(`·`)` 가 `inline` 의 이름 없는 자식이었다.
    const md = "# 제목\n\n본문 [링크](url) 과 (괄호\n\n```js\nf(a)\n```\n";
    var pm = Provider.init(md, .markdown, 0) orelse return error.NoProvider;
    defer pm.deinit();
    const lb: u32 = @intCast(std.mem.indexOf(u8, md, "[").?);
    const rb: u32 = @intCast(std.mem.indexOf(u8, md, "]").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = lb, .close = rb }), pm.bracketTokenPair(md, lb));
    const lp: u32 = rb + 1; // `](url)` 의 '('
    const rp: u32 = @intCast(std.mem.indexOf(u8, md, ")").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = lp, .close = rp }), pm.bracketTokenPair(md, rp));
    const lone: u32 = @intCast(std.mem.indexOf(u8, md, "(괄호").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), pm.bracketTokenPair(md, lone)); // 안 닫혔다
    const f_open: u32 = @intCast(std.mem.indexOf(u8, md, "f(").? + 1);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = f_open, .close = f_open + 2 }), pm.bracketTokenPair(md, f_open)); // 코드 펜스
    try std.testing.expectEqual(@as(?Provider.ByteRange, null), pm.proseLeafAt(lb)); // 마크다운은 글 잎 표시가 없다

    // **평평한 형제 — 한 목록 안에서 쌍이 포갠다.** 마크다운 `inline` 은 괄호 토큰을 자식으로 늘어놓으므로(코드 언어는 안쪽 괄호가 자식 노드로
    // 내려간다) 여기서만 ① 같은 목록 안의 「가장 안쪽」(적대적 1회차 T8 — 바깥을 골라도 초록이었다)과 ② 같은 종류의 깊이(T12 — 상한 1 로
    // 줄여도 초록이었다)가 관측된다.
    const flat = "본문 [a (b) c] 와 ((x)) 끝\n";
    var pf = Provider.init(flat, .markdown, 0) orelse return error.NoProvider;
    defer pf.deinit();
    const b_at: u32 = @intCast(std.mem.indexOf(u8, flat, "b)").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = b_at - 1, .close = b_at + 1 }), pf.enclosingBracketTokens(flat, b_at));
    const x_at: u32 = @intCast(std.mem.indexOf(u8, flat, "x").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = x_at - 2, .close = x_at + 2 }), pf.bracketTokenPair(flat, x_at - 2)); // 바깥
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = x_at - 1, .close = x_at + 1 }), pf.bracketTokenPair(flat, x_at + 1)); // 안쪽

    // **HTML 본문은 긴 잎(`text`)이다** — 괄호 토큰이 없고, 글 잎 범위가 그 괄호를 품는다.
    const html = "<p>보기 (a) 끝</p>\n";
    var ph = Provider.init(html, .html, 0) orelse return error.NoProvider;
    defer ph.deinit();
    const hp: u32 = @intCast(std.mem.indexOf(u8, html, "(a)").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), ph.bracketTokenPair(html, hp));
    const leaf = ph.proseLeafAt(hp) orelse return error.NoProseLeaf;
    try std.testing.expect(leaf.start <= hp and hp + 2 < leaf.end); // 쌍 전체가 잎 안
    try std.testing.expect(leaf.end - leaf.start > 3);

    // **코드 언어는 글 잎이 없다** — 같은 모양의 긴 잎(주석)이어도 `prose_brackets` 가 거짓이면 `null`(그 안의 괄호는 적힌 글자다).
    const js = "// 보기 (a) 끝\nx;\n";
    var pj = Provider.init(js, .javascript, 0) orelse return error.NoProvider;
    defer pj.deinit();
    try std.testing.expectEqual(@as(?Provider.ByteRange, null), pj.proseLeafAt(@intCast(std.mem.indexOf(u8, js, "(a)").?)));
}

test "SYN46 짝 없는 괄호·가장 안쪽 쌍·트리가 없을 때 (visual-mapping §5.1b)" {
    // 안 닫힌 '(' — 오류 복구가 폭 0 인 `MISSING` ')' 를 끼워도 그것은 짝이 아니다.
    const broken = "const a = f(1;\n";
    var p1 = Provider.init(broken, .zig, 0) orelse return error.NoProvider;
    defer p1.deinit();
    const o: u32 = @intCast(std.mem.indexOf(u8, broken, "(").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), p1.bracketTokenPair(broken, o));

    // 가장 안쪽 — 같은 형제 목록 안에서 처음 닫히는 품는 쌍, 그리고 조상보다 자식이 먼저.
    const nested = "f(g(a), [b])\n";
    var p2 = Provider.init(nested, .javascript, 0) orelse return error.NoProvider;
    defer p2.deinit();
    const g_open: u32 = @intCast(std.mem.indexOf(u8, nested, "g(").? + 1);
    const a_at: u32 = @intCast(std.mem.indexOf(u8, nested, "a)").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = g_open, .close = a_at + 1 }), p2.enclosingBracketTokens(nested, a_at));
    const b_at: u32 = @intCast(std.mem.indexOf(u8, nested, "b]").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = b_at - 1, .close = b_at + 1 }), p2.enclosingBracketTokens(nested, b_at));
    const comma: u32 = @intCast(std.mem.indexOf(u8, nested, ", ").?);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = 1, .close = @intCast(nested.len - 2) }), p2.enclosingBracketTokens(nested, comma));
    // **닫는 괄호 바로 앞은 품는다**(`pos ≤ close`) — 제품에서는 그 자리가 먼저 「닿은 괄호」로 답해져 이 갈래에 안 오지만(적대적 1회차 T7:
    // 제품 등가), 이 함수의 약속은 여기서 못박는다.
    const outer_close: u32 = @intCast(nested.len - 2);
    try std.testing.expectEqual(@as(?Provider.BracketPair, .{ .open = 1, .close = outer_close }), p2.enclosingBracketTokens(nested, outer_close));
    // 여는 괄호 바로 앞·닫는 괄호 바로 뒤는 품지 않는다(`open < pos ≤ close`)
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), p2.enclosingBracketTokens(nested, 1));
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), p2.enclosingBracketTokens(nested, @intCast(nested.len - 1)));

    // 범위 밖 byte 는 없다
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), p2.bracketTokenPair(nested, 999));

    // **괄호가 둘 붙은 토큰은 괄호가 아니다**(Bash `((`·`))`·`[[`·`]]`) — 어느 괄호인지 못 정한다. 마지막 것을 고르면 `((`·`))` 가 쌍으로
    // 선다(적대적 1회차 T2 — 코드 표본에 그런 토큰이 없어 살아남았다).
    const bash = "(( x + 1 ))\n[[ -n x ]]\n";
    var pb = Provider.init(bash, .bash, 0) orelse return error.NoProvider;
    defer pb.deinit();
    for ([_][]const u8{ "(( ", " ))", "[[ ", " ]]" }) |tok| {
        const at: u32 = @intCast(std.mem.indexOf(u8, bash, tok).?);
        const lo: u32 = if (tok[0] == ' ') at + 1 else at;
        try std.testing.expectEqual(@as(?Provider.BracketPair, null), pb.bracketTokenPair(bash, lo));
        try std.testing.expectEqual(@as(?Provider.BracketPair, null), pb.bracketTokenPair(bash, lo + 1));
    }

    // **이름 있는 짧은 잎은 괄호 토큰이 아니다** — 템플릿 문자열의 조각 `(`·`)` 는 같은 부모의 형제로 서서, 이름을 안 보면 문자열 속 두
    // 글자가 쌍이 된다(적대적 1회차 T3 — `"("` 는 짝이 없어 변이도 `null` 이었다).
    const tpl = "f(`(${a})`);\n";
    var pt = Provider.init(tpl, .javascript, 0) orelse return error.NoProvider;
    defer pt.deinit();
    const in_open: u32 = @intCast(std.mem.indexOf(u8, tpl, "`(").? + 1);
    const in_close: u32 = @intCast(std.mem.indexOf(u8, tpl, "})").? + 1);
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), pt.bracketTokenPair(tpl, in_open));
    try std.testing.expectEqual(@as(?Provider.BracketPair, null), pt.bracketTokenPair(tpl, in_close));
}

fn pointOfForTest(src: []const u8, at: usize) Point {
    var row: u32 = 0;
    var col: u32 = 0;
    for (src[0..at]) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
        } else col += 1;
    }
    return .{ .row = row, .column = col };
}

fn fullIndexForTest(allocator: std.mem.Allocator, prov: *Provider, source: []const u8) !BracketIndex {
    var idx: BracketIndex = .{};
    errdefer idx.deinit(allocator);
    if (!try idx.step(allocator, prov, source, 0)) return error.NoTree;
    return idx;
}

test "SYN47 괄호 목록 — 편집마다 민 위치 + 달라진 범위만 다시 훑은 목록이 처음부터 만든 것과 같다; 잘게 나눈 처음 훑기도 같다 (visual-mapping §5.1d)" {
    // 큰 문서에서 트리 전체를 훑으면 편집 한 번에 36~49 ms 라(§5.1d 실측) 증분으로 간다. 증분의 위험은 **조용히 틀린 목록**이다 — 그래서 편집마다
    // 처음부터 만든 목록과 괄호 하나까지 맞춘다. 편집 글자는 구조를 흔드는 것들(괄호 · 따옴표 · 주석 여는 글자 · 템플릿 · 줄바꿈)이다.
    const allocator = std.testing.allocator;
    const docs = [_]struct { lang: Language, src: []const u8 }{
        .{ .lang = .zig, .src = "const a = f(.{ \"(\", x });\n// ( [\nfn g() void {\n    if (x) { y[0] = (1 + 2); }\n}\n" },
        .{ .lang = .typescript, .src = "function f<T>(a: Array<T>): T { return a[0] ?? `${a}`; }\n/* { */ const b = [1, (2), {c: 3}];\n" },
        .{ .lang = .javascript, .src = "const s = `x${(a)}y`; f(\"(\", [1]);\n// }\nif (a) { b(); }\n" },
        .{ .lang = .python, .src = "def f(a, b=[1, 2]):\n    return {'k': (a, b)}  # (\nx = f\"{a}\"\n" },
        .{ .lang = .c, .src = "int m(void) { f(\"(\", a[0]); /* [ */ return (1); }\n" },
        .{ .lang = .bash, .src = "echo $(printf \"(\") ${x} [[ -n a ]]\ncase x in a) echo;; esac\n" },
        .{ .lang = .json, .src = "{\"k\": [\"(\", 1, {\"z\": []}]}\n" },
        .{ .lang = .rust, .src = "fn g(x: &[u8]) -> Vec<u8> { let c = |a| (a); vec![c(1)] }\n#[derive(Debug)] struct S {}\n" },
        // 새 눈 리뷰 뒤 — 다른 잎의 글자로 판정하는 규칙(CSS `url` 의 함수 이름 · Ruby 퍼센트 리터럴 · Bash `case`)과 들어가지 않는 노드(heredoc ·
        // raw string)가 있는 언어. CSS 는 `foo` ↔ `url` 이름 바꾸기가 트리 모양을 안 바꿔 달라진 범위가 인자를 안 덮는다(그래서 선언까지 넓힌다).
        .{ .lang = .css, .src = "a { b: url(\"q(1)\"); c: foo(\"q(2)\"); d: f([x]) }\n" },
        .{ .lang = .ruby, .src = "s = %w[a b].map { |x| x[0] }\nt = \"#{f(1)}\" + %Q(p)\n" },
        .{ .lang = .php, .src = "<?php\n$s = <<<EOT\n{$a['k']} (x\nEOT;\nf($a[0], `ls (x`);\n" },
        .{ .lang = .tsx, .src = "const e = <div a={f(1)}>(t) [x]</div>; let m: Map<K, V[]>;\n" },
        .{ .lang = .cpp, .src = "auto s = R\"(abc)\"; int f() { return (1); }\n" },
        .{ .lang = .bash, .src = "case x in (a) f ;; b) g ;; esac\ncat <<EOF\n$(d) (x\nEOF\n" },
    };
    const inserts = [_][]const u8{ "(", ")", "{", "}", "[", "]", "\"", "'", "//", "/*", "*/", "\n", "x", "${", "`", " (a)", "{[}]", "url", "%w[", "<<EOF\n", "R\"(" };
    var prng = std.Random.DefaultPrng.init(0xb1ac_5047);
    const r = prng.random();
    var partials: u64 = 0;
    var steps: usize = 0;
    for (docs) |d| {
        errdefer std.debug.print("SYN47 언어 {s}\n", .{@tagName(d.lang)});
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendSlice(allocator, d.src);
        var prov = Provider.init(text.items, d.lang, 0) orelse return error.NoProvider;
        defer prov.deinit();

        // 잘게 나눈 처음 훑기(1 ns 예산 — 512 노드마다 끊긴다) = 한 번에 만든 것
        var idx: BracketIndex = .{};
        defer idx.deinit(allocator);
        var rounds: usize = 0;
        while (!try idx.step(allocator, &prov, text.items, 1)) rounds += 1;
        {
            var full = try fullIndexForTest(allocator, &prov, text.items);
            defer full.deinit(allocator);
            try std.testing.expectEqualSlices(BracketLeaf, full.leaves.items, idx.leaves.items);
            try std.testing.expect(idx.leaves.items.len > 0);
        }

        const rebuilds_before = idx.rebuilds;
        for (0..60) |step_i| {
            const len = text.items.len;
            const start = r.uintLessThan(usize, len + 1);
            var old_end = start;
            var ins: []const u8 = "";
            if (r.boolean() and len > 0) {
                old_end = @min(len, start + r.uintLessThan(usize, 12));
            } else ins = inserts[r.uintLessThan(usize, inserts.len)];
            const at = pointOfForTest(text.items, start);
            const old_to = pointOfForTest(text.items, old_end);
            try text.replaceRange(allocator, start, old_end - start, ins);
            const new_end = start + ins.len;
            prov.onEdit(text.items, .{
                .start_byte = @intCast(start),
                .old_end_byte = @intCast(old_end),
                .new_end_byte = @intCast(new_end),
                .start_point = at,
                .old_end_point = old_to,
                .new_end_point = pointOfForTest(text.items, new_end),
            });
            idx.shift(allocator, @intCast(start), @intCast(old_end), @intCast(new_end));
            try idx.refresh(allocator, &prov, text.items, .{ .start = @intCast(start), .end = @intCast(new_end) });
            const ready = try idx.step(allocator, &prov, text.items, 0); // 부분 고침을 못 했으면(범위를 모른다) 처음부터
            if (prov.tree == null) {
                // 문서를 다 지웠다 — 트리가 없으면 목록도 없다(맞는 것이 없으니 준비가 안 된 것으로)
                try std.testing.expect(!ready);
                continue;
            }
            var full = try fullIndexForTest(allocator, &prov, text.items);
            defer full.deinit(allocator);
            try std.testing.expectEqualSlices(BracketLeaf, full.leaves.items, idx.leaves.items);
            // **여는 파싱 뒤 첫 편집도 부분 고침이다** — 처음엔 여는 파싱의 「범위 모름」이 남아 첫 편집이 늘 처음부터였다(큰 문서에선 그동안 색이 빈다).
            if (step_i == 0 and idx.rebuilds != rebuilds_before) return error.FirstEditRebuilt;
            steps += 1;
        }
        partials += idx.partials;
    }
    // 판정자가 증분 갈래를 실제로 지났다 — 전부 처음부터 만들었다면 위 대조는 공허하다
    try std.testing.expect(partials * 2 > steps);
}

test "SYN48 괄호 목록 — 처음 훑기 도중의 편집은 훑기를 다시 시작하지 않고, 다 훑으면 처음부터 만든 것과 같다 (visual-mapping §5.1d)" {
    // 처음엔 훑는 도중 편집이 오면 처음부터 다시 훑었다 — 4 MB 문서는 20~28 프레임이 걸려, 그보다 빨리 계속 치면 색이 영영 안 왔다(새 눈 리뷰).
    // 지금은 사본(트리·글)을 끝까지 훑고, 쌓인 편집에 모은 괄호를 통과시킨 뒤 다시 볼 범위만 고친다. 1 ns 예산으로 512 노드마다 끊어 편집을 끼운다.
    const allocator = std.testing.allocator;
    const unit = "fn g(a: u8) void {\n    if (a) { y[0] = (1 + f(.{ \"(\", x })); }\n}\n// ( [\n";
    var prng = std.Random.DefaultPrng.init(0x5e48_0001);
    const r = prng.random();
    const inserts = [_][]const u8{ "(", ")", "{", "}", "[", "]", "\"", "//", "\n", "x", " (a)" };
    for (0..6) |round| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (0..120) |_| try text.appendSlice(allocator, unit);
        var prov = Provider.init(text.items, .zig, 0) orelse return error.NoProvider;
        defer prov.deinit();
        var idx: BracketIndex = .{};
        defer idx.deinit(allocator);
        var steps: usize = 0;
        var edits_during_walk: usize = 0;
        while (!try idx.step(allocator, &prov, text.items, 1)) : (steps += 1) {
            if (steps == 1) {
                // **편집 범위 밖까지 바꾸는 편집** — 괄호가 든 줄 머리에 `//` 를 넣으면 그 줄의 괄호가 전부 주석이 된다. 편집 범위(두 글자)만 다시
                // 보면 사본에서 모은 그 줄의 괄호가 남는다 — 달라진 범위를 모아야 한다(무작위 편집이 이것을 못 만들어 그 수집을 뺀 변이가 살아남았다 —
                // 적대적 2회차 N05b).
                const at_line = std.mem.indexOfPos(u8, text.items, text.items.len / 2, "    if (a)") orelse return error.NoLine;
                const at = pointOfForTest(text.items, at_line);
                try text.insertSlice(allocator, at_line, "//");
                idx.shift(allocator, @intCast(at_line), @intCast(at_line), @intCast(at_line + 2));
                prov.onEdit(text.items, .{ .start_byte = @intCast(at_line), .old_end_byte = @intCast(at_line), .new_end_byte = @intCast(at_line + 2), .start_point = at, .old_end_point = at, .new_end_point = pointOfForTest(text.items, at_line + 2) });
                try idx.refresh(allocator, &prov, text.items, .{ .start = @intCast(at_line), .end = @intCast(at_line + 2) });
                try std.testing.expect(idx.walking);
                edits_during_walk += 1;
                continue;
            }
            if (steps == 2) {
                // **문자열이던 글이 코드가 되는 편집** — `"(", x` 의 여는 따옴표를 지우면 그 뒤 `(`·`)` 가 괄호가 된다. 새로 생긴 괄호는 지운 자리에
                // 안 걸쳐 편집 범위로는 못 찾는다 — 달라진 범위만 안다(위 `//` 는 줄 끝까지 가는 주석 잎 하나가 편집에 걸쳐 편집 범위만으로도 맞았다).
                const q = std.mem.indexOfPos(u8, text.items, text.items.len / 3, "\"(\", x") orelse return error.NoQuote;
                const at = pointOfForTest(text.items, q);
                const old_to = pointOfForTest(text.items, q + 1);
                try text.replaceRange(allocator, q, 1, "");
                idx.shift(allocator, @intCast(q), @intCast(q + 1), @intCast(q));
                prov.onEdit(text.items, .{ .start_byte = @intCast(q), .old_end_byte = @intCast(q + 1), .new_end_byte = @intCast(q), .start_point = at, .old_end_point = old_to, .new_end_point = at });
                try idx.refresh(allocator, &prov, text.items, .{ .start = @intCast(q), .end = @intCast(q) });
                edits_during_walk += 1;
                continue;
            }
            if (steps % 3 != 0) continue;
            // 편집 — 제품 순서(민다 → 판다 → 고친다)
            const len = text.items.len;
            const start = r.uintLessThan(usize, len + 1);
            var old_end = start;
            var ins: []const u8 = "";
            if (r.boolean() and len > 0) old_end = @min(len, start + r.uintLessThan(usize, 8)) else ins = inserts[r.uintLessThan(usize, inserts.len)];
            const at = pointOfForTest(text.items, start);
            const old_to = pointOfForTest(text.items, old_end);
            try text.replaceRange(allocator, start, old_end - start, ins);
            const new_end = start + ins.len;
            idx.shift(allocator, @intCast(start), @intCast(old_end), @intCast(new_end));
            prov.onEdit(text.items, .{ .start_byte = @intCast(start), .old_end_byte = @intCast(old_end), .new_end_byte = @intCast(new_end), .start_point = at, .old_end_point = old_to, .new_end_point = pointOfForTest(text.items, new_end) });
            try idx.refresh(allocator, &prov, text.items, .{ .start = @intCast(start), .end = @intCast(new_end) });
            if (idx.walking) edits_during_walk += 1;
            if (steps > 200_000) return error.WalkNeverFinished;
        }
        errdefer std.debug.print("SYN48 round {d} steps {d} edits {d}\n", .{ round, steps, edits_during_walk });
        try std.testing.expect(edits_during_walk > 0); // 판정자가 그 갈래를 실제로 지났다
        try std.testing.expectEqual(@as(u64, 1), idx.rebuilds); // 다시 시작하지 않았다
        var full = try fullIndexForTest(allocator, &prov, text.items);
        defer full.deinit(allocator);
        try std.testing.expectEqualSlices(BracketLeaf, full.leaves.items, idx.leaves.items);
    }
}

test "SYN49 CSS 함수 이름만 바꿔도(`foo` ↔ `url`) 증분 목록이 처음부터와 같다 — 달라진 범위를 선언까지 넓힌다 (visual-mapping §5.1d)" {
    // `url("…")` 의 따옴표 속 괄호를 셀지가 **다른 잎(함수 이름)의 글자**에 달렸다. 이름만 바꾸면 트리 모양이 그대로라 달라진 범위가 이름 잎만 덮고
    // 인자는 재사용돼 다시 안 훑는다(새 눈 리뷰). 무작위 퍼즈(SYN47)는 이 이름 바꾸기를 못 만들어 「넓히기」를 뺀 변이가 살아남았다(적대적 2회차 N14).
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "a { b: foo(\"q(1)\"); c: url(\"r(2)\"); }\n");
    var prov = Provider.init(text.items, .css, 0) orelse return error.NoProvider;
    defer prov.deinit();
    var idx: BracketIndex = .{};
    defer idx.deinit(allocator);
    _ = try idx.step(allocator, &prov, text.items, 0);
    const renames = [_]struct { at: usize, old: []const u8, new: []const u8 }{
        .{ .at = 7, .old = "foo", .new = "url" }, // 인자 속 `(1)` 이 괄호가 된다
        .{ .at = 23, .old = "url", .new = "foo" }, // 인자 속 `(2)` 가 글자가 된다
    };
    for (renames) |rn| {
        try std.testing.expectEqualStrings(rn.old, text.items[rn.at .. rn.at + rn.old.len]);
        const at = pointOfForTest(text.items, rn.at);
        const old_to = pointOfForTest(text.items, rn.at + rn.old.len);
        try text.replaceRange(allocator, rn.at, rn.old.len, rn.new);
        const new_end = rn.at + rn.new.len;
        idx.shift(allocator, @intCast(rn.at), @intCast(rn.at + rn.old.len), @intCast(new_end));
        prov.onEdit(text.items, .{ .start_byte = @intCast(rn.at), .old_end_byte = @intCast(rn.at + rn.old.len), .new_end_byte = @intCast(new_end), .start_point = at, .old_end_point = old_to, .new_end_point = pointOfForTest(text.items, new_end) });
        try idx.refresh(allocator, &prov, text.items, .{ .start = @intCast(rn.at), .end = @intCast(new_end) });
        try std.testing.expect(idx.ready); // 부분 고침으로 갔다
        var full = try fullIndexForTest(allocator, &prov, text.items);
        defer full.deinit(allocator);
        try std.testing.expectEqualSlices(BracketLeaf, full.leaves.items, idx.leaves.items);
    }
    try std.testing.expectEqual(@as(u64, 2), idx.partials);
}

test "SYN50 다음 여는 괄호 — 트리 걷기가 모든 자리에서 정의(글자마다 괄호 토큰·글 잎)와 같다; HTML 주석·스크립트 속은 아니다 (문서 모델 §3.9c ③)" {
    const samples = [_]struct { lang: Language, src: []const u8 }{
        .{ .lang = .javascript, .src = "// f(x)\nconst s = \"(\" + `a${b(1)}`; /* [ */ g(h[0], {k: 1}) ) (\n" },
        .{ .lang = .typescript, .src = "let a: Array<number> = [1]; f<T>(x) // (\n" },
        // **괄호가 첫 글자인 토큰** `{|`(Flow 식 정확 객체 타입) — caret 이 `{` 와 `|` 사이면 토큰은 caret 뒤에서 끝나지만 그 괄호는 caret
        // 앞이다: 「다음」이 아니다(적대적 2회차 K04 — 번들 grammar 의 문법 파일 스무 개 중 괄호가 끝 글자가 아닌 토큰은 TS·TSX 의 `{|` 뿐이다)
        .{ .lang = .typescript, .src = "type A = {| a: (1) |};\n" },
        .{ .lang = .python, .src = "x = '(' # [\ndef f(a, b=[1]): return {a: (b)}\n" },
        .{ .lang = .bash, .src = "echo \"$(date)\" ; f() { x; } # (\n" },
        .{ .lang = .zig, .src = "const a = f(.{ \"(\", x }); // [\n" },
        .{ .lang = .c, .src = "#define M(x) (x)\nint m(void) { return a[0]; } /* ( */\n" },
        .{ .lang = .html, .src = "<p>a ) (b) [c]</p><!-- (x) --><script>s = \"(\";</script><style>a{}</style>\n" },
        // 글 잎 사이에 괄호 든 주석 — 글 잎 **시작보다 앞**의 caret 에서 주석 속 '(' 를 건너뛰어야 한다; 글 속 `{`; 속성 값 속 `(`
        .{ .lang = .html, .src = "x <!-- ( --> y {z} <!-- [ --> <a onclick=\"f(q)\">v</a>\n" },
        // PHP 의 `text`(PHP 밖 HTML)는 글 잎이 아니다 — 글이 괄호를 담는 언어 표시가 없다
        .{ .lang = .php, .src = "a (b) <?php f(1); ?> c [d]\n" },
        // **속성 이름**(Angular `(click)`·`[value]`) — `attribute_name` 잎이다
        .{ .lang = .html, .src = "<button (click)=\"go()\" [value]=\"v\">x</button>\n" },
        .{ .lang = .markdown, .src = "# t (a)\n\n- [x] b ( c\n\n```\n(code)\n```\n" },
    };
    for (samples) |sm| {
        errdefer std.debug.print("SYN50 언어 {s}\n", .{@tagName(sm.lang)});
        var prov = Provider.init(sm.src, sm.lang, 0) orelse return error.NoProvider;
        defer prov.deinit();
        for (0..sm.src.len + 1) |pos| {
            errdefer std.debug.print("SYN50 pos={d}\n", .{pos});
            var want: ?u32 = null;
            for (pos..sm.src.len) |j| {
                const ch = sm.src[j];
                if (ch != '(' and ch != '[' and ch != '{') continue;
                if (prov.isOpenBracketToken(sm.src, @intCast(j)) or prov.isProseTextAt(@intCast(j))) {
                    want = @intCast(j);
                    break;
                }
            }
            try std.testing.expectEqual(want, prov.nextOpenBracket(sm.src, @intCast(pos)));
        }
    }
    // **HTML — 글(`text`)의 괄호만**: `a ) (b)` 의 '(' 는 치고(앞의 ')' 는 닫는 괄호라 건너뛴다), 주석 `(x)`·스크립트 문자열 `"("` 는 글이 아니다
    const html = "<p>a ) (b)</p><!-- (x) --><script>s = \"(\";</script>\n";
    var hp = Provider.init(html, .html, 0) orelse return error.NoProvider;
    defer hp.deinit();
    const open_b: u32 = @intCast(std.mem.indexOf(u8, html, "(b").?);
    try std.testing.expectEqual(@as(?u32, open_b), hp.nextOpenBracket(html, 0));
    const after_p: u32 = @intCast(std.mem.indexOf(u8, html, "<!--").?);
    try std.testing.expectEqual(@as(?u32, null), hp.nextOpenBracket(html, after_p));
    try std.testing.expectEqual(@as(?Provider.ByteRange, null), hp.proseLeafAt(@intCast(std.mem.indexOf(u8, html, "(x").?)));
    try std.testing.expectEqual(@as(?u32, null), hp.nextOpenBracket(html, @intCast(html.len)));
    // 스크립트 본문(`raw_text`)은 짝·감싸는 쌍에는 든다(보이는 판정) — `f(x)` 의 짝
    const js_open: u32 = @intCast(std.mem.indexOf(u8, html, "s = ").?);
    try std.testing.expect(hp.proseLeafAt(js_open) != null);
    try std.testing.expect(!hp.isProseTextAt(js_open));
    // 명시 단언 — 주석 뒤 글의 `{`, 속성 값의 `(`, PHP 의 글은 안 친다
    const h2 = "x <!-- ( --> y {z} <a onclick=\"f(q)\">v</a>\n";
    var hp2 = Provider.init(h2, .html, 0) orelse return error.NoProvider;
    defer hp2.deinit();
    try std.testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, h2, "{z").?)), hp2.nextOpenBracket(h2, 0));
    const after_z: u32 = @intCast(std.mem.indexOf(u8, h2, "} ").? + 1);
    try std.testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, h2, "(q").?)), hp2.nextOpenBracket(h2, after_z));
    // **걸음 수** — caret 앞에서 끝난 가지는 통째로 건너뛴다: 함수 1,000 개(각 노드 스무 개 남짓) 뒤 마지막 줄의 caret 에서 걸음은 최상위
    // 형제 수 자릿수다. 가지를 안 건너뛰면(모든 노드를 내려가면) 그 열 배를 넘는다. 초판(글자마다 루트에서 내려가기)의 44 초가 이 축이다.
    {
        var big: std.ArrayList(u8) = .empty;
        defer big.deinit(std.testing.allocator);
        for (0..1000) |_| try big.appendSlice(std.testing.allocator, "function f() { a(b(c(d)), [1, 2]); }\n");
        const tail_at: u32 = @intCast(big.items.len);
        try big.appendSlice(std.testing.allocator, "x + (y);\n");
        var bp = Provider.init(big.items, .javascript, 0) orelse return error.NoProvider;
        defer bp.deinit();
        try std.testing.expectEqual(@as(?u32, tail_at + 4), bp.nextOpenBracket(big.items, tail_at));
        try std.testing.expect(bp.next_open_visits > 1000 and bp.next_open_visits < 1100);
    }
    // 속성 이름 `(click)` — 짝이 서고(강조·닿은 점프), 그 앞 caret 의 다음 여는 괄호다(VS Code 도 짝짓는다 — 적대적 3회차 F1)
    const ng = "<button (click)=\"go()\">x</button>\n";
    var np = Provider.init(ng, .html, 0) orelse return error.NoProvider;
    defer np.deinit();
    const click: u32 = @intCast(std.mem.indexOf(u8, ng, "(click").?);
    try std.testing.expect(np.proseLeafAt(click) != null);
    try std.testing.expectEqual(@as(?u32, click), np.nextOpenBracket(ng, 0));
    // 주석은 여전히 아니다
    try std.testing.expectEqual(@as(?Provider.ByteRange, null), hp.proseLeafAt(@intCast(std.mem.indexOf(u8, html, "(x").?)));
    const php = "a (b) <?php $x = 1; ?> c\n";
    var pp = Provider.init(php, .php, 0) orelse return error.NoProvider;
    defer pp.deinit();
    try std.testing.expectEqual(@as(?u32, null), pp.nextOpenBracket(php, 0));
}

test "SYN51 형제 쌍 메모와 한 번 걷기 — 모든 자리에서 메모 없이·caret 마다 따로 물은 답과 같다 (문서 모델 §3.9c — 커서가 많은 점프)" {
    const a = std.testing.allocator;
    const samples = [_]struct { lang: Language, src: []const u8 }{
        .{ .lang = .javascript, .src = "// f(x)\nconst s = \"(\" + `a${b(1)}`; /* [ */ g(h[0], {k: 1}) ) (\nf([1, [2, (3)]], {a: {b: []}});\n" },
        .{ .lang = .typescript, .src = "type A = {| a: (1) |};\nlet a: Array<number> = [1]; f<T>(x) // (\n" },
        .{ .lang = .python, .src = "x = '(' # [\ndef f(a, b=[1]): return {a: (b)}\n" },
        .{ .lang = .bash, .src = "echo \"$(date)\" ; f() { x; } # (\n" },
        .{ .lang = .html, .src = "<p>a ) (b) [c]</p><!-- (x) --><button (click)=\"go()\">x</button><script>f(\"(\");</script>\n" },
        .{ .lang = .zig, .src = "const a = f(.{ \"(\", x }); // [\nfn g() void { h(&.{ 1, 2 }); }\n" },
        // 한 부모 아래 괄호 토큰이 여럿 — 종류가 엇갈려(`( [ ) ]`) 닫히는 순서와 여는 순서가 다르다
        .{ .lang = .javascript, .src = "x = ( [ ) ] ( ( ) [ ] ) ;\n" },
    };
    for (samples) |sm| {
        errdefer std.debug.print("SYN51 언어 {s}\n", .{@tagName(sm.lang)});
        var prov = Provider.init(sm.src, sm.lang, 0) orelse return error.NoProvider;
        defer prov.deinit();
        const n = sm.src.len + 1;
        const plain_tok = try a.alloc(?Provider.BracketPair, n);
        defer a.free(plain_tok);
        const plain_enc = try a.alloc(?Provider.BracketPair, n);
        defer a.free(plain_enc);
        const plain_next = try a.alloc(?u32, n);
        defer a.free(plain_next);
        for (0..n) |i| {
            plain_tok[i] = prov.bracketTokenPair(sm.src, @intCast(i));
            plain_enc[i] = prov.enclosingBracketTokens(sm.src, @intCast(i));
            plain_next[i] = prov.nextOpenBracket(sm.src, @intCast(i));
        }
        // 메모를 세우고 — 같은 부모를 여러 번 묻도록 모든 자리를 두 바퀴
        var memo = Provider.PairMemo.init(a);
        defer memo.deinit();
        prov.memo = &memo;
        defer prov.memo = null;
        for (0..2) |_| for (0..n) |i| {
            errdefer std.debug.print("SYN51 pos={d}\n", .{i});
            try std.testing.expectEqual(plain_tok[i], prov.bracketTokenPair(sm.src, @intCast(i)));
            try std.testing.expectEqual(plain_enc[i], prov.enclosingBracketTokens(sm.src, @intCast(i)));
        };
        try std.testing.expect(memo.map.count() > 0); // 메모가 실제로 섰다
        // 모든 자리를 한 번에(오름차순) — 자리마다 따로 걸은 것과 같다
        const qs = try a.alloc(u32, n);
        defer a.free(qs);
        for (qs, 0..) |*q, i| q.* = @intCast(i);
        const got = try a.alloc(?u32, n);
        defer a.free(got);
        prov.nextOpenBrackets(sm.src, qs, got);
        try std.testing.expectEqualSlices(?u32, plain_next, got);
    }
}
