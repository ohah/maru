//! 에이전트 세션 기록 도크(Codex·Claude) — 아카이브 스캔·필터·스크롤·인라인 상세의 orchestration.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1).
//! **F1(archive)과 F3(agent dock)을 하나로 합쳤다** — 문서가 둘을 나눈 것은 이름 기준이었는데,
//! 호출 관계를 실측하면 한 덩어리다. archive 메서드가 도크의 스크롤 앵커·인라인 상세·스모크 프로브를
//! 부르므로, 따로 떼면 그 14개를 pub으로 열었다가 다음 그룹에서 도로 닫아야 한다.
//!
//! 순수 로직이 아니라 `chrome_host`·`dock`·`runtime`·`metal_dirty`에 결합한 platform orchestration이라
//! L4에 남고 session(L2)으로 가지 않는다. 스캔·읽기·파싱은 worker(`agent_session_archive_backend` 등)가
//! 소유하고, 여기서는 그 결과를 메인 스레드 상태로 옮기고 도크 UI에 반영하는 일만 한다.
//!
//! 패턴: `*AppSession`을 받는 free 함수(Zig는 필드 privacy가 없어 필드를 직접 접근)로 두고,
//! ABI가 직접 부르는 smoke 게이트만 `app_session.zig`에 얇은 facade로 남긴다 — `find.zig`(E1)와 동형.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const dock_panel = maru.session.dock_panel;
const dock_layout = maru.session.dock_layout;
const agent_session_archive_view = maru.session.agent_session_archive_view;
const agent_session_archive_detail = maru.session.agent_session_archive_detail;
const agent_session_archive_backend = @import("../agent_session_archive_backend.zig");
const agent_session_archive_detail_backend = @import("../agent_session_archive_detail_backend.zig");
const agent_session_archive_scope_backend = @import("../agent_session_archive_scope_backend.zig");
const chrome_system_text = @import("../chrome/system_text.zig");
const scroll_ops = @import("scroll.zig"); // 스크롤바 fade alpha(host 소유 · view 가 얹는다)
const coretext_frame_builder = @import("../coretext_frame_builder.zig");
const metal_frame = maru.renderer.metal_frame;
const icons = maru.icons;
const layout_math = maru.session.layout_math;
const app_session_mod = @import("../app_session.zig"); // 공용 test 하네스·상수는 아직 그쪽 소유(이 PR 한계)
const AppSession = app_session_mod.AppSession;
const term_ops = @import("term.zig");
const agent_ops = @import("agent.zig");
const tab_ops = @import("tab.zig");
const dock_ops = @import("dock.zig");
const pane_ops = @import("pane.zig");
const git_ops = @import("git.zig"); // 범위 칩의 cwd 해석을 소스 컨트롤·탐색기·사이드바와 공유한다
const chrome_draw_lowering = app_session_mod.chrome_draw_lowering;
const dock_view_bar = app_session_mod.dock_view_bar;
const smokeProbeVisibleRect = AppSession.smokeProbeVisibleRect;
const AgentSessionArchiveScope = app_session_mod.AgentSessionArchiveScope;
const AgentSessionArchiveSmokeProbe = app_session_mod.AgentSessionArchiveSmokeProbe;
const AgentSessionDockPointerDispatch = AppSession.AgentSessionDockPointerDispatch;
const CollectedPane = AppSession.CollectedPane;
const MeasuredTextCache = app_session_mod.MeasuredTextCache;
const file_tree = app_session_mod.file_tree;

pub fn archiveOpenedDevice(file: std.Io.File) u64 {
    if (comptime builtin.os.tag != .macos) return 0;
    var stat: std.posix.Stat = undefined;
    if (std.c.fstat(file.handle, &stat) != 0) return std.math.maxInt(u64);
    return @intCast(stat.dev);
}

pub fn agentSessionArchiveMatches(record: agent_session_archive_backend.Record, query: []const u8) bool {
    return query.len == 0 or asciiContainsIgnoreCase(record.parsed.title, query) or
        asciiContainsIgnoreCase(record.parsed.summary, query) or
        asciiContainsIgnoreCase(record.parsed.cwd, query) or
        asciiContainsIgnoreCase(record.parsed.model, query);
}

/// 마지막 활동 시각은 이미 immutable worker snapshot 안에 있으므로 카드가 filesystem을 건드리지 않고
/// 상대 시간을 보인다. 시계 되감기와 미래 시각은 의도적으로 "방금"으로 그린다.
///
/// 넘기는 값은 **정렬 키와 같은 것**이어야 한다(`lastActivityNs`). 다르면 목록 순서와 카드가 말하는
/// 시간이 어긋나 "3일 전" 카드가 맨 위에 앉는다.
pub fn formatAgentSessionArchiveRelativeAge(now_ns: i128, activity_ns: i96, buf: []u8) []const u8 {
    const then: i128 = activity_ns;
    const delta_ns = if (now_ns > then) now_ns - then else 0;
    const minutes = @divFloor(delta_ns, 60 * std.time.ns_per_s);
    if (minutes == 0) return maru.i18n.t(.ad_time_now);
    if (minutes < 60) return maru.i18n.format(buf, maru.i18n.t(.ad_time_minutes), &.{.{ .d = @intCast(minutes) }});
    const hours = @divFloor(minutes, 60);
    if (hours < 24) return maru.i18n.format(buf, maru.i18n.t(.ad_time_hours), &.{.{ .d = @intCast(hours) }});
    return maru.i18n.format(buf, maru.i18n.t(.ad_time_days), &.{.{ .d = @intCast(@divFloor(hours, 24)) }});
}

pub fn agentSessionArchiveWithinRoot(record: agent_session_archive_backend.Record, root: []const u8) bool {
    return record.parsed.cwd_canonical and record.parsed.cwd.len > 0 and std.fs.path.isAbsolute(record.parsed.cwd) and
        file_tree.Tree.pathWithinRoot(record.parsed.cwd, root);
}

pub fn sameAgentSessionArchiveIdentity(a: *const agent_session_archive_backend.Record, b: *const agent_session_archive_backend.Record) bool {
    return a.parsed.provider == b.parsed.provider and a.inode == b.inode and a.device == b.device and
        std.mem.eql(u8, a.parsed.session_id, b.parsed.session_id);
}

/// A borrowed identity is sufficient only inside the one main-actor transaction that swaps an
/// immutable archive snapshot.  It is captured before the old records are freed and resolved
/// against the replacement before that free, so no session id is copied or retained past its
/// source snapshot.
pub const ArchiveScrollIdentity = struct {
    provider: maru.session.agent_session_archive.Provider,
    session_id: []const u8,
    device: u64,
    inode: std.Io.File.INode,

    pub fn fromRecord(record: *const agent_session_archive_backend.Record) ArchiveScrollIdentity {
        return .{
            .provider = record.parsed.provider,
            .session_id = record.parsed.session_id,
            .device = record.device,
            .inode = record.inode,
        };
    }

    pub fn eqlRecord(self: ArchiveScrollIdentity, record: *const agent_session_archive_backend.Record) bool {
        return self.provider == record.parsed.provider and self.device == record.device and self.inode == record.inode and
            std.mem.eql(u8, self.session_id, record.parsed.session_id);
    }
};

pub const ArchiveScrollAnchor = struct {
    identity: ArchiveScrollIdentity,
    /// Backing pixels from the anchored card's top to the old viewport top.  This is always
    /// non-negative because only a card crossing the viewport top may become an anchor.
    intra_card_y_px: u32,
};

/// 아카이브 목록의 항목 높이 규칙이다. `chrome.ui.scroll_area`는 높이가 균일하다고 가정하지 않고
/// comptime 함수로 물어보므로(docs/scroll-area.md §3), 그룹 헤더·카드·펼친 카드라는 이 도크만의
/// 예외가 전부 여기 한 자리에 모인다. 스크롤 투영·anchor 복원·페이지 키가 같은 값을 본다.
pub const ArchiveScrollItems = struct {
    /// **살아 있는 투영을 빌린 슬라이스**다. 스냅샷 교체·필터 재계산을 건너 붙들면 dangling이 되므로
    /// 호출자는 이 값을 저장하지 않고 같은 표현식 안에서 쓴다. 높이만 필요하면 필드를 복사한다.
    entries: []const agent_session_archive_view.Entry,
    group_h_px: u32,
    card_h_px: u32,
    gap_px: u32,
    /// 펼침은 최대 하나다. 그 index와 완전히 예약된 높이를 여기 함께 두어야 virtualization·clip·
    /// hit-test가 같은 content-space 기하에 합의한다 — host가 detail 전용 y를 따로 더하지 않는다.
    expanded_index: ?usize = null,
    expanded_h_px: u32 = 0,

    pub fn heightPx(self: ArchiveScrollItems, index: usize) u32 {
        return switch (self.entries[index]) {
            .group => self.group_h_px,
            .card => if (self.expanded_index != null and self.expanded_index.? == index)
                self.expanded_h_px
            else
                self.card_h_px,
        };
    }

    pub fn extent(self: ArchiveScrollItems, viewport_h_px: u32) chrome.ui.scroll_area.Extent {
        return .{ .count = self.entries.len, .gap_px = self.gap_px, .viewport_h_px = viewport_h_px };
    }
};

/// content-space에서 지금 목록 상단에 걸리는 그룹과, 그것을 밀어낼 다음 그룹의 자리.
pub const ArchiveStickyGroup = struct {
    /// 전체 목록에서의 index다. **가상화 창 밖일 수 있다** — 그래서 component가 이걸 못 구한다.
    index: usize,
    top_px: u32,
    next_top_px: ?u32,
};

/// 첫 그룹에 닿기 전이면 null이다. 그때는 흐름 위의 행이 그대로 보이고, 고정할 것이 없다.
///
/// "걸린 그룹"은 top이 offset **이하**인 마지막 그룹이다. 그 그룹의 행은 이미 뷰포트 위로 나갔거나
/// 막 상단에 닿았고, 고정 헤더가 같은 rect를 덮으므로 두 번 그려 보이지 않는다.
pub fn archiveStickyGroupFor(items: ArchiveScrollItems, offset_px: u32) ?ArchiveStickyGroup {
    var top: u32 = 0;
    var found: ?ArchiveStickyGroup = null;
    for (items.entries, 0..) |entry, index| {
        if (entry == .group) {
            if (top <= offset_px) {
                found = .{ .index = index, .top_px = top, .next_top_px = null };
            } else if (found != null) {
                found.?.next_top_px = top;
                return found;
            }
        }
        top +|= items.heightPx(index);
        if (index + 1 < items.entries.len) top +|= items.gap_px;
    }
    return found;
}

pub fn archiveScrollAnchorFor(
    records: []const agent_session_archive_backend.Record,
    projection: chrome.ui.scroll_area.Projection,
    items: ArchiveScrollItems,
) ?ArchiveScrollAnchor {
    var y: i64 = projection.first_origin_y_px;
    var index = projection.first_index;
    while (index < projection.end_exclusive) : (index += 1) {
        const entry = items.entries[index];
        const h: i64 = items.heightPx(index);
        if (entry == .card and y <= 0 and y + h > 0) {
            const record_index = entry.card;
            if (record_index >= records.len) return null;
            return .{
                .identity = .fromRecord(&records[record_index]),
                .intra_card_y_px = @intCast(-y),
            };
        }
        y += h;
        if (index + 1 < items.entries.len) y += items.gap_px;
    }
    return null;
}

pub fn archiveScrollAnchorOffsetFor(
    records: []const agent_session_archive_backend.Record,
    saved: ArchiveScrollAnchor,
    items: ArchiveScrollItems,
    max_offset_px: u32,
) ?u32 {
    var top: u32 = 0;
    for (items.entries, 0..) |entry, index| {
        const h = items.heightPx(index);
        if (entry == .card) {
            const record_index = entry.card;
            if (record_index < records.len and saved.identity.eqlRecord(&records[record_index]))
                return chrome.ui.scroll_area.anchorOffsetPx(top, saved.intra_card_y_px, max_offset_px);
        }
        top +|= h;
        if (index + 1 < items.entries.len) top +|= items.gap_px;
    }
    return null;
}

pub fn archiveSnapshotSelectionIndex(
    previous: ?*const agent_session_archive_backend.Record,
    replacement: []const agent_session_archive_backend.Record,
) ?usize {
    const selected = previous orelse return null;
    for (replacement, 0..) |*candidate, index| {
        if (sameAgentSessionArchiveIdentity(selected, candidate)) return index;
    }
    return null;
}

/// Scope refresh is driven by the cheap runtime observation, never a
/// filesystem comparison. A same-pane `cd` must therefore be distinguishable
/// from a repeated frame carrying the same CWD.
pub fn agentSessionArchiveObservedCwdChanged(previous: ?[]const u8, current: []const u8) bool {
    return if (previous) |path| !std.mem.eql(u8, path, current) else true;
}

/// 한 터미널의 런타임 단위: surface(그리드/스크롤백, 참조) + 그 surface에 붙은 live PTY 셸(참조) + 그 PTY를 drain하는
/// pump. **M3a**: `surface`와 `live_pty`의 **소유**가 둘 다 앱 전역 `app_runtime.live_registry`로 옮겨졌고(`LiveSurface` 번들
/// 슬롯), Term은 각각 그 슬롯 필드를 가리키는 포인터다(docs/window-surface-mobility.md §8A.1 옵션 A). reader thread가
/// 잡는 `&live_pty.reader`·`&surface.core`/`&surface.core_mutex` 주소는 registry의 heap 슬롯(`allocator.create`)이
/// 고정하므로 여전히 안정적이다 — 소유 위치가 Term-inline → registry-슬롯으로 바뀌었을 뿐 heap-pin 메커니즘은 동일하다.
/// surface·live_pty가 **같은 번들 슬롯**에 있어 cross-window 이동 시 Term이 창을 옮겨도 이 두 주소는 불변이다(reader 계약).
/// reader가 `&live_pty.reader`와 `&surface.core`(둘 다 이제 registry 슬롯)를 교차 바인딩하므로, teardown은 detach 선행
/// 후 registry.remove(번들 deinit=live_pty reader join → surface.deinit)를 한 번에 지킨다. pump는 안정 `*queue`만 들어
/// 이동 제약이 없다. 탭→pane 모델에서 한 Pane(split leaf)이 이 Term을 가로 탭으로 여러 개 들 수 있다(⌘T로 추가).
///
/// `TermRuntime` = Term의 런타임 부착(PTY 세션 **참조**·이벤트 펌프·생애 플래그) — platform이 소유하는 OS/런타임
/// 결합부. session 모델(`session_model.Model(TermRuntime).Term`)에 generic `Rt`로 주입된다(§3.1). 모델 struct
/// (Term/Pane/Tab)는 session core(src/session/session_model.zig)가 소유하고, 이 런타임 결합 타입만 platform에 남는다(S2-4b).
/// Dock-local, owned state for one inline archive disclosure. Keeping the selected record with
/// its stable file identity lets resume/reveal reject a snapshot replacement without creating a
/// Term, surface, or pane-body input owner.
pub const InlineArchiveDetail = struct {
    record: agent_session_archive_backend.Record,
    request_id: u64,
    state: enum { loading, ready, stale, unavailable } = .loading,
    detail: ?agent_session_archive_detail.Detail = null,

    pub fn deinit(self: *InlineArchiveDetail, allocator: std.mem.Allocator) void {
        if (self.detail) |*parsed| parsed.deinit(allocator);
        self.record.deinit(allocator);
        self.* = undefined;
    }
};

