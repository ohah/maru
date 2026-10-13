//! Enter 의 언어 규칙 — 「이 줄 뒤 Enter 는 무엇을 하나」를 정하는 **한 함수**(`decide` — 계획 editor-typing-rules TR2·TR3,
//! 문서 모델 §3.9a). 정규식 엔진 없이 문법마다 Zig 로 적는다(2026-10-13 사용자 결정). 순서는 VS Code 와 같다 — 언어 규칙(주석
//! 이어쓰기)이 먼저, 그다음 괄호, 그다음 들여쓰기 규칙(Python `:`·`case`·Ruby·HTML 태그).
//!
//! 입력은 caret 앞 줄 조각(`before` — 줄 머리부터), caret 뒤 줄 조각(`after` — 줄 끝까지), 바로 위 줄(`prev`)이다. 출력은 들여쓰기 갈래와
//! 새 줄 머리에 덧붙일 글자다 — 적용(커서·문서 순서·undo)은 `line_ops.planNewline` 이 한다.
//!
//! **L2 다 — 문서도 화면도 모른다.** 괄호 쌍은 호출자가 준다(괄호 색칠의 규칙 — 구문 모듈은 L4 만 들여온다).
const std = @import("std");
const language = @import("language.zig");
const indent_guides = @import("indent_guides.zig");

/// Enter 의 언어 문맥. 없으면(평문) 호출자가 `decide` 를 부르지 않는다 — 앞 공백만 잇는다.
pub const Context = struct {
    grammar: language.Grammar,
    /// 그 문법의 괄호 쌍(여는 것·닫는 것을 번갈아 — `"()[]{}"`). 괄호 색칠의 규칙(`bracketRuleFor().chars`)과 같은 집합.
    brackets: []const u8,
    /// 문자열 따옴표(`Grammar.stringQuotes`) — 그 안의 괄호·주석 표식은 세지 않는다.
    quotes: []const u8 = "",
    /// 줄 주석 표식(`Language.lineComment`) — 그 뒤의 괄호는 세지 않는다.
    line_comment: ?[]const u8 = null,
    /// 한 단계(감지한 들여쓰기 단위).
    unit: indent_guides.Unit,
    /// 짝 없는 여는 괄호를 줄 어디서든 보는가(`Grammar.bracketEnterAnywhere`).
    anywhere: bool = true,
};

pub const Indent = enum {
    /// 앞 공백을 그대로 잇는다.
    keep,
    /// 한 단계 더.
    indent,
    /// 가운데 줄은 한 단계 더, caret 뒤 조각은 원래 들여쓰기로 아래 줄에(`{|}` → `{` ⏎ `→|` ⏎ `}`).
    indent_outdent,
};

/// VS Code 의 모양과 같다(동작만 — `getEnterAction`): 새 줄 = 이어 받은 들여쓰기(+`remove` 만큼 뺀다) + `append`. `append` 가 없으면(`null`)
/// `indent`·`indent_outdent` 는 한 단계(그 파일의 단위), `keep` 은 없음 — VS Code 의 기본 `appendText` 가 탭이고 그것을 들여쓰기 단위로 바꾸는
/// 것과 같다. **`append` 가 있으면 그것이 한 단계를 대신한다**(블록 주석 `/** a| */` 의 가운데 줄은 ` * ` 이지 한 단계 + ` * ` 가 아니다).
pub const Action = struct {
    indent: Indent = .keep,
    /// 새 줄 머리(이어 받은 들여쓰기 뒤)에 덧붙일 글자 — 블록 주석 ` * `·줄 주석 `// `. 정적 문자열이다.
    append: ?[]const u8 = null,
    /// 이어 받은 들여쓰기 끝에서 뺄 글자 수(블록 주석이 끝난 줄 ` */` 뒤 — 정렬용 공백 하나).
    remove: u8 = 0,
};

