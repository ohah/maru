//! maru-browser 에이전트 플러그인(`plugins/maru-browser/`)이 **지금의 `maru browser` CLI 와 어긋나지 않는가**를 지킨다.
//!
//! 왜 중요한가: 스킬은 사용자의 Claude Code 에 배포돼, Maru pane 안에서 도는 에이전트가 그 글을 보고 셸 명령을 친다.
//! 스킬의 예시가 낡으면(옵션 이름이 바뀌었는데 스킬은 옛 철자) 에이전트는 매번 `unknown option` 과 9 KB 짜리 help 를
//! 받고 헤맨다. 반대로 CLI 에 새 명령이 생겼는데 스킬이 모르면 에이전트는 그 명령을 영영 안 쓴다. 둘 다 CLI 를 바꾼
//! PR 에서 잡아야 싸다 — 그래서 이 시험은 스킬 파일과 **진짜 파서**(`maru.cli.browser.parse`)·**진짜 help 문자열**
//! (`browser_help`)을 한자리에서 맞춘다. 설계와 결정은 control-plane-browser.md §9.6.3 이 단일 출처다.
//!
//! 무엇을 증명하나(한 가지씩 test 블록):
//!   ① 스킬의 모든 `maru browser …` 예시(코드 블록은 언어 표지와 무관하게 전부, 인라인 코드도)가 파서를 통과한다.
//!      바이너리를 돌려 exit 코드로 재지 않는 이유: 파스 오류도 「인스턴스 없음」도 exit 1 이라 둘을 못 가른다(실측).
//!   ② help 의 모든 하위 명령이 스킬 어딘가에 언급된다(역방향) — CLI 가 자라면 스킬 갱신을 같은 PR 에서 강제한다.
//!   ③ 스킬의 「쓸 수 있나」 점검이 쓰는 help 검사(`grep '^  open '`)가 help 에 **정확히 한 줄** 맞는다(ATTACK A19).
//!   ④ 스킬 안 상대 링크가 살아 있고, 참조 파일은 모두 SKILL.md 에서 한 단계로 걸린다.
//!   ⑤ 매니페스트 둘(plugin.json·marketplace.json)과 SKILL.md 앞머리가 서로 맞는다(이름·경로·semver·version 은 한 곳).
//!   ⑥ 스킬이 요구하는 최소 maru 버전이 한 곳뿐이고, 이 저장소가 내는 maru(`build.zig.zon` `.version`) 이하다.
//!
//! **공허하게 통과하지 않는다**(project-rules 「못 찾으면 실패」·pr-checklist 「판정자 규율」): 추출한 예시 수와 help 명령
//! 수에 하한을 단언하고, 코드 표시 밖 산문에 `maru browser` 가 나오면 실패한다 — 모든 명령이 ①을 지나게 하려고.
//! 아래 「스캐너 자체」 test 들은 추출 규칙이 실제로 그렇게 도는지(```bash 블록도 읽는다, 주석을 자른다 …)를 잰다.

const std = @import("std");
const browser = @import("maru").cli.browser;
/// 이 트리가 빌드하는 maru 의 버전(`build.zig.zon` `.version` — `maru --version` 이 내는 값과 같은 단일 출처).
const maru_version: []const u8 = @import("maru_version").version;
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const io = std.testing.io;

/// 저장소 루트 기준(build.zig 가 cwd 를 루트에 고정한다).
const plugin_root = "plugins/maru-browser";
const skill_dir = plugin_root ++ "/skills/maru-browser";
const skill_path = skill_dir ++ "/SKILL.md";
const plugin_manifest_path = plugin_root ++ "/.claude-plugin/plugin.json";
const marketplace_path = ".claude-plugin/marketplace.json";

/// 하한 — 「찾지 못함 = 통과」를 막는다. 지금 값보다 넉넉히 낮게 둬 문장 다듬기로는 안 걸리고,
/// 추출 규칙이 깨져 거의 0 이 되면 걸린다.
const min_skill_examples = 6;
const min_total_examples = 15;
const min_help_commands = 30;
const min_plugin_markdown_files = 7; // SKILL.md + 참조 5 + README

/// help 의 명령 가운데 스킬이 **일부러** 언급하지 않는 것과 그 이유. 비어 있는 것이 목표다 — 여기 넣으려면 이유를 적는다.
const intentionally_unmentioned = [_]struct { name: []const u8, why: []const u8 }{};

