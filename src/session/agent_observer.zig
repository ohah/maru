//! 터미널이 이미 소유한 foreground/screen/OSC/activity 관측값으로 대화형 에이전트 상태를 판정한다.
//! provider 설정이나 트랜스크립트를 읽지 않는 OS-중립 순수 코어다. platform은 bounded 화면 문자열만 넘긴다.

const std = @import("std");

pub const Agent = enum { claude, codex };

pub const State = enum { unknown, running, blocked, idle };

pub const Input = struct {
    screen: []const u8 = "",
    osc_title: []const u8 = "",
    osc_progress: []const u8 = "",
    output_active: bool = false,
};

pub const Detection = struct {
    state: State,
    rule_id: []const u8,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
    /// 매치했으나 상태를 바꾸지 말라는 규칙(skip_state_update)이 이긴 경우. Stabilizer가 직전 상태를 유지한다.
    skip: bool = false,
};

/// 화면 tail을 평면 하단 N행 대신 구조 region으로 나눈다. `screen`은 기존 whole tail이고, 나머지는 프롬프트
/// 마커·수평선을 앵커로 순수 문자열 슬라이싱해 얻는다(할당·정규식 없음). title/progress는 OSC 입력에서 온다.
/// 규칙 데이터의 실제 이관은 후속(규칙 이관 PR)이며, 이 파일은 엔진만 추가하고 기존 규칙/판정은 그대로 둔다.
const Region = enum { screen, title, progress, prompt_anchor, box_body, output, footer };

fn isScreenRegion(region: Region) bool {
    return switch (region) {
        .title, .progress => false,
        else => true,
    };
}

/// 재귀 불리언 게이트. leaf는 `contains`(대소문자 무시)·`line_prefix`이고 `all`(AND)/`any`(OR)/`not`(NAND)로
/// 중첩한다. comptime 데이터라 힙이 없다. 기존 평면 `all/any/none`은 이 게이트의 단층 특수형이다.
const Gate = struct {
    contains: []const []const u8 = &.{},
    line_prefix: []const []const u8 = &.{},
    /// 앞 공백을 벗긴 첫 코드포인트가 이 범위 중 하나(OR)에 드는 라인이 있는지.
    leading_codepoint_ranges: []const CodepointRange = &.{},
    all: []const Gate = &.{},
    any: []const Gate = &.{},
    not: []const Gate = &.{},
};

/// 빌드에 포함되는 작은 manifest 행. v1은 정규식 엔진 없이 문자열 조건·구조 region만 쓴다.
const Rule = struct {
    id: []const u8,
    state: State,
    priority: u16,
    region: Region,
    all: []const []const u8 = &.{},
    any: []const []const u8 = &.{},
    none: []const []const u8 = &.{},
    line_prefixes: []const []const u8 = &.{},
    /// 앞 공백을 벗긴 첫 코드포인트가 이 범위 중 하나(OR)에 드는 라인이 있는지. 스피너처럼 프레임 집합이
    /// 버전마다 달라지는 신호를 개별 문자 열거 없이 블록 범위로 판정한다(정규식 엔진 불필요).
    leading_codepoint_ranges: []const CodepointRange = &.{},
    /// 설정되면 평면 all/any/none 대신 이 게이트로 판정한다(중첩 조건용).
    gate: ?Gate = null,
    /// 화면 규칙은 scrollback 성격의 오래된 문구가 아니라 현재 composer/footer 가까이에서만 유효하다.
    max_lines_from_bottom: ?u8 = null,
    /// 매치돼도 상태를 바꾸지 않고 직전 상태를 유지한다(전이·로딩 중간 화면 오탐 억제). state는 unknown이어야 한다.
    skip_state_update: bool = false,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
};

/// 코드포인트 범위 조건. 정규식 엔진 없이 UTF-8 첫 코드포인트를 정수 비교만으로 판정한다.
const CodepointRange = struct { lo: u21, hi: u21 };

/// 브라유 점자 블록 전체. 에이전트 작업 스피너는 이 블록의 임의 프레임을 쓰고 버전마다 프레임 집합이 달라지므로
/// (실측: claude 2.1.218 OSC 타이틀은 U+2810·U+2802를 쓰는데, 과거 열거하던 10프레임과 교집합이 0이었다)
/// 개별 프레임을 열거하지 않고 블록 범위로 판정해 프레임 변경에 견디게 한다.
const braille_block = CodepointRange{ .lo = 0x2800, .hi = 0x28FF };

