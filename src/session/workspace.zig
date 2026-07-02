//! Workspace restore 직렬화(R1, writer). 실행 중이던 창/탭/split/터미널 레이아웃과 각 터미널의 cwd·shell을
//! 다시 열기 위한 **선언적 상태**를 `maru.workspace.v1` 텍스트로 굳힌다 — live PTY/process/grid 내용은 담지
//! 않는다(docs/workspace-restore.md). snapshot/trace와 같은 규칙: 첫 줄 bare 토큰(`schema=` 접두어 없음),
//! 이후 `<kind> <fields>` 라인, 따옴표 문자열은 `\` `"`·개행 escape. 이 파일은 모델(값 타입)과 writer만 둔다 —
//! reader(R2)·라이브 캡처(R3)·복원(R4)은 후속이 같은 모델을 소비/생산한다(snapshot.zig writer-only 선례).
//!
//! 계층: workspace → windows → tabs → (pane split 트리 + panes) → panes → surfaces(Term). 멀티 창은 windows가
//! N개(각 창 = 한 AppSession). split 트리는 preorder TreeNode 리스트로 — full binary tree라 self-delimiting
//! (split은 뒤따르는 두 subtree를 소비, leaf는 종단). 베이스: docs/workspace-restore.md 저장 모델 + 현재
//! 탭→pane→Term 풀 모델·멀티 창에 맞춰 window-aware로 확장.

const std = @import("std");
const split_tree = @import("split_tree.zig");
const writeEscaped = @import("../text_escape.zig").writeEscaped; // 따옴표 값 escape 단일 출처(trace/snapshot과 공유)

pub const header = "maru.workspace.v1";

/// 한 탭의 pane 수 sanity 상한. 손상·변조된 복원 파일이 pane_count를 부풀려도 split 트리 노드 상한
/// (2·pane_count−1)이 거대해져 깊은 재귀로 스택 오버플로가 나지 않게, parseTab이 먼저 이 값으로 가둔다.
/// 실제 레이아웃은 한 자릿수~십수 pane이라 1024는 어떤 현실 레이아웃보다 크다(손상만 거른다). 베이스: 표준이
/// 없어 sane 상한을 우리가 정함 — Ghostty는 바이너리 아카이버라 이 텍스트-깊은중첩 벡터 자체가 없다.
pub const max_panes_per_tab = 1024;

/// 한 surface가 보존하는 agent argv 토큰 수 sanity 상한 — 손상/변조 파일이 `agent-argc`를 부풀려 거대 루프를
/// 돌지 않게 parseSurface가 먼저 가둔다. 현실 에이전트 argv는 한 자릿수~수십 개라 256은 어떤 정상 호출보다 크다.
pub const max_agent_argv = 256;

/// 한 라인의 key=value 필드 수 sanity 상한 — key-addressed 리더(LineFields)는 라인을 통째 토큰화하므로, 손상/변조
/// 파일이 한 줄에 토큰을 무한정 채우면(예: agent-argc는 작은데 agent-arg를 수백만 개) 토큰화 작업·메모리가 라인
/// 길이만큼 부풀 수 있다. max_agent_argv가 argc *값*만 가두던 방어를 라인 *토큰 수*로도 유지한다. 정상 최대 라인은
/// surface(기본 키 ~9 + agent-argv ≤max_agent_argv)라, +64 여유면 어떤 정상·forward-compat 라인보다 크다(손상만 거른다).
pub const max_line_fields = max_agent_argv + 64;

pub const SplitDirection = split_tree.SplitDirection;

/// split 트리 한 노드(preorder). leaf는 pane 섹션 인덱스를 가리키고, split은 방향 + a의 비율(천분율 0..1000)을
/// 들고 뒤따르는 두 subtree(a, b)를 소비한다. ratio는 split_tree의 f32(0.05..0.95)를 *1000 반올림한 정수.
pub const TreeNode = union(enum) {
    leaf: usize,
    split: Split,

    pub const Split = struct {
        direction: SplitDirection,
        ratio_milli: u16,
    };
};

/// 한 터미널(Term)의 복원 가능 선언 상태(session.surface.RestorableSurfaceMetadata의 직렬화 부분집합 — id/
/// process_state 같은 런타임 값은 복원에 불필요하므로 안 담는다). cwd=OSC 7, title=OSC 0/2, command=spawn argv[0].
/// v1 복원이 실제로 소비하는 건 cwd·cols·rows뿐이다. title·command는 **목표 포맷의 선행 구현**으로 캡처·저장만
/// 하고 복원 spawn엔 아직 안 쓴다(기본 셸·"Maru" 제목으로 살림). 헛방어/유령 필드가 아니라 docs/workspace-restore.md에
/// 설계된 필드다: command=`shell_entry`(pane 재시작 기본 shell argv, round-trip 테스트까지 계획됨), title=pane title.
/// command는 argv[0]=셸이라 `last_observed_command` 자동 재실행 금지 정책과는 별개다. 정확한 제목·argv 복원은 후속.
pub const Surface = struct {
    // custom_name = 사용자 지정 이름(rename), title = 자동 제목(OSC 0/2). 둘은 별도 필드다 — 표시 우선순위는
    // custom_name(비면 안 씀) → title → 기본값(app.label.pick). ""=없음. 단일 출처: docs/workspace-restore.md
    // "사용자 지정 이름(custom_name)과 자동 제목".
    custom_name: []const u8 = "",
    title: []const u8 = "",
    cwd: []const u8 = "",
    command: []const u8 = "",
    cols: u16 = 0,
    rows: u16 = 0,
    // claude/codex 세션 자동 resume(opt-in allowlist 예외 — docs/workspace-restore.md "에이전트 세션 자동 resume").
    // agent_kind=""면 일반 셸 복원. agent_session=""면 폴백 resume(--continue/resume --last). agent_argv는 종료
    // 시점 보존 argv(redact 후)로, 복원 spawn이 세션지정 플래그를 갈아끼워 재구성한다.
    agent_kind: []const u8 = "",
    agent_session: []const u8 = "",
    agent_argv: []const []const u8 = &.{},
};