/// SKILL.md 앞머리에 쓰는 칸. Agent Skills 표준에서 이식 가능한 칸만 둔다 — 같은 SKILL.md 를 다른 에이전트에 복사해도
/// 오류가 나지 않게(claude.ai·API 업로드는 모르는 칸을 거절한다 — §9.6.3).
const allowed_frontmatter_keys = [_][]const u8{ "name", "description", "license", "compatibility", "metadata", "allowed-tools" };

// ── 마크다운 → 명령 추출 ───────────────────────────────────────────────────────────────────────────────────

/// 스킬 글에서 찾은 명령 하나.
const Example = struct {
    file: []const u8,
    line: usize,
    /// 원문(보고용).
    text: []const u8,
    /// `maru browser` 뒤의 인자(자리표시는 이미 바꿨다).
    args: []const []const u8,
};

const Scan = struct {
    examples: std.ArrayList(Example) = .empty,
    /// 언급된 하위 명령 이름(예시의 첫 인자 + 인라인 코드의 한 단어 명령).
    mentioned: std.StringHashMapUnmanaged(void) = .empty,
    /// `--help` 검사의 grep 패턴(`maru browser --help | grep … '<패턴>'`).
    help_greps: std.ArrayList([]const u8) = .empty,
    /// 규칙 위반(보고 문장).
    problems: std.ArrayList([]const u8) = .empty,
    /// `maru X.Y.Z` 꼴 인라인 코드(버전 언급) — ⑥이 최소 버전을 찾는다.
    versions: std.ArrayList(struct { file: []const u8, line: usize, version: []const u8 }) = .empty,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

/// 셸 한 줄을 단순 명령들로 가른다 — 따옴표 밖의 `|`·`||`·`&&`·`&`·`;` 에서 자르고, 따옴표 밖에서 낱말을 시작하는 `#` 부터는
/// 주석이라 버린다(`maru browser open … # → opened 12`). 따옴표가 안 닫히면 null.
fn shellSegments(arena: std.mem.Allocator, line: []const u8) !?[]const []const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var end: usize = line.len;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\' and i + 1 < line.len) {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '#' => if (i == 0 or isSpace(line[i - 1])) {
                end = i;
                break;
            },
            '|', '&', ';' => {
                try segs.append(arena, line[start..i]);
                if (i + 1 < line.len and line[i + 1] == c) i += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    if (quote != 0) return null;
    if (start <= end) try segs.append(arena, line[start..end]);
    return segs.items;
}

/// `browser_help` 의 명령 이름들 — `commands:` 다음 줄부터 빈 줄까지, **두 칸 들여쓰기 + 소문자로 시작하는 낱말**인 줄의
/// 첫 낱말(`  (click/type/… also take …)` 같은 덧붙임 줄은 괄호로 시작해 빠진다). 문자열 위치가 아니라 줄의 모양으로 찾는다.
fn helpCommands(arena: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, browser.browser_help, '\n');
    var in_commands = false;
    while (it.next()) |raw| {
        if (!in_commands) {
            if (std.mem.eql(u8, raw, "commands:")) in_commands = true;
            continue;
        }
        if (raw.len == 0) break;
        if (raw.len < 3 or !std.mem.startsWith(u8, raw, "  ") or !std.ascii.isLower(raw[2])) continue;
        const rest = raw[2..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        try names.append(arena, rest[0..sp]);
    }
    return names.items;
}

fn isHelpCommand(commands: []const []const u8, word: []const u8) bool {
    for (commands) |c| if (std.mem.eql(u8, c, word)) return true;
    return false;
}

/// `<id>`·`<file>` 같은 자리표시 낱말을 파서가 받는 값으로 바꾼다. 숫자 자리(`--surface`·`--req`·`--rule`)도
/// 글 자리(`--url`·`--text`)도 받는 값 하나(`12`)로 충분하다.
fn substitutePlaceholder(token: []const u8) []const u8 {
    if (token.len >= 3 and token[0] == '<' and token[token.len - 1] == '>') return "12";
    return token;
}

fn problem(arena: std.mem.Allocator, scan: *Scan, comptime fmt: []const u8, args: anytype) !void {
    try scan.problems.append(arena, try std.fmt.allocPrint(arena, fmt, args));
}