const claude_rules = [_]Rule{
    .{ .id = "permission_prompt", .state = .blocked, .priority = 1000, .region = .screen, .all = &.{"do you want to proceed?"}, .any = &.{ "esc to cancel", "yes", "tab to amend" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "selection_prompt", .state = .blocked, .priority = 990, .region = .screen, .all = &.{ "enter to select", "esc to cancel" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    // 폴더 신뢰 확인 등 확정형 선택 화면(실측: `❯ 1. Yes…` + `Enter to confirm · Esc to cancel`).
    .{ .id = "confirm_prompt", .state = .blocked, .priority = 985, .region = .screen, .all = &.{ "enter to confirm", "esc to cancel" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    // 입력 줄은 하단 거리가 아니라 구조로 집는다. 사용자 statusLine 커스텀이 상태줄을 여러 줄로 만들면 거리
    // 가드가 현재 프롬프트를 잔상으로 오인하므로(실측), prompt_anchor가 프롬프트 라인 자체를 앵커로 쓴다.
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .prompt_anchor, .line_prefixes = &.{"❯"}, .visible_idle = true },
    .{ .id = "idle_title", .state = .idle, .priority = 880, .region = .title, .any = &.{"✳"}, .visible_idle = true },
    // OSC 9;4(ConEmu progress)는 실측에서 두 provider 모두 emit하지 않았다 — 현재 발화하지 않는 규칙이다.
    // 표준 기반 데이터라 존치하되 근거 있는 값으로 오해하지 않도록 남긴다(docs/agent-session.md «실측 신호 기록»).
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    // 작업 중에도 composer가 열려 있어 live_prompt와 동시에 매치되므로 idle보다 우선한다(실측).
    .{ .id = "working_title", .state = .running, .priority = 950, .region = .title, .leading_codepoint_ranges = &.{braille_block}, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .any = &.{ "esc to interrupt", "esc to stop" }, .max_lines_from_bottom = 4, .visible_running = true },
};

const codex_rules = [_]Rule{
    .{ .id = "action_required_title", .state = .blocked, .priority = 1000, .region = .title, .all = &.{"action required"}, .visible_blocker = true },
    .{ .id = "confirmation_prompt", .state = .blocked, .priority = 990, .region = .screen, .any = &.{ "press enter to confirm or esc to cancel", "press enter to confirm or esc to go back", "press enter to continue", "allow command?", "enter to submit answer", "enter to submit all" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "interrupted_prompt", .state = .idle, .priority = 885, .region = .screen, .all = &.{"conversation interrupted"}, .max_lines_from_bottom = 4, .visible_idle = true },
    // Codex는 turn 실행 중에도 아래 composer를 열어 steering 입력을 받는다. 따라서 prompt가 더 아래에 있어도
    // `esc to interrupt`가 현재 tail에 함께 보이면 idle 근거가 아니다(실제 0.144.5 UI).
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{ "›", "❯" }, .none = &.{ "allow command?", "esc to interrupt" }, .max_lines_from_bottom = 4, .visible_idle = true },
    // OSC 9;4(ConEmu progress)는 실측에서 두 provider 모두 emit하지 않았다 — 현재 발화하지 않는 규칙이다.
    // 표준 기반 데이터라 존치하되 근거 있는 값으로 오해하지 않도록 남긴다(docs/agent-session.md «실측 신호 기록»).
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 950, .region = .title, .leading_codepoint_ranges = &.{braille_block}, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .all = &.{ "working", "esc to interrupt" }, .max_lines_from_bottom = 4, .visible_running = true },
};

pub fn detect(agent: Agent, input: Input) Detection {
    const rules: []const Rule = switch (agent) {
        .claude => &claude_rules,
        .codex => &codex_rules,
    };
    return detectWithRules(rules, input);
}

/// 규칙 집합을 주입해 판정한다. 프로덕션 detect()는 provider별 하드코딩 규칙을 넘기고, 테스트는 합성 규칙으로
/// region/게이트/skip 엔진을 격리 검증한다.
fn detectWithRules(rules: []const Rule, input: Input) Detection {
    const lines = scanLines(input.screen);
    var best: ?Rule = null;
    var best_position: usize = 0;
    for (rules) |rule| {
        const match_position = matchPosition(rule, input, &lines) orelse continue;
        if (best == null or ruleBetter(rule, match_position, best.?, best_position)) {
            best = rule;
            best_position = match_position;
        }
    }
    if (best) |rule| return .{
        .state = rule.state,
        .rule_id = rule.id,
        .visible_idle = rule.visible_idle,
        .visible_blocker = rule.visible_blocker,
        .visible_running = rule.visible_running,
        .skip = rule.skip_state_update,
    };
    if (input.output_active) return .{ .state = .running, .rule_id = "pty_activity" };
    return .{ .state = .unknown, .rule_id = "no_match" };
}

fn ruleBetter(candidate: Rule, candidate_position: usize, current: Rule, current_position: usize) bool {
    // 입력을 막는 현재 prompt는 다른 신호보다 항상 우선한다. 그 외 같은 화면의 idle/running 충돌은
    // 고정 priority가 아니라 더 아래(더 최신 chrome)에 보이는 증거가 이긴다. 위치는 full-screen offset 기준이라
    // 구조 region(footer/box_body 등) 규칙과 whole tail 규칙을 함께 비교할 수 있다.
    if (candidate.visible_blocker != current.visible_blocker) return candidate.visible_blocker;
    if (isScreenRegion(candidate.region) and isScreenRegion(current.region) and candidate_position != current_position) {
        return candidate_position > current_position;
    }
    return candidate.priority > current.priority;
}

fn matchPosition(rule: Rule, input: Input, lines: *const LineScan) ?usize {
    var haystack: []const u8 = "";
    var base: usize = 0;
    switch (rule.region) {
        .title => haystack = input.osc_title,
        .progress => haystack = input.osc_progress,
        else => {
            const slice = regionSliceScanned(lines, rule.region);
            haystack = slice.text;
            base = slice.offset;
        },
    }
    if (rule.gate) |g| {
        // 평면 조건과 같은 의미의 위치(근거가 실제로 보이는 자리)를 쓴다. region 끝을 쓰면 게이트 규칙이
        // 위치 tiebreak에서 항상 이겨 "더 아래가 최신"이라는 의미가 깨진다.
        return base + (gateMatchPosition(g, haystack) orelse return null);
    }
    var latest: usize = 0;
    for (rule.all) |needle| {
        const pos = lastIndexOfIgnoreCase(haystack, needle) orelse return null;
        latest = @max(latest, pos);
    }
    if (rule.any.len > 0) {
        var found: ?usize = null;
        for (rule.any) |needle| if (lastIndexOfIgnoreCase(haystack, needle)) |pos| {
            found = @max(found orelse 0, pos);
        };
        latest = @max(latest, found orelse return null);
    }
    for (rule.none) |needle| if (containsIgnoreCase(haystack, needle)) return null;
    if (rule.line_prefixes.len > 0) latest = @max(latest, lastLinePrefixPosition(haystack, rule.line_prefixes) orelse return null);
    if (rule.leading_codepoint_ranges.len > 0) latest = @max(latest, lastLeadingCodepointPosition(haystack, rule.leading_codepoint_ranges) orelse return null);
    if (rule.all.len == 0 and rule.any.len == 0 and rule.line_prefixes.len == 0 and rule.leading_codepoint_ranges.len == 0) return null;
    if (rule.max_lines_from_bottom) |max_lines| {
        var lines_after: usize = 0;
        for (haystack[latest..]) |byte| if (byte == '\n') {
            lines_after += 1;
        };
        if (lines_after >= max_lines) return null;
    }
    return base + latest;
}

/// 게이트가 매치하면 **근거의 위치**(region 안 byte offset)를 돌려준다. 여러 근거가 맞으면 가장 아래(가장 최신
/// chrome) 위치를 쓴다 — 평면 조건의 위치 의미와 같게 맞춰, 게이트 규칙도 같은 tiebreak 규칙을 따르게 한다.
/// 양성 근거가 하나도 없는 게이트는 매치로 치지 않는다(빌드 검증 `validateGate`가 1차 방어, 이건 2차).
fn gateMatchPosition(gate: Gate, text: []const u8) ?usize {
    var latest: usize = 0;
    var positive = false;
    for (gate.contains) |needle| {
        latest = @max(latest, lastIndexOfIgnoreCase(text, needle) orelse return null);
        positive = true;
    }
    for (gate.line_prefix) |prefix| {
        const single = [_][]const u8{prefix};
        latest = @max(latest, lastLinePrefixPosition(text, &single) orelse return null);
        positive = true;
    }
    if (gate.leading_codepoint_ranges.len > 0) {
        latest = @max(latest, lastLeadingCodepointPosition(text, gate.leading_codepoint_ranges) orelse return null);
        positive = true;
    }
    for (gate.all) |sub| {
        latest = @max(latest, gateMatchPosition(sub, text) orelse return null);
        positive = true;
    }
    if (gate.any.len > 0) {
        var best: ?usize = null;
        for (gate.any) |sub| if (gateMatchPosition(sub, text)) |pos| {
            best = @max(best orelse 0, pos);
        };
        latest = @max(latest, best orelse return null);
        positive = true;
    }
    for (gate.not) |sub| if (gateMatchPosition(sub, text) != null) return null;
    if (!positive) return null;
    return latest;
}

/// 양성 매처가 없는 게이트는 모든 텍스트에 매치되어 규칙이 조용히 전역 발화한다. 데이터 실수를 런타임이 아니라
/// **빌드에서** 잡는다. `not` 안의 게이트도 같은 이유로 양성 매처가 있어야 한다(비면 항상 매치되어 규칙이 죽는다).
fn gateHasPositiveMatcher(gate: Gate) bool {
    return gate.contains.len > 0 or gate.line_prefix.len > 0 or
        gate.leading_codepoint_ranges.len > 0 or gate.all.len > 0 or gate.any.len > 0;
}

fn validateGate(comptime gate: Gate, comptime rule_id: []const u8) void {
    if (!gateHasPositiveMatcher(gate)) @compileError("agent_observer rule '" ++ rule_id ++ "': 게이트에 양성 매처가 없습니다");
    for (gate.all) |sub| validateGate(sub, rule_id);
    for (gate.any) |sub| validateGate(sub, rule_id);
    for (gate.not) |sub| validateGate(sub, rule_id);
}

comptime {
    for (claude_rules) |rule| if (rule.gate) |g| validateGate(g, rule.id);
    for (codex_rules) |rule| if (rule.gate) |g| validateGate(g, rule.id);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    var offset: usize = 0;
    var latest: ?usize = null;
    while (offset <= haystack.len) {
        const relative = std.ascii.indexOfIgnoreCase(haystack[offset..], needle) orelse break;
        latest = offset + relative;
        offset += relative + @max(needle.len, 1);
    }
    return latest;
}

fn firstCodepoint(text: []const u8) ?u21 {
    var view = std.unicode.Utf8View.init(text) catch return null;
    var it = view.iterator();
    return it.nextCodepoint();
}

/// 앞 공백을 벗긴 첫 코드포인트가 주어진 범위 중 하나에 드는 라인 가운데 가장 아래 위치. 범위끼리는 OR이며
/// 정규식 엔진 없이 정수 비교만 한다.
fn lastLeadingCodepointPosition(text: []const u8, ranges: []const CodepointRange) ?usize {
    var position: usize = 0;
    var latest: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        const indent = line_raw.len - line.len;
        if (firstCodepoint(line)) |cp| {
            for (ranges) |range| {
                if (cp >= range.lo and cp <= range.hi) {
                    latest = position + indent;
                    break;
                }
            }
        }
        position += line_raw.len + 1;
    }
    return latest;
}

fn lastLinePrefixPosition(text: []const u8, prefixes: []const []const u8) ?usize {
    var position: usize = 0;
    var latest: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        const indent = line_raw.len - line.len;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, line, prefix)) latest = position + indent;
        }
        position += line_raw.len + 1;
    }
    return latest;
}

