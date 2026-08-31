//! 소스 컨트롤 도크의 **호스트 배선**(component ↔ AppSession).
//!
//! `session/scm_view.zig`의 행 모델을 component props로 투영하고, 만들어진 tree를 그리고, 포인터를
//! 그 tree로 라우팅한다. Session Dock(`agent_dock.zig`)과 **같은 경로**를 쓴다 — 두 도크 뷰가 서로 다른
//! 배선을 가지면 같은 컬럼에서 뷰를 갈아 끼울 때 스크롤·호버·히트테스트 규칙이 갈린다.
//!
//! **여기서 행 높이를 다시 곱하지 않는다.** 기하의 단일 출처는 component의 `DockMetrics`이고, 이 파일은
//! 그 값을 스크롤 투영에 그대로 넘긴다(옛 셀 그리드 경로가 갈려서 "그린 자리와 눌리는 자리"가 어긋났다).

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const CollectedPane = AppSession.CollectedPane;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const metal_frame = app_session_mod.metal_frame;
const terminal = maru.terminal; // Page/Home/End 키 이벤트 타입
const dock_ops = @import("dock.zig");
const git_ops = @import("git.zig");
const scroll_ops = @import("scroll.zig"); // 목록 스크롤 상한(스크롤바 기하의 max_offset)
const term_ops = @import("term.zig"); // 명령 주입 대상(활성 터미널) 판정 — P6b
const settings_ops = @import("settings.zig"); // 컨텍스트 메뉴 열고 닫기(브랜치 메뉴와 같은 장치)
const agent_dock = @import("agent_dock.zig");
const scm_view = app_session_mod.scm_view;
const scm_row_capacity = app_session_mod.scm_row_capacity;
const git_backend_mod = app_session_mod.git_backend_mod;
const git_write_command = app_session_mod.git_write_command;
const text_area = chrome.components.text_area;
const text_field = chrome.components.text_field;
const redact = maru.redact;

const component = chrome.components.scm_dock;
/// 행 모델 → 컴포넌트 항목. **최상위 중립 leaf 다** — `session` 과 `chrome` 이 서로를 import 할 수
/// 없어 이 변환이 둘 다 밖에 산다(`src/scm_items.zig` 머리말). Windows 표면이 같은 것을 쓴다.
const scm_items = maru.scm_items;

/// 도크가 그릴 **backing 스케일**. **Session Dock과 같은 값**을 쓴다 — 같은 컬럼의 두 뷰가 다른 축으로
/// 커지면 뷰를 갈아 끼울 때 행 높이가 튄다(docs/editor-surface-dock.md §3.5).
///
/// **`agentSessionDockUiZoomMilli`가 아니라 `agentSessionDockScaleMilli`다**(사용자 보고 2026-08-18).
/// 앞의 것은 **UI zoom만**(폰트 비율)이고, `DockMetrics.resolve`·`typography`가 받는 것은 **backing
/// 스케일 × zoom**이다(`ui/spacing.zig`: "resolves logical steps once at backing scale"). zoom만 주면
/// Retina(backing 2000)에서 이 도크의 모든 치수가 **절반**이 되고, 글리프는 실제 장치 스케일로 래스터돼
/// 글자가 뭉개져 보인다 — 1x 화면(캡처 하니스 포함)에서는 두 값이 같아 **증상이 아예 안 나타난다**.
pub fn scmDockScaleMilli(self: *const AppSession) u32 {
    return agent_dock.agentSessionDockScaleMilli(self);
}

/// 스크롤 투영의 항목 열. 높이는 component가 정하고(`DockMetrics.itemHeight`) 이 구조체는 그 함수를
/// 인덱스로 부를 수 있게만 감싼다.
pub const ScrollItems = struct {
    items: []const component.types.Item,
    metrics: component.types.DockMetrics,

    pub fn heightPx(self: ScrollItems, index: usize) u32 {
        if (index >= self.items.len) return 0;
        return self.metrics.itemHeight(self.items[index]);
    }

    pub fn extent(self: ScrollItems, viewport_h_px: u32) chrome.ui.scroll_area.Extent {
        return .{ .count = self.items.len, .gap_px = 0, .viewport_h_px = viewport_h_px };
    }
};

/// 목록 뷰포트 높이 = 도크 content에서 고정 chrome(탭 줄·커밋 줄·요약 줄·브랜치 줄)을 뺀 것.
/// 커밋 상자가 **한 줄에 담는 열 수**. 랩 계산의 단일 출처는 `DockMetrics.commitViewCols`이고,
/// host와 view가 **같은 상자 폭**으로 그것을 부른다 — 폭이 갈리면 상자 높이와 실제 줄 수가 어긋난다.
///
/// 상자 폭은 도크 content 폭 그대로다(커밋 줄에는 좌우 여백이 없다 — 사용자 결정 2026-08-16).
fn commitViewCols(self: *const AppSession) u16 {
    const content = dock_ops.dockGeometry(self).tree_content;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    // **상자는 이제 목록 줄이다**(②b) — 스크롤 영역이 오른쪽에 스크롤바 자리를 비우면(gutter) 줄 폭은
    // content 폭이 아니다. 여기서 그걸 빼지 않으면 host가 세는 열 수가 view보다 많아져, 상자 높이가
    // 실제 줄 수보다 적게 나오고 마지막 줄이 잘린다.
    //
    // **그 자리는 넘칠 때만 생긴다**(2026-08-20). 조건을 여기서 다시 판정하면 같은 폭을 두 곳에서 재는
    // 것이라, 마지막 투영이 정한 값(`scm_list_overflows` — `rememberScrollExtent`가 스크롤 상한과 함께
    // 남긴다)을 읽는다. 그 목록이 곧 지금 화면에 있는 상자와 같은 사실이다.
    const gutter = if (self.scm_list_overflows) m.scrollbar_width + m.scrollbar_inset_x * 2 else 0;
    return m.commitViewCols(@floatFromInt(content.w -| gutter), self.cell_width_px);
}

/// 테스트가 부르는 이름 — host가 **랩에 쓰는 열 수**다. 테스트는 이 값이 발행된 상자 rect에서 나온
/// 열 수와 같은지 본다(그 둘이 갈리면 상자 높이와 실제 줄 수가 어긋난다).
pub fn commitViewColsForTest(self: *const AppSession) u16 {
    return commitViewCols(self);
}

/// 커밋 상자 한 줄의 높이. **`view`와 같은 폴백을 쓴다**(0 → 1000) — `@max(scale, 1)`로 두면 scale이
/// 0인 순간 줄 높이가 1px이 되어 caret rect가 접히는데, 그리는 쪽은 멀쩡히 17px 간격으로 놓는다.
fn commitLineHeightPx(self: *const AppSession) u32 {
    const scale = scmDockScaleMilli(self);
    return chrome.ui.typography.lineHeightPx(.control, if (scale == 0) 1000 else scale);
}

/// 지금 화면에 그릴 **표시 텍스트**. 조합 중이면 본문의 caret 자리에 preedit을 끼운 합성 결과다.
///
/// **component가 합성하지 않는 이유**: props는 빌린 슬라이스이고 component는 할당하지 않는다. 조합
/// 글자를 따로 넘기면 랩·caret 계산이 "본문 기준"과 "합성 기준" 둘로 갈린다 — 조합 중 줄이 넘칠 때
/// 그 차이가 그대로 어긋난 caret이 된다.
fn commitDisplayText(self: *AppSession) []const u8 {
    const field = &self.scm_commit_field;
    if (field.preedit.items.len == 0) return field.text.items;
    self.scm_commit_display.clearRetainingCapacity();
    const caret = @min(field.caret, field.text.items.len);
    self.scm_commit_display.appendSlice(self.allocator, field.text.items[0..caret]) catch return field.text.items;
    self.scm_commit_display.appendSlice(self.allocator, field.preedit.items) catch return field.text.items;
    self.scm_commit_display.appendSlice(self.allocator, field.text.items[caret..]) catch return field.text.items;
    return self.scm_commit_display.items;
}

/// 표시 텍스트 기준 caret 오프셋 — 조합 중이면 **조합 글자 뒤**다(입력기가 그 자리에 다음 글자를 넣는다).
fn commitDisplayCaret(self: *const AppSession) usize {
    const field = &self.scm_commit_field;
    return @min(field.caret, field.text.items.len) + field.preedit.items.len;
}

/// 이미 얻어 둔 표시 텍스트로 세는 판. **`propsFor`가 이것을 쓴다** — 거기서 `commitRows`를 부르면
/// 합성 버퍼를 다시 채우게 되고, 그 프레임의 props가 이미 그 버퍼를 가리키고 있다(같은 내용이라
/// 지금은 무해하지만, 슬라이스를 든 채 그 버퍼를 다시 쓰는 모양 자체가 함정이다).
fn commitRowsOf(self: *AppSession, text: []const u8) u32 {
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const wrapped = text_area.wrap(text, commitViewCols(self), true, &lines);
    return @intCast(text_area.visibleRows(wrapped, commit_max_rows));
}

/// 상자가 자랄 수 있는 상한. 넘으면 세로 스크롤이다 — 상한이 없으면 긴 메시지가 목록을 통째로 밀어낸다.
const commit_max_rows: usize = 8;
/// 랩 결과 버퍼. 상자가 보여 줄 행 수가 아니라 **메시지 전체**의 시각 행 수다(caret이 몇 번째 줄인지
/// 알려면 안 보이는 줄까지 세야 한다).
const commit_wrap_max_rows: usize = 256;

fn listViewportHeightPx(self: *AppSession, has_branch: bool) u32 {
    const content = dock_ops.dockGeometry(self).tree_content;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    // **고정 chrome을 전부 뺀다.** 하나라도 빠뜨리면 목록이 자기 자리보다 크다고 믿고 스크롤 범위가
    // 어긋난다(탭 줄에서 실제로 그랬다).
    //
    // **커밋 줄은 더 이상 고정이 아니다**(②b — 저장소마다 하나씩이라 목록 항목이다). 그것까지 빼면
    // 호스트가 세는 창이 `build`가 세우는 창보다 작아져, 목록 아래쪽이 항목이 있는데도 안 그려지고
    // 스크롤은 끝을 지나 빈 자리로 간다(적대적 4회차).
    // 요약 줄은 히스토리 탭에서 **자리까지** 없다(build가 높이 0으로 세운다) — 여기서도 같이 빼야
    // 호스트가 세는 창과 컴포넌트가 세우는 창이 갈리지 않는다.
    const summary_h: u32 = if (self.scm_tab == .changes) m.summary_h else 0;
    const fixed = m.tab_h + summary_h + if (has_branch) m.branch_h else 0;
    return content.h -| fixed;
}

/// 그 저장소의 행 모델. **활성이면 목록 읽기**(증감까지), 아니면 머리 줄 읽기의 `status` 하나로 만든다
/// (②d — 파일 줄의 실체는 status에서 나오고 numstat은 숫자만 채운다).
fn modelForRepo(self: *AppSession, repo: []const u8, out: []scm_view.Row, scratch: []u8) ?scm_view.Model {
    const current = self.git_repo orelse "";
    if (std.mem.eql(u8, repo, current)) return git_ops.buildScmModel(self, out, scratch);
    const status = repoStatusTextFor(self, repo) orelse return null;
    return scm_view.build(status, "", "", "", self.scm_collapsed, self.scm_expanded, false, out, scratch);
}

/// 지금 목록 읽기가 보고 있는 저장소인가.
fn isCurrentRepo(self: *const AppSession, repo: []const u8) bool {
    const current = self.git_repo orelse return false;
    return std.mem.eql(u8, current, repo);
}

/// 그 저장소의 마지막 `status` 출력(없으면 null). 머리 줄 읽기가 실어 온 그 텍스트다.
fn repoStatusTextFor(self: *const AppSession, repo: []const u8) ?[]const u8 {
    for (self.scm_repo_status.items) |entry| {
        if (!std.mem.eql(u8, entry.path, repo)) continue;
        return if (entry.status_text.len > 0) entry.status_text else null;
    }
    return null;
}

/// 그 저장소에서 지금 강조할 행. **선택은 (저장소, 인덱스) 쌍이다**(②d) — 인덱스만 들면 다른
/// 저장소의 같은 번호 행이 함께 강조된다(모델이 저장소마다 따로 서기 때문).
fn selectedRowIn(self: *const AppSession, repo: []const u8) ?usize {
    const index = self.scm_selected_row orelse return null;
    const selected_repo = self.scm_selected_repo orelse return null;
    return if (std.mem.eql(u8, selected_repo, repo)) index else null;
}

pub const Extent = AppSession.FileTreeScrollExtent;

/// 목록 스크롤 상한. 휠·스크롤바 드래그·클램프가 이 값을 쓰고, **값을 만드는 자리는 투영 하나**다
/// (`rememberScrollExtent`) — 여기서 다시 세지 않는다.
///
/// 예전에는 이 함수가 **변경 사항 탭의 모델을 직접 세어** 상한을 만들었다. 그 값은 두 가지로 틀렸다:
/// ⑴ 히스토리·에이전트 탭의 목록은 출처가 아예 다른데(커밋·턴) 상한만 작업트리에서 왔다 — 작업트리가
/// 깨끗하면 상한이 0이라 그 탭들이 **아예 안 굴러갔고**, 스크롤바도 `max_offset == 0`이면 잡히지 않아
/// 끌 수도 없었다. ⑵ 변경 사항 탭에서도 `model.rows`만 세어 **저장소 머리 줄·커밋 상자·안내 줄**이
/// 빠졌다 — 목록이 실제보다 짧다고 믿으니 끝까지 내려가지지 않았다.
/// **값은 마지막 투영의 것이다** — 투영을 한 번도 안 지났으면 0이고(그리지 않은 목록에는 굴릴 것도
/// 없다), 목록이 바뀌는 순간은 곧 다시 그리는 순간이라 한 프레임 이상 낡지 않는다.
pub fn scrollExtent(self: *AppSession) Extent {
    return self.scm_scroll_extent;
}

/// 이번 투영이 만든 상한을 세션에 남긴다. **목록을 만든 그 자리가 그 목록의 높이를 아는 유일한 자리**라
/// 세 투영(변경 사항·히스토리·에이전트)이 전부 여기를 지난다.
fn rememberScrollExtent(self: *AppSession, scroll: chrome.ui.scroll_area.Projection, viewport_h_px: u32) void {
    self.scm_scroll_extent = .{
        .content_h_px = scroll.content_height_px,
        .viewport_h_px = viewport_h_px,
        .max_offset_px = scroll.max_offset_px,
    };
    // **넘치는가도 같은 자리에서 정한다.** 커밋 상자의 랩 계산이 이 값으로 스크롤바 자리(gutter)를 빼는데,
    // 그 판정을 props를 만드는 쪽에 따로 두면 두 값이 **갈릴 창**이 생긴다 — props는 그리는 프레임에만
    // 지나가고 투영은 포인터 경로에서도 지나가기 때문이다. 같은 `max_offset`에서 나오는 두 사실이므로
    // 한 번에 정한다.
    self.scm_list_overflows = scroll.max_offset_px > 0;
    // raw offset도 그 상한 안으로 당긴다. 발행·렌더는 `scmEffectiveScrollPx`가 매번 유계화하지만 **raw
    // 값은 그대로 남아**, 목록이 다시 길어질 때 그 자리로 튄다(git 결과가 올 때 `clampScmScroll`이
    // 하던 일이고, 이제 상한을 아는 자리가 여기다).
    self.scm_scroll.clamp(scroll.max_offset_px);
}

/// 목록을 못 만들었다 — 상한도 없다. **옛 값을 남기지 않는다**: 남기면 아무것도 안 그린 화면에서
/// 스크롤바가 서고 휠이 먹는다(그 상한은 이미 사라진 목록의 것이다).
fn forgetScrollExtent(self: *AppSession) void {
    self.scm_scroll_extent = .{
        .content_h_px = 0,
        .viewport_h_px = listViewportHeightPx(self, false),
        .max_offset_px = 0,
    };
    self.scm_list_overflows = false; // 목록이 없으면 스크롤바 자리도 없다(빈 띠를 남기지 않는다)
    self.scm_scroll.clamp(0);
}

/// 탭 이름 옆에 붙는 **변경 파일 수**. `git status`가 답하는 작업트리 사실이라 **활성 탭과 무관하다** —
/// 히스토리·에이전트 탭에서 0으로 두면 화면이 "바뀐 것이 없다"고 **거짓말**을 하고, 사용자는 변경 사항
/// 탭을 눌러 보고서야 아니라는 것을 안다(실제 증상이었다).
///
/// **모델을 만들지 않는다.** 이 수를 알려고 `buildScmModel`을 부르면 행마다 numstat 전체를 훑는
/// 비용까지 함께 내는데(285파일·"모두 보기"에서 실측 378µs), 그 숫자는 탭 라벨에 쓰이지 않는다 —
/// 이 자리는 히스토리·에이전트 탭의 **매 프레임 투영**이라 그 차이가 그대로 낭비가 된다. 세는 술어
/// (`belongs`)는 목록과 같은 것을 쓴다(실측 12.8µs — 적대적 검증 4회차).
fn changedFileCount(self: *AppSession) u32 {
    const result = self.git_result orelse return 0;
    return scm_view.changedFileCount(result.status);
}

pub const Projection = struct {
    items: []const component.types.Item,
    scroll: chrome.ui.scroll_area.Projection,
    branch: []const u8,
    ahead: u32,
    behind: u32,
    has_ab: bool,
    /// 아직 push하지 않은 것이 있나(`@{u}` 기준). 기본 브랜치 기준인 위 둘과 **다른 사실**이다.
    /// 히스토리·에이전트 탭은 `branch`가 빈 값이라 브랜치 줄 자체가 없고(높이 0), 그래서 이 값도 그 탭들에선
    /// 쓰이지 않는다 — 기본값 false로 둔다.
    unpushed: bool = false,
    summary: component.types.Summary,
    /// 커밋 버튼을 켤 수 있나 = index에 무언가 올라가 있나. **모델이 status로 판정한 것만 쓴다**
    /// (낙관적으로 추정하지 않는다 — 쓰기 문서 §7).
    has_staged: bool,
    /// 지금 읽은 저장소에 **줄이 하나라도 있나**. 빈 안내는 이 값으로 정한다 — `items`는 이제 저장소
    /// 머리 줄을 포함하므로 그것으로 세면 변경이 없어도 "비어 있지 않다"가 된다(P3d에서 실제로 그랬다).
    has_rows: bool,
    /// 탭 이름 옆의 **전체** 파일 수. 섹션 헤더의 `count`를 더해서 낸다 — 그 값은 접혀 있어도 잘려
    /// 있어도 전체를 말하므로, 화면 행을 세는 것과 달리 10행 상한·접기에 흔들리지 않는다.
    file_count: u32,
};

/// 모델 → 항목 열 + 스크롤 투영. **렌더와 포인터가 같은 함수를 지난다** — 두 곳이 각자 만들면 스크롤한
/// 뒤 누른 행과 열리는 행이 어긋난다.
///
/// 투영이 없으면(모델을 못 만들었다·버퍼가 없다) **스크롤 상한도 버린다** — 그리지 못한 화면에 옛
/// 상한이 남으면 스크롤바가 서고 휠이 먹는다.
pub fn project(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    return projectTab(self, arena) orelse {
        forgetScrollExtent(self);
        return null;
    };
}

fn projectTab(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    // **히스토리 탭은 다른 목록이다**(P4). 같은 스크롤·같은 격자를 쓰지만 행의 출처가 `git log`라
    // 여기서 갈린다 — 두 목록을 한 함수에 섞으면 "이 행이 어느 탭 것인가" 판정이 행마다 생긴다.
    if (self.scm_tab == .history) return projectHistory(self, arena);
    if (self.scm_tab == .agent) return projectAgentTurns(self, arena);

    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return null;

    // 쓰기가 실패했으면 그 사유를 **목록 맨 위 한 줄**로 낸다(§5 — 실패는 사실대로). 별도 배너를 만들지
    // 않는 이유는 이 자리가 이미 "목록이 사실과 다르다"를 말하는 자리(`notice`)이고, 사용자가 방금 누른
    // 동작의 결과를 그 목록 바로 위에서 읽는 것이 자연스럽기 때문이다.
    const notice_rows: usize = if (self.scm_write_error != null) 1 else 0;

    // **저장소 머리 줄이 목록의 첫 층이다**(§3.5.1c). 지금 읽어 둔 저장소의 줄들은 자기 머리 줄 아래에
    // 오고, 아직 안 읽은 저장소는 머리 줄만 선다("읽는 중…" — 배지의 빈자리와 구별한다).
    const repos = repoEntries(self);
    const current_repo = self.git_repo orelse "";

    // **저장소마다 자기 모델을 만든다**(②d). 파일 줄의 실체(경로·그룹·상태 문자·스테이지 동작)는
    // `status` 하나에서 나오므로, 비활성 저장소도 머리 줄 읽기에 실려 온 그 출력으로 줄을 세울 수 있다 —
    // **추가 프로세스가 없다**. `numstat`이 없으니 증감 숫자만 비고, 그 자리를 비우는 길은 이미 있다
    // (`unknown_delta` — 추적되지 않은 파일·충돌이 같은 길을 쓴다).
    const models = arena.alloc(?scm_view.Model, repos.entries.len) catch return null;
    var total_rows: usize = 0;
    for (repos.entries, 0..) |entry, index| {
        models[index] = null;
        if (repoCollapsed(self, entry.path)) continue; // 접힌 그룹은 줄을 만들지 않는다
        if (std.mem.eql(u8, entry.path, current_repo)) {
            models[index] = model;
            total_rows += model.rows.len;
            continue;
        }
        const status = repoStatusTextFor(self, entry.path) orelse continue;
        const rows = arena.alloc(scm_view.Row, scm_row_capacity) catch continue;
        const path_scratch = arena.alloc(u8, std.fs.max_path_bytes) catch continue;
        const built = scm_view.build(
            status,
            "", // numstat 셋은 없다 — 증감은 그 저장소를 열 때 채워진다
            "",
            "",
            self.scm_collapsed,
            self.scm_expanded,
            false,
            rows,
            path_scratch,
        );
        models[index] = built;
        total_rows += built.rows.len;
    }

    // 저장소마다 **커밋 줄 둘**(입력·버튼)과 **빈 안내 한 줄**이 더 붙을 수 있다 — 접힌 저장소는
    // 그것도 없다(②b).
    const items = arena.alloc(component.types.Item, total_rows + notice_rows + repos.entries.len * 4) catch return null;
    var n: usize = 0;
    // **저장소에 매인 사유는 여기 안 선다** — 그 저장소의 커밋 버튼 아래로 간다(아래 `.blocker`).
    // 여기 남는 것은 어느 저장소에도 안 매인 것(원격 갱신 결과 등)이다.
    if (self.scm_write_error) |err| {
        if (self.scm_write_error_repo == null) {
            items[n] = if (self.scm_write_error_blocking) .{ .blocker = err } else .{ .notice = err };
            n += 1;
        }
    }
    var model_start: usize = 0;
    var model_end: usize = 0;
    for (repos.entries, 0..) |entry, repo_index| {
        const is_current = std.mem.eql(u8, entry.path, current_repo);
        const collapsed = repoCollapsed(self, entry.path);
        // 활성 저장소는 목록 읽기가, 나머지는 **머리 줄 읽기**(P3d-③)가 채운다. 둘이 같은 값을 들지
        // 않는다 — 두 곳이 같은 사실을 가지면 어느 쪽이 최신인지 판정이 하나 더 생긴다.
        const summary = if (is_current) null else repoStatusFor(self, entry.path);
        const repo_model = models[repo_index];
        items[n] = .{
            .repo = .{
                .index = @intCast(repo_index),
                .name = repoDisplayName(entry, repos.entries),
                .branch = if (is_current)
                    headLabel(model.head)
                else if (summary) |sum|
                    (if (sum.detached) "(detached)" else sum.branch)
                else
                    "",
                .collapsed = collapsed,
                .primary = entry.primary,
                .count = if (is_current) countFiles(model.rows) else (if (summary) |sum| sum.count else 0),
                // 아직 답이 안 온 저장소만 "읽는 중…"이다 — **0건과 구별해야 한다**.
                .pending = !is_current and summary == null,
                // 읽지 못한 저장소는 그 사실을 적는다(0건으로 그리면 없는 사실을 단정한다).
                .failed = if (summary) |sum| sum.failed else false,
                // **전체 스테이지**는 그 저장소를 읽었고 스테이지할 것이 있을 때만 켠다(②c).
                .can_stage_all = if (repo_model) |rm| hasUnstaged(rm.rows) else false,
            },
        };
        n += 1;
        if (collapsed) continue; // 접힌 그룹은 상자도 파일 줄도 없다

        // **커밋 줄은 그 그룹 안에 산다**(②b). 지금 편집 중인 상자만 편집 상태를 갖고, 나머지는 그
        // 저장소의 **초안 글**을 보여 준다 — 화면에 있는 글이 곧 그 저장소로 커밋될 글이다.
        const focused = if (focusedCommitRepo(self)) |focus| std.mem.eql(u8, focus, entry.path) else false;
        const text = if (focused) commitDisplayText(self) else draftTextFor(self, entry.path);
        items[n] = .{
            .commit_box = .{
                .repo_index = @intCast(repo_index),
                .rows = commitRowsOf(self, text),
                .text = text,
                .edit = if (focused) .{
                    .focused = true,
                    .caret = commitDisplayCaret(self),
                    // 조합 중에는 선택이 없다(입력기가 그 구간을 소유한다) — 남기면 밴드가 조합 글자에 겹친다.
                    .selection = if (self.scm_commit_field.preedit.items.len > 0) null else selectionOf(self.scm_commit_field.selection),
                    .preedit = self.scm_commit_field.preedit.items,
                    .first_row = self.scm_commit_first_row,
                    // **깜빡임 위상은 세션이 소유한다**(component에는 시간이 없다).
                    .caret_visible = self.blink_visible,
                } else .{},
            },
        };
        n += 1;
        items[n] = .{
            .commit_button = .{
                .repo_index = @intCast(repo_index),
                // **실제 index 상태로만** 켠다(§7 — 낙관하지 않는다). 파일 줄이 화면에 있으면 그 판정도
                // 그 저장소의 status에서 나온다(②d) — 무엇을 커밋하는지 화면에 있으므로 막을 이유가 없다.
                .enabled = if (repo_model) |rm| rm.has_staged else false,
                .run = if (is_current) commitRunState(self) else .idle,
            },
        };
        n += 1;

        // **막힌 이유는 그 저장소의 버튼 바로 아래에 선다**(사용자 제보 2026-08-31). 예전에는 목록 맨
        // 위였는데, 아래쪽 워크트리에서 커밋하면 이유가 도크 꼭대기에 떠서 **어느 저장소 얘기인지도
        // 왜 안 됐는지도** 화면에서 안 이어졌다. 방금 누른 버튼 밑이 그 답이 있어야 할 자리다.
        if (self.scm_write_error) |err| blk: {
            if (!self.scm_write_error_blocking) break :blk;
            const owner = self.scm_write_error_repo orelse break :blk;
            if (!std.mem.eql(u8, owner, entry.path)) break :blk;
            if (n >= items.len) break :blk;
            items[n] = .{ .blocker = err };
            n += 1;
        }

        const rows = if (repo_model) |rm| rm.rows else &[_]scm_view.Row{};
        // **변경이 없다는 말은 그 그룹의 줄이다**(②b). 스크롤 영역 위쪽에 그리면 그 자리에 머리 줄이
        // 있어 **글자가 겹친다**(제품 캡처 2026-08-17). 저장소가 여럿이면 "어느 저장소가 비었나"도
        // 그 자리라야 말이 된다.
        if (repo_model != null and rows.len == 0) {
            items[n] = .{ .notice = git_ops.noticeNoChanges() };
            n += 1;
            continue;
        }
        if (is_current and rows.len > 0) {
            model_start = n;
            model_end = n + rows.len;
        }
        const selected = selectedRowIn(self, entry.path);
        for (rows, 0..) |row, index| {
            items[n] = scm_items.itemFor(row, @intCast(repo_index), index, selected, self.scm_collapsed);
            n += 1;
        }
    }
    const item_rows = if (model_start > 0) items[model_start..model_end] else items[n..n];
    applyScmPending(self, model.rows, item_rows);

    const branch: []const u8 = if (model.head.detached)
        "(detached)"
    else
        model.head.branch orelse "";
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const viewport_h = listViewportHeightPx(self, branch.len > 0);
    if (self.scm_commit_reveal) {
        self.scm_commit_reveal = false;
        revealCommitBox(self, items[0..n], m, viewport_h);
    }
    const list_items = ScrollItems{ .items = items[0..n], .metrics = m };
    const scroll = chrome.ui.scroll_area.project(
        list_items,
        ScrollItems.heightPx,
        list_items.extent(viewport_h),
        self.scm_scroll.offset_y_px,
    );
    // **이 목록이 곧 이 탭의 스크롤 상한이다** — 휠·스크롤바가 읽을 값을 여기서 남긴다.
    rememberScrollExtent(self, scroll, viewport_h);
    // **기준은 기본 브랜치다**(§3.5). `status`의 `# branch.ab`는 `@{u}` 기준이라 PR 브랜치에서 늘 `0 0`이고
    // (실측 2026-08-18), 그 숫자를 그대로 그리면 화면이 "차이 없음"이라고 **거짓말**한다. 기본 브랜치 기준
    // 읽기가 성공했으면 그것을 쓰고, 없으면(origin/HEAD가 없는 저장소·unborn) `@{u}` 값으로 돌아간다.
    const ab = defaultBranchAheadBehind(self);
    return .{
        .items = items[0..n],
        .scroll = scroll,
        .branch = branch,
        .ahead = if (ab) |v| v.ahead else model.head.ahead,
        .behind = if (ab) |v| v.behind else model.head.behind,
        .has_ab = ab != null or model.head.has_ab,
        // **`@{u}` 기준 ahead**가 여기 쓰인다(§3.5 — 그 값은 "push 됐는지"를 보여 주는 데만 쓴다).
        // 위 `ahead`/`behind`는 기본 브랜치 기준이라 서로 다른 사실이고, 그래서 개수가 아니라 **점 하나**다.
        .unpushed = model.head.has_ab and model.head.ahead > 0,
        .summary = .{ .added = model.total_added, .removed = model.total_removed },
        .has_rows = model.rows.len > 0,
        .file_count = countFiles(model.rows),
        .has_staged = model.has_staged,
    };
}

/// 편집 중인 상자를 **목록 창 안으로 끌어온다**.
///
/// 상자는 이제 목록 줄이라 창 밖으로 스크롤될 수 있다(②b). 그 상태에서 키를 치면 글자는 들어가는데
/// **화면에는 아무 일도 안 일어난다** — 사용자는 자기가 친 글자가 어디로 갔는지 알 수 없다(상자가
/// 목록에서 사라졌을 때와 같은 종류의 함정이고, 그쪽은 포커스를 뗐다). 여기서는 뗄 이유가 없으므로
/// 창을 옮긴다(편집기가 caret을 따라가는 것과 같은 규율).
fn revealCommitBox(self: *AppSession, items: []const component.types.Item, m: component.types.DockMetrics, viewport_h: u32) void {
    if (viewport_h == 0) return;
    const focus = self.scm_commit_focus_repo orelse return;
    const repos = repoEntries(self);
    var target: ?u32 = null;
    for (repos.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, focus)) target = @intCast(index);
    }
    const repo_index = target orelse return;
    var y: u32 = 0;
    for (items) |item| {
        const height = m.itemHeight(item);
        const is_target = switch (item) {
            .commit_box => |box| box.repo_index == repo_index,
            else => false,
        };
        if (is_target) {
            const bottom = y + height;
            if (y < self.scm_scroll.offset_y_px) {
                self.scm_scroll.offset_y_px = y;
            } else if (bottom > self.scm_scroll.offset_y_px + viewport_h) {
                // 상자가 창보다 크면 **위쪽을 보인다** — caret이 들어가는 첫 줄이 거기다.
                self.scm_scroll.offset_y_px = if (height >= viewport_h) y else bottom - viewport_h;
            }
            return;
        }
        y += height;
    }
}

/// 히스토리 탭의 투영(P4). 커밋 원문 한 덩어리를 행으로 편다.
///
/// **상대 시각은 여기서 만든다** — component에는 시간이 없고, `%ar`는 git의 로케일·문구를 탄다.
/// **활성 세션**의 턴 링(없으면 null). 목록·클릭이 모두 이 자리를 거친다(AT0 — 계약 §6.1).
///
/// 활성 pane 을 옮기면 목록이 통째로 바뀐다 — «세션별» 이라는 말의 정직한 귀결이다. 에이전트가 붙지
/// 않은 Term 이 활성이거나 신원이 없으면(관측 모드) null 이고, 그때 화면은 «관측한 턴이 없다» 를 말한다.
///
/// **`find` 를 쓴다(`ringFor` 가 아니다)** — 그리기만 하는 자리가 맵을 늘리면 안 된다.
fn activeTurnRing(self: *AppSession) ?*const maru.session.turn_snapshot.Ring {
    const identity = git_ops.activeOrLastSessionIdentity(self);
    if (identity.len == 0) return null;
    return self.turn_rings.find(identity);
}