/// 도크 진입에서 아카이브 스캔을 요청할지. 순수 판정이라 부작용 없이 테스트로 고정한다.
///
/// **가시성이 첫 조건이다.** `setDockView`는 도크가 닫힌 상태에서도 불리므로(workspace restore 등),
/// 이 가드가 없으면 보이지도 않는 도크가 사용자 이력 전체를 스캔한다.
pub fn shouldRefreshArchiveOnPresent(dock_visible: bool, view: dock_panel.View) bool {
    return dock_visible and view == .agent_sessions;
}

/// 점진 발행을 요청할지. 순수 판정이라 부작용 없이 테스트로 고정한다.
///
/// 기준은 "완주한 적이 있는가"가 아니라 **"지금 보여 줄 목록이 있는가"**다. 부분 진행 결과도 목록을
/// 통째로 교체하므로, 이미 목록이 있는데 점진 경로를 타면 첫 발행이 그 목록을 더 짧은 목록으로 덮는다.
pub fn shouldRequestArchiveProgress(visible_record_count: usize) bool {
    return visible_record_count == 0;
}

pub fn refreshAgentSessionArchive(self: *AppSession, force: bool) void {
    if (!self.agent_session_archive_initialized or self.agent_session_archive_loading) return;
    const now = std.Io.Clock.awake.now(self.io).nanoseconds;
    if (!force and self.agent_session_archive_completed_ns != 0 and now - self.agent_session_archive_completed_ns < agent_session_archive_snapshot_ttl_ns) return;
    const home_z = std.c.getenv("HOME") orelse return;
    const home = std.mem.span(home_z);
    if (home.len == 0) return;
    const owned = self.allocator.dupe(u8, home) catch return;
    // 점진 발행은 **빈 화면을 피하기 위한 것**이다(docs/agent-session-list.md §4.1). 그러므로 판정
    // 기준은 "완주한 적이 있는가"가 아니라 "지금 보여 줄 목록이 있는가"다.
    //
    // 부분 진행 결과도 목록을 통째로 교체하므로, 화면에 이미 목록이 있는데 점진 경로를 타면 첫 발행
    // (12개)이 그 목록을 덮어 **줄었다가 다시 차오르는** 것처럼 보인다. 이전 스캔이 부분만 받고
    // 취소된 뒤 재진입하는 경우가 정확히 그 상황이다. 이럴 때는 완성본 하나로 교체하는 편이 조용하다.
    const wants_progress = shouldRequestArchiveProgress(self.agent_session_archive_records.items.len);
    if (!self.agent_session_archive_backend.submit(owned, wants_progress)) {
        self.allocator.free(owned);
        return;
    }
    self.agent_session_archive_loading = true;
    self.metal_dirty = true;
}

/// Hiding this view must not let an old local-history scan replace a later, reopened dock.
/// The backend owns descriptor/allocation cleanup; this main-actor edge only withdraws the
/// generation and stops rendering a spinner for UI that is no longer visible.
pub fn cancelAgentSessionArchive(self: *AppSession) void {
    if (!self.agent_session_archive_initialized) return;
    if (!self.agent_session_archive_backend.cancel()) return;
    self.agent_session_archive_loading = false;
    self.metal_dirty = true;
}

pub fn updateAgentSessionArchive(self: *AppSession) void {
    if (!self.agent_session_archive_initialized) return;
    // The worker publishes one completed immutable snapshot only. Keeping
    // the old snapshot until this point prevents refresh from blanking or
    // visibly reordering the archive list while JSONL is still scanning.
    var result = self.agent_session_archive_backend.takeResult() orelse return;
    defer result.deinit(self.allocator);
    switch (result.outcome) {
        .completed, .partial_progress => {},
        .cancelled => {
            self.agent_session_archive_loading = false;
            // A reopened dock requests again only after the cancelled worker has fully
            // released its state. This makes the newest entry win without concurrent scans.
            // 이 force 재요청은 **여기가 단독 소유자**다 — 도크 진입 훅은 force를 쓰지 않는다
            // (양쪽이 쓰면 빠른 여닫기에서 `취소 → 재요청 → 취소`가 반복된다).
            if (dock_ops.dockVisible(self) and self.dock.view == .agent_sessions) refreshAgentSessionArchive(self, true);
            self.metal_dirty = true;
            return;
        },
        .retain_previous => {
            self.agent_session_archive_loading = false;
            self.showNoticeKey(.ad_session_list_apply_failed);
            self.metal_dirty = true;
            return;
        },
    }
    const prior_selected = if (self.agent_session_archive_selected) |index|
        if (index < self.agent_session_archive_records.items.len) &self.agent_session_archive_records.items[index] else null
    else
        null;
    const preserved_selected = archiveSnapshotSelectionIndex(prior_selected, result.records.items);
    // Keep the old backing records alive until the replacement projection has had one chance
    // to resolve the exact card anchor.  The anchor borrows the old session-id bytes, so
    // freeing this list before restore would either dangle or force a second owned identity
    // cache solely for this one atomic main-actor commit.
    const prior_scroll_offset = self.agent_session_archive_scroll.offset_y_px;
    const prior_scroll_anchor = captureAgentSessionDockScrollAnchor(self);
    var old_records = self.agent_session_archive_records;
    self.agent_session_archive_records = result.records;
    result.records = .empty;
    self.agent_session_archive_partial = result.partial;
    self.agent_session_archive_selected = preserved_selected;
    rebuildAgentSessionArchiveFilter(self);
    reconcileAgentSessionInlineDetailAgainstSnapshot(self);
    restoreAgentSessionDockScrollAnchor(self, prior_scroll_anchor, prior_scroll_offset);
    for (old_records.items) |*record| record.deinit(self.allocator);
    old_records.deinit(self.allocator);
    self.agent_session_archive_scroll.dropWheelResidue();
    // **부분 진행은 완료로 치지 않는다**(§4.1). `completed_ns`를 갱신하면 TTL 가드가 걸려 재스캔이
    // 막히고 목록이 불완전한 채 고정되며, spinner를 끄면 아직 도는 스캔이 끝난 것처럼 보인다.
    if (result.outcome == .completed) {
        self.agent_session_archive_loading = false;
        self.agent_session_archive_completed_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
    }
    self.metal_dirty = true;
}

pub fn clearAgentSessionArchiveWorkspaceRoot(self: *AppSession) void {
    if (self.agent_session_archive_workspace_root) |old| self.allocator.free(old);
    self.agent_session_archive_workspace_root = null;
}

pub fn clearAgentSessionArchiveProjectRoot(self: *AppSession) void {
    if (self.agent_session_archive_project_root) |old| self.allocator.free(old);
    self.agent_session_archive_project_root = null;
}

pub fn replaceAgentSessionArchiveScopeObservedCwd(self: *AppSession, owned_cwd: []u8) void {
    if (self.agent_session_archive_scope_observed_cwd) |old| self.allocator.free(old);
    self.agent_session_archive_scope_observed_cwd = owned_cwd;
}

pub fn clearAgentSessionArchiveScopeObservedCwd(self: *AppSession) void {
    if (self.agent_session_archive_scope_observed_cwd) |old| self.allocator.free(old);
    self.agent_session_archive_scope_observed_cwd = null;
}

pub fn submitAgentSessionArchiveScopeRoots(self: *AppSession, owned_cwd: []u8) bool {
    self.agent_session_archive_scope_request_id +%= 1;
    if (self.agent_session_archive_scope_request_id == 0) self.agent_session_archive_scope_request_id = 1;
    if (!self.agent_session_archive_scope_backend.submit(owned_cwd, self.agent_session_archive_scope_request_id)) return false;
    self.agent_session_archive_project_scope_loading = true;
    self.metal_dirty = true;
    return true;
}

/// A focus change can leave an older root walk in flight while the new
/// active Term has no local CWD. There is then no replacement job to fence
/// the old result, so advance the generation explicitly and let the drain
/// clear loading without ever publishing that previous tab's root.
pub fn invalidateAgentSessionArchiveScopeRequest(self: *AppSession) void {
    self.agent_session_archive_scope_request_id +%= 1;
    if (self.agent_session_archive_scope_request_id == 0) self.agent_session_archive_scope_request_id = 1;
}

/// cwd 해석은 **소스 컨트롤 뷰·파일 탐색기·사이드바와 같은 지점**(`git_ops.termCwd`)을 쓴다 — 규칙은
/// docs/editor-surface-dock.md §3.5가 단일 출처이고 요약하면 OSC 7 → 커널 조회 2단이다. 여기만 관측을
/// 직독하던 동안에는, 셸이 OSC 7을 안 보내는 Term에서 `현재 작업공간`·`현재 프로젝트` 칩이 **비활성으로
/// 죽었다**. 셸 통합이 없는 bash/fish는 상시, 그리고 이 도크에서 `이어하기`로 연 Term은 그 수명 내내
/// 그렇다 — 방금 이어한 세션의 프로젝트로 목록을 좁히려는 바로 그 순간 칩이 꺼지는 것이 옛 동작이었다.
///
/// **`.git` ancestor walk는 여전히 backend가 소유한다.** 이 자리는 canonicalization도 walk도 하지 않는다.
/// 원래 주석이 "in-memory observation만"이라고 못 박은 것은 그 walk를 main actor에서 막으려는 것이었는데,
/// 커널 cwd 조회는 그 부류가 아니다.
///
/// **이 함수는 프레임 경로가 아니다.** tick의 `refreshAgentSessionArchiveProjectScopeForFocus`는 활성
/// surface id가 바뀔 때만 여기까지 오고(그 전은 전부 필드 읽기), 나머지 호출자는 도크 진입과 칩 클릭이다.
/// 즉 도는 빈도가 focus 이동·view 전환 수준이며, 그마저도 실측 **약 9 µs**다(2026-08-12, 프로세스 848개인
/// 머신: `proc_listpgrppids` 8.65 µs + `proc_pidinfo` 0.78 µs). 비교 대상인 `.git` walk는 경로 구성요소마다
/// `access(2)`를 쓰는 자릿수가 다른 비용이다. 게다가 GUI tick이 같은 Term의 Term별 0.5초 캐시
/// (`term.rt.proc_cwd_*`)를 이미 데워 두므로 대개 syscall이 0이다 — 이 함수는 그 캐시를 공유한다.
///
/// (비용의 92%인 `proc_listpgrppids`는 **전체 프로세스 테이블 스캔**이다 — 없는 pgid도 8.65 µs로
/// `proc_listpids(ALL_PIDS)`와 같아 그룹 크기가 아니라 시스템 프로세스 수에 비례한다. 캐시가 막는 것이
/// 정확히 그 스캔이다.)
///
/// **원격 Term은 이제 여기서 끊긴다.** `termCwd`가 원격에 null을 내기 때문인데, 이것은 부수 효과가 아니라
/// 고쳐야 할 것이었다: 옛 경로는 원격 cwd를 그대로 backend에 넘겼고, `canonicalDirectory`는 그 경로를
/// **로컬 파일시스템에 대고** `realPath`+`openDir` 한다. 로컬에 같은 경로가 우연히 있으면 그 **로컬**
/// 디렉터리가 워크스페이스 루트로 서서, 원격 세션인데 로컬 아카이브를 "이 작업공간 것"으로 거른다
/// (docs/ssh-integration.md §9.4가 링크 감지에서 막은 것과 같은 함정).
pub fn requestAgentSessionArchiveScopeRoots(self: *AppSession, requested: ?AgentSessionArchiveScope) void {
    if (requested) |scope| switch (scope) {
        .workspace => self.agent_session_archive_workspace_scope_requested = true,
        .project => self.agent_session_archive_project_scope_requested = true,
        .all => unreachable,
    };
    const term = tab_ops.activeTab(self).activeTerm();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = git_ops.termCwd(self, term, &cwd_buf) orelse "";
    if (!std.fs.path.isAbsolute(cwd) or cwd.len == 0) {
        const had_observed_cwd = self.agent_session_archive_scope_observed_cwd != null;
        clearAgentSessionArchiveScopeObservedCwd(self);
        if (!had_observed_cwd and requested == null) return;
        if (self.agent_session_archive_project_scope_loading) {
            if (self.agent_session_archive_project_scope_pending_cwd) |old| self.allocator.free(old);
            self.agent_session_archive_project_scope_pending_cwd = null;
            invalidateAgentSessionArchiveScopeRequest(self);
        }
        clearAgentSessionArchiveWorkspaceRoot(self);
        clearAgentSessionArchiveProjectRoot(self);
        if (self.agent_session_archive_workspace_scope_requested) {
            self.agent_session_archive_workspace_scope_requested = false;
            self.showNoticeKey(.ad_workspace_path_missing);
        }
        if (self.agent_session_archive_project_scope_requested) {
            self.agent_session_archive_project_scope_requested = false;
            self.showNoticeKey(.ad_terminal_git_project_missing);
        }
        if (self.agent_session_archive_scope != .all) {
            rebuildAgentSessionArchiveFilter(self);
            self.agent_session_archive_selected = null;
            resetAgentSessionDockScroll(self);
            self.metal_dirty = true;
        }
        return;
    }
    const cwd_changed = agentSessionArchiveObservedCwdChanged(self.agent_session_archive_scope_observed_cwd, cwd);
    if (!cwd_changed and requested == null) return;
    const observed_cwd = self.allocator.dupe(u8, cwd) catch return;
    const owned_cwd = self.allocator.dupe(u8, cwd) catch {
        self.allocator.free(observed_cwd);
        return;
    };
    replaceAgentSessionArchiveScopeObservedCwd(self, observed_cwd);
    // A `cd` in the already active pane changes the containment authority
    // just as a pane switch does. Do not leave rows from the old CWD's
    // workspace/project visible while the replacement root is walking.
    if (cwd_changed and self.agent_session_archive_scope != .all) {
        clearAgentSessionArchiveWorkspaceRoot(self);
        clearAgentSessionArchiveProjectRoot(self);
        rebuildAgentSessionArchiveFilter(self);
        self.agent_session_archive_selected = null;
        resetAgentSessionDockScroll(self);
        self.metal_dirty = true;
    }
    if (self.agent_session_archive_project_scope_loading) {
        if (self.agent_session_archive_project_scope_pending_cwd) |old| self.allocator.free(old);
        self.agent_session_archive_project_scope_pending_cwd = owned_cwd;
        return;
    }
    if (!submitAgentSessionArchiveScopeRoots(self, owned_cwd)) {
        self.allocator.free(owned_cwd);
        if (self.agent_session_archive_workspace_scope_requested or self.agent_session_archive_project_scope_requested) {
            self.agent_session_archive_workspace_scope_requested = false;
            self.agent_session_archive_project_scope_requested = false;
            self.showNoticeKey(.ad_path_scan_start_failed);
        }
        return;
    }
}