// ── 화면 region 슬라이싱 (순수·힙 없음) ────────────────────────────────────
// 화면 tail을 프롬프트 마커/수평선을 앵커로 구조 region으로 나눈다. 앵커 순서는 프롬프트 마커 우선 →
// 수평선 → whole tail 폴백이라, 박스를 그리지 않는 화면(스트리밍·평문 프롬프트)에서도 안전 바닥이 있다.

const ScreenSlice = struct { text: []const u8, offset: usize };

const max_scan_lines = 256;
const LineScan = struct {
    text: []const u8,
    starts: [max_scan_lines]usize = undefined,
    ends: [max_scan_lines]usize = undefined, // 개행 제외한 라인 끝
    count: usize = 0,
};

fn scanLines(text: []const u8) LineScan {
    var lines = LineScan{ .text = text };
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (lines.count >= max_scan_lines) break;
        lines.starts[lines.count] = offset;
        lines.ends[lines.count] = offset + line.len;
        lines.count += 1;
        offset += line.len + 1;
    }
    return lines;
}

const rule_codepoints = [_]u21{ 0x2500, 0x2501, 0x2550 }; // ─ ━ ═
const border_corner_codepoints = [_]u21{
    0x256D, 0x256E, 0x256F, 0x2570, // ╭ ╮ ╯ ╰
    0x250C, 0x2510, 0x2514, 0x2518, // ┌ ┐ └ ┘
    0x2554, 0x2557, 0x255A, 0x255D, // ╔ ╗ ╚ ╝
    0x251C, 0x2524, 0x252C, 0x2534, 0x253C, // ├ ┤ ┬ ┴ ┼
};

