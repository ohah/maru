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
//!   ⑦ SKILL.md 의 「규칙」 구역(`<!-- maru:agent-rules:begin -->` … `end`)이 정확히 하나, 코드 블록 밖, 비지 않았다 — 이 구역은
//!      `maru mcp` 의 `instructions` 맨 앞에 **빌드 때 그대로** 심긴다(M10 — 규칙은 두 채널이 한 글).
//!   ⑧ 실제 `initialize` 응답의 `instructions` 가 그 구역 글로 **바이트 그대로** 시작한다(배선을 잰다 — 상수가 아니라).
//!   ⑨ 그 구역에 표면 고유 낱말(`maru browser`·`maru mcp`·`browser_`·플래그·인라인 코드·숫자·`$`)이 없다 — MCP 와 CLI 가 같은 글을 읽는다.
//!   ⑩ 「your tab」·「your own tab」 을 아무 데서도 쓰지 않는다 — CLI help 는 사람의 탭을, 스킬은 에이전트가 연 탭을 그렇게 불러 뜻이
//!      반대였다(M10 D7). 플러그인 글·`maru browser --help`·`maru mcp` 의 응답(instructions·도구와 인자 설명)·`maru mcp --help` 가
//!      「the user's tabs」 와 「tabs you opened」 로 말한다.
//!   ⑪ 사용자에게 묻는 호출에 주라는 시한 — 스킬의 「at least N minutes」·「N-minute」·Bash `timeout: N` 이 `maru mcp` 가 쓰는 같은 상수(`mcp.ask_wait_text`·
//!      `ask_wait_ms`, 사용자 결정 D5)와 같고, 그 대기(「about N s」)가 시한보다 짧다 — 두 표면의 숫자가 따로 바뀌지 못하게.
//!
//! **공허하게 통과하지 않는다**(project-rules 「못 찾으면 실패」·pr-checklist 「판정자 규율」): 추출한 예시 수와 help 명령
//! 수에 하한을 단언하고, 코드 표시 밖 산문에 `maru browser` 가 나오면 실패한다 — 모든 명령이 ①을 지나게 하려고.
//! 아래 「스캐너 자체」 test 들은 추출 규칙이 실제로 그렇게 도는지(```bash 블록도 읽는다, 주석을 자른다 …)를 잰다.

const std = @import("std");
const browser = @import("maru").cli.browser;
/// `maru mcp` 의 순수 절반 — ⑦⑧⑩ 이 표지 이름과 실제 `initialize`·`tools/list` 응답을 여기서 얻는다.
const mcp = @import("maru").cli.mcp;
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