/// 활성 세션의 링이 **밀려나서** 없나. 맵이 최근 세션 신원 몇 개까지만 들기 때문에 생기는 일이고
/// (`turn_snapshot.max_sessions` — `/clear` 도 새 신원을 만든다), 그때 「관측한 턴이 없다」고 말하면
/// 있었던 기록을 없었던 것처럼 만든다. **링이 아예 없을 때만** 묻는다 — 링이 다시 섰으면 그쪽이
/// `history_evicted` 로 답한다(맵의 자취는 그때 지워진다).
fn activeTurnRingEvicted(self: *AppSession) bool {
    const identity = git_ops.activeOrLastSessionIdentity(self);
    if (identity.len == 0) return false;
    return self.turn_rings.wasEvicted(identity);
}

/// 활성 Term 에 **에이전트는 붙어 있는데 신원이 없나**. 그 조합이 곧 «훅 모드가 아니다» 다(§6.1).
fn agentPresentWithoutIdentity(self: *AppSession) bool {
    if (!self.surface_initialized) return false;
    const active_id = term_ops.activeSurface(self).id;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                if (term.surface.id != active_id) continue;
                return term.agent_kind != .none and term.agent_transcript.identity().len == 0;
            }
        }
    }
    return false;
}

/// 에이전트 탭의 투영(P5 — §3.5.4). **1급 항목은 턴이다.**
///
/// 링은 **메모리·창 로컬**이라 앱을 껐다 켜면 사라진다 — 빈 목록은 오류가 아니라 "이번 실행에서 관측한
/// 턴이 없다"이고, 안내 문구도 그렇게 쓴다.
fn projectAgentTurns(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));

    var rows_buf: [maru.session.turn_snapshot.capacity]maru.session.turn_snapshot.Ring.TimelineRow = undefined;
    // **한 번만 조회한다** — 행과 «놓친 턴» 이 같은 링을 보므로 두 번 물으면 같은 답을 두 번 계산한다.
    const active_ring = activeTurnRing(self);
    const rows = if (active_ring) |ring| ring.timeline(&rows_buf) else &[_]maru.session.turn_snapshot.Ring.TimelineRow{};

    // 펼친 턴의 파일 줄도 목록에 든다(커밋과 같은 규율·같은 슬롯).
    var file_rows: usize = 0;
    if (self.scm_expanded_turn != null) {
        var files = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
        while (files.next()) |_| file_rows += 1;
        if (file_rows == 0) file_rows = 1; // 읽는 중·실패·빈 턴을 한 줄로 말한다
        if (self.scm_commit_files_truncated) file_rows += 1;
        // **셸 고지 한 줄**(AT4 §5). 여기서 안 세면 파일이 있는 턴에서 `n < items.len` 에 걸려
        // **조용히 잘린다** — 그리고 파일이 많은 턴이야말로 그 고지가 필요한 자리다.
        // 실제로 붙일지는 아래에서 정하므로 **넉넉히 하나**만 잡는다(안 붙으면 배열이 한 칸 남을 뿐이다).
        file_rows += 1;
    }
    const notice_rows: usize = if (rows.len == 0) 1 else 0;
    // **놓친 턴은 목록이 비어 있든 아니든 말한다** — 그 사실이 목록의 완전성을 좌우한다.
    const missed = if (active_ring) |ring| ring.missed else 0;
    const missed_rows: usize = if (missed > 0) 1 else 0;
    // **밀려난 기록도 목록이 비어 있든 아니든 말한다** — 바로 위와 같은 이유다. 링이 다시 섰으면 그 링이
    // 그 사실을 들고 있고(`history_evicted`), 아직 안 돌아왔으면 맵의 자취가 답한다.
    const evicted = if (active_ring) |ring| ring.history_evicted else activeTurnRingEvicted(self);
    // 목록이 비면 **아래 «빈 이유» 가 이 말을 대신한다** — 같은 사실을 두 줄로 내지 않는다.
    const evicted_rows: usize = if (evicted and rows.len > 0) 1 else 0;
    // 히스토리 탭과 같은 이유로 동작 결과 줄을 남긴다(P6 — 쓰기는 변경 사항 탭에서 걸지만 **결과는 탭을
    // 따라온다**).
    //
    // **막힌 이유는 따라오지 않는다**(사용자 제보 2026-08-31). 「커밋 메시지를 입력하세요」는 그 상자
    // 옆에서만 뜻이 있는데, 이 탭에는 커밋 상자가 없어 **읽고도 할 수 있는 것이 없다** — 게다가 그 말이
    // 목록 맨 위에 붙어 히스토리를 한 줄 밀어낸다. 「결과는 탭을 따라온다」가 지키려던 것은 *"내가 방금
    // 누른 것이 어떻게 됐나"* 이고, 그것은 **끝난 동작의 결과**(원격 갱신 완료 등)를 말한다.
    const carries_across_tabs = self.scm_write_error != null and !self.scm_write_error_blocking;
    const action_rows: usize = if (carries_across_tabs) 1 else 0;
    const items = arena.alloc(component.types.Item, rows.len + notice_rows + missed_rows + evicted_rows + action_rows + file_rows) catch return null;
    var n: usize = 0;
    if (carries_across_tabs) {
        items[n] = .{ .notice = self.scm_write_error.? };
        n += 1;
    }
    if (missed > 0 and n < items.len) {
        var buf: [48]u8 = undefined;
        const text = maru.i18n.format(&buf, maru.i18n.t(.scm_turns_missed), &.{.{ .d = @intCast(missed) }});
        items[n] = .{ .notice = arena.dupe(u8, text) catch "" };
        n += 1;
    }
    if (evicted_rows > 0 and n < items.len) {
        items[n] = .{ .notice = maru.i18n.t(.scm_turns_evicted) };
        n += 1;
    }
    if (rows.len == 0) {
        // **빈 이유를 구별해 말한다**(적대적 검증 2회차). 관측 모드에서는 이 목록이 영영 안 서는데
        // «이번 실행에서 관측한 턴이 없다» 는 곧 뜰 것처럼 읽혀 고장으로 보인다. 에이전트는 붙어 있는데
        // 신원이 없다 = 훅이 없다는 뜻이므로(계약 §6.1) 그때는 무엇을 해야 하는지 말한다.
        //
        // **밀려난 것도 «없다» 가 아니다**(적대적 검증 5회차). 맵 상한을 넘겨 그 세션이 버려졌으면 기록은
        // 있었는데 사라진 것이라, 같은 문구로 말하면 화면이 없던 일로 만든다.
        items[n] = .{ .notice = if (agentPresentWithoutIdentity(self))
            maru.i18n.t(.scm_turns_need_hooks)
        else if (evicted)
            maru.i18n.t(.scm_turns_evicted)
        else
            maru.i18n.t(.scm_no_turns) };
        n += 1;
    }

    for (rows, 0..) |row, index| {
        if (n >= items.len) break;
        const live = row.head == null;
        // "언제·누가"는 **오른쪽 스냅샷**(그 턴이 끝난 순간)이 든다. 진행 중은 아직 끝나지 않았다.
        const head = row.head;
        items[n] = .{
            .turn = .{
                .index = @intCast(index),
                .title = turnTitle(arena, row.back, live),
                // **순번을 붙이지 않는다**(AT0). 목록이 이미 한 세션 것이라 번호가 가리킬 대상이 없다
                // — `마지막 턴` 이 세션마다 한 줄씩 나오던 문제도 링이 갈리면서 함께 사라졌다.
                .agent = if (head) |snap| agentKindLabel(snap.agent_kind) else "",
                // **턴은 절대 시각이다**(커밋 히스토리는 상대 — `relativeTime`). 근거는 `formatTurnTime`.
                .when = if (head) |snap|
                    (if (snap.captured_s == 0) "" else turnTime(arena, snap.captured_s, now_s))
                else
                    "",
                .summary = if (head) |snap| turnSummary(arena, snap, editedCountFor(self, snap)) else "",
                // **무엇을 했는지**(AT2). 링에는 AT2 부터 실려 있었는데 화면에 올 자리가 없었다.
                .reply = if (head) |snap| snap.titleText() else "",
                .selected = keyMatches(self.scm_selected_turn, row),
                .expanded = keyMatches(self.scm_expanded_turn, row),
                .live = live,
            },
        };
        n += 1;
        if (!keyMatches(self.scm_expanded_turn, row)) continue;

        var row_key_buf: [maru.session.turn_snapshot.max_oid_len * 2 + 2]u8 = undefined;
        const row_key = timelineRowKey(row, &row_key_buf) orelse continue;
        if (!filesLoadedFor(self, row_key) or self.scm_commit_files_failed) {
            if (n < items.len) {
                items[n] = .{ .notice = if (self.scm_commit_files_failed and filesLoadedFor(self, row_key))
                    maru.i18n.t(.scm_turn_files_failed)
                else
                    maru.i18n.t(.scm_loading) };
                n += 1;
            }
            continue;
        }
        if (self.scm_commit_files_truncated and n < items.len) {
            items[n] = .{ .notice = maru.i18n.t(.scm_commit_files_truncated) };
            n += 1;
        }
        var files = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
        var file_index: u32 = 0;
        var any_file = false;
        // **사본은 파일마다가 아니라 한 번 찾는다.** 이 투영은 **매 프레임** 도는데, 파일마다 찾으면
        // 봉인 슬롯(최대 65)을 파일 수만큼 다시 훑고 그 안에서 다시 경로를 최대 256개 비교한다.
        const turn_capture_ref = turnCaptureRef(self, head);
        while (files.next()) |entry| : (file_index += 1) {
            if (n >= items.len) break;
            any_file = true;
            items[n] = .{
                .commit_file = .{
                    .index = file_index,
                    .name = std.fs.path.basename(entry.path),
                    .dir = entry.path[0 .. entry.path.len - std.fs.path.basename(entry.path).len],
                    .status = commitFileStatus(entry.letter),
                    .letter = entry.letter,
                    // 증감은 같은 출력에서 온다(`--raw --numstat`). **읽지 못했으면 자리를 비운다** —
                    // 0/0 은 「안 바뀐 파일」이라는 거짓 진술이다.
                    .added = entry.added,
                    .removed = entry.removed,
                    .binary = entry.binary,
                    .has_delta = entry.has_delta,
                    .selected = self.scm_selected_commit_file != null and self.scm_selected_commit_file.? == file_index,
                    .from_turn = true, // 이 줄을 누르면 `스냅샷 ↔ 스냅샷`이 열린다(커밋과 다른 비교다)
                    .origin = turnFileOrigin(self, turn_capture_ref, entry.path),
                },
            };
            n += 1;
        }
        if (!any_file and n < items.len) {
            items[n] = .{ .notice = maru.i18n.t(.scm_turn_no_files) };
            n += 1;
        }
        // **셸 고지는 파일 행 뒤에 선다**(계약 §5). 그 위 행들이 왜 `·` 인지를 여기서 말한다.
        if (shellNoticeFor(self, arena, head)) |text| {
            if (n < items.len) {
                items[n] = .{ .notice = text };
                n += 1;
            }
        }
    }

    const list_items = ScrollItems{ .items = items[0..n], .metrics = m };
    const viewport_h = listViewportHeightPx(self, false);
    const scroll = chrome.ui.scroll_area.project(
        list_items,
        ScrollItems.heightPx,
        list_items.extent(viewport_h),
        self.scm_scroll.offset_y_px,
    );
    // **이 목록이 곧 이 탭의 스크롤 상한이다** — 휠·스크롤바가 읽을 값을 여기서 남긴다.
    rememberScrollExtent(self, scroll, viewport_h);
    return .{
        .items = items[0..n],
        .scroll = scroll,
        .branch = "",
        .ahead = 0,
        .behind = 0,
        .has_ab = false,
        .summary = .{ .added = 0, .removed = 0 },
        .has_rows = rows.len > 0,
        .file_count = changedFileCount(self),
        .has_staged = false,
    };
}

/// 그 턴 줄이 지금 고른/펼친 것인가. **키는 두 tree**(`<A> <B>`)라 링이 밀려도 같은 턴을 가리킨다.
fn keyMatches(stored: ?[]const u8, row: maru.session.turn_snapshot.Ring.TimelineRow) bool {
    const key = stored orelse return false;
    var buf: [maru.session.turn_snapshot.max_oid_len * 2 + 2]u8 = undefined;
    const made = timelineRowKey(row, &buf) orelse return false;
    return std.mem.eql(u8, key, made);
}

/// 타임라인 행의 키. **진행 중은 오른쪽이 작업트리**라 키가 없다(그 줄은 읽지 않는다).
fn timelineRowKey(row: maru.session.turn_snapshot.Ring.TimelineRow, buf: []u8) ?[]const u8 {
    const head = row.head orelse return null;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ row.base.oid(), head.oid() }) catch null;
}

/// 턴 줄의 제목. **세는 규칙이 곧 화면 문구다** — `마지막 턴 이후`·`마지막 턴`·`N턴 전`.
fn turnTitle(arena: std.mem.Allocator, back: usize, live: bool) []const u8 {
    if (live) return maru.i18n.t(.scm_turn_live);
    if (back == 1) return maru.i18n.t(.scm_turn_last);
    return std.fmt.allocPrint(arena, "{d}{s}", .{ back, maru.i18n.t(.scm_turn_back_suffix) }) catch
        maru.i18n.t(.scm_turn_last);
}

/// 그 턴이 바꾼 파일 수를 사람이 읽을 꼴로. **아직 모르거나 0이면 빈 문자열**이다.
///
/// 0을 그리지 않는 이유: 읽기에 실패한 턴도 0으로 적히기 때문이다(무한 재요청을 막으려고 실패도
/// «읽었다»로 표시한다 — `applyTurnSummary`). «바꾼 것이 없다»와 «못 읽었다»를 한 글자로 구분할 수
/// 없으니 둘 다 조용히 비운다. 실제로 아무것도 안 바꾼 턴은 링이 이미 걸러 낸다(같은 tree 연속이면
/// push 하지 않는다).
/// 그 턴의 셸 고지 한 줄(계약 §5). 없으면 null.
///
/// **두 경우에 줄이 없고, 그 둘은 다른 사실이다:**
///
/// - `shell_calls == 0` — 셸을 **안 썼다**(계약 §5: 「0이면 줄이 사라진다」).
/// - 캡처가 없다(`capture_id == 0`) — 셸을 썼는지 **모른다**. 훅이 없으면 셀 방법이 없다.
///   여기서 「0개」를 그리면 「셸을 안 썼다」는 **거짓**이 된다(`✎ 0` 을 안 그리는 것과 같은 규율).
fn shellNoticeFor(
    self: *AppSession,
    arena: std.mem.Allocator,
    head: ?*const maru.session.turn_snapshot.Snapshot,
) ?[]const u8 {
    const snap = head orelse return null;
    if (snap.capture_id == 0) return null;
    const turn = self.turn_captures.sealedTurn(snap.capture_id) orelse return null;
    if (turn.shell_calls == 0) return null;
    // **여유를 크게 둔다.** `i18n.format` 은 넘치면 **바이트 단위로 자르므로** UTF-8 중간에서 끊겨
    // U+FFFD 가 뜬다. 지금 한국어 문구가 ~110 B 라 128 로는 번역자가 몇 글자만 더해도 깨진다.
    var buf: [256]u8 = undefined;
    const text = maru.i18n.format(&buf, maru.i18n.t(.scm_turn_shell_notice), &.{.{ .d = @intCast(turn.shell_calls) }});
    return arena.dupe(u8, text) catch null;
}

/// 그 파일을 **누가** 바꿨나(계약 §4.2). 목록은 tree 가 만들고 근거는 캡처가 붙인다 — 그 둘을 잇는
/// 유일한 자리다.
///
/// ⚠️ **경로의 모양이 다르다.** 훅은 **절대경로**를 주고(실측 610/610) `git diff --name-status` 는
/// **저장소 상대경로**를 준다. 정규화 없이 맞대면 **하나도 안 맞아 전부 `.turn_change` 로 떨어지는데**,
/// 「배지가 뜬다」만 보는 테스트는 그것을 통과시킨다. 아래 테스트는 **편집한 파일이 `.ai_edit` 인지**를
/// 직접 잰다.
///
/// 「캡처에 있는데 편집 도구 소행이 아님」은 `.turn_change` 다 — `Read` 로 열어 두고 셸로 고친 경우가
/// 그것이고, 그 판정은 `Entry.editedByAgent` 한 자리에 있다.
/// 스냅샷이 가리키는 봉인 사본(없으면 `null`).
///
/// **한 자리에 모아 둔 이유**: 「`capture_id == 0` 은 «모른다»」가 이 기능의 규율인데, 이 해상을
/// 부르는 쪽마다 인라인으로 쓰면 그 규율이 여러 벌로 갈린다. 제품(투영)과 테스트가 **같은 것**을 쓴다.
fn turnCaptureRef(
    self: *AppSession,
    head: ?*const maru.session.turn_snapshot.Snapshot,
) ?*const maru.session.turn_capture.Turn {
    const snap = head orelse return null;
    if (snap.capture_id == 0) return null;
    return self.turn_captures.sealedTurn(snap.capture_id);
}

fn turnFileOrigin(
    self: *AppSession,
    turn: ?*const maru.session.turn_capture.Turn,
    rel_path: []const u8,
) chrome.components.scm_dock.types.TurnFileOrigin {
    const found = turn orelse return .unknown;
    const repo = self.git_repo orelse return .unknown;
    for (found.entries.items) |entry| {
        const entry_rel = maru.session.repo_path.displayRelative(entry.path, repo);
        if (!std.mem.eql(u8, entry_rel, rel_path)) continue;
        return if (entry.editedByAgent()) .ai_edit else .turn_change;
    }
    // 캡처가 있는 턴인데 이 파일이 없다 = 편집 도구가 안 만졌다(셸·사용자·다른 세션).
    return .turn_change;
}

/// 그 스냅샷이 가리키는 사본에서 **에이전트 편집 도구가 실제로 바꾼 파일 수**. 없으면 0.
///
/// `turnSummary` 밖에 두는 이유: 그 함수는 세션 없이 값으로 검증되어야 한다(아래 테스트).
fn editedCountFor(self: *AppSession, snap: *const maru.session.turn_snapshot.Snapshot) u32 {
    if (snap.capture_id == 0) return 0;
    const turn = self.turn_captures.sealedTurn(snap.capture_id) orelse return 0;
    // **캐시를 읽는다** — 이 함수는 턴 행마다 **매 프레임** 돈다. 훑어 세는 `countEdited()` 는
    // 항목마다 `mem.eql` 로 최대 1 MiB 를 비교한다(`turn_capture.Turn.edited_count` 주석).
    return turn.edited_count;
}

fn turnSummary(
    arena: std.mem.Allocator,
    snap: *const maru.session.turn_snapshot.Snapshot,
    edited: u32,
) []const u8 {
    if (!snap.files_known or snap.changed_files == 0) return "";
    var buf: [32]u8 = undefined;
    const text = maru.i18n.format(&buf, maru.i18n.t(.scm_turn_file_count), &.{.{ .d = @intCast(snap.changed_files) }});
    // **두 소스가 한 줄에서 갈린다**(계약 §4.4-3). 왼쪽은 tree 가 세는 «그 턴 구간에 작업트리에서 바뀐
    // 파일» 이라 셸 편집·사용자·다른 세션이 **원리적으로 섞이고**, 오른쪽은 캡처가 세는 «에이전트 편집
    // 도구가 만졌고 실제로 내용이 달라진 파일» 이다. 둘의 차이가 곧 «내 것이 아닌 변경» 이다.
    //
    // ⚠️ **`Read` 를 여기 더하면 안 된다.** 경로를 실은 `PreToolUse` 의 70%가 `Read` 라(실측) 읽기만 한
    // 파일이 «편집» 으로 뜬다. 판정은 `Entry.editedByAgent` 한 자리에 있다.
    //
    // ⚠️ **오른쪽이 왼쪽보다 클 수 있다 — 그리고 그때 펼친 목록과 수가 안 맞는다.** `add -A` 가
    // gitignore 를 지키므로 에이전트가 **무시되는 파일**(`.env`·빌드 산출물·로컬 설정)을 고치면 tree 는
    // 못 보고 캡처는 본다. 그러면 `3개 파일 · ✎ AI 편집 5` 가 뜨는데 펼치면 `✎` 가 **3개뿐**이다 —
    // 목록은 tree 가 만들기 때문이다.
    //
    // **그래도 줄이지 않는다.** 「git 이 3개만 보지만 에이전트는 5개를 고쳤다」는 **사실이고 쓸모 있다** —
    // 수를 tree 에 맞춰 깎으면 그 사실이 사라진다. 두 라벨이 서로 다른 것을 센다고 이미 말하고 있다
    // (`N개 파일` 은 작업트리, `✎ N` 은 편집 도구). 목록이 캡처로 옮겨가면(tree 제거 뒤) 이 어긋남도
    // 함께 사라진다.
    //
    // 0이면 붙이지 않는다 — `files_known` 이 「0과 모름을 가른다」와 같은 규율이다. 캡처가 없는 턴
    // (관측 모드·훅 없는 세션·셸 전용 턴)에서 «✎ 0» 은 «에이전트가 아무것도 안 했다» 로 읽히는데,
    // 우리가 아는 것은 «편집 도구로는 아무것도 안 했다» 뿐이다.
    if (edited == 0) return arena.dupe(u8, text) catch "";
    // 문구는 계약 §4.2 의 배지 이름 그대로다(`✎ AI 편집`). 한글이 들어가는 것은 i18n 게이트의 요구이기도
    // 하다 — 기호만 쓰면 「번역을 빠뜨리고 영어를 복사한 항목」으로 잡힌다(실제로 잡혔다).
    var edited_buf: [48]u8 = undefined;
    const edited_text = maru.i18n.format(&edited_buf, maru.i18n.t(.scm_turn_edited_count), &.{.{ .d = @intCast(edited) }});
    var joined: [96]u8 = undefined;
    const both = std.fmt.bufPrint(&joined, "{s} · {s}", .{ text, edited_text }) catch
        return arena.dupe(u8, text) catch "";
    return arena.dupe(u8, both) catch "";
}

/// 에이전트 종류 라벨(모르면 빈 문자열 — 그 자리를 비운다).
fn agentKindLabel(kind: u8) []const u8 {
    // 값 집합이 갈리면 여기서 컴파일로 걸린다(순수 층은 정수만 받으므로 여기서 되돌린다).
    const parsed: app_session_mod.AgentKind = switch (kind) {
        0 => .none,
        1 => .claude,
        2 => .codex,
        else => return "",
    };
    return switch (parsed) {
        .none => "",
        .claude => "claude",
        .codex => "codex",
    };
}

fn projectHistory(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    // **벽시계다**(`awake`는 부팅 이후 경과라 커밋 시각과 뺄 수 없다 — 그러면 전부 "방금"이 된다).
    const now_s: i64 = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s));
    // 커밋 수를 먼저 센다(할당을 한 번만 하려고). 원문은 세션이 들고 있어 이 프레임 동안 안 바뀐다.
    var count: usize = 0;
    var counting = maru.session.git_log.iterate(self.scm_log_text);
    while (counting.next()) |_| count += 1;

    // 펼친 커밋의 파일 줄도 목록에 든다(P4b).
    var commit_file_rows: usize = 0;
    if (self.scm_expanded_commit != null) {
        var files = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
        while (files.next()) |_| commit_file_rows += 1;
        // 읽는 중이거나 실패면 그 사실을 한 줄로 말한다(빈 자리는 "바꾼 것이 없다"로 읽힌다).
        if (commit_file_rows == 0) commit_file_rows = 1;
        if (self.scm_commit_files_truncated) commit_file_rows += 1;
    }

    const notice_rows: usize = if (count == 0) 1 else 0;
    // **방금 누른 동작의 결과는 탭을 따라와야 한다**(P6). 쓰기를 거는 컨트롤은 전부 변경 사항 탭에 있다
    // — 브랜치 줄은 `branch`가 빈 이 탭에 서지 않으므로 `가져오기`도 여기서는 tree에 **없다**(아래
    // `.branch = ""`). 그래도 이 줄이 필요한 이유는 **커밋한 직후 여기로 옮겨 방금 만든 커밋을 확인하는**
    // 흐름이다: 옮기는 순간 결과가 사라지면 커밋이 됐는지 알 길이 없다.
    //
    // **막힌 이유는 따라오지 않는다**(사용자 제보 2026-08-31). 바로 위 문단이 지키려는 것은 *"커밋이
    // 됐는지"* 이고, 「커밋 메시지를 입력하세요」는 **그 상자 옆에서만** 뜻이 있다 — 이 탭에는 상자가
    // 없어 읽고도 할 수 있는 것이 없고, 목록 맨 위에 붙어 히스토리를 한 줄 밀어낸다.
    const carries_across_tabs = self.scm_write_error != null and !self.scm_write_error_blocking;
    const action_rows: usize = if (carries_across_tabs) 1 else 0;
    // **상한만큼 읽었으면 더 있을 수 있다** — 그때만 "더 보기"를 세운다. 끝까지 읽었는데 세우면
    // 눌러도 아무 일이 없어 고장으로 읽힌다.
    const more_rows: usize = if (count >= self.scm_log_limit) 1 else 0;
    // 출력이 상한에서 잘렸으면 **그 사실을 적는다** — "더 없다"와 "더 못 읽었다"는 다른 사실이다.
    const truncated_rows: usize = if (self.scm_log_truncated) 1 else 0;
    const items = arena.alloc(component.types.Item, count + notice_rows + action_rows + more_rows + truncated_rows + commit_file_rows) catch return null;
    var n: usize = 0;
    if (carries_across_tabs) {
        items[n] = .{ .notice = self.scm_write_error.? };
        n += 1;
    }
    if (count == 0) {
        // 셋을 구별한다: 아직 못 읽음 · 읽었지만 커밋 없음 · 읽기 실패.
        items[n] = .{ .notice = if (self.scm_log_failed)
            maru.i18n.t(.scm_log_read_failed)
        else if (self.scm_log_repo == null)
            maru.i18n.t(.scm_loading)
        else
            maru.i18n.t(.scm_no_commits) };
        n += 1;
    }
    var it = maru.session.git_log.iterate(self.scm_log_text);
    var index: u32 = 0;
    while (it.next()) |commit| : (index += 1) {
        if (n >= items.len) break;
        const expanded = if (self.scm_expanded_commit) |oid| std.mem.eql(u8, oid, commit.oid) else false;
        var refs = maru.session.git_log.refs(commit.refs);
        const first_ref = refs.next();
        // **그리지 않은 나머지를 센다**(§3.5.3 — `+N`으로 접는다). 이름은 안 싣는다: 화면에 못 그릴
        // 문자열을 프레임마다 들고 다닐 이유가 없고, 접힌 이름을 보여 주는 길이 아직 없다.
        var ref_more: u32 = 0;
        while (refs.next()) |_| ref_more +|= 1;
        items[n] = .{
            .commit = .{
                .index = index,
                .subject = commit.subject,
                .author = commit.author,
                // 시각이 0이면 **자리를 비운다**(1970년으로 그리지 않는다).
                .when = if (commit.timestamp == 0) "" else relativeTime(self, arena, now_s - commit.timestamp),
                .short_oid = commit.shortOid(),
                .ref = if (first_ref) |ref| ref.name else "",
                .ref_is_head = if (first_ref) |ref| ref.kind == .head else false,
                .ref_more = ref_more,
                .selected = if (self.scm_selected_commit) |sel| std.mem.eql(u8, sel, commit.oid) else false,
                .expanded = expanded,
            },
        };
        n += 1;
        if (!expanded) continue;

        // 펼친 커밋의 파일 줄. 원문이 아직 없으면 **그 사실**을 한 줄로 말한다.
        if (!filesLoadedFor(self, commit.oid) or self.scm_commit_files_failed) {
            if (n < items.len) {
                items[n] = .{ .notice = if (self.scm_commit_files_failed and filesLoadedFor(self, commit.oid))
                    maru.i18n.t(.scm_commit_files_failed)
                else
                    maru.i18n.t(.scm_loading) };
                n += 1;
            }
            continue;
        }
        var files = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
        var file_index: u32 = 0;
        var any_file = false;
        while (files.next()) |entry| : (file_index += 1) {
            if (n >= items.len) break;
            any_file = true;
            items[n] = .{
                .commit_file = .{
                    .index = file_index,
                    .name = std.fs.path.basename(entry.path),
                    .dir = entry.path[0 .. entry.path.len - std.fs.path.basename(entry.path).len],
                    .status = commitFileStatus(entry.letter),
                    .letter = entry.letter,
                    .added = entry.added,
                    .removed = entry.removed,
                    .binary = entry.binary,
                    .has_delta = entry.has_delta,
                    .selected = self.scm_selected_commit_file != null and self.scm_selected_commit_file.? == file_index,
                },
            };
            n += 1;
        }
        if (self.scm_commit_files_truncated and n < items.len) {
            items[n] = .{ .notice = maru.i18n.t(.scm_commit_files_truncated) };
            n += 1;
        }
        // 읽었는데 파일이 없다 — 빈 커밋(`--allow-empty`)이 실제로 있다.
        if (!any_file and n < items.len) {
            items[n] = .{ .notice = maru.i18n.t(.scm_commit_no_files) };
            n += 1;
        }
    }

    if (truncated_rows == 1 and n < items.len) {
        items[n] = .{ .notice = maru.i18n.t(.scm_list_truncated) };
        n += 1;
    }
    if (more_rows == 1 and n < items.len) {
        items[n] = .load_more;
        n += 1;
    }

    const list_items = ScrollItems{ .items = items[0..n], .metrics = m };
    const viewport_h = listViewportHeightPx(self, false);
    const scroll = chrome.ui.scroll_area.project(
        list_items,
        ScrollItems.heightPx,
        list_items.extent(viewport_h),
        self.scm_scroll.offset_y_px,
    );
    // **이 목록이 곧 이 탭의 스크롤 상한이다** — 휠·스크롤바가 읽을 값을 여기서 남긴다.
    rememberScrollExtent(self, scroll, viewport_h);
    return .{
        .items = items[0..n],
        .scroll = scroll,
        .branch = "",
        .ahead = 0,
        .behind = 0,
        .has_ab = false,
        .summary = .{ .added = 0, .removed = 0 },
        .has_rows = count > 0,
        .file_count = changedFileCount(self),
        .has_staged = false,
    };
}

/// `--name-status`의 상태 문자를 화면 색 종류로. 목록 파일 행과 **같은 표**를 쓴다 — 같은 글자가
/// 두 탭에서 다른 색이면 사용자가 그 색을 못 믿는다.
fn commitFileStatus(letter: u8) component.types.StatusKind {
    return switch (letter) {
        'A', 'C' => .added,
        'D' => .deleted,
        else => .modified, // `M`·`R`·`T`…
    };
}

/// 목록 자리 → 커밋 OID. **지금 원문에서 다시 찾는다** — intent가 든 것은 자리뿐이고, 그 사이 목록이
/// 늘어났을 수 있다(파일 행이 모델 인덱스를 다시 조회하는 것과 같은 규율).
///
/// 반환 슬라이스는 세션이 든 원문을 빌린다(호출자가 곧바로 쓴다).
fn commitOidAt(self: *AppSession, index: u32) ?[]const u8 {
    var it = maru.session.git_log.iterate(self.scm_log_text);
    var i: u32 = 0;
    while (it.next()) |commit| : (i += 1) {
        if (i == index) return commit.oid;
    }
    return null;
}

/// 펼친 커밋의 그 파일 비교를 연다(P4b).
fn openCommitFileDiff(self: *AppSession, index: u32) void {
    const oid = self.scm_expanded_commit orelse return;
    const repo = self.git_repo orelse return;
    // **실린 목록이 그 커밋의 것일 때만 연다**(적대적 검증). 늦게 온 클릭이 다른 항목의 목록에서
    // 같은 번호를 집으면 **엉뚱한 파일**이 열린다 — 그리는 쪽과 같은 불변식을 여기서도 건다.
    if (!filesLoadedFor(self, oid)) return;
    var it = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
    var i: u32 = 0;
    while (it.next()) |entry| : (i += 1) {
        if (i != index) continue;
        // 저장소 밖 경로는 **여는 단계에서** 막는다(목록 행과 같은 심층 방어).
        if (!maru.session.repo_path.isSafeRelative(entry.path)) {
            self.showNoticeKey(.git_path_outside_repo);
            return;
        }
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ repo, entry.path }) catch return;
        git_ops.openCommitDiffTerm(self, repo, abs, entry.path, entry.orig_path, oid);
        self.scm_selected_commit_file = index;
        self.metal_dirty = true;
        return;
    }
}