/// split leaf 한 칸(panel) — 가로 탭으로 여러 Term을 들 수 있다(탭→pane 모델). active-term = 보이는 Term.
pub const Pane = struct {
    active_term: usize = 0,
    // 사용자 지정 이름(rename). Pane은 자동 제목 출처가 없어 custom_name 하나뿐(""=없음). 탭바 좌측 라벨 세그먼트로 표시.
    custom_name: []const u8 = "",
    surfaces: []const Surface,
};

/// 한 워크스페이스(사이드바 탭) — pane split 트리 + 그 leaf들이 가리키는 pane 섹션들. active-pane = 포커스 panel.
pub const Tab = struct {
    active_pane: usize = 0,
    // 사용자 지정 이름(rename). 워크스페이스는 자동 제목 출처가 없어 custom_name 하나뿐(""=없음). 없으면 사이드바
    // 라벨은 활성 Term 라벨로 폴백한다(표시 해석은 platform이 app.label.pick으로). 예전 placeholder `title`을 대체.
    custom_name: []const u8 = "",
    // 위치 고정(우클릭 메뉴) — true면 드래그 재정렬에서 안 움직이고 사이드바에 고정 표시가 뜬다. 기본 false.
    pinned: bool = false,
    // 사이드바 카드 배경 tint(0xRRGGBB, 0=없음/기본 테마색). 우클릭 메뉴 프리셋으로 설정. 기본 0.
    background_color: u32 = 0,
    // 사이드바 카드 좌측 accent 막대색(0xRRGGBB, 0=기본 — 활성=테마 앰버·비활성=막대 없음). 우클릭 메뉴
    // 프리셋으로 설정. 지정하면 활성·비활성 카드 모두 그 색으로 막대 표시. 배경 tint와 직교. 기본 0.
    accent_color: u32 = 0,
    tree: []const TreeNode, // preorder; leaf의 pane 인덱스가 panes를 가리킨다
    panes: []const Pane,
};

/// 한 OS 창 = 한 AppSession. 탭들 + 활성 탭.
pub const Window = struct {
    active_tab: usize = 0,
    tabs: []const Tab,
};

/// 저장 단위(최근 세션 1개). 창 N개.
pub const Workspace = struct {
    windows: []const Window,
};

/// 헤더 + 전체 workspace를 새 문자열로 직렬화한다(호출자 소유). live 캡처(R3)가 모델을 채워 넘기고, reader(R2)가
/// 같은 규칙으로 되읽는다.
pub fn serialize(allocator: std.mem.Allocator, ws: Workspace) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}\n", .{header});
    for (ws.windows) |win| try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

/// 한 창(Window) 블록만 직렬화한다(헤더 없음). 멀티 창 저장(R5)에서 각 AppSession이 자기 창 블록을 내고,
/// Swift가 `maru.workspace.v1` 헤더 하나 아래로 모아 parse 가능한 전체 텍스트를 만든다.
pub fn serializeWindow(allocator: std.mem.Allocator, win: Window) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

fn writeWindow(w: *std.Io.Writer, win: Window) !void {
    try w.print("window tabs={d} active-tab={d}\n", .{ win.tabs.len, win.active_tab });
    for (win.tabs) |tab| try writeTab(w, tab);
}

fn writeTab(w: *std.Io.Writer, tab: Tab) !void {
    try w.print("tab panes={d} active-pane={d} custom-name=\"", .{ tab.panes.len, tab.active_pane });
    try writeEscaped(w, tab.custom_name);
    try w.print("\" pinned={d} background-color={d} accent-color={d}\n", .{ @intFromBool(tab.pinned), tab.background_color, tab.accent_color });
    for (tab.tree) |node| try writeTreeNode(w, node);
    for (tab.panes) |pane| try writePane(w, pane);
}

fn writeTreeNode(w: *std.Io.Writer, node: TreeNode) !void {
    switch (node) {
        .leaf => |idx| try w.print("tree-node leaf pane={d}\n", .{idx}),
        .split => |s| try w.print("tree-node split {s} ratio={d}\n", .{ @tagName(s.direction), s.ratio_milli }),
    }
}

fn writePane(w: *std.Io.Writer, pane: Pane) !void {
    try w.print("pane surfaces={d} active-term={d} custom-name=\"", .{ pane.surfaces.len, pane.active_term });
    try writeEscaped(w, pane.custom_name);
    try w.writeAll("\"\n");
    for (pane.surfaces) |s| try writeSurface(w, s);
}