/// 그 줄 뒤 Enter 의 갈래.
pub fn decide(ctx: Context, before: []const u8, after: []const u8, prev: ?[]const u8) Action {
    if (blockComment(ctx.grammar, before, after, prev)) |a| return a;
    if (lineCommentContinue(ctx, before, after)) |a| return a;
    if (bracketAction(ctx, before, after)) |a| return a;
    if (ctx.grammar == .html) if (htmlTag(before, after)) |a| return a;
    if (indentRule(ctx, before, after)) return .{ .indent = .indent };
    return .{};
}

// ── 블록 주석 ─────────────────────────────────────────────────────────────────────

/// `/* */` 블록 주석을 쓰는 문법(C 계열·CSS) — 이어쓰기(` * `)를 한다. VS Code 는 TS·JS·Java·PHP 에만 규칙을 두고 C·C++·Go·Rust 에는 두지 않는다 —
/// 같은 주석 문법이라 우리는 함께 한다(계획의 「의도한 차이」).
fn hasBlockComment(g: language.Grammar) bool {
    return switch (g) {
        .c, .cpp, .java, .javascript, .typescript, .tsx, .go, .rust, .php, .kotlin, .css => true,
        else => false,
    };
}

fn blockComment(g: language.Grammar, before: []const u8, after: []const u8, prev: ?[]const u8) ?Action {
    if (!hasBlockComment(g)) return null;
    const t = std.mem.trimStart(u8, before, " \t");
    // ① 여는 줄 `/**`·`/*`(그 줄에서 닫히지 않았다) → ` * `. caret 뒤가 `*/` 면 그것은 아래 줄로(`/** a| */` → ` * |` ⏎ ` */`).
    if (std.mem.startsWith(u8, t, "/*") and std.mem.indexOf(u8, t[2..], "*/") == null) {
        const rest = std.mem.trimStart(u8, after, " \t");
        return .{ .indent = if (std.mem.startsWith(u8, rest, "*/")) .indent_outdent else .keep, .append = " * " };
    }
    // ② 닫는 줄 ` */`·` * … */` → 정렬 공백 하나를 뺀다(VS Code `removeText: 1`). 앞 공백이 있어야 한다(` */` 의 공백이 정렬이다).
    const ws = before.len - t.len;
    if (ws > 0 and before[ws - 1] == ' ' and std.mem.startsWith(u8, t, "*") and std.mem.endsWith(u8, std.mem.trimEnd(u8, t, " \t"), "*/")) return .{ .remove = 1 };
    // ③ 가운데 줄 ` * …`(앞 줄이 주석 안 — `/*` 또는 `*` 로 시작하고 `*/` 로 끝나지 않는다) → `* `(정렬 공백은 이어 받은 들여쓰기가 든다).
    if (std.mem.startsWith(u8, t, "*") and !std.mem.startsWith(u8, t, "*/") and (t.len == 1 or t[1] == ' ')) {
        const p = std.mem.trim(u8, prev orelse return null, " \t");
        if ((std.mem.startsWith(u8, p, "/*") or std.mem.startsWith(u8, p, "*")) and !std.mem.endsWith(u8, p, "*/")) return .{ .append = "* " };
    }
    return null;
}

// ── 줄 주석 ─────────────────────────────────────────────────────────────────────

/// 줄 주석 **가운데**에서 Enter 면 그 표식으로 잇는다(VS Code: `// …|…` → `// ` — 줄 끝이면 잇지 않는다). `//` 를 쓰는 문법만.
fn lineCommentContinue(ctx: Context, before: []const u8, after: []const u8) ?Action {
    const lc = ctx.line_comment orelse return null;
    if (!std.mem.eql(u8, lc, "//")) return null;
    if (std.mem.trim(u8, after, " \t").len == 0) return null; // 줄 끝 — 잇지 않는다
    const at = commentStart(before, ctx.quotes, lc) orelse return null;
    // 표식 뒤에 글자가 있어야 한다(빈 `//` 는 잇지 않는다 — VS Code `//\s*\S`).
    if (std.mem.trim(u8, before[at + lc.len ..], " \t").len == 0) return null;
    // 줄 머리의 주석만(`  // …`) — 코드 뒤 주석(`x = 1; // …`)도 VS Code 는 잇는다(`\s//\s+\S`). 같게 한다.
    return .{ .append = "// " };
}

