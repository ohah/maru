//! L2 session core — OS-중립 세션 모델(Term/Pane/Tab + split 트리).
//!
//! 런타임 부착(PTY 세션·이벤트 펌프·생애 플래그)은 generic 파라미터 `Rt`로 주입한다 —
//! platform/macos/app_session이 `TermRuntime`을 넣어 `Model(TermRuntime)`으로 인스턴스화하고, 이 레이어는
//! PTY/렌더 핸들을 모른 채 모델만 소유한다(`SplitTree(comptime Leaf)` 선례). 단일 출처:
//! docs/layering-and-portability.md §3.1.
//!
//! 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 식별자로 새지 않는다 — tests/boundary/imports.zig가 강제.
//! `surface`(터미널 그리드/스크롤백)·`split_tree`(레이아웃 트리)는 이미 OS-중립인 src/app 모듈이고, `agent_state`는
//! 중립 판정 결과(agent_transcript.AgentState)다.

const std = @import("std");
const surface_mod = @import("../app/surface.zig");
const split_tree = @import("../app/split_tree.zig");
const agent_transcript = @import("agent_transcript.zig");
const workspace = @import("../app/workspace.zig"); // OS-중립 직렬화 모델(app.workspace.v1) — TreeNode 변환용

const Surface = surface_mod.Surface;

/// Term 포그라운드에서 도는 에이전트 CLI 종류. 사이드바에 심볼로 표시(claude=✶, codex=◆).
/// platform이 PTY proc_name 폴링(pollAgentKinds)으로 채우는 파생값이고, 모델은 라벨 표시에만 쓴다.
pub const AgentKind = enum(u8) { none = 0, claude, codex };

/// idle 에이전트 답변 첫 줄을 담는 inline 버퍼 길이(alloc 회피 — 폭에 맞춰 다시 말줄임).
pub const agent_answer_max: usize = 192;

