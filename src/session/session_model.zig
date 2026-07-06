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
const surface_mod = @import("surface.zig");
const split_tree = @import("split_tree.zig");
const agent_transcript = @import("agent_transcript.zig");
const workspace = @import("workspace.zig"); // OS-중립 직렬화 모델(session.workspace.v1) — TreeNode 변환용

const Surface = surface_mod.Surface;

/// Term 포그라운드에서 도는 에이전트 CLI 종류. 사이드바에 심볼로 표시(claude=✶, codex=◆).
/// platform이 PTY proc_name 폴링(pollAgentKinds)으로 채우는 파생값이고, 모델은 라벨 표시에만 쓴다.
pub const AgentKind = enum(u8) { none = 0, claude, codex };

/// idle 에이전트 답변 미리보기(여러 줄 평탄화 — copyPreviewFlattened)를 담는 inline 버퍼 길이(alloc 회피 —
/// 사이드바는 폭에 맞춰 다시 말줄임, 알림 본문은 더 많이 보임). 알림 배너 ~2줄을 채우게 256으로 둔다.
pub const agent_answer_max: usize = 256;

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
            /// syncAutoTitles가 마지막으로 auto_title에 반영한 core.title_generation(P4-1). 코어의 현재 generation과 같으면
            /// 제목/cwd가 안 바뀐 것이라 lock+복사를 건너뛴다(매 tick 전-Term lock 제거 — docs/io-render-threading.md §12).
            /// 0=아직 미반영(초기 windowTitle이 빈 상태와 일치 — 코어 title/cwd가 세팅돼야 generation이 ≥1로 오른다).
            last_title_gen: u32 = 0,
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
            /// 사이드바 카드 좌측 accent 막대색(0xRRGGBB, 0=기본 — 활성 카드는 테마 앰버, 비활성은 막대 없음).
            /// 지정하면 활성·비활성 카드 모두 그 색으로 막대 표시(배경 tint와 직교). workspace.v1 영속.
            accent_color: u32 = 0,
            /// 사이드바 그룹 **시작 마커**(위치 파생 소속 — docs/sidebar-groups.md §2.1). null=그룹 시작 아님
            /// (자기 위 가장 가까운 마커에 소속되거나, 위에 마커가 없으면 최상위). 소속 자체는 저장하지 않고
            /// self.tabs 순서에서 파생한다 — 이 필드는 "이 탭부터 이 이름의 그룹 시작"만 든다. owned(destroyTab 해제).
            group_start: ?[]const u8 = null,
            /// group_start!=null일 때만 의미 — 그 그룹이 접혔는지(영속). 검색 활성 동안은 projectRows가 일시 무시.
            group_collapsed: bool = false,
            /// 중첩 그룹 깊이 레벨(SG5-3 — docs/sidebar-groups.md §9). group_start!=null일 때만 의미: 1=최상위 그룹,
            /// 2=그 안 중첩, … 소속과 마찬가지로 **정규화 depth는 위치에서 파생**(projectRows가 스택으로 재계산·클램프)하고
            /// 이 필드는 "이 마커가 얼마나 깊이 들어가려는가"의 힌트다. 최상위에서 create_group=1, 그룹 안에서=그 카드
            /// depth+1. workspace.v1 영속(group-depth, 기본 1=키 생략). 기본 1(비마커 탭에선 무의미).
            group_depth: u8 = 1,
            /// 사이드바 그룹 공통 색(0xRRGGBB, 0=색 없음/기본 폴백 — docs/sidebar-groups.md §9 SG5-2). group_start!=null일
            /// 때만 의미 — 그룹 시작 마커 **하나에만** 저장하고, 소속 카드는 위치 파생으로 그 색을 따른다(별도 저장 없음,
            /// §2.1 위치 파생과 동형). 헤더 밴드 tint·소속 카드 좌측 accent 막대에 실린다. 개별 카드 background_color와는
            /// 다른 층(그룹 색=헤더+막대, 카드 배경=별도 tint)이라 서로 안 덮는다. workspace.v1 영속(group-color). 기본 0.
            group_color: u32 = 0,
            /// 그룹-로컬 pin(GL — docs/sidebar-groups.md §13). 이 카드가 **자기 그룹 subtree 안에서** 위로(마커 직후)
            /// 고정됐는가(그룹 안 leaf 멤버 전용). 전역 핀(Tab.pinned = [고정][비고정] 리전, §12)과 **직교하는 별개 축**이다:
            /// pinned=전역 프리픽스, local_pinned=한 그룹 subtree [marker, end) 내부 순서. group_start!=null(마커)·top-level
            /// 카드에선 무의미(마커=그룹 고정 권위·top카드=개별 pin은 Tab.pinned가 든다). **전역 파티션 머신**
            /// (countPinnedTabs·stablePartitionPinned·clampMoveToGroup·normalizePinnedFromGroups)은 이 필드를 **안 읽는다**
            /// — 멤버 pinned를 재해석하면 전역 partition이 그룹을 shred(C3)하므로 새 필드로 격리한다(§13). stablePartitionSubtree만
            /// 이 값으로 subtree 내부를 물리 재배열한다. workspace.v1 영속(local-pinned, 기본 false=키 생략). destroyTab 무관(스칼라).
            local_pinned: bool = false,
            /// §2.1 재설계 서브파티션 마커(docs/sidebar-groups.md §14). 한 핀 리전 **안**에서 이 카드가 **최상위(depth 0)로
            /// 복귀**하는 지점 = 앞 그룹 리전을 끝내는 리딩 break 신호(pin 플립과 동형의 두 번째 리셋 신호). 위치 파생 소속을
            /// **override**: 이 카드는 depth 0(top-level)이고 depth 스택을 비우며, 뒤 비마커 카드는 sticky-reset으로 빈 스택을 타
            /// 다음 마커 전까지 자동 top-level이다(§2.1 위치 파생을 서브파티션으로 일반화 — pin ⊃ subregion(top_level) ⊃ group ⊃
            /// nest). group_start==null(비마커)·leaf 카드 전용(마커의 형제 top-level 그룹은 group_depth=1 pop으로 표현하므로
            /// 마커엔 세팅 금지, local_pinned §13.8 선례). 전역 파티션과 직교(핀 프리픽스 I1 불변 — top_level은 항상 한 핀 리전
            /// 안의 안쪽 파티션). 소속·depth는 저장하지 않고 위치에서 파생하며(§2.1) 이 필드는 "여기서 그룹 리전 끝, 최상위 복귀"만
            /// 든다. workspace.v1 영속(top-level, 기본 false=키 생략 → 전 탭 false면 7 파생 경계 리셋/break가 no-op = byte-identical).
            /// destroyTab 무관(스칼라). SR1은 저장+파생 토대만 — 배선(createGroup write·드래그 전이·normalize 재작성)은 SR2~5.
            top_level: bool = false,

            /// 포커스된 panel. pane 내부(Term/surface) 접근에 쓴다. 탭은 항상 panel ≥1.
            pub fn activePane(self: *Tab) *Pane {
                return self.panes.items[self.active_pane];
            }
            /// 포커스된 panel의 활성 Term(탭 대표 surface).
            pub fn activeTerm(self: *Tab) *Term {
                return self.activePane().activeTerm();
            }
        };

        // ── workspace 직렬화 변환(PaneTree ↔ session.workspace.TreeNode) ──────────────────────────────────
        // 라이브 split 트리(세션 모델)와 직렬화 모델(session.workspace.v1) 사이의 pure 변환. PTY/렌더 없이
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

        // ── pane hit-test / 방향 탐색(순수, 레이아웃 rect 기반) ──────────────────────────────────────
        // 마우스 클릭 panel·키보드 방향 이동 대상을 split 레이아웃 rect로만 고른다(self/OS 무관). platform이
        // termRect로 layout해 leaf_rects를 만들어 넘긴다 — divider/sidebar hit-test가 chrome인 것과 같은 결로,
        // pane 선택은 session 모델 연산이다.

        /// 키보드 pane 이동 방향(좌/우/상/하). split 탭에서 활성 panel 기준 인접 panel을 고른다.
        pub const FocusDirection = enum { left, right, up, down };

        /// 레이아웃 rect들에서 (x_px,y_px)를 담는 panel을 hit-test([x,x+w)×[y,y+h) 반열린). 비유한/밖이면 null.
        /// 순수 함수(레이아웃 rect만 입력) — OS 무관.
        pub fn paneAtPoint(leaf_rects: []const PaneTree.LeafRect, x_px: f64, y_px: f64) ?*Pane {
            if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
            for (leaf_rects) |lr| {
                const x0: f64 = @floatFromInt(lr.rect.x);
                const y0: f64 = @floatFromInt(lr.rect.y);
                if (x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(lr.rect.w)) and
                    y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(lr.rect.h)))
                {
                    return lr.leaf;
                }
            }
            return null;
        }

        /// 활성 panel에서 dir 방향 가장 가까운 인접 panel(없으면 null). panel rect 중심 비교 — 방향 반평면 안
        /// 후보 중 주축거리 + 부축어긋남×2(정렬 우대) 최소. 순수 함수 — OS 무관.
        pub fn paneInDirection(leaf_rects: []const PaneTree.LeafRect, active_pane: *Pane, dir: FocusDirection) ?*Pane {
            var active_rect: ?split_tree.Rect = null;
            for (leaf_rects) |lr| {
                if (lr.leaf == active_pane) {
                    active_rect = lr.rect;
                    break;
                }
            }
            const ar = active_rect orelse return null;
            const acx = @as(f64, @floatFromInt(ar.x)) + @as(f64, @floatFromInt(ar.w)) / 2.0;
            const acy = @as(f64, @floatFromInt(ar.y)) + @as(f64, @floatFromInt(ar.h)) / 2.0;
            var best: ?*Pane = null;
            var best_score: f64 = std.math.inf(f64);
            for (leaf_rects) |lr| {
                if (lr.leaf == active_pane) continue;
                const cx = @as(f64, @floatFromInt(lr.rect.x)) + @as(f64, @floatFromInt(lr.rect.w)) / 2.0;
                const cy = @as(f64, @floatFromInt(lr.rect.y)) + @as(f64, @floatFromInt(lr.rect.h)) / 2.0;
                const dx = cx - acx;
                const dy = cy - acy;
                const in_dir = switch (dir) {
                    .left => dx < 0,
                    .right => dx > 0,
                    .up => dy < 0,
                    .down => dy > 0,
                };
                if (!in_dir) continue;
                const primary: f64 = switch (dir) {
                    .left, .right => @abs(dx),
                    .up, .down => @abs(dy),
                };
                const secondary: f64 = switch (dir) {
                    .left, .right => @abs(dy),
                    .up, .down => @abs(dx),
                };
                const score = primary + 2.0 * secondary; // 부축 정렬(같은 행/열)을 우대
                if (score < best_score) {
                    best_score = score;
                    best = lr.leaf;
                }
            }
            return best;
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

// pane hit-test/방향 탐색이 레이아웃 rect만으로(self/OS 없이) 동작 — 마우스 pane 전환·키보드 pane 이동의
// 기하 코어. leaf는 pointer-identity만 쓰므로 빈 Pane 더미로 충분하다.
test "session model: paneAtPoint 헤드리스 hit-test(레이아웃 rect만, fake Rt)" {
    const M = Model(struct {});
    var a: M.Pane = .{};
    var b: M.Pane = .{};
    // 좌우 2-panel: a=[0,100)×[0,200), b=[100,200)×[0,200).
    const rects = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&a, M.paneAtPoint(&rects, 50, 100).?);
    try std.testing.expectEqual(&b, M.paneAtPoint(&rects, 150, 100).?);
    try std.testing.expectEqual(&a, M.paneAtPoint(&rects, 0, 0).?); // 좌상단 경계 포함
    try std.testing.expectEqual(&b, M.paneAtPoint(&rects, 100, 0).?); // x=100 경계는 b(반열린)
    try std.testing.expect(M.paneAtPoint(&rects, 200, 0) == null); // 오른쪽 밖
    try std.testing.expect(M.paneAtPoint(&rects, 50, 200) == null); // 아래 밖
    try std.testing.expect(M.paneAtPoint(&rects, std.math.nan(f64), 5) == null); // 비유한
}