fn writeSurface(w: *std.Io.Writer, s: Surface) !void {
    // custom-name(사용자 지정 이름)을 auto title 앞에 둔다 — 둘을 인접 배치해 사람이 읽기 쉽게. 리더(parseSurface)는
    // key-addressed(순서 무관·이름 조회, LineFields)라 이 순서는 가독성용일 뿐이고, 구조 키 agent-argc만 필수다.
    try w.writeAll("surface custom-name=\"");
    try writeEscaped(w, s.custom_name);
    try w.writeAll("\" title=\"");
    try writeEscaped(w, s.title);
    try w.writeAll("\" cwd=\"");
    try writeEscaped(w, s.cwd);
    try w.writeAll("\" command=\"");
    try writeEscaped(w, s.command);
    try w.print("\" cols={d} rows={d} agent-kind=\"", .{ s.cols, s.rows });
    try writeEscaped(w, s.agent_kind);
    try w.writeAll("\" agent-session=\"");
    try writeEscaped(w, s.agent_session);
    try w.print("\" agent-argc={d}", .{s.agent_argv.len});
    // agent-argc=N 뒤에 agent-arg="..."를 N개 — parsePane의 surfaces=N count+반복과 같은 self-delimiting 패턴.
    for (s.agent_argv) |arg| {
        try w.writeAll(" agent-arg=\"");
        try writeEscaped(w, arg);
        try w.writeAll("\"");
    }
    try w.writeAll("\n");
}

// ── R2: reader/parser ──────────────────────────────────────────────────────────
// maru.workspace.v1 텍스트를 같은 모델로 되읽는다(round-trip). 결과는 arena가 모든 슬라이스·문자열을 소유하므로
// ParsedWorkspace.deinit() 한 번으로 정리한다. split 트리는 writer와 같은 preorder를 재귀로 재구성한다(split는
// 뒤따르는 두 subtree를 소비). 알 수 없는 trailing 라인은 forgiving하게 멈춘다(window 루프가 안 맞으면 종료).

pub const ParseError = error{ BadHeader, BadLine, Truncated } || std.mem.Allocator.Error;

/// parse 결과 — arena가 workspace의 모든 할당(슬라이스·escape 해제 문자열)을 소유한다. deinit으로 한 번에 해제.
pub const ParsedWorkspace = struct {
    arena: std.heap.ArenaAllocator,
    workspace: Workspace,

    pub fn deinit(self: *ParsedWorkspace) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!ParsedWorkspace {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines = LineIter{ .text = text };
    const head = lines.next() orelse return error.Truncated;
    if (!std.mem.eql(u8, head, header)) return error.BadHeader;

    var windows: std.ArrayList(Window) = .empty;
    while (lines.peek()) |line| {
        if (!std.mem.startsWith(u8, line, "window ")) break; // 알 수 없는 trailing → forgiving 종료
        try windows.append(a, try parseWindow(a, &lines));
    }
    return .{ .arena = arena, .workspace = .{ .windows = try windows.toOwnedSlice(a) } };
}

fn parseWindow(a: std.mem.Allocator, lines: *LineIter) ParseError!Window {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "window")) return error.BadLine;
    const tab_count = try f.requireUint("tabs", usize); // 구조 키(탭 개수) — 없으면 BadLine
    const active_tab = try f.getUint("active-tab", usize, 0); // 스칼라(기본 0=첫 탭)

    var tabs: std.ArrayList(Tab) = .empty;
    var i: usize = 0;
    while (i < tab_count) : (i += 1) try tabs.append(a, try parseTab(a, lines));
    return .{ .active_tab = active_tab, .tabs = try tabs.toOwnedSlice(a) };
}

fn parseTab(a: std.mem.Allocator, lines: *LineIter) ParseError!Tab {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "tab")) return error.BadLine;
    const pane_count = try f.requireUint("panes", usize); // 구조 키(트리·pane 개수 결정) — 없으면 BadLine

    // 손상/변조 파일 방어(R6 graceful). 0개 탭은 빌드 단계에서 무효이고, 부풀린 pane_count는 아래 트리 노드
    // 상한을 거대화해 깊은 재귀를 부르므로 sane 상한으로 먼저 가둔다 — 위반 시 BadLine→그 창은 기본 창으로.
    if (pane_count == 0 or pane_count > max_panes_per_tab) return error.BadLine;

    // 스칼라 속성(순서 무관·없으면 기본값 = additive 하위호환). background-color·accent-color는 나중 추가돼도
    // 옛 파일이 안 깨지고 0(없음)으로 복원된다(docs/workspace-restore.md "직렬화 진화 계획").
    const active_pane = try f.getUint("active-pane", usize, 0);
    const custom_name = try f.getQuoted(a, "custom-name", "");
    const pinned = (try f.getUint("pinned", u8, 0)) != 0;
    const background_color = try f.getUint("background-color", u32, 0);
    const accent_color = try f.getUint("accent-color", u32, 0);

    var tree: std.ArrayList(TreeNode) = .empty;
    // 구조 불변식: pane P개 탭의 split 트리는 leaf P + split (P−1) = 정확히 2P−1 노드다. 그보다 많이 읽히면
    // (손상·순환) BadLine으로 멈춰 크래시 대신 graceful 폴백한다. pane_count가 가둬졌으니 재귀 깊이도 ≤2P−1.
    try parseTree(a, lines, &tree, 2 * pane_count - 1); // 탭의 트리 하나(self-delimiting preorder)

    var panes: std.ArrayList(Pane) = .empty;
    var i: usize = 0;
    while (i < pane_count) : (i += 1) try panes.append(a, try parsePane(a, lines));
    return .{ .active_pane = active_pane, .custom_name = custom_name, .pinned = pinned, .background_color = background_color, .accent_color = accent_color, .tree = try tree.toOwnedSlice(a), .panes = try panes.toOwnedSlice(a) };
}