fn codepointIn(cp: u21, set: []const u21) bool {
    for (set) |c| if (c == cp) return true;
    return false;
}

/// 입력 박스 테두리/구분선 라인인지. 코너·정션을 허용해 둥근·이중 테두리도 인정하고, rule 문자만이거나
/// rule 문자가 3개 이상이면 수평선으로 본다.
fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    var view = std.unicode.Utf8View.init(trimmed) catch return false;
    var it = view.iterator();
    var rule_count: usize = 0;
    var other_count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (codepointIn(cp, &rule_codepoints)) {
            rule_count += 1;
        } else if (codepointIn(cp, &border_corner_codepoints)) {
            // 코너/정션은 테두리 구성요소이므로 other로 세지 않는다.
        } else other_count += 1;
    }
    if (rule_count == 0) return false;
    return other_count == 0 or rule_count >= 3;
}

/// 라인에서 앞의 박스 세로선 `│`와 공백을 벗긴 내용.
fn promptContent(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, t, "│")) t = std.mem.trimStart(u8, t["│".len..], " \t\r");
    return t;
}

fn isPromptLine(line: []const u8) bool {
    const content = promptContent(line);
    return std.mem.startsWith(u8, content, "❯") or std.mem.startsWith(u8, content, "›");
}

fn lineText(lines: *const LineScan, idx: usize) []const u8 {
    return lines.text[lines.starts[idx]..lines.ends[idx]];
}