/// 펼친 턴의 그 파일 비교를 연다(P5). **양쪽 다 tree**라 작업트리를 읽지 않는다 — 그 턴의 결과가
/// 지금 파일 상태와 무관하게 고정된다(§3.5.4가 타임라인을 두 스냅샷 사이로 잡은 이유).
fn openTurnFileDiff(self: *AppSession, index: u32) void {
    const repo = self.git_repo orelse return;
    const key = expandedTurnKey(self) orelse return;
    if (!filesLoadedFor(self, key)) return; // 위와 같은 이유

    const sep = std.mem.indexOfScalar(u8, key, ' ') orelse return;
    const base_tree = key[0..sep];
    const head_tree = key[sep + 1 ..];
    var it = maru.session.git_status.iterateCommitFiles(self.scm_commit_files_text);
    var i: u32 = 0;
    while (it.next()) |entry| : (i += 1) {
        if (i != index) continue;
        if (!maru.session.repo_path.isSafeRelative(entry.path)) {
            self.showNoticeKey(.git_path_outside_repo);
            return;
        }
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ repo, entry.path }) catch return;
        git_ops.openTurnDiffTerm(self, repo, abs, entry.path, entry.orig_path, base_tree, head_tree);
        self.scm_selected_commit_file = index;
        self.metal_dirty = true;
        return;
    }
}

/// macOS libc 의 `struct tm`. **zig 0.16 std 에는 `tm` 도 `localtime_r` 도 없어** 여기서 최소한만 선언한다
/// (`gmtoff`·`zone` 이 붙은 BSD 배치다 — 그 둘이 빠진 선언을 쓰면 `gmtoff` 자리가 어긋난다).
///
/// **이것으로 얻는 것은 오프셋 하나뿐이다.** 날짜·시각 계산은 아래 `formatTurnTime` 이 순수하게 한다 —
/// libc 가 채운 필드를 그대로 화면에 쓰면 그 자리가 테스트 밖으로 나간다(이 파일의 다른 순수 헬퍼와 같은 규율).
const CTm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const i64, result: *CTm) ?*CTm;

/// 그 **시점의** UTC 오프셋(초). 시점마다 구하는 이유는 서머타임이다 — 지금 오프셋 하나로 과거 턴을
/// 환산하면 경계를 넘은 턴이 한 시간 어긋난다. 실패하면 0(UTC)으로 본다: 시각을 안 보여 주는 것보다
/// 낫고, 그 환경에서는 어차피 로컬이 UTC다.
fn utcOffsetAt(unix_s: i64) i64 {
    var tm: CTm = undefined;
    if (localtime_r(&unix_s, &tm) == null) return 0;
    return @intCast(tm.gmtoff);
}

/// 턴이 끝난 **시각**. 오늘이면 `14:32`, 아니면 `08-22 14:32`.
///
/// **왜 상대 표기가 아닌가**(2026-08-23 사용자 결정): 턴 목록에서 알고 싶은 것은 «얼마나 지났나» 가 아니라
/// «언제 것인가» 다. `2턴 전` 옆의 `5분 전` 은 둘 다 상대라 서로를 설명하지 못하고, 특히 같은 저장소에
/// 세션이 여럿이면 «어느 것이 내가 방금 돌린 턴인가» 를 시각으로 짚게 된다. 커밋 히스토리 탭은 그대로
/// 상대 표기를 쓴다 — 몇 달 전 커밋에 `03-14 09:21` 은 오히려 읽기 어렵다.
///
/// ⚠️ **날짜가 붙으면 그 줄의 에이전트 라벨이 밀릴 수 있다.** `turnRow`(view.zig)는 시각을 오른쪽에
/// 먼저 앉히고 남는 폭이 모자라면 라벨을 **통째로 그리지 않는다**. 오늘 턴(`14:32`, 5자)은 옛 `2시간 전`
/// 보다 짧아 오히려 여유가 늘지만, 하루를 넘긴 턴(`08-22 14:32`, 11자)은 좁은 사이드바에서 라벨을
/// 밀어낸다. 링이 메모리·창 로컬이라 그런 턴 자체가 드물고, 그때도 제목(`3턴 전`)은 남는다 —
/// 우선순위를 뒤집는 것은 레이아웃 결정이라 여기서 하지 않는다.
///
/// **순수 함수다.** 오프셋은 호출자가 넘긴다(위 `utcOffsetAt`). 각 시점의 오프셋을 따로 받는 이유도
/// 서머타임이다 — 하나로 합치면 경계를 넘은 턴에서 «오늘» 판정이 틀린다.
fn formatTurnTime(buf: []u8, captured_s: i64, captured_off: i64, now_s: i64, now_off: i64) []const u8 {
    const local = captured_s + captured_off;
    if (local < 0) return ""; // 1970 이전은 그릴 값이 아니다(캡처 시각 0은 호출자가 이미 거른다)
    const day: i64 = @divFloor(local, std.time.s_per_day);
    const secs_in_day: u17 = @intCast(local - day * std.time.s_per_day);
    const hour = secs_in_day / 3600;
    const minute = (secs_in_day % 3600) / 60;

    const now_local = now_s + now_off;
    const now_day: i64 = @divFloor(now_local, std.time.s_per_day);
    if (day == now_day) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch "";
    }

    const year_day = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1, // `day_index`는 0-based다
        hour,
        minute,
    }) catch "";
}

/// 위 순수 함수를 arena 문자열로. 화면 항목이 프레임 동안만 들고 있으므로 arena 로 복사한다.
fn turnTime(arena: std.mem.Allocator, captured_s: i64, now_s: i64) []const u8 {
    var buf: [24]u8 = undefined;
    const text = formatTurnTime(&buf, captured_s, utcOffsetAt(captured_s), now_s, utcOffsetAt(now_s));
    if (text.len == 0) return "";
    return arena.dupe(u8, text) catch "";
}

/// `3시간 전`처럼 사람이 읽는 상대 시각. **arena에 만든다**(프레임 안에서만 쓴다).
///
/// git의 `%ar`를 쓰지 않는 이유: 그 문구는 git의 로케일을 타서 같은 화면 안에서 다른 상대시각 표기와
/// 규칙이 갈린다. 미래 시각(시계가 어긋난 커밋)은 `방금`으로 접는다 — "-3시간 전"은 읽을 수 없다.
///
/// **턴 목록은 이것을 쓰지 않는다**(2026-08-23 — `formatTurnTime` 의 절대 표기로 갔다). 남은 사용처는
/// 커밋 히스토리 탭이다: 몇 달 전 커밋에 `03-14 09:21` 은 오히려 읽기 어렵다.
fn relativeTime(self: *AppSession, arena: std.mem.Allocator, delta_s: i64) []const u8 {
    _ = self;
    // 문구는 `agent_dock`·`notification` 과 **같은 키를 쓴다** — 같은 개념을 세 파일이 각자 적으면
    // 한쪽만 고쳐지는 드리프트가 생긴다(i18n 리터럴 게이트가 이 자리를 잡았다).
    // `i18n.format` 은 할당하지 않으므로 스택 버퍼에 만든 뒤 arena 로 복사한다.
    var buf: [48]u8 = undefined;
    if (delta_s < 60) return maru.i18n.t(.ad_time_now);
    const minutes = @divFloor(delta_s, 60);
    if (minutes < 60) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_minutes), &.{.{ .d = @intCast(minutes) }})) catch "";
    const hours = @divFloor(minutes, 60);
    if (hours < 24) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_hours), &.{.{ .d = @intCast(hours) }})) catch "";
    const days = @divFloor(hours, 24);
    if (days < 30) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_days), &.{.{ .d = @intCast(days) }})) catch "";
    const months = @divFloor(days, 30);
    if (months < 12) return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_months), &.{.{ .d = @intCast(months) }})) catch "";
    return arena.dupe(u8, maru.i18n.format(&buf, maru.i18n.t(.ad_time_years), &.{.{ .d = @intCast(@divFloor(months, 12)) }})) catch "";
}

/// 등폭 face 의 **포인트당 advance**(device px × 1000 / 논리 pt).
///
/// chrome 텍스트는 role 이 정한 고정 point size 로 그려지는데 셀 폭은 사용자 `font.size` 에서 온다.
/// 그 둘이 벌어지면 셀 기반 추정이 열마다 모자라고, 이어 그리는 글자가 앞 글자를 파고든다(실측:
/// `font.size` 12 상당에서 SCM 파일 행의 이름과 경로 꼬리가 붙었다). 비율을 넘겨 컴포넌트가 환산한다.
fn advanceMilliPerPoint(self: *const AppSession) u32 {
    const point_size = self.appearance.font.size;
    if (!(point_size > 0)) return 0;
    // **소수까지 온 advance 를 먼저 쓴다.** 정수 cell 로 비율을 내면 반올림(최대 0.5px)이 그대로 비율에
    // 실려, 열이 늘수록 다시 어긋난다 — 그 근사를 없애려고 native 메트릭에 이 값을 더했다.
    const milli_px: f32 = if (self.glyph_advance_milli_px != 0)
        @floatFromInt(self.glyph_advance_milli_px)
    else if (self.glyph_cell_width_px != 0)
        @as(f32, @floatFromInt(self.glyph_cell_width_px)) * 1000.0
    else
        @as(f32, @floatFromInt(self.cell_width_px)) * 1000.0;
    if (!(milli_px > 0)) return 0;
    const milli = milli_px / point_size;
    if (!(milli > 0)) return 0;
    return @intFromFloat(@round(milli));
}

/// 편집기의 선택을 DTO 값으로 옮긴다. 값 집합이 갈리면 여기서 컴파일로 걸린다.
fn selectionOf(sel: ?text_field.TextField.Selection) ?component.types.Selection {
    const s = sel orelse return null;
    if (s.anchor == s.focus) return null; // 빈 선택은 caret이지 밴드가 아니다
    return .{ .anchor = s.anchor, .focus = s.focus };
}

fn propsFor(self: *AppSession, projection: Projection, window: []const component.types.Item) component.types.Props {
    const content = dock_ops.dockGeometry(self).tree_content;
    // **여기서 합성 버퍼를 다시 채우지 않는다.** 그 글자는 `project`가 이미 만들어 항목에 실었고,
    // 다시 부르면 **이미 넘긴 슬라이스를 뒤에서 건드리는** 모양이 된다(내용이 같아 지금은 무해하지만
    // 그 패턴 자체가 함정이다 — 같은 이유로 한 번 고쳤던 자리다).
    return .{
        .viewport_px = .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(content.w),
            .height = @floatFromInt(content.h),
        },
        .scale_milli = scmDockScaleMilli(self),
        // fade 는 host 가 계산하고 **view 가 paint 시점에** 얹는다 — build(tree)는 모른다(계약 §7).
        .scrollbar_alpha = scroll_ops.dockScrollAreaAlpha(self),
        .cell_width_px = self.cell_width_px,
        // **face 의 포인트당 advance.** 자연 글리프 폭(자간 보정 전)을 터미널 point size 로 나눈 값이다 —
        // 등폭 face 라 advance 는 크기에 비례하므로, 컴포넌트가 role 크기로 곱하면 실제 폭이 나온다.
        // 자간이 든 `cell_width_px` 가 아니라 `glyph_cell_width_px` 를 쓰는 이유: 자간은 **셀 배치 step**
        // 을 좁히는 값이지 글리프가 실제로 차지하는 폭이 아니다(그 구분은 `applyFontSpacing` 이 소유).
        .advance_milli_per_point = advanceMilliPerPoint(self),
        .snapshot_generation = self.scm_dock_snapshot_generation,
        .active_tab = self.scm_tab, // 어느 탭이 활성인지는 세션이 든다(P4)
        // 히스토리에서 `+N -N`은 작업트리의 숫자라 커밋 목록과 관계가 없다 — 0으로 두면 틀린 진술이다.
        // 히스토리·에이전트 탭에서 `+N -N`은 **작업트리의 숫자**라 그 목록과 관계가 없다 — 0으로 두면
        // "바뀐 것이 없다"는 틀린 진술이고, 자리까지 없애야 빈 띠가 안 남는다.
        .show_summary = self.scm_tab == .changes,
        .items = window,
        .scroll_offset_px = projection.scroll.offset_y_px,
        .content_h_px = projection.scroll.content_height_px,
        // 스크롤바가 **실제로 설 때만** 그 자리를 비운다(§3.5 — 빈 띠를 남기지 않는다). 창 높이를
        // 아는 쪽이 여기라 판정도 여기서 한다.
        // **투영이 정한 값을 읽기만 한다**(`rememberScrollExtent`) — 커밋 상자의 랩 계산이 읽는 그 값이라,
        // 여기서 다시 판정하면 host가 세는 줄 수와 view가 그리는 줄 수가 갈릴 수 있다.
        .list_overflows = self.scm_list_overflows,
        .content_first_item_origin_y_px = projection.scroll.first_origin_y_px,
        .branch = projection.branch,
        .ahead = projection.ahead,
        .behind = projection.behind,
        .has_ab = projection.has_ab,
        .unpushed = projection.unpushed,
        // 원격 갱신 버튼(P6). **누를 수 있는가는 저장소 사실이고**(원격이 있나), **도는 중인가는 세션
        // 상태다** — 둘을 한 값으로 합치면 도는 동안 "원격이 없다"로 보인다.
        .fetch = .{
            .enabled = scmHasRemote(self),
            .running = self.scm_fetch_inflight != 0,
        },
        // `∨`는 **fetch와 따로 판정한다**(§3.5). 원격이 없어도 메뉴에는 고를 것이 남는다(비교 기준) —
        // 오히려 `origin/HEAD`가 없는 저장소가 원격 없는 저장소라, fetch에 묶어 두면 이 기능이 가장
        // 필요한 곳에서 열리지 않는다. 아직 못 읽었으면 열지 않는다(그때 아는 것은 "모른다"뿐이다).
        .remote_menu_enabled = self.git_result != null,
        .summary = projection.summary,
        .changed_file_count = projection.file_count,
        // **커밋 줄은 props가 아니라 목록 항목이다**(②b) — 저장소마다 하나씩이라 여기 하나만 실으면
        // "어느 저장소로 커밋하는가"가 화면에서 사라진다. 아래 `display`는 그 항목을 만들 때 쓴다.
        // 읽기는 됐는데 바뀐 것이 없다 — 그 사실을 **문장으로** 말한다. 이 자리를 비워 두면 화면이
        // "아직 못 읽었다"와 똑같아진다(§3.5 빈 상태 표). 다른 두 문장은 목록을 그리기도 전에
        // 나오므로(`git_result == null` 경로) 여기서 고를 것은 이 하나뿐이다.
    };
}

/// 테스트가 렌더 없이 tree를 만들 때 쓰는 표면. 제품 경로(`collectScmDock`)와 **같은 props**를 내므로
/// 테스트가 자기만의 기하를 지어내지 않는다.
pub fn testProps(self: *AppSession, projection: Projection) component.types.Props {
    const start = @min(projection.scroll.first_index, projection.items.len);
    const end = @min(projection.scroll.end_exclusive, projection.items.len);
    return propsFor(self, projection, projection.items[start..end]);
}

/// 한 프레임의 도크 그리기. Session Dock과 같은 순서다: 투영 → tree → view → 배경 quad → 글자.
pub fn collectScmDock(
    self: *AppSession,
    collected: *std.ArrayList(CollectedPane),
    builder: coretext_frame_builder.CoreTextFrameBuilder,
    colors: metal_frame.CellColors,
) void {
    if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
    const content = dock_ops.dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const projection = project(self, arena) orelse return;
    // **가상화**: 화면에 보이는 창만 component에 넘긴다. 그 창의 첫 항목이 어디서 시작하는지는
    // 투영이 답하고, tree가 자식 전체를 그만큼 평행이동한다.
    const start = @min(projection.scroll.first_index, projection.items.len);
    const end = @min(projection.scroll.end_exclusive, projection.items.len);
    const window = projection.items[start..end];
    const props = propsFor(self, projection, window);

    const sizes = component.build.bufferSizes(window);
    const frame = component.build.build(props, .{
        .nodes = arena.alloc(chrome.ui.tree.UiNode, sizes.nodes) catch return,
        .entries = arena.alloc(chrome.ui.tree.RectEntry, sizes.entries) catch return,
        .layout_items = arena.alloc(chrome.ui.layout.Item, sizes.layout_items) catch return,
        .flex_scratch = arena.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch) catch return,
        .child_rects = arena.alloc(chrome.ui.layout.UiRect, sizes.child_rects) catch return,
        .actions = arena.alloc(component.ids.Entry, sizes.actions) catch return,
    }) catch return;

    // paint quad는 published entry 하나당 최대 하나다. 상수로 세면 tree가 자라는 변경마다 조용히
    // 모자라는데, 그 결과가 "그 컴포넌트만 안 그려짐"이 아니라 **도크 전체 정지**다(view가 실패하면
    // 아래 publish까지 못 가서 hit tree가 이전 프레임에 멈춘다 — Session Dock에서 실제로 겪었다).
    // 예산 산술은 **방출하는 쪽(component)**이 소유한다 — 여기서 세면 view가 op을 하나 더할 때마다
    // 조용히 낡고, 그 증상은 도크 전체가 빈 화면이다(실제로 두 번 그랬다).
    const budget = component.view.drawBufferSizes(props, frame.tree.entries.len);
    const ops = arena.alloc(chrome.draw.Op, budget.ops) catch return;
    const runs = arena.alloc(chrome.draw.Run, budget.runs) catch return;
    const text_bytes = arena.alloc(u8, budget.text_bytes) catch return;
    const tokens = self.buildChromeTokens();
    const draws = component.view.view(props, frame, self.scm_dock_interaction, &tokens, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    }) catch return;

    publishScmDockFrame(self, frame, window);

    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, content.x, content.y, &self.gpu_quads, 2);
    const cols: u16 = @intCast(@min(content.w / self.cell_width_px, std.math.maxInt(u16)));
    const rows: u16 = @intCast(@min(content.h / self.cell_height_px, std.math.maxInt(u16)));
    // 등록 아이콘은 셀 경로로, **일반 글자는 measured CoreText 경로**로 간다. 아이콘만 그리면 도크가
    // 배경과 화살표만 있는 빈 카드가 된다(첫 배선에서 실제로 그랬다).
    const icon_dl = chrome_draw_lowering.buildIconTextDrawList(
        self.allocator,
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
    ) catch return;

    const scale = scmDockScaleMilli(self);
    const scroll_origin_y_px = props.content_first_item_origin_y_px;
    // 목록 글자를 자를 뷰포트. **quad 는 tree 의 `effective_clip` 이 자르지만 measured 글자는 이 값이
    // 없으면 아무 데도 안 잘린다** — 그 상태에서 반쯤 스크롤된 첫 행의 라벨이 요약 줄 위에 그려졌다
    // (2026-08-25 사용자가 골든 캡처에서 지적). 사각형의 출처는 컴포넌트 하나다(`build`).
    const scroll_clip: ?metal_frame.ClipPx = blk: {
        const rect = component.build.scrollTextViewport(frame.tree) orelse break :blk null;
        break :blk .{
            .x = content.x +| @as(u32, @intFromFloat(@max(rect.x, 0))),
            .y = content.y +| @as(u32, @intFromFloat(@max(rect.y, 0))),
            .w = @intFromFloat(@max(rect.width, 0)),
            .h = @intFromFloat(@max(rect.height, 0)),
        };
    };
    const base_fingerprint = chrome_draw_lowering.richTextFingerprint(
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
        scroll_origin_y_px,
    );
    // zoom은 같은 셀 메트릭에서도 CoreText point size를 바꾸므로 fingerprint에 함께 접는다.
    const fingerprint = base_fingerprint ^ (@as(u64, scale) *% 0x9e3779b185ebca87);
    if (!app_session_mod.MeasuredTextCache.hit(self.scm_dock_rich_text_cache, fingerprint))
        shapeScmDockText(self, draws.ops, &tokens, fingerprint, scale, scroll_origin_y_px);
    if (self.scm_dock_rich_text_cache) |*cache| {
        if (cache.fingerprint == fingerprint) {
            self.collectMeasuredTextFromCache(
                collected,
                app_session_mod.chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return,
                cache,
                builder,
                scroll_clip,
                .{ .pane = .{
                    .origin_x = content.x,
                    .origin_y = content.y,
                    .colors = colors,
                    .scroll_delta_y_px = @floatFromInt(scroll_origin_y_px - cache.scroll_origin_y_px),
                } },
            );
        }
    }
    self.collectShaped(collected, icon_dl, builder, .{ .pane = .{
        .origin_x = content.x,
        .origin_y = content.y,
        .colors = colors,
    } });
}

/// 이 프레임의 글자를 셰이핑해 캐시에 넣는다. **다음 tick으로 미루지 않는다** — 미루면 그 프레임의
/// 도크가 글자 없는 빈 카드가 된다(Session Dock과 같은 판단).
fn shapeScmDockText(
    self: *AppSession,
    ops: []const chrome.draw.Op,
    tokens: *const chrome.Tokens,
    fingerprint: u64,
    scale_milli: u32,
    scroll_origin_y_px: i32,
) void {
    const chrome_system_text = app_session_mod.chrome_system_text;
    // face는 터미널과 같은 resolved appearance에서 온다 — 같은 화면의 다른 도크 뷰가 사용자 폰트인데
    // 여기만 시스템 UI face면 앱이 폰트 설정을 절반만 따르는 셈이다.
    var request = chrome_system_text.prepareRequest(self.allocator, fingerprint, ops, tokens, self.cell_width_px, .{
        .family = self.appearance.font.family,
        .fallback = self.appearance.font.fallback,
    }) catch return;
    defer request.deinit(self.allocator);
    var unresolved = chrome_system_text.shapeRequest(self.allocator, &request, scale_milli) catch return;
    defer unresolved.deinit(self.allocator);
    const artifact = chrome_system_text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
    app_session_mod.MeasuredTextCache.store(&self.scm_dock_rich_text_cache, self.allocator, fingerprint, artifact, scroll_origin_y_px);
}

/// 히트 tree 발행. 같은 스냅샷에서 같은 tree가 다시 나오는 것은 **교체가 아니다** — 그걸 교체로 치면
/// 방금 누른 행이 AppKit의 mouse-up 전에 취소된다(Session Dock과 같은 판단).
pub fn publishScmDockFrame(self: *AppSession, frame: component.build.Frame, window: []const component.types.Item) void {
    // **그 창의 커밋 상자 자리를 함께 기억한다.** 클릭 → caret 변환이 아직 포커스가 없는 상자의 rect를
    // 알아야 하는데, 상자가 저장소마다 하나씩이라 고정 id가 없다(②b). 발행과 같은 자리에서 적어야
    // 테스트가 제품과 다른 경로로 발행해도 둘이 어긋나지 않는다.
    rememberCommitBoxNode(self, window);
    // **같은 tree가 다시 나왔는가.** 이 판정이 좌우하는 것은 `capture` 하나뿐이다 — 표까지 함께 얼리면
    // **세대만 오른 프레임**에서 표가 옛 세대로 굳고, 그 화면의 클릭이 영영 stale로 거부된다. 히스토리
    // 탭에서 실제로 그랬다: `git status` 결과는 그 목록을 안 바꾸므로(`projectHistory`는 `git log`만 쓴다)
    // tree가 늘 같아 발행이 계속 건너뛰어졌고, 표는 옛 세대에 남았다. **두 관심사를 한 `return`에 묶은
    // 것이 그 버그의 구조였다** — capture 보존과 표 동결은 다른 요구다.
    const replaced = !frameEql(self.scm_dock_entries.items, self.scm_dock_actions.items, frame.tree.entries, frame.actions);
    // 두 저장소를 **먼저** 확보한다. 할당이 실패해도 마지막으로 온전히 그린 hit tree가 남아야 한다.
    self.scm_dock_entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len) catch return;
    self.scm_dock_actions.ensureTotalCapacity(self.allocator, frame.actions.len) catch return;
    self.scm_dock_entries.clearRetainingCapacity();
    self.scm_dock_actions.clearRetainingCapacity();
    self.scm_dock_entries.appendSlice(self.allocator, frame.tree.entries) catch return;
    self.scm_dock_actions.appendSlice(self.allocator, frame.actions) catch return;
    // 기하·action 매핑이 **바뀌었을 때만** 진행 중인 capture를 버린다(같은 tree는 교체가 아니다).
    if (replaced) self.scm_dock_interaction.capture = null;
    // **세대는 여기서 올리지 않는다.** action 표는 그리기 직전의 세대로 태깅되므로, 발행 직후 올리면
    // 그 프레임의 클릭이 전부 stale로 거부된다(테스트가 "행을 눌렀는데 0개 열림"으로 잡았다).
    // 세대는 **목록이 바뀔 때**(새 git 결과·목록 폐기) 올린다 — `git.zig`가 그 지점을 소유한다.
    // 세대가 무효로 만드는 것은 intent가 싣는 **모델 인덱스·목록 자리**이지 화면이 아니라서, 그 기준을
    // 여기로 옮기면 정의와 사용처가 갈린다. 이 함수의 몫은 **그 세대를 표가 따라오게 하는 것**이고,
    // 위의 무조건 갱신이 그 길이다.
}

fn frameEql(
    old_entries: []const chrome.ui.tree.RectEntry,
    old_actions: []const component.ids.Entry,
    new_entries: []const chrome.ui.tree.RectEntry,
    new_actions: []const component.ids.Entry,
) bool {
    if (old_entries.len != new_entries.len or old_actions.len != new_actions.len) return false;
    for (old_entries, new_entries) |old, new| {
        if (old.id != new.id) return false;
        if (old.rect.x != new.rect.x or old.rect.y != new.rect.y) return false;
        if (old.rect.width != new.rect.width or old.rect.height != new.rect.height) return false;
    }
    for (old_actions, new_actions) |old, new| {
        if (!std.meta.eql(old.intent, new.intent)) return false;
    }
    return true;
}

/// 발행된 track·thumb rect로 만든 스크롤바 기하. **그린 것이 곧 잡는 것**이다 — 여기서 비율을 다시
/// 재면 화면의 막대와 손가락이 어긋난다(목록 자신이 이미 그 rect로 그려졌다).
///
/// 막대가 없으면(넘치지 않는 목록) null이고, 그때는 잡을 것도 없다.
fn scmScrollbarGeometry(self: *AppSession) ?chrome.ui.scroll_area.ScrollbarGeometry {
    var track: ?chrome.ui.layout.UiRect = null;
    var thumb: ?chrome.ui.layout.UiRect = null;
    for (self.scm_dock_entries.items) |entry| {
        if (entry.id == component.build.NodeIds.scroll_track) track = entry.rect;
        if (entry.id == component.build.NodeIds.scroll_thumb) thumb = entry.rect;
    }
    const t = track orelse return null;
    const h = thumb orelse return null;
    const max_offset = scroll_ops.scmScrollExtent(self).max_offset_px;
    if (max_offset == 0) return null; // 다 보이면 막대는 거짓 신호다
    return .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .hit_x = t.x,
        .hit_w = t.width,
        .thumb_y = h.y,
        .thumb_h = h.height,
        .max_offset_px = max_offset,
    };
}

/// 스크롤바 위에서 눌렀다 — 드래그를 연다. **thumb인지 track 빈 곳인지 가르는 규칙은
/// `scroll_area.Drag.begin`이 소유한다**(빈 곳이면 그 지점으로 먼저 점프하고, 이어지는 드래그는 옮긴 뒤
/// 기하를 쓴다 — 그래서 눌렀다 그대로 끌 때 위치가 안 튄다). 스크롤바 밖이면 열리지 않는다.
fn beginScmScrollbarDrag(self: *AppSession, local_x: f64, local_y: f64) void {
    const geometry = scmScrollbarGeometry(self) orelse return;
    if (self.scm_scroll_drag.begin(geometry, local_x, local_y)) |jumped| applyScmScrollOffset(self, jumped);
}

/// 드래그 한 걸음. 좌표는 흡수만 하고 **적용은 한 번**이다(같은 프레임의 move 여럿이 한 번으로 접힌다).
///
/// **기하가 바뀌면 끝낸다.** 끄는 동안 목록이 바뀌면(git 결과 도착·저장소 전환) 막대의 자리가 달라지는데,
/// 잡을 때의 기하로 계속 계산하면 손가락과 화면이 어긋난 채 목록이 움직인다. 파일 트리 스크롤바가 같은
/// 이유로 스냅샷을 대조한다(그쪽은 carry verdict, 이쪽은 발행된 rect 비교로 같은 사실을 본다).
fn dragScmScrollbar(self: *AppSession, local_x: f64, local_y: f64) void {
    if (!scmScrollbarSameGeometry(self)) {
        endScmScrollbarDrag(self);
        return;
    }
    self.scm_scroll_drag.absorb(local_x, local_y);
    if (self.scm_scroll_drag.takeOffset()) |offset| applyScmScrollOffset(self, offset);
}

/// 잡을 때의 track·최대 offset이 지금도 같은가. thumb의 **자리**는 스크롤에 따라 움직이는 값이라 보지
/// 않는다(그걸 보면 자기 드래그가 자기를 취소한다).
fn scmScrollbarSameGeometry(self: *AppSession) bool {
    const live = scmScrollbarGeometry(self) orelse return false;
    const held = self.scm_scroll_drag.geometry;
    return live.track_y == held.track_y and live.track_h == held.track_h and
        live.thumb_h == held.thumb_h and live.max_offset_px == held.max_offset_px;
}

fn applyScmScrollOffset(self: *AppSession, offset_px: u32) void {
    if (offset_px == self.scm_scroll.offset_y_px) return;
    self.scm_scroll.offset_y_px = offset_px;
    self.scm_scroll.dropWheelResidue(); // 위치가 확정됐다 — 가는 도중이던 휠 잔여는 뜻이 없다
    self.metal_dirty = true;
}

pub fn endScmScrollbarDrag(self: *AppSession) void {
    self.scm_scroll_drag.end();
}

/// 포인터를 도크 tree로 라우팅한다. 반환된 intent는 호출자가 그 프레임에 적용한다.
pub fn scmDockPointer(
    self: *AppSession,
    phase: chrome.ui.interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) ?component.ids.Intent {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return null;
    if (self.scm_dock_entries.items.len == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    const local_x = x_px - @as(f64, @floatFromInt(content.x));
    const local_y = y_px - @as(f64, @floatFromInt(content.y));
    const tree_view = chrome.ui.tree.UiRectTree{ .entries = self.scm_dock_entries.items };
    const dispatched = chrome.ui.interaction.dispatch(
        &self.scm_dock_interaction,
        tree_view,
        .{ .phase = phase, .x_px = local_x, .y_px = local_y, .timestamp_ns = 0 },
    ) catch return null;
    // `dirty`에 무언가 들어오면 다시 그려야 한다(호버가 들어오고 나가는 것도 그림이 바뀌는 일이다).
    for (dispatched.dirty.ids) |id| {
        if (id != null) {
            self.metal_dirty = true;
            break;
        }
    }
    // **드래그를 버리지 않는다.** 이 tree에서 drag를 선언한 것은 스크롤바뿐이고(그 선언이 곧 계약이다),
    // 지금까지는 이 결과를 흘려서 막대가 **보이는데 안 잡히는** 컨트롤이었다.
    // **누른 순간 드래그를 연다.** `began`은 threshold를 넘은 뒤에 오므로, 거기서 잡으면 그 사이 움직인
    // 만큼 thumb이 손가락 아래로 튄다(threshold가 0이어도 첫 좌표는 move에서 온다).
    if (phase == .down) beginScmScrollbarDrag(self, local_x, local_y);
    if (dispatched.drag) |event| switch (event) {
        .began, .moved => |update| {
            dragScmScrollbar(self, update.x_px, update.y_px);
            return null; // 드래그 중에는 클릭 intent가 없다
        },
        .dropped => |update| {
            dragScmScrollbar(self, update.x_px, update.y_px);
            endScmScrollbarDrag(self);
            return null;
        },
        .cancelled => {
            endScmScrollbarDrag(self);
            return null;
        },
    };
    // 손을 뗐으면 잡은 자리도 놓는다(드래그가 안 시작된 클릭도 여기로 온다).
    if (phase == .up) endScmScrollbarDrag(self);
    const action = dispatched.action orelse return null;
    var table = component.ids.Table.init(self.scm_dock_actions.items);
    table.count = self.scm_dock_actions.items.len;
    return table.resolve(action, self.scm_dock_snapshot_generation);
}

/// 지금 호버한 노드가 **선언한** 커서. 판정은 component가 했고(`build`의 `rowCursor`), 여기서는 그
/// 값을 published tree에서 읽어 host 커서로 옮기기만 한다.
///
/// 도크 전체가 화살표였다: 탐색기 행 판정을 그대로 썼는데 이 뷰에는 그런 행이 없어 늘 "행 아님"이었다
/// (사용자 지적 2026-08-17).
pub fn scmHoverCursor(self: *AppSession) chrome.ui.tree.CursorHint {
    const hovered = self.scm_dock_interaction.hovered orelse return .auto;
    for (self.scm_dock_entries.items) |entry| {
        if (entry.id == hovered) return entry.cursor;
    }
    return .auto;
}

/// intent를 실제 동작으로 옮긴다. **모델 인덱스는 다시 조회한다** — intent가 든 것은 인덱스뿐이고,
/// 그 사이 목록이 갱신됐을 수 있다(늦은 클릭이 엉뚱한 파일을 열지 않게).
/// 좌표를 아는 자리에서 부르는 판. **커밋 상자만 좌표가 필요하다** — caret은 tree hit이 아니라 글자
/// hit이라 어디를 눌렀는지 알아야 한다. 나머지는 그대로 `applyScmDockIntent`로 간다.
pub fn applyScmDockIntentAt(self: *AppSession, intent: component.ids.Intent, x_px: f64, y_px: f64) void {
    switch (intent) {
        .commit_focus => |index| if (repoPathAt(self, index)) |repo| focusCommitAt(self, index, repo, x_px, y_px),
        else => applyScmDockIntent(self, intent),
    }
}

/// 목록 자리 → 저장소 경로. **지금 목록에서 다시 찾는다** — intent가 든 것은 자리뿐이고, 그 사이
/// 터미널이 열리고 닫히며 목록이 바뀔 수 있다(파일 행이 모델 인덱스를 다시 조회하는 것과 같은 규율).
///
/// 반환 슬라이스는 **이 프레임 동안만** 유효하다(호출자가 곧바로 쓴다).
/// 캡처 전용: 소스 컨트롤 도크의 파일 행을 **클릭한 것처럼** 열어 비교를 띄운다
/// (`MARU_OPEN_SCM_DIFF=<파일 행 순번|last>`, 0-based).
///
/// **왜 필요한가.** N1.5의 기본 경로 전환은 계약이 *"실제 클릭 경로를 눈으로 확인한 뒤에"* 하라고
/// 정했는데(plans/native-editor.md), 스크린샷 하니스에는 포인터가 없어 도크 행을 누를 수가 없다.
/// 강제 호버 훅이 같은 이유로 있는 자리다.
///
/// **제품 경로를 그대로 태운다** — `.open_row` 핸들러가 하는 일(저장소 → 모델 → 파일 행 →
/// `selectRow` + `openDiffForScmRow`)을 같은 순서로 부른다. 여기서 `entry.diff_*`를 직접 채우면
/// 그것은 클릭 경로가 아니라 그 배관의 복제가 되어, 확인하려던 것을 확인하지 못한다.
///
/// **모델이 찰 때까지 기다린다.** 목록은 git 백엔드의 비동기 결과라 첫 프레임에는 비어 있다.
/// 그래서 래치는 **실제로 연 뒤에만** 세운다 — 실패한 프레임에서 세우면 목록이 도착해도 안 연다.
///
/// 도크가 소스 컨트롤 뷰가 아니면 **여기서 연다**(캡처 하니스는 그 전환도 누를 수 없다).
/// env 미설정이면 무동작.
pub fn maybeDebugOpenScmDiff(self: *AppSession) void {
    if (self.debug_scm_diff_opened or !self.dock_initialized) return;
    const raw = std.c.getenv("MARU_OPEN_SCM_DIFF") orelse return;
    // **다른 훅과 달리 `"0"`을 끄는 값으로 보지 않는다** — 여기서 그것은 "첫 파일 행"이라는 **인덱스**다.
    // 끄려면 env를 지운다(빈 값은 아래에서 무동작).
    const spec = std.mem.span(raw);
    if (spec.len == 0) return;

    self.dock.presented = true;
    self.dock.view = .source_control;

    // **첫 저장소만 본다** — 캡처 하니스는 한 저장소를 열고 찍는다. 목록에 저장소가 여럿인 화면을
    // 찍어야 하면 그때 인덱스를 받게 늘린다.
    const repo = repoPathAt(self, 0) orelse return; // 목록이 아직 없다 — 다음 프레임에 다시 본다
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo, &rows_buf, &scratch) orelse return;

    // **파일 행만 센다** — 섹션 머리·"더 보기"·안내 줄은 클릭 대상이 아니다.
    const want_last = std.mem.eql(u8, spec, "last");
    const want_index: usize = if (want_last) 0 else std.fmt.parseInt(usize, spec, 10) catch 0;
    var seen: usize = 0;
    var chosen: ?struct { index: usize, file: scm_view.FileRow } = null;
    for (model.rows, 0..) |row, i| {
        switch (row) {
            .file => |f| {
                if (want_last or seen == want_index) chosen = .{ .index = i, .file = f };
                seen += 1;
            },
            else => {},
        }
    }
    const pick = chosen orelse return; // 변경된 파일이 하나도 없다

    self.debug_scm_diff_opened = true;
    selectRow(self, repo, @intCast(pick.index));
    git_ops.openDiffForScmRow(self, repo, pick.file);
}