/// 문자열 밖의 첫 줄 주석 표식 자리.
fn commentStart(line: []const u8, quotes: []const u8, lc: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        if (std.mem.startsWith(u8, line[i..], lc)) return i;
        if (std.mem.indexOfScalar(u8, quotes, b) != null) {
            i += 1;
            while (i < line.len and line[i] != b) : (i += 1) {
                if (line[i] == '\\') i += 1;
            }
        }
    }
    return null;
}

// ── 괄호(TR2) ─────────────────────────────────────────────────────────────────────

fn bracketAction(ctx: Context, before: []const u8, after: []const u8) ?Action {
    const o = lastUnclosedOpener(before, ctx) orelse return null;
    if (!ctx.anywhere) {
        const trimmed = std.mem.trimEnd(u8, before, " \t");
        if (trimmed.len == 0 or trimmed[trimmed.len - 1] != o) return null;
    }
    const rest = std.mem.trimStart(u8, after, " \t");
    if (rest.len > 0 and closerOf(ctx.brackets, o) == rest[0]) return .{ .indent = .indent_outdent };
    return .{ .indent = .indent };
}

/// `head` 를 왼쪽부터 읽어 **짝 없이 남은 마지막 여는 괄호**(없으면 `null`). 문자열·줄 주석 뒤는 세지 않는다. 닫는 괄호는 짝이 맞을 때만
/// 닫는다. 스택은 상한이 있다(넘치면 오래된 것을 버린다 — 마지막 것이 답이라 충분하다).
pub fn lastUnclosedOpener(head: []const u8, ctx: Context) ?u8 {
    var stack: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < head.len) : (i += 1) {
        const b = head[i];
        if (ctx.line_comment) |lc| if (lc.len > 0 and std.mem.startsWith(u8, head[i..], lc)) break;
        if (std.mem.indexOfScalar(u8, ctx.quotes, b) != null) {
            i += 1;
            while (i < head.len and head[i] != b) : (i += 1) {
                if (head[i] == '\\') i += 1;
            }
            continue;
        }
        if (openerIndex(ctx.brackets, b)) |_| {
            if (n == stack.len) {
                std.mem.copyForwards(u8, stack[0 .. n - 1], stack[1..n]);
                n -= 1;
            }
            stack[n] = b;
            n += 1;
        } else if (closerOpen(ctx.brackets, b)) |open| {
            if (n > 0 and stack[n - 1] == open) n -= 1;
        }
    }
    return if (n > 0) stack[n - 1] else null;
}

fn openerIndex(brackets: []const u8, b: u8) ?usize {
    var k: usize = 0;
    while (k + 1 < brackets.len) : (k += 2) if (brackets[k] == b) return k;
    return null;
}

fn closerOpen(brackets: []const u8, b: u8) ?u8 {
    var k: usize = 0;
    while (k + 1 < brackets.len) : (k += 2) if (brackets[k + 1] == b) return brackets[k];
    return null;
}

/// 여는 괄호의 짝(닫는 것).
pub fn closerOf(brackets: []const u8, open: u8) ?u8 {
    const k = openerIndex(brackets, open) orelse return null;
    return brackets[k + 1];
}

// ── 들여쓰기 규칙(TR3) ─────────────────────────────────────────────────────────────

fn indentRule(ctx: Context, before: []const u8, after: []const u8) bool {
    _ = after;
    return switch (ctx.grammar) {
        .python => pythonBlock(before, ctx.quotes),
        .ruby => rubyBlock(before),
        .c, .cpp, .java, .javascript, .typescript, .tsx, .go, .php => caseLabel(before),
        else => false,
    };
}

/// 줄 끝 주석(`#` — 문자열 밖)을 떼고 뒤 공백을 지운 코드.
fn codePart(line: []const u8, quotes: []const u8, comment: []const u8) []const u8 {
    const end = commentStart(line, quotes, comment) orelse line.len;
    return std.mem.trim(u8, line[0..end], " \t");
}