/// 세션 모델 생성자 — 런타임 부착 타입 `Rt`로 parametrize한다(platform=`TermRuntime`).
/// `const Model = session_model.Model(TermRuntime); const Term = Model.Term;` 식으로 platform이
/// 별칭을 잡으면 기존 `Term`/`*Term`/`Pane`/`Tab`/`PaneTree` 참조가 전부 그대로다.
pub fn Model(comptime Rt: type) type {
    return struct {
        /// 한 터미널의 모델 — surface(OS-중립 그리드/스크롤백)와 라벨·git·agent 메타. 런타임 부착은 `rt: Rt`로
        /// 주입(platform=TermRuntime). 모델은 `Rt`(PTY 결합)를 모른 채 surface·메타만 소유한다.
        pub const Term = struct {
            surface: Surface = undefined,
            /// 런타임 부착(PTY 세션·pump·생애 플래그) — generic `Rt`로 주입. platform이 `TermRuntime`을 넣는다.
            rt: Rt = .{},
            /// git 브랜치 표시 캐시(owned, cwd 파생). termGitBranch가 cwd가 바뀔 때만 재계산. destroyTerm이 해제.
            git_branch: ?[]const u8 = null,
            git_branch_cwd: ?[]const u8 = null,
            /// 포그라운드가 어떤 에이전트 CLI인지(파생값). pollAgentKinds가 ≈0.5s마다 proc_name으로 갱신.
            agent_kind: AgentKind = .none,
            /// 에이전트 세션 진행 상태(파생값) — pollAgentState가 세션 JSONL tail로 판정. mtime=세션 파일 mtime(나노초,
            /// 안 바뀌면 재파싱 skip). answer_buf/_len=idle일 때 마지막 답변 첫 줄(inline 버퍼). owned 포인터 없음.
            agent_state: agent_transcript.AgentState = .unknown,
            agent_session_mtime: i128 = 0,
            agent_answer_buf: [agent_answer_max]u8 = undefined,
            agent_answer_len: usize = 0,
            /// 사이드바·탭 라벨용 자동 제목 캐시(owned). syncAutoTitles가 core.windowTitle()을 복사해 채운다. destroyTerm이 해제.
            auto_title: std.ArrayListUnmanaged(u8) = .empty,
        };

        /// split leaf 하나 = 가로 탭(Term) 묶음. 항상 Term ≥1. tree leaf가 active_term의 surface를 가리킨다.
        pub const Pane = struct {
            terms: std.ArrayList(*Term) = .empty,
            active_term: usize = 0,
            /// 가로 탭 스크롤 offset(컬럼). 탭이 바 폭을 넘으면 ‹›/트랙패드가 이 값을 움직인다(per-pane).
            tab_scroll_cols: u32 = 0,
            /// 스크롤바 fade 타이머(per-pane). updateScrollbarFade가 view_offset 변화를 감지해 리셋.
            scrollbar_idle_ticks: u32 = 0,
            scrollbar_last_view_offset: usize = 0,
            /// 사용자 지정 이름(rename, owned). Pane은 자동 제목 출처가 없어 custom_name 하나뿐. destroyPane이 해제.
            custom_name: ?[]const u8 = null,

            /// 활성 Term(보이는 터미널). 입력/커서/렌더가 이 Term의 surface를 쓴다. Pane은 항상 Term ≥1.
            pub fn activeTerm(self: *Pane) *Term {
                return self.terms.items[self.active_term];
            }
        };

        /// 한 탭의 split 레이아웃 트리. leaf=`*Pane`. 순수 연산(layout·removeLeaf 등)은 split_tree가 소유.
        pub const PaneTree = split_tree.SplitTree(*Pane);

        /// 워크스페이스(사이드바 탭)의 panel들 + split 트리 루트. tree leaf가 각 Pane의 활성 Term surface를 가리킨다.
        pub const Tab = struct {
            panes: std.ArrayList(*Pane) = .empty,
            active_pane: usize = 0,
            /// SplitTree 루트(split 모델). 단일 leaf면 panel 1개 = 풀 탭. split이 leaf를 split 노드로 바꾼다.
            tree: PaneTree.Node = undefined,
            /// 워크스페이스 사용자 지정 이름(rename, owned). 없으면 활성 Term 라벨로 폴백. destroyTab이 해제.
            custom_name: ?[]const u8 = null,
            /// 위치 고정(Pin) — true면 드래그 재정렬에서 안 움직인다. workspace.v1 영속.
            pinned: bool = false,
            /// 사이드바 카드 배경 tint(0xRRGGBB, 0=기본 테마색). workspace.v1 영속.
            background_color: u32 = 0,

            /// 포커스된 panel. pane 내부(Term/surface) 접근에 쓴다. 탭은 항상 panel ≥1.
            pub fn activePane(self: *Tab) *Pane {
                return self.panes.items[self.active_pane];
            }
            /// 포커스된 panel의 활성 Term(탭 대표 surface).
            pub fn activeTerm(self: *Tab) *Term {
                return self.activePane().activeTerm();
            }
        };

        // ── workspace 직렬화 변환(PaneTree ↔ app.workspace.TreeNode) ──────────────────────────────────
        // 라이브 split 트리(세션 모델)와 직렬화 모델(app.workspace.v1) 사이의 pure 변환. PTY/렌더 없이
        // 트리 구조만 다루므로 session core가 소유한다(capture/restore 오케스트레이션·PTY spawn은 platform).

        /// 활성 탭 트리(PaneTree, `*Pane` leaf)를 `workspace.TreeNode` preorder 리스트로 평탄화(저장용).
        /// leaf는 `tab.panes`의 인덱스로, split은 방향+ratio_milli로 인코딩. arena만 할당하는 pure 함수.
        pub fn flattenTree(arena: std.mem.Allocator, tab: *Tab, node: PaneTree.Node, out: *std.ArrayList(workspace.TreeNode)) !void {
            switch (node) {
                .leaf => |pane_ptr| {
                    const idx = paneIndexOf(tab, pane_ptr) orelse return error.PaneNotFound;
                    try out.append(arena, .{ .leaf = idx });
                },
                .split => |s| {
                    const milli: u16 = @intFromFloat(@round(std.math.clamp(s.ratio, 0.0, 1.0) * 1000.0));
                    try out.append(arena, .{ .split = .{ .direction = s.direction, .ratio_milli = milli } });
                    try flattenTree(arena, tab, s.a, out);
                    try flattenTree(arena, tab, s.b, out);
                },
            }
        }

        fn paneIndexOf(tab: *Tab, pane: *Pane) ?usize {
            for (tab.panes.items, 0..) |p, i| {
                if (p == pane) return i;
            }
            return null;
        }

        /// `workspace.TreeNode` preorder를 `PaneTree.Node`(`*Pane`)로 복원. leaf 인덱스→`panes[i]`, split은
        /// 새 노드(allocator로 생성, `splits`에 추적). 같은 pane을 두 leaf로 참조하면 error(UAF 차단). allocator만
        /// 쓰는 pure 함수 — `self.allocator` 대신 인자로 받아 platform 비의존(호출자가 splits capacity 예약).
        pub fn buildTreeNode(allocator: std.mem.Allocator, panes: []const *Pane, nodes: []const workspace.TreeNode, idx: *usize, splits: *std.ArrayList(*PaneTree.Split), used: []bool) !PaneTree.Node {
            if (idx.* >= nodes.len) return error.MalformedTree;
            const node = nodes[idx.*];
            idx.* += 1;
            switch (node) {
                .leaf => |pane_index| {
                    if (pane_index >= panes.len) return error.MalformedTree;
                    if (used[pane_index]) return error.MalformedTree; // 같은 pane을 두 leaf로 참조(중복) — UAF 차단
                    used[pane_index] = true;
                    return .{ .leaf = panes[pane_index] };
                },
                .split => |s| {
                    const split = try allocator.create(PaneTree.Split);
                    splits.appendAssumeCapacity(split); // capacity 예약됨 — 무실패 추적(create↔추적 사이 누수 없음)
                    split.* = .{
                        .direction = s.direction,
                        .ratio = split_tree.clampRatio(@as(f32, @floatFromInt(s.ratio_milli)) / 1000.0),
                        .a = try buildTreeNode(allocator, panes, nodes, idx, splits, used),
                        .b = try buildTreeNode(allocator, panes, nodes, idx, splits, used),
                    };
                    return .{ .split = split };
                },
            }
        }
    };
}

