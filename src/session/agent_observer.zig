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

    /// 화면·OSC에서 실제로 본 근거가 있는지. 없으면 **약한 신호**이며(현재는 PTY activity 폴백 하나) 근거 있는
    /// 직전 상태를 즉시 덮지 못한다. 단일 출처는 docs/agent-session.md «상태 모델과 우선순위» 신호 세기 중재.
    pub fn hasVisibleEvidence(self: Detection) bool {
        return self.visible_idle or self.visible_blocker or self.visible_running;
    }
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
    /// **일시적 오버레이 규칙 전용** 거리 게이트. 권한 확인·중단 배너처럼 스크롤되는 출력 문구는 위로 밀린 뒤에는
    /// 현재 근거가 아니므로 하단 거리로 유효 범위를 제한한다. 반대로 입력 프롬프트·실행 footer 같은 **상시 chrome**에는
    /// 걸지 않는다 — 사용자 입력이 길어지면 chrome이 스스로 밀려나 근거가 사라지기 때문이다(실측).
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
    // 실행 footer도 상시 chrome이라 거리 게이트를 걸지 않는다. 사용자 statusLine이 여러 줄이거나 입력이 여러 행이면
    // footer가 스스로 위로 밀려 근거가 사라지고, 그 화면에는 idle 근거도 없어 판정이 폴백으로 떨어진다(실측).
    // 잔상 방지는 거리가 아니라 위치 tiebreak가 맡는다 — 아래로 돌아온 프롬프트가 위쪽 옛 footer를 이긴다.
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .any = &.{ "esc to interrupt", "esc to stop" }, .visible_running = true },
};

const codex_rules = [_]Rule{
    .{ .id = "action_required_title", .state = .blocked, .priority = 1000, .region = .title, .all = &.{"action required"}, .visible_blocker = true },
    .{ .id = "confirmation_prompt", .state = .blocked, .priority = 990, .region = .screen, .any = &.{ "press enter to confirm or esc to cancel", "press enter to confirm or esc to go back", "press enter to continue", "allow command?", "enter to submit answer", "enter to submit all" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "interrupted_prompt", .state = .idle, .priority = 885, .region = .screen, .all = &.{"conversation interrupted"}, .max_lines_from_bottom = 4, .visible_idle = true },
    // Codex는 turn 실행 중에도 아래 composer를 열어 steering 입력을 받는다. 따라서 prompt가 더 아래에 있어도
    // `esc to interrupt`가 현재 tail에 함께 보이면 idle 근거가 아니다(실제 0.144.5 UI). 즉 codex에서는 "아래=최신"
    // tiebreak가 성립하지 않고 `esc to interrupt` 문구가 turn 진행의 discriminator다.
    //
    // 하단 거리 게이트는 뺐다. codex composer는 박스 테두리 없이 `› 입력` + 빈 행 + `Context …` 상태줄(상수 2행)
    // 구조라(실측 0.146.0), 입력이 4행이 되면 마커의 하단 거리가 5가 되어 **유일한 idle 근거가 사라진다.** 그러면
    // pty_activity 폴백만 남아 타이핑 에코가 running으로 단정됐다(사용자 보고 증상). 프롬프트 아래에 상태줄이 상수로
    // 붙어서 `prompt_anchor`("마커 아래가 모두 공백") 정의에도 걸리지 않으므로 region 이관 대신 `screen`을 유지한다.
    //
    // discriminator는 실측 footer 문구 그대로 **닫는 괄호까지** 쓴다: `• Working (3s • esc to interrupt)`. 괄호 없는
    // 느슨한 `esc to interrupt`로 두면 에이전트가 **산문에서 그 표현을 언급**하기만 해도(터미널을 만드는 저장소에서는
    // 흔하다) 이 규칙이 idle을 지우고 아래 working_footer가 거짓 running을 세운다. 반대 위험(provider가 문구를 바꿔
    // 근거를 잃음)은 폴백으로 degrade될 뿐이라, 거짓 running보다 근거 상실을 택했다.
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{ "›", "❯" }, .none = &.{ "allow command?", "esc to interrupt)" }, .visible_idle = true },
    // OSC 9;4(ConEmu progress)는 실측에서 두 provider 모두 emit하지 않았다 — 현재 발화하지 않는 규칙이다.
    // 표준 기반 데이터라 존치하되 근거 있는 값으로 오해하지 않도록 남긴다(docs/agent-session.md «실측 신호 기록»).
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 950, .region = .title, .leading_codepoint_ranges = &.{braille_block}, .visible_running = true },
    // live_prompt의 `none`과 **같은 문자열**을 쓴다. 한쪽만 좁으면(예: `Working` 단어를 함께 요구) provider가 문구를
    // 바꿀 때 "프롬프트도 아니고 실행도 아닌" 화면이 생겨 근거 공백이 나고, 폴백이 그 틈을 메우며 오판한다. 같은
    // discriminator를 공유하면 두 규칙이 구성상 상호배타가 되어 공백이 없다. 거리 게이트를 뺀 이유는 실측 배치에서
    // footer가 live composer **위**에 와서(에코 → footer → steering composer → 상태줄) 하단 거리가 6이 되고,
    // 그러면 **실제 작업 중에도** running 근거가 사라지기 때문이다(반대 방향 결함).
    //
    // claude와 달리 codex는 문구를 좁게(닫는 괄호 포함) 잡는다. claude는 프롬프트가 항상 footer보다 아래라 위치
    // tiebreak가 산문 오탐을 막아 주지만, codex는 그 전제가 반대여서 문구 자체가 유일한 방어선이다.
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .any = &.{"esc to interrupt)"}, .visible_running = true },
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