pub fn updateAgentSessionArchiveProjectScope(self: *AppSession) void {
    var result = self.agent_session_archive_scope_backend.takeResult() orelse return;
    defer result.deinit(self.allocator);
    if (result.request_id != self.agent_session_archive_scope_request_id) {
        // An active-Term transition without a usable CWD invalidated this
        // worker. It has no replacement completion to clear the spinner.
        self.agent_session_archive_project_scope_loading = false;
        self.metal_dirty = true;
        return;
    }
    self.agent_session_archive_project_scope_loading = false;
    if (self.agent_session_archive_project_scope_pending_cwd) |pending_cwd| {
        self.agent_session_archive_project_scope_pending_cwd = null;
        if (submitAgentSessionArchiveScopeRoots(self, pending_cwd)) return;
        self.allocator.free(pending_cwd);
        self.agent_session_archive_workspace_scope_requested = false;
        self.agent_session_archive_project_scope_requested = false;
        self.showNoticeKey(.ad_path_scan_restart_failed);
        self.metal_dirty = true;
        return;
    }
    clearAgentSessionArchiveWorkspaceRoot(self);
    self.agent_session_archive_workspace_root = result.workspace_root;
    result.workspace_root = null;
    clearAgentSessionArchiveProjectRoot(self);
    self.agent_session_archive_project_root = result.project_root;
    result.project_root = null;
    if (self.agent_session_archive_scope != .all) {
        rebuildAgentSessionArchiveFilter(self);
        self.agent_session_archive_selected = null;
        resetAgentSessionDockScroll(self);
    }
    if (self.agent_session_archive_workspace_scope_requested) {
        self.agent_session_archive_workspace_scope_requested = false;
        if (self.agent_session_archive_workspace_root == null) {
            self.showNoticeKey(.ad_workspace_path_missing);
        } else {
            self.agent_session_archive_scope = .workspace;
            rebuildAgentSessionArchiveFilter(self);
            self.agent_session_archive_selected = null;
            resetAgentSessionDockScroll(self);
        }
    }
    if (self.agent_session_archive_project_scope_requested) {
        self.agent_session_archive_project_scope_requested = false;
        if (self.agent_session_archive_project_root == null) {
            self.showNoticeKey(.ad_terminal_git_project_missing);
        } else {
            self.agent_session_archive_scope = .project;
            rebuildAgentSessionArchiveFilter(self);
            self.agent_session_archive_selected = null;
            resetAgentSessionDockScroll(self);
        }
    }
    self.metal_dirty = true;
}

pub fn refreshAgentSessionArchiveProjectScopeForFocus(self: *AppSession) void {
    if (!dock_ops.dockVisible(self) or self.dock.view != .agent_sessions or !self.surface_initialized) return;
    const surface_id = term_ops.activeSurface(self).id;
    if (self.agent_session_archive_project_scope_surface_id == surface_id) return;
    self.agent_session_archive_project_scope_surface_id = surface_id;
    refreshAgentSessionArchiveScopeSnapshots(self);
    requestAgentSessionArchiveScopeRoots(self, null);
}

pub fn refreshAgentSessionArchiveScopeSnapshots(self: *AppSession) void {
    // A workspace root belongs to the active workspace tab, never to the
    // window-global explorer. Drop the old snapshot before a new worker
    // result arrives so switching tabs cannot briefly show another tab's
    // archive containment range.
    clearAgentSessionArchiveWorkspaceRoot(self);
    clearAgentSessionArchiveProjectRoot(self);
    clearAgentSessionArchiveScopeObservedCwd(self);
    rebuildAgentSessionArchiveFilter(self);
    self.agent_session_archive_selected = null;
    resetAgentSessionDockScroll(self);
}

pub fn selectAgentSessionArchiveScope(self: *AppSession, scope: AgentSessionArchiveScope) void {
    if (scope != .workspace) self.agent_session_archive_workspace_scope_requested = false;
    if (scope != .project) self.agent_session_archive_project_scope_requested = false;
    const available = switch (scope) {
        .workspace => self.agent_session_archive_workspace_root != null,
        .project => {
            requestAgentSessionArchiveScopeRoots(self, .project);
            return;
        },
        .all => true,
    };
    if (!available) {
        if (scope == .workspace) {
            requestAgentSessionArchiveScopeRoots(self, .workspace);
            return;
        }
        unreachable;
    }
    self.agent_session_archive_scope = scope;
    rebuildAgentSessionArchiveFilter(self);
    self.agent_session_archive_selected = null;
    closeAgentSessionInlineDetail(self);
    resetAgentSessionDockScroll(self);
    self.metal_dirty = true;
}

pub fn archiveSmokeFakeProviderExecutable(provider: maru.session.agent_session_archive.Provider) ?[]const u8 {
    const enabled = std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE") orelse return null;
    if (!std.mem.eql(u8, std.mem.span(enabled), "1")) return null;
    // Keep the test-only direct-exec seam narrower than a single generic flag: it is valid
    // only for one named cold-process action scenario per provider. Normal launches,
    // including a user who happens to export the generic flag, retain `/usr/bin/env`.
    const raw_scenario = std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO") orelse return null;
    const scenario = std.mem.span(raw_scenario);
    const known_codex_scenario = std.mem.eql(u8, scenario, "resume-pointer") or
        std.mem.eql(u8, scenario, "resume-keyboard") or
        std.mem.eql(u8, scenario, "reveal-pointer") or
        std.mem.eql(u8, scenario, "reveal-keyboard") or
        std.mem.eql(u8, scenario, "reveal-recheck-pointer");
    const raw = switch (provider) {
        .codex => if (known_codex_scenario)
            std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CODEX")
        else
            null,
        .claude => if (std.mem.eql(u8, scenario, "claude-resume-pointer"))
            std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CLAUDE")
        else
            null,
    } orelse return null;
    const path = std.mem.span(raw);
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
}

pub fn archiveSmokeScenarioIs(expected: []const u8) bool {
    const enabled = std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE") orelse return false;
    if (!std.mem.eql(u8, std.mem.span(enabled), "1")) return false;
    const raw = std.c.getenv("MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO") orelse return false;
    return std.mem.eql(u8, std.mem.span(raw), expected);
}

/// Explicit archive-log action. The pending external-open ABI is shared
/// with file-tree reveal, but this admission first reopens the exact
/// no-follow regular file and compares the worker snapshot identity.
pub fn revealAgentSessionArchiveLog(self: *AppSession, record: *const agent_session_archive_backend.Record) !void {
    const file = try std.Io.Dir.cwd().openFile(self.io, record.source_path, .{ .follow_symlinks = false });
    defer file.close(self.io);
    const stat = try file.stat(self.io);
    if (stat.kind != .file or stat.inode != record.inode or archiveOpenedDevice(file) != record.device) return error.StaleArchiveSource;
    const owned = try self.allocator.dupe(u8, record.source_path);
    if (self.file_tree_external_open) |old| self.allocator.free(old);
    self.file_tree_external_open = owned;
}

pub fn cloneAgentSessionArchiveRecord(
    allocator: std.mem.Allocator,
    source: *const agent_session_archive_backend.Record,
) !agent_session_archive_backend.Record {
    const parsed = try source.parsed.clone(allocator);
    errdefer {
        var owned = parsed;
        owned.deinit(allocator);
    }
    const path = try allocator.dupe(u8, source.source_path);
    return .{
        .parsed = parsed,
        .source_path = path,
        .mtime_ns = source.mtime_ns,
        .inode = source.inode,
        .device = source.device,
    };
}

pub fn nextAgentSessionArchiveDetailRequestId(self: *AppSession) u64 {
    self.agent_session_archive_detail_request_id +%= 1;
    if (self.agent_session_archive_detail_request_id == 0) self.agent_session_archive_detail_request_id = 1;
    return self.agent_session_archive_detail_request_id;
}

pub fn inlineArchiveDetailMatchesRecord(detail: *const InlineArchiveDetail, record: *const agent_session_archive_backend.Record) bool {
    return detail.record.parsed.provider == record.parsed.provider and
        detail.record.device == record.device and
        detail.record.inode == record.inode and
        std.mem.eql(u8, detail.record.parsed.session_id, record.parsed.session_id);
}

/// A dock-local disclosure owns a cloned, identity-bound record and deliberately creates
/// neither a Term nor a surface. The SessionDock completed tree is its only render/input
/// owner. Selecting the same exact source toggles it; a different source revokes prior
/// capture before its loading state is painted.
pub fn openAgentSessionInlineDetail(self: *AppSession, record: *const agent_session_archive_backend.Record) !void {
    if (self.agent_session_inline_detail) |*existing| {
        if (inlineArchiveDetailMatchesRecord(existing, record)) {
            closeAgentSessionInlineDetail(self);
            return;
        }
        existing.deinit(self.allocator);
        self.agent_session_inline_detail = null;
    }
    self.agent_session_inline_detail = .{
        .record = try cloneAgentSessionArchiveRecord(self.allocator, record),
        .request_id = nextAgentSessionArchiveDetailRequestId(self),
    };
    invalidateAgentSessionDockFrame(self);
    submitInlineAgentSessionDetail(self);
    self.metal_dirty = true;
}

/// A disclosure has no independent surface lifetime. Every path which removes it revokes
/// the painted action table first, so delayed input cannot act on detail hidden by scope,
/// search, grouping, or Escape.
pub fn closeAgentSessionInlineDetail(self: *AppSession) void {
    if (self.agent_session_inline_detail) |*detail| detail.deinit(self.allocator);
    self.agent_session_inline_detail = null;
    invalidateAgentSessionDockFrame(self);
    self.metal_dirty = true;
}

/// The bounded backend accepts one detached read at a time.  A fast card switch therefore
/// leaves the newer identity in loading state until the older result is drained; the next
/// main-actor tick retries using only the current cloned identity.  No old result is ever
/// reused for the newer card.
pub fn submitInlineAgentSessionDetail(self: *AppSession) void {
    const detail = self.agent_session_inline_detail orelse return;
    if (detail.state != .loading) return;
    var source: agent_session_archive_detail_backend.Source = .{
        .provider = detail.record.parsed.provider,
        .source_path = self.allocator.dupe(u8, detail.record.source_path) catch return,
        .inode = detail.record.inode,
        .device = detail.record.device,
    };
    if (!self.agent_session_archive_detail_backend.submit(source, detail.request_id)) source.deinit(self.allocator);
}

/// Frame work is queue-only: the detached backend performed every open,
/// stat, read, parse and redact operation before this point.
pub fn updateAgentSessionArchiveDetail(self: *AppSession) void {
    var result = self.agent_session_archive_detail_backend.takeResult() orelse return;
    defer result.deinit(self.allocator);
    if (self.agent_session_inline_detail) |*detail| {
        if (detail.request_id == result.request_id and detail.state == .loading) {
            detail.state = switch (result.state) {
                .ready => .ready,
                .stale => .stale,
                .unavailable => .unavailable,
            };
            if (result.detail) |parsed| {
                detail.detail = parsed;
                result.detail = null;
            }
            invalidateAgentSessionDockFrame(self);
            self.metal_dirty = true;
        }
    }
    // A stale completion frees the one backend slot; retry the still-current loading
    // identity only after that release, never by queuing raw transcript input on UI.
    submitInlineAgentSessionDetail(self);
}

/// A refreshed archive may nominate the same provider session id from a different file
/// identity. The currently expanded disclosure cannot reveal or resume through that
/// replacement. Absence is intentionally not a mismatch: a bounded/partial snapshot cannot
/// prove the old file disappeared.
pub fn reconcileAgentSessionInlineDetailAgainstSnapshot(self: *AppSession) void {
    if (self.agent_session_inline_detail) |*detail| {
        var replacement_seen = false;
        for (self.agent_session_archive_records.items) |record| {
            if (record.parsed.provider != detail.record.parsed.provider or
                !std.mem.eql(u8, record.parsed.session_id, detail.record.parsed.session_id)) continue;
            replacement_seen = record.inode != detail.record.inode or record.device != detail.record.device;
            break;
        }
        if (replacement_seen and detail.state != .stale) {
            if (detail.detail) |*parsed| parsed.deinit(self.allocator);
            detail.detail = null;
            detail.state = .stale;
            invalidateAgentSessionDockFrame(self);
            self.metal_dirty = true;
        }
    }
}

/// 스크롤 영역의 높이를 **layout에게 묻는다**(docs/scroll-area.md §4.2).
///
/// 창(`project`)의 입력에 뷰포트 높이가 있고 그 출력이 무엇을 build할지 정하므로 "layout 전에
/// 뷰포트를 알아야 한다"는 순서 문제가 있다. 예전에는 `content.h - fixedChromeHeight()`로
/// **예측**해서 풀었는데, 그러면 같은 수의 출처가 둘이 되어 고정 chrome이 하나 늘거나 margin이
/// 바뀔 때 조용히 어긋난다(어긋나면 마지막 항목이 잘리거나 빈 띠가 남는다).
///
/// 대신 **자식 없는** scroll-area로 layout을 한 번 돌린다. item 노드를 만들지 않으므로 비싸지
/// 않다 — 고정 chrome 넷과 빈 컨테이너뿐이다. 실패하면 0을 돌려주고, 그러면 창이 비어 이 프레임에
/// 목록이 그려지지 않는다(틀린 높이로 그리는 것보다 낫다).
pub fn agentSessionDockContentViewportHeightPx(self: *const AppSession) u32 {
    const content = dock_ops.dockGeometry(self).tree_content;
    if (content.w == 0 or content.h == 0) return 0;

    // 버퍼 크기는 **계약에서 파생한다**. 예전에는 고정 `[16]`이었고, 넘치면 조용히 `return 0`이었다 —
    // 그런데 이 함수의 0은 "스크롤 뷰포트 높이 0"이라 가상화가 통째로 죽는다는 뜻이고, 컴파일도 테스트도
    // 그것을 잡지 못한다. 도크에 노드를 하나 더하는 것만으로 스크롤이 조용히 멈추는 함정이라, 상한을
    // `bufferSizes`에서 comptime으로 받아 영원히 맞게 둔다(정렬 토글이 이미 그 여유를 한 칸 먹었다).
    const sizes = comptime chrome.components.session_dock.build.bufferSizes(&.{});
    var nodes: [sizes.nodes]chrome.ui.tree.UiNode = undefined;
    var entries: [sizes.entries]chrome.ui.tree.RectEntry = undefined;
    var layout_items: [sizes.layout_items]chrome.ui.layout.Item = undefined;
    var flex_scratch: [sizes.flex_scratch]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [sizes.child_rects]chrome.ui.layout.UiRect = undefined;
    var actions: [sizes.actions]chrome.components.session_dock.ids.Entry = undefined;

    const frame = chrome.components.session_dock.build.build(
        agentSessionDockProps(self, content, .{
            .content_height_px = 0,
            .max_offset_px = 0,
            .offset_y_px = 0,
            .first_index = 0,
            .first_origin_y_px = 0,
            .end_exclusive = 0,
        }, &.{}),
        .{
            .nodes = &nodes,
            .entries = &entries,
            .layout_items = &layout_items,
            .flex_scratch = &flex_scratch,
            .child_rects = &child_rects,
            .actions = &actions,
        },
    ) catch return 0;
    const index = frame.tree.find(chrome.components.session_dock.build.NodeIds.content) orelse return 0;
    return @intFromFloat(@max(@round(frame.tree.entries[index].rect.height), 0));
}

