//! 소스 컨트롤 도크의 **호스트 배선**(component ↔ AppSession).
//!
//! `session/scm_view.zig`의 행 모델을 component props로 투영하고, 만들어진 tree를 그리고, 포인터를
//! 그 tree로 라우팅한다. Session Dock(`agent_dock.zig`)과 **같은 경로**를 쓴다 — 두 도크 뷰가 서로 다른
//! 배선을 가지면 같은 컬럼에서 뷰를 갈아 끼울 때 스크롤·호버·히트테스트 규칙이 갈린다.
//!
//! **여기서 행 높이를 다시 곱하지 않는다.** 기하의 단일 출처는 component의 `DockMetrics`이고, 이 파일은
//! 그 값을 스크롤 투영에 그대로 넘긴다(옛 셀 그리드 경로가 갈려서 "그린 자리와 눌리는 자리"가 어긋났다).

const std = @import("std");
const maru = @import("maru");

const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const CollectedPane = AppSession.CollectedPane;
const coretext_frame_builder = app_session_mod.coretext_frame_builder;
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const metal_frame = app_session_mod.metal_frame;
const dock_ops = @import("dock.zig");
const git_ops = @import("git.zig");
const agent_dock = @import("agent_dock.zig");
const scm_view = app_session_mod.scm_view;
const scm_row_capacity = app_session_mod.scm_row_capacity;
const git_backend_mod = app_session_mod.git_backend_mod;
const git_write_command = app_session_mod.git_write_command;
const text_area = chrome.components.text_area;
const text_field = chrome.components.text_field;
const redact = maru.redact;

const component = chrome.components.scm_dock;

/// 도크 UI zoom. **Session Dock과 같은 값**을 쓴다 — 같은 컬럼의 두 뷰가 다른 축으로 커지면 뷰를
/// 갈아 끼울 때 행 높이가 튄다(docs/editor-surface-dock.md §3.5).
pub fn scmDockScaleMilli(self: *const AppSession) u32 {
    return agent_dock.agentSessionDockUiZoomMilli(self);
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
    // **상자는 이제 목록 줄이다**(②b) — 스크롤 영역이 오른쪽에 스크롤바 자리를 늘 비워 두므로(gutter)
    // 줄 폭은 content 폭이 아니다. 여기서 그걸 빼지 않으면 host가 세는 열 수가 view보다 많아져,
    // 상자 높이가 실제 줄 수보다 적게 나오고 마지막 줄이 잘린다.
    const gutter = m.scrollbar_width + m.scrollbar_inset_x * 2;
    return m.commitViewCols(@floatFromInt(content.w -| gutter), self.cell_width_px);
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
    const summary_h: u32 = if (self.scm_tab == .history) 0 else m.summary_h;
    const fixed = m.tab_h + summary_h + if (has_branch) m.branch_h else 0;
    return content.h -| fixed;
}

