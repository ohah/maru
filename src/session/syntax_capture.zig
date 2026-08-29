//! **캡처 이름 → 색 역할**(native-editor-visual-mapping.md §5.3). tree-sitter가 말한 어휘를
//! `syntax_theme.SyntaxColors`의 11색으로 옮긴다.
//!
//! **§5.3이 이 표를 코드에 두라고 정했다** — *"두 소스 × 언어별 캡처 변형까지 문서에 나열하면 즉시
//! 낡는다. 이 문서는 다대일이라는 규칙과 색이 상한이라는 사실만 정하고, 실제 표는 `syntax_theme`
//! 옆에 둔다."* 그래서 여기가 그 자리다.
//!
//! **다대일이고, 색을 캡처 수에 맞춰 늘리지 않는다.** 번들 grammar 하나가 캡처 36개를 내는데 색은
//! 11개다. 팔레트가 터미널 ANSI 16색에서 파생하므로(§5.3) 색을 늘릴수록 서로 구분되지 않는다 —
//! 구분이 필요한 것이 실제로 겹쳐 보이면 그때 근거와 함께 더한다.
//!
//! **모르는 캡처는 무색이다.** 그것이 §5의 규율(*"grammar가 없으면 무색"*)과 같은 방향이다 —
//! 색이 없는 것은 기능 상실이 아니라 저하이고, 아무 색이나 넣는 것보다 낫다.

const std = @import("std");

/// 색 역할. **`syntax_theme.SyntaxColors`의 필드와 이름이 하나씩 대응한다** — 아래 `comptime`
/// 검사가 그것을 강제하므로 한쪽만 늘리면 컴파일이 죽는다. 두 벌이 조용히 갈리는 것을 막는 자리다.
pub const Role = enum {
    keyword,
    string,
    number,
    comment,
    property,
    type_name,
    function,
    punctuation,
    tag,
    attribute,
    invalid,
};

/// 캡처 이름 하나에 대한 **의도된** 답. `null`은 "못 찾았다"가 아니라 **"색을 안 준다고 정했다"**이다.
///
/// 둘을 가르는 이유: 아래 표에 없는 이름은 grammar가 새로 낸 것이고, 그때는 무색으로 떨어지되
/// **판정자가 그것을 잡아야 한다**(제품 쪽 `HLX` 판정자가 grammar의 캡처 집합을 이 표와 대조한다).
/// 반면 `variable`처럼 일부러 안 칠하는 것은 표에 **적혀 있어야** 그 의도가 보인다.
pub const Mapping = union(enum) {
    /// 이 역할의 색으로 칠한다.
    role: Role,
    /// **일부러 안 칠한다.** 본문 기본색으로 남는다.
    uncolored,
};

/// 캡처 이름 → 매핑. 표에 없으면 `null`(= grammar가 새로 낸 이름).
///
/// **점을 경계로 접두 폴백을 한다.** `keyword.conditional`을 못 찾으면 `keyword`를 찾는다 —
/// tree-sitter 관례이고, grammar가 세분을 늘려도 조용히 무색이 되지 않는다. 이 규칙이 없으면
/// grammar 하나 올릴 때마다 화면에서 색이 사라지고 아무도 모른다.
pub fn lookup(capture: []const u8) ?Mapping {
    var name = capture;
    while (true) {
        if (exact(name)) |m| return m;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        name = name[0..dot];
    }
}

/// 색만 필요할 때. `uncolored`와 "모르는 이름"이 **둘 다 `null`**이 되므로, 그 둘을 갈라야 하는
/// 판정자는 `lookup`을 쓴다.
pub fn roleFor(capture: []const u8) ?Role {
    return switch (lookup(capture) orelse return null) {
        .role => |r| r,
        .uncolored => null,
    };
}