/// Completed Session Dock geometry is the only coordinate source for the native IME
/// candidate window.  The field's label is shaped by CoreText, but its end caret follows
/// the same bounded EAW cell budget as the component before the worker has a new artifact.
/// This keeps a Korean composition inside the field rather than falling back to the active
/// terminal cursor.
pub fn agentSessionDockSearchCaretRect(self: *const AppSession) ?chrome.draw.Rect {
    if (!self.agentSessionSearchOwnsInput()) return null;
    const cw = self.cell_width_px;
    if (cw == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    const entry = for (self.agent_session_dock_entries.items) |candidate| {
        if (candidate.id == chrome.components.session_dock.build.NodeIds.search) break candidate;
    } else return null;
    const button = chrome.components.session_dock.types.ButtonMetrics.resolve(agentSessionDockScaleMilli(self));
    const left = entry.rect.x + @as(f32, @floatFromInt(button.content_inset_x_px + button.leading_icon_extent_px + button.leading_icon_gap_px));
    const right = entry.rect.x + entry.rect.width - @as(f32, @floatFromInt(button.content_inset_x_px));
    if (right <= left) return null;
    const query_cols = chrome.components.overlay_input.displayCols(self.agent_session_archive_search.query.items);
    // Marked text is painted immediately after committed query. The native candidate window
    // must follow that same visible end, otherwise a Korean composition is anchored before
    // its own preedit syllable while waiting for commit.
    const preedit_cols = chrome.components.overlay_input.displayCols(self.agent_session_archive_search.preedit.items);
    const wanted_x = left + @as(f32, @floatFromInt(query_cols +| preedit_cols)) * @as(f32, @floatFromInt(cw));
    const x = @min(wanted_x, right - @as(f32, @floatFromInt(cw)));
    const line_h = chrome.ui.typography.lineHeightPx(.control, agentSessionDockScaleMilli(self));
    if (entry.rect.height < @as(f32, @floatFromInt(line_h))) return null;
    return .{
        .x = @as(i32, @intCast(content.x)) + @as(i32, @intFromFloat(@floor(x))),
        .y = @as(i32, @intCast(content.y)) + @as(i32, @intFromFloat(@floor(entry.rect.y + (entry.rect.height - @as(f32, @floatFromInt(line_h)) / 2)))),
        .w = cw,
        .h = line_h,
    };
}

/// Finds the one materialized projection entry whose source identity owns the inline
/// disclosure.  The record index is not stable across snapshots, so the lookup compares the
/// cloned `(provider, session id, device, inode)` identity rather than retaining an index.
pub fn agentSessionDockExpandedProjectionIndex(self: *const AppSession) ?usize {
    const detail = self.agent_session_inline_detail orelse return null;
    for (self.agent_session_archive_projection.entries.items, 0..) |entry, entry_index| {
        if (entry != .card) continue;
        const record_index = entry.card;
        if (record_index >= self.agent_session_archive_records.items.len) continue;
        if (inlineArchiveDetailMatchesRecord(&detail, &self.agent_session_archive_records.items[record_index]))
            return entry_index;
    }
    return null;
}

/// This is the sole translation from archive entries to fixed chrome pixel metrics. It is pure
/// and bounded (records are capped at 500), and therefore safe on the render/input path.
pub fn agentSessionDockScrollProjection(self: *const AppSession) chrome.ui.scroll_area.Projection {
    const items = agentSessionDockScrollItems(self);
    return chrome.ui.scroll_area.project(
        items,
        ArchiveScrollItems.heightPx,
        items.extent(agentSessionDockContentViewportHeightPx(self)),
        self.agent_session_archive_scroll.offset_y_px,
    );
}

pub fn agentSessionDockScrollItems(self: *const AppSession) ArchiveScrollItems {
    const m = chrome.components.session_dock.types.DockMetrics.resolve(agentSessionDockScaleMilli(self));
    return .{
        .entries = self.agent_session_archive_projection.entries.items,
        .group_h_px = m.group_h,
        .card_h_px = m.card_h,
        .gap_px = m.item_gap,
        .expanded_index = agentSessionDockExpandedProjectionIndex(self),
        .expanded_h_px = m.card_h + m.expanded_detail_h + m.expanded_actions_h,
    };
}

/// Captures only a card that crosses the old viewport top.  A group header or the inter-item
/// gap cannot stand in for a session identity: when either occupies that boundary the caller
/// deliberately falls back to the retained numeric offset rather than guessing a neighbour.
pub fn captureAgentSessionDockScrollAnchor(self: *const AppSession) ?ArchiveScrollAnchor {
    const projection = agentSessionDockScrollProjection(self);
    return archiveScrollAnchorFor(
        self.agent_session_archive_records.items,
        projection,
        agentSessionDockScrollItems(self),
    );
}

/// Resolves the old card identity only against a materialized replacement card.  It never
/// falls back to a title/path/mtime or a nearby record: an absent or collapsed identity keeps
/// the old numeric pixel offset, clamped to the new content bounds.
pub fn restoreAgentSessionDockScrollAnchor(self: *AppSession, anchor: ?ArchiveScrollAnchor, fallback_offset_px: u32) void {
    const projection = agentSessionDockScrollProjection(self);
    if (anchor) |saved| {
        if (archiveScrollAnchorOffsetFor(
            self.agent_session_archive_records.items,
            saved,
            agentSessionDockScrollItems(self),
            projection.max_offset_px,
        )) |offset| {
            _ = self.agent_session_archive_scroll.setOffsetPx(offset, projection.max_offset_px);
            return;
        }
    }
    _ = self.agent_session_archive_scroll.setOffsetPx(fallback_offset_px, projection.max_offset_px);
}

/// Session Dock가 키보드를 소유하는가 — 도크가 보이는 것만으로는 부족하고 사용자가 도크 안을 눌러
/// 키보드를 넘겨준 상태여야 한다(docs/agent-session-list.md §키보드: `agent_session_list` focus owner가
/// Enter/Page/Home/End를 갖는다). 스크롤 키·Enter·`/`가 **같은 게이트**를 써야 터미널에서 타이핑하는
/// 동안 도크가 그 키를 가져가지 않는다. 검색 필드가 활성이면 그쪽이 먼저다.
pub fn agentSessionDockOwnsKeys(self: *const AppSession) bool {
    return dock_ops.dockVisible(self) and self.dock.view == .agent_sessions and
        !self.agent_session_archive_search_active and
        self.agent_session_dock_key_focus;
}

/// 도크 안 primary down은 키보드를 도크로 넘긴다. 카드/그룹뿐 아니라 헤더·빈 여백도 포함한다 —
/// 사용자가 도크를 눌렀다는 사실이 소유권이고, 그 frame에 어떤 action rect가 있었는지가 아니다.
pub fn takeAgentSessionDockKeyFocus(self: *AppSession) void {
    if (self.agent_session_dock_key_focus) return;
    self.agent_session_dock_key_focus = true;
    self.metal_dirty = true;
}

/// 도크의 keyboard 소유권을 놓는다 — 선택 카드·펼친 detail·스크롤 위치는 그대로다. `focus_owner`는
/// 도크 카드를 눌러도 `.workspace`에 머무르므로, 터미널을 다시 클릭했을 때 조건부 `focusWorkspaceInput`
/// 하나로는 이 소유권이 남아 도크가 계속 키를 가져갔다. 도크 검색도 도크가 가진 키 소비자이므로
/// 여기서 함께 blur한다 — 그러지 않으면 `handleAgentSessionArchiveSearchKey`의 `else => return true`가
/// 터미널로 돌아온 뒤의 **모든** 키를 계속 삼킨다(Enter 하나가 아니라 타이핑 전체).
pub fn releaseAgentSessionDockKeyFocus(self: *AppSession) void {
    const had_focus = self.agent_session_dock_key_focus or self.agent_session_dock_interaction.focused != null;
    self.agent_session_dock_key_focus = false;
    self.agent_session_dock_interaction.focused = null;
    const blurred = blurAgentSessionDockSearch(self);
    if (had_focus or blurred) self.metal_dirty = true;
}

/// 도크 검색바를 blur한다(포커스 아웃 — 도크 밖 클릭·view 전환·접기). 사이드바 검색의 `blurSidebarSearch`와
/// 같은 규율이다: **비활성만 하고 검색어는 보존**해 다시 검색바를 누르면 이어서 편집·필터한다. 조합 중이던
/// IME preedit는 잃지 않도록 확정한다(`commitPreedit`의 "포커스 상실" 계약). 완전히 비우려면 Esc다.
pub fn blurAgentSessionDockSearch(self: *AppSession) bool {
    if (!self.agent_session_archive_search_active) return false;
    self.agent_session_archive_search_active = false;
    if (self.agent_session_archive_search.commitPreedit(self.allocator)) {
        rebuildAgentSessionArchiveFilter(self);
        resetAgentSessionDockScroll(self);
    }
    return true;
}

/// Session Dock owns these navigation keys whenever its search field does not.  Returning
/// true at a boundary is intentional: a key aimed at the visible dock must not leak into the
/// focused terminal just because no further pixel motion is possible.
pub fn handleAgentSessionDockScrollKey(self: *AppSession, event: terminal.KeyEvent) bool {
    if (!agentSessionDockOwnsKeys(self) or
        event.modifiers.command or event.modifiers.control or event.modifiers.option or event.modifiers.shift)
        return false;
    const projection = agentSessionDockScrollProjection(self);
    // 카드 높이만 있으면 되므로 항목 열을 빌린 채로 두지 않는다(`ArchiveScrollItems.entries` 수명).
    const card_h_px = agentSessionDockScrollItems(self).card_h_px;
    const changed = switch (event.key) {
        .page_up => self.agent_session_archive_scroll.scrollByPx(
            -@as(i64, chrome.ui.scroll_area.pageStepPx(agentSessionDockContentViewportHeightPx(self), card_h_px)),
            projection.max_offset_px,
        ),
        .page_down => self.agent_session_archive_scroll.scrollByPx(
            @as(i64, chrome.ui.scroll_area.pageStepPx(agentSessionDockContentViewportHeightPx(self), card_h_px)),
            projection.max_offset_px,
        ),
        .home => self.agent_session_archive_scroll.setOffsetPx(0, projection.max_offset_px),
        .end => self.agent_session_archive_scroll.setOffsetPx(projection.max_offset_px, projection.max_offset_px),
        else => return false,
    };
    self.agent_session_archive_scroll.dropWheelResidue();
    if (changed) self.metal_dirty = true;
    return true;
}

pub fn resetAgentSessionDockScroll(self: *AppSession) void {
    self.agent_session_archive_scroll.reset();
    self.agent_session_archive_scroll.dropWheelResidue();
}

pub fn rebuildAgentSessionArchiveFilter(self: *AppSession) void {
    self.agent_session_archive_filtered_indices.clearRetainingCapacity();
    for (self.agent_session_archive_records.items, 0..) |record, index| {
        const scope_matches = switch (self.agent_session_archive_scope) {
            .all => true,
            .workspace => if (self.agent_session_archive_workspace_root) |root|
                agentSessionArchiveWithinRoot(record, root)
            else
                false,
            .project => if (self.agent_session_archive_project_root) |root|
                agentSessionArchiveWithinRoot(record, root)
            else
                false,
        };
        if (scope_matches and agentSessionArchiveMatches(record, self.agent_session_archive_search.query.items))
            self.agent_session_archive_filtered_indices.append(self.allocator, index) catch break;
    }
    // records는 worker가 마지막 활동 시각 내림차순으로 발행한다. 오래된순은 그 목록을 **뒤집기만**
    // 하면 된다 — 여기서 다시 정렬하면 정렬 키가 두 곳에 생겨 서로 어긋날 수 있다. 그룹은 이 순서를
    // 따라 projection이 다시 만들므로 그룹 순서와 그룹 안 순서가 함께 뒤집힌다.
    if (self.agent_session_archive_sort == .oldest_first)
        std.mem.reverse(usize, self.agent_session_archive_filtered_indices.items);
    rebuildAgentSessionArchiveProjection(self);
}

pub fn rebuildAgentSessionArchiveProjection(self: *AppSession) void {
    var items: std.ArrayList(agent_session_archive_view.Item) = .empty;
    defer items.deinit(self.allocator);
    items.ensureTotalCapacity(self.allocator, self.agent_session_archive_filtered_indices.items.len) catch return;
    for (self.agent_session_archive_filtered_indices.items) |record_index| {
        if (record_index >= self.agent_session_archive_records.items.len) continue;
        const parsed = &self.agent_session_archive_records.items[record_index].parsed;
        items.appendAssumeCapacity(.{
            .record_index = record_index,
            .cwd = parsed.cwd,
            .cwd_canonical = parsed.cwd_canonical,
        });
    }
    const collapsed: []const []const u8 = self.agent_session_archive_collapsed_groups.items;
    const staged = agent_session_archive_view.build(self.allocator, items.items, collapsed) catch return;
    self.agent_session_archive_projection.deinit(self.allocator);
    self.agent_session_archive_projection = staged;
    self.agent_session_dock_snapshot_generation +%= 1;
    if (self.agent_session_dock_snapshot_generation == 0) self.agent_session_dock_snapshot_generation = 1;
}

/// 정렬 방향을 뒤집는다. 목록 순서가 통째로 바뀌므로 scroll anchor를 복원하지 않고 맨 위로 보낸다 —
/// 뒤집힌 목록의 "같은 자리"는 사용자가 보던 자리가 아니다. 열린 카드는 identity로 유지된다.
pub fn toggleAgentSessionArchiveSort(self: *AppSession) void {
    self.agent_session_archive_sort = self.agent_session_archive_sort.toggled();
    rebuildAgentSessionArchiveFilter(self);
    self.agent_session_archive_scroll.offset_y_px = 0;
    self.agent_session_archive_scroll.clamp(agentSessionDockScrollProjection(self).max_offset_px);
    self.agent_session_archive_scroll.dropWheelResidue();
    self.metal_dirty = true;
}

pub fn toggleAgentSessionArchiveGroup(self: *AppSession, group_index: usize) void {
    if (group_index >= self.agent_session_archive_projection.groups.items.len) return;
    const key = self.agent_session_archive_projection.groups.items[group_index].key;
    var existing: ?usize = null;
    for (self.agent_session_archive_collapsed_groups.items, 0..) |collapsed, index| {
        if (std.mem.eql(u8, collapsed, key)) {
            existing = index;
            break;
        }
    }
    if (existing) |index| {
        const removed = self.agent_session_archive_collapsed_groups.orderedRemove(index);
        self.allocator.free(removed);
    } else {
        const owned = self.allocator.dupe(u8, key) catch return;
        self.agent_session_archive_collapsed_groups.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
    }
    // A group change may remove the disclosure from the materialized projection. It must
    // not leave a hidden ready action capability alive.
    closeAgentSessionInlineDetail(self);
    rebuildAgentSessionArchiveProjection(self);
    self.agent_session_archive_scroll.clamp(agentSessionDockScrollProjection(self).max_offset_px);
    self.agent_session_archive_scroll.dropWheelResidue();
    self.metal_dirty = true;
}

pub fn handleAgentSessionArchiveSearchKey(self: *AppSession, event: terminal.KeyEvent) bool {
    if (!self.agent_session_archive_search_active) return false;
    switch (event.key) {
        .escape => {
            self.agent_session_archive_search_active = false;
            self.agent_session_archive_search.clear();
        },
        .backspace => {
            self.agent_session_archive_search.backspace();
        },
        .char => |codepoint| {
            if (event.modifiers.command or event.modifiers.control or event.modifiers.option) return true;
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8) catch return true;
            if (self.agent_session_archive_search.query.items.len + len <= 256)
                self.agent_session_archive_search.appendChar(self.allocator, codepoint) catch {};
        },
        else => return true,
    }
    rebuildAgentSessionArchiveFilter(self);
    resetAgentSessionDockScroll(self);
    // A query may hide the selected record; do not leave a hidden archive
    // identity selected for the later explicit action/tab path.
    self.agent_session_archive_selected = null;
    closeAgentSessionInlineDetail(self);
    self.metal_dirty = true;
    return true;
}