/// 한 subtree를 preorder로 읽어 out에 append(self-delimiting). split는 뒤따르는 두 subtree(a,b)를 재귀로 소비.
/// max_nodes = 2·pane_count−1(구조 불변식): 이미 그만큼 읽었으면 더 읽지 않고 BadLine — 노드 수·재귀 깊이를 함께 가둔다.
fn parseTree(a: std.mem.Allocator, lines: *LineIter, out: *std.ArrayList(TreeNode), max_nodes: usize) ParseError!void {
    if (out.items.len >= max_nodes) return error.BadLine; // 트리 노드 수 > 2·pane−1 — 손상/순환(스택 오버플로 방지)
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "tree-node")) return error.BadLine;
    const kind = try r.word();
    if (std.mem.eql(u8, kind, "leaf")) {
        try r.key("pane=");
        try out.append(a, .{ .leaf = try r.uint(usize) });
    } else if (std.mem.eql(u8, kind, "split")) {
        const dir_word = try r.word();
        const dir: SplitDirection = if (std.mem.eql(u8, dir_word, "horizontal"))
            .horizontal
        else if (std.mem.eql(u8, dir_word, "vertical"))
            .vertical
        else
            return error.BadLine;
        try r.key("ratio=");
        const ratio = try r.uint(u16);
        try out.append(a, .{ .split = .{ .direction = dir, .ratio_milli = ratio } });
        try parseTree(a, lines, out, max_nodes); // a
        try parseTree(a, lines, out, max_nodes); // b
    } else return error.BadLine;
}

fn parsePane(a: std.mem.Allocator, lines: *LineIter) ParseError!Pane {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "pane")) return error.BadLine;
    const surface_count = try f.requireUint("surfaces", usize); // 구조 키(surface 개수) — 없으면 BadLine
    const active_term = try f.getUint("active-term", usize, 0); // 스칼라(기본 0)
    const custom_name = try f.getQuoted(a, "custom-name", "");

    var surfaces: std.ArrayList(Surface) = .empty;
    var i: usize = 0;
    while (i < surface_count) : (i += 1) try surfaces.append(a, try parseSurface(a, lines));
    return .{ .active_term = active_term, .custom_name = custom_name, .surfaces = try surfaces.toOwnedSlice(a) };
}

fn parseSurface(a: std.mem.Allocator, lines: *LineIter) ParseError!Surface {
    const f = try LineFields.parse(a, lines.next() orelse return error.Truncated);
    if (!std.mem.eql(u8, f.kind, "surface")) return error.BadLine;
    // 스칼라 속성(순서 무관·없으면 기본값). cols/rows는 복원 시 실제 pane 크기로 resize되므로 누락 시 sane 터미널
    // 기본(80×24)으로 graceful — 실 파일엔 항상 있고, 이 기본은 손상/축약 파일에서만 쓰인다.
    const custom_name = try f.getQuoted(a, "custom-name", "");
    const title = try f.getQuoted(a, "title", "");
    const cwd = try f.getQuoted(a, "cwd", "");
    const command = try f.getQuoted(a, "command", "");
    const cols = try f.getUint("cols", u16, 80);
    const rows = try f.getUint("rows", u16, 24);
    const agent_kind = try f.getQuoted(a, "agent-kind", "");
    const agent_session = try f.getQuoted(a, "agent-session", "");
    // agent-argc는 구조 키(반복 agent-arg 개수의 self-delimiting 기준) — 없으면 BadLine, 거대값은 방어 차단.
    const argc = try f.requireUint("agent-argc", usize);
    if (argc > max_agent_argv) return error.BadLine; // 손상/변조 방어(거대 루프 차단)
    var argv: std.ArrayList([]const u8) = .empty;
    for (f.fields) |field| { // 반복 키 agent-arg를 나온 순서대로 수집(key-addressed find는 첫 매치만이라 직접 순회)
        if (!std.mem.eql(u8, field.key, "agent-arg")) continue;
        if (!field.is_quoted) return error.BadLine;
        try argv.append(a, try unescapeQuoted(a, field.raw));
    }
    if (argv.items.len != argc) return error.BadLine; // self-delimiting 정합: agent-argc == 실제 agent-arg 개수(불일치=손상)
    return .{
        .custom_name = custom_name,
        .title = title,
        .cwd = cwd,
        .command = command,
        .cols = cols,
        .rows = rows,
        .agent_kind = agent_kind,
        .agent_session = agent_session,
        .agent_argv = try argv.toOwnedSlice(a),
    };
}

/// 텍스트를 개행 단위 라인으로 나눈다(마지막 개행 뒤 빈 줄은 내지 않는다). peek은 소비 없이 다음 라인을 본다.
const LineIter = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.i >= self.text.len) return null;
        const start = self.i;
        const nl = std.mem.indexOfScalarPos(u8, self.text, self.i, '\n') orelse self.text.len;
        self.i = if (nl < self.text.len) nl + 1 else self.text.len;
        return self.text[start..nl];
    }

    fn peek(self: *const LineIter) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

/// `tree-node` 구조 라인 전용 순차(positional) 파서 — leaf/split 판별 word + pane=/ratio= 정수. 스칼라 속성 라인
/// (window/tab/pane/surface)은 순서 무관 key-addressed(LineFields)로 읽는다(docs/workspace-restore.md "직렬화 진화
/// 계획"). tree-node는 구조(라인 타입·판별 word)라 key=value가 아니어서 positional 유지. word=공백까지 한 토큰, key=`name` 정확 매치, uint=숫자.
const FieldReader = struct {
    line: []const u8,
    i: usize = 0,

    fn skipSpaces(self: *FieldReader) void {
        while (self.i < self.line.len and self.line[self.i] == ' ') self.i += 1;
    }

    fn word(self: *FieldReader) ParseError![]const u8 {
        self.skipSpaces();
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] != ' ') self.i += 1;
        if (self.i == start) return error.BadLine;
        return self.line[start..self.i];
    }

    fn key(self: *FieldReader, name: []const u8) ParseError!void {
        self.skipSpaces();
        if (!std.mem.startsWith(u8, self.line[self.i..], name)) return error.BadLine;
        self.i += name.len;
    }

    fn uint(self: *FieldReader, comptime T: type) ParseError!T {
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] >= '0' and self.line[self.i] <= '9') self.i += 1;
        if (self.i == start) return error.BadLine;
        return std.fmt.parseInt(T, self.line[start..self.i], 10) catch error.BadLine;
    }
};

