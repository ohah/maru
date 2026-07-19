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
};

const Region = enum { screen, title, progress };

/// 빌드에 포함되는 작은 manifest 행. v1은 단순 문자열 조건만 허용해 외부 코드 실행이나 정규식 엔진이 없다.
const Rule = struct {
    id: []const u8,
    state: State,
    priority: u16,
    region: Region,
    all: []const []const u8 = &.{},
    any: []const []const u8 = &.{},
    none: []const []const u8 = &.{},
    line_prefixes: []const []const u8 = &.{},
    /// 화면 규칙은 scrollback 성격의 오래된 문구가 아니라 현재 composer/footer 가까이에서만 유효하다.
    max_lines_from_bottom: ?u8 = null,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
};

const braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const claude_rules = [_]Rule{
    .{ .id = "permission_prompt", .state = .blocked, .priority = 1000, .region = .screen, .all = &.{"do you want to proceed?"}, .any = &.{ "esc to cancel", "yes", "tab to amend" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "selection_prompt", .state = .blocked, .priority = 990, .region = .screen, .all = &.{ "enter to select", "esc to cancel" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{"❯"}, .none = &.{ "enter to select", "esc to cancel" }, .max_lines_from_bottom = 4, .visible_idle = true },
    .{ .id = "idle_title", .state = .idle, .priority = 880, .region = .title, .any = &.{"✳"}, .visible_idle = true },
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 800, .region = .title, .any = &braille_frames, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .any = &.{ "esc to interrupt", "esc to stop" }, .max_lines_from_bottom = 4, .visible_running = true },
};

const codex_rules = [_]Rule{
    .{ .id = "action_required_title", .state = .blocked, .priority = 1000, .region = .title, .all = &.{"action required"}, .visible_blocker = true },
    .{ .id = "confirmation_prompt", .state = .blocked, .priority = 990, .region = .screen, .any = &.{ "press enter to confirm or esc to cancel", "allow command?", "enter to submit answer", "enter to submit all" }, .max_lines_from_bottom = 6, .visible_blocker = true },
    .{ .id = "interrupted_prompt", .state = .idle, .priority = 885, .region = .screen, .all = &.{"conversation interrupted"}, .max_lines_from_bottom = 4, .visible_idle = true },
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{ "›", "❯" }, .none = &.{"allow command?"}, .max_lines_from_bottom = 4, .visible_idle = true },
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 895, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 800, .region = .title, .any = &braille_frames, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 890, .region = .screen, .all = &.{ "working", "esc to interrupt" }, .max_lines_from_bottom = 4, .visible_running = true },
};

pub fn detect(agent: Agent, input: Input) Detection {
    const rules: []const Rule = switch (agent) {
        .claude => &claude_rules,
        .codex => &codex_rules,
    };
    var best: ?Rule = null;
    var best_screen_position: usize = 0;
    for (rules) |rule| {
        const match_position = matchPosition(rule, input) orelse continue;
        if (best == null or ruleBetter(rule, match_position, best.?, best_screen_position)) {
            best = rule;
            best_screen_position = match_position;
        }
    }
    if (best) |rule| return .{
        .state = rule.state,
        .rule_id = rule.id,
        .visible_idle = rule.visible_idle,
        .visible_blocker = rule.visible_blocker,
        .visible_running = rule.visible_running,
    };
    if (input.output_active) return .{ .state = .running, .rule_id = "pty_activity" };
    return .{ .state = .unknown, .rule_id = "no_match" };
}

fn ruleBetter(candidate: Rule, candidate_position: usize, current: Rule, current_position: usize) bool {
    // 입력을 막는 현재 prompt는 다른 신호보다 항상 우선한다. 그 외 같은 화면의 idle/running 충돌은
    // 고정 priority가 아니라 더 아래(더 최신 chrome)에 보이는 증거가 이긴다.
    if (candidate.visible_blocker != current.visible_blocker) return candidate.visible_blocker;
    if (candidate.region == .screen and current.region == .screen and candidate_position != current_position) {
        return candidate_position > current_position;
    }
    return candidate.priority > current.priority;
}

fn matchPosition(rule: Rule, input: Input) ?usize {
    const haystack = switch (rule.region) {
        .screen => input.screen,
        .title => input.osc_title,
        .progress => input.osc_progress,
    };
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
    if (rule.all.len == 0 and rule.any.len == 0 and rule.line_prefixes.len == 0) return null;
    if (rule.max_lines_from_bottom) |max_lines| {
        var lines_after: usize = 0;
        for (haystack[latest..]) |byte| if (byte == '\n') {
            lines_after += 1;
        };
        if (lines_after >= max_lines) return null;
    }
    return latest;
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

test "current prompt below a stale running footer becomes idle" {
    try std.testing.expectEqual(State.idle, detect(.claude, .{ .screen = "Working… esc to interrupt\nanswer\n❯ " }).state);
    try std.testing.expectEqual(State.idle, detect(.codex, .{ .screen = "Working\nEsc to interrupt\n› " }).state);
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