/// 도크의 비례 텍스트를 **이번 프레임 안에서** 셰이핑해 캐시에 넣는다.
///
/// 예전에는 이 일을 detached worker에 맡기고 결과를 다음 tick에 받았다. 그런데 도크의 모든 텍스트와
/// 등록 SVG 아이콘이 이 아티팩트 **하나**에 실리므로(`shapesTextOp`가 `!wide_icons` 전부를 담는다),
/// 결과가 없는 프레임의 도크는 카드 배경만 남은 빈 상자가 됐다. 게다가 in-flight가 1개라 스크롤처럼
/// 매 프레임 내용이 바뀌는 동안에는 도착한 결과가 계속 fingerprint 불일치로 버려져, 한 프레임 깜빡임이
/// 아니라 스크롤하는 내내 빈 상태가 유지됐다(사용자 보고).
///
/// 나머지 chrome은 이미 이렇게 하고 있다 — 사이드바·탭바·터미널 본문은 `CoreTextFrameBuilder.shapeOnly`로
/// 같은 tick에 CoreText를 부르며, 터미널은 셀마다 `CTLine`을 하나씩 만든다. 도크 한 프레임은 그에 비하면
/// run 수십 개다(측정: 55 run·969 glyph에 1.4ms, ReleaseFast). 그러므로 캐시는 빈 프레임을 정당화하는
/// 장치가 아니라 **순수 최적화**이며, miss는 지금 셰이핑해서 메운다.
///
/// 실패하면 캐시를 건드리지 않는다. 옛 fingerprint가 남아 hit되지 않으므로 호출자가 아이콘 없는
/// 프레임을 그리게 되지만, 잘못된 기하의 아티팩트를 재사용하는 것보다 낫다.
pub fn shapeAgentSessionDockRichText(
    self: *AppSession,
    ops: []const chrome.draw.Op,
    tokens: *const chrome.Tokens,
    fingerprint: u64,
    dock_scale_milli: u32,
    scroll_origin_y_px: i32,
) void {
    // face는 터미널과 같은 resolved appearance에서 온다 — 같은 화면의 사이드바가 사용자 monospace인데
    // 도크만 시스템 UI face면 앱이 폰트 설정을 절반만 따르는 셈이다(docs/font-strategy.md "Chrome 텍스트
    // face"). 크기 위계(role 토큰)는 여전히 `font.size`와 독립이라 도크 기하는 이 값에 흔들리지 않는다.
    var request = chrome_system_text.prepareRequest(self.allocator, fingerprint, ops, tokens, self.cell_width_px, .{
        .family = self.appearance.font.family,
        .fallback = self.appearance.font.fallback,
    }) catch return;
    defer request.deinit(self.allocator);
    var unresolved = chrome_system_text.shapeRequest(self.allocator, &request, dock_scale_milli) catch return;
    defer unresolved.deinit(self.allocator);
    const artifact = chrome_system_text.resolveArtifact(self.allocator, &self.renderer_state.font_registry, unresolved) catch return;
    // 셰이핑이 이 프레임 안에서 끝나므로 기준 원점은 지금 그리는 그 값이다. worker 시절에는 submit
    // 시점과 poll 시점의 스크롤이 달라 이 기준이 어긋날 수 있었지만 이제 그 간극이 없다.
    // 옛 아티팩트 해제는 `store`가 소유한다 — 예전에는 여기서 **모든** 슬롯을 비우고(clear) 자기 것만
    // 다시 채웠는데, 소비처가 늘면 그 방식이 남의 캐시를 매 셰이핑마다 버리게 된다.
    MeasuredTextCache.store(&self.agent_session_dock_rich_text_cache, self.allocator, fingerprint, artifact, scroll_origin_y_px);
}

/// Cmd font-size zoom의 비율만 Session Dock의 native Chrome UI zoom으로 쓴다. Terminal font
/// family/line spacing/cell metrics은 intentionally excluded: one bounded value must be shared by
/// layout, text worker, paint, hit testing, and scroll projection so a stale scale cannot split
/// what is visible from what is clickable.
pub fn agentSessionDockUiZoomMilli(self: *const AppSession) u32 {
    const base = self.base_font_size;
    const current = self.appearance.font.size;
    if (!(base > 0) or !(current > 0)) return 1000;
    const ratio = current / base;
    if (!std.math.isFinite(ratio)) return 1000;
    const milli: f32 = std.math.clamp(
        @round(ratio * 1000.0),
        @as(f32, @floatFromInt(session_dock_ui_zoom_min_milli)),
        @as(f32, @floatFromInt(session_dock_ui_zoom_max_milli)),
    );
    return @intFromFloat(milli);
}

/// Device backing scale and the user-visible bounded Dock zoom compose once. `0` remains the
/// pre-render fallback used by DockMetrics, while multiplication stays saturating for malformed
/// test/config input instead of wrapping a published Chrome tree to a tiny size.
pub fn agentSessionDockScaleMilli(self: *const AppSession) u32 {
    const backing = if (self.scale_milli == 0) @as(u32, 1000) else self.scale_milli;
    const product = @as(u64, backing) * @as(u64, agentSessionDockUiZoomMilli(self));
    return @intCast(@min((product + 500) / 1000, @as(u64, std.math.maxInt(u32))));
}

/// AS3-a 제품 경계: archive의 immutable projection을 SessionDock component props로만
/// 투영하고, component가 만든 같은 rect tree를 semantic paint/CoreText/Metal에 함께
/// 전달한다. 이 함수는 scanner·provider를 호출하지 않으며 매 frame에는 이미 publish된
/// snapshot만 읽는다. 따라서 느린 JSONL 분석이 메인 render tick을 막지 않는다.
/// 도크 컴포넌트에 넘길 props를 만드는 **유일한** 자리다. 렌더 경로 안에 리터럴로 두면 테스트가
/// 그 구성을 복제하게 되고, 복제본은 host를 판정하지 못한다 — 실제로 가상화 원점을 0으로 바꾸는
/// 변이가 복제 기반 테스트를 통과했다.
pub fn agentSessionDockScrollbarMinThumbPx(self: *const AppSession) u32 {
    return chrome.components.session_dock.types.DockMetrics.resolve(agentSessionDockScaleMilli(self)).scrollbar_min_thumb;
}

/// 그룹 하나를 component DTO로 옮기는 **유일한** 자리다. 흐름 위의 행과 상단 고정 헤더가 같은
/// 값을 봐야 한다 — 라벨이나 개수가 갈리면 스크롤 도중 같은 그룹이 두 물건으로 보인다.
pub fn agentSessionDockGroupItem(self: *const AppSession, group_index: usize) ?chrome.components.session_dock.types.Group {
    if (group_index >= self.agent_session_archive_projection.groups.items.len) return null;
    const group = self.agent_session_archive_projection.groups.items[group_index];
    return .{
        .identity = @intCast(group_index),
        .label = group.label,
        .count = @intCast(@min(group.count, std.math.maxInt(u16))),
        .collapsed = group.collapsed,
    };
}

/// 상단에 걸린 그룹. **가상화 창 밖일 수 있으므로** component가 아니라 여기서 구한다.
pub fn agentSessionDockStickyGroup(self: *const AppSession, offset_px: u32) ?chrome.components.session_dock.types.StickyGroup {
    const head = archiveStickyGroupFor(agentSessionDockScrollItems(self), offset_px) orelse return null;
    const entry = self.agent_session_archive_projection.entries.items[head.index];
    const group = agentSessionDockGroupItem(self, switch (entry) {
        .group => |group_index| group_index,
        .card => return null,
    }) orelse return null;
    return .{ .group = group, .top_px = head.top_px, .next_top_px = head.next_top_px };
}

pub fn agentSessionDockProps(
    self: *const AppSession,
    content: @FieldType(dock_layout.Geometry, "tree_content"),
    scroll_projection: chrome.ui.scroll_area.Projection,
    items: []const chrome.components.session_dock.types.Item,
) chrome.components.session_dock.types.Props {
    const dock_scale_milli = agentSessionDockScaleMilli(self);
    return .{
        .viewport_px = .{ .width = @floatFromInt(content.w), .height = @floatFromInt(content.h) },
        .cell_width_px = self.cell_width_px,
        .cell_height_px = self.cell_height_px,
        .scale_milli = dock_scale_milli,
        // Archive records are atomically swapped by the worker. Its scan generation is
        // not exposed here yet, so the projection generation is the stable, main-thread
        // action guard for this first host slice.
        .snapshot_generation = self.agent_session_dock_snapshot_generation,
        .displayed_count = @intCast(@min(self.agent_session_archive_filtered_indices.items.len, std.math.maxInt(u16))),
        .scope = switch (self.agent_session_archive_scope) {
            .workspace => .workspace,
            .project => .project,
            .all => .all,
        },
        .sort_order = self.agent_session_archive_sort,
        .workspace_scope_enabled = self.agent_session_archive_workspace_root != null,
        .project_scope_enabled = self.agent_session_archive_project_root != null,
        .search = self.agent_session_archive_search.query.items,
        .search_preedit = self.agent_session_archive_search.preedit.items,
        .search_focused = self.agent_session_archive_search_active,
        .search_cursor_visible = self.blink_visible,
        // The rich system-text worker follows the same truthful loading rule as archive
        // refresh: existing cards remain visible while its immutable artifact is pending.
        .partial = self.agent_session_archive_partial,
        .loading = self.agent_session_archive_loading and self.agent_session_archive_records.items.len == 0,
        .refreshing = self.agent_session_archive_loading and self.agent_session_archive_records.items.len > 0,
        .spinner_phase = @intCast(self.agent_spin_frame & 7),
        .content_first_item_origin_y_px = scroll_projection.first_origin_y_px,
        // 가상화 때문에 component는 보이는 아이템만 받는다. scrollbar가 "얼마나 긴 목록의 어디"인지
        // 알 수 있는 유일한 입력이 이 두 값이다.
        .scroll_content_height_px = scroll_projection.content_height_px,
        // fade 는 host 가 계산하고 **view 가 paint 시점에** 얹는다 — build(tree)는 이 값을 모른다(계약 §7).
        .scrollbar_alpha = scroll_ops.dockScrollAreaAlpha(self),
        .scroll_offset_px = scroll_projection.offset_y_px,
        .expanded_identity = if (self.agent_session_inline_detail != null and self.agent_session_archive_selected != null)
            @intCast(self.agent_session_archive_selected.?)
        else
            null,
        .items = items,
        .sticky_group = agentSessionDockStickyGroup(self, scroll_projection.offset_y_px),
    };
}