/// 따옴표 값의 escape(`\\` `\"` `\n` `\r` `\t`)를 해제해 arena에 dup한다(writer.writeEscaped의 역연산).
/// LineFields가 조회 시점에 호출한다(원바이트는 토큰화 때 span만 잡아두고, 실제 읽는 키만 여기서 해제).
fn unescapeQuoted(a: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\') {
            i += 1;
            if (i >= raw.len) return error.BadLine;
            try out.append(a, switch (raw[i]) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.BadLine,
            });
            i += 1;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// 스칼라 속성 라인(`<kind> key=val key="quoted" ...`)을 **순서 무관** key=value 필드로 토큰화한다(key-addressed —
/// docs/workspace-restore.md "직렬화 진화 계획"). 구조 키(개수: `tabs`/`panes`/`surfaces`/`agent-argc`)는 `requireUint`으로
/// 없으면 BadLine(손상 탐지 loud-fail 유지), 스칼라 속성은 `getUint`/`getQuoted`로 없으면 기본값(additive 하위호환 —
/// 옛 파일이 안 깨짐). 미지 키는 조회 안 되어 자연히 skip(forward-compat). 값은 조회 시점에 파싱(quoted는 그때
/// escape 해제 → arena). 반복 키(`agent-arg`)는 `fields`를 직접 순회해 순서대로 수집한다.
const LineFields = struct {
    const Field = struct { key: []const u8, raw: []const u8, is_quoted: bool }; // raw: uint=숫자 슬라이스 / quoted=따옴표 안 원바이트(escape 미해제)

    kind: []const u8,
    fields: []const Field,

    /// 라인을 `kind` + (key,value) 필드로 훑는다. 따옴표 값은 escape(`\"`)를 존중해 닫는 따옴표를 찾으므로, 값 안의
    /// `key=` 흉내나 공백이 토큰 경계를 깨지 않는다. key에 `=`가 없으면 BadLine, 닫는 따옴표가 없으면 BadLine.
    fn parse(a: std.mem.Allocator, line: []const u8) ParseError!LineFields {
        var i: usize = 0;
        while (i < line.len and line[i] == ' ') i += 1;
        const ks = i;
        while (i < line.len and line[i] != ' ') i += 1;
        if (i == ks) return error.BadLine; // 라인 타입 토큰 없음
        const kind = line[ks..i];

        var list: std.ArrayList(Field) = .empty;
        while (true) {
            while (i < line.len and line[i] == ' ') i += 1;
            if (i >= line.len) break;
            if (list.items.len >= max_line_fields) return error.BadLine; // 손상/변조 방어: 한 줄 토큰 폭주 차단(작업·메모리 경계)
            const key_start = i;
            while (i < line.len and line[i] != '=' and line[i] != ' ') i += 1;
            if (i >= line.len or line[i] != '=' or i == key_start) return error.BadLine; // key= 형식 아님
            const key = line[key_start..i];
            i += 1; // '=' 소비
            if (i < line.len and line[i] == '"') {
                i += 1;
                const vs = i;
                while (i < line.len and line[i] != '"') {
                    i += if (line[i] == '\\') 2 else 1; // escape 다음 1바이트 건너뜀(닫는 따옴표가 \" 를 안 오인하게)
                }
                if (i >= line.len) return error.BadLine; // 닫는 따옴표 없음(escape가 끝을 넘어가도 여기서 걸림)
                try list.append(a, .{ .key = key, .raw = line[vs..i], .is_quoted = true });
                i += 1; // 닫는 따옴표 소비
            } else {
                const vs = i;
                while (i < line.len and line[i] != ' ') i += 1;
                try list.append(a, .{ .key = key, .raw = line[vs..i], .is_quoted = false });
            }
        }
        return .{ .kind = kind, .fields = try list.toOwnedSlice(a) };
    }

    fn find(self: LineFields, key: []const u8) ?Field {
        for (self.fields) |f| if (std.mem.eql(u8, f.key, key)) return f;
        return null;
    }

    /// 스칼라 정수 속성: 있으면 파싱(quoted면 BadLine·garbage면 BadLine — 있는데 깨졌으면 조용히 기본값 금지), 없으면 default.
    fn getUint(self: LineFields, key: []const u8, comptime T: type, default: T) ParseError!T {
        const f = self.find(key) orelse return default;
        if (f.is_quoted) return error.BadLine;
        return std.fmt.parseInt(T, f.raw, 10) catch error.BadLine;
    }

    /// 구조 정수 키(개수 등): 없으면 BadLine(loud-fail — 기본값으로 못 때움).
    fn requireUint(self: LineFields, key: []const u8, comptime T: type) ParseError!T {
        const f = self.find(key) orelse return error.BadLine;
        if (f.is_quoted) return error.BadLine;
        return std.fmt.parseInt(T, f.raw, 10) catch error.BadLine;
    }

    /// 스칼라 따옴표 속성: 있으면 escape 해제해 arena dup, 없으면 default(호출자 리터럴 — arena가 통째 소유하므로 정적 슬라이스도 안전).
    fn getQuoted(self: LineFields, a: std.mem.Allocator, key: []const u8, default: []const u8) ParseError![]const u8 {
        const f = self.find(key) orelse return default;
        if (!f.is_quoted) return error.BadLine;
        return unescapeQuoted(a, f.raw);
    }
};