fn firstWord(code: []const u8) []const u8 {
    var i: usize = 0;
    while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '_')) i += 1;
    return code[0..i];
}

fn isOneOf(w: []const u8, list: []const []const u8) bool {
    for (list) |k| if (std.mem.eql(u8, w, k)) return true;
    return false;
}

/// Python — 제어문으로 시작해 `:` 로 끝나는 줄(줄 끝 주석은 뗀다). VS Code 의 목록에 `match`·`case`(3.10)를 더하고 `lambda`·딕셔너리
/// 리터럴(`d = {'k':`)은 아니다(첫 낱말이 제어문이 아니다).
fn pythonBlock(before: []const u8, quotes: []const u8) bool {
    const code = codePart(before, quotes, "#");
    if (code.len == 0 or code[code.len - 1] != ':') return false;
    const w = firstWord(code);
    return isOneOf(w, &.{ "def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally", "with", "async", "match", "case" });
}

/// `case X:`·`default:` 로 끝나는 줄(switch 를 쓰는 C 계열).
fn caseLabel(before: []const u8) bool {
    const code = std.mem.trim(u8, before, " \t");
    if (code.len == 0 or code[code.len - 1] != ':') return false;
    if (std.mem.eql(u8, code, "default:")) return true;
    return std.mem.startsWith(u8, code, "case ") and code.len > "case :".len;
}

/// Ruby — 블록을 여는 줄. 첫 낱말이 블록 키워드거나(`private`·`protected def` 포함), 줄이 `do`(뒤에 `|인자|` 가능)로 끝나거나, `= if`·`= case`
/// 꼴. 한 줄로 닫힌 것(`… end`)·후위 조건(`return if x` — 첫 낱말이 아니다)은 아니다. 문자열 안 `do`(`"a do b"`)는 따옴표를 떼고 본다.
fn rubyBlock(before: []const u8) bool {
    const code = codePart(before, "\"'", "#");
    if (code.len == 0) return false;
    if (endsWithWord(code, "end")) return false;
    var w = firstWord(code);
    if (isOneOf(w, &.{ "private", "protected" })) w = firstWord(std.mem.trimStart(u8, code[w.len..], " \t"));
    if (isOneOf(w, &.{ "def", "class", "module", "if", "unless", "while", "until", "case", "begin", "for", "else", "elsif", "when", "rescue", "ensure", "in" })) return true;
    // `… do` / `… do |x|` — 문자열을 걷어낸 코드에서.
    var buf: [512]u8 = undefined;
    const bare = stripStrings(code, "\"'", &buf);
    var t = bare;
    if (t.len > 0 and t[t.len - 1] == '|') {
        const open = std.mem.lastIndexOfScalar(u8, t[0 .. t.len - 1], '|') orelse return false;
        t = std.mem.trimEnd(u8, t[0..open], " \t");
    }
    if (endsWithWord(t, "do")) return true;
    // `x = if a` · `x = case y`
    if (std.mem.indexOf(u8, bare, "= ")) |eq| {
        const rhs = firstWord(std.mem.trimStart(u8, bare[eq + 1 ..], " \t"));
        return isOneOf(rhs, &.{ "if", "unless", "case" });
    }
    return false;
}

fn endsWithWord(s: []const u8, w: []const u8) bool {
    if (!std.mem.endsWith(u8, s, w)) return false;
    if (s.len == w.len) return true;
    const b = s[s.len - w.len - 1];
    return !(std.ascii.isAlphanumeric(b) or b == '_' or b == '.');
}

/// 따옴표 안을 지운 사본(낱말 판정용 — `"a do b"` 의 `do` 를 세지 않게). 버퍼가 모자라면 앞부분만.
fn stripStrings(s: []const u8, quotes: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (i += 1) {
        const b = s[i];
        if (std.mem.indexOfScalar(u8, quotes, b) != null) {
            i += 1;
            while (i < s.len and s[i] != b) : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            continue;
        }
        buf[n] = b;
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " \t");
}