/// `browser_help` 의 명령 이름들 — 줄 모양 규칙(`commands:` 절의 「두 칸 + 소문자로 시작하는 낱말」)은 `browser.help_command_names` 한 곳이
/// 소유한다(하위 명령 help 와 모르는 명령의 목록도 그것을 쓴다 — 같은 규칙을 이 시험에 또 두면 두 벌이 갈린다). 추출이 틀렸는지는 ② 가 파서로 본다.
fn helpCommands(arena: std.mem.Allocator) ![]const []const u8 {
    _ = arena;
    return browser.help_command_names;
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
                // 도움말은 두 꼴만 — 전역 `maru browser --help` 와 한 명령 `maru browser <명령> --help`(사용자 결정 D6). 한 명령 꼴은
                // 구판 maru 에서 전역 help(exit 0)라 읽기 예시로는 해가 없지만, 구판을 거르는 **점검**(`| grep`)에는 전역 꼴만 쓴다.
                const global = subst.len == 1 and std.mem.eql(u8, subst[0], "--help");
                const one = cmd.help != null and subst.len == 2 and std.mem.eql(u8, subst[1], "--help");
                if (!global and !one) {
                    try problem(arena, scan, "{s}:{d}: 도움말 예시는 `maru browser --help`·`maru browser <명령> --help` 꼴만 쓴다 — {s}", .{ file, line_no, trimmed });
                    continue;
                }
                // `--help | grep … '<패턴>'` 이면 그 패턴을 ③이 본다.
                if (seg_index + 1 < segments.len) {
                    const next = std.mem.trim(u8, segments[seg_index + 1], " \t\r");
                    if (try browser.splitLine(arena, next)) |gt| {
                        if (gt.len >= 2 and std.mem.eql(u8, gt[0], "grep")) {
                            if (!global) {
                                try problem(arena, scan, "{s}:{d}: help 점검(`| grep`)은 전역 `maru browser --help` 로만 한다 — {s}", .{ file, line_no, trimmed });
                                continue;
                            }
                            try scan.help_greps.append(arena, gt[gt.len - 1]);
                        }
                    }
                }
                if (one) try scan.mentioned.put(arena, subst[0], {});
            } else {
                // 파서는 받지만 한 번짜리 CLI 가 보내기 전에 거절하는 꼴(`--out` 없는 screenshot — M5)도 위반이다.
                if (browser.cliOutputRefusal(cmd)) |why| {
                    try problem(arena, scan, "{s}:{d}: CLI 가 거절한다({s}) — {s}", .{ file, line_no, why, trimmed });
                    continue;
                }
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

// ── ⑦⑧⑨ 「규칙」 구역 → `maru mcp` instructions (M10) ─────────────────────────────────────────────────────

const RegionError = error{ RegionMissing, RegionDuplicated, RegionOrder, RegionInFence, RegionEmpty, RegionMarkerNotAlone };

/// SKILL.md 에서 규칙 구역을 찾는다 — 표지 줄 사이의 줄들(앞뒤 공백 줄 제외). 표지는 **줄 하나를 통째로** 차지해야 하고, 시작·끝이
/// 정확히 하나씩, 그 순서로, 코드 블록 밖에 있어야 한다. 하나라도 어기면 오류다 — 못 찾고 통과하지 않는다(project-rules).
/// 바이너리의 추출(`mcp.zig` `agentRulesRegion`, 컴파일 때)과 **따로** 쓴 판이다 — 같은 함수를 부르면 그 함수의 틀림을 못 본다.
fn findRulesRegion(text: []const u8) RegionError![]const u8 {
    var begin_end: ?usize = null; // 시작 표지 줄 바로 뒤
    var end_start: ?usize = null; // 끝 표지 줄의 첫 바이트
    var in_fence = false;
    var pos: usize = 0;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..nl];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) in_fence = !in_fence;
        for ([_][]const u8{ mcp.agent_rules_begin, mcp.agent_rules_end }, 0..) |marker, which| {
            if (std.mem.indexOf(u8, line, marker) == null) continue;
            if (!std.mem.eql(u8, trimmed, marker)) return error.RegionMarkerNotAlone;
            if (in_fence) return error.RegionInFence;
            if (which == 0) {
                if (begin_end != null) return error.RegionDuplicated;
                if (end_start != null) return error.RegionOrder;
                begin_end = @min(nl + 1, text.len);
            } else {
                if (end_start != null) return error.RegionDuplicated;
                if (begin_end == null) return error.RegionOrder;
                end_start = pos;
            }
        }
        pos = nl + 1;
    }
    const a = begin_end orelse return error.RegionMissing;
    const b = end_start orelse return error.RegionMissing;
    const region = std.mem.trim(u8, text[a..b], " \t\r\n");
    if (region.len == 0) return error.RegionEmpty;
    return region;
}

/// 구역에 있으면 안 되는 표면 고유 낱말. 같은 글이 CLI 스킬과 MCP 도구 양쪽에 실리므로, 한쪽의 명령 이름·플래그·숫자는 다른 쪽에서 틀린
/// 말이 된다(예: CPU 조건의 수명은 CLI 에서는 에이전트 프로세스, MCP 에서는 그 연결 — §9.6.3). 숫자는 판마다 달라질 수 있는 동작 사실이다.
fn surfaceToken(region: []const u8) ?[]const u8 {
    for ([_][]const u8{ "maru browser", "browser_", "--", "`", "$", "maru mcp" }) |t| {
        if (std.mem.indexOf(u8, region, t) != null) return t;
    }
    for (region) |c| if (std.ascii.isDigit(c)) return "숫자";
    return null;
}