test "workspace serialize: 단일 창/탭/pane/surface" {
    const surfaces = [_]Surface{
        .{ .title = "app shell", .cwd = "/home/user/proj", .command = "/bin/zsh", .cols = 80, .rows = 24 },
    };
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .custom_name = "work", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .active_tab = 0, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "maru.workspace.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=1 active-pane=0 custom-name=\"work\" pinned=0 background-color=0 accent-color=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pane surfaces=1 active-term=0 custom-name=\"\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface custom-name=\"\" title=\"app shell\" cwd=\"/home/user/proj\" command=\"/bin/zsh\" cols=80 rows=24 agent-kind=\"\" agent-session=\"\" agent-argc=0\n") != null);
}

test "workspace serialize: split 트리(중첩) + 멀티 pane" {
    // split horizontal { split vertical { leaf0, leaf1 }, leaf2 } — preorder 5노드, 3 panes.
    const s0 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 24 }};
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes = [_]Pane{
        .{ .surfaces = &s0 },
        .{ .surfaces = &s1 },
        .{ .surfaces = &s2 },
    };
    const tree = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs = [_]Tab{.{ .active_pane = 2, .custom_name = "split", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=3 active-pane=2 custom-name=\"split\" pinned=0 background-color=0 accent-color=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split horizontal ratio=500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split vertical ratio=300\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=2\n") != null);
}

test "workspace serialize: 멀티 창 + cwd/title escape" {
    // 따옴표·공백·개행이 섞인 cwd/title이 한 줄·한 토큰으로 escape돼야 한다.
    const s = [_]Surface{.{ .title = "a \"b\"", .cwd = "/tmp/x y\n", .command = "/bin/zsh", .cols = 10, .rows = 5 }};
    const panes = [_]Pane{.{ .surfaces = &s }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tab = Tab{ .tree = &tree, .panes = &panes };
    const tabs0 = [_]Tab{tab};
    const tabs1 = [_]Tab{tab};
    const windows = [_]Window{ .{ .tabs = &tabs0 }, .{ .tabs = &tabs1 } };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    // window 라인이 두 번(멀티 창).
    var it = std.mem.splitScalar(u8, text, '\n');
    var window_lines: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "window ")) window_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), window_lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface custom-name=\"\" title=\"a \\\"b\\\"\" cwd=\"/tmp/x y\\n\" command=\"/bin/zsh\" cols=10 rows=5 agent-kind=\"\" agent-session=\"\" agent-argc=0\n") != null);
}

test "workspace round-trip: serialize → parse → 다시 serialize 동일(중첩 split·멀티 창·escape)" {
    // 복잡한 모델(멀티 창, 중첩 split, escape 필요한 cwd/title)을 직렬화한 뒤 되읽고 다시 직렬화하면 동일해야 한다.
    const s0 = [_]Surface{ .{ .title = "a \"b\"", .cwd = "/tmp/x y", .command = "/bin/zsh", .cols = 40, .rows = 24 }, .{ .cwd = "/var\nlog", .command = "/bin/bash", .cols = 40, .rows = 24 } };
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes0 = [_]Pane{ .{ .active_term = 1, .surfaces = &s0 }, .{ .surfaces = &s1 }, .{ .surfaces = &s2 } };
    const tree0 = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs0 = [_]Tab{.{ .active_pane = 2, .custom_name = "split", .tree = &tree0, .panes = &panes0 }};

    const sA = [_]Surface{.{ .title = "w2", .cwd = "/home", .command = "/bin/zsh", .cols = 100, .rows = 30 }};
    const panes1 = [_]Pane{.{ .surfaces = &sA }};
    const tree1 = [_]TreeNode{.{ .leaf = 0 }};
    const tabs1 = [_]Tab{.{ .custom_name = "single", .tree = &tree1, .panes = &panes1 }};

    const windows = [_]Window{ .{ .active_tab = 0, .tabs = &tabs0 }, .{ .active_tab = 0, .tabs = &tabs1 } };

    const text1 = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text1);

    var parsed = try parse(std.testing.allocator, text1);
    defer parsed.deinit();

    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2); // writer↔reader 고정점
}