/// 현재 입력 프롬프트 라인. 마지막 프롬프트라도 그 아래에 실제 출력이 남아 있으면 scrollback 잔상이므로
/// 현재 프롬프트가 아니다. "현재"의 구조적 정의: 프롬프트와 그 아래 첫 수평선 사이가 비어 있거나(박스 안 입력줄),
/// 수평선이 없으면 프롬프트 아래가 모두 공백일 것. 하단 거리(행 수) 대신 구조로 판정하므로 상태줄이 몇 줄이든
/// 영향받지 않고, 선택지 목록(`❯ 1. Yes` 아래 다른 항목이 이어짐)도 현재 입력 프롬프트로 오인하지 않는다.
fn lastPromptLineIndex(lines: *const LineScan) ?usize {
    var i: usize = lines.count;
    while (i > 0) {
        i -= 1;
        if (!isPromptLine(lineText(lines, i))) continue;
        const limit = firstRuleBelow(lines, i) orelse lines.count;
        var j = i + 1;
        while (j < limit) : (j += 1) {
            if (std.mem.trim(u8, lineText(lines, j), " \t\r").len != 0) return null;
        }
        return i;
    }
    return null;
}

fn nearestRuleAbove(lines: *const LineScan, idx: usize) ?usize {
    var i: usize = idx;
    while (i > 0) {
        i -= 1;
        if (isHorizontalRule(lineText(lines, i))) return i;
    }
    return null;
}

fn firstRuleBelow(lines: *const LineScan, idx: usize) ?usize {
    var i: usize = idx + 1;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) return i;
    }
    return null;
}

fn lastRuleBelow(lines: *const LineScan, idx: usize) ?usize {
    var found: ?usize = null;
    var i: usize = idx + 1;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) found = i;
    }
    return found;
}

fn lastRuleOverall(lines: *const LineScan) ?usize {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < lines.count) : (i += 1) {
        if (isHorizontalRule(lineText(lines, i))) found = i;
    }
    return found;
}

/// idx 라인 다음 라인의 시작 offset(마지막이면 text 끝).
fn lineStartAfter(lines: *const LineScan, idx: usize) usize {
    return if (idx + 1 < lines.count) lines.starts[idx + 1] else lines.text.len;
}

/// 미리 스캔한 라인 정보로 region 슬라이스를 얻는다(detect 당 1회 스캔 공유). 대상 텍스트는 `lines.text`가
/// 단일 출처다 — 별도 화면 인자를 받으면 스캔과 어긋난 버퍼가 넘어올 수 있어 받지 않는다.
fn regionSliceScanned(lines: *const LineScan, region: Region) ScreenSlice {
    const screen = lines.text;
    switch (region) {
        .screen => return .{ .text = screen, .offset = 0 },
        .title, .progress => return .{ .text = "", .offset = 0 },
        .prompt_anchor => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = "", .offset = 0 };
            return .{ .text = lineText(lines, p), .offset = lines.starts[p] };
        },
        .box_body => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = "", .offset = 0 };
            const above = nearestRuleAbove(lines, p);
            const below = firstRuleBelow(lines, p);
            const start = if (above) |a| lines.starts[a + 1] else lines.starts[p];
            const end = if (below) |b| lines.starts[b] else lines.ends[p];
            const s = @min(start, screen.len);
            const e = @min(@max(end, s), screen.len);
            return .{ .text = screen[s..e], .offset = s };
        },
        .output => {
            const p = lastPromptLineIndex(lines) orelse return .{ .text = screen, .offset = 0 };
            const above = nearestRuleAbove(lines, p);
            const end = if (above) |a| lines.starts[a] else lines.starts[p];
            const e = @min(end, screen.len);
            return .{ .text = screen[0..e], .offset = 0 };
        },
        .footer => {
            if (lastPromptLineIndex(lines)) |p| {
                const below = lastRuleBelow(lines, p);
                const start = if (below) |b| lineStartAfter(lines, b) else lineStartAfter(lines, p);
                const s = @min(start, screen.len);
                return .{ .text = screen[s..], .offset = s };
            }
            const last = lastRuleOverall(lines);
            const start = if (last) |b| lineStartAfter(lines, b) else 0;
            const s = @min(start, screen.len);
            return .{ .text = screen[s..], .offset = s };
        },
    }
}

/// 단발 편의 래퍼(테스트·외부 호출용). 프로덕션 detect 경로는 공유 스캔을 쓰는 regionSliceScanned를 쓴다.
fn regionSlice(screen: []const u8, region: Region) ScreenSlice {
    const lines = scanLines(screen);
    return regionSliceScanned(&lines, region);
}