fn skillText(arena: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, skill_path, arena, .limited(1024 * 1024));
}

test "⑦ SKILL.md 의 규칙 구역 표지가 정확히 하나씩, 그 순서로, 코드 블록 밖에 있고 구역이 비지 않았다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const region = findRulesRegion(try skillText(arena)) catch |e| {
        std.debug.print("{s}: 규칙 구역({s} … {s})이 틀렸다: {s}\n", .{ skill_path, mcp.agent_rules_begin, mcp.agent_rules_end, @errorName(e) });
        return e;
    };
    std.debug.print("plugin skill: 규칙 구역 {d} 바이트\n", .{region.len});
    // 플러그인 글 중 표지가 있는 곳은 SKILL.md 하나 — 참조 파일에 사본이 생기면 어느 쪽이 심기는지 갈린다.
    for (try pluginMarkdown(arena)) |f| {
        if (std.mem.eql(u8, f.path, skill_path)) continue;
        if (std.mem.indexOf(u8, f.text, mcp.agent_rules_begin) != null or std.mem.indexOf(u8, f.text, mcp.agent_rules_end) != null) {
            std.debug.print("{s}: 규칙 구역 표지는 SKILL.md 에만 둔다\n", .{f.path});
            return error.RegionOutsideSkill;
        }
    }
}

test "⑧ 실제 initialize 응답의 instructions 가 SKILL.md 의 규칙 구역 글로 바이트 그대로 시작한다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const region = try findRulesRegion(try skillText(arena));
    const reply = (try mcp.handleLine(std.testing.allocator, arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).reply;
    defer std.testing.allocator.free(reply);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{ .allocate = .alloc_always });
    const served = v.object.get("result").?.object.get("instructions").?.string;
    if (!std.mem.startsWith(u8, served, region)) {
        // 이 시험이 도는 트리의 SKILL.md 와 바이너리에 심긴 글이 다르다 — 빌드 배선(build.zig `maru_browser_skill_md`)이 다른 파일을 가리키거나,
        // 추출 규칙(`mcp.agentRulesRegion`)이 이 시험의 것과 갈렸다.
        std.debug.print("instructions 가 규칙 구역으로 시작하지 않는다.\n--- 구역({d} 바이트)\n{s}\n--- instructions 앞({d} 바이트)\n{s}\n", .{
            region.len, region, @min(served.len, region.len), served[0..@min(served.len, region.len)],
        });
        return error.InstructionsDoNotStartWithRules;
    }
    // 구역 뒤에는 빈 줄 하나와 이 서버만의 안내만 온다(표면 고유 사실은 각자) — 구분자가 빠지거나, 끝 표지 줄이 따라 실리거나,
    // 다른 글이 덧붙으면 여기서 갈린다.
    const tail = served[region.len..];
    if (!std.mem.eql(u8, tail, "\n\n" ++ mcp.server_guidance)) {
        std.debug.print("instructions 의 구역 뒤가 「빈 줄 + server_guidance」 가 아니다:\n{s}\n", .{tail[0..@min(tail.len, 200)]});
        return error.InstructionsTailUnexpected;
    }
    try std.testing.expect(std.mem.indexOf(u8, mcp.server_guidance, "browser_list") != null);
}

test "⑨ 규칙 구역에 표면 고유 낱말(명령·도구 이름·플래그·인라인 코드·숫자)이 없다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const region = try findRulesRegion(try skillText(arena));
    if (surfaceToken(region)) |t| {
        std.debug.print("{s}: 규칙 구역에 표면 고유 낱말 「{s}」 — 이 글은 MCP 에도 그대로 실린다. 그 사실은 구역 밖(스킬의 다른 절, mcp.zig `server_guidance`)에\n", .{ skill_path, t });
        return error.SurfaceTokenInRules;
    }
}