/// 셸 명령 조각 하나를 판정한다. `inline_span` 이면 한 낱말 명령(`` `open` ``)은 예시가 아니라 언급으로 센다.
fn takeCommand(
    arena: std.mem.Allocator,
    scan: *Scan,
    commands: []const []const u8,
    file: []const u8,
    line_no: usize,
    text: []const u8,
    inline_span: bool,
) !void {
    const segments = (try shellSegments(arena, text)) orelse {
        try problem(arena, scan, "{s}:{d}: 따옴표가 닫히지 않는다 — {s}", .{ file, line_no, text });
        return;
    };
    for (segments, 0..) |segment, seg_index| {
        const trimmed = std.mem.trim(u8, segment, " \t\r");
        if (trimmed.len == 0) continue;
        const tokens = (try browser.splitLine(arena, trimmed)) orelse {
            try problem(arena, scan, "{s}:{d}: 따옴표가 닫히지 않는다 — {s}", .{ file, line_no, trimmed });
            continue;
        };
        if (tokens.len == 0) continue;
        // `maru browser` 가 명령의 맨 앞이 아닌 꼴(`X=1 maru browser …`·`sudo maru browser …`)은 아래 판정을 비껴가므로 금지한다.
        for (tokens[1..], 1..) |t, k| {
            if (std.mem.eql(u8, t, "maru") and k + 1 < tokens.len and std.mem.eql(u8, tokens[k + 1], "browser")) {
                try problem(arena, scan, "{s}:{d}: `maru browser` 는 명령의 맨 앞에 둔다 — {s}", .{ file, line_no, trimmed });
            }
        }
        var args: []const []const u8 = undefined;
        if (tokens.len >= 2 and std.mem.eql(u8, tokens[0], "maru") and std.mem.eql(u8, tokens[1], "browser")) {
            // 인라인 `` `maru browser` `` 은 CLI 이름 자체의 언급이다.
            if (tokens.len == 2 and inline_span) continue;
            args = tokens[2..];
        } else if (isHelpCommand(commands, tokens[0])) {
            if (tokens.len == 1 and inline_span) {
                try scan.mentioned.put(arena, tokens[0], {});
                continue;
            }
            args = tokens;
        } else continue;

        const subst = try arena.alloc([]const u8, args.len);
        for (args, 0..) |a, k| subst[k] = substitutePlaceholder(a);

        if (browser.parse(subst)) |cmd| {
            if (cmd == .help) {
                // 도움말은 `maru browser --help` 그 꼴만 — 다른 꼴의 `.help`(`open --help`)는 구판에서도 exit 0 이라 점검에 못 쓴다.
                if (!(subst.len == 1 and std.mem.eql(u8, subst[0], "--help"))) {
                    try problem(arena, scan, "{s}:{d}: 도움말 예시는 `maru browser --help` 꼴만 쓴다 — {s}", .{ file, line_no, trimmed });
                    continue;
                }
                // `--help | grep … '<패턴>'` 이면 그 패턴을 ③이 본다.
                if (seg_index + 1 < segments.len) {
                    const next = std.mem.trim(u8, segments[seg_index + 1], " \t\r");
                    if (try browser.splitLine(arena, next)) |gt| {
                        if (gt.len >= 2 and std.mem.eql(u8, gt[0], "grep")) try scan.help_greps.append(arena, gt[gt.len - 1]);
                    }
                }
            } else {
                try scan.mentioned.put(arena, subst[0], {});
            }
            try scan.examples.append(arena, .{ .file = file, .line = line_no, .text = trimmed, .args = subst });
        } else |err| {
            try problem(arena, scan, "{s}:{d}: 파서가 거절한다({s}) — {s}", .{ file, line_no, @errorName(err), trimmed });
        }
    }
}