pub fn collectAgentSessionDock(
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
    const scroll_projection = agentSessionDockScrollProjection(self);
    const items = buildAgentSessionDockItems(self, arena, scroll_projection) catch return;
    const dock_scale_milli = agentSessionDockScaleMilli(self);
    const props = agentSessionDockProps(self, content, scroll_projection, items);
    var expansion_actions: usize = 0;
    var expansion_turns: usize = 0;
    for (items) |item| switch (item) {
        .group => {},
        .card => |card| if (card.expanded) |expanded| {
            expansion_actions += 2 + @as(usize, @intFromBool(expanded.focus_live_enabled));
            expansion_turns += expanded.turns.len;
        },
    };
    // 버퍼 크기는 **build가 소유한다**. 여기서 같은 산술을 다시 쓰면 둘이 갈리는 날 build가
    // `InsufficientNodeBuffer`로 실패하고, 아래 `catch return`이 그것을 삼켜 도크가 통째로 멈춘다.
    const sizes = chrome.components.session_dock.build.bufferSizes(items);
    const frame = chrome.components.session_dock.build.build(props, .{
        .nodes = arena.alloc(chrome.ui.tree.UiNode, sizes.nodes) catch return,
        .entries = arena.alloc(chrome.ui.tree.RectEntry, sizes.entries) catch return,
        .layout_items = arena.alloc(chrome.ui.layout.Item, sizes.layout_items) catch return,
        .flex_scratch = arena.alloc(chrome.ui.layout.FlexScratch, sizes.flex_scratch) catch return,
        .child_rects = arena.alloc(chrome.ui.layout.UiRect, sizes.child_rects) catch return,
        .actions = arena.alloc(chrome.components.session_dock.ids.Entry, sizes.actions) catch return,
    }) catch return;

    // Card quad + text op capacity: fixed header/scope/search cards plus either one item
    // quad and title/summary/provider/metadata/disclosure text runs per projection item, or nine inert initial-loading
    // skeleton stripes. Keep the placeholder budget explicit so the first scan cannot
    // silently drop its loading affordance through a fixed-capacity overflow.
    // B1-button-a emits the registered SVG icon and the measured action label as two
    // semantic ops. Reserve both before the view runs: dropping only the label on a full
    // fixed buffer would leave an enabled-looking icon with no command text.
    // generic paint의 quad는 published entry 하나당 최대 하나다. 이 몫을 상수로 세면 tree가
    // 자라는 변경마다 조용히 모자라는데, 그 결과가 "그 컴포넌트만 안 그려짐"이 아니라 **도크 전체
    // 정지**다 — `view`가 실패하면 아래 `publishAgentSessionDockFrame`까지 못 가서 hit tree가
    // 이전 프레임에 멈춘다(scrollbar를 추가하다 실제로 겪었다). 그래서 entry 수에서 유도한다.
    const paint_quad_budget = frame.tree.entries.len;
    // +1은 header의 정렬 토글 label이다.
    const text_op_budget = 22 + items.len * 6 + expansion_actions * 2 + expansion_turns * 2 + 4;
    const ops = arena.alloc(chrome.draw.Op, paint_quad_budget + text_op_budget) catch return;
    // 카드 하나가 쓰는 run 상한: title·summary·provider·chevron 넷에 **메타 줄의 세그먼트 넷과 그 사이
    // 구분자 셋**(개수·시각·모델·서브에이전트)이 더해져 11이다. 메타는 op 하나지만 run 은 여럿이라
    // (한 줄 안의 색 위계 — `chrome.draw.Run`), 이 몫을 op 예산과 같은 값으로 두면 카드가 몇 개만
    // 늘어도 `view` 가 `InsufficientRunBuffer` 로 실패한다. 그 결과는 "메타 줄만 빠짐"이 아니라
    // **도크 전체 정지**다(위 paint_quad_budget 주석과 같은 실패 양식). 여유 1을 더해 12로 잡는다.
    const runs = arena.alloc(chrome.draw.Run, 10 + items.len * 12 + expansion_actions * 2 + expansion_turns * 2 + 4) catch return;
    const text_bytes = arena.alloc(u8, 1024 + items.len * 1024 + expansion_turns * 1024) catch return;
    const tokens = self.buildChromeTokens();
    const draws = chrome.components.session_dock.view.view(props, frame, self.agent_session_dock_interaction, &tokens, .{
        .ops = ops,
        .runs = runs,
        .text_bytes = text_bytes,
    }) catch return;

    publishAgentSessionDockFrame(self, frame, props.snapshot_generation);

    // GPU card backgrounds must precede terminal/pane text; the adapter fixes this to
    // renderer layer 2 instead of the overlay layer used by modal components.
    chrome_draw_lowering.appendBackgroundQuads(self.allocator, &.{draws}, &tokens, content.x, content.y, &self.gpu_quads, 2);
    // One completed Dock tree becomes one DrawList and one CoreText shaping pass. The
    // component keeps every text origin local to `content`; the collected pane translates
    // the whole batch exactly once to backing coordinates.
    const cols: u16 = @intCast(@min(content.w / self.cell_width_px, std.math.maxInt(u16)));
    const rows: u16 = @intCast(@min(content.h / self.cell_height_px, std.math.maxInt(u16)));
    const icon_dl = chrome_draw_lowering.buildIconTextDrawList(
        self.allocator,
        draws.ops,
        &tokens,
        self.cell_width_px,
        self.cell_height_px,
        cols,
        rows,
    ) catch return;
    // 스크롤 목록의 현재 원점. 목록 전체가 이 값만큼 함께 움직이므로, 셰이핑 키는 이 값을 뺀
    // 상대 좌표로 만들고(스크롤 불변) 캐시를 재사용할 때 차이만 다시 더한다.
    const scroll_origin_y_px = props.content_first_item_origin_y_px;
    // 스크롤 뷰포트. published tree가 이미 갖고 있는 그 사각형을 backing 좌표로 옮겨 GPU 단계에
    // 넘긴다. 이게 있으면 component가 "이 줄이 clip 안에 통째로 들어가는가"를 미리 판정할 필요가
    // 없다 — 반쯤 걸친 카드/그룹도 픽셀 단위로 잘려 보인다.
    const scroll_clip: ?metal_frame.ClipPx = blk: {
        const rect = chrome.components.session_dock.build.scrollTextViewport(frame.tree) orelse break :blk null;
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
    // `richTextFingerprint` owns semantic component facts; scale changes the CoreText
    // point size even when integer cell metrics happen to round to the same value.
    const fingerprint = base_fingerprint ^ (@as(u64, dock_scale_milli) *% 0x9e3779b185ebca87);
    // 캐시는 순수 최적화다. hit이면 CoreText 호출을 건너뛰고, miss면 지금 셰이핑해 이번 프레임에
    // 그린다 — 다음 tick으로 미루면 그 프레임의 도크가 글자도 아이콘도 없는 빈 카드가 된다.
    const cache_hit = MeasuredTextCache.hit(self.agent_session_dock_rich_text_cache, fingerprint);
    if (!cache_hit) shapeAgentSessionDockRichText(self, draws.ops, &tokens, fingerprint, dock_scale_milli, scroll_origin_y_px);
    if (self.agent_session_dock_rich_text_cache) |*cache| {
        if (cache.fingerprint == fingerprint) {
            self.collectMeasuredTextFromCache(collected, chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return, cache, builder, scroll_clip, .{ .pane = .{
                .origin_x = content.x,
                .origin_y = content.y,
                .colors = colors,
                .scroll_delta_y_px = @floatFromInt(scroll_origin_y_px - cache.scroll_origin_y_px),
            } });
            self.collectShaped(collected, icon_dl, builder, .{ .pane = .{
                .origin_x = content.x,
                .origin_y = content.y,
                .colors = colors,
            } });
            return;
        }
    }
    // 셰이핑이 실패한 프레임만 여기 온다(폰트 없음·할당 실패 등). 텍스트 없이 배경만 그리는 대신
    // 아이콘 draw list라도 낸다 — 이 경로는 결함 상태이며 정상 흐름의 일부가 아니다.
    self.collectShaped(collected, icon_dl, builder, .{ .pane = .{
        .origin_x = content.x,
        .origin_y = content.y,
        .colors = colors,
    } });
}

/// The component receives only the cards that can appear in the current viewport. This is
/// a first virtualization consumer: hidden archive rows do not allocate CoreText frames or
/// Metal quads, while scroll remains a projection concern owned by the archive model.
pub fn buildAgentSessionDockItems(
    self: *const AppSession,
    allocator: std.mem.Allocator,
    scroll_projection: chrome.ui.scroll_area.Projection,
) ![]chrome.components.session_dock.types.Item {
    var out: std.ArrayList(chrome.components.session_dock.types.Item) = .empty;
    if (scroll_projection.first_index == scroll_projection.end_exclusive) return try out.toOwnedSlice(allocator);
    var entry_index = scroll_projection.first_index;
    const now_ns: i128 = std.Io.Clock.real.now(self.io).nanoseconds;
    while (entry_index < scroll_projection.end_exclusive) : (entry_index += 1) {
        const entry = self.agent_session_archive_projection.entries.items[entry_index];
        switch (entry) {
            .group => |group_index| {
                const group = agentSessionDockGroupItem(self, group_index) orelse continue;
                try out.append(allocator, .{ .group = group });
            },
            .card => |record_index| {
                if (record_index >= self.agent_session_archive_records.items.len) continue;
                const record = self.agent_session_archive_records.items[record_index];
                const parsed = record.parsed;
                var age_buf: [32]u8 = undefined;
                const age = formatAgentSessionArchiveRelativeAge(now_ns, agent_session_archive_backend.lastActivityNs(record), &age_buf);
                const model = if (parsed.model.len > 0) parsed.model else maru.i18n.t(.ad_no_model);
                // 서브에이전트를 돌린 세션만 그 개수를 덧붙인다. 0이면 아무것도 그리지 않아 평범한
                // 세션의 메타 줄이 길어지지 않는다(docs/agent-session-list.md §2.3). 상한 초과는
                // `999+`로 — 스캐너가 그 값에서 세기를 멈추므로 정확한 수를 주장하지 않는다.
                // 메타 줄은 **세그먼트로** 넘긴다 — 구분자와 색 위계는 컴포넌트가 소유한다
                // (`session_dock.types.CardMetadata`). 여기서 한 문장으로 뭉치면 개수·시각·모델이
                // 한 색으로 읽히고, 빈 세그먼트가 생길 때 구분자 손질을 문구가 떠안게 된다.
                var messages_buf: [64]u8 = undefined;
                const messages = try allocator.dupe(u8, maru.i18n.format(&messages_buf, maru.i18n.t(.ad_meta_messages), &.{
                    .{ .d = parsed.message_count },
                }));
                const subagents: []const u8 = if (record.subagent_count == 0) "" else blk: {
                    var sub_buf: [64]u8 = undefined;
                    const over = record.subagent_count >= agent_session_archive_backend.max_subagent_count;
                    const key = if (over) maru.i18n.t(.ad_meta_subagents_more) else maru.i18n.t(.ad_meta_subagents);
                    const count = if (over) agent_session_archive_backend.max_subagent_count else record.subagent_count;
                    break :blk try allocator.dupe(u8, maru.i18n.format(&sub_buf, key, &.{.{ .d = count }}));
                };
                const metadata: chrome.components.session_dock.types.CardMetadata = .{
                    .messages = messages,
                    .age = try allocator.dupe(u8, age),
                    .model = model,
                    .subagents = subagents,
                };
                var expanded: ?chrome.components.session_dock.types.Expanded = null;
                if (self.agent_session_inline_detail) |detail| if (inlineArchiveDetailMatchesRecord(&detail, &record)) {
                    const detail_state: chrome.components.session_dock.types.DetailState = switch (detail.state) {
                        .loading => .loading,
                        .ready => .ready,
                        .stale => .stale,
                        .unavailable => .unavailable,
                    };
                    var turns: []chrome.components.session_dock.types.Turn = &.{};
                    var action_record_count: u32 = 0;
                    if (detail.state == .ready) if (detail.detail) |parsed_detail| {
                        const count = @min(parsed_detail.turns.items.len, 3);
                        turns = try allocator.alloc(chrome.components.session_dock.types.Turn, count);
                        for (parsed_detail.turns.items[0..count], turns) |turn, *out_turn| out_turn.* = .{
                            .role = switch (turn.role) {
                                .user => .user,
                                .assistant => .assistant,
                            },
                            .text = turnText(turn),
                        };
                        action_record_count = parsed_detail.action_records;
                    };
                    expanded = .{
                        .state = detail_state,
                        .turns = turns,
                        .action_record_count = action_record_count,
                        .resume_enabled = detail.state == .ready,
                        .reveal_enabled = detail.state == .ready,
                        .focus_live_enabled = detail.state == .ready and archiveSessionHasLiveMapping(self, &detail),
                    };
                };
                try out.append(allocator, .{ .card = .{
                    .identity = @intCast(record_index),
                    .provider = switch (parsed.provider) {
                        .codex => .codex,
                        .claude => .claude,
                    },
                    .title = parsed.title,
                    .summary = parsed.summary,
                    .metadata = metadata,
                    .selected = self.agent_session_archive_selected != null and self.agent_session_archive_selected.? == record_index,
                    .expanded = expanded,
                } });
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Successful paint candidates alone replace the published input snapshot. Reconcile clears
/// a captured old action before the old backing entries are overwritten, so a delayed pointer
/// up can never open a session from the previous archive/scope/search result.
pub fn publishAgentSessionDockFrame(
    self: *AppSession,
    frame: chrome.components.session_dock.build.Frame,
    generation: u64,
) void {
    // A normal redraw rebuilds the same value tree from the same immutable archive snapshot.
    // Treating that as a replacement would cancel a just-pressed card before AppKit sends its
    // matching mouse-up. Only a geometry/action mapping change is a true replacement; that
    // path still reconciles below and deliberately cancels capture.
    if (agentSessionDockFrameEql(
        self.agent_session_dock_entries.items,
        self.agent_session_dock_actions.items,
        frame.tree.entries,
        frame.actions,
    )) return;
    // Reserve both backing stores before touching the old snapshot. An allocation failure
    // must leave the last fully painted hit tree intact rather than publishing entries with
    // no matching action table (or clearing a usable dock during refresh).
    self.agent_session_dock_entries.ensureTotalCapacity(self.allocator, frame.tree.entries.len) catch return;
    self.agent_session_dock_actions.ensureTotalCapacity(self.allocator, frame.actions.len) catch return;
    const old_tree = chrome.ui.tree.UiRectTree{ .entries = self.agent_session_dock_entries.items };
    if (self.agent_session_dock_entries.items.len > 0) {
        // 기본 `reconcile`은 언제나 capture를 취소한다. 그것이 click의 안전한 기본값이지만
        // **scrollbar drag에는 치명적**이다 — thumb을 끌면 thumb rect가 바뀌어 매 프레임 tree가
        // 새로 발행되므로, 기본 경로에서는 드래그가 첫 move에 죽는다(사용자 보고: "스크롤바를
        // 눌러도 드래그가 안 된다"). 그래서 scrollbar drag만 좁은 carry 문을 태운다. carry 조건은
        // 그 모듈이 소유한다: 같은 identity가 새 tree에 정확히 하나, 여전히 닿을 수 있고 enabled,
        // 그리고 host가 준 compatibility key가 같을 때만이다.
        const scroll_payload = chrome.components.session_dock.build.scroll_drag_payload;
        const dragging_scrollbar = if (self.agent_session_dock_interaction.capture) |capture|
            if (capture.drag) |declared| declared.payload == scroll_payload else false
        else
            false;
        if (dragging_scrollbar) {
            // archive snapshot이 드래그 도중 교체되면 목록 길이 자체가 달라지므로 이어갈 근거가
            // 없다. 그 판정을 generation 비교 하나로 위임한다.
            const previous = chrome.ui.interaction.GestureCompatibility{
                .kind = scroll_payload,
                .enabled = true,
                .owner_epoch = self.agent_session_dock_snapshot_generation,
                .domain_identity = 0,
            };
            const current = chrome.ui.interaction.GestureCompatibility{
                .kind = scroll_payload,
                .enabled = true,
                .owner_epoch = generation,
                .domain_identity = 0,
            };
            _ = chrome.ui.interaction.reconcileCarryingCapture(
                &self.agent_session_dock_interaction,
                frame.tree,
                previous,
                current,
            ) catch return;
            // carry하지 못했으면 capture는 이미 비워졌다. host 쪽 drag 상태도 함께 끝내야
            // 다음 down이 자기 grab 지점을 새로 잡는다.
            if (self.agent_session_dock_interaction.capture == null) endAgentSessionDockScrollDrag(self);
        } else {
            _ = chrome.ui.interaction.reconcile(&self.agent_session_dock_interaction, old_tree, frame.tree) catch return;
        }
    }
    self.agent_session_dock_entries.clearRetainingCapacity();
    self.agent_session_dock_actions.clearRetainingCapacity();
    self.agent_session_dock_entries.appendSliceAssumeCapacity(frame.tree.entries);
    self.agent_session_dock_actions.appendSliceAssumeCapacity(frame.actions);
    // The component action table itself carries this generation, and the click path resolves
    // against this exact published value.
    self.agent_session_dock_snapshot_generation = generation;
}

/// 상세 턴 하나가 화면에 낼 문자열.
///
/// 가려진 턴의 문구는 **여기서** 푼다 — 워커가 만들어 캐시하면 그 시점 언어에 얼어붙어, 사용자가 화면
/// 언어를 바꿔도 그 줄만 옛 언어로 남는다(계약 §5.2: 한 프레임 안에 두 언어가 섞이지 않는다). 이 코드는
/// UI 스레드에서 돈다.
///
/// 한 줄짜리를 함수로 빼 둔 이유는 **테스트가 붙을 자리를 만들기 위해서**다. 이 해석이 죽으면 가려진
/// 턴이 빈 줄로 보이는데, 크래시가 아니라 조용히 사라지는 종류라 다른 어떤 테스트도 말하지 않는다.
fn turnText(turn: maru.session.agent_session_archive_detail.Turn) []const u8 {
    return if (turn.redacted) maru.i18n.t(.arch_redacted) else turn.text;
}

/// Selection/source changes invalidate the actually painted action capability before the
/// next frame can rebuild it.  This is stronger than merely incrementing a generation: a
/// queued pointer-up cannot resolve a prior resume/reveal rectangle during the repaint gap.
pub fn invalidateAgentSessionDockFrame(self: *AppSession) void {
    self.agent_session_dock_entries.clearRetainingCapacity();
    self.agent_session_dock_actions.clearRetainingCapacity();
    self.agent_session_dock_interaction = .{};
    self.agent_session_dock_snapshot_generation +%= 1;
    if (self.agent_session_dock_snapshot_generation == 0) self.agent_session_dock_snapshot_generation = 1;
}

/// Value equality is the publication gate for this particular frame snapshot. `UiRectTree`
/// entries contain no borrowed archive text, and ids/action ids are scalar, so a structural
/// comparison detects both a layout change and a different visible archive projection without
/// relying on the broader scan generation alone.
pub fn agentSessionDockFrameEql(
    old_entries: []const chrome.ui.tree.RectEntry,
    old_actions: []const chrome.components.session_dock.ids.Entry,
    new_entries: []const chrome.ui.tree.RectEntry,
    new_actions: []const chrome.components.session_dock.ids.Entry,
) bool {
    if (old_entries.len != new_entries.len or old_actions.len != new_actions.len) return false;
    for (old_entries, new_entries) |old, new| {
        if (!std.meta.eql(old, new)) return false;
    }
    for (old_actions, new_actions) |old, new| {
        if (!std.meta.eql(old, new)) return false;
    }
    return true;
}

pub fn dispatchAgentSessionDockPointer(
    state: *chrome.ui.interaction.InteractionState,
    entries: []const chrome.ui.tree.RectEntry,
    actions: []const chrome.components.session_dock.ids.Entry,
    generation: u64,
    event: chrome.ui.interaction.UiPointerEvent,
) ?AgentSessionDockPointerDispatch {
    const dispatched = chrome.ui.interaction.dispatch(state, .{ .entries = entries }, event) catch return null;
    var visual_changed = false;
    for (dispatched.dirty.ids) |id| {
        if (id != null) {
            visual_changed = true;
            break;
        }
    }
    const action_id = dispatched.action orelse return .{ .intent = null, .visual_changed = visual_changed, .drag = dispatched.drag };
    var table = chrome.components.session_dock.ids.Table.init(@constCast(actions));
    table.count = actions.len;
    return .{ .intent = table.resolve(action_id, generation), .visual_changed = visual_changed, .drag = dispatched.drag };
}

/// Keyboard shortcuts are not a second action path.  They resolve the same published,
/// generation-bound SessionDock capability as pointer-up, so a closed/loading/stale card
/// cannot resume or reveal merely because a row remains selected.
pub fn agentSessionDockShortcutIntent(
    self: *const AppSession,
    wanted: chrome.components.session_dock.ids.Intent,
) ?chrome.components.session_dock.ids.Intent {
    const detail = self.agent_session_inline_detail orelse return null;
    if (detail.state != .ready) return null;
    var table = chrome.components.session_dock.ids.Table.init(@constCast(self.agent_session_dock_actions.items));
    table.count = self.agent_session_dock_actions.items.len;
    for (self.agent_session_dock_actions.items) |entry| {
        if (std.meta.activeTag(entry.intent) != std.meta.activeTag(wanted)) continue;
        return table.resolve(entry.action_id, self.agent_session_dock_snapshot_generation);
    }
    return null;
}

pub fn agentSessionDockSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{};
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_actions.items) |action| {
        switch (action.intent) {
            .select_card => {},
            else => continue,
        }
        if (action.snapshot_generation != self.agent_session_dock_snapshot_generation) continue;
        for (self.agent_session_dock_entries.items) |entry| {
            const ui_action = entry.action orelse continue;
            if (ui_action.id != action.action_id) continue;
            const visible = smokeProbeVisibleRect(entry) orelse continue;
            return .{
                .request_id = self.agent_session_dock_snapshot_generation,
                .generation = self.agent_session_dock_snapshot_generation,
                .x_px = @as(f32, @floatFromInt(content.x)) + visible.x,
                .y_px = @as(f32, @floatFromInt(content.y)) + visible.y,
                .width_px = visible.width,
                .height_px = visible.height,
                .present = true,
                .enabled = ui_action.enabled,
            };
        }
    }
    return .{};
}

/// The fixture may locate the refresh hit rect only after the normal component has painted
/// it. This observer neither requests a scan nor exposes the internal action id.
pub fn agentSessionDockRefreshSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{};
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_actions.items) |action| {
        switch (action.intent) {
            .refresh => {},
            else => continue,
        }
        if (action.snapshot_generation != self.agent_session_dock_snapshot_generation) continue;
        for (self.agent_session_dock_entries.items) |entry| {
            const ui_action = entry.action orelse continue;
            if (ui_action.id != action.action_id) continue;
            const visible = smokeProbeVisibleRect(entry) orelse continue;
            return .{
                .request_id = self.agent_session_dock_snapshot_generation,
                .generation = self.agent_session_dock_snapshot_generation,
                .x_px = @as(f32, @floatFromInt(content.x)) + visible.x,
                .y_px = @as(f32, @floatFromInt(content.y)) + visible.y,
                .width_px = visible.width,
                .height_px = visible.height,
                .present = true,
                .enabled = ui_action.enabled,
            };
        }
    }
    return .{};
}

/// Reads a fixed SessionDock node from the already-published tree. It deliberately returns
/// the border rect, not text/icon ink bounds: text placement belongs to the rich-text
/// artifact and a test observer must not reimplement layout in the platform host.
pub fn agentSessionDockNodeSmokeProbe(self: *const AppSession, node_id: chrome.ui.tree.UiId) AgentSessionArchiveSmokeProbe {
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{};
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_entries.items) |entry| {
        if (entry.id != node_id) continue;
        return .{
            .request_id = self.agent_session_dock_snapshot_generation,
            .generation = self.agent_session_dock_snapshot_generation,
            .x_px = @as(f32, @floatFromInt(content.x)) + entry.rect.x,
            .y_px = @as(f32, @floatFromInt(content.y)) + entry.rect.y,
            .width_px = entry.rect.width,
            .height_px = entry.rect.height,
            .present = true,
            .enabled = true,
        };
    }
    return .{};
}