/// 「your tab」·「your own tab」(대소문자 무시)의 첫 자리. 사람에게 쓴 글이면 「사용자 탭」, 에이전트에게 쓴 글이면 「에이전트 탭」 이라
/// 같은 말이 반대가 된다.
fn ambiguousTabWord(text: []const u8) ?usize {
    return std.ascii.findIgnoreCase(text, "your tab") orelse std.ascii.findIgnoreCase(text, "your own tab");
}

/// `maru mcp` 가 실제로 내는 글 — `initialize` 의 instructions 와 `tools/list` 의 모든 문자열(도구·인자 설명). 돌려준 글은 `arena` 소유.
fn servedMcpText(arena: std.mem.Allocator) ![]const u8 {
    var all: std.ArrayList(u8) = .empty;
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
    }) |line| {
        const reply = (try mcp.handleLine(std.testing.allocator, arena, line)).reply;
        defer std.testing.allocator.free(reply);
        // JSON 을 풀어 이스케이프(`\u…`) 뒤의 글을 본다.
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, reply, .{ .allocate = .alloc_always });
        try collectStrings(arena, &all, v);
    }
    return all.items;
}

fn collectStrings(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => |s| {
            try out.appendSlice(arena, s);
            try out.append(arena, '\n');
        },
        .array => |a| for (a.items) |x| try collectStrings(arena, out, x),
        .object => |o| for (o.values()) |x| try collectStrings(arena, out, x),
        else => {},
    }
}

test "⑩ 플러그인 글·CLI help·MCP 안내는 「your tab」 이라 쓰지 않는다 — 사용자 탭과 에이전트가 연 탭을 이름으로 가른다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bad: usize = 0;
    for (try pluginMarkdown(arena)) |f| if (ambiguousTabWord(f.text)) |at| {
        std.debug.print("{s}:{d}: 「your tab」 — 「tabs you opened」(에이전트 탭) 또는 「the user's tabs」 로\n", .{ f.path, 1 + std.mem.count(u8, f.text[0..at], "\n") });
        bad += 1;
    };
    if (ambiguousTabWord(browser.browser_help) != null) {
        std.debug.print("maru browser --help 가 「your tab」 이라 쓴다 — 에이전트는 자기 탭으로 읽는다\n", .{});
        bad += 1;
    }
    const served = try servedMcpText(arena);
    // 공허한 통과를 막는다 — 응답에서 실제로 글을 모았는가(instructions·도구 설명이 다 들었는가).
    try std.testing.expect(std.mem.indexOf(u8, served, mcp.agent_rules) != null);
    try std.testing.expect(std.mem.indexOf(u8, served, "Print page console logs.") != null);
    if (ambiguousTabWord(served)) |at| {
        std.debug.print("maru mcp 의 응답이 「your tab」 이라 쓴다: …{s}…\n", .{served[at -| 60..@min(served.len, at + 60)]});
        bad += 1;
    }
    if (ambiguousTabWord(mcp.usage) != null) {
        std.debug.print("maru mcp --help 가 「your tab」 이라 쓴다\n", .{});
        bad += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
    // 양성 대조 — 대소문자와 단·복수, 「your own tab」 모두 걸린다.
    try std.testing.expect(ambiguousTabWord("On Your tabs") != null and ambiguousTabWord("in your tab.") != null);
    try std.testing.expect(ambiguousTabWord("work in your own tab") != null);
    try std.testing.expect(ambiguousTabWord("tabs you opened and the user's tabs") == null);
}

/// 스킬 글에서 「기다림」 의 숫자를 모은다(⑪) — 주라는 시한(「at least N minutes」·「a N-minute shell timeout」), Bash 도구의 ms(`timeout: N`),
/// 대기 최대치(「about N s」·「about N seconds」). 공백류(줄바꿈 포함)는 한 칸으로 접어서 본다 — 마크다운 줄이 「at least」 와 숫자 사이에서 끊겨도
/// 놓치지 않게(적대 리뷰 C·D: 「3-minute」 꼴 두 자리와 줄바꿈 꼴을 처음 판이 못 봤다).
const WaitMention = struct { kind: enum { allowance_minutes, timeout_ms, about_seconds }, value: u64, line: usize };