/// 모델 행 하나를 component 항목으로 옮긴다. **문자열은 복사하지 않는다** — `git_result`가 이 프레임
/// 동안 살아 있고, component는 immutable snapshot만 읽는다.
fn itemFor(row: scm_view.Row, repo_index: u32, model_index: usize, selected_row: ?usize, collapsed: [scm_view.section_count]bool) component.types.Item {
    return switch (row) {
        .section => |section| .{
            .section = .{
                .repo_index = repo_index,
                .section = sectionOf(section.section),
                .count = @intCast(section.count),
                .collapsed = collapsed[@intFromEnum(section.section)],
                // 섹션 헤더의 일괄 동작. 모델이 "대상이 하나도 없으면(전부 충돌) `.none`"까지 판정해 둔다.
                .action = actionOf(section.action),
            },
        },
        .file => |file| .{
            .file = .{
                .repo_index = repo_index,
                .model_index = @intCast(model_index),
                .name = std.fs.path.basename(file.path),
                .dir = file.path[0 .. file.path.len - std.fs.path.basename(file.path).len],
                .status = statusOf(file),
                .letter = file.letter,
                .added = file.added,
                .removed = file.removed,
                .has_delta = !file.unknown_delta and !file.binary,
                .binary = file.binary,
                // 행 동작(`+`/`−`). **충돌 행은 모델이 `.none`으로 준다** — `git add`는 충돌을 "해결됨"으로
                // 표시하므로, 그 행에 `+`를 두면 사용자가 의도하지 않은 해결이 일어난다.
                .action = actionOf(file.action),
                .selected = selected_row != null and selected_row.? == model_index,
            },
        },
        .more => |more| .{ .more = .{ .repo_index = repo_index, .section = sectionOf(more.section), .hidden = @intCast(more.hidden) } },
        .notice => |notice| .{ .notice = notice.text() },
    };
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

fn sectionOf(section: scm_view.Section) component.types.Section {
    // 값 집합이 갈리면 이 switch가 컴파일에서 걸린다(component는 session 모듈을 import하지 않는다).
    return switch (section) {
        .staged => .staged,
        .changes => .changes,
    };
}

fn statusOf(file: scm_view.FileRow) component.types.StatusKind {
    if (file.conflicted) return .conflicted;
    if (file.untracked) return .added; // 새로 생긴 것과 같은 계열(§3.5.2)
    return switch (file.letter) {
        'A', 'C' => .added,
        'D' => .deleted,
        else => .modified,
    };
}

/// 모델 행 하나의 높이. **정책은 component의 `itemHeight`가 소유한다** — 여기서 숫자를 다시 고르면
/// 스크롤 상한과 그린 자리가 갈린다. 그래서 높이 계산에 필요한 최소 항목을 만들어 그 함수에 묻는다.
fn rowHeightPx(m: component.types.DockMetrics, row: scm_view.Row) u32 {
    const probe: component.types.Item = switch (row) {
        .section => .{ .section = .{ .section = .changes, .count = 0, .collapsed = false, .action = .none } },
        .file => .{ .file = .{ .name = "", .dir = "", .status = .modified, .letter = 'M', .action = .none } },
        .more => .{ .more = .{ .section = .changes, .hidden = 0 } },
        .notice => .{ .notice = "" },
    };
    return m.itemHeight(probe);
}

pub const Extent = struct { content_h_px: u32, viewport_h_px: u32, max_offset_px: u32 };

/// 목록 스크롤 상한. 휠·클램프가 이 값을 쓰고, 렌더는 같은 기하를 `project`로 다시 받는다.
pub fn scrollExtent(self: *AppSession) Extent {
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const m = component.types.DockMetrics.resolve(scmDockScaleMilli(self));
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse
        return .{ .content_h_px = 0, .viewport_h_px = listViewportHeightPx(self, false), .max_offset_px = 0 };
    var content: u32 = 0;
    for (model.rows) |row| content +|= rowHeightPx(m, row);
    const has_branch = model.head.detached or model.head.branch != null;
    const viewport = listViewportHeightPx(self, has_branch);
    return .{ .content_h_px = content, .viewport_h_px = viewport, .max_offset_px = content -| viewport };
}

pub const Projection = struct {
    items: []const component.types.Item,
    scroll: chrome.ui.scroll_area.Projection,
    branch: []const u8,
    ahead: u32,
    behind: u32,
    has_ab: bool,
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
pub fn project(self: *AppSession, arena: std.mem.Allocator) ?Projection {
    // **히스토리 탭은 다른 목록이다**(P4). 같은 스크롤·같은 격자를 쓰지만 행의 출처가 `git log`라
    // 여기서 갈린다 — 두 목록을 한 함수에 섞으면 "이 행이 어느 탭 것인가" 판정이 행마다 생긴다.
    if (self.scm_tab == .history) return projectHistory(self, arena);

    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = git_ops.buildScmModel(self, &rows_buf, &scratch) orelse return null;

    // 쓰기가 실패했으면 그 사유를 **목록 맨 위 한 줄**로 낸다(§5 — 실패는 사실대로). 별도 배너를 만들지
    // 않는 이유는 이 자리가 이미 "목록이 사실과 다르다"를 말하는 자리(`notice`)이고, 사용자가 방금 누른
    // 동작의 결과를 그 목록 바로 위에서 읽는 것이 자연스럽기 때문이다.
    const notice_rows: usize = if (self.scm_write_error != null) 1 else 0;

    // **저장소 머리 줄이 목록의 첫 층이다**(§3.5.1c). 지금 읽어 둔 저장소의 줄들은 자기 머리 줄 아래에
    // 오고, 아직 안 읽은 저장소는 머리 줄만 선다(maru.i18n.t(.scm_loading) — 배지의 빈자리와 구별한다).
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
    if (self.scm_write_error) |err| {
        items[n] = .{ .notice = err };
        n += 1;
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
                // 아직 답이 안 온 저장소만 maru.i18n.t(.scm_loading)이다 — **0건과 구별해야 한다**.
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
            items[n] = itemFor(row, @intCast(repo_index), index, selected, self.scm_collapsed);
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
    return .{
        .items = items[0..n],
        .scroll = scroll,
        .branch = branch,
        .ahead = model.head.ahead,
        .behind = model.head.behind,
        .has_ab = model.head.has_ab,
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
        var files = maru.session.git_status.iterateNameStatus(self.scm_commit_files_text);
        while (files.next()) |_| commit_file_rows += 1;
        // 읽는 중이거나 실패면 그 사실을 한 줄로 말한다(빈 자리는 "바꾼 것이 없다"로 읽힌다).
        if (commit_file_rows == 0) commit_file_rows = 1;
        if (self.scm_commit_files_truncated) commit_file_rows += 1;
    }

    const notice_rows: usize = if (count == 0) 1 else 0;
    // **상한만큼 읽었으면 더 있을 수 있다** — 그때만 "더 보기"를 세운다. 끝까지 읽었는데 세우면
    // 눌러도 아무 일이 없어 고장으로 읽힌다.
    const more_rows: usize = if (count >= self.scm_log_limit) 1 else 0;
    // 출력이 상한에서 잘렸으면 **그 사실을 적는다** — "더 없다"와 "더 못 읽었다"는 다른 사실이다.
    const truncated_rows: usize = if (self.scm_log_truncated) 1 else 0;
    const items = arena.alloc(component.types.Item, count + notice_rows + more_rows + truncated_rows + commit_file_rows) catch return null;
    var n: usize = 0;
    if (count == 0) {
        // 셋을 구별한다: 아직 못 읽음 · 읽었지만 커밋 없음 · 읽기 실패.
        items[0] = .{ .notice = if (self.scm_log_failed)
            maru.i18n.t(.scm_log_read_failed)
        else if (self.scm_log_repo == null)
            maru.i18n.t(.scm_loading)
        else
            maru.i18n.t(.scm_no_commits) };
        n = 1;
    }
    var it = maru.session.git_log.iterate(self.scm_log_text);
    var index: u32 = 0;
    while (it.next()) |commit| : (index += 1) {
        if (n >= items.len) break;
        const expanded = if (self.scm_expanded_commit) |oid| std.mem.eql(u8, oid, commit.oid) else false;
        var refs = maru.session.git_log.refs(commit.refs);
        const first_ref = refs.next();
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
                .selected = self.scm_selected_commit != null and self.scm_selected_commit.? == index,
                .expanded = expanded,
            },
        };
        n += 1;
        if (!expanded) continue;

        // 펼친 커밋의 파일 줄. 원문이 아직 없으면 **그 사실**을 한 줄로 말한다.
        if (self.scm_commit_files_oid == null or self.scm_commit_files_failed) {
            if (n < items.len) {
                items[n] = .{ .notice = if (self.scm_commit_files_failed)
                    "이 커밋의 파일을 읽지 못했습니다"
                else
                    "읽는 중…" };
                n += 1;
            }
            continue;
        }
        var files = maru.session.git_status.iterateNameStatus(self.scm_commit_files_text);
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
                    .selected = self.scm_selected_commit_file != null and self.scm_selected_commit_file.? == file_index,
                },
            };
            n += 1;
        }
        if (self.scm_commit_files_truncated and n < items.len) {
            items[n] = .{ .notice = "이 커밋의 파일 목록이 잘렸습니다" };
            n += 1;
        }
        // 읽었는데 파일이 없다 — 빈 커밋(`--allow-empty`)이 실제로 있다.
        if (!any_file and n < items.len) {
            items[n] = .{ .notice = "이 커밋이 바꾼 파일이 없습니다" };
            n += 1;
        }
    }

    if (truncated_rows == 1 and n < items.len) {
        items[n] = .{ .notice = "출력이 너무 커서 목록이 잘렸습니다" };
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
    return .{
        .items = items[0..n],
        .scroll = scroll,
        .branch = "",
        .ahead = 0,
        .behind = 0,
        .has_ab = false,
        .summary = .{ .added = 0, .removed = 0 },
        .has_rows = count > 0,
        .file_count = 0,
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
    var it = maru.session.git_status.iterateNameStatus(self.scm_commit_files_text);
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

/// `3시간 전`처럼 사람이 읽는 상대 시각. **arena에 만든다**(프레임 안에서만 쓴다).
///
/// git의 `%ar`를 쓰지 않는 이유: 그 문구는 git의 로케일을 타서 같은 화면 안에서 다른 상대시각 표기와
/// 규칙이 갈린다. 미래 시각(시계가 어긋난 커밋)은 `방금`으로 접는다 — "-3시간 전"은 읽을 수 없다.
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
        .cell_width_px = self.cell_width_px,
        .snapshot_generation = self.scm_dock_snapshot_generation,
        .active_tab = self.scm_tab, // 어느 탭이 활성인지는 세션이 든다(P4)
        // 히스토리에서 `+N -N`은 작업트리의 숫자라 커밋 목록과 관계가 없다 — 0으로 두면 틀린 진술이다.
        .show_summary = self.scm_tab != .history,
        .items = window,
        .scroll_offset_px = projection.scroll.offset_y_px,
        .content_h_px = projection.scroll.content_height_px,
        .content_first_item_origin_y_px = projection.scroll.first_origin_y_px,
        .branch = projection.branch,
        .ahead = projection.ahead,
        .behind = projection.behind,
        .has_ab = projection.has_ab,
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
    if (frameEql(self.scm_dock_entries.items, self.scm_dock_actions.items, frame.tree.entries, frame.actions)) return;
    // 두 저장소를 **먼저** 확보한다. 할당이 실패해도 마지막으로 온전히 그린 hit tree가 남아야 한다.
    self.scm_dock_entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len) catch return;
    self.scm_dock_actions.ensureTotalCapacity(self.allocator, frame.actions.len) catch return;
    self.scm_dock_entries.clearRetainingCapacity();
    self.scm_dock_actions.clearRetainingCapacity();
    self.scm_dock_entries.appendSlice(self.allocator, frame.tree.entries) catch return;
    self.scm_dock_actions.appendSlice(self.allocator, frame.actions) catch return;
    // 기하·action 매핑이 바뀌었으므로 진행 중인 capture는 더 이상 유효하지 않다.
    self.scm_dock_interaction.capture = null;
    // **세대는 여기서 올리지 않는다.** action 표는 그리기 직전의 세대로 태깅되므로, 발행 직후 올리면
    // 그 프레임의 클릭이 전부 stale로 거부된다(테스트가 "행을 눌렀는데 0개 열림"으로 잡았다).
    // 세대는 **목록이 바뀔 때**(새 git 결과·목록 폐기) 올린다 — `git.zig`가 그 지점을 소유한다.
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
fn repoPathAt(self: *AppSession, index: u32) ?[]const u8 {
    const repos = repoEntries(self);
    if (index >= repos.entries.len) return null;
    // 캐시는 세션 소유라 그대로 빌려 줘도 된다(프레임 안에서 쓴다).
    return repos.entries[index].path;
}

/// 상자 **밖**을 눌렀으면 편집을 뗀다. 안이면 아무것도 안 한다(그 클릭은 caret을 놓는 클릭이다).
pub fn blurCommitIfOutside(self: *AppSession, x_px: f64, y_px: f64) void {
    if (self.scm_commit_focus_repo == null) return;
    const rect = commitBoxRect(self) orelse return blurCommit(self);
    const content = dock_ops.dockGeometry(self).tree_content;
    const local_x = x_px - @as(f64, @floatFromInt(content.x));
    const local_y = y_px - @as(f64, @floatFromInt(content.y));
    const inside = local_x >= rect.x and local_x < rect.x + rect.width and
        local_y >= rect.y and local_y < rect.y + rect.height;
    if (!inside) blurCommit(self);
}

pub fn applyScmDockIntent(self: *AppSession, intent: component.ids.Intent) void {
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
            self.scm_selected_commit = index;
            // **고르기와 펼치기는 같은 클릭이다**(P4b). 커밋을 눌렀을 때 사용자가 보려는 것은 "그 커밋이
            // 무엇을 바꿨나"이고, 그것을 따로 여는 두 번째 컨트롤을 만들 이유가 없다.
            if (commitOidAt(self, index)) |oid| toggleCommitExpanded(self, oid);
            self.metal_dirty = true;
        },
        // 펼친 커밋의 파일 → `커밋^ ↔ 커밋` 비교를 연다.
        .open_commit_file => |index| openCommitFileDiff(self, index),
        .toggle_repo => |index| {
            // **인덱스는 목록 기준**이라 지금 목록에서 다시 찾는다 — 늦게 온 클릭이 다른 저장소를 접지
            // 않게(파일 행이 모델 인덱스를 다시 조회하는 것과 같은 규율).
            const repos = repoEntries(self);
            if (index >= repos.entries.len) return;
            toggleRepoCollapsed(self, repos.entries[index].path);
        },
        .scroll_thumb, .scroll_track => {},
    }
}