/// 마크다운 하나를 훑는다. 펜스(```` ``` ````·`~~~`) 안은 **언어 표지와 무관하게** 줄마다 셸 명령으로, 펜스 밖은 인라인 코드
/// 조각마다 명령으로 본다. 펜스 밖에서 코드 표시를 뺀 산문에 `maru browser` 가 남으면 위반이다(코드 표시 없는 명령은
/// 파서 판정을 비껴가므로).
fn scanMarkdown(arena: std.mem.Allocator, scan: *Scan, commands: []const []const u8, file: []const u8, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var fence: ?[]const u8 = null;
    var in_frontmatter = false;
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const lead = std.mem.trimStart(u8, line, " \t");
        // 앞머리의 `allowed-tools` 값은 명령이 아니라 권한 규칙(`Bash(maru browser *)`)이다 — ⑤가 값을 통째로 고정한다.
        if (line_no == 1 and std.mem.eql(u8, line, "---")) {
            in_frontmatter = true;
            continue;
        }
        if (in_frontmatter) {
            if (std.mem.eql(u8, line, "---")) {
                in_frontmatter = false;
                continue;
            }
            if (std.mem.startsWith(u8, line, "allowed-tools:")) continue;
        }
        if (fence) |f| {
            if (std.mem.startsWith(u8, lead, f)) {
                fence = null;
                continue;
            }
            try takeCommand(arena, scan, commands, file, line_no, lead, false);
            continue;
        }
        if (std.mem.startsWith(u8, lead, "```")) {
            fence = "```";
            continue;
        }
        if (std.mem.startsWith(u8, lead, "~~~")) {
            fence = "~~~";
            continue;
        }
        // 인라인 코드: 백틱 n 개로 열고 같은 n 개로 닫는다(CommonMark). 닫히지 않으면 그 백틱은 글자다.
        var prose: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] != '`') {
                try prose.append(arena, line[i]);
                i += 1;
                continue;
            }
            var n: usize = 0;
            while (i + n < line.len and line[i + n] == '`') n += 1;
            const open_end = i + n;
            var j = open_end;
            const close: ?usize = while (j < line.len) {
                if (line[j] != '`') {
                    j += 1;
                    continue;
                }
                var m: usize = 0;
                while (j + m < line.len and line[j + m] == '`') m += 1;
                if (m == n) break j;
                j += m;
            } else null;
            if (close) |c| {
                const span = std.mem.trim(u8, line[open_end..c], " ");
                if (std.mem.startsWith(u8, span, "maru ") and isSemver(span[5..])) {
                    try scan.versions.append(arena, .{ .file = file, .line = line_no, .version = span[5..] });
                }
                try takeCommand(arena, scan, commands, file, line_no, span, true);
                try prose.append(arena, ' ');
                i = c + n;
            } else {
                try prose.appendSlice(arena, line[i..open_end]);
                i = open_end;
            }
        }
        if (std.mem.indexOf(u8, prose.items, "maru browser") != null) {
            try problem(arena, scan, "{s}:{d}: 코드 표시 밖에 `maru browser` 가 있다 — 명령은 늘 `…` 나 코드 블록에 둔다", .{ file, line_no });
        }
    }
    if (fence != null) try problem(arena, scan, "{s}: 코드 블록이 닫히지 않는다", .{file});
}

// ── 파일 모으기 ───────────────────────────────────────────────────────────────────────────────────────────

const MdFile = struct { path: []const u8, text: []const u8 };

/// 플러그인 아래 모든 `.md` — 목록을 손으로 두면 새 참조 파일을 빠뜨려 게이트가 조용히 통과한다.
fn pluginMarkdown(arena: std.mem.Allocator) ![]const MdFile {
    var files: std.ArrayList(MdFile) = .empty;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, plugin_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try posixWalk(dir, arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ plugin_root, entry.path });
        const text = try cwd.readFileAlloc(io, path, arena, .limited(1024 * 1024));
        try files.append(arena, .{ .path = path, .text = text });
    }
    // walker 순서는 파일 시스템마다 다르다 — 보고를 결정적으로.
    std.mem.sort(MdFile, files.items, {}, struct {
        fn lt(_: void, a: MdFile, b: MdFile) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    return files.items;
}

fn scanPlugin(arena: std.mem.Allocator) !struct { scan: Scan, files: []const MdFile, commands: []const []const u8 } {
    const commands = try helpCommands(arena);
    const files = try pluginMarkdown(arena);
    var scan: Scan = .{};
    for (files) |f| try scanMarkdown(arena, &scan, commands, f.path, f.text);
    return .{ .scan = scan, .files = files, .commands = commands };
}

fn reportProblems(scan: *const Scan) usize {
    for (scan.problems.items) |p| std.debug.print("{s}\n", .{p});
    return scan.problems.items.len;
}

// ── ① 예시 → 진짜 파서 ────────────────────────────────────────────────────────────────────────────────────

test "① 스킬의 모든 maru browser 예시가 진짜 파서를 통과하고, 예시가 하한 이상 있다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try scanPlugin(arena);

    try std.testing.expect(got.files.len >= min_plugin_markdown_files);
    var in_skill: usize = 0;
    for (got.scan.examples.items) |e| {
        if (std.mem.eql(u8, e.file, skill_path)) in_skill += 1;
    }
    // 실제로 무엇을 쟀는지 늘 한 줄 남긴다 — 「초록」만으로는 0 개를 잰 초록과 구별이 안 된다.
    std.debug.print("plugin skill: 파일 {d} · 예시 {d}(SKILL.md {d}) · 언급된 명령 {d}\n", .{
        got.files.len, got.scan.examples.items.len, in_skill, got.scan.mentioned.count(),
    });
    if (in_skill < min_skill_examples or got.scan.examples.items.len < min_total_examples) {
        std.debug.print("예시가 너무 적다 — SKILL.md {d}(하한 {d}), 전체 {d}(하한 {d}). 추출 규칙이 깨졌거나 스킬이 비었다.\n", .{
            in_skill, min_skill_examples, got.scan.examples.items.len, min_total_examples,
        });
        return error.TooFewExamples;
    }
    try std.testing.expectEqual(@as(usize, 0), reportProblems(&got.scan));
}