fn repoPathAt(self: *AppSession, index: u32) ?[]const u8 {
    const repos = repoEntries(self);
    if (index >= repos.entries.len) return null;
    // 캐시는 세션 소유라 그대로 빌려 줘도 된다(프레임 안에서 쓴다).
    return repos.entries[index].path;
}

/// 창 좌표가 **편집 중인 커밋 상자 안**인가. 포인터가 그 상자를 뜻하는지 묻는 자리가 둘이라(클릭의
/// 포커스 해제 · 휠의 대상 판정) 한 함수로 둔다 — 두 곳이 각자 재면 경계 한 픽셀에서 갈리고, 그 갈림은
/// "가장자리에서만 휠이 목록으로 샌다"처럼 재현하기 어려운 증상이 된다.
///
/// 편집 중인 상자가 없거나 그 상자가 화면(발행된 tree)에 없으면 false다.
pub fn pointInCommitBox(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (self.scm_commit_focus_repo == null) return false;
    const rect = commitBoxRect(self) orelse return false;
    const content = dock_ops.dockGeometry(self).tree_content;
    const local_x = x_px - @as(f64, @floatFromInt(content.x));
    const local_y = y_px - @as(f64, @floatFromInt(content.y));
    // **그 entry의 clip으로 한 번 더 자른다.** 발행된 항목 rect는 스크롤에 따라 뷰포트 밖으로도 뻗는다
    // (그리기만 잘린다) — 상자 rect만 보면 상자가 위로 밀린 상태에서 **요약·탭 띠 위**를 눌러도
    // "상자 안"이 되어, 안 보이는 상자가 굴러가거나 편집이 안 떨어진다(적대적 검증 2026-08-19).
    //
    // **일반 히트테스트가 쓰는 바로 그 값이다**(`interaction.zig`가 `effective_clip`으로 후보를 자른다).
    // 여기서 "스크롤 영역 rect"를 따로 찾아 자르면 같은 사실에 규칙이 둘이 되고, 상자에 clip하는 조상이
    // 하나 더 생기는 날 조용히 갈린다.
    if (commitBoxClip(self)) |clip| {
        if (local_x < clip.x or local_x >= clip.x + clip.width) return false;
        if (local_y < clip.y or local_y >= clip.y + clip.height) return false;
    }
    return local_x >= rect.x and local_x < rect.x + rect.width and
        local_y >= rect.y and local_y < rect.y + rect.height;
}

/// 편집 중인 상자 entry의 **effective clip**(없으면 null = 안 잘린다).
pub fn commitBoxClip(self: *AppSession) ?chrome.ui.layout.UiRect {
    const entry = focusedCommitBoxEntry(self) orelse return null;
    return entry.effective_clip;
}

/// 편집 중인 상자의 **발행된 entry**. rect도 clip도 여기서 나온다 — 같은 탐색(저장소 → 노드 id →
/// 발행 entry)을 두 곳에 적으면 한쪽만 고쳐진다.
fn focusedCommitBoxEntry(self: *AppSession) ?chrome.ui.tree.RectEntry {
    const repo = focusedCommitRepo(self) orelse return null;
    const repos = repoEntries(self);
    for (repos.entries, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.path, repo)) continue;
        if (index >= self.scm_commit_box_nodes.len) return null;
        const id = self.scm_commit_box_nodes[index] orelse return null;
        for (self.scm_dock_entries.items) |published| {
            if (published.id == id) return published;
        }
        return null;
    }
    return null;
}

/// 상자 **밖**을 눌렀으면 편집을 뗀다. 안이면 아무것도 안 한다(그 클릭은 caret을 놓는 클릭이다).
pub fn blurCommitIfOutside(self: *AppSession, x_px: f64, y_px: f64) void {
    if (self.scm_commit_focus_repo == null) return;
    // **상자가 화면에서 사라졌으면 뗀다**(스크롤로 밀려났거나 그룹이 접혔다) — `pointInCommitBox`는
    // 그 경우도 false를 내므로 아래 한 줄이 두 사실을 함께 처리한다.
    if (!pointInCommitBox(self, x_px, y_px)) blurCommit(self);
}

/// 이 인텐트가 **로컬 저장소에 작용하나**(RS2 — [계획](../../../../docs/plans/remote-scm.md)).
///
/// 원격 목록을 보는 동안 이런 인텐트가 통과하면, 화면은 원격인데 손은 **로컬 파일**에 간다 —
/// 스테이지·되돌리기가 보고 있지도 않은 파일을 바꾸고, 행 클릭은 로컬에 우연히 같은 경로가 있으면
/// 남의 파일을 연다(§9.4 가 링크 감지에서 막은 함정, 그리고 이 계획이 선 이유).
///
/// **exhaustive switch 다.** 인텐트가 하나 늘면 여기서 컴파일이 깨져 분류를 강제한다 — 목록을 손으로
/// 적어 두면 새 동작이 조용히 원격에서 로컬을 만지는 쪽으로 샌다. 화면만 바꾸는 것(접기·탭·스크롤)과
/// 원격에서도 뜻이 그대로인 것(새로고침 — 원격이면 원격을 다시 읽는다)은 통과시킨다.
pub fn intentTouchesLocalRepo(intent: component.ids.Intent) bool {
    return switch (intent) {
        // 로컬 파일·로컬 index 를 만진다.
        .open_row,
        .row_action,
        .section_action,
        .commit,
        .commit_focus,
        .stage_all_repo,
        .fetch_remote,
        .open_remote_menu,
        .open_turn_file,
        .open_commit_file,
        => true,
        // 화면 상태만 바꾸거나, 원격에서도 같은 뜻으로 도는 것.
        .toggle_section,
        .expand_section,
        .toggle_repo,
        .select_commit,
        .select_turn,
        .load_more_commits,
        .select_tab,
        .refresh_repo,
        .scroll_thumb,
        .scroll_track,
        => false,
    };
}

pub fn applyScmDockIntent(self: *AppSession, intent: component.ids.Intent) void {
    // **원격 목록을 보는 동안 로컬을 만지는 동작은 여기서 끊는다**(RS2). 진입점 한 겹에서 막는 이유는
    // 하위 경로가 열 곳이 넘어 하나라도 빠뜨리면 그 자리가 곧 사고이기 때문이다 — 그리고 「조용히
    // 무동작」이 아니라 **이유를 말한다**(도크의 다른 거절과 같은 규율).
    if (git_ops.scmTargetIsRemote(self) and intentTouchesLocalRepo(intent)) {
        setScmWriteNotice(self, maru.i18n.t(.scm_remote_read_only));
        return;
    }
    switch (intent) {
        .toggle_section => |section| {
            const index = sectionIndex(section);
            self.scm_collapsed[index] = !self.scm_collapsed[index];
            self.scm_selected_row = null; // 행 번호가 밀리므로 강조를 내린다(§ 적대적 검증 4회차)
            self.metal_dirty = true;
        },
        .expand_section => |section| {
            self.scm_expanded[sectionIndex(section)] = true;
            self.scm_selected_row = null;
            self.metal_dirty = true;
        },
        .open_row => |ref| {
            // **어느 저장소의 몇 번째 행인가**(②d). 저장소마다 모델이 따로 서므로 인덱스만으로는
            // 남의 파일을 연다.
            const repo = repoPathAt(self, ref.repo_index) orelse return;
            var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
            var scratch: [std.fs.max_path_bytes]u8 = undefined;
            const model = modelForRepo(self, repo, &rows_buf, &scratch) orelse return;
            if (ref.model_index >= model.rows.len) return;
            switch (model.rows[ref.model_index]) {
                .file => |file| {
                    selectRow(self, repo, ref.model_index);
                    git_ops.openDiffForScmRow(self, repo, file);
                },
                .section, .more, .notice => {},
            }
        },
        .row_action => |ref| submitRowWrite(self, ref),
        .section_action => |ref| submitSectionWrite(self, ref),
        // 좌표가 필요한 intent다 — 여기서는 **어느 저장소인지**만 세우고 caret은 `focusCommitAt`이 놓는다
        // (그쪽만 클릭 지점을 안다). 좌표 없이 온 경우(테스트·키보드)는 글 끝에 붙는다.
        .commit_focus => |index| if (repoPathAt(self, index)) |repo| focusCommitRepo(self, repo),
        // **어느 저장소로 커밋하는가**를 intent가 실어 온다(②b). 인덱스는 지금 목록에서 다시 찾는다.
        .commit => |index| if (repoPathAt(self, index)) |repo| submitCommitFor(self, repo),
        // **새로고침은 읽기라 언제나 실행한다**(②c). 활성 저장소면 목록 읽기를, 아니면 그 머리 줄
        // 읽기를 다시 건다 — 둘이 같은 사실을 각자 들지 않는다.
        .refresh_repo => |index| {
            const repo = repoPathAt(self, index) orelse return;
            if (isCurrentRepo(self, repo)) {
                git_ops.refreshGitStatus(self);
            } else {
                markRepoStatusStaleFor(self, repo);
            }
            self.metal_dirty = true;
        },
        .stage_all_repo => |index| {
            const repo = repoPathAt(self, index) orelse return;
            submitStageAllFor(self, repo);
        },
        // 탭 전환(P4). **읽기는 여기서 걸지 않는다** — 그 탭이 무엇을 필요로 하는지는 `pumpScmLog`가
        // 매 tick 보고 정한다(뷰 진입·저장소 변경·상한 증가가 전부 같은 판정을 지난다).
        .select_tab => |tab| selectScmTab(self, tab),
        // 고르기까지가 이 조각이다(P4) — 그 커밋의 diff를 여는 것은 P4b.
        // **더 읽는다**(P4). 상한을 올리고 원문을 버리면 다음 tick의 `pumpScmLog`가 다시 읽는다 —
        // 여기서 직접 읽기를 걸면 "언제 읽는가" 판정이 두 곳이 된다.
        .load_more_commits => {
            self.scm_log_limit +|= app_session_mod.scm_log_limit_initial;
            if (self.scm_log_repo) |old| self.allocator.free(old);
            self.scm_log_repo = null; // 이 값이 "이미 읽어 뒀다"의 표식이다
            self.metal_dirty = true;
        },
        .select_commit => |index| {
            // **OID로 든다**(자리는 새 커밋이 생기면 밀린다 — 적대적 검증).
            if (commitOidAt(self, index)) |oid| {
                if (self.scm_selected_commit) |old_sel| self.allocator.free(old_sel);
                self.scm_selected_commit = self.allocator.dupe(u8, oid) catch null;
            }
            // **고르기와 펼치기는 같은 클릭이다**(P4b). 커밋을 눌렀을 때 사용자가 보려는 것은 "그 커밋이
            // 무엇을 바꿨나"이고, 그것을 따로 여는 두 번째 컨트롤을 만들 이유가 없다.
            if (commitOidAt(self, index)) |oid| toggleCommitExpanded(self, oid);
            self.metal_dirty = true;
        },
        // 펼친 커밋의 파일 → `커밋^ ↔ 커밋` 비교를 연다.
        .open_commit_file => |index| openCommitFileDiff(self, index),
        // 턴 줄도 **고르기이자 펼치기**다(커밋 줄과 같은 규율).
        .select_turn => |index| {
            // **진행 중 줄은 변경 사항 탭으로 보낸다**(적대적 검증). 그 줄은 오른쪽이 작업트리라 tree
            // 둘로 읽을 수 없어 펼칠 것이 없는데, 아무 일도 안 하면 죽은 컨트롤이 된다 — 그 줄이
            // 가리키는 목록은 실제로 변경 사항 탭이 이미 보여 준다.
            if (isLiveTurnRow(self, index)) {
                selectScmTab(self, .changes);
                return;
            }
            selectTurn(self, index);
            toggleTurnExpanded(self, index);
            self.metal_dirty = true;
        },
        .open_turn_file => |index| openTurnFileDiff(self, index),
        .toggle_repo => |index| {
            // **인덱스는 목록 기준**이라 지금 목록에서 다시 찾는다 — 늦게 온 클릭이 다른 저장소를 접지
            // 않게(파일 행이 모델 인덱스를 다시 조회하는 것과 같은 규율).
            const repos = repoEntries(self);
            if (index >= repos.entries.len) return;
            toggleRepoCollapsed(self, repos.entries[index].path);
        },
        // 원격 갱신(P6). 대상은 **브랜치 줄이 말하는 그 저장소**(활성 저장소)다 — 그 줄의 ahead/behind가
        // 곧 이 버튼이 바꾸는 값이고, 다른 저장소를 갱신하면 화면과 결과가 어긋난다.
        .fetch_remote => submitFetch(self),
        // `∨` — `push`/`pull`을 넣어 줄 보조 메뉴(P6b).
        .open_remote_menu => openRemoteMenu(self),
        // 스크롤바는 **누른 순간**(`beginScmScrollbarDrag`) 이미 처리됐다 — thumb은 잡기만 하고, track의
        // 빈 곳은 그 지점으로 뛴다. 여기 click intent로 다시 다루면 같은 누름이 두 번 적용된다.
        .scroll_thumb, .scroll_track => {},
    }
}

/// 기본 브랜치(`origin/HEAD`) 대비 ahead/behind. 없으면 null이고 호출자가 `@{u}` 값으로 돌아간다.
///
/// **활성 저장소만 갖는다.** 이 값을 쓰는 자리는 브랜치 줄 하나뿐이고 그 줄은 활성 저장소를 말한다 —
/// 비활성 저장소까지 읽으면 저장소마다 프로세스가 하나씩 더 뜨는데 그 숫자는 화면에 나오지도 않는다.
fn defaultBranchAheadBehind(self: *AppSession) ?maru.session.git_status.AheadBehind {
    const result = self.git_result orelse return null;
    return maru.session.git_status.parseAheadBehind(result.ahead_behind);
}

/// 이 저장소에 원격이 있나(P6). **`git remote` 출력이 유일한 출처다** — 못 읽었으면(선택 명령이라 실패할
/// 수 있다) 없는 것으로 본다: 버튼이 꺼진 채 이유를 말하는 쪽이, 눌러서 실패로 배우는 쪽보다 낫다.
pub fn scmHasRemote(self: *AppSession) bool {
    const result = self.git_result orelse return false;
    return std.mem.trim(u8, result.remotes, " \t\r\n").len > 0;
}

/// 원격 갱신을 건다(P6 — §3.6 §4). **쓰기와 다른 in-flight**라 커밋·스테이지를 막지 않는다.
fn submitFetch(self: *AppSession) void {
    if (self.scm_fetch_inflight != 0) return; // 도는 중에 또 누르면 흘린다(프로세스를 쌓지 않는다)
    const repo = self.git_repo orelse return;
    // **아직 안 읽었으면 아무 말도 하지 않는다.** "원격이 없다"는 단정인데 그때 우리가 아는 것은
    // "모른다"뿐이다(머리 줄이 `읽는 중…`과 0건을 가르는 것과 같은 규율).
    if (self.git_result == null) return;
    // 원격이 없으면 **왜 안 되는지 적는다**(§3.5 — 비활성 컨트롤은 이유를 말한다). tree가 이미 action을
    // 껐지만, 그 판단이 프레임 사이에 뒤집힐 수 있어 실행 직전에 한 번 더 본다.
    if (!scmHasRemote(self)) return setScmWriteNotice(self, maru.i18n.t(.scm_no_remote));
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_fetch_seq += 1;
    if (!self.git_backend.?.submitFetch(git_exe, repo, self.scm_fetch_seq)) return;
    self.scm_fetch_inflight = self.scm_fetch_seq;
    if (self.scm_fetch_repo) |old| self.allocator.free(old);
    self.scm_fetch_repo = self.allocator.dupe(u8, repo) catch null;
    clearScmWriteError(self); // 지난 실패 문구가 새 시도 위에 남지 않게
    self.metal_dirty = true;
}

/// `∨` 보조 메뉴를 연다(P6b — 쓰기·원격 §4). 여는 자리는 그 `∨`의 **발행된 rect**다: 메뉴는 누른 자리에서
/// 자라야 하고, 그 자리를 여기서 다시 계산하면 "그린 자리와 눌리는 자리"의 주인이 둘이 된다.
///
/// **원격이 없으면 열지 않는다.** 원격이 없는 저장소에서 `push`/`pull`은 무엇을 골라도 실패한다 — 칩과
/// 같은 판정을 쓰고, 이유도 같은 자리에 적는다.
fn openRemoteMenu(self: *AppSession) void {
    if (self.git_result == null) return; // 아직 모른다 — 단정하지 않는다(칩과 같은 규율)
    const rect = scmNodeRect(self, component.build.NodeIds.remote_menu) orelse return;
    const content = dock_ops.dockGeometry(self).tree_content;
    settings_ops.closeContextMenu(self);

    // **실을 수 있는 것만 싣는다.** `push`/`pull`은 원격이 없으면 무엇을 골라도 실패하므로 그 저장소의
    // 메뉴에는 아예 없다(§4 — 비활성 컨트롤은 이유를 말하되, 메뉴 줄에는 이유를 적을 자리가 없다).
    // 기준 고르기는 원격과 무관하게 늘 있다: `origin/HEAD`가 없는 저장소의 대표가 **원격 없는 저장소**라
    // 원격을 조건으로 걸면 정작 이 기능이 필요한 곳에서 못 연다.
    var n: usize = 0;
    if (scmHasRemote(self)) {
        self.scm_remote_menu_items[n] = .push;
        self.context_menu_items_buf[n] = maru.i18n.t(.scm_menu_push);
        n += 1;
        self.scm_remote_menu_items[n] = .pull;
        self.context_menu_items_buf[n] = maru.i18n.t(.scm_menu_pull);
        n += 1;
    }
    self.scm_remote_menu_items[n] = .pick_base;
    self.context_menu_items_buf[n] = maru.i18n.t(.scm_menu_pick_base);
    n += 1;
    self.scm_remote_menu_len = n;
    self.context_menu_items_len = n;
    self.scm_remote_menu_open = true;
    // 도크-로컬 rect를 창 좌표로 옮긴다. 메뉴 자신이 작업영역 안으로 clamp하므로(브랜치 줄은 바닥이라
    // 아래로 자랄 자리가 없다) 여기서 위로 띄우는 계산을 따로 하지 않는다.
    self.chrome_host.context_menu.show(
        @intFromFloat(@as(f64, @floatFromInt(content.x)) + rect.x),
        @intFromFloat(@as(f64, @floatFromInt(content.y)) + rect.y),
        n,
    );
    self.metal_dirty = true;
}

/// 발행된 도크 tree에서 그 노드의 rect(도크-로컬). 고정 chrome은 창이 스크롤돼도 같은 id를 쓴다.
fn scmNodeRect(self: *AppSession, id: u64) ?chrome.ui.layout.UiRect {
    for (self.scm_dock_entries.items) |entry| {
        if (entry.id == id) return entry.rect;
    }
    return null;
}

/// 이 저장소에 **고른 기준**이 있으면 그것(없으면 빈 값 — 그러면 `origin/HEAD`다).
///
/// **저장소로 찾는다.** 기준은 저장소마다 다른 사실이라, 짝을 안 보면 남의 저장소에서 고른 이름으로
/// 숫자를 센다(§3.5).
pub fn scmBaseRefFor(self: *AppSession, repo: []const u8) []const u8 {
    for (self.scm_base_entries[0..self.scm_base_len]) |entry| {
        if (std.mem.eql(u8, entry.repo, repo)) return entry.base;
    }
    return &.{};
}

/// `origin/HEAD`가 **없는** 저장소인가(§3.5). 없으면 되돌아갈 기본값이 없으므로 기준 목록에서
/// "기본값" 줄을 뺀다 — 없는 것을 고르게 두면 고른 뒤 아무 일도 안 일어난다.
///
/// **결과를 아직 못 받았으면 "없다"고 하지 않는다**: 그때 우리가 아는 것은 "모른다"뿐이고,
/// 이 술어의 소비자는 그 둘을 다르게 다뤄야 한다(빈 상태 3-상태와 같은 규율).
pub fn scmDefaultBaseMissing(self: *AppSession) bool {
    const result = self.git_result orelse return false;
    return std.mem.trim(u8, result.default_base, " \t\r\n").len == 0;
}

/// 기준 목록에 **뜰 줄들**을 만든다 — 화면에 실을 글자(`context_menu_items_buf`)와 그 줄이 무엇인지
/// (`scm_base_menu_rows`)를 **함께** 세운다. 줄이 걸러지거나(원격 이름) 빠질 수 있어(`기본값`)
/// 자리만으로는 뜻을 되돌릴 수 없기 때문이다(`∨` 메뉴와 같은 규율).
fn buildBaseMenuRows(self: *AppSession) usize {
    var n: usize = 0;
    // "기본값"은 **되돌아갈 곳이 있을 때만** 뜬다. `origin/HEAD`가 없는 저장소에서 이 줄을 고르면
    // 기준이 없는 상태로 돌아가는 것이라, 고르기 전과 후가 같다(아무 말도 하지 않는 선택지다).
    if (!scmDefaultBaseMissing(self)) {
        self.context_menu_items_buf[n] = maru.i18n.t(.scm_base_default);
        self.scm_base_menu_rows[n] = .default_base;
        n += 1;
    }
    const room = @min(self.scm_base_menu_rows.len, self.context_menu_items_buf.len);
    for (self.branch_menu_names[0..self.branch_menu_len], 0..) |name, i| {
        if (n >= room) break;
        // **원격 이름 자체는 뺀다.** `refs/remotes/origin/HEAD`의 짧은 이름이 `origin`이라 목록에 그대로
        // 뜨는데, 그것은 위의 `기본값` 줄과 **같은 것을 가리킨다**(제품 캡처 2026-08-19에서 나란히 떴다).
        // 같은 뜻의 줄이 둘이면 사용자는 둘이 다르다고 읽는다. 판정은 이미 읽어 둔 `git remote` 출력으로
        // 한다 — 이름이 그 목록에 있으면 그것은 브랜치가 아니라 원격이다(git 버전에 기대지 않는다).
        if (isRemoteName(self, name)) continue;
        self.context_menu_items_buf[n] = name;
        self.scm_base_menu_rows[n] = .{ .branch = i };
        n += 1;
    }
    self.scm_base_menu_len = n;
    self.context_menu_items_len = n;
    return n;
}

/// 테스트가 부르는 이름 — 줄 만들기는 rect·메뉴 표시와 **분리돼 있다**(그래야 발행된 tree 없이도
/// 자리↔뜻 대응을 단언할 수 있다).
pub fn buildBaseMenuRowsForTest(self: *AppSession) usize {
    return buildBaseMenuRows(self);
}

/// 그 저장소의 기준을 세우거나(`ref`) 지운다(`null`). 세웠으면 true — 실패하면 화면을 안 바꾼다.
///
/// **자리가 꽉 차면 오래된 것을 버리지 않고 거절한다**(workspace의 상한과 같은 규율): 조용히 밀어내면
/// 사용자는 "어제 고른 기준이 왜 기본값이지"를 겪고, 그 이유가 화면 어디에도 없다.
pub fn rememberScmBase(self: *AppSession, repo: []const u8, ref: ?[]const u8) bool {
    // **들어오는 자리에서 거른다**(적대적 검증 2026-08-19). 저장 쪽(`workspace.serialize`)도 같은 검사를
    // 하는데, 그쪽이 걸리면 **workspace 저장이 통째로 실패한다** — 탭·pane·창 위치까지 함께 잃는다.
    // 기준 하나 때문에 그 폭발 반경을 감수할 이유가 없으므로, 못 실을 값은 여기서 안 받는다.
    if (ref) |name| {
        if (!maru.session.git_command.isSafeBaseRef(name)) return false;
        if (!std.fs.path.isAbsolute(repo) or repo.len > std.fs.max_path_bytes) return false;
    }
    var index: ?usize = null;
    for (self.scm_base_entries[0..self.scm_base_len], 0..) |entry, i| {
        if (std.mem.eql(u8, entry.repo, repo)) index = i;
    }
    if (ref == null) {
        const at = index orelse return true; // 원래 없던 것을 지우는 것은 성공이다
        self.allocator.free(self.scm_base_entries[at].repo);
        self.allocator.free(self.scm_base_entries[at].base);
        self.scm_base_len -= 1;
        if (at != self.scm_base_len) self.scm_base_entries[at] = self.scm_base_entries[self.scm_base_len];
        self.workspaceChanged(.scm_base);
        return true;
    }
    if (index) |at| {
        if (std.mem.eql(u8, self.scm_base_entries[at].base, ref.?)) return true;
    }
    const name = self.allocator.dupe(u8, ref.?) catch return false;
    if (index) |at| {
        self.allocator.free(self.scm_base_entries[at].base);
        self.scm_base_entries[at].base = name;
        self.workspaceChanged(.scm_base);
        return true;
    }
    if (self.scm_base_len == self.scm_base_entries.len) {
        self.allocator.free(name);
        return false;
    }
    const repo_copy = self.allocator.dupe(u8, repo) catch {
        self.allocator.free(name); // 짝이 반만 서면 다음 프레임이 남의 기준을 쓴다
        return false;
    };
    self.scm_base_entries[self.scm_base_len] = .{ .repo = repo_copy, .base = name };
    self.scm_base_len += 1;
    self.workspaceChanged(.scm_base);
    return true;
}

/// 이 이름이 **원격 이름**인가(`git remote` 출력 한 줄과 정확히 같은가).
fn isRemoteName(self: *AppSession, name: []const u8) bool {
    const result = self.git_result orelse return false;
    var it = std.mem.tokenizeAny(u8, result.remotes, "\r\n");
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), name)) return true;
    }
    return false;
}

/// 걷은 목록으로 **기준 브랜치 메뉴**를 연다(§3.5). 자리는 브랜치 줄의 `∨` — 그 메뉴에서 왔다.
pub fn openBaseMenu(self: *AppSession) void {
    const rect = scmNodeRect(self, component.build.NodeIds.remote_menu) orelse return;
    const content = dock_ops.dockGeometry(self).tree_content;
    settings_ops.closeContextMenu(self);
    const n = buildBaseMenuRows(self);
    if (n == 0) return self.showNoticeKey(.set_no_branches);
    self.scm_base_menu_open = true;
    self.chrome_host.context_menu.show(
        @intFromFloat(@as(f64, @floatFromInt(content.x)) + rect.x),
        @intFromFloat(@as(f64, @floatFromInt(content.y)) + rect.y),
        n,
    );
    self.metal_dirty = true;
}

/// 고른 기준을 세운다. **우리가 실행하는 것은 읽기뿐이다** — 이 선택은 다음 목록 읽기의 인자를 바꾼다.
pub fn applyBaseMenuSelection(self: *AppSession, index: usize) void {
    if (index >= self.scm_base_menu_len) return;
    switch (self.scm_base_menu_rows[index]) {
        .default_base => setScmBase(self, null),
        .branch => |i| {
            if (i >= self.branch_menu_len) return;
            const name = self.branch_menu_names[i];
            // **여기서 거른다**(백엔드의 같은 검사는 심층 방어다 — §6). 목록은 우리가 읽은 ref 이름이라
            // 정상이면 늘 통과하지만, 통과 못 한 이름을 조용히 무시하면 사용자는 "골랐는데 안 바뀐다"만 본다.
            if (!maru.session.git_command.isSafeBaseRef(name)) return self.showNoticeKey(.set_branch_name_invalid);
            setScmBase(self, name);
        },
    }
}

/// 테스트가 부르는 이름 — 메뉴 줄 표를 세우지 않고 "이 이름을 골랐다"만 재현한다(자리↔뜻 대응은
/// 그쪽 테스트가 따로 고정한다).
pub fn applyBaseMenuSelectionForTest(self: *AppSession, ref: []const u8) void {
    setScmBase(self, ref);
}

fn setScmBase(self: *AppSession, ref: ?[]const u8) void {
    // 이 메뉴는 **인텐트를 안 거친다**(상태바 브랜치 항목 → `openBaseMenu` → 선택 콜백). 원격일 때
    // 통과하면 원격 경로를 키로 기준을 적어, 로컬에 같은 경로가 있으면 그쪽 기준을 덮는다
    // (적대적 검증 3회차).
    if (git_ops.scmTargetIsRemote(self)) return setScmWriteNotice(self, maru.i18n.t(.scm_remote_read_only));
    const repo = self.git_repo orelse return;
    // **거절당하면 그 사실을 적는다**(적대적 검증 2026-08-19). 조용히 돌아가면 사용자는 메뉴에서 이름을
    // 골랐는데 화면이 그대로인 것만 본다 — 같은 값을 다시 골라도 아무 일이 없다(상태가 이미 그 값이거나,
    // 애초에 못 받는 값이라서). P7a가 "읽기가 도는 중"에 대해 고친 실패와 **같은 종류**다.
    if (!rememberScmBase(self, repo, ref)) return setScmWriteNotice(self, maru.i18n.t(.scm_base_limit));
    // 기준이 바뀌면 숫자와 "브랜치에 COMMIT 됨" 목록이 **함께** 달라진다 — 셋이 한 읽기에서 오므로
    // 다시 읽는 것 말고 다른 갱신 경로가 없다. 지금 못 걸 수도 있으므로(읽기·쓰기가 도는 중) 사실로
    // 남겨 두고, 실제로 제출된 자리에서 내린다.
    self.scm_base_reread_pending = true;
    git_ops.refreshGitStatus(self);
    self.metal_dirty = true;
}