/// 도크의 탭을 바꾼다(P4). **편집은 그대로 둔다** — 탭을 옮긴다고 사용자가 쓰던 커밋 메시지를
/// 버릴 이유가 없고, 상자는 변경 사항 탭으로 돌아오면 그 자리에 있다.
pub fn selectScmTab(self: *AppSession, tab: component.types.Tab) void {
    if (self.scm_tab == tab) return;
    self.scm_tab = tab;
    // 목록·히스토리는 서로 다른 스크롤 축이다 — 남겨 두면 히스토리 첫 화면이 엉뚱한 자리에서 시작한다.
    self.scm_scroll = .{};
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
    self.scm_selected_commit = null;
    // **펼친 커밋과 그 파일도 버린다**(P4b 적대적 검증). 남겨 두면 그 OID를 **새 저장소에서** 읽는다 —
    // 대개 실패하지만, 실패든 아니든 그건 이 저장소의 사실이 아니다.
    if (self.scm_expanded_commit) |oid| self.allocator.free(oid);
    self.scm_expanded_commit = null;
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
    self.metal_dirty = true;
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
    if (self.scm_tab != .history) return;
    if (self.scm_commit_files_inflight != 0) return;
    const oid = self.scm_expanded_commit orelse return;
    if (self.scm_commit_files_oid) |current| {
        if (std.mem.eql(u8, current, oid)) return; // 이미 그 커밋을 읽어 뒀다(실패도 답이다)
    }
    const repo = self.git_repo orelse return;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse return;
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch return;
    }
    self.scm_commit_files_seq += 1;
    if (!self.git_backend.?.submitCommitFiles(git_exe, repo, oid, self.scm_commit_files_seq)) return;
    self.scm_commit_files_inflight = self.scm_commit_files_seq;
}