// ── ② help → 스킬(역방향) ────────────────────────────────────────────────────────────────────────────────

test "② help 의 모든 하위 명령이 스킬에 언급된다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try scanPlugin(arena);

    std.debug.print("plugin skill: help 명령 {d}\n", .{got.commands.len});
    try std.testing.expect(got.commands.len >= min_help_commands);
    var missing: usize = 0;
    for (got.commands) |name| {
        // help 에서 뽑은 낱말이 정말 명령인가 — 파서가 「모르는 명령」이라 하면 추출이 틀린 것이다(문자열이 아니라 파서로 확인).
        if (browser.parse(&.{name})) |_| {} else |err| {
            if (err == error.UnknownSubcommand) {
                std.debug.print("help 에서 뽑은 `{s}` 를 파서가 모른다 — helpCommands 추출이 틀렸다\n", .{name});
                missing += 1;
                continue;
            }
        }
        if (got.scan.mentioned.contains(name)) continue;
        var excused = false;
        for (intentionally_unmentioned) |x| {
            if (std.mem.eql(u8, x.name, name)) excused = true;
        }
        if (excused) continue;
        std.debug.print("help 의 `{s}` 가 스킬 어디에도 없다 — 참조 파일에 언급하거나 intentionally_unmentioned 에 이유와 함께 적는다\n", .{name});
        missing += 1;
    }
    // 면제 목록이 낡지 않게 — 이제 help 에 없거나 이미 언급되는 이름이면 목록에서 지운다.
    for (intentionally_unmentioned) |x| {
        if (!isHelpCommand(got.commands, x.name) or got.scan.mentioned.contains(x.name)) {
            std.debug.print("intentionally_unmentioned 의 `{s}` 는 더 필요 없다\n", .{x.name});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

// ── ③ 점검의 help 검사 ──────────────────────────────────────────────────────────────────────────────────

test "③ 스킬 점검의 `maru browser --help | grep` 패턴이 help 에 정확히 한 줄 맞는다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = try helpCommands(arena);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, skill_path, arena, .limited(1024 * 1024));
    var scan: Scan = .{};
    try scanMarkdown(arena, &scan, commands, skill_path, text);

    if (scan.help_greps.items.len == 0) {
        std.debug.print("SKILL.md 에 `maru browser --help | grep …` 점검이 없다 — 구판 maru 를 거를 길이 없어진다\n", .{});
        return error.MissingHelpCheck;
    }
    for (scan.help_greps.items) |pattern| {
        // `^` + 글자 그대로만 허용한다 — 정규식 기호를 쓰면 아래 「줄 머리 비교」가 grep 과 다른 답을 낸다.
        try std.testing.expect(pattern.len > 1 and pattern[0] == '^');
        const literal = pattern[1..];
        try std.testing.expect(std.mem.indexOfAny(u8, literal, ".[]*+?(){}|$\\") == null);
        var hits: usize = 0;
        var it = std.mem.splitScalar(u8, browser.browser_help, '\n');
        while (it.next()) |l| {
            if (std.mem.startsWith(u8, l, literal)) hits += 1;
        }
        if (hits != 1) {
            std.debug.print("점검 패턴 '{s}' 가 help 에 {d} 줄 맞는다(1 이어야) — help 모양이 바뀌었으면 SKILL.md 점검도 함께 고친다\n", .{ pattern, hits });
            return error.HelpCheckDrift;
        }
    }
}

// ── ④ 링크 ───────────────────────────────────────────────────────────────────────────────────────────────

/// `](대상)` 의 대상들(외부 URL·같은 문서 앵커 제외, `#앵커` 는 뗀다).
fn relativeLinks(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "](")) |at| {
        const start = at + 2;
        const end = std.mem.indexOfScalarPos(u8, text, start, ')') orelse break;
        i = end;
        var target = text[start..end];
        if (std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) continue;
        if (std.mem.indexOfScalar(u8, target, '#')) |h| target = target[0..h];
        if (target.len == 0) continue;
        try out.append(arena, target);
    }
    return out.items;
}