/// 고른 줄을 **활성 터미널에 명령으로 넣어 준다**(P6b). 실행은 사용자가 한다 — 남의 저장소를 바꾸는 일이고
/// hook·충돌·강제 여부가 걸린다(쓰기·원격 §4, 브랜치 전환과 같은 패턴이라 개행을 붙이지 않는다).
///
/// **`pasteText`를 쓰지 않는다.** 그쪽은 커밋 상자가 입력을 소유하면 글자를 **커밋 메시지로** 보낸다 —
/// 사용자가 고른 것은 "터미널에서 실행할 명령"이므로 그 라우팅이 여기서는 틀린다(상자에 `git push`가
/// 적히고 아무 일도 안 일어난다).
///
/// 기준 고르기(§3.5)는 명령이 아니라 **다음 읽기의 인자**를 바꾼다 — 터미널로 나가지 않는다.
pub fn applyRemoteMenuSelection(self: *AppSession, index: usize) void {
    // **index가 아니라 뜻으로 되돌린다**(§3.5). 원격이 없는 저장소에서는 `push`/`pull`이 빠져 0번이
    // 기준 고르기다 — 자리를 여기서 다시 세면 그 저장소에서 엉뚱한 항목이 실행된다.
    if (index >= self.scm_remote_menu_len) return;
    switch (self.scm_remote_menu_items[index]) {
        .push, .pull => {
            const cmd: []const u8 = if (self.scm_remote_menu_items[index] == .push) "git push" else "git pull";
            if (!term_ops.activeTermIsTerminal(self)) return setScmWriteNotice(self, maru.i18n.t(.scm_no_terminal));
            term_ops.submitPaste(self, cmd, false, term_ops.activeSurface(self).id);
        },
        // 목록 읽기는 비동기다 — 결과가 오면 `drainGitStatus`가 `openBaseMenu`를 부른다(브랜치 메뉴와 같은 길).
        .pick_base => settings_ops.requestBranchMenu(self, .pick_base),
    }
}

/// 끝난 fetch를 거둔다. **성공이든 실패든 목록을 다시 읽는다** — 성공이면 remote-tracking ref가 바뀌어
/// ahead/behind가 낡았고, 실패면 우리가 아는 것과 저장소가 갈렸을 수 있다(§5·§7과 같은 규율).
pub fn drainScmFetch(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeFetchResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    if (taken.request_id != self.scm_fetch_inflight) return; // 낡은 결과는 버린다
    self.scm_fetch_inflight = 0;
    self.metal_dirty = true;
    clearScmWriteError(self);
    if (taken.ok()) {
        // **성공도 말한다.** 아무 말이 없으면 "눌렀는데 아무 일도 안 일어났다"로 읽힌다 — 원격에 새 것이
        // 없으면 화면 숫자가 그대로라 더욱 그렇다.
        setScmWriteNotice(self, maru.i18n.t(.scm_fetch_done));
    } else {
        self.scm_write_error = writeErrorText(self, taken);
    }
    // fetch가 바꾸는 것은 remote-tracking ref다 — 그 저장소의 머리 줄을 다시 읽어야 ahead/behind가 따라온다.
    // **쓰기가 도는 중이면 그 읽기는 §6-1이 막는다** — 그래도 잃지 않는다: 그 쓰기가 끝날 때
    // `drainScmWrite`가 한 번 읽고, 비활성 저장소들은 위 호출이 낡음으로 표시해 둔다.
    if (self.scm_fetch_repo) |repo| {
        if (isCurrentRepo(self, repo)) {
            git_ops.refreshGitStatus(self);
        } else {
            markRepoStatusStaleFor(self, repo);
        }
    }
}

/// 도크의 탭을 바꾼다(P4). **편집은 그대로 둔다** — 탭을 옮긴다고 사용자가 쓰던 커밋 메시지를
/// 버릴 이유가 없고, 상자는 변경 사항 탭으로 돌아오면 그 자리에 있다.
pub fn selectScmTab(self: *AppSession, tab: component.types.Tab) void {
    if (self.scm_tab == tab) return;
    self.scm_tab = tab;
    // 목록·히스토리는 서로 다른 스크롤 축이다 — 남겨 두면 히스토리 첫 화면이 엉뚱한 자리에서 시작한다.
    self.scm_scroll = .{};
    // **상한도 함께 버린다.** 그 값은 방금 떠난 목록의 것이고, 다음 투영이 새 목록으로 채운다 — 남겨
    // 두면 그 한 프레임 동안 휠·스크롤바가 남의 목록 길이로 움직인다.
    forgetScrollExtent(self);
    self.metal_dirty = true;
}

/// 히스토리 탭이 지금 필요한 읽기를 건다. **그 탭을 볼 때만** 돈다 — 안 보는 목록을 읽는 것은
/// 프로세스를 공짜로 띄우는 일이다(§6 비용 규율).
pub fn pumpScmLog(self: *AppSession) void {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return;
    if (self.scm_tab != .history) return;
    if (self.scm_log_inflight != 0) return;
    const repo = self.git_repo orelse return; // 저장소를 못 잡았으면 읽을 것도 없다
    // 이미 **그 저장소를 그 상한으로** 읽어 뒀으면 다시 읽지 않는다.
    if (self.scm_log_repo) |current| {
        if (std.mem.eql(u8, current, repo) and !self.scm_log_failed and self.scm_log_text.len > 0) return;
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_log_seq += 1;
    if (!self.git_backend.?.submitLog(git_exe, repo, self.scm_log_limit, self.scm_log_seq)) return;
    self.scm_log_inflight = self.scm_log_seq;
}

/// 도착한 커밋 목록을 싣는다. **경로로 맞춘다** — 저장소가 그 사이에 바뀌면 남의 커밋이 된다.
pub fn drainScmLog(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeLogResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    if (taken.request_id != self.scm_log_inflight) return; // 낡은 답은 버린다
    self.scm_log_inflight = 0;
    self.metal_dirty = true;
    // **실패도 기록한다**(그 탭이 영영 "읽는 중"으로 남지 않게). 첫 커밋 전 저장소는 `git log`가
    // 실패하는데, 그건 오류가 아니라 "커밋이 없다"이고 화면 문구가 그렇게 갈린다.
    self.scm_log_failed = !taken.ok;
    self.scm_log_truncated = taken.truncated;
    const text_copy = self.allocator.dupe(u8, taken.text) catch return;
    const repo_copy = self.allocator.dupe(u8, taken.repo) catch {
        self.allocator.free(text_copy);
        return;
    };
    if (self.scm_log_text.len > 0) self.allocator.free(self.scm_log_text);
    if (self.scm_log_repo) |old| self.allocator.free(old);
    self.scm_log_text = text_copy;
    self.scm_log_repo = repo_copy;
    // **새 목록이다** — 옛 화면을 겨냥한 늦은 클릭을 거부한다(파일 목록이 같은 이유로 세대를 올린다).
    // 커밋 줄의 intent는 **자리**를 싣고 그 자리가 여기서 다른 커밋을 가리키게 되기 때문이다.
    git_ops.bumpScmDockGeneration(self);
}

/// 저장소가 바뀌었으면 히스토리 원문을 버린다. **남의 커밋을 그리는 것보다 빈 화면이 낫다.**
pub fn dropScmLogIfRepoChanged(self: *AppSession) void {
    const repo = self.git_repo orelse "";
    const current = self.scm_log_repo orelse return;
    if (std.mem.eql(u8, current, repo)) return;
    self.allocator.free(current);
    self.scm_log_repo = null;
    if (self.scm_log_text.len > 0) self.allocator.free(self.scm_log_text);
    self.scm_log_text = &.{};
    self.scm_log_limit = app_session_mod.scm_log_limit_initial;
    self.scm_log_failed = false;
    self.scm_log_truncated = false;
    // **고른 커밋도 버린다**(적대적 검증). 인덱스는 그 목록 안의 자리라, 목록이 바뀌면 같은 번호가
    // 다른 저장소의 다른 커밋을 가리킨다 — 화면에는 "무언가 골라 둔" 강조만 남는다.
    if (self.scm_selected_commit) |oid| self.allocator.free(oid);
    self.scm_selected_commit = null;
    // **펼친 커밋과 그 파일도 버린다**(P4b 적대적 검증). 남겨 두면 그 OID를 **새 저장소에서** 읽는다 —
    // 대개 실패하지만, 실패든 아니든 그건 이 저장소의 사실이 아니다.
    if (self.scm_expanded_commit) |oid| self.allocator.free(oid);
    self.scm_expanded_commit = null;
    // 턴 쪽도 같이 버린다 — 링은 저장소가 갈리면 통째로 비워지므로 그 키는 어느 턴도 가리키지 않는다.
    if (self.scm_expanded_turn) |key| self.allocator.free(key);
    self.scm_expanded_turn = null;
    if (self.scm_selected_turn) |key| self.allocator.free(key);
    self.scm_selected_turn = null;
    dropCommitFiles(self);
}

/// 히스토리에서 커밋을 **펼치거나 접는다**(P4b). 같은 커밋을 다시 누르면 접힌다 — 목록에서 자리를
/// 돌려받는 길이 그 줄 자신이어야 한다(그룹 헤더와 같은 규율).
pub fn toggleCommitExpanded(self: *AppSession, oid: []const u8) void {
    if (self.scm_expanded_commit) |current| {
        const same = std.mem.eql(u8, current, oid);
        self.allocator.free(current);
        self.scm_expanded_commit = null;
        dropCommitFiles(self);
        if (same) {
            self.metal_dirty = true;
            return; // 접기
        }
    }
    self.scm_expanded_commit = self.allocator.dupe(u8, oid) catch null;
    // 턴 쪽 펼침도 접는다 — 슬롯이 하나라 둘이 동시에 열려 있으면 서로의 파일을 그린다(적대적 검증).
    if (self.scm_expanded_turn) |key| {
        self.allocator.free(key);
        self.scm_expanded_turn = null;
    }
    self.metal_dirty = true;
}

/// 실려 있는 파일 목록이 **그 키의 것**인가. 슬롯을 두 탭이 공유하므로, 키를 확인하지 않으면 앞서
/// 펼친 항목의 파일이 새 항목 아래에 그려진다(적대적 검증에서 실제로 그랬다 — 탭을 오가면 커밋의 파일이
/// 턴 아래에 섰다). 읽는 중에도 같은 이유로 옛 목록이 남지 않는다.
fn filesLoadedFor(self: *const AppSession, key: []const u8) bool {
    const current = self.scm_commit_files_oid orelse return false;
    return std.mem.eql(u8, current, key);
}

/// 그 자리가 **진행 중** 줄인가(오른쪽이 작업트리라 tree 둘로 읽을 수 없는 줄).
fn isLiveTurnRow(self: *AppSession, index: u32) bool {
    var rows_buf: [maru.session.turn_snapshot.capacity]maru.session.turn_snapshot.Ring.TimelineRow = undefined;
    const rows = if (activeTurnRing(self)) |ring| ring.timeline(&rows_buf) else &[_]maru.session.turn_snapshot.Ring.TimelineRow{};
    if (index >= rows.len) return false;
    return rows[index].head == null;
}

/// 고른 턴을 세운다. **키로 든다**(자리는 새 턴이 들어오면 밀린다). 진행 중은 키가 없어 강조가 없다 —
/// 그 줄은 늘 맨 위라 눈으로 찾기 쉽고, 밴드가 없다고 잃을 것이 없다.
fn selectTurn(self: *AppSession, index: u32) void {
    var rows_buf: [maru.session.turn_snapshot.capacity]maru.session.turn_snapshot.Ring.TimelineRow = undefined;
    const rows = if (activeTurnRing(self)) |ring| ring.timeline(&rows_buf) else &[_]maru.session.turn_snapshot.Ring.TimelineRow{};
    if (index >= rows.len) return;
    var key_buf: [maru.session.turn_snapshot.max_oid_len * 2 + 2]u8 = undefined;
    if (self.scm_selected_turn) |old| self.allocator.free(old);
    self.scm_selected_turn = null;
    const key = timelineRowKey(rows[index], &key_buf) orelse return;
    self.scm_selected_turn = self.allocator.dupe(u8, key) catch null;
}

/// 턴을 펼치거나 접는다(P5). 같은 줄을 다시 누르면 접힌다 — 커밋 줄과 같은 규율이고, 파일 목록
/// 슬롯도 **같은 것**을 쓴다(두 탭 모두 한 번에 하나만 펼친다).
pub fn toggleTurnExpanded(self: *AppSession, index: u32) void {
    var rows_buf: [maru.session.turn_snapshot.capacity]maru.session.turn_snapshot.Ring.TimelineRow = undefined;
    const rows = if (activeTurnRing(self)) |ring| ring.timeline(&rows_buf) else &[_]maru.session.turn_snapshot.Ring.TimelineRow{};
    if (index >= rows.len) return;
    var key_buf: [maru.session.turn_snapshot.max_oid_len * 2 + 2]u8 = undefined;
    // **진행 중은 키가 없다** — 그래도 고르기는 되고, 펼침만 성립하지 않는다.
    const key = timelineRowKey(rows[index], &key_buf);
    if (self.scm_expanded_turn) |current| {
        const same = if (key) |k| std.mem.eql(u8, current, k) else false;
        self.allocator.free(current);
        self.scm_expanded_turn = null;
        dropCommitFiles(self);
        if (same) {
            self.metal_dirty = true;
            return;
        }
    }
    if (key) |k| self.scm_expanded_turn = self.allocator.dupe(u8, k) catch null;
    // 커밋 쪽 펼침도 함께 접는다 — 슬롯이 하나라 둘이 동시에 열려 있으면 서로의 파일을 그린다.
    if (self.scm_expanded_commit) |oid| {
        self.allocator.free(oid);
        self.scm_expanded_commit = null;
    }
    self.metal_dirty = true;
}

/// 펼친 턴의 두 tree 키(없으면 null). **저장된 키를 그대로 쓴다** — 자리로 다시 찾으면 링이 밀렸을 때
/// 다른 턴을 읽는다.
fn expandedTurnKey(self: *AppSession) ?[]const u8 {
    return self.scm_expanded_turn;
}

/// 펼친 커밋의 파일 원문을 버린다(다른 커밋을 펼쳤거나 접었다).
fn dropCommitFiles(self: *AppSession) void {
    if (self.scm_commit_files_oid) |old| self.allocator.free(old);
    self.scm_commit_files_oid = null;
    if (self.scm_commit_files_text.len > 0) self.allocator.free(self.scm_commit_files_text);
    self.scm_commit_files_text = &.{};
    self.scm_commit_files_failed = false;
    self.scm_commit_files_truncated = false;
    // 그 커밋의 파일 목록이 사라졌다 — 그 안의 자리를 가리키던 강조도 뜻을 잃는다.
    self.scm_selected_commit_file = null;
}

/// 펼친 커밋의 파일 목록을 읽는다. **펼쳤을 때만** 돈다 — 안 펼친 커밋을 미리 읽는 것은 프로세스를
/// 공짜로 띄우는 일이다(§6 비용 규율, 히스토리 목록과 같은 판단).
pub fn pumpCommitFiles(self: *AppSession) void {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return;
    // **원격 목록을 보는 동안 로컬 git 으로 파일 목록을 읽지 않는다**(RS2 적대적 검증 1회차) —
    // `git_repo` 에 든 것이 원격 경로라, 로컬에 같은 경로가 있으면 남의 저장소를 읽어 그 화면에 싣는다.
    if (git_ops.scmTargetIsRemote(self)) return;
    if (self.scm_commit_files_inflight != 0) return;
    // 두 탭이 **같은 슬롯**을 쓴다(한 번에 하나만 펼친다). 무엇을 읽을지는 지금 보고 있는 탭이 정한다.
    const key: []const u8 = switch (self.scm_tab) {
        .history => self.scm_expanded_commit orelse return,
        .agent => expandedTurnKey(self) orelse return,
        .changes => return,
    };
    if (self.scm_commit_files_oid) |current| {
        if (std.mem.eql(u8, current, key)) return; // 이미 그것을 읽어 뒀다(실패도 답이다)
    }
    const repo = self.git_repo orelse return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_commit_files_seq += 1;
    const submitted = switch (self.scm_tab) {
        .history => self.git_backend.?.submitCommitFiles(git_exe, repo, key, self.scm_commit_files_seq),
        .agent => self.git_backend.?.submitTurnFiles(git_exe, repo, key, self.scm_commit_files_seq),
        .changes => false,
    };
    if (!submitted) return;
    self.scm_commit_files_inflight = self.scm_commit_files_seq;
}

/// 턴 줄의 요약(`N개 파일`)을 **한 번에 하나씩** 채운다.
///
/// `pumpCommitFiles` 의 «펼쳤을 때만 읽는다» 규율과 다른 판단이 필요한 자리다. 커밋 히스토리는 수백 개라
/// 미리 읽으면 프로세스를 공짜로 띄우지만, **턴은 최대 7개고 결과가 링에 남아 다시 묻지 않는다.**
/// tree↔tree `--raw --numstat` 은 실측 30 ms 라 목록 하나를 채우는 데 드는 총비용이 240 ms 남짓이고,
/// 그것도 도크의 에이전트 탭을 **보고 있을 때만** 든다.
///
/// **슬롯을 펼침 요청과 공유하므로** 둘 중 하나만 돈다(§6 — `git_backend` 의 결과 자리가 하나다).
/// 펼침이 먼저다: 사용자가 방금 누른 것이 요약보다 급하다.
pub fn pumpTurnSummaries(self: *AppSession) void {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return;
    if (self.scm_tab != .agent) return; // 안 보는 탭 때문에 프로세스를 띄우지 않는다
    if (self.scm_commit_files_inflight != 0 or self.scm_turn_summary_inflight != 0) return;
    const identity = git_ops.activeOrLastSessionIdentity(self);
    if (identity.len == 0) return;
    const ring = self.turn_rings.find(identity) orelse return;
    const turn = ring.nextUnknownFiles() orelse return;

    const repo = self.git_repo orelse return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }

    var key_buf: [maru.session.turn_snapshot.max_oid_len * 2 + 2]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ turn.base, turn.head }) catch return;
    const head_owned = self.allocator.dupe(u8, turn.head) catch return;
    // **어느 세션의 링에 적을지도 지금 기억한다**(AT0). 도착 시점의 «지금 활성» 을 쓰면 그 사이 pane 을
    // 옮겼을 때 남의 세션에 숫자를 적는다.
    const session_owned = self.allocator.dupe(u8, identity) catch {
        self.allocator.free(head_owned);
        return;
    };

    self.scm_commit_files_seq += 1;
    if (!self.git_backend.?.submitTurnFiles(git_exe, repo, key, self.scm_commit_files_seq)) {
        self.allocator.free(head_owned);
        self.allocator.free(session_owned);
        return;
    }
    if (self.scm_turn_summary_head) |old| self.allocator.free(old);
    if (self.scm_turn_summary_session) |old| self.allocator.free(old);
    self.scm_turn_summary_head = head_owned;
    self.scm_turn_summary_session = session_owned;
    self.scm_turn_summary_inflight = self.scm_commit_files_seq;
}

/// 요약 결과를 링에 적는다. **실패해도 «읽었다»로 표시한다** — 안 그러면 같은 턴을 매 tick 다시 물어
/// 프로세스를 무한히 띄운다. 그때 수는 0이고, 화면은 0을 그리지 않으므로 그 줄만 요약 없이 선다.
fn applyTurnSummary(self: *AppSession, ok: bool, text: []const u8) void {
    self.scm_turn_summary_inflight = 0;
    const head = self.scm_turn_summary_head orelse return;
    var count: u32 = 0;
    if (ok) {
        // 같은 출력 형식이므로 **같은 이터레이터로 센다**(`--raw --numstat` — numstat 줄까지 세면
        // 파일 수가 정확히 두 배가 된다).
        var files = maru.session.git_status.iterateCommitFiles(text);
        while (files.next()) |_| count +|= 1;
    }
    // **어느 세션의 링인지 요청 시점에 기억해 둔 값으로 되찾는다**(AT0). 결과가 오는 사이 활성 세션이
    // 바뀌었을 수 있고, 그때 «지금 활성» 링에 적으면 남의 세션에 숫자를 적는다. 그 세션이 맵에서
    // 밀려났으면 버린다 — 화면에도 없는 링이다.
    if (self.scm_turn_summary_session) |sid| {
        if (self.turn_rings.findMut(sid)) |ring| ring.markFiles(head, count);
    }
    self.allocator.free(head);
    self.scm_turn_summary_head = null;
    if (self.scm_turn_summary_session) |sid| self.allocator.free(sid);
    self.scm_turn_summary_session = null;
    self.metal_dirty = true;
}

/// 도착한 파일 목록을 싣는다. **OID로 맞춘다** — 사용자가 빠르게 다른 커밋을 펼치면 늦게 온 답이
/// 남의 줄을 채운다.
pub fn drainCommitFiles(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeCommitFilesResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    // **한 슬롯을 둘이 쓴다** — 요청 번호로 갈라 보낸다(§3.5.4 요약). 순서를 뒤집으면 요약 결과가
    // 「내 것이 아니다」로 버려져 그 줄이 영영 안 채워진다.
    if (taken.request_id == self.scm_turn_summary_inflight and self.scm_turn_summary_inflight != 0) {
        applyTurnSummary(self, taken.ok, taken.text);
        return;
    }
    if (taken.request_id != self.scm_commit_files_inflight) return;
    self.scm_commit_files_inflight = 0;
    self.metal_dirty = true;
    self.scm_commit_files_failed = !taken.ok;
    self.scm_commit_files_truncated = taken.truncated;
    const text_copy = self.allocator.dupe(u8, taken.text) catch return;
    const oid_copy = self.allocator.dupe(u8, taken.oid) catch {
        self.allocator.free(text_copy);
        return;
    };
    if (self.scm_commit_files_text.len > 0) self.allocator.free(self.scm_commit_files_text);
    if (self.scm_commit_files_oid) |old| self.allocator.free(old);
    self.scm_commit_files_text = text_copy;
    self.scm_commit_files_oid = oid_copy;
    // 펼친 커밋 아래에 줄이 생겼다 = 그 아래 모든 자리가 밀린다.
    git_ops.bumpScmDockGeneration(self);
}

/// 쓰기가 끝났으면 커밋 목록도 낡았다(적대적 검증). **커밋을 하면 그 목록이 곧 틀린다** — 방금 만든
/// 커밋이 히스토리에 없으면 사용자는 커밋이 안 된 줄 안다.
///
/// 원문을 버리고 표식(`scm_log_repo`)을 지우면 다음 tick의 `pumpScmLog`가 다시 읽는다 — 읽기를 거는
/// 자리는 여전히 하나다.
pub fn invalidateScmLog(self: *AppSession) void {
    if (self.scm_log_repo) |old| self.allocator.free(old);
    self.scm_log_repo = null;
    self.scm_log_failed = false;
}

/// 그 저장소의 커밋 상자로 포커스를 옮긴다(caret은 그대로).
///
/// **어느 저장소인지가 포커스의 일부다**(②b) — 상자가 여럿이므로 "편집 중"만으로는 글자가 어디로 갈지
/// 정해지지 않는다. 저장소가 바뀌면 그 전 상자의 글은 초안으로 담고 새 상자의 초안을 꺼낸다.
pub fn focusCommitRepo(self: *AppSession, repo: []const u8) void {
    if (self.scm_commit_focus_repo) |current| {
        if (std.mem.eql(u8, current, repo)) return;
        // 상자를 옮기는 것은 저장소를 옮기는 것과 같다 — 쓰던 글을 그 저장소에 남긴다.
        _ = self.scm_commit_field.commitPreedit(self.allocator);
        stashCommitDraft(self, current);
        self.allocator.free(current);
        self.scm_commit_focus_repo = null;
    }
    self.scm_commit_focus_repo = self.allocator.dupe(u8, repo) catch null;
    restoreCommitDraft(self, repo);
    self.metal_dirty = true;
}

/// 지금 편집 중인 상자의 저장소(없으면 null).
pub fn focusedCommitRepo(self: *const AppSession) ?[]const u8 {
    return self.scm_commit_focus_repo;
}

/// 상자가 입력을 놓았는데 **조합이 남아 있으면** 확정한다. 매 tick 도는 값싼 확인이다.
///
/// 뷰 전환은 `setDockView`가 직접 뗀다. 하지만 도크를 접거나 닫는 길은 그 함수를 지나지 않아,
/// 조합 중이던 글자가 확정되지 않은 채 남는다 — 입력기는 이미 그 조합을 잊었으므로 사용자는
/// 지울 수도 고칠 수도 없는 글자를 보게 된다. **경로를 열거하는 대신 상태로 판정한다**: 소유가
/// 없는데 조합이 있으면 그건 언제나 잘못된 상태다.
///
/// 포커스 플래그는 그대로 둔다 — 도크를 다시 펴면 쓰던 자리에서 이어 쓰는 것이 맞다.
pub fn settleCommitInput(self: *AppSession) void {
    // **편집 중인 상자가 화면에서 사라졌으면 뗀다**(②b). 그 저장소의 터미널이 닫히면 목록에서 빠지는데,
    // 포커스를 그대로 두면 키는 계속 그 상자로 가고 **화면에는 그 상자가 없다** — 사용자는 자기가 친
    // 글자가 어디로 갔는지 알 수 없다. 쓰던 글은 초안으로 남으므로 잃지 않는다.
    if (self.scm_commit_focus_repo) |focus| {
        if (self.dock.view == .source_control and dock_ops.dockVisible(self)) {
            const repos = repoEntries(self);
            var listed = false;
            for (repos.entries) |entry| {
                if (std.mem.eql(u8, entry.path, focus)) listed = true;
            }
            if (!listed) blurCommit(self);
        }
    }
    if (self.scm_commit_field.preedit.items.len == 0) return;
    if (self.scmCommitOwnsInput()) return;
    if (self.scm_commit_field.commitPreedit(self.allocator)) self.metal_dirty = true;
}

/// 커밋 상자에서 포커스를 뗀다. **조합 중이면 먼저 확정하고**(그러지 않으면 조합 글자가 화면에서
/// 사라진 채 편집기 안에만 남는다) 쓰던 글을 그 저장소의 초안으로 담는다.
pub fn blurCommit(self: *AppSession) void {
    const repo = self.scm_commit_focus_repo orelse return;
    _ = self.scm_commit_field.commitPreedit(self.allocator);
    stashCommitDraft(self, repo);
    self.allocator.free(repo);
    self.scm_commit_focus_repo = null;
    self.metal_dirty = true;
}

/// 클릭 지점에 caret을 놓는다. **글자 hit이라 좌표가 필요하다** — tree hit은 "상자를 눌렀다"까지만 안다.
///
/// 세로는 시각 행, 가로는 `text_field.caretAtColumn`이 푼다(§12.1 — 가로 축의 주인은 하나다).
pub fn focusCommitAt(self: *AppSession, repo_index: usize, repo: []const u8, x_px: f64, y_px: f64) void {
    focusCommitRepo(self, repo);
    // **조합 중이면 먼저 확정한다**(macOS 관례 — 다른 곳을 누르면 조합이 끝난다). 그러지 않으면 아래
    // 계산이 조합 글자가 끼워진 화면과 조합 없는 본문 사이에서 갈려, 누른 자리와 caret이 어긋난다.
    _ = self.scm_commit_field.commitPreedit(self.allocator);
    const rect = commitBoxRectAt(self, repo_index) orelse return;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const content = dock_ops.dockGeometry(self).tree_content;
    const local_x = x_px - @as(f64, @floatFromInt(content.x)) - rect.x;
    const local_y = y_px - @as(f64, @floatFromInt(content.y)) - rect.y;

    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const cols = commitViewCols(self);
    const text = self.scm_commit_field.text.items;
    const wrapped = text_area.wrap(text, cols, true, &lines);
    if (wrapped.lines.len == 0) return;

    const line_h: f32 = @floatFromInt(commitLineHeightPx(self));
    const rel_y = local_y - @as(f64, @floatFromInt(m.commit_pad_y));
    const row_f = @floor(rel_y / @as(f64, line_h));
    // **보이는 창 안으로 가둔다.** 상자 아래 여백(`commit_pad_y`)을 누르면 나눗셈이 창 밖 행을 주는데,
    // 그 행은 화면에 없다 — caret이 안 보이는 줄로 가고 스크롤이 한 줄 따라 움직인다. 눌린 자리에서
    // 가장 가까운 **보이는** 줄이 답이다.
    const visible = text_area.visibleRows(wrapped, commit_max_rows);
    const first: usize = @min(self.scm_commit_first_row, wrapped.lines.len - 1);
    const last_visible = @min(first + visible - 1, wrapped.lines.len - 1);
    const row_index: usize = if (row_f < 0)
        first
    else
        @min(first + @as(usize, @intFromFloat(row_f)), last_visible);

    const line = wrapped.lines[row_index];
    const band_col: i32 = blk: {
        const cell: f64 = @floatFromInt(@max(self.cell_width_px, 1));
        const rel_x = local_x - @as(f64, @floatFromInt(m.inset_x));
        if (rel_x <= 0) break :blk 0;
        // **내림이다.** 반올림하면 두 칸 글자(한글·이모지)의 **왼쪽 절반**을 눌러도 열이 1로 올라가고,
        // `caretAtColumn`의 동점 규칙(뒤 경계)과 겹쳐 caret이 그 글자 **뒤**로 간다. 내림이면 왼쪽 칸은
        // 앞, 오른쪽 칸은 뒤가 되어 두 칸 글자의 절반이 각각 앞뒤를 가리킨다.
        break :blk @intFromFloat(rel_x / cell);
    };
    const line_view: text_field.View = .{ .text = text[line.start..line.end], .caret = 0 };
    const within = text_field.caretAtColumn(line_view, .{ .cols = cols }, band_col);
    self.scm_commit_field.caret = line.start + within;
    self.scm_commit_field.clearSelection();
    scrollCommitToCaret(self);
    self.metal_dirty = true;
}

/// published tree에서 **지금 편집 중인** 커밋 상자 rect를 찾는다. **그린 것과 같은 기하**를 쓴다 —
/// 여기서 다시 계산하면 클릭 자리와 글자 자리가 갈린다.
///
/// 상자가 여럿이므로(②b) 고정 id로는 못 찾는다. 그리는 쪽이 그 프레임의 노드 id를 남기고
/// (`publishScmDockFrame` 직전), 여기서는 그것을 쓴다.
pub fn commitBoxRect(self: *AppSession) ?chrome.ui.layout.UiRect {
    const repo = focusedCommitRepo(self) orelse return commitBoxRectAt(self, 0);
    const repos = repoEntries(self);
    for (repos.entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, repo)) return commitBoxRectAt(self, index);
    }
    return null;
}

/// 그 자리 저장소의 커밋 상자 rect. **첫 클릭에도 쓴다** — 아직 포커스가 없는 상자의 caret을 놓으려면
/// 그 rect가 필요하다.
pub fn commitBoxRectAt(self: *AppSession, repo_index: usize) ?chrome.ui.layout.UiRect {
    if (repo_index >= self.scm_commit_box_nodes.len) return null;
    const id = self.scm_commit_box_nodes[repo_index] orelse return null;
    for (self.scm_dock_entries.items) |entry| {
        if (entry.id == id) return entry.rect;
    }
    return null;
}

/// 그 창에서 **편집 중인 상자**의 노드 id를 기억한다. 창이 스크롤되면 같은 상자의 id가 달라지므로
/// 매 프레임 다시 정한다.
fn rememberCommitBoxNode(self: *AppSession, window: []const component.types.Item) void {
    self.scm_commit_box_nodes = @splat(null);
    for (window, 0..) |item, index| switch (item) {
        .commit_box => |box| {
            if (box.repo_index < self.scm_commit_box_nodes.len) {
                self.scm_commit_box_nodes[box.repo_index] = component.build.NodeIds.item(index);
            }
        },
        else => {},
    };
}

/// 상자 한 행의 높이(px). 트랙패드의 점 단위를 행으로 바꿀 때 쓴다 — **그리기와 같은 출처**여야
/// "한 행 굴렸는데 반 행만 움직인다"가 안 생긴다(`commitBoxHeight`가 같은 값을 쓴다).
pub fn commitRowHeightPx(self: *AppSession) u32 {
    return component.types.DockMetrics.resolve(scmDockScaleMilli(self)).commit_row_h;
}

/// 휠 한 틱이 상자에 무엇을 했나.
///
/// **`absorbed`와 `ignored`를 가르는 것이 계약이다.** 굴릴 것이 있는데 이번 틱에 잔여만 쌓였으면
/// 소비해야 한다 — 안 그러면 트랙패드로 천천히 굴리는 동안 **뒤의 목록**이 대신 움직인다. 반대로
/// 글이 다 보이면(막대도 안 그려진다) 소비하지 않는다 — 상자 위가 죽은 구역이 되어 목록이 안 굴러간다.
pub const CommitWheel = enum { scrolled, absorbed, ignored };