/// **표.** 왼쪽은 tree-sitter capture 이름(점 세분은 접두 폴백이 처리하므로 뿌리만 적는다),
/// 오른쪽은 우리 색이다. 근거는 `syntax_theme.zig` 머리말이 적어 둔 터미널 관례다 —
/// keyword=magenta · string=green · number=yellow · comment/punctuation=dim · function=blue ·
/// property/type=cyan · tag=red · invalid=bright red.
fn exact(name: []const u8) ?Mapping {
    const table = .{
        // ── 키워드 ──────────────────────────────────────────────────────────────
        // `keyword.conditional`·`.return`·`.type` 등 열 갈래가 전부 여기로 접힌다.
        .{ "keyword", Mapping{ .role = .keyword } },

        // ── 리터럴 ──────────────────────────────────────────────────────────────
        .{ "string", Mapping{ .role = .string } }, // `string.escape`도 포함
        // 문자 리터럴(`'a'`)은 **문자열과 같은 색**이다. 따로 슬롯을 만들지 않는 이유는 위 다대일
        // 규율이고, 실제로 둘을 다른 색으로 쓰는 터미널 테마를 근거로 삼을 만큼 못 봤다.
        .{ "character", Mapping{ .role = .string } },
        .{ "number", Mapping{ .role = .number } }, // `number.float` 포함
        // **참·거짓과 상수는 숫자 색이다.** 팔레트에 `constant` 슬롯이 없고, 셋 다 "리터럴"이라는
        // 같은 자리에 있다. 키워드로 칠하는 테마도 있지만 그러면 `true`가 `if`와 같아진다.
        .{ "boolean", Mapping{ .role = .number } },
        .{ "constant", Mapping{ .role = .number } }, // `constant.builtin` 포함

        // ── 주석 ────────────────────────────────────────────────────────────────
        // `comment.documentation`도 여기로 접힌다. **지금은 접히는 것이 옳다** —
        // `src/syntax/tree_sitter.zig` 머리말이 적었듯 predicate를 평가하지 않아 모든 주석에
        // 그 캡처가 조건 없이 붙는다. 평가기가 서면 그때 갈지 판단한다.
        .{ "comment", Mapping{ .role = .comment } },

        // ── 이름 ────────────────────────────────────────────────────────────────
        .{ "function", Mapping{ .role = .function } }, // `.builtin`·`.call` 포함
        .{ "type", Mapping{ .role = .type_name } }, // `type.builtin` 포함
        // `const std = @import("std")`의 `std`가 `@module`이다. 이름공간은 **타입과 같은 색**을
        // 쓰는 것이 관례다(둘 다 "무엇의 종류인가"를 가리킨다).
        .{ "module", Mapping{ .role = .type_name } },
        // 구조체 필드 접근(`s.x`의 `x`)이 `@variable.member`다 — 우리 어휘로는 `property`.
        // **`variable`보다 먼저 잡혀야 한다**: 접두 폴백이 긴 이름부터 보므로 순서가 아니라
        // 이름 길이가 그것을 정한다.
        .{ "variable.member", Mapping{ .role = .property } },

        // ── 옛 규약 이름 ────────────────────────────────────────────────────────
        //
        // **grammar 마다 캡처 규약 세대가 다르다.** zig grammar 는 새 이름(`variable.member`·
        // `keyword.import`)을 쓰는데, 2026-08-29 에 함께 실은 열일곱 중 다수가 **옛 nvim 규약**을
        // 쓴다. 표에 없으면 그 토큰은 무색이다 — 문법이 맞아도 화면이 비는 부류다.
        //
        // 실측으로 골랐다: 열일곱 grammar 의 `highlights.scm` 에서 캡처 이름을 뽑아(따옴표 안
        // predicate 인자는 뺀다 — `#eq? @kw "@media"` 의 `@media` 는 캡처가 아니다) 이 표와
        // 대조하니 **못 받는 이름이 열아홉**이었다. 아래가 그 열아홉이다.

        // **`property` 가 가장 넓다** — 열 개 언어(객체 키·구조체 필드·CSS 속성)가 이 이름을 쓴다.
        // 위 `variable.member` 와 같은 자리다.
        .{ "property", Mapping{ .role = .property } },
        // 대문자로 시작하는 식별자를 생성자로 본다(python 은 `#match? "^[A-Z]"` 로 그렇게 적었다).
        // 클래스 이름이므로 타입 색이 맞다.
        .{ "constructor", Mapping{ .role = .type_name } },
        // 문자열 안의 이스케이프(`\n`). 새 규약의 `string.escape` 와 같은 것이다.
        .{ "escape", Mapping{ .role = .string } },
        .{ "delimiter", Mapping{ .role = .punctuation } },
        .{ "float", Mapping{ .role = .number } },
        // 제어 흐름 키워드를 따로 부르는 판(kotlin). 우리 어휘로는 전부 keyword 다.
        .{ "conditional", Mapping{ .role = .keyword } },
        .{ "repeat", Mapping{ .role = .keyword } },
        .{ "exception", Mapping{ .role = .keyword } },
        .{ "include", Mapping{ .role = .keyword } },
        // `module` 과 같은 자리(패키지·이름공간).
        .{ "namespace", Mapping{ .role = .type_name } },

        // ── 마크업(markdown) ────────────────────────────────────────────────────
        // 제목에 슬롯이 없다. **keyword 가 가장 눈에 띄는 자리**라 그것을 쓴다 — 제목이 본문색이면
        // 문서 구조가 화면에서 안 보인다.
        .{ "text.title", Mapping{ .role = .keyword } },
        // 인라인 코드·펜스 블록. 문자열과 같은 성질(그대로 읽는 글자)이다.
        .{ "text.literal", Mapping{ .role = .string } },
        // 링크 대상과 라벨. property(파랑)가 링크 관례에 가깝다.
        .{ "text.uri", Mapping{ .role = .property } },
        .{ "text.reference", Mapping{ .role = .property } },

        // ── 기호 ────────────────────────────────────────────────────────────────
        .{ "punctuation", Mapping{ .role = .punctuation } }, // `.bracket`·`.delimiter`
        // 연산자에 슬롯이 없다. `punctuation`(fg를 살짝 흐린 색)이 가장 가깝다 — 키워드 색으로
        // 칠하면 `=`·`+`가 `if`만큼 튄다.
        .{ "operator", Mapping{ .role = .punctuation } },

        // ── 일부러 안 칠하는 것 ─────────────────────────────────────────────────
        // **평범한 식별자는 본문색이다.** 여기에 색을 주면 화면의 거의 모든 글자가 칠해져
        // 강조가 강조 구실을 못 한다. `variable.builtin`·`variable.parameter`도 접두 폴백으로
        // 여기 걸린다(`variable.member`만 위에서 먼저 잡힌다).
        .{ "variable", Mapping.uncolored },
        // Neovim 맞춤법 검사용 표시일 뿐 색이 아니다. grammar가 `(comment) @comment @spell`처럼
        // 색 캡처와 **겹쳐서** 낸다.
        .{ "spell", Mapping.uncolored },
        // 매개변수 이름. 팔레트에 슬롯이 없고 **본문에서 차지하는 넓이가 크다** — 색을 주면
        // 시그니처가 통째로 칠해진다. `variable.parameter`(새 규약)가 이미 본문색인 것과 같은 판단이다.
        .{ "parameter", Mapping.uncolored },
        // 보간·삽입 **영역 전체**를 감싸는 캡처(`"${...}"`). 안쪽 토큰이 각자 색을 갖는데 이것이
        // 겹쳐 오면 마지막이 이기는 규칙 때문에 그 색을 통째로 덮는다.
        .{ "embedded", Mapping.uncolored },
        // grammar 가 **명시적으로 "칠하지 말라"** 고 표시한 자리다.
        .{ "none", Mapping.uncolored },
        // 밑줄로 시작하는 이름은 **predicate 조건용 보조 캡처**다(kotlin 이 `#eq? @_function "Regex"`
        // 처럼 쓴다). 색이 아니라 검사용이므로 칠하지 않는다.
        .{ "_class", Mapping.uncolored },
        .{ "_function", Mapping.uncolored },
        // 블록·break 라벨(`outer:`). 팔레트에 마땅한 자리가 없고 빈도가 낮아 본문색으로 둔다 —
        // 겹쳐 보인다는 근거가 생기면 그때 슬롯을 논의한다.
        .{ "label", Mapping.uncolored },

        // ── 번들 grammar가 아직 안 내는 것 ──────────────────────────────────────
        // Zig grammar에는 없지만 **표준 캡처 이름**이라 마크업 grammar를 더하는 순간 온다.
        // 색 슬롯(`tag`·`attribute`·`invalid`)이 이미 있으므로 그때 이 표를 고칠 일이 없다.
        // 아래 `HL5`가 "지금은 안 쓰인다"는 사실 자체를 잰다 — 쓰인다고 착각하지 않게.
        .{ "tag", Mapping{ .role = .tag } },
        .{ "attribute", Mapping{ .role = .attribute } },
        .{ "error", Mapping{ .role = .invalid } },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) return row[1];
    }
    return null;
}