test "workspace round-trip: tab pinned·background_color·accent_color 보존" {
    const surfaces = [_]Surface{.{ .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .custom_name = "work", .pinned = true, .background_color = 0xDDA15E, .accent_color = 0x4A7BC4, .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pinned=1 background-color=14524766 accent-color=4881348\n") != null); // 0xDDA15E=14524766, 0x4A7BC4=4881348

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const tab = parsed.workspace.windows[0].tabs[0];
    try std.testing.expectEqual(true, tab.pinned);
    try std.testing.expectEqual(@as(u32, 0xDDA15E), tab.background_color);
    try std.testing.expectEqual(@as(u32, 0x4A7BC4), tab.accent_color);
}

test "workspace parse: 구조·escape 해제·forgiving" {
    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=1 custom-name=\"my tab\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node split vertical ratio=250\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"left pane\"\n" ++
        "surface custom-name=\"editor\" title=\"top\" cwd=\"/a b\\\"c\" command=\"/bin/zsh\" cols=80 rows=24 agent-kind=\"\" agent-session=\"\" agent-argc=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/bash\" cols=80 rows=10 agent-kind=\"\" agent-session=\"\" agent-argc=0\n" ++
        "trailing-garbage that should be ignored\n";

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const ws = parsed.workspace;

    try std.testing.expectEqual(@as(usize, 1), ws.windows.len);
    const tab = ws.windows[0].tabs[0];
    try std.testing.expectEqual(@as(usize, 1), tab.active_pane);
    try std.testing.expectEqualStrings("my tab", tab.custom_name); // 워크스페이스 사용자 지정 이름
    try std.testing.expectEqual(@as(u32, 0), tab.accent_color); // accent-color=0 파싱
    // 트리: split(vertical, 250) { leaf0, leaf1 } — preorder 3노드.
    try std.testing.expectEqual(@as(usize, 3), tab.tree.len);
    try std.testing.expect(tab.tree[0].split.direction == .vertical);
    try std.testing.expectEqual(@as(u16, 250), tab.tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(usize, 1), tab.tree[2].leaf);
    // surface[0] cwd escape 해제: `/a b"c`. custom_name(사용자)과 title(자동)은 별도 필드로 round-trip.
    try std.testing.expectEqual(@as(usize, 2), tab.panes.len);
    try std.testing.expectEqualStrings("left pane", tab.panes[0].custom_name); // pane 사용자 지정 이름
    try std.testing.expectEqualStrings("editor", tab.panes[0].surfaces[0].custom_name); // Term 사용자 지정 이름
    try std.testing.expectEqualStrings("top", tab.panes[0].surfaces[0].title); // Term 자동 제목(별도)
    try std.testing.expectEqualStrings("/a b\"c", tab.panes[0].surfaces[0].cwd);
    try std.testing.expectEqual(@as(u16, 80), tab.panes[0].surfaces[0].cols);
    try std.testing.expectEqualStrings("", tab.panes[1].custom_name); // 빈 custom_name = 이름 없음
    try std.testing.expectEqualStrings("/bin/bash", tab.panes[1].surfaces[0].command);
}

test "workspace parse: key-addressed 하위호환·순서무관·미지키 skip·구조키 필수" {
    // ① 하위호환: background-color·accent-color가 없는 옛 tab 라인도 파싱되고 각각 0(기본)이 된다(폴백 없음).
    //    active-pane·pinned도 없이 panes=만 있어도 스칼라는 전부 기본값으로 복원 — additive 필드가 옛 파일을 안 깬다.
    const old =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 custom-name=\"legacy\"\n" ++ // background-color·accent-color·active-pane·pinned 없음(구버전)
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 custom-name=\"\"\n" ++ // active-term 없음
        "surface custom-name=\"\" title=\"\" cwd=\"/w\" command=\"/bin/zsh\" cols=100 rows=30 agent-kind=\"\" agent-session=\"\" agent-argc=0\n";
    var op = try parse(std.testing.allocator, old);
    defer op.deinit();
    const ot = op.workspace.windows[0].tabs[0];
    try std.testing.expectEqualStrings("legacy", ot.custom_name);
    try std.testing.expectEqual(@as(u32, 0), ot.background_color); // 없음 → 기본 0
    try std.testing.expectEqual(@as(u32, 0), ot.accent_color); // 없음 → 기본 0
    try std.testing.expectEqual(false, ot.pinned); // 없음 → 기본 false
    try std.testing.expectEqual(@as(usize, 0), ot.active_pane); // 없음 → 기본 0
    try std.testing.expectEqual(@as(usize, 0), ot.panes[0].active_term); // 없음 → 기본 0

    // ② 순서 무관 + ③ 미지 키 skip: 스칼라 키 순서를 뒤섞고 모르는 future-key를 끼워도 정확히 파싱된다(forward-compat).
    const reordered =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab accent-color=100 panes=1 future-key=\"ignored\" pinned=1 custom-name=\"x\" background-color=200 active-pane=0\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/zsh\" cols=80 rows=24 agent-kind=\"\" agent-session=\"\" agent-argc=0\n";
    var rp = try parse(std.testing.allocator, reordered);
    defer rp.deinit();
    const rt = rp.workspace.windows[0].tabs[0];
    try std.testing.expectEqual(@as(u32, 200), rt.background_color); // 순서 뒤섞여도 이름으로 정확히
    try std.testing.expectEqual(@as(u32, 100), rt.accent_color);
    try std.testing.expectEqual(true, rt.pinned);
    try std.testing.expectEqualStrings("x", rt.custom_name); // future-key는 조용히 skip, 값 흉내가 경계 안 깸

    // ④ 구조 키(panes=)가 없으면 loud-fail(BadLine) — 손상 탐지는 유지(스칼라만 기본값, 개수 키는 required).
    const no_panes =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab active-pane=0 custom-name=\"\"\n"; // panes= 없음 → 블록 파싱 불가
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, no_panes));
}

test "workspace parse: 잘못된 헤더는 에러" {
    try std.testing.expectError(error.BadHeader, parse(std.testing.allocator, "not.a.workspace\nwindow tabs=0 active-tab=0\n"));
}

test "workspace parse: 손상 트리는 구조 불변식으로 graceful 차단(크래시 대신 BadLine)" {
    // 탭은 panes=2(트리 노드 최대 2·2−1=3)인데 split가 과하게 중첩돼 4번째 노드를 요구 → BadLine으로 멈춘다
    // (깊은 재귀 스택 오버플로 방지). 복원 측은 이 에러로 그 창을 기본 창으로 떨군다.
    const deep =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, deep));

    // 부풀린 pane_count는 트리 노드 상한(2·pane−1)을 거대화하므로 sane 상한(max_panes_per_tab)에서 먼저 막는다.
    const huge =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=999999 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, huge));
}