/// 휠로 상자 안을 굴린다.
///
/// **위치의 단일 출처는 `scm_commit_first_row`다.** 여기서는 목록·사이드바가 쓰는 것과 **같은 순수
/// 함수**(`scroll_area.State.scrollByWheel`)에 그 값을 실어 부호·잔여·클램프를 그쪽이 정하게 하고
/// 결과만 되받는다 — 같은 규칙을 두 번 적으면 한쪽만 고쳐진다(방향이 뒤집힌 스크롤은 그렇게 생긴다).
///
/// **다 보이면 굴리지 않는다.** 그때 막대는 애초에 안 그려지고(거짓 신호가 되므로), 굴릴 것이 없는데
/// 소비하면 뒤의 목록이 못 움직인다.
pub fn scrollCommitByWheel(self: *AppSession, delta: f64, unit_rows: f64) CommitWheel {
    if (self.scm_commit_focus_repo == null) return .ignored;
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const wrapped = text_area.wrap(commitDisplayText(self), commitViewCols(self), true, &lines);
    const visible = text_area.visibleRows(wrapped, commit_max_rows);
    if (wrapped.lines.len <= visible) {
        self.scm_commit_wheel_residue = 0; // 굴릴 것이 없으면 잔여도 없다
        return .ignored;
    }
    const max_first: u32 = @intCast(wrapped.lines.len - visible);
    var state: chrome.ui.scroll_area.State = .{
        .offset_y_px = self.scm_commit_first_row,
        .wheel_residue_px = self.scm_commit_wheel_residue,
    };
    const moved = state.scrollByWheel(delta, unit_rows, max_first);
    self.scm_commit_wheel_residue = state.wheel_residue_px;
    if (!moved) return .absorbed; // 잔여만 쌓였다 — 그래도 이 휠은 상자의 것이다
    self.scm_commit_first_row = state.offset_y_px;
    return .scrolled;
}

/// 포인터가 상자를 떠났다 — 가는 도중이던 잔여를 버린다(목록·탐색기와 같은 규율).
pub fn dropCommitWheelResidue(self: *AppSession) void {
    self.scm_commit_wheel_residue = 0;
}

/// caret이 상자 밖으로 나갔으면 첫 행을 옮긴다(제약 ⑥ — 시각 행으로 센다).
pub fn scrollCommitToCaret(self: *AppSession) void {
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const wrapped = text_area.wrap(commitDisplayText(self), commitViewCols(self), true, &lines);
    const visible = text_area.visibleRows(wrapped, commit_max_rows);
    const first = text_area.scrollToCaret(wrapped, self.scm_commit_first_row, visible, commitDisplayCaret(self));
    if (first != self.scm_commit_first_row) {
        self.scm_commit_first_row = @intCast(first);
        self.metal_dirty = true;
    }
}

/// 낙관적으로 옮긴 행을 투영 결과에 얹는다(§7).
///
/// **모델을 고치지 않는다.** `session/scm_view`는 git 출력의 순수 함수로 남아야 P4·P5가 그대로 쓴다 —
/// "아직 확인되지 않은 사용자 의도"는 세션 상태이지 도메인이 아니다. 그래서 옮기기는 **투영 층에서**
/// 일어나고, 컴포넌트는 받은 것을 그대로 그린다(낙관인지 확정인지 모른다).
///
/// **낙관의 경계**(§7): 옮기는 것은 **그 행 하나의 자리**뿐이다.
///   - 개수·요약 숫자는 건드리지 않는다 — 부분 스테이지·rename에서 틀린 숫자가 나오고, 그건 사용자가
///     커밋 직전에 보는 값이다.
///   - **증감을 지운다.** 그 숫자는 행이 선 그룹의 축(index ↔ 작업트리)에서 나오는데 옮긴 뒤의 축을
///     우리는 아직 모른다. 옛 축의 숫자를 새 자리에 두면 그건 거짓말이다.
///   - **동작을 끈다.** 쓰기가 도는 동안 두 번째 클릭은 어차피 흘려지고(§6), 누를 수 있어 보이면
///     "안 눌렸다"로 읽힌다.
///   - 상태 문자는 **그대로 둔다.** 새 축의 글자를 추측하면(`U` → `A`) 맞을 때가 많지만 그건 추측이고,
///     ~100 ms 뒤 읽기가 사실을 싣고 온다.
fn applyScmPending(self: *AppSession, rows: []const scm_view.Row, items: []component.types.Item) void {
    const pending = self.scm_pending orelse return;
    const target: scm_view.Section = switch (pending.from) {
        .staged => .changes,
        .changes => .staged,
    };

    // 떠나는 행과 도착 그룹 헤더를 찾는다. **도착 헤더가 없으면 옮기지 않는다** — 그 그룹이 화면에
    // 없다는 뜻이고(개수 0이면 헤더를 안 낸다), 갈 곳 없는 행을 숨기면 그 파일이 잠깐 사라져 보인다.
    var from_index: ?usize = null;
    var target_header: ?usize = null;
    for (rows, 0..) |row, index| {
        switch (row) {
            .file => |file| {
                if (from_index == null and file.section == pending.from and std.mem.eql(u8, file.path, pending.path)) {
                    from_index = index;
                }
            },
            .section => |section| {
                if (section.section == target) target_header = index;
            },
            else => {},
        }
    }
    const moving = from_index orelse return;
    const header = target_header orelse return;
    if (moving >= items.len or header >= items.len) return;

    var carried = items[moving].file;
    carried.action = .none;
    carried.has_delta = false;
    carried.binary = false;

    // 배열 안에서 한 칸씩 밀어 헤더 **바로 뒤**에 끼운다(그 그룹의 첫 행 자리).
    if (moving > header) {
        var i = moving;
        while (i > header + 1) : (i -= 1) items[i] = items[i - 1];
        items[header + 1] = .{ .file = carried };
    } else {
        var i = moving;
        while (i < header) : (i += 1) items[i] = items[i + 1];
        items[header] = .{ .file = carried };
    }
}

/// 행 하나의 `+`/`−`. **모델 인덱스는 다시 조회한다** — intent가 든 것은 인덱스뿐이고 그 사이 목록이
/// 갱신됐을 수 있다(늦은 클릭이 엉뚱한 파일을 스테이지하지 않게. `open_row`와 같은 규율이다).
fn submitRowWrite(self: *AppSession, ref: component.ids.RowRef) void {
    const repo = repoPathAt(self, ref.repo_index) orelse return;
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo, &rows_buf, &scratch) orelse return;
    if (ref.model_index >= model.rows.len) return;
    const row = switch (model.rows[ref.model_index]) {
        .file => |file| file,
        .section, .more, .notice => return,
    };
    // 모델이 이미 판정한 것을 다시 판정하지 않는다 — 충돌 행은 여기서 `.none`이라 아무 일도 일어나지 않는다.
    // 규칙은 **중립이 소유한다**(`git_write_command.kindForRow`) — Windows 표면도 같은 것을 쓴다.
    const kind = git_write_command.kindForRow(row.action, model.head.unborn) orelse return;
    const paths = [_][]const u8{row.path};
    if (!submitWrite(self, repo, kind, &paths)) return;

    // **낙관적 반영**(§7): 화면은 즉시 바뀐다. 안 그러면 100 ms 남짓 아무 일도 안 일어나 두 번 누르게
    // 되고, 두 번째 클릭은 in-flight라 흘려져 "안 눌렸다"로 읽힌다. 낙관은 **이 행 하나**에만 건다.
    setScmPending(self, row.path, row.section);
}

/// 강조할 행을 세운다. **저장소와 함께** 든다(②d) — 인덱스만 들면 다른 저장소의 같은 번호 행이
/// 함께 강조된다.
fn selectRow(self: *AppSession, repo: []const u8, index: u32) void {
    if (self.scm_selected_repo) |old| self.allocator.free(old);
    self.scm_selected_repo = self.allocator.dupe(u8, repo) catch null;
    self.scm_selected_row = index;
    self.metal_dirty = true;
}

/// 방금 건 쓰기가 **어느 저장소로 갔는가**. 끝난 뒤 그 저장소를 다시 읽어야 화면이 사실을 따라간다 —
/// 활성 저장소면 목록 읽기가, 아니면 그 머리 줄 읽기가 그 일을 한다.
fn rememberWriteRepo(self: *AppSession, repo: []const u8) void {
    if (self.scm_write_repo) |old| self.allocator.free(old);
    self.scm_write_repo = self.allocator.dupe(u8, repo) catch null;
}

/// 낙관적으로 옮길 행을 기억한다. 경로는 **복사한다** — 모델 버퍼는 프레임마다 다시 만들어진다.
fn setScmPending(self: *AppSession, path: []const u8, from: scm_view.Section) void {
    clearScmPending(self);
    const copy = self.allocator.dupe(u8, path) catch return;
    self.scm_pending = .{ .path = copy, .from = from };
    self.metal_dirty = true;
}

pub fn clearScmPending(self: *AppSession) void {
    if (self.scm_pending) |pending| {
        self.allocator.free(pending.path);
        self.scm_pending = null;
    }
}

/// 섹션 헤더의 일괄 `+`/`−`. **방향은 host가 지금 상태로 다시 정한다**(intent가 방향을 싣지 않는 이유 —
/// published tree와 host 상태가 어긋날 수 있다).
/// 그 저장소의 **모든 변경**을 스테이지한다(②c). `git add -A`라 경로를 싣지 않는다 — 화면에 안 보이는
/// 파일(10행 상한에 걸린 것)까지 드는 것이 "모두"의 뜻이다.
fn submitStageAllFor(self: *AppSession, repo: []const u8) void {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo, &rows_buf, &scratch) orelse {
        // **감추지 않고 이유를 말한다** — 버튼은 꺼진 색이지만 눌리기는 한다.
        setScmWriteNotice(self, maru.i18n.t(.scm_repo_unread));
        return;
    };
    if (!hasUnstaged(model.rows)) {
        setScmWriteNotice(self, maru.i18n.t(.scm_nothing_to_stage));
        return;
    }
    _ = submitWrite(self, repo, .stage_all, &.{});
}

/// 스테이지할 것이 남아 있나(= `변경 사항` 그룹에 파일이 있나). **충돌 행은 세지 않는다** — `git add`가
/// 충돌을 "해결됨"으로 표시하므로 그 행은 일괄 대상이 아니다(모델이 이미 `.none`으로 준다).
fn hasUnstaged(rows: []const scm_view.Row) bool {
    for (rows) |row| switch (row) {
        .file => |file| {
            if (file.section == .changes and file.action == .stage) return true;
        },
        else => {},
    };
    return false;
}

fn submitSectionWrite(self: *AppSession, ref: component.ids.SectionRef) void {
    const repo = repoPathAt(self, ref.repo_index) orelse return;
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo, &rows_buf, &scratch) orelse return;
    const target = switch (ref.section) {
        .staged => scm_view.Section.staged,
        .changes => scm_view.Section.changes,
    };
    const kind = git_write_command.kindForSection(target, model.head.unborn);
    // `_all` 변종은 경로를 받지 않는다. **그래서 화면에 안 보이는 파일까지 든다** — 그것이 "모두"의 뜻이고,
    // 10행 상한에 걸려 접힌 파일도 사용자가 기대하는 대상이다.
    _ = submitWrite(self, repo, kind, &.{});
}

/// 쓰기 하나를 건다. **in-flight 하나**(§6) — 도는 동안 눌린 것은 흘린다(큐를 쌓으면 오래된 클릭이
/// 뒤늦게 저장소를 바꾼다).
fn submitWrite(self: *AppSession, repo: []const u8, kind: git_write_command.Kind, paths: []const []const u8) bool {
    // **두 번째 겹**(RS2 적대적 검증 3회차). 인텐트 게이트가 첫 겹이지만 쓰기를 거는 길이 그것만이
    // 아니다 — 커밋은 키 입력 경로에서도 들어온다(`settleCommitInput`). 로컬 index 를 만지는 자리마다
    // 묻는 대신, **그 자리로 들어가는 마지막 문**에서 한 번 더 본다.
    if (git_ops.scmTargetIsRemote(self)) {
        setScmWriteNotice(self, maru.i18n.t(.scm_remote_read_only));
        return false;
    }
    if (self.scm_write_inflight != 0) return false;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return false;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return false;
    }
    self.scm_write_seq += 1;
    if (!self.git_backend.?.submitWrite(git_exe, repo, kind, paths, null, self.scm_write_seq)) return false;
    self.scm_write_inflight = self.scm_write_seq;
    rememberWriteRepo(self, repo);
    clearScmWriteError(self);
    self.metal_dirty = true;
    return true;
}

pub fn clearScmWriteError(self: *AppSession) void {
    if (self.scm_write_error) |err| {
        self.allocator.free(err);
        self.scm_write_error = null;
    }
    // 사유와 그 **소속**은 함께 산다 — 하나만 남으면 다음 안내가 엉뚱한 저장소 아래에 선다.
    if (self.scm_write_error_repo) |repo| {
        self.allocator.free(repo);
        self.scm_write_error_repo = null;
    }
    self.scm_write_error_blocking = false;
}

/// 끝난 쓰기를 거둔다. **성공이든 실패든 목록을 다시 읽는다** — 성공이면 사실이 바뀌었고, 실패면 우리가
/// 아는 상태와 저장소가 갈렸다는 뜻이다(§5·§7). 읽기는 여기서 **한 번만** 건다.
pub fn drainScmWrite(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeWriteResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    if (taken.request_id != self.scm_write_inflight) return; // 낡은 결과는 버린다
    self.scm_write_inflight = 0;
    self.metal_dirty = true;
    // **성공이든 실패든 낙관을 걷는다.** 뒤이어 거는 읽기가 사실을 싣고 오므로, 낙관을 남겨 두면 그
    // 사실 위에 옛 추측이 덧그려진다(§7 — 실패하면 되돌린다).
    clearScmPending(self);

    // 커밋이었으면 **성공이든 실패든** 메시지 파일을 지우고, 성공했으면 상자를 비운다.
    if (self.scm_commit_inflight) finishCommit(self, taken.ok());
    if (!taken.ok()) {
        clearScmWriteError(self);
        self.scm_write_error = writeErrorText(self, taken);
    }
    // 커밋 목록도 낡았다 — 방금 만든 커밋이 히스토리에 없으면 커밋이 안 된 줄 안다.
    invalidateScmLog(self);
    // 쓰기가 끝난 **뒤** 한 번 읽는다(§6-1 — 쓰기마다 읽기를 걸면 `+`를 빠르게 누를 때 프로세스가 줄줄이 뜬다).
    // **어느 저장소를 읽느냐**가 ②d에서 갈린다: 비활성 저장소에 쓴 것이면 목록 읽기(활성 저장소)는
    // 그 사실을 모르므로 그 저장소의 머리 줄 읽기를 낡았다고 표시한다.
    if (self.scm_write_repo) |repo| {
        const current = self.git_repo orelse "";
        if (!std.mem.eql(u8, repo, current)) {
            markRepoStatusStaleFor(self, repo);
            return;
        }
    }
    git_ops.refreshGitStatus(self);
}

/// 화면에 낼 실패 사유. **redact하고 자른다**(§5) — 홈 경로·IP·`user@host`가 stderr에 섞이고, hook 출력은
/// 수천 줄이 될 수 있다. trace·로그에는 싣지 않는다(화면은 방금 누른 동작의 결과, 로그는 나중에 공유되는 산출물).
fn writeErrorText(self: *AppSession, result: git_backend_mod.WriteResult) ?[]u8 {
    if (!result.spawned) return self.allocator.dupe(u8, maru.i18n.t(.scm_git_spawn_failed)) catch null;
    const raw = std.mem.trimEnd(u8, result.stderr, "\n");
    if (raw.len == 0) return self.allocator.dupe(u8, maru.i18n.t(.scm_git_command_failed)) catch null;
    // **마지막 줄만** 낸다. 목록 안 한 줄짜리 자리라 여러 줄을 담을 수 없고, hook 거부 사유는 보통 끝에 온다.
    const last_break = std.mem.lastIndexOfScalar(u8, raw, '\n');
    const last = if (last_break) |at| raw[at + 1 ..] else raw;
    const anonymized = redact.anonymizeAlloc(self.allocator, last, .{}) catch return null;
    defer self.allocator.free(anonymized);
    const max_cols: usize = 160;
    const clipped = if (anonymized.len > max_cols) anonymized[0..max_cols] else anonymized;
    return self.allocator.dupe(u8, clipped) catch null;
}

fn sectionIndex(section: component.types.Section) usize {
    return switch (section) {
        .staged => @intFromEnum(scm_view.Section.staged),
        .changes => @intFromEnum(scm_view.Section.changes),
    };
}

const testing = std.testing;

test "상태 종류: 충돌·추적되지 않음·추가·삭제가 서로 다른 축으로 간다" {
    // 색은 종류가 정하고(component), 종류는 여기서 정한다 — 두 곳이 같은 판정을 하면 갈린다.
    try testing.expectEqual(component.types.StatusKind.conflicted, scm_items.statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .none, .conflicted = true }));
    try testing.expectEqual(component.types.StatusKind.added, scm_items.statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .stage, .untracked = true }));
    try testing.expectEqual(component.types.StatusKind.added, scm_items.statusOf(.{ .section = .staged, .path = "a", .letter = 'A', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.deleted, scm_items.statusOf(.{ .section = .staged, .path = "a", .letter = 'D', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.modified, scm_items.statusOf(.{ .section = .staged, .path = "a", .letter = 'M', .action = .unstage }));
}

test "섹션 값은 두 모듈 사이에서 1:1이다" {
    // component는 session 모듈을 import하지 않으므로 이 변환이 유일한 다리다. 값이 갈리면 여기서 걸린다.
    try testing.expectEqual(component.types.Section.staged, scm_items.sectionOf(.staged));
    try testing.expectEqual(component.types.Section.changes, scm_items.sectionOf(.changes));
    try testing.expectEqual(@intFromEnum(scm_view.Section.staged), sectionIndex(.staged));
    try testing.expectEqual(@intFromEnum(scm_view.Section.changes), sectionIndex(.changes));
}

test "draw 예산은 최악 행 구성을 담는다(모자라면 도크가 통째로 빈다)" {
    // 이 테스트가 없으면 view에 op을 하나 더하는 변경이 조용히 예산을 넘기고, 증상은 "그 op이 안 보임"이
    // 아니라 **도크 전체가 빈 화면**이다(실제로 겪었다 — 증감을 두 색으로 가르면서 행당 5 → 6이 됐다).
    // 그래서 제품 경로와 **같은 `drawBudget`**으로 버퍼를 잡고, 가장 op을 많이 내는 행 구성으로 돌린다.
    const component_types = component.types;
    var items: [12]component_types.Item = undefined;
    // 그룹 헤더 둘 + 파일 열 — 파일 행이 op을 가장 많이 낸다(아이콘·이름·경로·증감 둘·상태 문자).
    items[0] = .{ .section = .{ .section = .staged, .count = 5, .collapsed = false, .action = .none } };
    items[6] = .{ .section = .{ .section = .changes, .count = 5, .collapsed = false, .action = .none } };
    // 나머지 항목 종류도 예산에 든다 — 서식 문자열이 component 것이라 platform은 길이를 모른다.
    items[10] = .{ .more = .{ .section = .changes, .hidden = std.math.maxInt(u32) } };
    items[11] = .{ .notice = "git 출력이 상한에 걸려 잘렸다 — 뒤쪽 파일은 오지 않았다" };
    for (&items, 0..) |*item, index| {
        if (index == 0 or index == 6 or index == 10 or index == 11) continue;
        item.* = .{
            .file = .{
                .name = "some-file-name.zig",
                // **경로에 상한이 없다** — `name`+`dir`이 곧 git 경로다. 행당 고정 바이트로 예산을 잡으면
                // 어떤 값을 골라도 그보다 긴 저장소가 있고, 넘치는 순간 도크가 통째로 빈다.
                .dir = "src/" ++ "very-long-directory-segment/" ** 45,
                .status = .modified,
                .letter = 'M',
                .added = 123,
                .removed = 456,
                .has_delta = true,
                .action = .none,
            },
        };
    }

    const props: component_types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 480 },
        .items = &items,
        // 숫자는 **u32 최댓값**으로 민다 — 자릿수를 10으로 잡아 둔 예산이 실제로 그만큼 버티는지가
        // 산술이 아니라 테스트로 확인돼야 한다(브랜치 줄은 계산상 여유가 1바이트뿐이었다).
        .branch = "feat/a-really-long-branch-name-that-someone-will-eventually-create",
        .has_ab = true,
        .ahead = std.math.maxInt(u32),
        .behind = std.math.maxInt(u32),
        .summary = .{ .added = std.math.maxInt(u32), .removed = std.math.maxInt(u32) },
        .changed_file_count = std.math.maxInt(u32),
    };

    const sizes = component.build.bufferSizes(&items);
    const allocator = testing.allocator;
    const nodes = try allocator.alloc(chrome.ui.tree.UiNode, sizes.nodes);
    defer allocator.free(nodes);
    const entries = try allocator.alloc(chrome.ui.tree.RectEntry, sizes.entries);
    defer allocator.free(entries);
    const layout_items = try allocator.alloc(chrome.ui.layout.Item, sizes.layout_items);
    defer allocator.free(layout_items);
    const flex_scratch = try allocator.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch);
    defer allocator.free(flex_scratch);
    const child_rects = try allocator.alloc(chrome.ui.layout.UiRect, sizes.child_rects);
    defer allocator.free(child_rects);
    const actions = try allocator.alloc(component.ids.Entry, sizes.actions);
    defer allocator.free(actions);

    const frame = try component.build.build(props, .{
        .nodes = nodes,
        .entries = entries,
        .layout_items = layout_items,
        .flex_scratch = flex_scratch,
        .child_rects = child_rects,
        .actions = actions,
    });

    const budget = component.view.drawBufferSizes(props, frame.tree.entries.len);
    const ops = try allocator.alloc(chrome.draw.Op, budget.ops);
    defer allocator.free(ops);
    const runs = try allocator.alloc(chrome.draw.Run, budget.runs);
    defer allocator.free(runs);
    const text_bytes = try allocator.alloc(u8, budget.text_bytes);
    defer allocator.free(text_bytes);

    const tokens = chrome.tokens.Tokens.base(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 16, .g = 17, .b = 18 },
    });
    // 호버가 걸린 행도 동작 글리프를 하나 더 낸다 — 그 최악까지 담아야 한다.
    const hovered: chrome.ui.interaction.InteractionState = .{ .hovered = component.build.NodeIds.item(1) };
    const draws = try component.view.view(props, frame, hovered, &tokens, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    });
    try testing.expect(draws.ops.len > 0);
}

test "스크롤한 창에서도 intent는 모델 인덱스를 싣는다" {
    // **P1b가 창 자리를 실어 내보냈다.** 그러면 목록을 스크롤한 뒤 누른 행과 열리는(그리고 스테이지되는)
    // 행이 어긋난다 — host가 그 값으로 모델을 다시 조회하기 때문이다. 쓰기가 붙은 지금은 그 어긋남이
    // "엉뚱한 파일이 열린다"가 아니라 **"엉뚱한 파일이 스테이지된다"**가 된다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .changes, .count = 3, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "a.zig", .letter = 'M', .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "b.zig", .letter = 'M', .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "c.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = scm_items.itemFor(row, 0, index, null, @splat(false));
    }

    // 창이 2번째 행부터 시작한다고 하자(앞 둘은 스크롤아웃).
    const window = items[2..];
    try testing.expectEqual(@as(u32, 2), window[0].file.model_index);
    try testing.expectEqual(@as(u32, 3), window[1].file.model_index);
}

test "낙관적 반영: 그 행만 옮기고 개수·증감·동작은 낙관하지 않는다 (§7)" {
    // `+`를 누르면 화면이 **즉시** 바뀐다(안 그러면 두 번 누르고, 두 번째는 in-flight라 흘려져
    // "안 눌렸다"로 읽힌다). 다만 낙관은 **그 행 하나의 자리**뿐이다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .staged, .count = 1, .action = .unstage } },
        .{ .file = .{ .section = .staged, .path = "kept.zig", .letter = 'M', .action = .unstage } },
        .{ .section = .{ .section = .changes, .count = 2, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "moving.zig", .letter = 'M', .action = .stage, .added = 3, .removed = 1 } },
        .{ .file = .{ .section = .changes, .path = "other.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = scm_items.itemFor(row, 0, index, null, @splat(false));
    }
    // 낙관 없이는 원래 자리다.
    try testing.expectEqualStrings("moving.zig", items[3].file.name);

    var session: AppSession = undefined;
    session.allocator = testing.allocator;
    session.scm_pending = .{ .path = try testing.allocator.dupe(u8, "moving.zig"), .from = .changes };
    defer testing.allocator.free(session.scm_pending.?.path);

    applyScmPending(&session, &rows, &items);

    // ① 그 행이 **스테이지된 변경** 헤더 바로 뒤로 옮겨졌다.
    try testing.expectEqualStrings("moving.zig", items[1].file.name);
    // ② 나머지 행들은 순서를 지킨다.
    try testing.expectEqualStrings("kept.zig", items[2].file.name);
    try testing.expectEqualStrings("other.zig", items[4].file.name);
    // ③ **개수는 낙관하지 않는다** — 헤더 숫자는 그대로다(실제 결과가 온 뒤에 바뀐다).
    try testing.expectEqual(@as(u32, 1), items[0].section.count);
    try testing.expectEqual(@as(u32, 2), items[3].section.count);
    // ④ **증감을 지운다** — 그 숫자는 옛 축(작업트리)의 것이고 새 자리의 축을 우리는 아직 모른다.
    try testing.expect(!items[1].file.has_delta);
    // ⑤ **동작을 끈다** — 쓰기가 도는 동안 두 번째 클릭은 어차피 흘려진다.
    try testing.expectEqual(component.types.RowAction.none, items[1].file.action);
    // ⑥ 상태 문자는 그대로다(새 축의 글자를 추측하지 않는다).
    try testing.expectEqual(@as(u8, 'M'), items[1].file.letter);
}

test "낙관적 반영: 도착 그룹이 화면에 없으면 옮기지 않는다" {
    // 개수 0인 섹션은 헤더를 안 낸다. 갈 곳이 없는데 원래 자리에서 지우면 **그 파일이 잠깐 사라져
    // 보인다** — 사용자가 방금 누른 파일이 목록에서 없어지는 것이 가장 나쁜 실패 모드다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .changes, .count = 1, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "only.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = scm_items.itemFor(row, 0, index, null, @splat(false));
    }

    var session: AppSession = undefined;
    session.allocator = testing.allocator;
    session.scm_pending = .{ .path = try testing.allocator.dupe(u8, "only.zig"), .from = .changes };
    defer testing.allocator.free(session.scm_pending.?.path);

    applyScmPending(&session, &rows, &items);
    // 그대로다 — 파일이 사라지지 않는다.
    try testing.expectEqualStrings("only.zig", items[1].file.name);
    try testing.expectEqual(component.types.RowAction.stage, items[1].file.action);
}

// ── 키 입력(P3c) ────────────────────────────────────────────────────────────────
//
// 주소창(`web.zig handleAddrEditKey`)과 **같은 배치**를 따른다 — macOS 줄 편집 관례가 한 벌이어야
// 사용자가 두 입력란에서 다른 규칙을 배우지 않는다. 다른 것은 세로 축뿐이다(↑↓·Home/End·Enter).

/// 커밋 메시지의 단어 구분자. **개행이 핵심이다**(§12.3 ④) — 안 넘기면 ⌥←/→가 줄 끝과 다음 줄
/// 첫 단어를 한 단어로 붙인다.
const commit_word_separators = text_area.word_separators;

/// 커밋 상자가 활성일 때의 키 처리. 반환값은 "이 키를 먹었나"이고, 먹지 않은 키는 호출자가 원래
/// 경로로 보낸다.
pub fn handleCommitKey(self: *AppSession, ev: chrome.input.InputEvent) bool {
    if (self.scm_commit_focus_repo == null) return false;
    const field = &self.scm_commit_field;
    switch (ev) {
        .key => |k| switch (k.key) {
            // Esc는 **편집을 끝내되 글자는 남긴다.** 지우면 사용자가 쓴 것이 예고 없이 사라진다 —
            // 취소의 뜻이 "내가 쓴 것을 버린다"인지 "커밋을 그만둔다"인지 알 수 없으므로 덜 파괴적인
            // 쪽을 고른다.
            .escape => blurCommit(self),
            .enter => {
                // ⌘Enter = 커밋(§12.2). 실행 배선은 P3c-2이고, 지금은 그 자리만 지킨다.
                if (k.mods.command) return true;
                field.insertText(self.allocator, "\n") catch {};
                afterEdit(self);
            },
            .left => {
                if (k.mods.command) commitHome(self, k.mods.shift) // ⌘← = **시각 행** 처음(§12.3 ⑤)
                else if (k.mods.option) field.moveWordLeft(commit_word_separators, k.mods.shift) else field.moveLeft(k.mods.shift);
                afterMove(self);
            },
            .right => {
                if (k.mods.command) commitEnd(self, k.mods.shift) else if (k.mods.option) field.moveWordRight(commit_word_separators, k.mods.shift) else field.moveRight(k.mods.shift);
                afterMove(self);
            },
            .up => {
                commitVertical(self, -1, k.mods.shift);
                afterMove(self);
            },
            .down => {
                commitVertical(self, 1, k.mods.shift);
                afterMove(self);
            },
            .backspace => {
                if (k.mods.command) field.deleteToLineStart() else if (k.mods.option) field.deleteWordBackward(commit_word_separators) else field.deleteBackward();
                afterEdit(self);
            },
            .char => {
                if (k.mods.command and (k.codepoint == 'a' or k.codepoint == 'A')) {
                    field.selectAll();
                    self.metal_dirty = true;
                    return true;
                }
                if (k.mods.control and (k.codepoint == 'a' or k.codepoint == 'A')) {
                    commitHome(self, k.mods.shift); // ⌃A 줄 시작(emacs)
                    afterMove(self);
                    return true;
                }
                if (k.mods.command and (k.codepoint == 'x' or k.codepoint == 'X')) {
                    cutCommitSelection(self);
                    return true;
                }
                if (k.mods.control and (k.codepoint == 'e' or k.codepoint == 'E')) {
                    commitEnd(self, k.mods.shift);
                    afterMove(self);
                    return true;
                }
                // 그 외 수정자 조합은 **먹지 않는다** — ⌘S·⌘W 같은 앱 단축키가 상자 안에서 죽으면
                // 사용자는 입력란을 벗어나야만 앱을 쓸 수 있게 된다.
                if (k.mods.command or k.mods.control or k.mods.option) return false;
                // **제어 codepoint는 넣지 않는다.** Enter·Tab·Backspace는 각자 다른 key로 오므로 여기
                // `.char`로 오는 C0/DEL은 우리가 글자로 셀 수 없는 것이고, 들어가면 화면에서는 폭 0이라
                // 안 보이는 채 커밋 메시지에만 남는다(붙여넣기 위생과 같은 규칙).
                if (k.codepoint < 0x20 or k.codepoint == 0x7F) return true;
                field.insertCp(self.allocator, k.codepoint) catch {};
                afterEdit(self);
            },
            .tab, .other => return false,
        },
        .pointer => return false, // 진입은 포인터 경로(`focusCommitAt`)가 이미 처리했다
    }
    return true;
}

/// 글자가 바뀐 뒤 — 스크롤을 caret에 맞추고 다시 그린다. **상자 높이가 함께 바뀐다**(랩 결과가 달라지므로).
fn afterEdit(self: *AppSession) void {
    scrollCommitToCaret(self);
    self.scm_commit_reveal = true;
    self.metal_dirty = true;
}

/// caret만 움직인 뒤. 글자는 그대로라 상자 높이는 안 바뀌지만 스크롤은 따라가야 한다.
fn afterMove(self: *AppSession) void {
    scrollCommitToCaret(self);
    self.scm_commit_reveal = true;
    self.metal_dirty = true;
}

/// ↑/↓ — **시각 행** 단위(§12.2). 논리 줄 단위면 접힌 줄 안에서 caret이 건너뛴다.
fn commitVertical(self: *AppSession, delta: i32, extend: bool) void {
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const field = &self.scm_commit_field;
    const wrapped = text_area.wrap(field.text.items, commitViewCols(self), true, &lines);
    const next = text_area.moveVertical(field.text.items, wrapped, field.caret, delta);
    applyCaret(self, next, extend);
}

fn commitHome(self: *AppSession, extend: bool) void {
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const field = &self.scm_commit_field;
    const wrapped = text_area.wrap(field.text.items, commitViewCols(self), true, &lines);
    applyCaret(self, text_area.lineStart(wrapped, field.caret), extend);
}

fn commitEnd(self: *AppSession, extend: bool) void {
    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const field = &self.scm_commit_field;
    const wrapped = text_area.wrap(field.text.items, commitViewCols(self), true, &lines);
    applyCaret(self, text_area.lineEnd(wrapped, field.caret), extend);
}

/// caret을 옮기며 선택을 유지/해제한다. **`TextField`의 규칙과 같아야 한다** — ⇧면 anchor를 두고
/// 늘리고, 아니면 선택을 버린다(주소창의 `moveLeft(extend)`가 하는 것과 같은 일).
fn applyCaret(self: *AppSession, offset: usize, extend: bool) void {
    const field = &self.scm_commit_field;
    if (extend) {
        field.selectTo(offset);
    } else {
        field.caret = offset;
        field.clearSelection();
    }
}

/// IME 조합 글자를 세운다(입력기가 준 그대로). 확정은 `commitCommitPreedit`이 한다.
pub fn setCommitPreedit(self: *AppSession, bytes: []const u8) void {
    self.scm_commit_field.setPreedit(self.allocator, bytes) catch return;
    scrollCommitToCaret(self);
    self.metal_dirty = true;
}