// ── HTML 태그 ─────────────────────────────────────────────────────────────────────

/// 내용을 갖지 않는 요소(VS Code 의 목록과 같다) — 그 뒤에서는 들여쓰지 않는다.
const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "menuitem", "meta", "param", "source", "track", "wbr" };

/// caret 앞의 마지막 태그가 **여는 태그**(`<div …>` — 닫는 태그·자기 닫힘·void 요소·주석이 아니다)이고 그 뒤에 다른 태그가 없으면(글자는 있어도
/// 된다 — `<li>a|`) 한 단계, 그 태그의 닫는 짝(`</div>`)이 caret 뒤에 바로 오면 가운데 줄(VS Code html `onEnterRules`). 태그 이름 비교는 대소문자를
/// 가리지 않는다.
fn htmlTag(before: []const u8, after: []const u8) ?Action {
    const lt = std.mem.lastIndexOfScalar(u8, before, '<') orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, before, lt, '>') orelse return null;
    if (gt == lt + 1 or before[gt - 1] == '/') return null; // `<>`·자기 닫힘
    const tag = before[lt + 1 .. gt];
    if (tag.len == 0 or !std.ascii.isAlphabetic(tag[0])) return null; // `</x>`·`<!-- -->`·`<?…?>`
    var n: usize = 0;
    while (n < tag.len and (std.ascii.isAlphanumeric(tag[n]) or tag[n] == '-' or tag[n] == ':' or tag[n] == '_' or tag[n] == '.')) n += 1;
    const name = tag[0..n];
    for (void_elements) |v| if (std.ascii.eqlIgnoreCase(name, v)) return null;
    const rest = std.mem.trimStart(u8, after, " \t");
    if (rest.len >= name.len + 3 and std.mem.startsWith(u8, rest, "</") and std.ascii.eqlIgnoreCase(rest[2 .. 2 + name.len], name)) {
        const tail = std.mem.trimStart(u8, rest[2 + name.len ..], " \t");
        if (tail.len > 0 and tail[0] == '>') return .{ .indent = .indent_outdent };
    }
    return .{ .indent = .indent };
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const vscode = @import("enter_rules_vscode.zig");

fn ctxFor(g: language.Grammar) Context {
    const brackets: []const u8 = switch (g) {
        .json => "[]{}",
        .html => "(){}",
        else => "()[]{}",
    };
    const lc: ?[]const u8 = switch (g) {
        .python, .ruby, .bash => "#",
        .html, .css, .json, .markdown, .none => null,
        else => "//",
    };
    return .{ .grammar = g, .brackets = brackets, .quotes = g.stringQuotes(), .line_comment = lc, .unit = .{ .tabs = false, .width = 4 }, .anywhere = g.bracketEnterAnywhere() };
}

/// 의도한 차이 — VS Code 규칙과 일부러 다르게 답하는 입력과 그 이유(계획 editor-typing-rules 「실측」 표·TR3 설계).
const Intended = struct { grammar: language.Grammar, before: []const u8 };
const intended = [_]Intended{
    .{ .grammar = .typescript, .before = "const s = \"{\";" }, // 문자열 안 괄호
    .{ .grammar = .typescript, .before = "// {" }, // 줄 주석 안 괄호
    .{ .grammar = .typescript, .before = "const t = `${x} {`" }, // 템플릿 문자열 안 괄호
    .{ .grammar = .c, .before = "/**" }, // C 계열은 같은 블록 주석이라 이어 쓴다(VS Code 는 TS·JS·Java·PHP 만)
    .{ .grammar = .go, .before = "/**" }, // 같은 이유
    .{ .grammar = .rust, .before = "/**" }, // 같은 이유
    .{ .grammar = .c, .before = "case 1:" }, // switch 를 쓰는 C 계열 전부(VS Code 는 C·C++ 에 규칙이 없다)
    .{ .grammar = .python, .before = "if x:  # note" }, // 줄 끝 주석을 떼고 본다
    .{ .grammar = .python, .before = "match x:" }, // 3.10 match·case
    .{ .grammar = .ruby, .before = "s = \"a do b\"" }, // 문자열 안 do
    .{ .grammar = .ruby, .before = "if a then b end" }, // 한 줄로 닫힌 블록
};