test "session model: paneInDirection 헤드리스 방향 탐색(반평면+정렬, fake Rt)" {
    const M = Model(struct {});
    var a: M.Pane = .{};
    var b: M.Pane = .{};
    var c: M.Pane = .{};
    var d: M.Pane = .{};

    // 좌우 2-panel: a 왼쪽, b 오른쪽.
    const lr = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&b, M.paneInDirection(&lr, &a, .right).?);
    try std.testing.expectEqual(&a, M.paneInDirection(&lr, &b, .left).?);
    try std.testing.expect(M.paneInDirection(&lr, &a, .up) == null); // 좌우 split이라 위/아래 없음
    try std.testing.expect(M.paneInDirection(&lr, &c, .left) == null); // 활성 panel이 leaf에 없음

    // 2×2 격자: a=좌상, b=우상, c=좌하, d=우하. 정렬(같은 행/열) 우대.
    const grid = [_]M.PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &c, .rect = .{ .x = 0, .y = 100, .w = 100, .h = 100 } },
        .{ .leaf = &d, .rect = .{ .x = 100, .y = 100, .w = 100, .h = 100 } },
    };
    try std.testing.expectEqual(&b, M.paneInDirection(&grid, &a, .right).?); // a→우: b(같은 행)
    try std.testing.expectEqual(&c, M.paneInDirection(&grid, &a, .down).?); // a→하: c(같은 열)
    try std.testing.expectEqual(&d, M.paneInDirection(&grid, &b, .down).?); // b→하: d
    try std.testing.expectEqual(&c, M.paneInDirection(&grid, &d, .left).?); // d→좌: c(같은 행)
}