test "workspace serializeWindow: 헤더 없는 블록을 모아 전체로 parse(R5 집계)" {
    // 두 창을 각각 serializeWindow(헤더 없음)로 내고 헤더 하나 아래로 모으면, parse가 전체 workspace로 읽는다.
    const s0 = [_]Surface{.{ .cwd = "/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p0 = [_]Pane{.{ .surfaces = &s0 }};
    const t0 = [_]TreeNode{.{ .leaf = 0 }};
    const win0 = Window{ .tabs = &[_]Tab{.{ .tree = &t0, .panes = &p0 }} };

    const s1 = [_]Surface{.{ .cwd = "/b", .command = "/bin/bash", .cols = 100, .rows = 30 }};
    const p1 = [_]Pane{.{ .surfaces = &s1 }};
    const t1 = [_]TreeNode{.{ .leaf = 0 }};
    const win1 = Window{ .tabs = &[_]Tab{.{ .tree = &t1, .panes = &p1 }} };

    const b0 = try serializeWindow(std.testing.allocator, win0);
    defer std.testing.allocator.free(b0);
    const b1 = try serializeWindow(std.testing.allocator, win1);
    defer std.testing.allocator.free(b1);
    try std.testing.expect(std.mem.startsWith(u8, b0, "window ")); // 헤더 없음

    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}{s}", .{ header, b0, b1 });
    defer std.testing.allocator.free(text);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.workspace.windows.len);
    try std.testing.expectEqualStrings("/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/b", parsed.workspace.windows[1].tabs[0].panes[0].surfaces[0].cwd);
}

test "workspace serialize: 선언적 — env/fd/pid/last-observed 필드 없음(민감 데이터 미저장 정책)" {
    // 모델이 PTY 핸들·env·last_observed_command 필드를 안 가져, 저장 텍스트에 그런 라인이 절대 안 샌다
    // (docs/workspace-restore.md: live process 저장 금지, env는 allowlist 전까지 비움, last command 자동실행 금지).
    // 이 가드는 누가 나중에 그런 필드를 추가하면 깨져서 정책 위반을 컴파일·테스트 단계에서 잡는다.
    const s = [_]Surface{.{ .title = "api", .cwd = "/home/user/.secret-proj", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p = [_]Pane{.{ .surfaces = &s }};
    const t = [_]TreeNode{.{ .leaf = 0 }};
    const w = [_]Window{.{ .tabs = &[_]Tab{.{ .tree = &t, .panes = &p }} }};
    const text = try serialize(std.testing.allocator, .{ .windows = &w });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "env=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fd=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pid=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last-observed") == null);
    // cwd는 경로라 정상 저장된다(redaction 대상은 env이지 path가 아님 — workspace-restore.md).
    try std.testing.expect(std.mem.indexOf(u8, text, "cwd=\"/home/user/.secret-proj\"") != null);
}

test "workspace round-trip: agent_kind·agent_session·agent_argv 보존(escape 포함)" {
    // claude/codex 세션 resume 정보가 serialize→parse를 통해 그대로 round-trip되는지. argv 토큰은 공백·따옴표를
    // 포함해도 한 줄·토큰별로 안전히 인코딩돼야 한다(agent-argc=N + agent-arg="..." 패턴, docs/workspace-restore.md).
    const argv = [_][]const u8{ "claude", "--dangerously-skip-permissions", "--resume", "id a\"b" };
    const surfaces = [_]Surface{.{
        .command = "/Users/me/.local/bin/claude",
        .cols = 80,
        .rows = 24,
        .agent_kind = "claude",
        .agent_session = "23cb4875-83e6-4e9e-b37f-6e1112d5fff9",
        .agent_argv = &argv,
    }};
    const panes = [_]Pane{.{ .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "agent-kind=\"claude\" agent-session=\"23cb4875-83e6-4e9e-b37f-6e1112d5fff9\" agent-argc=4") != null);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const s = parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0];
    try std.testing.expectEqualStrings("claude", s.agent_kind);
    try std.testing.expectEqualStrings("23cb4875-83e6-4e9e-b37f-6e1112d5fff9", s.agent_session);
    try std.testing.expectEqual(@as(usize, 4), s.agent_argv.len);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", s.agent_argv[1]);
    try std.testing.expectEqualStrings("id a\"b", s.agent_argv[3]); // escape round-trip(따옴표 포함)
}

test "workspace parse: agent-argc 과대값은 graceful 차단(BadLine)" {
    // 손상/변조 파일이 agent-argc를 부풀려도 max_agent_argv에서 먼저 막아 거대 루프를 돈다(복원 측은 기본 창 폴백).
    const huge =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 active-pane=0 custom-name=\"\" pinned=0 background-color=0 accent-color=0\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/zsh\" cols=80 rows=24 agent-kind=\"claude\" agent-session=\"\" agent-argc=999999\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, huge));
}

test "workspace parse: 라인 필드 수 상한 초과는 BadLine(key-addressed 토큰 폭주 방어)" {
    // agent-argc는 작지만(2) agent-arg 토큰을 max_line_fields 넘게 채운 라인 — count 불일치 이전에 LineFields.parse의
    // 필드 상한에서 먼저 BadLine. max_agent_argv가 argc 값만 가두던 방어를 key-addressed 리더의 라인 토큰 수로도 유지함을 고정.
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=1 custom-name=\"\"\n" ++
        "tree-node leaf pane=0\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"\" command=\"/bin/zsh\" cols=80 rows=24 agent-kind=\"\" agent-session=\"\" agent-argc=2");
    var k: usize = 0;
    while (k < max_line_fields + 8) : (k += 1) try buf.appendSlice(a, " agent-arg=\"x\""); // 기본 9키 + 이만큼 → 상한 초과
    try buf.appendSlice(a, "\n");
    try std.testing.expectError(error.BadLine, parse(a, buf.items));
}