fn waitMentions(arena: std.mem.Allocator, text: []const u8) ![]const WaitMention {
    // 공백류를 한 칸으로 접은 글과, 접은 글의 바이트마다 원래 줄 번호.
    var norm: std.ArrayList(u8) = .empty;
    var line_of: std.ArrayList(usize) = .empty;
    var line: usize = 1;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            if (norm.items.len == 0 or norm.items[norm.items.len - 1] != ' ') {
                try norm.append(arena, ' ');
                try line_of.append(arena, line);
            }
            if (c == '\n') line += 1;
            continue;
        }
        try norm.append(arena, c);
        try line_of.append(arena, line);
    }
    const t = norm.items;
    var out: std.ArrayList(WaitMention) = .empty;
    const Pat = struct { head: []const u8, tails: []const []const u8, kind: @FieldType(WaitMention, "kind") };
    const pats = [_]Pat{
        .{ .head = "at least ", .tails = &.{" minute"}, .kind = .allowance_minutes },
        .{ .head = "timeout: ", .tails = &.{""}, .kind = .timeout_ms },
        .{ .head = "timeout:", .tails = &.{""}, .kind = .timeout_ms }, // 붙여 쓴 꼴(위 꼴과 겹치지 않게 아래에서 숫자로 시작할 때만)
        .{ .head = "about ", .tails = &.{ " s", " second" }, .kind = .about_seconds },
    };
    for (pats) |pat| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, t, from, pat.head)) |at| {
            from = at + pat.head.len;
            var end = from;
            while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
            if (end == from) continue; // 숫자가 아니면 기다림 숫자가 아니다(「at least one」·「timeout: 」 뒤 공백 꼴은 위 패턴이 맡는다)
            // 꼬리 하나가 맞아야 한다. 「about 150 s」 의 단위 뒤는 낱말 경계여야 한다(「about 15 sites」 를 초로 읽지 않게) — 「 s」 가 「 seconds」 의
            // 앞부분이기도 하므로 꼬리마다 경계까지 보고 처음 맞는 것을 쓴다. 「second」 는 복수 s 까지 받는다.
            const matched = for (pat.tails) |tl| {
                if (!std.mem.startsWith(u8, t[end..], tl)) continue;
                if (pat.kind != .about_seconds) break true;
                var after = end + tl.len;
                if (std.mem.eql(u8, tl, " second") and after < t.len and t[after] == 's') after += 1;
                if (after < t.len and std.ascii.isAlphabetic(t[after])) continue;
                break true;
            } else false;
            if (!matched) continue;
            try out.append(arena, .{ .kind = pat.kind, .value = try std.fmt.parseInt(u64, t[from..end], 10), .line = line_of.items[at] });
        }
    }
    // 「a 3-minute shell timeout」 — 숫자 바로 뒤 「-minute」.
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, t, from, "-minute")) |at| {
        from = at + 1;
        var start = at;
        while (start > 0 and std.ascii.isDigit(t[start - 1])) start -= 1;
        if (start == at) continue;
        if (start > 0 and std.ascii.isAlphanumeric(t[start - 1])) continue; // 「v2-minute」 같은 낱말 조각
        try out.append(arena, .{ .kind = .allowance_minutes, .value = try std.fmt.parseInt(u64, t[start..at], 10), .line = line_of.items[start] });
    }
    return out.items;
}

/// 한 글의 기다림 숫자가 `mcp` 의 상수와 맞는가 — 틀린 것마다 한 줄 보고, 그 수.
fn waitProblems(path: []const u8, mentions: []const WaitMention) usize {
    var bad: usize = 0;
    for (mentions) |m| {
        const ok = switch (m.kind) {
            .allowance_minutes => m.value == mcp.ask_wait_minutes,
            .timeout_ms => m.value == mcp.ask_wait_ms,
            .about_seconds => m.value * std.time.ms_per_s < mcp.ask_wait_ms,
        };
        if (ok) continue;
        std.debug.print("{s}:{d}: 기다림 숫자 {d}({s}) — maru mcp 의 시한은 {s}({d} ms, mcp.ask_wait_*)다\n", .{ path, m.line, m.value, @tagName(m.kind), mcp.ask_wait_text, mcp.ask_wait_ms });
        bad += 1;
    }
    return bad;
}