pub const Stabilizer = struct {
    current: State = .unknown,
    last_evidence_ms: u64 = 0,
    evidence_missing: bool = false,

    pub const evidence_grace_ms: u64 = 700;

    pub fn reset(self: *Stabilizer) void {
        self.* = .{};
    }

    /// idle fast-path가 화면 재스캔을 생략해도 되는지 알려 준다. 한 번 no-match를 봤다면 grace 만료를
    /// 실제로 관측할 때까지 polling을 계속해야 stale idle이 영구 고착되지 않는다.
    pub fn needsExpiryProbe(self: Stabilizer) bool {
        return self.evidence_missing and self.current != .unknown;
    }

    /// 명시 신호는 즉시 반영한다. 일시적인 화면 재그리기에는 직전 상태를 짧게 유지하지만, 근거가 계속
    /// 사라진 상태를 running/blocked/idle로 무한 보존하지 않고 grace 뒤 unknown으로 실패시킨다.
    pub fn observe(self: *Stabilizer, detection: Detection, now_ms: u64) State {
        // skip 규칙: 매치했으나 상태 보류. 직전 상태가 있으면 근거만 갱신하고 상태는 유지한다.
        if (detection.skip) {
            if (self.current != .unknown) {
                self.last_evidence_ms = now_ms +| 1;
                self.evidence_missing = false;
            }
            return self.current;
        }
        if (detection.state != .unknown) {
            self.current = detection.state;
            self.last_evidence_ms = now_ms +| 1;
            self.evidence_missing = false;
            return self.current;
        }
        self.evidence_missing = true;
        if (self.current == .unknown) return .unknown;
        const last_ms = self.last_evidence_ms -| 1;
        if (self.last_evidence_ms == 0 or now_ms -| last_ms >= evidence_grace_ms) self.current = .unknown;
        return self.current;
    }
};

test "claude manifest prioritizes a visible blocker over working text" {
    const d = detect(.claude, .{ .screen = "Working · esc to interrupt\nDo you want to proceed?\n❯ 1. Yes\nEsc to cancel" });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}

test "claude prompt and OSC progress report visible idle" {
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .screen = "────────────────\n❯ " }).state);
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .osc_progress = "4;0" }).state);
}

test "codex working title and action-required title are distinct" {
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_title = "⠋ Working" }).state);
    try std.testing.expectEqual(State.blocked, detect(.codex, .{ .osc_title = "Action Required" }).state);
}

test "codex startup selection screens are blocked until the user confirms" {
    const update = detect(.codex, .{ .screen = "1. Update now\n2. Skip\nPress enter to continue" });
    try std.testing.expectEqual(State.blocked, update.state);
    try std.testing.expect(update.visible_blocker);

    const hooks = detect(.codex, .{ .screen = "Hooks need review\n3. Continue without trusting\nPress enter to confirm or esc to go back" });
    try std.testing.expectEqual(State.blocked, hooks.state);
    try std.testing.expect(hooks.visible_blocker);
}

test "codex interruption screen becomes idle even after output activity" {
    const d = detect(.codex, .{ .screen = "■ Conversation interrupted\n› ", .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "current running footer beats a prior prompt or interruption in the screen tail" {
    try std.testing.expectEqual(State.running, detect(.claude, .{ .screen = "❯ previous prompt\nWorking… esc to interrupt" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .screen = "■ Conversation interrupted\n› previous prompt\nWorking\nEsc to interrupt" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .screen = "■ Conversation interrupted", .osc_progress = "4;2", .osc_title = "✳" }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_progress = "4;2", .osc_title = "✳" }).state);
}

test "codex steering composer below a working footer remains running" {
    const d = detect(.codex, .{ .screen = "Working (8s · esc to interrupt)\n› Add a follow-up" });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "current prompt below a stale running footer becomes idle" {
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .screen = "Working… esc to interrupt\nanswer\n❯ " }).state);
    // Codex는 현재 `esc to interrupt`가 있으면 아래 prompt도 steering composer라 running이다. footer가 사라지고 과거
    // Working 텍스트만 남은 뒤 새 prompt가 보일 때 idle로 복귀한다.
    try std.testing.expectEqual(State.idle, detect(.codex, .{ .screen = "Working\nanswer\n› " }).state);
}

test "prompt outside the bounded bottom region is not current idle evidence" {
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = "❯ old\n1\n2\n3\n4\n5" }).state);
}

test "activity is a running fallback and silence is unknown" {
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_progress = "4;1;50" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_progress = "4;3" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .output_active = true }).state);
    try std.testing.expectEqual(State.unknown, detect(.codex, .{}).state);
}

test "stabilizer publishes evidence immediately and expires stale state to unknown" {
    var s: Stabilizer = .{ .current = .running };
    const explicit_idle: Detection = .{ .state = .idle, .rule_id = "prompt", .visible_idle = true };
    try std.testing.expectEqual(State.idle, s.observe(explicit_idle, 10));
    try std.testing.expectEqual(State.idle, s.observe(.{ .state = .unknown, .rule_id = "no_match" }, 709));
    try std.testing.expect(s.needsExpiryProbe());
    try std.testing.expectEqual(State.unknown, s.observe(.{ .state = .unknown, .rule_id = "no_match" }, 710));
    try std.testing.expect(!s.needsExpiryProbe());
}

// ── region·게이트 엔진 (규칙 이관 전 격리 검증) ──────────────────────────────