test "④ 스킬 안 상대 링크가 살아 있고, 참조 파일은 모두 SKILL.md 에서 바로 걸린다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = try pluginMarkdown(arena);
    const cwd = std.Io.Dir.cwd();

    var broken: usize = 0;
    var skill_links: []const []const u8 = &.{};
    for (files) |f| {
        const links = try relativeLinks(arena, f.text);
        if (std.mem.eql(u8, f.path, skill_path)) skill_links = links;
        const base = std.fs.path.dirname(f.path) orelse ".";
        for (links) |l| {
            const resolved = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, l });
            cwd.access(io, resolved, .{}) catch {
                std.debug.print("{s}: 링크 대상이 없다 — {s}\n", .{ f.path, l });
                broken += 1;
            };
        }
    }
    // 참조는 SKILL.md 에서 한 단계 — 참조를 거쳐야 닿는 파일은 에이전트가 끝까지 안 읽을 수 있다(§9.6.3).
    var refs: usize = 0;
    const ref_prefix = skill_dir ++ "/references/";
    for (files) |f| {
        if (!std.mem.startsWith(u8, f.path, ref_prefix)) continue;
        refs += 1;
        const rel = f.path[skill_dir.len + 1 ..];
        var linked = false;
        for (skill_links) |l| {
            if (std.mem.eql(u8, l, rel)) linked = true;
        }
        if (!linked) {
            std.debug.print("{s} 가 SKILL.md 에서 바로 걸리지 않는다\n", .{f.path});
            broken += 1;
        }
    }
    try std.testing.expect(refs >= 5);
    try std.testing.expectEqual(@as(usize, 0), broken);
}

// ── ⑤ 매니페스트 ─────────────────────────────────────────────────────────────────────────────────────────

fn isSemver(v: []const u8) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    var parts: usize = 0;
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0) return false;
        if (p.len > 1 and p[0] == '0') return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return parts == 3;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// SKILL.md 앞머리(`---` … `---`)의 최상위 `키: 값` — 들여쓴 줄(값의 이어짐)은 키가 아니다.
fn frontmatter(arena: std.mem.Allocator, text: []const u8) !?std.StringArrayHashMapUnmanaged([]const u8) {
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, first, "\r"), "---")) return null;
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) return map;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        try map.put(arena, line[0..colon], std.mem.trim(u8, line[colon + 1 ..], " "));
    }
    return null; // 닫히지 않은 앞머리
}