fn intendedDiff(g: language.Grammar, before: []const u8) bool {
    for (intended) |d| if (d.grammar == g and std.mem.eql(u8, d.before, before)) return true;
    return false;
}

/// VS Code 의 답을 우리 모양으로 옮긴다 — `none` 은 `keep`, 기본 appendText(`""`·탭)는 `null`(한 단계).
fn fromVscode(e: vscode.Expect) Action {
    const ind: Indent = if (std.mem.eql(u8, e.indent, "indent")) .indent else if (std.mem.eql(u8, e.indent, "indentOutdent")) .indent_outdent else .keep;
    const app: ?[]const u8 = if (e.append.len == 0 or std.mem.eql(u8, e.append, "\t")) null else e.append;
    return .{ .indent = ind, .append = app, .remove = e.remove };
}

fn sameAction(a: Action, b: Action) bool {
    if (a.indent != b.indent or a.remove != b.remove) return false;
    if (a.append == null or b.append == null) return a.append == null and b.append == null;
    return std.mem.eql(u8, a.append.?, b.append.?);
}

test "INDR1 VS Code 규칙 대조 — 핀 커밋의 내장 언어 설정을 원래 의미로 돌린 말뭉치와 같은 갈래, 갈리는 것은 의도한 차이 목록에만 (계획 editor-typing-rules TR3)" {
    var differ: usize = 0;
    for (vscode.cases) |e| {
        const got = decide(ctxFor(e.grammar), e.before, e.after, if (e.prev.len > 0) e.prev else null);
        const want = fromVscode(e);
        const same = sameAction(got, want);
        if (intendedDiff(e.grammar, e.before)) {
            // 의도한 차이는 **실제로 갈려야** 한다 — 같아졌다면 목록이 낡았거나 VS Code 가 바뀌었다.
            if (same) {
                std.debug.print("intended diff vanished: {s} {s}\n", .{ @tagName(e.grammar), e.before });
                return error.IntendedDiffVanished;
            }
            differ += 1;
            continue;
        }
        if (!same) {
            std.debug.print("differs from VS Code: {s} before={s} after={s} prev={s} want={s}/{?s}/{d} got={s}/{?s}/{d}\n", .{ @tagName(e.grammar), e.before, e.after, e.prev, @tagName(want.indent), want.append, want.remove, @tagName(got.indent), got.append, got.remove });
            return error.UnexpectedDiff;
        }
    }
    // 목록의 차이가 전부 말뭉치에 있다(목록만 남은 낡은 항목이 없다).
    try testing.expectEqual(intended.len, differ);
}

test "INDR2 블록·줄 주석 — 여는 줄은 ` * `, `*/` 앞이면 그것을 아래로, 가운데 줄은 `* `(앞 줄이 주석 안일 때만), 닫는 줄 뒤는 정렬 공백 하나 빼기, 줄 주석은 가운데서만 잇는다 (계획 editor-typing-rules TR3)" {
    const c = ctxFor(.typescript);
    try testing.expect(sameAction(decide(c, "/**", "", null), .{ .append = " * " }));
    try testing.expect(sameAction(decide(c, "  /* a", "", null), .{ .append = " * " }));
    try testing.expect(sameAction(decide(c, "/** a", " */", null), .{ .indent = .indent_outdent, .append = " * " }));
    try testing.expect(sameAction(decide(c, " * a", "", " * b"), .{ .append = "* " }));
    try testing.expect(sameAction(decide(c, " * a", "", "x = 2 *"), .{})); // 앞 줄이 주석 안이 아니다 — 곱셈 이어 쓰기
    try testing.expect(sameAction(decide(c, " */", "", " * a"), .{ .remove = 1 }));
    try testing.expect(sameAction(decide(c, "/** a */", "", null), .{})); // 한 줄로 닫힌 주석
    try testing.expect(sameAction(decide(c, "// a", "b", null), .{ .append = "// " }));
    try testing.expect(sameAction(decide(c, "// a", "", null), .{})); // 줄 끝은 잇지 않는다
    try testing.expect(sameAction(decide(c, "//", "b", null), .{})); // 빈 주석
    try testing.expect(sameAction(decide(c, "s = \"// x", "y\"", null), .{})); // 문자열 안 `//`
    // 블록 주석이 없는 문법·`#` 주석 문법은 이 규칙이 없다.
    try testing.expect(sameAction(decide(ctxFor(.python), "/**", "", null), .{}));
    try testing.expect(sameAction(decide(ctxFor(.python), "# a", "b", null), .{}));
}

