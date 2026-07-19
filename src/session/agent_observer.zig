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
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_running: bool = false,
};

const braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const claude_rules = [_]Rule{
    .{ .id = "permission_prompt", .state = .blocked, .priority = 1000, .region = .screen, .all = &.{"do you want to proceed?"}, .any = &.{ "esc to cancel", "yes", "tab to amend" }, .visible_blocker = true },
    .{ .id = "selection_prompt", .state = .blocked, .priority = 990, .region = .screen, .all = &.{ "enter to select", "esc to cancel" }, .visible_blocker = true },
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{"❯"}, .none = &.{ "enter to select", "esc to cancel" }, .visible_idle = true },
    .{ .id = "idle_title", .state = .idle, .priority = 880, .region = .title, .any = &.{"✳"}, .visible_idle = true },
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 810, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 800, .region = .title, .any = &braille_frames, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 790, .region = .screen, .any = &.{ "esc to interrupt", "esc to stop" }, .visible_running = true },
};

const codex_rules = [_]Rule{
    .{ .id = "action_required_title", .state = .blocked, .priority = 1000, .region = .title, .all = &.{"action required"}, .visible_blocker = true },
    .{ .id = "confirmation_prompt", .state = .blocked, .priority = 990, .region = .screen, .any = &.{ "press enter to confirm or esc to cancel", "allow command?", "enter to submit answer", "enter to submit all" }, .visible_blocker = true },
    .{ .id = "interrupted_prompt", .state = .idle, .priority = 920, .region = .screen, .all = &.{"conversation interrupted"}, .visible_idle = true },
    .{ .id = "live_prompt", .state = .idle, .priority = 900, .region = .screen, .line_prefixes = &.{ "›", "❯" }, .none = &.{ "esc to interrupt", "allow command?" }, .visible_idle = true },
    .{ .id = "progress_idle", .state = .idle, .priority = 870, .region = .progress, .all = &.{"4;0"}, .visible_idle = true },
    .{ .id = "progress_running", .state = .running, .priority = 810, .region = .progress, .any = &.{ "4;1", "4;2", "4;3", "4;4" }, .visible_running = true },
    .{ .id = "working_title", .state = .running, .priority = 800, .region = .title, .any = &braille_frames, .visible_running = true },
    .{ .id = "working_footer", .state = .running, .priority = 790, .region = .screen, .all = &.{ "working", "esc to interrupt" }, .visible_running = true },
};

pub fn detect(agent: Agent, input: Input) Detection {
    const rules: []const Rule = switch (agent) {
        .claude => &claude_rules,
        .codex => &codex_rules,
    };
    var best: ?Rule = null;
    for (rules) |rule| {
        if (!matches(rule, input)) continue;
        if (best == null or rule.priority > best.?.priority) best = rule;
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

fn matches(rule: Rule, input: Input) bool {
    const haystack = switch (rule.region) {
        .screen => input.screen,
        .title => input.osc_title,
        .progress => input.osc_progress,
    };
    for (rule.all) |needle| if (!containsIgnoreCase(haystack, needle)) return false;
    if (rule.any.len > 0) {
        var found = false;
        for (rule.any) |needle| if (containsIgnoreCase(haystack, needle)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    for (rule.none) |needle| if (containsIgnoreCase(haystack, needle)) return false;
    if (rule.line_prefixes.len > 0 and !hasLinePrefix(haystack, rule.line_prefixes)) return false;
    return rule.all.len > 0 or rule.any.len > 0 or rule.line_prefixes.len > 0;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn hasLinePrefix(text: []const u8, prefixes: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimStart(u8, line_raw, " \t\r");
        for (prefixes) |prefix| if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

pub const Stabilizer = struct {
    current: State = .unknown,
    pending_idle_started_ms: u64 = 0,
    pending_idle_confirmations: u8 = 0,

    pub fn reset(self: *Stabilizer) void {
        self.* = .{};
    }

    /// 명시 visible 신호는 즉시 반영한다. 화면 근거 없는 running→idle만 3회 확인하되 700ms에서 상한을 둔다.
    pub fn observe(self: *Stabilizer, detection: Detection, now_ms: u64) State {
        if (detection.state == .unknown) return self.current;
        const plain_idle = self.current == .running and detection.state == .idle and !detection.visible_idle;
        if (!plain_idle) {
            self.pending_idle_started_ms = 0;
            self.pending_idle_confirmations = 0;
            self.current = detection.state;
            return self.current;
        }
        if (self.pending_idle_started_ms == 0) {
            self.pending_idle_started_ms = now_ms +| 1;
            self.pending_idle_confirmations = 1;
            return self.current;
        }
        self.pending_idle_confirmations +|= 1;
        const started_ms = self.pending_idle_started_ms - 1;
        if (self.pending_idle_confirmations >= 3 or now_ms -| started_ms >= 700) {
            self.current = .idle;
            self.pending_idle_started_ms = 0;
            self.pending_idle_confirmations = 0;
        }
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

test "activity is a running fallback and silence is unknown" {
    try std.testing.expectEqual(State.running, detect(.claude, .{ .osc_progress = "4;1;50" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .osc_progress = "4;3" }).state);
    try std.testing.expectEqual(State.running, detect(.codex, .{ .output_active = true }).state);
    try std.testing.expectEqual(State.unknown, detect(.codex, .{}).state);
}

test "stabilizer publishes visible idle immediately and confirms plain idle" {
    var s: Stabilizer = .{ .current = .running };
    const explicit_idle: Detection = .{ .state = .idle, .rule_id = "prompt", .visible_idle = true };
    try std.testing.expectEqual(State.idle, s.observe(explicit_idle, 10));

    s = .{ .current = .running };
    const inferred_idle: Detection = .{ .state = .idle, .rule_id = "inferred" };
    try std.testing.expectEqual(State.running, s.observe(inferred_idle, 100));
    try std.testing.expectEqual(State.running, s.observe(inferred_idle, 200));
    try std.testing.expectEqual(State.idle, s.observe(inferred_idle, 300));
}