/// 시한을 말해야 하는 글이 그 언급을 잃었는가(공허 통과 막기) — 모자라면 true.
fn waitCoverageMissing(mentions: []const WaitMention, min_allowance: usize, min_timeout: usize) bool {
    var allowance: usize = 0;
    var timeout: usize = 0;
    for (mentions) |m| switch (m.kind) {
        .allowance_minutes => allowance += 1,
        .timeout_ms => timeout += 1,
        .about_seconds => {},
    };
    return allowance < min_allowance or timeout < min_timeout;
}

test "⑪ 스킬이 말하는 시한(「at least N minutes」·「N-minute」·`timeout: N`)은 maru mcp 와 같은 상수이고, 대기(「about N s」)는 그보다 짧다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 시한을 말해야 하는 글(묻는 호출을 다루는 곳) — 하나라도 숫자를 잃으면(문장을 다듬다 지우면) 공허하게 통과하지 않게 파일마다 본다. 그 파일이
    // 없어도(이름을 바꾸면) 조용히 빠지지 않게 찾은 수를 센다.
    const must = [_]struct { path: []const u8, allowance: usize, timeout: usize }{
        .{ .path = skill_path, .allowance = 2, .timeout = 1 },
        .{ .path = skill_dir ++ "/references/dialogs-and-uploads.md", .allowance = 1, .timeout = 0 },
        .{ .path = skill_dir ++ "/references/tabs-and-permissions.md", .allowance = 2, .timeout = 0 },
    };
    var found: [must.len]usize = @splat(0);
    var bad: usize = 0;
    var total: usize = 0;
    for (try pluginMarkdown(arena)) |f| {
        const mentions = try waitMentions(arena, f.text);
        total += mentions.len;
        bad += waitProblems(f.path, mentions);
        for (must, 0..) |want, k| if (std.mem.eql(u8, want.path, f.path)) {
            found[k] += 1;
            if (waitCoverageMissing(mentions, want.allowance, want.timeout)) {
                std.debug.print("{s}: 시한 언급이 모자란다(시한 {d} 곳·timeout: {d} 곳 이상이어야 한다)\n", .{ f.path, want.allowance, want.timeout });
                bad += 1;
            }
        };
    }
    for (must, found) |want, n| if (n != 1) {
        std.debug.print("{s}: 시한을 말해야 하는 글이 {d} 개 — 정확히 하나여야 한다(파일 이름이 바뀌었나)\n", .{ want.path, n });
        bad += 1;
    };
    std.debug.print("plugin skill: 기다림 숫자 {d} 곳, 시한 {s}\n", .{ total, mcp.ask_wait_text });
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "스캐너: 기다림 숫자 — 틀린 분·ms·긴 대기(크고 작은 쪽·경계)가 걸리고, 줄바꿈·붙여 쓴 꼴도 읽고, 숫자 아닌 낱말은 숫자가 아니다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = "waits up to about 150 s. Give it a timeout of at least " ++ mcp.ask_wait_text ++ " (Bash: `timeout: 180000`), a 3-minute\nshell timeout, about 179 seconds.";
    const g = try waitMentions(arena, good);
    try std.testing.expectEqual(@as(usize, 5), g.len);
    try std.testing.expectEqual(@as(usize, 0), waitProblems("t.md", g));
    // 보고 줄 번호는 원래 글 기준이다 — 「3-minute」 는 1 줄, 줄바꿈 뒤 「about 179 seconds」 는 둘째 줄.
    for (g) |m| if (m.value == 179) try std.testing.expectEqual(@as(usize, 2), m.line) else try std.testing.expectEqual(@as(usize, 1), m.line);
    for ([_][]const u8{
        "a timeout of at least 2 minutes", "a timeout of at least 5 minutes", "at least 2\nminutes", "a 2-minute shell timeout", "a 4-minute timeout",
        "Bash: `timeout: 120000`",         "Bash: `timeout: 300000`",         "timeout:120000",      "waits about 240 s",        "waits about 180 s",
        "about 200 seconds",
    }) |wrong| {
        const m = try waitMentions(arena, wrong);
        errdefer std.debug.print("스캐너: 「{s}」 → {d} 개\n", .{ wrong, m.len });
        try std.testing.expectEqual(@as(usize, 1), m.len);
        try std.testing.expectEqual(@as(usize, 1), waitProblems("t.md", m));
    }
    try std.testing.expectEqual(@as(usize, 0), (try waitMentions(arena, "at least one tab, about 15 sites, at least 8 tabs, v2-minute, timeout: none")).len);
    // 파일별 하한의 양성 대조 — 언급을 잃은 글은 걸리고, 다 있는 글은 안 걸린다.
    try std.testing.expect(waitCoverageMissing(try waitMentions(arena, "no numbers here"), 1, 0));
    try std.testing.expect(waitCoverageMissing(try waitMentions(arena, "at least 3 minutes"), 1, 1));
    try std.testing.expect(!waitCoverageMissing(g, 2, 1));
}