test "isHorizontalRule는 둥근·이중·순수 테두리를 인정하고 일반 텍스트는 거부한다" {
    try std.testing.expect(isHorizontalRule("╭───╮"));
    try std.testing.expect(isHorizontalRule("╔═══╗"));
    try std.testing.expect(isHorizontalRule("────"));
    try std.testing.expect(isHorizontalRule("━━━━"));
    try std.testing.expect(!isHorizontalRule("normal text line"));
    try std.testing.expect(!isHorizontalRule(""));
}

test "region output/footer/box_body가 다중 수평선 박스에서 prompt를 정확히 가른다" {
    const screen =
        "● output line\n" ++
        "╭─────╮\n" ++
        "│ ❯ hi │\n" ++
        "╰─────╯\n" ++
        "───────\n" ++
        "  Esc to interrupt\n";
    try std.testing.expect(containsIgnoreCase(regionSlice(screen, .footer).text, "esc to interrupt"));
    const output = regionSlice(screen, .output).text;
    try std.testing.expect(containsIgnoreCase(output, "output line"));
    try std.testing.expect(!containsIgnoreCase(output, "❯ hi"));
    const body = regionSlice(screen, .box_body).text;
    try std.testing.expect(containsIgnoreCase(body, "❯ hi"));
    try std.testing.expect(!containsIgnoreCase(body, "esc to interrupt"));
    try std.testing.expect(containsIgnoreCase(regionSlice(screen, .prompt_anchor).text, "❯ hi"));
}

test "region은 박스 없는 화면에서 마커/whole tail로 폴백한다" {
    const streaming = "● Reading files…\n  Searching\nWorking… esc to interrupt\n";
    try std.testing.expect(regionSlice(streaming, .prompt_anchor).text.len == 0);
    try std.testing.expect(containsIgnoreCase(regionSlice(streaming, .footer).text, "esc to interrupt"));

    const plain = "● Done.\n❯ \n";
    try std.testing.expect(!containsIgnoreCase(regionSlice(plain, .footer).text, "esc"));
    const out = regionSlice(plain, .output).text;
    try std.testing.expect(containsIgnoreCase(out, "Done"));
    try std.testing.expect(!containsIgnoreCase(out, "❯"));
}

test "footer region 규칙은 과거 output의 esc는 무시하고 현재 footer만 running으로 본다" {
    const rules = [_]Rule{
        .{ .id = "footer_running", .state = .running, .priority = 100, .region = .footer, .any = &.{"esc to interrupt"}, .visible_running = true },
    };
    // 과거 esc가 박스 위 output에만 있으면 footer는 비어 매치하지 않는다.
    const stale = "Working esc to interrupt\nanswer\n╭───╮\n│ ❯ │\n╰───╯\n";
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = stale }).state);
    // 박스 아래 footer에 esc가 있으면 running.
    const running = "● out\n╭───╮\n│ ❯ │\n╰───╯\n  esc to interrupt\n";
    try std.testing.expectEqual(State.running, detectWithRules(&rules, .{ .screen = running }).state);
}

test "중첩 all/any/not 게이트가 detectWithRules에서 평가된다" {
    const rules = [_]Rule{
        .{ .id = "gated_blocker", .state = .blocked, .priority = 100, .region = .screen, .visible_blocker = true, .gate = .{
            .all = &.{.{ .contains = &.{"do you want to proceed?"} }},
            .any = &.{ .{ .contains = &.{"esc to cancel"} }, .{ .contains = &.{"tab to amend"} } },
            .not = &.{.{ .contains = &.{"conversation interrupted"} }},
        } },
    };
    try std.testing.expectEqual(State.blocked, detectWithRules(&rules, .{ .screen = "Do you want to proceed?\n❯ 1. Yes\nEsc to cancel" }).state);
    // any 미충족
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = "Do you want to proceed?\n(no options)" }).state);
    // not 위배
    try std.testing.expectEqual(State.unknown, detectWithRules(&rules, .{ .screen = "Do you want to proceed? esc to cancel\nConversation interrupted" }).state);
}

test "skip_state_update 규칙은 매치해도 상태를 바꾸지 않고 직전 상태를 유지한다" {
    const rules = [_]Rule{
        .{ .id = "loading", .state = .unknown, .priority = 100, .region = .screen, .all = &.{"reticulating splines"}, .skip_state_update = true },
    };
    const d = detectWithRules(&rules, .{ .screen = "reticulating splines" });
    try std.testing.expect(d.skip);
    var s: Stabilizer = .{ .current = .running };
    try std.testing.expectEqual(State.running, s.observe(d, 10)); // 보류: running 유지
    try std.testing.expectEqual(State.running, s.observe(d, 20));
}

// ── 게이트 경화 회귀 ────────────────────────────────────────────────────────