/// The expanded item's outer rect is a stable disclosure border, unlike its clipped child
/// action leaves. The observer ties it to the exact open detail before returning it, so a
/// recycled projected row can never stand in for a different archive identity.
pub fn agentSessionDockExpandedCardSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    const detail = self.agent_session_inline_detail orelse return .{};
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{};
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_actions.items) |action| {
        const record_index: usize = switch (action.intent) {
            .select_card => |identity| if (identity <= std.math.maxInt(usize)) @intCast(identity) else continue,
            else => continue,
        };
        if (action.snapshot_generation != self.agent_session_dock_snapshot_generation or
            record_index >= self.agent_session_archive_records.items.len or
            !inlineArchiveDetailMatchesRecord(&detail, &self.agent_session_archive_records.items[record_index])) continue;
        for (self.agent_session_dock_entries.items) |entry| {
            const ui_action = entry.action orelse continue;
            if (ui_action.id != action.action_id) continue;
            const root_index = entry.parent_index orelse continue;
            if (root_index >= self.agent_session_dock_entries.items.len) continue;
            const root = self.agent_session_dock_entries.items[root_index];
            return .{
                .request_id = detail.request_id,
                .generation = self.agent_session_dock_snapshot_generation,
                .x_px = @as(f32, @floatFromInt(content.x)) + root.rect.x,
                .y_px = @as(f32, @floatFromInt(content.y)) + root.rect.y,
                .width_px = root.rect.width,
                .height_px = root.rect.height,
                .state = switch (detail.state) {
                    .loading => 1,
                    .ready => 2,
                    .stale => 3,
                    .unavailable => 4,
                },
                .present = true,
                .enabled = true,
            };
        }
    }
    return .{};
}

/// Returns the un-clipped outer rect of the one identity-bound expanded card only while it
/// crosses the content clip top. The normal capability probes intentionally return a clipped
/// hit rect, but that value is always pinned to the clip edge for a partial row and cannot
/// distinguish a preserved intra-card scroll position from a broken refresh restore.
///
/// This fixture observer is not an action lookup: `request_id` merely links the rect to the
/// already-open inline detail, and no provider/session/path/action data crosses the boundary.
pub fn agentSessionDockExpandedAnchorSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    const detail = self.agent_session_inline_detail orelse return .{};
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{};
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_actions.items) |action| {
        const record_index: usize = switch (action.intent) {
            .select_card => |identity| if (identity <= std.math.maxInt(usize)) @intCast(identity) else continue,
            else => continue,
        };
        if (action.snapshot_generation != self.agent_session_dock_snapshot_generation or
            record_index >= self.agent_session_archive_records.items.len or
            !inlineArchiveDetailMatchesRecord(&detail, &self.agent_session_archive_records.items[record_index])) continue;
        for (self.agent_session_dock_entries.items) |entry| {
            const ui_action = entry.action orelse continue;
            if (ui_action.id != action.action_id) continue;
            const root_index = entry.parent_index orelse continue;
            if (root_index >= self.agent_session_dock_entries.items.len) continue;
            const root = self.agent_session_dock_entries.items[root_index];
            const clip = root.effective_clip orelse continue;
            if (!(root.rect.y < clip.y and root.rect.y + root.rect.height > clip.y)) continue;
            return .{
                .request_id = detail.request_id,
                .generation = self.agent_session_dock_snapshot_generation,
                .x_px = @as(f32, @floatFromInt(content.x)) + root.rect.x,
                .y_px = @as(f32, @floatFromInt(content.y)) + root.rect.y,
                .width_px = root.rect.width,
                .height_px = root.rect.height,
                .state = switch (detail.state) {
                    .loading => 1,
                    .ready => 2,
                    .stale => 3,
                    .unavailable => 4,
                },
                .present = true,
                .enabled = true,
            };
        }
    }
    return .{};
}

/// Reads an action only from the same SessionDock tree that was painted for the inline
/// disclosure.  The closed AppKit fixture still calls the historical probe enum names, but
/// no archive Term/surface or second detail tree participates in the observation.
pub fn inlineDetailSmokeProbe(
    self: *const AppSession,
    wanted: chrome.components.session_dock.ids.Intent,
) AgentSessionArchiveSmokeProbe {
    const detail = self.agent_session_inline_detail orelse return .{};
    const state: u32 = switch (detail.state) {
        .loading => 1,
        .ready => 2,
        .stale => 3,
        .unavailable => 4,
    };
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self)) return .{ .request_id = detail.request_id, .state = state };
    const content = dock_ops.dockGeometry(self).tree_content;
    for (self.agent_session_dock_actions.items) |action| {
        if (std.meta.activeTag(action.intent) != std.meta.activeTag(wanted) or
            action.snapshot_generation != self.agent_session_dock_snapshot_generation) continue;
        for (self.agent_session_dock_entries.items) |entry| {
            const ui_action = entry.action orelse continue;
            if (ui_action.id != action.action_id) continue;
            const visible = smokeProbeVisibleRect(entry) orelse continue;
            return .{
                .request_id = detail.request_id,
                .generation = self.agent_session_dock_snapshot_generation,
                .x_px = @as(f32, @floatFromInt(content.x)) + visible.x,
                .y_px = @as(f32, @floatFromInt(content.y)) + visible.y,
                .width_px = visible.width,
                .height_px = visible.height,
                .state = state,
                .present = true,
                .enabled = ui_action.enabled,
            };
        }
    }
    return .{ .request_id = detail.request_id, .state = state };
}

/// The fixture enters the list through exactly the same view-switcher slot as a user click.
/// This is geometry-only: it neither changes `dock.view` nor starts a scan. The normal mouse
/// dispatcher remains the sole authority that turns the later physical click into `setDockView`.
pub fn agentSessionDockSwitcherSmokeProbe(self: *const AppSession) AgentSessionArchiveSmokeProbe {
    if (!dock_ops.dockVisible(self) or self.cell_width_px == 0) return .{};
    const bar = dock_ops.dockGeometry(self).view_bar;
    const slot = dock_view_bar.slotRect(
        .{ .x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h },
        self.cell_width_px,
        2,
    ) orelse return .{};
    if (slot.w == 0 or slot.h == 0) return .{};
    return .{
        .x_px = @floatFromInt(slot.x),
        .y_px = @floatFromInt(slot.y),
        .width_px = @floatFromInt(slot.w),
        .height_px = @floatFromInt(slot.h),
        .present = true,
        .enabled = true,
    };
}

/// Pointer의 backing-px를 component-local px로 한 번만 변환해 같은 completed
/// SessionDock tree에 lifecycle event를 보낸다. 예전 archive 행 번호 계산을 병행하지
/// 않으므로 카드가 둥근 여백/가변 높이로 바뀌어도 "보이는 곳 = 눌리는 곳"이 유지된다.
pub fn agentSessionDockPointer(
    self: *AppSession,
    phase: chrome.ui.interaction.UiPointerPhase,
    x_px: f64,
    y_px: f64,
) ?chrome.components.session_dock.ids.Intent {
    if (self.dock.view != .agent_sessions or !dock_ops.dockVisible(self) or self.cell_width_px == 0 or self.cell_height_px == 0) return null;
    const content = dock_ops.dockGeometry(self).tree_content;
    if (self.agent_session_dock_entries.items.len == 0) return null;
    const local_x = x_px - @as(f64, @floatFromInt(content.x));
    const local_y = y_px - @as(f64, @floatFromInt(content.y));
    // scrollbar를 잡는 순간은 down이다(up의 action이 아니다). 눌린 지점이 thumb인지 track인지에 따라
    // grab 지점이 달라지고, track이면 그 자리로 먼저 점프한 뒤 이어서 끌 수 있어야 한다.
    if (phase == .down) beginAgentSessionDockScrollDrag(self, local_x, local_y);
    const dispatched = dispatchAgentSessionDockPointer(
        &self.agent_session_dock_interaction,
        self.agent_session_dock_entries.items,
        self.agent_session_dock_actions.items,
        self.agent_session_dock_snapshot_generation,
        .{
            .phase = phase,
            .x_px = local_x,
            .y_px = local_y,
            .timestamp_ns = 0,
        },
    ) orelse return null;
    if (dispatched.visual_changed) self.metal_dirty = true;
    if (dispatched.drag) |event| absorbAgentSessionDockScrollDrag(self, event);
    return dispatched.intent;
}

/// published tree가 발행한 track/thumb rect에서 현재 scrollbar 기하를 되읽는다. 여기서 다시 계산하면
/// 보이는 것과 다른 두 번째 출처가 생긴다 — 그 갈라짐이 정확히 "보이는 곳과 눌리는 곳이 다른" 결함이다.
pub fn agentSessionDockScrollbarGeometry(self: *const AppSession) ?chrome.ui.scroll_area.ScrollbarGeometry {
    const build_ids = chrome.components.session_dock.build.NodeIds;
    var track: ?chrome.ui.layout.UiRect = null;
    var thumb: ?chrome.ui.layout.UiRect = null;
    for (self.agent_session_dock_entries.items) |entry| {
        if (entry.id == build_ids.scroll_track) track = entry.rect;
        if (entry.id == build_ids.scroll_thumb) thumb = entry.rect;
    }
    const t = track orelse return null;
    const h = thumb orelse return null;
    // 잡는 자리(hit)는 tree에 안 실린다 — entry에는 그린 rect만 담긴다. 거터 폭으로 역산해 채운다.
    const bar: chrome.ui.scroll_area.ScrollbarGeometry = .{
        .track_x = t.x,
        .track_y = t.y,
        .track_w = t.width,
        .track_h = t.height,
        .hit_x = t.x,
        .hit_w = t.width,
        .thumb_y = h.y,
        .thumb_h = h.height,
        .max_offset_px = agentSessionDockScrollProjection(self).max_offset_px,
    };
    return bar.withHitSpan(@floatFromInt(chrome.components.session_dock.types.DockMetrics.resolve(agentSessionDockScaleMilli(self)).scrollbarMetrics().gutterPx()));
}