test "스캐너: 규칙 구역 — 표지가 없거나·둘이거나·거꾸로거나·코드 블록 안이거나·줄에 다른 글과 섞이거나·비면 오류, 표면 낱말은 걸린다" {
    const b = mcp.agent_rules_begin;
    const e = mcp.agent_rules_end;
    try std.testing.expectEqualStrings("- rule one\n- rule two", try findRulesRegion("# T\n" ++ b ++ "\n\n- rule one\n- rule two\n\n" ++ e ++ "\nafter\n"));
    try std.testing.expectError(error.RegionMissing, findRulesRegion("# T\n- no markers\n"));
    try std.testing.expectError(error.RegionMissing, findRulesRegion(b ++ "\n- open\n"));
    try std.testing.expectError(error.RegionDuplicated, findRulesRegion(b ++ "\nx\n" ++ b ++ "\ny\n" ++ e ++ "\n"));
    try std.testing.expectError(error.RegionDuplicated, findRulesRegion(b ++ "\nx\n" ++ e ++ "\ny\n" ++ e ++ "\n"));
    try std.testing.expectError(error.RegionOrder, findRulesRegion(e ++ "\nx\n" ++ b ++ "\n"));
    try std.testing.expectError(error.RegionInFence, findRulesRegion("```\n" ++ b ++ "\n```\nx\n" ++ e ++ "\n"));
    try std.testing.expectError(error.RegionMarkerNotAlone, findRulesRegion("see " ++ b ++ "\nx\n" ++ e ++ "\n"));
    try std.testing.expectError(error.RegionEmpty, findRulesRegion(b ++ "\n\n" ++ e ++ "\n"));
    // 부정 판정자의 양성 대조 — 금지 낱말 하나하나가 실제로 걸린다.
    try std.testing.expect(surfaceToken("- Work in a tab you opened.") == null);
    for ([_][]const u8{ "use maru browser open", "call browser_open", "pass --reload", "run `exec`", "up to 8 tabs", "in $TMPDIR", "add maru mcp" }) |bad| {
        try std.testing.expect(surfaceToken(bad) != null);
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
    // 한 명령의 help 는 예시로 되지만(D6) 모르는 명령·그 밖의 꼴·한 명령 help 의 grep 점검은 위반이다.
    try std.testing.expectEqual(@as(usize, 0), (try scanText(arena, "`maru browser open --help`\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "`maru browser nosuchcmd --help`\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "`maru browser open --url x --help`\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "```\nmaru browser open --help | grep -c '^  open '\n```\n")).problems.items.len);
    // `--out` 없는 screenshot 은 파서는 받아도 CLI 가 거절한다(M5).
    try std.testing.expectEqual(@as(usize, 1), (try scanText(arena, "```\nmaru browser screenshot --surface 12\n```\n")).problems.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try scanText(arena, "```\nmaru browser screenshot --surface 12 --out \"$TMPDIR/a.png\"\n```\n")).problems.items.len);
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