/// 도착한 파일 목록을 싣는다. **OID로 맞춘다** — 사용자가 빠르게 다른 커밋을 펼치면 늦게 온 답이
/// 남의 줄을 채운다.
pub fn drainCommitFiles(self: *AppSession) void {
    const backend = &(self.git_backend orelse return);
    var taken = backend.takeCommitFilesResult() orelse return;
    defer taken.deinit(git_backend_mod.worker_allocator);
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

/// 모델의 행 동작을 component 값으로 옮긴다. 값이 갈리면 이 exhaustive switch가 컴파일로 걸린다.
fn actionOf(action: scm_view.RowAction) component.types.RowAction {
    return switch (action) {
        .stage => .stage,
        .unstage => .unstage,
        .none => .none,
    };
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
    const kind: git_write_command.Kind = switch (row.action) {
        .stage => .stage,
        .unstage => if (model.head.unborn) .unstage_unborn else .unstage,
        .none => return,
    };
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
    const kind: git_write_command.Kind = switch (target) {
        .staged => if (model.head.unborn) .unstage_all_unborn else .unstage_all,
        .changes => .stage_all,
    };
    // `_all` 변종은 경로를 받지 않는다. **그래서 화면에 안 보이는 파일까지 든다** — 그것이 "모두"의 뜻이고,
    // 10행 상한에 걸려 접힌 파일도 사용자가 기대하는 대상이다.
    _ = submitWrite(self, repo, kind, &.{});
}

/// 쓰기 하나를 건다. **in-flight 하나**(§6) — 도는 동안 눌린 것은 흘린다(큐를 쌓으면 오래된 클릭이
/// 뒤늦게 저장소를 바꾼다).
fn submitWrite(self: *AppSession, repo: []const u8, kind: git_write_command.Kind, paths: []const []const u8) bool {
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
    try testing.expectEqual(component.types.StatusKind.conflicted, statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .none, .conflicted = true }));
    try testing.expectEqual(component.types.StatusKind.added, statusOf(.{ .section = .changes, .path = "a", .letter = 'U', .action = .stage, .untracked = true }));
    try testing.expectEqual(component.types.StatusKind.added, statusOf(.{ .section = .staged, .path = "a", .letter = 'A', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.deleted, statusOf(.{ .section = .staged, .path = "a", .letter = 'D', .action = .unstage }));
    try testing.expectEqual(component.types.StatusKind.modified, statusOf(.{ .section = .staged, .path = "a", .letter = 'M', .action = .unstage }));
}

test "섹션 값은 두 모듈 사이에서 1:1이다" {
    // component는 session 모듈을 import하지 않으므로 이 변환이 유일한 다리다. 값이 갈리면 여기서 걸린다.
    try testing.expectEqual(component.types.Section.staged, sectionOf(.staged));
    try testing.expectEqual(component.types.Section.changes, sectionOf(.changes));
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

    const tokens = chrome.tokens.Tokens.tui(.{
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
        item.* = itemFor(row, 0, index, null, @splat(false));
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
        item.* = itemFor(row, 0, index, null, @splat(false));
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
        item.* = itemFor(row, 0, index, null, @splat(false));
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
        setScmWriteNotice(self, maru.i18n.t(.scm_repo_unread));
        return;
    }
    // 조합 중이면 먼저 확정한다 — 안 그러면 화면에 보이는 글자가 메시지에서 빠진다.
    _ = self.scm_commit_field.commitPreedit(self.allocator);
    const message = std.mem.trim(u8, self.scm_commit_field.text.items, " \t\r\n");
    if (message.len == 0) {
        setScmWriteNotice(self, maru.i18n.t(.scm_need_commit_message));
        return;
    }
    var rows_buf: [scm_row_capacity]scm_view.Row = undefined;
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const model = modelForRepo(self, repo_path, &rows_buf, &scratch) orelse return;
    if (!model.has_staged) {
        // **감추지 않고 이유를 말한다.** 버튼은 꺼진 색이지만 눌리기는 하므로, 눌렀는데 아무 일도
        // 없으면 사용자는 앱이 멈춘 줄 안다.
        setScmWriteNotice(self, maru.i18n.t(.scm_nothing_staged));
        return;
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = commitMessagePath(self, &path_buf) orelse return;
    // 메시지는 **원문 그대로** 쓴다(끝에 개행 하나만 보장 — git이 마지막 줄을 삼키지 않게).
    writeCommitMessageFile(self, path, self.scm_commit_field.text.items) catch {
        setScmWriteNotice(self, maru.i18n.t(.scm_commit_msg_write_failed));
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

/// 실패가 아니라 **안내**를 목록 위 한 줄로 낸다(빈 메시지·스테이지 0건처럼 git을 부르기도 전에 끝난
/// 경우). `scm_write_error`와 같은 자리를 쓰는 이유는 사용자가 방금 누른 동작의 결과를 같은 곳에서
/// 읽기 때문이다.
fn setScmWriteNotice(self: *AppSession, text: []const u8) void {
    clearScmWriteError(self);
    self.scm_write_error = self.allocator.dupe(u8, text) catch null;
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
/// 지운 값을 다시 읽는 동안 머리 줄이 maru.i18n.t(.scm_loading)으로 되돌아가 화면이 깜빡이기 때문이다 — 낡은 값을
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