test "INDR3 언어 규칙 — Python 제어문 `:`(주석 떼고·match/case), `case`/`default`, Ruby 블록(한 줄로 닫힘·후위 조건·문자열 안은 아님), HTML 태그(void·닫는 태그·자기 닫힘은 아님) (계획 editor-typing-rules TR3)" {
    const py = ctxFor(.python);
    for ([_][]const u8{ "def f():", "  if x:  # note", "match x:", "    case 1:", "async def f():", "with a as b:", "else:" }) |l| try testing.expect(sameAction(decide(py, l, "", null), .{ .indent = .indent }));
    for ([_][]const u8{ "d = {'k':", "lambda x: x", "print(\"a:\")", "x = 1  # if:", "" }) |l| try testing.expect(sameAction(decide(py, l, "", null), .{}));
    const ts = ctxFor(.typescript);
    try testing.expect(sameAction(decide(ts, "  case 1:", "", null), .{ .indent = .indent }));
    try testing.expect(sameAction(decide(ts, "default:", "", null), .{ .indent = .indent }));
    try testing.expect(sameAction(decide(ts, "a ? b :", "", null), .{}));
    try testing.expect(sameAction(decide(ts, "cases:", "", null), .{})); // `cases` 라는 라벨 — `case` 낱말이 아니다(H12)
    const rb = ctxFor(.ruby);
    for ([_][]const u8{ "def foo", "class A < B", "arr.each do |x|", "loop do", "x = if a", "private def foo", "  elsif x", "when 1", "begin" }) |l| try testing.expect(sameAction(decide(rb, l, "", null), .{ .indent = .indent }));
    // 줄 끝에서 열린 채 다음 줄로 이어지는 문자열 안의 `do`(`s = "start do`)도 아니다 — 따옴표로 닫힌 문자열은 줄이 따옴표로 끝나 `do` 가 끝에 올
    // 수 없으니, 문자열 걷어내기가 가르는 것은 이 꼴이다(적대적 5회차 H11 이 살아남아 더한 장면).
    for ([_][]const u8{ "if a then b end", "return if a", "s = \"a do b\"", "puts x", "# def foo", "end", "s = \"start do" }) |l| try testing.expect(sameAction(decide(rb, l, "", null), .{}));
    const html = ctxFor(.html);
    try testing.expect(sameAction(decide(html, "<div>", "</div>", null), .{ .indent = .indent_outdent }));
    try testing.expect(sameAction(decide(html, "<DIV class=\"a\">", "</div>", null), .{ .indent = .indent_outdent }));
    try testing.expect(sameAction(decide(html, "<li>a", "", null), .{ .indent = .indent }));
    // 자기 닫힘은 void 가 아닌 요소로도 잰다(`<br/>` 는 void 목록이 먼저 걸러 자기 닫힘 판정을 못 잰다 — H14).
    for ([_][]const u8{ "<br>", "<img src=\"x\">", "</div>", "<br/>", "<!-- a -->", "a < b", "<Foo />", "<div/>" }) |l| try testing.expect(sameAction(decide(html, l, "", null), .{}));
}