comptime {
    // **`Role`과 `SyntaxColors`가 갈리지 않게 못박는다.** 색을 늘리면서 역할을 안 늘리면(또는 그
    // 반대면) 여기서 컴파일이 죽는다 — 두 벌이 조용히 어긋나는 것이 이 저장소가 반복해서 당한
    // 형태다. 이름까지 같아야 소비처가 `@field`로 옮길 수 있다.
    //
    // **진단 문구는 영어다.** 화면에 나가는 문자열이 아니라 컴파일러 진단이고, 번역 대상 레이어의
    // 한국어 리터럴은 `tests/boundary/i18n_literals.zig` 원장이 센다(§7.2). 실측으로 걸렸다:
    // `src/session/syntax_capture.zig: 한국어 리터럴 2 개 (원장 0) — 늘었다`.
    const SyntaxColors = @import("syntax_theme.zig").SyntaxColors;
    const color_fields = @typeInfo(SyntaxColors).@"struct".fields;
    const roles = @typeInfo(Role).@"enum".fields;
    if (color_fields.len != roles.len) @compileError("Role and SyntaxColors must have the same number of entries");
    for (roles) |r| {
        if (!@hasField(SyntaxColors, r.name)) @compileError("Role has no matching SyntaxColors field: " ++ r.name);
    }
}