// 이식성 증거: 진짜 `TermRuntime`(PTY/렌더 핸들) 없이 빈 fake `Rt`로 모델을 인스턴스화해 Term/Pane/Tab/
// split 트리를 헤드리스로 구성·조회할 수 있어야 한다. 이게 가능하면 모델이 OS/런타임에 결합하지 않았다는
// 뜻이고(Linux 등 다른 타깃이 같은 모델을 재사용), S2-4b 추출이 의도대로 됐음을 증명한다.
test "session model: 헤드리스 — fake Rt로 Term/Pane/Tab/PaneTree 구성(PTY·surface 없이)" {
    const FakeRt = struct {}; // PTY/OS 핸들 0 — platform의 TermRuntime을 대신하는 빈 런타임.
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    // Term을 PTY 없이 만든다(surface는 undefined로 두고 모델 메타만 단언 — 모델은 런타임을 모른다).
    var t1: M.Term = .{ .agent_kind = .claude };
    try std.testing.expectEqual(AgentKind.claude, t1.agent_kind);
    try std.testing.expectEqual(@as(usize, 0), t1.agent_answer_len);
    try std.testing.expectEqual(agent_transcript.AgentState.unknown, t1.agent_state);

    // Pane이 *Term을 가로 탭으로 들고 activeTerm을 반환한다.
    var pane: M.Pane = .{};
    defer pane.terms.deinit(allocator);
    try pane.terms.append(allocator, &t1);
    try std.testing.expectEqual(&t1, pane.activeTerm());

    // PaneTree(split 트리)가 *Pane leaf로 구성된다 — surface/PTY 없이 레이아웃 모델만(split_tree 위임).
    var p2: M.Pane = .{};
    var split = M.PaneTree.Split{ .direction = .horizontal, .a = .{ .leaf = &pane }, .b = .{ .leaf = &p2 } };
    const root: M.PaneTree.Node = .{ .split = &split };
    try std.testing.expectEqual(@as(usize, 2), M.PaneTree.leafCount(root));

    // Tab이 트리를 들고 activePane/activeTerm을 반환한다.
    var tab: M.Tab = .{ .tree = root };
    defer tab.panes.deinit(allocator);
    try tab.panes.append(allocator, &pane);
    try std.testing.expectEqual(&pane, tab.activePane());
    try std.testing.expectEqual(&t1, tab.activeTerm());
}

// workspace 직렬화 변환(flattenTree→buildTreeNode)이 라이브 트리를 PTY/surface 없이 round-trip한다.
// 저장(라이브→TreeNode)·복원(TreeNode→라이브)이 session core에서 pure하게 닫힘을 증명한다(S2-5).
test "session model: workspace 트리 round-trip(flattenTree→buildTreeNode, fake Rt)" {
    const FakeRt = struct {};
    const M = Model(FakeRt);
    const allocator = std.testing.allocator;

    var pane0: M.Pane = .{};
    var pane1: M.Pane = .{};
    defer pane0.terms.deinit(allocator);
    defer pane1.terms.deinit(allocator);
    var split = M.PaneTree.Split{ .direction = .vertical, .ratio = 0.4, .a = .{ .leaf = &pane0 }, .b = .{ .leaf = &pane1 } };

    var tab: M.Tab = .{ .tree = .{ .split = &split } };
    defer tab.panes.deinit(allocator);
    try tab.panes.append(allocator, &pane0);
    try tab.panes.append(allocator, &pane1);

    // 라이브 트리 → preorder TreeNode 리스트([split, leaf0, leaf1]).
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    var nodes: std.ArrayList(workspace.TreeNode) = .empty;
    try M.flattenTree(arena_inst.allocator(), &tab, tab.tree, &nodes);
    try std.testing.expectEqual(@as(usize, 3), nodes.items.len);

    // TreeNode 리스트 → 라이브 트리 복원(leaf 인덱스→panes[i], split 새 노드).
    const panes = [_]*M.Pane{ &pane0, &pane1 };
    var splits: std.ArrayList(*M.PaneTree.Split) = .empty;
    defer {
        for (splits.items) |sp| allocator.destroy(sp);
        splits.deinit(allocator);
    }
    try splits.ensureTotalCapacity(allocator, 1);
    var used = [_]bool{ false, false };
    var idx: usize = 0;
    const root = try M.buildTreeNode(allocator, &panes, nodes.items, &idx, &splits, &used);
    try std.testing.expectEqual(@as(usize, 2), M.PaneTree.leafCount(root));
    try std.testing.expect(std.meta.activeTag(root) == .split);
}