test "⑤ 매니페스트 둘과 SKILL.md 앞머리가 서로 맞는다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();

    const market_text = try cwd.readFileAlloc(io, marketplace_path, arena, .limited(64 * 1024));
    const market = try std.json.parseFromSliceLeaky(std.json.Value, arena, market_text, .{});
    try std.testing.expect(market == .object);
    try std.testing.expectEqualStrings("maru", getString(market.object, "name") orelse "");
    const owner = market.object.get("owner") orelse return error.MissingOwner;
    try std.testing.expect(owner == .object and getString(owner.object, "name") != null);
    const plugins = market.object.get("plugins") orelse return error.MissingPlugins;
    try std.testing.expect(plugins == .array and plugins.array.items.len >= 1);

    const plugin_text = try cwd.readFileAlloc(io, plugin_manifest_path, arena, .limited(64 * 1024));
    const plugin = try std.json.parseFromSliceLeaky(std.json.Value, arena, plugin_text, .{});
    try std.testing.expect(plugin == .object);
    const plugin_name = getString(plugin.object, "name") orelse return error.MissingName;
    try std.testing.expectEqualStrings("maru-browser", plugin_name);
    const version = getString(plugin.object, "version") orelse return error.MissingVersion;
    if (!isSemver(version)) {
        std.debug.print("plugin.json version '{s}' 은 MAJOR.MINOR.PATCH 가 아니다\n", .{version});
        return error.BadVersion;
    }

    var found: usize = 0;
    for (plugins.array.items) |entry| {
        try std.testing.expect(entry == .object);
        const name = getString(entry.object, "name") orelse return error.MissingName;
        const source = getString(entry.object, "source") orelse return error.MissingSource;
        // 상대 경로 source 는 마켓플레이스 루트(저장소 루트) 기준 `./…` 이다.
        try std.testing.expect(std.mem.startsWith(u8, source, "./"));
        const manifest = try std.fmt.allocPrint(arena, "{s}/.claude-plugin/plugin.json", .{source[2..]});
        cwd.access(io, manifest, .{}) catch {
            std.debug.print("marketplace 항목 `{s}` 의 source `{s}` 에 .claude-plugin/plugin.json 이 없다\n", .{ name, source });
            return error.MissingPluginDir;
        };
        // version 은 plugin.json 한 곳에만 — 두 곳이면 plugin.json 이 조용히 이기고 둘이 갈린다.
        if (entry.object.get("version") != null) {
            std.debug.print("marketplace 항목 `{s}` 에 version 이 있다 — plugin.json 에만 둔다\n", .{name});
            return error.VersionInTwoPlaces;
        }
        if (std.mem.eql(u8, name, plugin_name)) {
            found += 1;
            try std.testing.expectEqualStrings("./" ++ plugin_root, source);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found);

    const skill_text = try cwd.readFileAlloc(io, skill_path, arena, .limited(1024 * 1024));
    const fm = (try frontmatter(arena, skill_text)) orelse return error.MissingFrontmatter;
    for (fm.keys()) |k| {
        var ok = false;
        for (allowed_frontmatter_keys) |a| {
            if (std.mem.eql(u8, a, k)) ok = true;
        }
        if (!ok) {
            std.debug.print("SKILL.md 앞머리 `{s}` 는 이식 가능한 칸이 아니다\n", .{k});
            return error.NonPortableFrontmatter;
        }
    }
    try std.testing.expectEqualStrings("maru-browser", fm.get("name") orelse "");
    const description = fm.get("description") orelse return error.MissingDescription;
    try std.testing.expect(description.len > 0 and description.len <= 1024);
    try std.testing.expect(std.mem.indexOfScalar(u8, description, '<') == null);
    // 묻지 않고 쓸 도구는 `maru browser` 명령뿐이어야 한다(사용자 결정 D5) — 다른 도구가 끼면 이 스킬이 그 권한까지 연다.
    if (fm.get("allowed-tools")) |tools| try std.testing.expectEqualStrings("Bash(maru browser *)", tools);
}

// ── ⑥ 최소 maru 버전 ─────────────────────────────────────────────────────────────────────────────────

fn semverLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    for (0..3) |_| {
        const x = std.fmt.parseInt(u64, ia.next().?, 10) catch unreachable;
        const y = std.fmt.parseInt(u64, ib.next().?, 10) catch unreachable;
        if (x != y) return x < y;
    }
    return false;
}