// ── 판정자 ──────────────────────────────────────────────────────────────────────

test "HL1 점 세분은 뿌리로 접힌다 — grammar가 잘게 나눠도 색이 사라지지 않는다" {
    // **이 규칙이 이 모듈의 값어치다.** 표에 뿌리만 적고 세분을 폴백으로 받으므로, grammar를
    // 올려 `keyword.coroutine` 같은 이름이 늘어도 화면에서 색이 빠지지 않는다. 접두 폴백이
    // 없으면 그런 회귀는 **조용히** 일어난다 — 아무 테스트도 안 깨지고 화면만 흐려진다.
    try std.testing.expectEqual(Role.keyword, roleFor("keyword").?);
    try std.testing.expectEqual(Role.keyword, roleFor("keyword.conditional").?);
    try std.testing.expectEqual(Role.keyword, roleFor("keyword.return").?);
    try std.testing.expectEqual(Role.keyword, roleFor("keyword.function.async.deeply.nested").?);

    try std.testing.expectEqual(Role.string, roleFor("string.escape").?);
    try std.testing.expectEqual(Role.number, roleFor("number.float").?);
    try std.testing.expectEqual(Role.comment, roleFor("comment.documentation").?);
    try std.testing.expectEqual(Role.function, roleFor("function.builtin").?);
    try std.testing.expectEqual(Role.type_name, roleFor("type.builtin").?);
    try std.testing.expectEqual(Role.punctuation, roleFor("punctuation.bracket").?);
}

test "HL2 더 긴 이름이 이긴다 — variable.member는 property, 나머지 variable은 무색" {
    // 폴백이 **가장 긴 것부터** 보지 않으면 `variable.member`가 `variable`에 먼저 걸려 본문색이
    // 된다 — 구조체 필드가 통째로 안 칠해지는데 아무것도 안 깨진다.
    try std.testing.expectEqual(Role.property, roleFor("variable.member").?);
    try std.testing.expectEqual(@as(?Role, null), roleFor("variable"));
    try std.testing.expectEqual(@as(?Role, null), roleFor("variable.builtin"));
    try std.testing.expectEqual(@as(?Role, null), roleFor("variable.parameter"));
}

test "HL3 '안 칠한다'와 '모르는 이름'을 가른다" {
    // 색만 보면 둘 다 무색이라 같아 보인다. 그 구분이 있어야 grammar가 새 캡처를 냈을 때
    // 제품 판정자가 그것을 **새 이름으로** 잡을 수 있다.
    try std.testing.expectEqual(Mapping.uncolored, lookup("variable").?);
    try std.testing.expectEqual(Mapping.uncolored, lookup("spell").?);
    try std.testing.expectEqual(@as(?Mapping, null), lookup("nonexistent.capture.name"));
    try std.testing.expectEqual(@as(?Mapping, null), lookup(""));
}