/// 상태를 세우는 규칙은 반드시 `visible_*` 근거 플래그를 하나 이상 든다. Stabilizer의 신호 세기 중재가
/// "근거 없는 상태 = 약한 신호"로 판정하므로, 플래그를 빠뜨린 규칙은 조용히 약한 신호로 강등돼 근거 있는 직전
/// 상태를 못 이긴다. 그런 데이터 실수를 런타임이 아니라 **빌드에서** 잡아, 약한 신호 생산자를 PTY activity 폴백
/// 하나로 못박는다. `skip_state_update`는 상태를 세우지 않으므로 반대로 근거 플래그가 없어야 한다.
fn validateRuleEvidence(comptime rule: Rule) void {
    const flagged = rule.visible_idle or rule.visible_blocker or rule.visible_running;
    if (rule.skip_state_update) {
        if (rule.state != .unknown or flagged)
            @compileError("agent_observer rule '" ++ rule.id ++ "': skip 규칙은 state=unknown이고 visible_* 플래그가 없어야 합니다");
        return;
    }
    if (rule.state != .unknown and !flagged)
        @compileError("agent_observer rule '" ++ rule.id ++ "': 상태를 세우는 규칙은 visible_* 근거 플래그가 있어야 합니다");
}

comptime {
    for (claude_rules) |rule| {
        if (rule.gate) |g| validateGate(g, rule.id);
        validateRuleEvidence(rule);
    }
    for (codex_rules) |rule| {
        if (rule.gate) |g| validateGate(g, rule.id);
        validateRuleEvidence(rule);
    }
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
/// 현재 프롬프트가 아니다. "현재"의 구조적 정의는 두 갈래다.
///
/// - **박스 본문 갈래**: 프롬프트가 박스 상단 테두리 **바로 아래 첫 줄**이고 아래에도 닫는 수평선이 있으면, 그 사이는
///   사용자가 입력 중인 여러 행이다. 내용이 있어도 잔상 근거가 아니다 — 실측(claude)에서 입력 2행부터 이 검사가
///   프롬프트를 지워 idle 근거를 잃었다. "바로 아래 첫 줄"을 요구하는 이유는, 그렇지 않으면 위쪽 잔상 프롬프트와
///   아래 어딘가의 수평선(에이전트 출력에 흔한 구분선)만으로 잔상이 현재 프롬프트로 승격되기 때문이다.
/// - **공백 갈래**: 그 밖에는 프롬프트 아래가 모두 공백일 것. 닫는 테두리가 없는 선택지 목록(`❯ 1. Yes` 아래에 다른
///   항목이 이어짐)과 출력이 이어지는 잔상 프롬프트가 여기서 걸러진다.
///
/// 어느 갈래든 하단 거리(행 수)는 보지 않으므로 상태줄이 몇 줄이든, 입력이 몇 행이든 영향받지 않는다.
fn lastPromptLineIndex(lines: *const LineScan) ?usize {
    var i: usize = lines.count;
    while (i > 0) {
        i -= 1;
        if (!isPromptLine(lineText(lines, i))) continue;
        if (firstRuleBelow(lines, i) != null) {
            if (nearestRuleAbove(lines, i)) |above| if (above + 1 == i) return i;
        }
        var j = i + 1;
        while (j < lines.count) : (j += 1) {
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
    /// 현재 상태가 화면·OSC 근거(`visible_*`)로 세워졌는지. 근거 없는 약한 신호(현재는 PTY activity 폴백 하나)가
    /// 근거 있는 상태를 즉시 덮지 못하게 하는 판단 재료다. 이게 없으면 타이핑 에코 같은 output이 근거 있는 idle을
    /// 곧바로 running으로 바꿔, 규칙 데이터를 고쳐도 같은 증상이 다른 화면에서 재발한다.
    evidence_backed: bool = false,

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
            // 신호 세기 중재: 화면·OSC 근거가 없는 상태(약한 신호)는 근거 있는 직전 상태를 즉시 덮지 못한다.
            // 근거의 grace가 만료될 때까지 보류하고, 그 안에 같은 근거가 다시 오면 약한 신호는 버려진다.
            // 무기한 보류는 하지 않는다 — grace가 지나면 약한 신호가 이제 가장 최신 근거이므로 반영한다.
            if (!detection.hasVisibleEvidence() and self.evidence_backed and
                self.current != .unknown and self.current != detection.state)
            {
                self.evidence_missing = true;
                if (!self.graceExpired(now_ms)) return self.current;
            }
            self.current = detection.state;
            self.evidence_backed = detection.hasVisibleEvidence();
            self.last_evidence_ms = now_ms +| 1;
            self.evidence_missing = false;
            return self.current;
        }
        self.evidence_missing = true;
        if (self.current == .unknown) return .unknown;
        if (self.graceExpired(now_ms)) {
            self.current = .unknown;
            self.evidence_backed = false;
        }
        return self.current;
    }

    /// 직전 근거가 grace를 넘겼는지. `last_evidence_ms`는 "아직 근거 없음"을 0으로 구분하려고 +1 저장한다.
    fn graceExpired(self: Stabilizer, now_ms: u64) bool {
        if (self.last_evidence_ms == 0) return true;
        return now_ms -| (self.last_evidence_ms -| 1) >= evidence_grace_ms;
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
    // codex footer는 실측 문구(닫는 괄호 포함)로 적는다 — 산문 오탐을 막으려고 규칙이 괄호까지 요구한다.
    try std.testing.expectEqual(State.running, detect(.codex, .{ .screen = "■ Conversation interrupted\n› previous prompt\n• Working (2s • Esc to interrupt)" }).state);
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

// ── 실 화면 캡처 기반 fixture (codex 0.146.0, tmux 80×24) ────────────────────
// 사용자 입력이 여러 행이 되면 상시 chrome(composer·실행 footer)이 스스로 위로 밀린다. 캡처로 확인한 배치:
// idle은 `› 입력` + 빈 행 + `Context …` 상태줄(상수 2행), 실행 중은 `› 에코` → `• Working (… esc to interrupt)`
// → `› steering 입력` → `tab to queue message …` 순으로 **실행 footer가 live composer보다 위**에 온다.
// 수평선 폭만 가독성을 위해 줄였고 마커·문구·행 구성은 캡처 그대로다(docs/agent-session.md «실측 신호 기록»).

test "codex 실측: composer 입력이 여러 행이어도 타이핑이 running으로 보이지 않는다" {
    // 입력 4행이면 `›` 마커의 하단 거리가 5가 되어, 거리 게이트가 있던 시절엔 유일한 idle 근거가 사라졌다.
    // 그러면 PTY activity 폴백만 남아 **타이핑 에코가 running으로 단정**된다(사용자 보고 증상).
    const screen =
        "  Tip: Try the Desktop app. Run 'codex app' or visit\n" ++
        "  https://chatgpt.com/codex?app-landing-page=true\n" ++
        "\n" ++
        "\n" ++
        "› please refactor the observer module so that the distance guard no longer\n" ++
        "  decides whether the composer is current, and add fixtures and also please\n" ++
        "  double check the stabilizer arbitration path because weak signals must not\n" ++
        "  override evidence backed states in any case\n" ++
        "\n" ++
        "  Context 0% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
    try std.testing.expect(!std.mem.eql(u8, d.rule_id, "pty_activity"));
}

test "codex 실측: 입력이 12행을 넘는 composer도 tail에 들어오면 idle이다" {
    // 실측(0.146.0): composer는 입력 행 수만큼 제한 없이 자란다(개행 18행까지 확인). 규칙 쪽은 행 수에 무관하지만,
    // platform이 넘기는 tail 행 상한이 짧으면 마커 자체가 tail 밖으로 나가 근거가 사라진다. 그 상한이 이 화면을
    // 계속 실어 주는지가 회귀 지점이라, 규칙이 이 모양에서 idle을 내는 것을 여기서 못박는다.
    const screen =
        "› line1\n  line2\n  line3\n  line4\n  line5\n  line6\n  line7\n" ++
        "  line8\n  line9\n  line10\n  line11\n  line12\n  line13\n  line14\n" ++
        "\n" ++
        "  Context 4% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = true });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "codex 실측: 실행 중 steering 배치는 output이 조용해도 running이다" {
    // footer의 하단 거리가 6이라, 거리 게이트가 있으면 **실제 작업 중에도** running 근거가 사라진다(반대 방향 결함).
    // output_active=false로 두어 폴백이 아니라 화면 근거로 running이 나오는지 못박는다.
    const screen =
        "  20\n" ++
        "\n" ++
        "› write a detailed 12 line haiku sequence about terminals, thinking carefully\n" ++
        "  about each line\n" ++
        "\n" ++
        "\n" ++
        "• Working (3s • esc to interrupt)\n" ++
        "\n" ++
        "\n" ++
        "› also please make sure the last line rhymes with the first line and keep the\n" ++
        "  whole thing under twenty words total in the end\n" ++
        "\n" ++
        "  tab to queue message                                        96% context left\n";
    const d = detect(.codex, .{ .screen = screen, .output_active = false });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

test "codex 실측: turn이 끝나 footer가 사라진 화면은 idle이다" {
    // `• Working …` 행은 turn 종료 시 화면에서 사라진다(스크롤로 남지 않는다) → `esc to interrupt` 부재가 완료 근거다.
    const screen =
        "  19\n" ++
        "\n" ++
        "  20\n" ++
        "\n" ++
        "\n" ++
        "› Implement {feature}\n" ++
        "\n" ++
        "  Context 4% used · weekly 67% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "codex: 산문에 언급된 esc to interrupt는 running 근거가 아니다" {
    // 적대적 검증에서 나온 케이스. footer 문구를 괄호 없이 느슨하게 잡으면, 에이전트가 그 표현을 설명하기만 해도
    // idle 근거가 지워지고 거짓 running이 선다. 터미널을 만드는 저장소에서는 이 산문이 실제로 나온다.
    const screen =
        "● 규칙은 화면에 `esc to interrupt` 문구가 보이는지로 판정합니다.\n" ++
        "  그 문구가 사라지면 turn이 끝난 것으로 봅니다.\n" ++
        "\n" ++
        "› \n" ++
        "\n" ++
        "  Context 7% used · weekly 61% left · gpt-5.6-sol low\n";
    const d = detect(.codex, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 입력이 여러 행이어도 입력 줄이 idle 근거다" {
    // claude 박스는 여러 행 입력을 상·하단 수평선 사이에 담는다. 그 본문은 사용자 입력이므로 프롬프트가 잔상이라는
    // 근거가 아니다. 여기서는 OSC 타이틀을 비워, ✳ 타이틀에 가려지지 않고 화면만으로 판정되는지 확인한다.
    const screen =
        "\n" ++
        "  tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf\n" ++
        "────────────────────────────────────\n" ++
        "❯ please refactor the observer module so that the distance guard no longer\n" ++
        "  decides whether the composer is current, and add fixtures grounded in real\n" ++
        "  captures\n" ++
        "────────────────────────────────────\n" ++
        "  codexprobe\n" ++
        "  Opus 5 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.idle, d.state);
    try std.testing.expect(d.visible_idle);
}

test "claude 실측: 박스 밖 선택지 목록은 여러 행이어도 입력 프롬프트가 아니다" {
    // 박스 본문 허용이 선택지 목록까지 열어 주면 안 된다. 신뢰 확인 화면은 마커 아래에 수평선이 없으므로
    // “아래가 모두 공백” 판정이 그대로 적용돼 프롬프트로 승격되지 않는다(blocker 문구를 뺀 최소 화면으로 확인).
    const screen =
        " Quick safety check: Is this a project you created or one you trust?\n" ++
        "\n" ++
        " ❯ 1. Yes, I trust this folder\n" ++
        "   2. No, exit\n";
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = screen }).state);
}

test "claude: 출력 구분선만 아래에 있는 잔상 프롬프트는 현재 프롬프트가 아니다" {
    // 적대적 검증에서 나온 케이스. 박스 본문 허용을 "아래에 수평선이 있으면"으로 두면, 에이전트 출력에 흔한 구분선
    // 하나만으로 위쪽 잔상 프롬프트가 현재 프롬프트로 승격된다. 그래서 프롬프트가 박스 상단 바로 아래 첫 줄일 것을
    // 함께 요구한다(composer는 항상 그 형태다).
    const screen =
        "❯ 예전 프롬프트\n" ++
        "● Reading files…\n" ++
        "────────────────\n" ++
        "  더 많은 출력\n";
    try std.testing.expectEqual(State.unknown, detect(.claude, .{ .screen = screen }).state);
}

test "실행 footer 규칙은 아래 상태줄이 길어도 무효화되지 않는다" {
    // 상시 chrome 규칙에는 하단 거리 게이트를 걸지 않는다. 사용자 statusLine이 4행이면 거리 게이트가 실행 근거까지
    // 지워 버린다(그 화면에는 idle 근거도 없어 결과가 unknown이 된다).
    const screen =
        "────────────────────────────────────\n" ++
        "❯ steering input row one\n" ++
        "  steering input row two\n" ++
        "────────────────────────────────────\n" ++
        "  esc to interrupt\n" ++
        "  yoonhb\n" ++
        "  ctx 3% │ 5h 8% (00:20)\n" ++
        "  Opus 5 (1M context) │ █ xhigh\n" ++
        "  ⏸ manual mode on\n";
    const d = detect(.claude, .{ .screen = screen });
    try std.testing.expectEqual(State.running, d.state);
    try std.testing.expect(d.visible_running);
}

// ── 신호 세기 중재 ──────────────────────────────────────────────────────────

test "약한 신호는 근거 있는 상태를 즉시 덮지 못하고 grace 만료 뒤에만 반영된다" {
    var s: Stabilizer = .{};
    const strong_idle: Detection = .{ .state = .idle, .rule_id = "live_prompt", .visible_idle = true };
    const weak_running: Detection = .{ .state = .running, .rule_id = "pty_activity" };
    try std.testing.expectEqual(State.idle, s.observe(strong_idle, 1_000));
    // 타이핑 에코도 output이므로 폴백은 running을 말한다. 화면 근거가 없는 그 말이 idle을 덮으면 안 된다.
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 1_100));
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 1_600));
    try std.testing.expect(s.needsExpiryProbe());
    // 같은 근거가 다시 오면 grace가 갱신되어 계속 idle이다.
    try std.testing.expectEqual(State.idle, s.observe(strong_idle, 1_650));
    try std.testing.expectEqual(State.idle, s.observe(weak_running, 2_300));
    // 근거가 grace 안에 재확인되지 않으면 그때 약한 신호가 최신 근거가 된다(무기한 보류 금지).
    try std.testing.expectEqual(State.running, s.observe(weak_running, 2_351));
    try std.testing.expect(!s.needsExpiryProbe());
}

test "근거 있는 상태가 없거나 같은 상태면 약한 신호를 그대로 반영한다" {
    var s: Stabilizer = .{};
    const weak_running: Detection = .{ .state = .running, .rule_id = "pty_activity" };
    try std.testing.expectEqual(State.running, s.observe(weak_running, 10));
    try std.testing.expectEqual(State.running, s.observe(weak_running, 110));
    // 강한 근거는 언제나 즉시 이긴다.
    try std.testing.expectEqual(State.idle, s.observe(.{ .state = .idle, .rule_id = "live_prompt", .visible_idle = true }, 120));
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