/// 조합을 확정한다 — `commitPreedit`이 조합 글자를 본문에 넣고 조합 상태를 비운다.
pub fn commitCommitPreedit(self: *AppSession) void {
    if (self.scm_commit_field.commitPreedit(self.allocator)) afterEdit(self);
}

/// 입력기가 확정한 글자를 넣는다(한글 등 — 평문 타이핑도 macOS에서는 이 경로다). 붙여넣기도 같은
/// 문으로 들어온다.
///
/// **위생 처리를 한다**(주소창과 같은 규율, 다만 허용 집합이 다르다):
///  - **개행과 탭은 남긴다** — 커밋 메시지는 여러 줄이 정상이고(제목·빈 줄·본문), 탭은 §12.3 ③대로
///    전개하지 않고 한 칸으로 센다. 주소창이 개행을 지우는 이유는 URL이 한 줄이기 때문이다.
///  - `\r`은 **버린다**(CRLF 클립보드). 남기면 커밋 메시지에 CR이 섞여 들어가고, 화면에서는 폭 0
///    글자라 아무 표시도 없이 사라진다 — 저장되는 것과 보이는 것이 달라진다.
///  - 나머지 C0 제어문자·DEL도 버린다(ESC·FF·VT…). 위와 같은 이유다.
///  - **유효 UTF-8만** 넣는다. 손상 바이트가 들어가면 폭 계산(`clusterCols`)과 랩이 어긋나 caret이 민다.
pub fn insertCommitText(self: *AppSession, bytes: []const u8) void {
    if (self.scm_commit_focus_repo == null) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    buf.ensureTotalCapacity(self.allocator, bytes.len) catch return;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1; // 손상 lead 바이트 skip
            continue;
        };
        if (i + n > bytes.len) break; // 잘린 꼬리
        const cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch {
            i += n;
            continue;
        };
        const keep = cp == '\n' or cp == '\t' or (cp >= 0x20 and cp != 0x7F);
        if (keep) buf.appendSlice(self.allocator, bytes[i .. i + n]) catch return;
        i += n;
    }
    if (buf.items.len == 0) return;
    self.scm_commit_field.insertText(self.allocator, buf.items) catch return;
    afterEdit(self);
}

/// 커밋 상자의 caret rect(창 좌표) — IME 후보창을 그 자리에 띄운다. **그린 것과 같은 기하**를 쓴다:
/// published 상자 rect + 같은 랩 결과. 상자가 아직 안 그려졌으면 null이고 호출자가 폴백한다.
pub fn commitCaretRect(self: *AppSession) ?chrome.draw.Rect {
    if (self.scm_commit_focus_repo == null) return null;
    const rect = commitBoxRect(self) orelse return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));

    var lines: [commit_wrap_max_rows]text_area.VisualLine = undefined;
    const text = commitDisplayText(self);
    const cols = commitViewCols(self);
    const wrapped = text_area.wrap(text, cols, true, &lines);
    const caret = commitDisplayCaret(self);
    const row = text_area.lineAt(wrapped, caret);
    const line_h = commitLineHeightPx(self);

    const col: u32 = if (wrapped.lines.len == 0) 0 else blk: {
        const line = wrapped.lines[row];
        const line_view: text_field.View = .{
            .text = text[line.start..line.end],
            .caret = @min(caret -| line.start, line.end - line.start),
        };
        break :blk text_field.fieldLayout(line_view, .{ .cols = cols }).caret_col;
    };
    const visible_row = row -| self.scm_commit_first_row;
    return .{
        .x = @intFromFloat(@as(f32, @floatFromInt(content.x)) + rect.x + @as(f32, @floatFromInt(m.inset_x + col * self.cell_width_px))),
        .y = @intFromFloat(@as(f32, @floatFromInt(content.y)) + rect.y + @as(f32, @floatFromInt(m.commit_pad_y + @as(u32, @intCast(visible_row)) * line_h))),
        .w = @max(self.cell_width_px, 1),
        .h = line_h,
    };
}

/// ⌘X — 선택을 **먼저 클립보드-쓰기 큐에 캡처**한 뒤 지운다(주소창과 같은 경로·같은 순서). 바이트를
/// 넘기지 "지금 선택을 복사해"가 아니므로 비동기 순서 문제가 없다. 선택 없음·OOM이면 무동작(글자 보존).
fn cutCommitSelection(self: *AppSession) void {
    const sel = self.scm_commit_field.selection orelse return;
    const slice = self.scm_commit_field.text.items[sel.lo()..sel.hi()];
    if (slice.len == 0) return;
    const captured = self.allocator.dupe(u8, slice) catch return;
    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
    self.chrome_clipboard_write = captured;
    _ = self.scm_commit_field.deleteSelection();
    afterEdit(self);
}

// ── 저장소별 초안(사용자 결정 2026-08-16) ─────────────────────────────────────────
//
// 목록·스크롤·선택은 저장소가 갈릴 때 **버린다**(`clearScmResult` — "다른 목록이므로 의미가 없다").
// 메시지는 다르다: 사용자가 쓴 글이라 버리면 예고 없이 사라지고, 그대로 두면 **다른 저장소를 향해
// 쓴 글로 커밋**하게 된다. 그래서 버리지도 두지도 않고 **저장소마다 따로 든다**.
//
// 워크트리도 자연히 갈린다 — 링크된 워크트리는 루트 경로가 다르므로 키가 다르다.

/// 지금 편집 중인 글을 그 저장소의 초안으로 담는다. 빈 글은 담지 않고, 있던 초안은 지운다 —
/// 비운 것도 사용자의 뜻이다.
pub fn stashCommitDraft(self: *AppSession, repo: []const u8) void {
    const text = self.scm_commit_field.text.items;
    for (self.scm_commit_drafts.items, 0..) |*draft, index| {
        if (!std.mem.eql(u8, draft.repo, repo)) continue;
        if (text.len == 0) { // 비웠으면 초안도 없앤다
            self.allocator.free(draft.repo);
            self.allocator.free(draft.text);
            _ = self.scm_commit_drafts.orderedRemove(index);
            return;
        }
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(draft.text);
        draft.text = copy;
        return;
    }
    if (text.len == 0) return;
    // **가장 오래된 것부터** 버린다(가장 앞이 가장 오래됐다 — 새 초안은 뒤에 붙는다).
    while (self.scm_commit_drafts.items.len >= app_session_mod.scm_commit_draft_max) {
        const oldest = self.scm_commit_drafts.orderedRemove(0);
        self.allocator.free(oldest.repo);
        self.allocator.free(oldest.text);
    }
    const repo_copy = self.allocator.dupe(u8, repo) catch return;
    const text_copy = self.allocator.dupe(u8, text) catch {
        self.allocator.free(repo_copy);
        return;
    };
    self.scm_commit_drafts.append(self.allocator, .{ .repo = repo_copy, .text = text_copy }) catch {
        self.allocator.free(repo_copy);
        self.allocator.free(text_copy);
    };
}

/// 그 저장소의 초안을 편집기로 꺼낸다(없으면 빈 상자). **caret·스크롤도 함께 초기화한다** — 옛
/// 저장소의 caret 오프셋은 새 글에서 다른 자리를 가리킨다.
pub fn restoreCommitDraft(self: *AppSession, repo: []const u8) void {
    self.scm_commit_field.clear();
    self.scm_commit_first_row = 0;
    for (self.scm_commit_drafts.items) |draft| {
        if (!std.mem.eql(u8, draft.repo, repo)) continue;
        self.scm_commit_field.setText(self.allocator, draft.text) catch self.scm_commit_field.clear();
        break;
    }
    self.metal_dirty = true;
}

/// 저장소가 갈릴 때 초안을 옮겨 담는다. **`rememberGitRepo`가 부른다** — 그 함수가 옛 저장소와 새
/// 저장소를 동시에 아는 유일한 자리다.
pub fn switchCommitDraft(self: *AppSession, from: ?[]const u8, to: []const u8) void {
    if (from) |old| {
        if (std.mem.eql(u8, old, to)) return;
        stashCommitDraft(self, old);
        restoreCommitDraft(self, to);
        return;
    }
    // **저장소를 처음 알게 된 순간에는 상자를 지우지 않는다.** 사용자는 읽기가 끝나기 전에도 타이핑할
    // 수 있고(도크는 열리자마자 상자를 보여 준다), 그 글은 "지금 보고 있는 저장소"를 향해 쓴 것이다.
    // 지우면 첫 읽기가 끝나는 순간 쓴 글이 사라진다 — 제품 캡처에서 실제로 그랬다(2026-08-16).
    //
    // 쓰던 글이 있으면 그것이 이 저장소의 초안이 된다(떠날 때 그 키로 담긴다). 비어 있을 때만 꺼낸다.
    if (self.scm_commit_field.text.items.len > 0) return;
    restoreCommitDraft(self, to);
}

// ── 커밋 실행(P3c-2) ───────────────────────────────────────────────────────────

/// 커밋 메시지를 담을 임시 파일 경로. **저장소 밖**이다(캐시 디렉터리) — 저장소 안에 두면 그 파일이
/// 작업트리에 나타나 목록에 뜨고, 최악에는 `add -A`가 자기를 담는다(턴 스냅샷 index가 같은 이유로
/// 캐시에 산다). 창마다 다른 이름을 써서 두 창이 동시에 커밋해도 서로의 메시지를 덮지 않는다.
pub fn testCommitMessagePath(self: *AppSession, buf: []u8) ?[]const u8 {
    return commitMessagePath(self, buf);
}

fn commitMessagePath(self: *AppSession, buf: []u8) ?[]const u8 {
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len == 0) return null;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrintZ(&dir_buf, "{s}/.cache/maru", .{home})) |dir| {
        _ = std.c.mkdir(dir.ptr, 0o700);
    } else |_| {}
    return std.fmt.bufPrint(buf, "{s}/.cache/maru/commit-msg-{d}", .{ home, @intFromPtr(self) }) catch null;
}

/// 커밋을 건다. **메시지는 argv가 아니라 파일로 간다**(쓰기 문서 §2 — 여러 줄·따옴표·비ASCII를 argv에
/// 싣지 않는다).
///
/// 켤 수 있는지는 **여기서 다시 본다** — published tree의 버튼은 언제나 눌리고, 그 프레임의 상태가
/// 지금과 다를 수 있다(§7 — 낙관하지 않는다).
/// 지금 편집 중인 상자의 저장소로 커밋한다(⌘Enter·기본 진입점).
pub fn submitCommit(self: *AppSession) void {
    const repo = focusedCommitRepo(self) orelse return;
    submitCommitFor(self, repo);
}

/// **그 저장소로** 커밋한다(②b — 버튼이 어느 저장소인지 실어 온다).
pub fn submitCommitFor(self: *AppSession, repo_path: []const u8) void {
    if (self.scm_write_inflight != 0) return; // 쓰기는 하나씩(§6-2)
    // **무엇을 커밋하는지 화면에 있으면 실행한다**(②d — 사용자 결정 2026-08-17). 판정의 출처는 그
    // 저장소의 `status`이고, 파일 줄도 그 출력에서 나온다. 아직 그 저장소를 못 읽었을 때만 막는다:
    // 그때는 스테이지 여부도 목록도 모르므로 "무엇을 커밋하는지" 모르는 채 실행하는 것이 된다.
    if (repoStatusTextFor(self, repo_path) == null and !isCurrentRepo(self, repo_path)) {
        setScmWriteBlocker(self, repo_path, maru.i18n.t(.scm_repo_unread));
        return;
    }
    // 조합 중이면 먼저 확정한다 — 안 그러면 화면에 보이는 글자가 메시지에서 빠진다.
    _ = self.scm_commit_field.commitPreedit(self.allocator);
    const message = std.mem.trim(u8, self.scm_commit_field.text.items, " \t\r\n");
    if (message.len == 0) {
        setScmWriteBlocker(self, repo_path, maru.i18n.t(.scm_need_commit_message));
        return;
    }
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo_path, &rows_buf, &scratch) orelse return;
    if (!model.has_staged) {
        // **감추지 않고 이유를 말한다.** 버튼은 꺼진 색이지만 눌리기는 하므로, 눌렀는데 아무 일도
        // 없으면 사용자는 앱이 멈춘 줄 안다.
        setScmWriteBlocker(self, repo_path, maru.i18n.t(.scm_nothing_staged));
        return;
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = commitMessagePath(self, &path_buf) orelse return;
    // 메시지는 **원문 그대로** 쓴다(끝에 개행 하나만 보장 — git이 마지막 줄을 삼키지 않게).
    writeCommitMessageFile(self, path, self.scm_commit_field.text.items) catch {
        setScmWriteBlocker(self, repo_path, maru.i18n.t(.scm_commit_msg_write_failed));
        return;
    };

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    // **그 상자의 저장소로 간다**(②b·②d) — 활성 저장소를 다시 구하면 화면에 보이는 상자와 커밋되는
    // 곳이 갈린다.
    const repo = repo_path;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_write_seq += 1;
    if (git_ops.scmTargetIsRemote(self)) {
        setScmWriteNotice(self, maru.i18n.t(.scm_remote_read_only)); // 위와 같은 두 번째 겹
        return;
    }
    if (!self.git_backend.?.submitWrite(git_exe, repo, .commit, &.{}, path, self.scm_write_seq)) {
        deleteCommitMessageFile(path);
        return;
    }
    self.scm_write_inflight = self.scm_write_seq;
    rememberWriteRepo(self, repo);
    self.scm_commit_inflight = true;
    self.scm_commit_started_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    clearScmWriteError(self);
    self.metal_dirty = true;
}

/// 메시지 파일을 쓴다(0600 — 커밋 메시지도 사용자의 글이다).
fn writeCommitMessageFile(self: *AppSession, path: []const u8, text: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < text.len) {
        const n = std.c.write(fd, text.ptr + written, text.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    // **끝에 개행 하나**를 보장한다 — 없으면 git이 마지막 줄을 그대로 쓰긴 하지만 로그 도구마다
    // 표시가 갈린다. 이미 개행으로 끝나면 더하지 않는다.
    if (text.len == 0 or text[text.len - 1] != '\n') {
        if (std.c.write(fd, "\n", 1) != 1) return error.WriteFailed;
    }
    _ = self;
}

fn deleteCommitMessageFile(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(path_z.ptr);
}

/// 커밋이 끝난 뒤 정리. **성공이든 실패든 메시지 파일을 지운다** — 남기면 다음 커밋이 남의 글을 쓸 수
/// 있고(같은 이름을 재사용한다), 무엇보다 사용자의 글이 캐시에 굴러다닌다.
fn finishCommit(self: *AppSession, ok: bool) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (commitMessagePath(self, &path_buf)) |path| deleteCommitMessageFile(path);
    self.scm_commit_inflight = false;
    self.scm_commit_started_ns = 0;
    if (!ok) return;
    // 성공했으면 상자를 비운다 — 그 글은 이제 커밋에 들어갔고, 남겨 두면 다음 커밋에 다시 들어간다.
    self.scm_commit_field.clear();
    self.scm_commit_first_row = 0;
    // 그 저장소의 초안도 함께 지운다(빈 글을 담으면 `stashCommitDraft`가 항목을 없앤다).
    var repo_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (git_ops.gitRepoRoot(self, &repo_buf)) |repo| stashCommitDraft(self, repo);
}

/// 테스트가 그 자리에 문구를 심는 유일한 통로. 제품 경로와 **같은 함수**를 태워, 지우는 규칙(저장소가
/// 바뀌면 사라진다)을 테스트가 자기만의 대입으로 우회하지 않게 한다.
pub fn setScmWriteNoticeForTest(self: *AppSession, text: []const u8) void {
    setScmWriteNotice(self, text);
}

pub fn setScmWriteBlockerForTest(self: *AppSession, repo_path: ?[]const u8, text: []const u8) void {
    setScmWriteBlocker(self, repo_path, text);
}

/// 지금 탭의 목록을 판정자가 그대로 본다. **제품이 그리는 것과 같은 함수**를 지난다 — 테스트가 자기
/// 목록을 만들면 "무엇이 화면에 서는가" 를 안 재게 된다.
pub fn projectTabForTest(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    return projectTab(self, arena);
}

/// 실패가 아니라 **안내**를 목록 위 한 줄로 낸다(빈 메시지·스테이지 0건처럼 git을 부르기도 전에 끝난
/// 경우). `scm_write_error`와 같은 자리를 쓰는 이유는 사용자가 방금 누른 동작의 결과를 같은 곳에서
/// 읽기 때문이다.
fn setScmWriteNotice(self: *AppSession, text: []const u8) void {
    clearScmWriteError(self);
    self.scm_write_error = self.allocator.dupe(u8, text) catch null;
    self.metal_dirty = true;
}

/// **동작이 멈춘 이유**를 그 저장소 자리에 낸다(사용자 제보 2026-08-31).
///
/// `setScmWriteNotice` 와 두 가지가 다르다 — 붉게 그려지고(`Item.blocker`), 그 저장소의 커밋 버튼
/// **바로 아래**에 선다. 「커밋했습니다」와 「왜 안 됐습니다」가 같은 톤·같은 자리면 사용자는 누른
/// 동작이 됐는지 아닌지를 화면에서 못 읽는다.
///
/// `repo_path` 가 `null` 이면 저장소에 안 매인 것이라 예전처럼 목록 맨 위에 서되, 색은 붉다.
fn setScmWriteBlocker(self: *AppSession, repo_path: ?[]const u8, text: []const u8) void {
    clearScmWriteError(self);
    self.scm_write_error = self.allocator.dupe(u8, text) catch null;
    if (repo_path) |path| self.scm_write_error_repo = self.allocator.dupe(u8, path) catch null;
    self.scm_write_error_blocking = true;
    self.metal_dirty = true;
}

/// 커밋이 오래 걸리는가. **프로세스를 죽이지 않는다**(쓰기 문서 §3) — hook은 테스트 전체를 돌 수도
/// 있고, 중간에 죽이면 index·`.git`이 어중간해진다. 상한은 **화면 문구**일 뿐이다.
pub fn commitRunState(self: *const AppSession) component.types.CommitRun {
    if (!self.scm_commit_inflight) return .idle;
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    const elapsed = now -| self.scm_commit_started_ns;
    return if (elapsed >= commit_slow_after_ns) .slow else .running;
}

/// 이 시간을 넘으면 "오래 걸리는 중"으로 말한다. hook이 도는 저장소에서 몇 초는 정상이므로 짧게 잡으면
/// 늘 그 문구가 뜬다.
const commit_slow_after_ns: i128 = 5 * std.time.ns_per_s;

// ── 저장소·워크트리 목록(P3d-①) ──────────────────────────────────────────────────
//
// 목록의 단위는 저장소가 아니라 **워크트리**다(§3.5.1c). 무엇이 뜨는지는 사용자 결정이다:
// **열린 터미널들이 선 저장소 + 각자의 워크트리**.

/// 목록 항목 하나(경로는 세션 버퍼를 빌린다 — 프레임 안에서만 유효하다).
pub const RepoEntry = maru.session.scm_repos.Entry;

/// **활성 터미널이 선 저장소 하나**(사용자 결정 2026-08-17). 열린 터미널을 전부 세면 목록이 여덟 줄이
/// 되어 "지금 무엇을 보고 있나"가 사라진다 — 실제로 그 화면을 보고 결정이 뒤집혔다.
///
/// 워크트리는 여기서 나오지 않는다: 그 저장소의 `worktree list`가 실려 오면 `collect`가 아래에 펼친다.
///
/// **원격·파일 Term이면 빈 목록이다** — `termCwd`가 null을 주고, 그건 "저장소가 없다"가 아니라 "물어볼
/// 곳이 없다"이다(§3.5의 3-상태 판정과 같은 규율). 그때는 `ensureListed`가 **마지막으로 읽은
/// 저장소**(`git_repo`)를 세우므로 화면은 그 자리에 그대로 머문다: 파일을 열었다고 목록이 비면,
/// 사용자가 한 일(파일 열기)과 화면이 잃은 것(저장소)이 대응하지 않는다.
fn collectRepoRoots(self: *AppSession, store: []u8, out: [][]const u8) usize {
    if (out.len == 0) return 0;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = git_ops.activeTerminalCwd(self, &cwd_buf) orelse return 0;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = app_session_mod.AppSession.repoRootFor(cwd, &root_buf) orelse return 0;
    if (root.len > store.len) return 0;
    @memcpy(store[0..root.len], root);
    out[0] = store[0..root.len];
    return 1;
}

/// 목록에 세울 항목들. **지금 읽어 둔 워크트리 목록만 편다** — 저장소마다 읽기를 새로 걸지 않는다
/// (읽기는 순차이고, N개를 동시에 띄우지 않는다는 §6 규율은 저장소가 여럿이어도 같다). 아직 안 읽은
/// 저장소는 자기 한 줄로만 뜨고, 그 저장소를 보는 순간 읽기가 나머지를 채운다.
/// 목록을 **저주기로만** 다시 걷는다. 주기는 cwd 캐시와 같은 500ms다 — 그 값이 곧 "터미널을 새로
/// 열었을 때 목록에 뜨기까지"의 상한이고, 이 목록을 만드는 walk-up이 경로 구성요소마다 `access(2)`를
/// 쓰므로 프레임마다 걸으면 blocking syscall이 초당 수천 번이 된다(cwd 캐시가 같은 이유로 있다).
const repo_list_poll_interval_ns: i128 = 500 * std.time.ns_per_ms;

/// 목록을 **지금 다시 걷게** 한다. 읽기 결과가 바뀌면 워크트리 목록도 바뀔 수 있으므로 그 순간
/// 무효화한다 — 주기(500ms)를 기다리면 방금 만든 워크트리가 그만큼 늦게 뜬다.
pub fn invalidateRepoList(self: *AppSession) void {
    self.scm_repo_list_walked_ns = 0;
}

/// 목록에 세울 저장소·워크트리(세션 소유 슬라이스). **캐시를 먼저 본다.**
pub fn repoEntries(self: *AppSession) maru.session.scm_repos.Collected {
    refreshRepoList(self);
    // 세션 저장소를 `Entry` 뷰로 빌려 준다 — 호출자는 읽기만 한다.
    var buf = self.scm_repo_entry_view[0..@min(self.scm_repo_list.items.len, self.scm_repo_entry_view.len)];
    for (self.scm_repo_list.items[0..buf.len], 0..) |entry, index| {
        buf[index] = .{ .path = entry.path, .origin = entry.origin, .primary = entry.primary };
    }
    return .{ .entries = buf, .truncated = self.scm_repo_list_truncated };
}

/// 주기가 지났으면 다시 걷는다. **문자열을 통째로 갈아 끼우지 않는다** — 같은 목록이면 그대로 두어
/// 프레임 사이에 슬라이스가 흔들리지 않게 한다(비교가 싸다: 경로 몇 개).
fn refreshRepoList(self: *AppSession) void {
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    // `walked_ns == 0`은 **무효화 신호**다(읽기 결과가 바뀐 직후) — 주기와 무관하게 다시 걷는다.
    if (self.scm_repo_list_walked_ns != 0 and now - self.scm_repo_list_walked_ns < repo_list_poll_interval_ns) return;
    self.scm_repo_list_walked_ns = now;

    var store: RepoEntryStore = .{};
    const fresh = collectRepoEntriesUncached(self, &store);
    // 같은 목록이면 손대지 않는다.
    if (fresh.entries.len == self.scm_repo_list.items.len) {
        var same = true;
        for (fresh.entries, self.scm_repo_list.items) |entry, cached| {
            if (!std.mem.eql(u8, entry.path, cached.path) or entry.primary != cached.primary) same = false;
        }
        if (same) {
            self.scm_repo_list_truncated = fresh.truncated;
            // 목록이 같아도 **요약 청소는 한다** — 캐시에 남은 옛 항목은 목록이 바뀌던 순간에 생겼고,
            // 그 뒤로 목록이 안정되면 여기 말고는 치울 자리가 없다(그러면 상한이 막힌다).
            dropStaleRepoStatus(self);
            return;
        }
    }
    for (self.scm_repo_list.items) |entry| {
        self.allocator.free(entry.path);
        self.allocator.free(entry.origin);
    }
    self.scm_repo_list.clearRetainingCapacity();
    for (fresh.entries) |entry| {
        const path = self.allocator.dupe(u8, entry.path) catch break;
        const origin = self.allocator.dupe(u8, entry.origin) catch {
            self.allocator.free(path);
            break;
        };
        self.scm_repo_list.append(self.allocator, .{ .path = path, .origin = origin, .primary = entry.primary }) catch {
            self.allocator.free(path);
            self.allocator.free(origin);
            break;
        };
    }
    self.scm_repo_list_truncated = fresh.truncated;
    dropStaleRepoStatus(self);
}

/// 목록에서 사라진 저장소의 머리 줄 요약을 버린다.
///
/// **안 버리면 상한이 막힌다**: 요약 캐시는 목록 상한(8)과 같은 상한을 두는데, 저장소를 여닫으며
/// 옛 항목이 쌓이면 그 자리가 차서 **새 저장소가 영영 `읽는 중…`으로 남는다**. 게다가 그 값들은 이미
/// 화면에 없는 저장소의 것이라 들고 있을 이유도 없다.
fn dropStaleRepoStatus(self: *AppSession) void {
    var index: usize = 0;
    while (index < self.scm_repo_status.items.len) {
        const entry = self.scm_repo_status.items[index];
        var listed = false;
        for (self.scm_repo_list.items) |repo| {
            if (std.mem.eql(u8, repo.path, entry.path)) listed = true;
        }
        if (listed) {
            index += 1;
            continue;
        }
        self.allocator.free(entry.path);
        self.allocator.free(entry.branch);
        if (entry.status_text.len > 0) self.allocator.free(entry.status_text);
        _ = self.scm_repo_status.orderedRemove(index);
    }
}

/// 목록을 **지금 실제로 걷는다**(캐시 없음). `refreshRepoList`만 부른다.
fn collectRepoEntriesUncached(self: *AppSession, store: *RepoEntryStore) maru.session.scm_repos.Collected {
    var root_count = collectRepoRoots(self, &store.path_bytes, &store.roots);
    // **우리가 읽은 저장소는 언제나 목록에 있다.** 보통은 터미널에서 나오지만, 그 터미널이 닫혔거나
    // 활성 Term이 파일 Term·원격이면 목록에서 빠질 수 있다 — 그때 목록을 그대로 두면 방금 읽어 화면에
    // 그리고 있는 저장소가 목록에 없는 모순이 된다(그 줄들이 붙을 머리 줄이 사라진다).
    if (self.git_repo) |repo| {
        root_count = maru.session.scm_repos.ensureListed(&store.roots, root_count, repo);
    }
    const roots = store.roots[0..root_count];
    var repos: [maru.session.scm_repos.max_entries]maru.session.scm_repos.Repo = undefined;
    var count: usize = 0;
    for (roots) |root| {
        if (count == repos.len) break;
        const worktrees = worktreesFor(self, root, &store.worktrees);
        repos[count] = .{
            .root = root,
            .worktrees = worktrees,
            // **주 워크트리는 git이 첫 줄로 말한다**(`worktree list --porcelain`). 우리가 선 자리로
            // 판정하면 워크트리에 선 터미널에서 신원이 뒤집힌다.
            .main = if (worktrees.len > 0) worktrees[0] else "",
        };
        count += 1;
    }
    return maru.session.scm_repos.collect(repos[0..count], &store.entries);
}

/// 그 저장소의 워크트리 경로들. **지금 결과에 실려 온 것만** 편다 — 다른 저장소의 목록을 그 저장소의
/// 것으로 쓰면 화면이 남의 워크트리를 그 밑에 매단다.
fn worktreesFor(self: *AppSession, root: []const u8, out: [][]const u8) []const []const u8 {
    const current = self.git_repo orelse return &.{};
    if (!std.mem.eql(u8, current, root)) return &.{};
    const result = self.git_result orelse return &.{};
    if (result.worktrees.len == 0) return &.{};
    var items: [maru.session.scm_repos.max_entries]maru.session.git_command.Worktree = undefined;
    const n = maru.session.git_command.collectWorktrees(result.worktrees, &items);
    var used: usize = 0;
    for (items[0..n]) |item| {
        if (used == out.len) break;
        // **사라진 워크트리는 세우지 않는다.** git이 `prunable`로 말해 준다 — 그 줄을 그리면 커밋 상자가
        // 달린 빈 줄이 되고, 읽기는 실패만 되풀이한다(제품 캡처 2026-08-17에서 실제로 그랬다).
        if (item.prunable) continue;
        out[used] = item.path;
        used += 1;
    }
    return out[0..used];
}

/// 목록을 만드는 동안 쓰는 버퍼 묶음. **호출자가 든다** — 이 층은 할당하지 않는다(프레임 arena와 같은 규율).
pub const RepoEntryStore = struct {
    roots: [maru.session.scm_repos.max_entries][]const u8 = undefined,
    worktrees: [maru.session.scm_repos.max_entries][]const u8 = undefined,
    entries: [maru.session.scm_repos.max_entries]maru.session.scm_repos.Entry = undefined,
    /// 루트 경로 문자열을 담는 자리. `termCwd`가 준 스택 버퍼는 호출이 끝나면 사라지므로 여기 옮겨 담는다.
    path_bytes: [maru.session.scm_repos.max_entries * std.fs.max_path_bytes]u8 = undefined,
};

/// 그 저장소가 접혀 있나. **경로가 키다** — 목록 자리는 터미널이 열리고 닫히며 움직인다.
pub fn repoCollapsed(self: *const AppSession, path: []const u8) bool {
    for (self.scm_repo_collapsed.items) |item| {
        if (std.mem.eql(u8, item, path)) return true;
    }
    return false;
}

/// 접기/펴기. **세션 한정**이다(§3.5.1c) — 목록 자체가 매번 새로 계산되는 값이라 접힘만 저장해도
/// 다음 실행의 목록과 대응이 보장되지 않는다(섹션 접힘과 같은 규율).
pub fn toggleRepoCollapsed(self: *AppSession, path: []const u8) void {
    for (self.scm_repo_collapsed.items, 0..) |item, index| {
        if (!std.mem.eql(u8, item, path)) continue;
        self.allocator.free(item);
        _ = self.scm_repo_collapsed.orderedRemove(index);
        self.metal_dirty = true;
        return;
    }
    const copy = self.allocator.dupe(u8, path) catch return;
    self.scm_repo_collapsed.append(self.allocator, copy) catch {
        self.allocator.free(copy);
        return;
    };
    // **접으면 그 상자는 화면에 없다** — 포커스를 두면 키가 보이지 않는 상자로 계속 들어간다(목록에서
    // 빠졌을 때와 같은 함정). 쓰던 글은 초안으로 남으므로 다시 펴면 그대로 있다.
    if (self.scm_commit_focus_repo) |focus| {
        if (std.mem.eql(u8, focus, path)) blurCommit(self);
    }
    self.metal_dirty = true;
}

/// 목록에 그릴 이름. 보통 마지막 경로 조각이고, **같은 이름이 둘이면 한 조각 더** 붙인다 —
/// 워크트리를 브랜치 이름으로 만들면 이름이 겹치는 일이 흔하다.
fn repoDisplayName(entry: RepoEntry, all: []const RepoEntry) []const u8 {
    const base = std.fs.path.basename(entry.path);
    var duplicate = false;
    for (all) |other| {
        if (std.mem.eql(u8, other.path, entry.path)) continue;
        if (std.mem.eql(u8, std.fs.path.basename(other.path), base)) duplicate = true;
    }
    if (!duplicate) return base;
    // 부모 조각까지 붙인다(`…/parent/base`가 아니라 경로 뒤 두 조각) — 그래도 겹치면 그대로 둔다.
    const parent = std.fs.path.dirname(entry.path) orelse return base;
    const start = if (std.fs.path.dirname(parent)) |grand| grand.len + 1 else 0;
    return entry.path[@min(start, entry.path.len)..];
}

/// 머리 줄에 적을 HEAD 표시. 분리 HEAD면 브랜치가 없으므로 그 사실을 말한다.
fn headLabel(head: maru.session.git_status.Head) []const u8 {
    if (head.detached) return "(detached)";
    return head.branch orelse "";
}

fn countFiles(rows: []const scm_view.Row) u32 {
    var count: u32 = 0;
    for (rows) |row| switch (row) {
        .section => |section| count += @intCast(section.count),
        else => {},
    };
    return count;
}

// ── 비활성 저장소 머리 줄 읽기(P3d-③) ────────────────────────────────────────────
//
// 목록에 뜬 저장소 중 **지금 보고 있지 않은 것**을 하나씩 읽어 머리 줄을 채운다. 읽는 것은
// `status` 하나뿐이다 — 머리 줄에 필요한 것이 전부 거기 있고, numstat 셋·merge-base·branch 범위는
// 펼쳐서 파일 줄을 그릴 때만 쓰인다(§3.5.1c). 저장소 여덟이면 프로세스가 48개가 아니라 13개다.
//
// **동시성이 아니라 배치 크기가 답이다.** 다른 저장소끼리는 `index.lock`이 겹치지 않으므로 병렬도
// 가능하지만, backend가 결과 슬롯 하나·in-flight 하나라 구조를 바꿔야 하고 위 감축을 하면 남는 이득이
// 작다. 필요해지면 측정하고 연다.