test "HL4 번들 grammar가 내는 캡처 36개가 전부 의도된 답을 갖는다" {
    // **이 목록은 grammar에서 뽑은 것이다**(`queries/highlights.scm`의 캡처 전수, 따옴표 안
    // 문자열 제외 — `"@import"`·`"@cImport"`는 predicate 인자이지 캡처가 아니다).
    //
    // 여기서 `null`이 나오면 **표에 없는 이름**이라는 뜻이고, 화면에서는 그 토큰이 조용히
    // 무색이 된다. grammar를 올릴 때 이 판정자가 먼저 깨져야 그것을 안다.
    const grammar_captures = [_][]const u8{
        "boolean",           "character",           "comment",               "comment.documentation",
        "constant",          "constant.builtin",    "function",              "function.builtin",
        "function.call",     "keyword",             "keyword.conditional",   "keyword.coroutine",
        "keyword.exception", "keyword.function",    "keyword.import",        "keyword.modifier",
        "keyword.operator",  "keyword.repeat",      "keyword.return",        "keyword.type",
        "label",             "module",              "number",                "number.float",
        "operator",          "punctuation.bracket", "punctuation.delimiter", "spell",
        "string",            "string.escape",       "type",                  "type.builtin",
        "variable",          "variable.builtin",    "variable.member",       "variable.parameter",
    };
    try std.testing.expectEqual(@as(usize, 36), grammar_captures.len);
    for (grammar_captures) |cap| {
        if (lookup(cap) == null) {
            std.debug.print("표에 없는 grammar 캡처: {s}\n", .{cap});
            return error.UnmappedCapture;
        }
    }
}

test "HL17 열일곱 언어가 내는 캡처도 전부 표에 있다" {
    // `HL4`는 **zig grammar** 의 캡처만 지킨다. 2026-08-29 에 열일곱이 더 실리면서 그 목록으로는
    // 나머지 언어가 무색이 되는 것을 못 잡게 됐다 — 실제로 `property` 하나가 **열 개 언어**에서
    // 빠져 있었다(객체 키·구조체 필드·CSS 속성).
    //
    // 이 목록도 grammar 에서 뽑았다(`highlights.scm` 전수, **따옴표 안은 제외** — `#eq? @kw "@media"`
    // 의 `@media` 는 캡처가 아니라 predicate 인자다. 그 오탐을 안 걸렀을 때 css at-rule 다섯 개가
    // 가짜로 "빠진 캡처" 로 잡혔다).
    //
    // zig 목록과 겹치는 것은 `HL4` 가 이미 지키므로 여기서는 **zig 에 없는 이름만** 센다.
    const other_language_captures = [_][]const u8{
        "_class",
        "_function",
        "attribute",
        "conditional",
        "constructor",
        "delimiter",
        "embedded",
        "escape",
        "exception",
        "float",
        "function.macro",
        "function.method",
        "function.method.builtin",
        "function.special",
        "include",
        "module.builtin",
        "namespace",
        "none",
        "parameter",
        "property",
        "punctuation.special",
        "repeat",
        "string.regex",
        "string.special",
        "string.special.key",
        "string.special.regex",
        "string.special.symbol",
        "tag",
        "tag.error",
        "text.literal",
        "text.reference",
        "text.title",
        "text.uri",
    };
    for (other_language_captures) |cap| {
        if (lookup(cap) == null) {
            std.debug.print("표에 없는 grammar 캡처: {s}\n", .{cap});
            return error.UnmappedCapture;
        }
    }
}

test "HL5 색이 붙는 캡처와 일부러 무색인 캡처가 둘 다 있다 — 항진명제가 아니다" {
    // 위 `HL4`는 "전부 표에 있다"만 본다. 표가 **전부 무색**이어도 통과하므로 그것만으로는
    // 색이 하나도 안 붙는 회귀를 못 잡는다.
    var colored: usize = 0;
    var uncolored: usize = 0;
    for ([_][]const u8{ "keyword", "string", "number", "comment", "type", "function", "operator" }) |c| {
        if (roleFor(c) != null) colored += 1;
    }
    for ([_][]const u8{ "variable", "spell", "label" }) |c| {
        if (roleFor(c) == null) uncolored += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), colored);
    try std.testing.expectEqual(@as(usize, 3), uncolored);

    // 번들 grammar는 마크업 캡처를 안 낸다. **쓰인다고 착각하지 않게** 그 사실을 적어 둔다 —
    // 표에는 있고(마크업 grammar가 오면 그대로 쓰인다) 지금 화면에는 안 나온다.
    try std.testing.expectEqual(Role.tag, roleFor("tag").?);
    try std.testing.expectEqual(Role.attribute, roleFor("attribute").?);
    try std.testing.expectEqual(Role.invalid, roleFor("error").?);
}