test "양성 매처 없는 게이트는 매치로 치지 않는다" {
    // 빈 게이트가 참이면 규칙이 모든 화면에서 조용히 발화한다. 빌드 검증(validateGate)이 1차 방어이고,
    // 런타임에서도 매치로 치지 않는지 여기서 못박는다.
    try std.testing.expect(gateMatchPosition(.{}, "아무 화면") == null);
    try std.testing.expect(gateMatchPosition(.{}, "") == null);
    try std.testing.expect(gateMatchPosition(.{ .any = &.{.{}} }, "무엇이든") == null);
    try std.testing.expect(!gateHasPositiveMatcher(.{}));
    try std.testing.expect(gateHasPositiveMatcher(.{ .contains = &.{"x"} }));
}

test "게이트 매치 위치는 region 끝이 아니라 근거가 보이는 자리다" {
    const screen = "esc to interrupt\nanswer\nready";
    // 가장 위 줄의 근거를 잡으면 위치도 그 자리여야 한다(region 끝이면 screen.len이 되어 항상 최댓값).
    const pos = gateMatchPosition(.{ .contains = &.{"esc to interrupt"} }, screen).?;
    try std.testing.expectEqual(@as(usize, 0), pos);
    try std.testing.expect(pos < screen.len);
    // 여러 근거면 더 아래(최신) 자리를 쓴다.
    const lower = gateMatchPosition(.{ .contains = &.{ "esc to interrupt", "ready" } }, screen).?;
    try std.testing.expectEqual(std.mem.indexOf(u8, screen, "ready").?, lower);
}

test "게이트 규칙이 위치 tiebreak에서 아래쪽 화면 규칙에 지고 이긴다" {
    // 게이트 근거가 위, 평면 근거가 아래 → 아래(평면)가 이긴다.
    const rules = [_]Rule{
        .{ .id = "gated_top", .state = .running, .priority = 100, .region = .screen, .gate = .{ .contains = &.{"esc to interrupt"} }, .visible_running = true },
        .{ .id = "flat_bottom", .state = .idle, .priority = 100, .region = .screen, .any = &.{"ready now"}, .visible_idle = true },
    };
    try std.testing.expectEqual(State.idle, detectWithRules(&rules, .{ .screen = "esc to interrupt\nanswer\nready now" }).state);
    // 반대로 게이트 근거가 아래면 게이트가 이긴다.
    try std.testing.expectEqual(State.running, detectWithRules(&rules, .{ .screen = "ready now\nanswer\nesc to interrupt" }).state);
}

// ── 실 화면 캡처 기반 fixture (claude 2.1.218, tmux 140×45) ──────────────────
// 캡처로 확인한 사실: OSC 타이틀이 주 신호(작업=브라유 스피너, 대기=✳), 입력 줄은 수평선 사이 bare `❯`,
// 그 아래 사용자 statusLine이 여러 줄, 작업 중에도 composer가 열려 있고 `esc to interrupt` 문구는 없다.

test "claude 실측: 브라유 스피너 타이틀은 프레임이 달라도 running으로 잡힌다" {
    // 실제 관측 프레임 U+2810 / U+2802 — 과거 열거하던 10프레임에는 없던 값이다.
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠐ 터미널에 대한 haiku 작성" }).state);
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠂ 터미널에 대한 haiku 작성" }).state);
    // 과거 프레임도 같은 블록이라 그대로 커버(회귀 없음).
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_title = "⠋ Working" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_title = "⠐ Working" }).state);
}

test "claude 실측: 대기 타이틀 ✳는 idle이고 스피너 범위에 걸리지 않는다" {
    const d = detect(.claude, .{ .osc_title = "✳ 터미널에 대한 haiku 작성" });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 커스텀 statusLine이 여러 줄이어도 입력 줄을 idle로 잡는다" {
    // 하단 거리 가드였다면 상태줄 4줄에 밀려 잔상으로 오인됐을 화면.
    const screen =
        "● Done. Updated 3 files.\n" ++
        "────────────────────────\n" ++
        "❯ \n" ++
        "────────────────────────\n" ++
        "  yoonhb\n" ++
        "  ctx 3% │ 5h 8% (00:20) │ 7d 49% (07/28 12:00)\n" ++
        "  Opus 4.8 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on · ← 1 agent";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 작업 중에는 composer가 열려 있어도 스피너 타이틀이 idle을 이긴다" {
    const screen =
        "✳ Flibbertigibbeting… (2s · thinking with xhigh effort)\n" ++
        "────────────────────────\n" ++
        "❯ \n" ++
        "────────────────────────\n" ++
        "  yoonhb\n" ++
        "  Opus 4.8 (1M context) │ █ xhigh";
    const d = detect(.claude, .{ .screen = screen, .osc_title = "⠂ 터미널에 대한 haiku 작성" });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "claude 실측: 폴더 신뢰 확인 화면은 blocked이고 선택지를 입력 프롬프트로 오인하지 않는다" {
    const screen =
        "Quick safety check: Is this a project you created or one you trust?\n" ++
        "❯ 1. Yes, I trust this folder\n" ++
        "  2. No, exit\n" ++
        "\n" ++
        "Enter to confirm · Esc to cancel";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.blocked, d.state);
    try std.testing.expect(d.visible_blocker);
}