test "⑥ 스킬의 최소 maru 버전은 SKILL.md 한 곳이고, 이 저장소의 maru 버전 이하다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try scanPlugin(arena);

    // `maru 0.0.0` 은 최소가 아니라 「버전을 매기기 전 소스 빌드」의 언급이다(점검의 갈래 하나).
    var minimum: ?[]const u8 = null;
    var count: usize = 0;
    for (got.scan.versions.items) |v| {
        if (std.mem.eql(u8, v.version, "0.0.0")) continue;
        count += 1;
        std.debug.print("plugin skill: 최소 버전 언급 {s}:{d} maru {s}\n", .{ v.file, v.line, v.version });
        if (!std.mem.eql(u8, v.file, skill_path)) {
            std.debug.print("최소 버전은 SKILL.md 에만 둔다 — {s}:{d}\n", .{ v.file, v.line });
            return error.MinimumOutsideSkill;
        }
        minimum = v.version;
    }
    // 한 곳 — 둘이면 하나만 고쳐 갈린다. 없으면 점검이 무엇과 비교하는지 잃는다.
    if (count != 1) {
        std.debug.print("최소 maru 버전(`maru X.Y.Z` 인라인 코드, 0.0.0 제외)이 {d} 곳이다 — 1 곳이어야 한다\n", .{count});
        return error.MinimumNotSingle;
    }
    try std.testing.expect(isSemver(maru_version));
    // 이 저장소가 아직 내지 않은 maru 를 요구하면 모든 사용자가 「갱신하라」를 받는다. `0.0.0` 도 예외 없이 비교한다 —
    // 버전을 매기기 전 트리에 이 스킬이 들어가면 바로 그 일이 난다(§9.6.3).
    if (semverLess(maru_version, minimum.?)) {
        std.debug.print("스킬은 maru {s} 이상을 요구하는데 이 트리의 build.zig.zon 은 {s} 다 — 버전을 올리는 PR 이 먼저 들어가야 한다\n", .{ minimum.?, maru_version });
        return error.MinimumAboveThisTree;
    }
}

// ── 스캐너 자체 ───────────────────────────────────────────────────────────────────────────────────────────
// 위 판정이 「아무것도 못 찾아 초록」이 되지 않는지를 작은 글로 직접 잰다(ATTACK A15).

fn scanText(arena: std.mem.Allocator, text: []const u8) !Scan {
    var scan: Scan = .{};
    try scanMarkdown(arena, &scan, try helpCommands(arena), "t.md", text);
    return scan;
}

test "스캐너: 언어 표지와 무관하게 모든 펜스를 읽고, 주석·자리표시를 처리한다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scan = try scanText(arena,
        \\```bash
        \\maru browser click --surface <id> --ref n41   # → ok
        \\```
        \\~~~
        \\maru browser screenshot --surface 12 --out "${TMPDIR:-/tmp}/s-$(date +%s).png"
        \\~~~
        \\```
        \\maru browser --help | grep -c '^  open '
        \\```
    );
    try std.testing.expectEqual(@as(usize, 0), scan.problems.items.len);
    try std.testing.expectEqual(@as(usize, 3), scan.examples.items.len);
    try std.testing.expectEqualStrings("12", scan.examples.items[0].args[2]);
    try std.testing.expectEqual(@as(usize, 1), scan.help_greps.items.len);
    try std.testing.expectEqualStrings("^  open ", scan.help_greps.items[0]);
}

test "스캐너: 틀린 옵션·코드 밖 명령·앞에 무언가 붙은 명령은 위반이다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "```\nmaru browser click --surface 1 --reff n4\n```\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "run maru browser list first\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "`X=1 maru browser list`\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "`maru browser open --help`\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "```sh\nmaru browser list\n")).problems.items.len); // 안 닫힌 펜스
}

test "스캐너: 인라인 코드 — 한 낱말 명령은 언급, 인자가 있으면 예시, CLI 이름만은 통과" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const scan = try scanText(arena, "Use `maru browser` — `close` your tab with `close --surface <id>`; ``maru browser list`` too.\n");
    try std.testing.expectEqual(@as(usize, 0), scan.problems.items.len);
    try std.testing.expectEqual(@as(usize, 2), scan.examples.items.len);
    try std.testing.expect(scan.mentioned.contains("close") and scan.mentioned.contains("list"));
    const vs = try scanText(arena, "Needs `maru 0.1.0`; `maru 0.0.0` is a source build; `maru X.Y.Z` is not a version.\n");
    try std.testing.expectEqual(@as(usize, 2), vs.versions.items.len);
    try std.testing.expectEqualStrings("0.1.0", vs.versions.items[0].version);
    try std.testing.expect(semverLess("0.9.9", "0.10.0") and !semverLess("0.1.0", "0.1.0") and semverLess("0.0.0", "0.1.0"));
    // 인자가 있는데 파서가 거절하면 위반이다(`close` 는 `--surface` 가 필수).
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "`close --now`\n")).problems.items.len);
}

test "스캐너: help 명령 추출은 덧붙임 줄을 빼고 파서가 아는 이름만 낸다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = try helpCommands(arena);
    try std.testing.expect(isHelpCommand(commands, "open") and isHelpCommand(commands, "trace") and isHelpCommand(commands, "repl"));
    for (commands) |c| try std.testing.expect(c[0] != '(');
}