/// 그 저장소의 요약을 찾는다(없으면 아직 안 읽었다는 뜻).
pub fn repoStatusFor(self: *const AppSession, path: []const u8) ?app_session_mod.RepoStatusEntry {
    for (self.scm_repo_status.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry;
    }
    return null;
}

/// 목록 갱신 시점(뷰 진입·창 포커스·`.git` 이벤트)에 **전부 낡았다고 표시**한다. 지우지 않는 이유는
/// 지운 값을 다시 읽는 동안 머리 줄이 "읽는 중…"으로 되돌아가 화면이 깜빡이기 때문이다 — 낡은 값을
/// 보여 주다 조용히 바뀌는 편이 낫다(그 값은 방금 전 사실이다).
/// 그 저장소 **하나만** 낡았다고 표시한다(쓰기가 끝난 뒤 — 그 줄만 사실이 바뀌었다).
pub fn markRepoStatusStaleFor(self: *AppSession, repo: []const u8) void {
    for (self.scm_repo_status.items) |*entry| {
        if (!std.mem.eql(u8, entry.path, repo)) continue;
        entry.stale = true;
        // 실패 backoff는 성공한 읽기에는 걸리지 않는다 — 여기서 되돌릴 것도 없다.
        self.metal_dirty = true;
        return;
    }
}

pub fn markRepoStatusStale(self: *AppSession) void {
    for (self.scm_repo_status.items) |*entry| entry.stale = true;
}

/// 아직 안 읽었거나 낡은 저장소 **하나**에 읽기를 건다. 매 tick 부르되 대부분은 그냥 돌아간다.
const repo_status_retry_ns: i128 = 5 * std.time.ns_per_s;

/// 그 저장소를 **지금** 읽을 것인가. 순수 판정이라 여기서 단위로 짚는다.
///
/// 실패한 저장소는 쉬었다 간다: 곧바로 다시 걸면 사라진 워크트리 하나가 매 tick git을 띄우고,
/// 하나씩 도는 규율(§6) 때문에 뒤의 저장소는 차례가 **영영** 오지 않는다.
pub fn shouldReadRepoStatus(known: ?app_session_mod.RepoStatusEntry, now: i128) bool {
    const entry = known orelse return true; // 아직 한 번도 못 읽었다
    if (entry.failed) return now - entry.read_ns >= repo_status_retry_ns;
    return entry.stale;
}

pub fn pumpRepoStatus(self: *AppSession) void {
    if (self.dock.view != .source_control or !dock_ops.dockVisible(self)) return;
    if (self.scm_repo_status_inflight != 0) return; // 하나씩
    if (self.scm_write_inflight != 0) return; // 쓰기 중에는 읽지 않는다(§6)
    // **활성 저장소는 건너뛴다**(아래 루프) — 그래서 이 읽기는 목록 읽기와 **같은 저장소를 겹치지
    // 않는다**. §6의 `index.lock` 규율이 걸리는 조건이 그 겹침이므로, 슬롯을 나눠 둘이 동시에 돌아도
    // 그 규율을 깨지 않는다.

    const repos = repoEntries(self);
    const current = self.git_repo orelse "";
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    for (repos.entries) |entry| {
        if (std.mem.eql(u8, entry.path, current)) continue; // 활성은 목록 읽기가 채운다
        if (!shouldReadRepoStatus(repoStatusFor(self, entry.path), now)) continue;
        submitRepoStatus(self, entry.path);
        return; // **하나만** 건다 — 나머지는 다음 tick에
    }
}

fn submitRepoStatus(self: *AppSession, repo: []const u8) void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_repo_status_seq += 1;
    if (!self.git_backend.?.submitRepoStatus(git_exe, repo, self.scm_repo_status_seq)) return;
    self.scm_repo_status_inflight = self.scm_repo_status_seq;
}

/// 도착한 요약을 캐시에 싣는다. **경로로 맞춘다** — 목록은 그 사이에 바뀔 수 있고, 순서로 맞추면 늦게
/// 온 답이 남의 줄을 채운다.
pub fn drainRepoStatus(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeRepoStatusResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
    if (taken.request_id != self.scm_repo_status_inflight) return; // 낡은 답은 버린다
    self.scm_repo_status_inflight = 0;
    if (taken.repo.len == 0) return; // 어느 저장소의 답인지 모르면 실을 자리가 없다
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (!taken.ok) {
        // **실패도 기록한다.** 안 기록하면 그 저장소는 계속 "아직 안 읽은 것"이라 매 tick 다시 읽힌다.
        recordRepoStatusFailure(self, taken.repo, now);
        return;
    }

    const summary = maru.session.scm_repos.summarize(taken.text);
    const branch_copy = self.allocator.dupe(u8, summary.branch) catch return;
    // **status 텍스트도 든다**(②d) — 그 저장소를 펼치면 이 출력으로 파일 줄을 세운다(추가 프로세스 없이).
    // 상한을 넘으면 비워 둔다: 요약은 이미 뽑았고, 그 저장소를 열면 목록 읽기가 다시 읽는다.
    const status_copy: []u8 = if (taken.text.len <= app_session_mod.scm_repo_status_text_max)
        (self.allocator.dupe(u8, taken.text) catch &.{})
    else
        &.{};
    for (self.scm_repo_status.items) |*entry| {
        if (!std.mem.eql(u8, entry.path, taken.repo)) continue;
        self.allocator.free(entry.branch);
        if (entry.status_text.len > 0) self.allocator.free(entry.status_text);
        entry.* = .{
            .path = entry.path,
            .branch = branch_copy,
            .status_text = status_copy,
            .detached = summary.detached,
            .count = summary.count,
            .ahead = summary.ahead,
            .behind = summary.behind,
            .has_ab = summary.has_ab,
            .read_ns = now,
        };
        self.metal_dirty = true;
        return;
    }
    // 새 항목. 상한은 목록 상한과 같다 — 목록에 없는 저장소를 기억할 이유가 없다.
    if (self.scm_repo_status.items.len >= maru.session.scm_repos.max_entries) {
        self.allocator.free(branch_copy);
        if (status_copy.len > 0) self.allocator.free(status_copy);
        return;
    }
    const path_copy = self.allocator.dupe(u8, taken.repo) catch {
        self.allocator.free(branch_copy);
        if (status_copy.len > 0) self.allocator.free(status_copy);
        return;
    };
    self.scm_repo_status.append(self.allocator, .{
        .path = path_copy,
        .branch = branch_copy,
        .detached = summary.detached,
        .count = summary.count,
        .ahead = summary.ahead,
        .behind = summary.behind,
        .has_ab = summary.has_ab,
        .read_ns = now,
        .status_text = status_copy,
    }) catch {
        self.allocator.free(path_copy);
        self.allocator.free(branch_copy);
        if (status_copy.len > 0) self.allocator.free(status_copy);
        return;
    };
    self.metal_dirty = true;
}

/// 읽기 실패를 캐시에 남긴다. **개수는 0으로 두지 않고 "읽지 못함"으로 그린다** — 0건은 사실을
/// 단정하는 값이고, 우리는 그 사실을 모른다.
fn recordRepoStatusFailure(self: *AppSession, repo: []const u8, now: i128) void {
    for (self.scm_repo_status.items) |*entry| {
        if (!std.mem.eql(u8, entry.path, repo)) continue;
        entry.failed = true;
        entry.stale = false;
        entry.read_ns = now;
        // **옛 목록은 버린다.** 못 읽은 저장소의 지난 파일 줄을 계속 그리면 화면이 지금 사실을 말하지 않는다.
        if (entry.status_text.len > 0) {
            self.allocator.free(entry.status_text);
            entry.status_text = &.{};
        }
        self.metal_dirty = true;
        return;
    }
    if (self.scm_repo_status.items.len >= maru.session.scm_repos.max_entries) return;
    const path_copy = self.allocator.dupe(u8, repo) catch return;
    const branch_copy = self.allocator.dupe(u8, "") catch {
        self.allocator.free(path_copy);
        return;
    };
    self.scm_repo_status.append(self.allocator, .{
        .path = path_copy,
        .branch = branch_copy,
        .detached = false,
        .count = 0,
        .ahead = 0,
        .behind = 0,
        .has_ab = false,
        .failed = true,
        .read_ns = now,
    }) catch {
        self.allocator.free(path_copy);
        self.allocator.free(branch_copy);
        return;
    };
    self.metal_dirty = true;
}

/// 그 저장소의 초안 글(없으면 빈 문자열). **편집 중이 아닌 상자가 보여 주는 것**이다 — 화면에 있는
/// 글이 곧 그 저장소로 커밋될 글이어야 한다.
fn draftTextFor(self: *const AppSession, repo: []const u8) []const u8 {
    for (self.scm_commit_drafts.items) |draft| {
        if (std.mem.eql(u8, draft.repo, repo)) return draft.text;
    }
    return "";
}

test "턴 시각: 오늘이면 시:분, 다른 날이면 월-일까지 — 오프셋은 호출자가 넘긴다" {
    var buf: [24]u8 = undefined;
    const kst: i64 = 9 * 3600;

    // 2026-08-23 17:14 UTC+9 (= 08:14 UTC).
    const captured: i64 = 1787472840;
    const same_day_now: i64 = captured + 3600; // 같은 날 한 시간 뒤
    try std.testing.expectEqualStrings("17:14", formatTurnTime(&buf, captured, kst, same_day_now, kst));

    // 하루 뒤에서 보면 «오늘»이 아니므로 날짜가 붙는다.
    const next_day_now: i64 = captured + std.time.s_per_day;
    try std.testing.expectEqualStrings("08-23 17:14", formatTurnTime(&buf, captured, kst, next_day_now, kst));

    // **오프셋이 시각을 가른다.** 같은 순간을 UTC 로 보면 08:14 이다.
    try std.testing.expectEqualStrings("08:14", formatTurnTime(&buf, captured, 0, same_day_now, 0));
}

test "턴 시각: 같은 순간도 오프셋이 다르면 다른 시각으로 그린다" {
    var buf: [24]u8 = undefined;
    var utc_buf: [24]u8 = undefined;
    const kst: i64 = 9 * 3600;
    const captured: i64 = 1787498400;
    const utc_text = formatTurnTime(&utc_buf, captured, 0, captured, 0);
    const kst_text = formatTurnTime(&buf, captured, kst, captured, kst);
    // 둘 다 자기 기준으로는 «오늘»이라 시:분만 나오고, 그 값이 9시간 어긋난다.
    try std.testing.expectEqual(@as(usize, 5), utc_text.len);
    try std.testing.expectEqual(@as(usize, 5), kst_text.len);
    try std.testing.expect(!std.mem.eql(u8, utc_text, kst_text));
}

test "턴 시각: 1970 이전은 그리지 않는다(빈 문자열)" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("", formatTurnTime(&buf, -1, 0, 0, 0));
    // 오프셋 때문에 음수가 되는 경우도 같다.
    try std.testing.expectEqualStrings("", formatTurnTime(&buf, 100, -3600, 0, 0));
}

test "턴 요약: 모르거나 0이면 자리를 비운다(실패한 턴도 0으로 오기 때문이다)" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();

    // 아직 안 읽었다 — `0개 파일` 이라고 말하면 거짓이다.
    var unknown: maru.session.turn_snapshot.Snapshot = .{};
    try std.testing.expectEqualStrings("", turnSummary(a, &unknown, 0));

    // 읽었는데 0이다. 실패한 턴도 이 모양으로 오므로(무한 재요청을 막으려고 실패를 «읽었다»로 표시한다)
    // 둘을 가를 수 없어 둘 다 비운다.
    var zero: maru.session.turn_snapshot.Snapshot = .{ .files_known = true, .changed_files = 0 };
    try std.testing.expectEqualStrings("", turnSummary(a, &zero, 0));

    // 실제로 바꾼 것이 있으면 그 수를 말한다.
    var three: maru.session.turn_snapshot.Snapshot = .{ .files_known = true, .changed_files = 3 };
    const text = turnSummary(a, &three, 0);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '3') != null);
    // **캡처가 없으면 `✎` 를 안 붙인다** — «✎ 0» 은 «에이전트가 아무것도 안 했다» 로 읽히는데
    // 우리가 아는 것은 «편집 도구로는 안 했다» 뿐이다.
    try std.testing.expect(std.mem.indexOf(u8, text, "✎") == null);
}

// [AT4 §5] 셸 고지는 **두 경우에 없고 그 둘은 다른 사실이다** — 「안 썼다」와 「모른다」.
test "셸 고지: 썼으면 수를 말하고, 0이거나 모르면 줄이 없다" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const gpa = session.allocator;

    // ① 셸을 썼다 — 수가 문구에 든다.
    session.turn_captures.noteShellCall("S1");
    session.turn_captures.noteShellCall("S1");
    session.turn_captures.noteShellCall("S1");
    const used = session.turn_captures.seal(gpa, "S1");
    try std.testing.expect(used != 0);
    var snap_used: maru.session.turn_snapshot.Snapshot = .{ .capture_id = used };
    const text = shellNoticeFor(session, a, &snap_used) orelse return error.MissingNotice;
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '3') != null);

    // ② 캡처는 있는데 셸은 **안 썼다** — 줄이 없다(계약 §5).
    try std.testing.expect(session.turn_captures.noteBefore(gpa, "S2", "/r/a.zig", .edit, .empty));
    const no_shell = session.turn_captures.seal(gpa, "S2");
    try std.testing.expect(no_shell != 0);
    var snap_no_shell: maru.session.turn_snapshot.Snapshot = .{ .capture_id = no_shell };
    try std.testing.expect(shellNoticeFor(session, a, &snap_no_shell) == null);

    // ③ **캡처가 없다 — 썼는지 «모른다».** 여기서 「0개」를 그리면 「안 썼다」는 거짓이 된다.
    //    ②만 보는 테스트는 이 구현을 통과시킨다.
    var snap_unknown: maru.session.turn_snapshot.Snapshot = .{};
    try std.testing.expect(shellNoticeFor(session, a, &snap_unknown) == null);
    try std.testing.expect(shellNoticeFor(session, a, null) == null);
}

// [AT3 §4.2] **배지 join 의 핵심 위험은 경로 모양이다.** 훅은 절대경로를(실측 610/610), `git diff
// --name-status` 는 저장소 상대경로를 준다. 정규화가 없으면 **하나도 안 맞아 전부 `.turn_change`** 로
// 떨어지는데 「배지가 뜬다」만 보는 테스트는 그것을 통과시킨다 — 그래서 **`.ai_edit` 인지**를 직접 잰다.
test "턴 파일 배지: 절대경로 캡처와 상대경로 목록이 같은 파일로 맞는다" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.git_repo = try allocator.dupe(u8, "/repo");

    // 편집 도구가 고친 파일 하나, 읽기만 한 파일 하나 — 둘 다 내용이 달라졌다.
    const gpa = session.allocator;
    try std.testing.expect(session.turn_captures.noteBefore(gpa, "S1", "/repo/src/edited.zig", .edit, .{ .text = try gpa.dupe(u8, "before") }));
    session.turn_captures.noteAfter(gpa, "S1", "/repo/src/edited.zig", .{ .text = try gpa.dupe(u8, "after") });
    try std.testing.expect(session.turn_captures.noteBefore(gpa, "S1", "/repo/src/shell.zig", .read, .{ .text = try gpa.dupe(u8, "before") }));
    session.turn_captures.noteAfter(gpa, "S1", "/repo/src/shell.zig", .{ .text = try gpa.dupe(u8, "after") });
    const id = session.turn_captures.seal(gpa, "S1");
    try std.testing.expect(id != 0);

    var snap: maru.session.turn_snapshot.Snapshot = .{ .capture_id = id };

    // 목록이 주는 것은 **저장소 상대경로**다.
    try std.testing.expectEqual(
        chrome.components.scm_dock.types.TurnFileOrigin.ai_edit,
        turnFileOrigin(session, turnCaptureRef(session, &snap), "src/edited.zig"),
    );
    // 읽기만 한 파일은 내용이 달라졌어도 **편집 도구 소행이 아니다**.
    try std.testing.expectEqual(
        chrome.components.scm_dock.types.TurnFileOrigin.turn_change,
        turnFileOrigin(session, turnCaptureRef(session, &snap), "src/shell.zig"),
    );
    // 캡처에 없는 파일도 마찬가지다.
    try std.testing.expectEqual(
        chrome.components.scm_dock.types.TurnFileOrigin.turn_change,
        turnFileOrigin(session, turnCaptureRef(session, &snap), "src/never_touched.zig"),
    );
    // **캡처가 없는 턴은 `.unknown`** 이다 — 「셸이 고쳤다」와 「우리가 못 봤다」를 가른다.
    var no_capture: maru.session.turn_snapshot.Snapshot = .{};
    try std.testing.expectEqual(
        chrome.components.scm_dock.types.TurnFileOrigin.unknown,
        turnFileOrigin(session, turnCaptureRef(session, &no_capture), "src/edited.zig"),
    );
    try std.testing.expectEqual(
        chrome.components.scm_dock.types.TurnFileOrigin.unknown,
        turnFileOrigin(session, turnCaptureRef(session, null), "src/edited.zig"),
    );
}

test "턴 요약: 캡처가 센 편집 수를 tree 의 수와 **나란히** 말한다" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();

    var snap: maru.session.turn_snapshot.Snapshot = .{ .files_known = true, .changed_files = 12 };
    const text = turnSummary(a, &snap, 3);
    // 두 수가 **둘 다** 있어야 한다 — 한쪽이 다른 쪽을 대체하면 그 줄이 답하는 질문이 바뀐다.
    try std.testing.expect(std.mem.indexOf(u8, text, "12") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, '3') != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "✎") != null);

    // **tree 가 0이면 캡처가 있어도 줄이 빈다** — 그 자리는 「못 읽었다」와 구분되지 않는다.
    var zero: maru.session.turn_snapshot.Snapshot = .{ .files_known = true, .changed_files = 0 };
    try std.testing.expectEqualStrings("", turnSummary(a, &zero, 5));
}

/// 도크가 **소스 컨트롤 뷰로 키를 들고 있을 때**의 PageUp/PageDown/Home/End.
///
/// Session Dock(`agent_dock.handleAgentSessionDockScrollKey`)과 같은 규율이고, 다른 것은 상한의 출처뿐이다 —
/// 여기서는 마지막 투영이 남긴 `scmScrollExtent`를 읽는다(세 탭의 목록 출처가 달라 그 자리가 유일한
/// 단일 출처다).
///
/// **커밋 상자가 편집 중이어도 양보하지 않는다(적대적 검증 1회차 정정).** 처음엔 "Home/End 는 caret 의
/// 것"이라며 `scmCommitOwnsInput()` 에서 물러났는데, 상자를 읽어 보니 **그 넷을 아무도 안 먹는다** —
/// `handleCommitKey` 는 escape·enter·←→↑↓ 만 다루고, 애초에 `chromeInputFromKeyEvent` 가 Page/Home/End 를
/// `.other` 로 축약해 상자까지 가지도 않는다(줄 처음·끝은 ⌘←/⌘→ 다). 그래서 양보하면 그 키는 상자도
/// 목록도 아닌 **터미널로 새어** 뒤의 셸이 스크롤백을 감는다 — 이 함수가 막으려던 바로 그 증상이다.
/// 커밋 라우팅은 이 함수보다 **앞**이므로(`scmCommitOwnsInput()` 블록) 상자가 실제로 쓰는 키는 여기 오지도
/// 않는다. 모달도 같다 — `anyOverlayOpen()` 이 앞에서 모든 키를 소비한다.
pub fn handleScmDockScrollKey(self: *AppSession, event: terminal.KeyEvent) bool {
    if (!dock_ops.dockVisible(self) or self.dock.view != .source_control or !self.dockKeyFocus()) return false;
    if (event.modifiers.command or event.modifiers.control or event.modifiers.option or event.modifiers.shift)
        return false;
    const extent = scroll_ops.scmScrollExtent(self);
    const row_h = component.types.DockMetrics.resolve(scmDockScaleMilli(self)).row_h;
    const step = chrome.ui.scroll_area.pageStepPx(extent.viewport_h_px, row_h);
    const changed = switch (event.key) {
        .page_up => self.scm_scroll.scrollByPx(-@as(i64, step), extent.max_offset_px),
        .page_down => self.scm_scroll.scrollByPx(@as(i64, step), extent.max_offset_px),
        .home => self.scm_scroll.setOffsetPx(0, extent.max_offset_px),
        .end => self.scm_scroll.setOffsetPx(extent.max_offset_px, extent.max_offset_px),
        else => return false,
    };
    self.scm_scroll.dropWheelResidue();
    if (changed) self.metal_dirty = true;
    return true;
}

test "소스 컨트롤 키보드 스크롤: 한 행을 남기고 · 끝으로 가고 · 주인이 아니면 안 잡는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 마지막 투영이 남기는 자리를 직접 채운다 — 이 핸들러가 읽는 유일한 상한 출처다(`scrollExtent`).
    const viewport_h: u32 = 400;
    const max_offset: u32 = 1000;
    session.scm_scroll_extent = .{
        .content_h_px = viewport_h + max_offset,
        .viewport_h_px = viewport_h,
        .max_offset_px = max_offset,
    };
    const row_h = component.types.DockMetrics.resolve(scmDockScaleMilli(session)).row_h;
    try std.testing.expect(viewport_h > row_h);

    // ① **주인이 아니면 안 잡는다.** 도크가 안 보이거나 다른 뷰이거나 키를 안 들었으면 그 키는
    //    터미널 것이다 — 여기서 true를 돌리면 셸에서 친 PageDown이 사라진다.
    session.dock_initialized = true;
    session.dock.presented = true;
    session.dock.collapsed = false;
    session.dock.view = .source_control;
    try std.testing.expect(dock_ops.dockVisible(session));
    session.agent_session_dock_key_focus = false;
    try std.testing.expect(!handleScmDockScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    session.agent_session_dock_key_focus = true;
    session.dock.view = .explorer;
    try std.testing.expect(!handleScmDockScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    session.dock.view = .source_control;
    try std.testing.expectEqual(@as(u32, 0), session.scm_scroll.offset_y_px);

    // ② PageDown은 **한 행을 남긴다** — 한 화면을 통째로 넘기면 읽던 자리가 끊긴다(`pageStepPx` 계약).
    try std.testing.expect(handleScmDockScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    try std.testing.expectEqual(viewport_h - row_h, session.scm_scroll.offset_y_px);

    // ③ End는 정확히 상한, Home은 0이다.
    try std.testing.expect(handleScmDockScrollKey(session, .{ .key = .end, .modifiers = .{} }));
    try std.testing.expectEqual(max_offset, session.scm_scroll.offset_y_px);
    try std.testing.expect(handleScmDockScrollKey(session, .{ .key = .home, .modifiers = .{} }));
    try std.testing.expectEqual(@as(u32, 0), session.scm_scroll.offset_y_px);

    // ④ **경계에서도 소비한다.** 맨 위에서 PageUp은 픽셀을 못 움직이지만 true여야 한다 — 안 그러면
    //    보이는 목록을 겨눈 키가 뒤의 터미널로 새어 스크롤백이 감긴다.
    try std.testing.expect(handleScmDockScrollKey(session, .{ .key = .page_up, .modifiers = .{} }));
    try std.testing.expectEqual(@as(u32, 0), session.scm_scroll.offset_y_px);

    // ⑤ 수식키가 붙으면 넘기지 않는다 — ⌘Home 같은 조합은 다른 주인이 있다.
    try std.testing.expect(!handleScmDockScrollKey(session, .{ .key = .end, .modifiers = .{ .command = true } }));
    try std.testing.expectEqual(@as(u32, 0), session.scm_scroll.offset_y_px);

    // ⑥ 스크롤 키가 아닌 것은 그대로 흘려보낸다.
    try std.testing.expect(!handleScmDockScrollKey(session, .{ .key = .enter, .modifiers = .{} }));

    // ⑦ **커밋 상자가 편집 중이어도 목록이 먹는다**(적대적 검증 1회차). 상자는 이 넷을 안 다루고
    //    (`handleCommitKey` = escape·enter·←→↑↓), `chromeInputFromKeyEvent` 가 Page/Home/End 를
    //    `.other` 로 축약해 거기까지 가지도 않는다. 여기서 물러나면 그 키는 상자도 목록도 아닌
    //    **터미널로 샌다** — 이 함수가 막으려던 바로 그 증상이다.
    const repo = try session.allocator.dupe(u8, "/tmp/repo");
    session.scm_commit_focus_repo = repo;
    defer {
        session.allocator.free(repo);
        session.scm_commit_focus_repo = null;
    }
    session.scm_tab = .changes;
    try std.testing.expect(session.scmCommitOwnsInput()); // 상자가 입력 주인인 상태를 실제로 만든다
    try std.testing.expect(handleScmDockScrollKey(session, .{ .key = .page_down, .modifiers = .{} }));
    try std.testing.expectEqual(viewport_h - row_h, session.scm_scroll.offset_y_px);

    // ⑧ **제품 키 경로로도 태운다**(적대적 검증 2회차). 위 ①~⑦ 은 핸들러를 직접 부르므로 라우팅
    //    줄이 지워져도 초록으로 남는다 — 그러면 테스트는 통과하는데 제품에서는 키가 안 듣는다.
    //    `handleKeyEvent` 를 지나면 그 앞의 게이트들(모달·커밋 상자·`input.page-keys` 터미널 스크롤)과의
    //    **순서**까지 함께 고정된다.
    session.scm_commit_focus_repo = null; // 상자 라우팅이 앞에서 먹지 않게 되돌린다
    _ = session.scm_scroll.setOffsetPx(0, max_offset);
    _ = try session.handleKeyEvent(.{ .key = .end, .modifiers = .{} });
    try std.testing.expectEqual(max_offset, session.scm_scroll.offset_y_px);
    _ = try session.handleKeyEvent(.{ .key = .home, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 0), session.scm_scroll.offset_y_px);
}

test "소스 컨트롤 도크: 클릭이 키보드 소유권을 준다 — 그래야 Page/Home/End 가 먹는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // **이 테스트가 없어서 기능이 통째로 죽어 있었다(2026-08-30).** 키 핸들러도 라우팅도 맞았는데
    // 소유권을 주는 한 줄이 소스 컨트롤 분기의 `return` **뒤**에 있어 영영 실행되지 않았다. 상태를
    // 손으로 세우는 판정자는 그 자리를 못 본다 — 포인터를 실제로 태워야 보인다.
    session.backing_width_px = 1400;
    session.backing_height_px = 900;
    session.dock_initialized = true;
    session.dock.presented = true;
    session.dock.collapsed = false;
    session.dock.view = .source_control;
    try std.testing.expect(dock_ops.dockVisible(session));
    try std.testing.expect(!session.dockKeyFocus()); // 누르기 전에는 도크가 키를 안 든다

    const dock_rect = dock_ops.dockGeometry(session).dock;
    try std.testing.expect(dock_rect.w > 0 and dock_rect.h > 0); // 기하가 0이면 아래 클릭이 아무 데도 안 닿는다
    const x: f64 = @as(f64, @floatFromInt(dock_rect.x)) + @as(f64, @floatFromInt(dock_rect.w)) / 2;
    const y: f64 = @as(f64, @floatFromInt(dock_rect.y)) + @as(f64, @floatFromInt(dock_rect.h)) / 2;
    session.mouse(1, x, y, 0, 0); // primary down — 제품과 같은 진입점

    try std.testing.expect(session.dockKeyFocus()); // ← 이 한 줄이 이번 회귀를 잡는다

    // 소유권이 섰으니 그 키가 실제로 목록을 옮긴다(상한은 마지막 투영이 남긴 자리에서 온다).
    session.scm_scroll_extent = .{ .content_h_px = 1400, .viewport_h_px = 400, .max_offset_px = 1000 };
    _ = try session.handleKeyEvent(.{ .key = .end, .modifiers = .{} });
    try std.testing.expectEqual(@as(u32, 1000), session.scm_scroll.offset_y_px);
}

test "fade alpha 가 바뀌어도 발행 tree 는 불변이고, alpha 는 draw 에 닿는다(계약 §7 — SCM 축)" {
    // **세션 도크에만 판정자가 있었다.** 두 도크는 `paintWithAlphaOverrides` 라는 같은 축을 쓰지만,
    // SCM 쪽 배선(`view.zig` 가 `props.scrollbar_alpha` 를 실제로 넘기는지)이 끊겨도 그걸 잡을 눈이
    // 없었다 — 적대적 검증 3회차에서 코드로만 확인하고 넘긴 자리다.
    const rows = [_]scm_view.Row{
        .{ .section = .{ .section = .changes, .count = 2, .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "a.zig", .letter = 'M', .action = .stage } },
        .{ .file = .{ .section = .changes, .path = "b.zig", .letter = 'M', .action = .stage } },
    };
    var items: [rows.len]component.types.Item = undefined;
    for (rows, &items, 0..) |row, *item, index| {
        item.* = scm_items.itemFor(row, 0, index, null, @splat(false));
    }

    var props: component.types.Props = .{
        .viewport_px = .{ .x = 0, .y = 0, .width = 320, .height = 480 },
        .items = &items,
        // 스크롤바는 **넘칠 때만** 난다(build 의 `gutter_px` 분기와 같은 사실이다).
        .content_h_px = 4000,
        .list_overflows = true,
        .scrollbar_alpha = 0xFF,
    };

    const sizes = component.build.bufferSizes(&items);
    const allocator = testing.allocator;
    const nodes = try allocator.alloc(chrome.ui.tree.UiNode, sizes.nodes);
    defer allocator.free(nodes);
    const entries = try allocator.alloc(chrome.ui.tree.RectEntry, sizes.entries);
    defer allocator.free(entries);
    const layout_items = try allocator.alloc(chrome.ui.layout.Item, sizes.layout_items);
    defer allocator.free(layout_items);
    const flex_scratch = try allocator.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch);
    defer allocator.free(flex_scratch);
    const child_rects = try allocator.alloc(chrome.ui.layout.UiRect, sizes.child_rects);
    defer allocator.free(child_rects);
    const actions = try allocator.alloc(component.ids.Entry, sizes.actions);
    defer allocator.free(actions);
    const buffers = component.build.Buffers{
        .nodes = nodes,
        .entries = entries,
        .layout_items = layout_items,
        .flex_scratch = flex_scratch,
        .child_rects = child_rects,
        .actions = actions,
    };

    const full = try component.build.build(props, buffers);
    // 다음 build 가 같은 버퍼를 덮어쓰므로 값으로 떠 둔다.
    const full_entries = try allocator.dupe(chrome.ui.tree.RectEntry, full.tree.entries);
    defer allocator.free(full_entries);
    const full_actions = try allocator.dupe(component.ids.Entry, full.actions);
    defer allocator.free(full_actions);
    try testing.expect(full.tree.find(component.build.NodeIds.scroll_thumb) != null); // 스크롤바가 실제로 났다

    // **alpha 만 다르게** 다시 만든다. fade 가 도는 매 프레임이 이 상황이다.
    props.scrollbar_alpha = 0x4D;
    const faint = try component.build.build(props, buffers);

    // alpha 를 tree 에 실으면 여기서 false 가 되고, `publishScmDockFrame` 의 early return 이 fade 내내
    // 무산된다 — 발행이 매 프레임 도는 값이 된다.
    try testing.expect(frameEql(full_entries, full_actions, faint.tree.entries, faint.actions));

    // **그리고 alpha 는 실제로 draw 에 닿아야 한다.** tree 불변만 재면 「아무 데도 안 얹히는」 판도
    // 통과한다(세션 도크에서 1회차에 그렇게 잡혔다).
    const budget = component.view.drawBufferSizes(props, faint.tree.entries.len);
    const ops = try allocator.alloc(chrome.draw.Op, budget.ops);
    defer allocator.free(ops);
    const runs = try allocator.alloc(chrome.draw.Run, budget.runs);
    defer allocator.free(runs);
    const text_bytes = try allocator.alloc(u8, budget.text_bytes);
    defer allocator.free(text_bytes);

    const tokens = chrome.tokens.Tokens.base(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_background = .{ .r = 30, .g = 30, .b = 30 },
        .sidebar_foreground = .{ .r = 200, .g = 200, .b = 200 },
        .sidebar_active = .{ .r = 60, .g = 60, .b = 60 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 13, .g = 14, .b = 15 },
        .accent = .{ .r = 16, .g = 17, .b = 18 },
    });
    const drawn = try component.view.view(props, faint, .{}, &tokens, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    });

    const thumb_rect = faint.tree.entries[faint.tree.find(component.build.NodeIds.scroll_thumb).?].rect;
    var saw_faint = false;
    for (drawn.ops) |op| switch (op) {
        .quad => |q| {
            const qx: f32 = @floatFromInt(q.rect.x);
            const qy: f32 = @floatFromInt(q.rect.y);
            if (@abs(qx - thumb_rect.x) < 1.5 and @abs(qy - thumb_rect.y) < 1.5) {
                try testing.expectEqual(@as(u8, 0x4D), q.alpha);
                saw_faint = true;
            }
        },
        else => {},
    };
    try testing.expect(saw_faint); // thumb quad 를 실제로 찾았다 — 못 찾으면 위 단언이 헛돈다
}