/// down이 scrollbar 안이면 드래그를 연다. thumb이면 잡은 지점을 그대로 유지하고, track이면 그 지점으로
/// 먼저 점프한 뒤 thumb 중앙을 잡은 것으로 친다(그래야 눌렀다 끌기 시작할 때 위치가 튀지 않는다).
/// down이 스크롤바 위인지, 잡기인지 점프인지, 잡은 지점을 어떻게 기억하는지는 `scroll_area.Drag`가
/// 안다. host는 published 기하를 건네고 점프 결과만 적용한다 — 기하를 두 번째로 만들지 않는다.
pub fn beginAgentSessionDockScrollDrag(self: *AppSession, local_x: f64, local_y: f64) void {
    const bar = agentSessionDockScrollbarGeometry(self) orelse return;
    if (self.agent_session_dock_scroll_drag.begin(bar, local_x, local_y)) |jumped|
        setAgentSessionDockScrollOffset(self, jumped);
}

/// drag 이벤트에서 **좌표만** 흡수한다. payload 판정은 여기(host)가 한다 — `scroll_area`는
/// `interaction`을 import할 수 없다(그쪽이 `tree`를 쓰고 `tree`가 `scroll_area`를 쓴다).
pub fn absorbAgentSessionDockScrollDrag(self: *AppSession, event: chrome.ui.interaction.DragEvent) void {
    const payload = chrome.components.session_dock.build.scroll_drag_payload;
    switch (event) {
        .began, .moved => |update| {
            if (update.payload != payload) return;
            self.agent_session_dock_scroll_drag.absorb(update.x_px, update.y_px);
        },
        .dropped => |update| {
            if (update.payload != payload) return;
            // 마지막 좌표는 버리지 않는다 — 놓기 직전의 위치가 최종 스크롤이다.
            self.agent_session_dock_scroll_drag.absorb(update.x_px, update.y_px);
            applyAgentSessionDockScrollDrag(self);
            endAgentSessionDockScrollDrag(self);
        },
        .cancelled => |cancelled| {
            if (cancelled.payload != payload) return;
            endAgentSessionDockScrollDrag(self);
        },
    }
}

pub fn endAgentSessionDockScrollDrag(self: *AppSession) void {
    self.agent_session_dock_scroll_drag.end();
}

/// tick이 부르는 소비 지점. 좌표 → offset 변환은 `Drag`가 하고 host는 그 결과를 적용만 한다.
pub fn applyAgentSessionDockScrollDrag(self: *AppSession) void {
    const offset = self.agent_session_dock_scroll_drag.takeOffset() orelse return;
    setAgentSessionDockScrollOffset(self, offset);
}

pub fn setAgentSessionDockScrollOffset(self: *AppSession, offset_px: u32) void {
    const projection = agentSessionDockScrollProjection(self);
    if (!self.agent_session_archive_scroll.setOffsetPx(offset_px, projection.max_offset_px)) return;
    // 휠 잔여분은 스크롤 위치의 함수가 아니라 그 위치로 가는 도중의 상태다. 다른 경로가 위치를
    // 확정했으면 남은 잔여분은 의미가 없다(키보드 스크롤과 같은 규율).
    self.agent_session_archive_scroll.dropWheelResidue();
    self.metal_dirty = true;
}

pub fn applyAgentSessionDockIntent(self: *AppSession, intent: chrome.components.session_dock.ids.Intent) void {
    switch (intent) {
        .refresh => refreshAgentSessionArchive(self, true),
        .scope => |scope| selectAgentSessionArchiveScope(self, switch (scope) {
            .workspace => .workspace,
            .project => .project,
            .all => .all,
        }),
        .toggle_sort => toggleAgentSessionArchiveSort(self),
        .focus_search => {
            self.agent_session_archive_search_active = true;
            self.resetCursorBlink();
            self.metal_dirty = true;
        },
        .toggle_group => |identity| {
            if (identity <= std.math.maxInt(usize)) toggleAgentSessionArchiveGroup(self, @intCast(identity));
        },
        .select_card => |identity| {
            if (identity > std.math.maxInt(usize)) return;
            const record_index: usize = @intCast(identity);
            self.agent_session_archive_selected = record_index;
            if (record_index < self.agent_session_archive_records.items.len) {
                openAgentSessionInlineDetail(self, &self.agent_session_archive_records.items[record_index]) catch {
                    self.showNoticeKey(.ad_session_archive_open_failed);
                };
            }
            self.metal_dirty = true;
        },
        .resume_session => if (self.agent_session_inline_detail) |detail| if (detail.state == .ready) {
            agent_ops.resumeAgentSessionInNewTerm(self, &detail.record) catch self.showNoticeKey(.ad_session_resume_failed);
        },
        .reveal_log => if (self.agent_session_inline_detail) |*detail| if (detail.state == .ready) {
            revealAgentSessionArchiveLog(self, &detail.record) catch |err| {
                // Reveal performs a fresh no-follow identity check.  A source replaced after
                // the ready frame must immediately become stale in this same inline card;
                // keeping ready buttons after this rejection would make the UI lie.
                if (err == error.StaleArchiveSource) {
                    if (detail.detail) |*parsed| parsed.deinit(self.allocator);
                    detail.detail = null;
                    detail.state = .stale;
                    invalidateAgentSessionDockFrame(self);
                    if (archiveSmokeScenarioIs("reveal-recheck-pointer"))
                        self.agent_session_archive_smoke_stale_reveal_count +%= 1;
                }
                self.showNoticeKey(.ad_log_source_changed);
            };
        },
        .focus_live => if (self.agent_session_inline_detail) |detail| if (detail.state == .ready) {
            if (!focusLiveArchiveSession(self, &detail)) self.showNoticeKey(.ad_open_session_not_found);
        },
        // scrollbar는 up의 click이 아니라 down의 위치와 이어지는 drag가 결정한다. 목표 offset은
        // pointer 좌표의 함수라 intent에 실을 수 없으므로 pointer 경로가 이미 처리했다.
        .scroll_thumb, .scroll_track => {},
    }
}

pub fn archiveSessionHasLiveMapping(self: *const AppSession, detail: *const InlineArchiveDetail) bool {
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!term.rt.live_initialized or term.rt.terminated) continue;
        const provider_matches = switch (detail.record.parsed.provider) {
            .claude => term.agent_kind == .claude,
            .codex => term.agent_kind == .codex,
        };
        if (provider_matches and std.mem.eql(u8, term.agent_transcript.identity(), detail.record.parsed.session_id)) return true;
    };
    return false;
}

/// Identity comparison is deliberately repeated at activation time. A panel may have been
/// painted while a provider rotated its child session identity; focus is only authorized for
/// the exact provider/session pair visible in the current action table.
pub fn focusLiveArchiveSession(self: *AppSession, detail: *const InlineArchiveDetail) bool {
    for (self.tabs.items, 0..) |tab, tab_index| for (tab.panes.items) |pane| for (pane.terms.items, 0..) |term, term_index| {
        if (!term.rt.live_initialized or term.rt.terminated) continue;
        const provider_matches = switch (detail.record.parsed.provider) {
            .claude => term.agent_kind == .claude,
            .codex => term.agent_kind == .codex,
        };
        if (!provider_matches or !std.mem.eql(u8, term.agent_transcript.identity(), detail.record.parsed.session_id)) continue;
        _ = tab_ops.switchTab(self, tab_index);
        _ = pane_ops.focusPaneByPtr(self, pane);
        self.focusTerm(term_index);
        return true;
    };
    return false;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub const agent_session_archive_snapshot_ttl_ns: i128 = 15 * std.time.ns_per_s;

pub fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var index: usize = 0;
        while (index < needle.len and std.ascii.toLower(haystack[start + index]) == std.ascii.toLower(needle[index])) : (index += 1) {}
        if (index == needle.len) return true;
    }
    return false;
}

// Session Dock은 terminal line spacing·font size와 별도 Chrome typography(role별 고정 pt)를 유지한다.
// **face는 예외로 terminal `font.family`를 따른다** — 사이드바와 한 화면에 보이므로 face까지 독립이면
// 사용자 폰트 설정을 앱이 절반만 따르게 된다(docs/font-strategy.md "Chrome 텍스트 face"). 크기 위계가
// 독립이라 face를 바꿔도 도크 기하는 불변이다. 다만 사용자가
// Cmd+/−/0으로 요청한 font-size zoom은 Dock 전체의 명시적 UI zoom으로 반영한다. 범위는 좁은 dock에서
// 48pt action target과 최소 읽기 밀도를 보존하도록 [75%, 150%]로 제한한다.
pub const session_dock_ui_zoom_min_milli: u32 = 750;

pub const session_dock_ui_zoom_max_milli: u32 = 1500;

// 가려진 턴의 문구가 **화면 언어를 따라가는지** 본다.
//
// 워커는 플래그만 세우고 문장은 안 만든다(계약 §5.2 — 번역 문자열의 수명은 프레임을 넘기지 않는다).
// 그 해석이 죽으면 가려진 턴이 **빈 줄**로 보이고 가려졌다는 표시가 사라진다 — 크래시가 아니라 조용히
// 사라지는 종류라, 이 테스트가 없으면 되돌려도 아무도 말하지 않는다(실제로 그랬다).
test "가려진 턴의 문구는 그리는 시점의 언어로 풀린다" {
    const lang_before = maru.i18n.lang();
    defer maru.i18n.setLang(lang_before);

    const redacted: maru.session.agent_session_archive_detail.Turn = .{ .role = .user, .text = &.{}, .redacted = true };
    const plain: maru.session.agent_session_archive_detail.Turn = .{ .role = .assistant, .text = @constCast("본문 그대로") };

    maru.i18n.setLang(.ko);
    try std.testing.expectEqualStrings(maru.i18n.tIn(.ko, .arch_redacted), turnText(redacted));
    maru.i18n.setLang(.en);
    try std.testing.expectEqualStrings(maru.i18n.tIn(.en, .arch_redacted), turnText(redacted));

    // 두 언어가 실제로 다른 문장이어야 위 둘이 무언가를 지킨다 — 같으면 해석이 죽어도 통과한다.
    try std.testing.expect(!std.mem.eql(u8, maru.i18n.tIn(.ko, .arch_redacted), maru.i18n.tIn(.en, .arch_redacted)));

    // 가리지 않은 턴은 원문 그대로다 — 모든 턴을 가림 문구로 바꿔도 위 단언은 통과하기 때문이다.
    try std.testing.expectEqualStrings("본문 그대로", turnText(plain));
}

test "fade alpha 가 바뀌어도 발행 tree 는 불변이다(계약 §7 — 동등 비교가 살아 있어야 한다)" {
    const component = chrome.components.session_dock;
    // 기존 「publishes no scrollbar when the list fits」와 **같은 모양**으로 두고 content 만 넘치게 한다 —
    // 카드를 많이 넣으면 레이아웃 조건이 달라져 스크롤바 발행 자체가 갈린다(첫 판에서 그렇게 잡혔다).
    const items = [_]component.types.Item{
        .{ .card = .{ .identity = 1, .provider = .claude, .title = "a", .summary = "b", .metadata = .{ .messages = "c" } } },
    };
    var base = component.types.Props{
        .viewport_px = .{ .width = 640, .height = 480 },
        .cell_width_px = 8,
        .cell_height_px = 16,
        .snapshot_generation = 5,
        .displayed_count = 1,
        .items = &items,
        .scroll_content_height_px = 4000,
        .scrollbar_alpha = 0xFF,
    };
    var nodes: [512]chrome.ui.tree.UiNode = undefined;
    var entries: [512]chrome.ui.tree.RectEntry = undefined;
    var layout_items: [512]chrome.ui.layout.Item = undefined;
    var flex_scratch: [512]chrome.ui.layout.FlexScratch = undefined;
    var child_rects: [512]chrome.ui.layout.UiRect = undefined;
    var actions: [512]component.ids.Entry = undefined;
    const buffers = component.build.Buffers{
        .nodes = &nodes,
        .entries = &entries,
        .layout_items = &layout_items,
        .flex_scratch = &flex_scratch,
        .child_rects = &child_rects,
        .actions = &actions,
    };

    const full = try component.build.build(base, buffers);
    // entry·action 은 다음 build 가 같은 버퍼를 덮어쓰므로 값으로 떠 둔다.
    var full_entries: [512]chrome.ui.tree.RectEntry = undefined;
    var full_actions: [512]component.ids.Entry = undefined;
    @memcpy(full_entries[0..full.tree.entries.len], full.tree.entries);
    @memcpy(full_actions[0..full.actions.len], full.actions);
    const full_len = full.tree.entries.len;
    const full_alen = full.actions.len;
    try std.testing.expect(full.tree.find(component.build.NodeIds.scroll_thumb) != null); // 스크롤바가 실제로 발행됐다

    // **alpha 만 다르게** 다시 만든다. fade 가 도는 매 프레임이 이 상황이다.
    base.scrollbar_alpha = 0x4D;
    const faint = try component.build.build(base, buffers);

    // ⚠️ 이것이 이 테스트의 본체다 — alpha 를 tree 에 실으면 여기서 false 가 되고,
    // `publishAgentSessionDockFrame` 의 early return 이 fade 내내 무산된다(그 함수에 드래그 carry
    // 판정이 붙어 있어 계약이 「좁아지면 정확성 문제」라고 경고한 자리다).
    try std.testing.expect(agentSessionDockFrameEql(
        full_entries[0..full_len],
        full_actions[0..full_alen],
        faint.tree.entries,
        faint.actions,
    ));

    // **그리고 alpha 는 실제로 draw 에 반영돼야 한다**(적대적 검증 1회차 — tree 불변만 재면 「아무 데도
    // 안 얹히는」 판도 통과한다). view 를 태워 스크롤바 quad 의 alpha 를 직접 본다.
    var ops: [512]chrome.draw.Op = undefined;
    var runs: [64]chrome.draw.Run = undefined;
    var text_bytes: [4096]u8 = undefined;
    // Tokens 는 팔레트가 필요하고 `Rgb` 가 비공개라 손으로 못 만든다 — 제품이 쓰는 자리를 그대로 빌린다.
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
    const tk = session.buildChromeTokens();
    const drawn = try component.view.view(base, faint, .{}, &tk, .{
        .ops = &ops,
        .runs = &runs,
        .text_bytes = &text_bytes,
    });
    const thumb_rect = faint.tree.entries[faint.tree.find(component.build.NodeIds.scroll_thumb).?].rect;
    var saw_faint = false;
    for (drawn.ops) |op| switch (op) {
        .quad => |q| {
            const qx: f32 = @floatFromInt(q.rect.x);
            const qy: f32 = @floatFromInt(q.rect.y);
            if (@abs(qx - thumb_rect.x) < 1.5 and @abs(qy - thumb_rect.y) < 1.5) {
                try std.testing.expectEqual(@as(u8, 0x4D), q.alpha);
                saw_faint = true;
            }
        },
        else => {},
    };
    try std.testing.expect(saw_faint); // thumb quad 를 실제로 찾았다 — 못 찾으면 위 단언이 헛돈다
}
