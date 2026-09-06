//! 파일 탐색기·파일 패널 — 트리 스캔·선택·mutation, 패널 열기/닫기·dirty 동기·dock entry 관리.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F2).
//!
//! **탐색기(tree)와 패널(panel)을 한 파일에 둔다.** 문서는 원래 "반드시 2개 이상 분할"이었으나 호출
//! 관계가 **양방향**이라(tree→panel 10건, panel→tree 18건) 나누면 서로의 내부 함수를 열어야 해서
//! pub화가 26 → 75개로 는다. Zig는 파일 간 순환 import를 허용하니 컴파일은 되지만, 그렇게 얻는
//! 경계는 이름뿐이다.
//!
//! tree→panel은 조회가 아니라 **명령**이다 — `openFileTreePath`→`openFilePanelPath`(열기),
//! `applyFileTreeRename`→`retireFilePanelSurface`(정리), `begin/releaseFileTreeMutationEditorLocks`→
//! `queueFilePanelDirtySyncAction`·`queueFilePanelCloseUnlock`(락), `updateFileTreeMutations`→
//! `openCreatedFilePanel`(생성 후 열기). 즉 탐색기가 패널의 **생명주기를 직접 관리**한다.
//! 이 순환은 분해가 만든 것이 아니라 **드러낸** 것이다 — 한 파일 안에 있어서 안 보였을 뿐이다.
//! 방향 정리는 별도 PR로 둔다(부수효과 순서를 건드리는 구조 변경이라 "동작 변경 0" 범위 밖).
//!
//! 그룹 경계는 이름이 아니라 호출 관계로 잡았다. `dockHasContent`·`normalizeEmptyDockGroups`·
//! `removeDeletedDockEntries`는 이름이 dock이지만 내용은 전부 file 도메인이라 포함하고,
//! dock view 전환·레이아웃(F5)과는 겹치지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const path_shape = maru.path_shape; // 이 파일이 만드는 경로는 전부 중립 층으로 간다 — native 이음 금지(계약 §5 규칙 1)
const app_session_mod = @import("../app_session.zig"); // 공용 test 하네스·상수는 그쪽 소유
const AppSession = app_session_mod.AppSession;
const latchExternalFileChange = app_session_mod.latchExternalFileChange;
const FilePanelSaveCloseAction = app_session_mod.FilePanelSaveCloseAction;
const FileTreeReloadAction = AppSession.FileTreeReloadAction;
const FileTreeTrashOutcome = app_session_mod.FileTreeTrashOutcome;
const PendingFileTreeRootValidation = app_session_mod.PendingFileTreeRootValidation;
const headerIconRasterExtentPx = app_session_mod.headerIconRasterExtentPx;
const term_ops = @import("term.zig");
const web_ops = @import("web.zig");
const workspace_ops = @import("workspace.zig");
const settings_ops = @import("settings.zig");
const scroll_ops = @import("scroll.zig");
const PendingDockFocus = app_session_mod.PendingDockFocus;
const dock_ops = @import("dock.zig");
const file_tree_dock_ops = @import("file_tree_dock.zig");
const git_ops = @import("git.zig");
const remote_shell = maru.session.remote_shell; // 원격 명령 상한(RF4 — buildRemoteFileRead 의 cmd_buf 크기)
const git_command = maru.session.git_command; // 원격 파일 읽기 argv 의 SSOT(RF4)
const ssh_upload = if (builtin.os.tag == .macos) @import("../ssh_upload.zig") else struct {}; // 활성 터미널 cwd 해석을 소스 컨트롤 뷰와 공유한다(followActiveTerminalCwd)
const pane_ops = @import("pane.zig");
const renameatx_np = AppSession.renameatx_np;
const FilePanelOpenPathResult = AppSession.FilePanelOpenPathResult;
const FileTreePerfCounters = app_session_mod.FileTreePerfCounters;
const PendingFileTreeDelete = app_session_mod.PendingFileTreeDelete;
const PinnedFilePanelParent = AppSession.PinnedFilePanelParent;
const bumpExternalFileChange = AppSession.bumpExternalFileChange;
const entryKindForOpenKind = AppSession.entryKindForOpenKind;
const file_tree_backend = app_session_mod.file_tree_backend;
const panelKindForEntryKind = AppSession.panelKindForEntryKind;
const rowFileIdentity = AppSession.rowFileIdentity;
const stableOpenedFileHash = AppSession.stableOpenedFileHash;
const CloseScope = app_session_mod.CloseScope;
const FileEntryConstIterator = AppSession.FileEntryConstIterator;
const FileEntryIterator = AppSession.FileEntryIterator;
const FileOpenResult = AppSession.FileOpenResult;
const FilePanelDockControlAction = AppSession.FilePanelDockControlAction;
const FilePanelLinkError = AppSession.FilePanelLinkError;
const FilePanelReadError = AppSession.FilePanelReadError;
const FilePanelWriteError = AppSession.FilePanelWriteError;
const FileTreeEditKind = app_session_mod.FileTreeEditKind;
const FileTreeEditTarget = app_session_mod.FileTreeEditTarget;
const FileTreeFocusOwner = app_session_mod.FileTreeFocusOwner;
const FileTreeMutationEditorLock = app_session_mod.FileTreeMutationEditorLock;
const FileTreeRootOperation = app_session_mod.FileTreeRootOperation;
const FileTreeRootOutcome = app_session_mod.FileTreeRootOutcome;
const FileTreeScrollExtent = AppSession.FileTreeScrollExtent;
const Pane = app_session_mod.Pane;
const PendingClose = app_session_mod.PendingClose;
const PendingFilePanelClose = app_session_mod.PendingFilePanelClose;
const PendingRenameRemap = app_session_mod.PendingRenameRemap;
const RestoredFileEntries = AppSession.RestoredFileEntries;
const Tab = app_session_mod.Tab;
const Term = app_session_mod.Term;
const agent_dock = app_session_mod.agent_dock;
const dock_layout = app_session_mod.dock_layout;
const dock_panel = app_session_mod.dock_panel;
const file_panel_bridge = app_session_mod.file_panel_bridge;
const file_tree = app_session_mod.file_tree;
const file_tree_mutation_backend = app_session_mod.file_tree_mutation_backend;
const file_tree_navigation = app_session_mod.file_tree_navigation;
const file_tree_layout = maru.session.file_tree_layout; // 그리기와 히트테스트가 같은 산술을 쓰게 하는 단일 출처
const hasProtectedFilePanelsForExit = AppSession.hasProtectedFilePanelsForExit;
const layout_math = app_session_mod.layout_math;
const usizeOptEql = AppSession.usizeOptEql;

pub fn setFileTreeSelection(self: *AppSession, index: usize) bool {
    if (!self.file_tree_selection.set(self.file_tree_rows.items, index)) return false;
    // 방금 보여 줬다 — 뒤이은 재투영이 같은 신원으로 스크롤을 다시 뺏지 않게 표시한다. **그리고 보여
    // 주지 못했으면 기록하지 않는다**(도크가 접혔거나 렌더 전) — 그때 표시하면 도크를 열어도 안 보인다.
    if (scrollFileTreeRowIntoView(self, index))
        self.file_tree_revealed_selection_generation = self.file_tree_selection.generation;
    self.metal_dirty = true;
    return true;
}

/// 세로 폭이 좁은 창에서는 Artifact의 우측 column 대신 하단 band가 더 읽기 쉽다. 파일 도크의
/// tree/entry 상태는 그대로 두고 side만 바꾸며, side별 기본 크기를 다시 쓰도록 명시 크기는 비운다.
/// 커맨드 팔릿에서 실행하므로 색/테마와 무관한 구조 전환이고, 모든 terminal pane의 grid를 즉시 갱신한다.
pub fn toggleFilePanelDockSide(self: *AppSession) void {
    if (!self.dock_initialized or !self.dock.presented) return;
    self.dock.side = switch (self.dock.side) {
        .right => .bottom,
        .bottom => .right,
    };
    self.dock.size = 0;
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    self.last_resize_size = null;
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
    self.workspaceChanged(.dock);
}

pub fn fileTreeMutationTarget(row: file_tree.Row) ?file_tree_mutation.Target {
    return switch (row) {
        .root => |v| .{ .kind = .root, .path = v.path, .identity = v.identity },
        .directory => |v| .{ .kind = .directory, .path = v.path, .symlink = v.symlink, .identity = v.identity },
        .file => |v| .{ .kind = .file, .path = v.path, .symlink = v.symlink, .identity = v.identity },
        .recent_header, .recent_file, .empty => null,
    };
}

pub fn finishPendingTrashRecord(self: *AppSession, id: u64) void {
    var index: usize = 0;
    while (index < self.file_tree_trash_queue_len and self.file_tree_trash_queue[index].id != id) : (index += 1) {}
    if (index >= self.file_tree_trash_queue_len) return;
    const pending = self.file_tree_trash_queue[index];
    self.allocator.free(pending.root);
    self.allocator.free(pending.original);
    self.allocator.free(pending.staged);
    var i = index + 1;
    while (i < self.file_tree_trash_queue_len) : (i += 1) self.file_tree_trash_queue[i - 1] = self.file_tree_trash_queue[i];
    self.file_tree_trash_queue_len -= 1;
}

pub fn filePanelCloseEntry(self: *AppSession, pending: PendingFilePanelClose) ?*dock_panel.Entry {
    if (pending.surface_generation != pending.surface_id) return null; // surface id는 앱 전역 비재사용이라 generation token 겸용.
    const entry = fileEntryForSurfaceId(self, pending.surface_id) orelse return null;
    if (!std.mem.eql(u8, entry.path, pending.expected_path) or
        entry.external_change_generation != pending.state_generation) return null;
    if (pending.phase != .syncing and entry.editor_revision != pending.revision) return null;
    return entry;
}

pub fn fileEntries(self: *AppSession) FileEntryIterator {
    return .{ .session = self };
}

/// 지금 화면을 차지하고 있는 파일 entry(활성 탭 → 활성 pane → 활성 Term). 창 전체에서 최대 하나다 —
/// 옛 도크의 "focused group의 active entry"와 같은 자리다. 트리 활성 마커의 단일 출처.
pub fn activeFileEntry(self: *AppSession) ?*dock_panel.Entry {
    if (self.tabs.items.len == 0) return null;
    const tab = self.tabs.items[self.app_window.active_tab];
    return tab.activeTerm().file_entry;
}

pub fn markFilePanelCloseDirtySyncPending(self: *AppSession, entry: *dock_panel.Entry, request_id: u64) void {
    // source→read 전환 뒤에도 CM6 buffer와 dirty 상태는 surface에 남는다. 닫기 transaction은 mode와 무관하게
    // 최신 snapshot을 요구해야 read-mode dirty 탭이 즉시 닫히지 않는다.
    if (!entry.usesEditorBridge() or entry.surface_id == 0) return;
    entry.dirty_sync_pending = true;
    queueFilePanelDirtySyncAction(self, entry.surface_id, request_id);
}

pub fn countTabFileEntries(tab: *Tab) usize {
    var n: usize = 0;
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            if (term.file_entry != null) n += 1;
        }
    }
    return n;
}

pub fn queueFilePanelCloseUnlock(self: *AppSession, surface_id: u64, request_id: u64) void {
    if (surface_id == 0 or request_id == 0) return;
    for (self.file_panel_close_unlock_actions[0..self.file_panel_close_unlock_actions_len]) |*queued| {
        if (queued.surface_id != surface_id) continue;
        // 같은 surface의 더 새 close가 이전 unlock drain 전에 취소되면 최신 owner만 풀면 된다. 이전 owner는
        // 이미 새 sync가 대체했거나 이 unlock이 없어도 더 이상 입력을 막지 않는다.
        queued.request_id = request_id;
        return;
    }
    if (self.file_panel_close_unlock_actions_len >= self.file_panel_close_unlock_actions.len) return;
    self.file_panel_close_unlock_actions[self.file_panel_close_unlock_actions_len] = .{ .surface_id = surface_id, .request_id = request_id };
    self.file_panel_close_unlock_actions_len += 1;
}

pub fn refreshFileTreeWatchRoots(self: *AppSession) !void {
    if (!self.file_tree_initialized) return;
    try resetFileTreeWatchRootsFor(self, &self.file_tree, null);
    self.file_tree_watch_reset_pending = true;
}

pub fn fileTreeMutationEditorLock(self: *AppSession, surface_id: u64, request_id: u64) ?*FileTreeMutationEditorLock {
    for (self.file_tree_mutation_editor_locks[0..self.file_tree_mutation_editor_locks_len]) |*lock| {
        if (lock.surface_id == surface_id and lock.request_id == request_id and lock.phase == .waiting) return lock;
    }
    return null;
}

/// FP16 §3.4: "어느 파일 WebView가 native focus를 갖나"는 별도 축이 아니라 **활성 pane의 활성 Term**에서
/// 파생된다 — 파일이 워크스페이스 pane 탭이 된 뒤로 브라우저 Term과 같은 규칙이다. 옛 `.dock_surface`
/// 축은 그래서 사라졌다(도크가 워크스페이스 밖에 있던 시절의 잔재).
/// 그 파일 surface가 지금 **입력 소유**인가. 두 가지다 — workspace 소유이면서 활성 pane의 활성 Term이
/// 그 파일이거나(`focusedDockSurface`), 트리가 소유 중이면서 그 파일이 Esc 복원 대상이거나.
/// 후자를 빼면 트리에서 rename/삭제할 때 파괴된 surface가 복원 대상으로 남는다(code-review max).
pub fn fileSurfaceOwnsInput(self: *const AppSession, surface_id: u64) bool {
    if (surface_id == 0) return false;
    return switch (self.focus_owner) {
        .file_tree => |owner| owner.restore_surface == surface_id,
        else => (self.focusedDockSurface() orelse return false) == surface_id,
    };
}

/// 대상 행을 뷰포트 안으로 **최소한만** 민다(file-explorer §1 정책 4 — 이미 보이면 스크롤을 안 뺏는다).
/// 픽셀 좌표라 "보인다"의 기준은 행이 **온전히** 들어와 있는가다: 부분적으로 걸친 행은 마저 넣는다.
///
/// 반환값은 **판정할 수 있었는가**이지 스크롤을 옮겼는가가 아니다. 렌더 메트릭이 아직 없거나(첫 프레임)
/// 도크가 접혀 뷰포트가 0이면 이 함수는 아무것도 못 하고 `false`를 낸다 — 그때 호출자가 "보여 줬다"고
/// 기록하면(`file_tree_revealed_selection_generation`) 도크를 다시 열어도 그 선택은 영영 안 보인다.
/// `scrollFileTreeToFollowedCwd`가 같은 위험을 pending 유지로 다루는 것과 같은 규율이다.
pub fn scrollFileTreeRowIntoView(self: *AppSession, index: usize) bool {
    const row_h = file_tree_dock_ops.fileTreeRowHeightPx(self);
    if (row_h == 0) return false;
    const extent = fileTreeScrollExtent(self);
    if (extent.viewport_h_px == 0) return false;
    const top: u64 = @as(u64, index) * @as(u64, row_h);
    const bottom = top + row_h;
    const offset = fileTreeEffectiveScrollPx(self);
    if (top < offset) {
        setFileTreeScrollOffsetPx(self, @intCast(@min(top, @as(u64, std.math.maxInt(i32)))));
    } else if (bottom > @as(u64, offset) + extent.viewport_h_px) {
        setFileTreeScrollOffsetPx(self, @intCast(@min(bottom - extent.viewport_h_px, @as(u64, std.math.maxInt(i32)))));
    }
    return true;
}

pub fn applyFileTreeRename(self: *AppSession, id: u64, new_path: []const u8) bool {
    const plan = if (self.pending_rename_remap) |*pending| pending else return false;
    if (plan.id != id) return false;
    // Validate the exact admission snapshot before the first swap. Open is globally blocked while a
    // rename is in flight; unrelated close/reorder is tolerated because lookup is by expected path.
    //
    // **키는 expected path + `mutation_pending_id` 스탬프다(FP16 §1 ⑷).** 정합성을 지는 건 원래부터 이 쌍이었고
    // `EntryId`는 빠른 핸들일 뿐이었다 — close 후 같은 경로 재오픈이라는 aliasing 시나리오도 새 entry에는
    // 스탬프가 없어 fail-close된다(스파이크 §11.1 S2). 소유가 Term으로 옮겨가도 이 키는 그대로 성립한다.
    for (plan.dock_items[0..plan.dock_len]) |item| {
        const entry = fileEntryForPath(self, item.expected) orelse return false;
        if (entry.mutation_pending_id != id) return false;
    }
    for (plan.recent_items[0..plan.recent_len]) |item| {
        const current = self.file_tree.recentAt(item.index) orelse return false;
        if (!std.mem.eql(u8, current, item.expected)) return false;
    }

    var retired_focus = false;
    for (plan.recent_items[0..plan.recent_len]) |item|
        std.debug.assert(self.file_tree.replaceRecentOwned(item.index, item.expected, item.replacement));
    for (plan.dock_items[0..plan.dock_len]) |item| {
        const entry = fileEntryForPath(self, item.expected) orelse unreachable;
        const old_surface = entry.surface_id;
        const old_owned = entry.path;
        const old_kind = entry.kind;
        entry.path = item.replacement;
        self.allocator.free(old_owned);
        const new_kind = item.new_kind orelse entry.kind;
        const kind_changed = new_kind != entry.kind;
        if (kind_changed) {
            entry.kind = new_kind;
            entry.mode = dock_panel.Mode.defaultFor(new_kind);
        }
        // 뷰를 다시 세워야 하는 조건은 **둘**이다(FP16 §1 ⑵⑶).
        //  ⓐ trust config 전환 — `WKWebViewConfiguration`이 init 시점 고정이라(MaruAppHost.swift:2843~2868)
        //     신뢰↔격리는 재생성 말고 방법이 없다. 격리(html·pdf)는 핀 URL이 init에 캐시된 `let`이라 같은
        //     kind끼리도 지금은 재생성한다(핀만 갱신하는 무손실 경로는 §13 백로그).
        //  ⓑ **kind 변경** — shell의 뷰어는 생성 시점 `?lang=`/`?kind=` 힌트로 정해지고 `entry.mode`도
        //     되밀 채널이 없다. kind만 바꾸고 뷰를 두면 `.md`→`.png`에서 markdown shell이 PNG 바이트를
        //     텍스트로 그리고, 더 나쁘게는 mode가 non-editable로 리셋된 채 CM6가 살아 있어 이후 삭제/rename이
        //     편집기 잠금·dirty 스냅샷을 건너뛴다(code-review max). 그래서 kind가 바뀌면 반드시 재생성한다.
        const rebuild = kind_changed or filePanelKindIsIsolated(old_kind) or filePanelKindIsIsolated(entry.kind);
        if (old_surface != 0 and rebuild) {
            // 재생성 경로에서는 **통지를 destroyTerm 하나만** 낸다 — retire까지 통지하면 같은 surface가
            // 두 번 닫힘으로 보고돼 Swift가 이미 없는 WKWebView를 두 번 정리한다(code-review max).
            noteRetiredFilePanelFocus(self, entry, &retired_focus);
            // 새 kind의 뷰를 즉시 다시 만든다. 실패하면 surface_id가 0인 채로 남아 저장·mode 전환·닫기가
            // 전부 SurfaceNotFound가 되는 좀비 탭이 되므로, 그때는 그 탭을 닫아 좀비를 안 남긴다.
            // 실패는 첫 `try`(createWebTerm)에서만 난다 — 그 시점 옛 Term은 **아직 살아 있다**. 그러니
            // 통지하거나 닫으려 들면 안 되고(살아 있는 surface를 닫혔다고 보고하게 된다), 사용자에게
            // 알리고 옛 뷰를 그대로 둔다. 다음 열기/전환이 다시 시도한다(code-review max).
            rebuildFileTermSurface(self, entry) catch {
                self.showNoticeKey(.fp_view_rebuild_failed);
            };
        } else if (old_surface != 0) {
            // 경로만 바뀐 신뢰 kind rename은 **아무 통지도 하지 않는다** — breadcrumb은 `entry.path`에서
            // 파생하는 Zig GPU chrome이고 read/write는 pathless라 shell이 경로를 모른다(§11.1 S3·S4).
            // 상대 asset도 깨지지 않는다: 트리 rename은 이름만 바꾸므로 파일과 그 형제 asset이 **함께**
            // 움직인다(디렉터리 rename이면 하위 트리가 통째로). 그래서 옛 `!same_dir` reload 분기는 제거했다
            // — 디렉터리 rename에서 하위 entry 전부를 헛되이 재로드시키던 결함이었다(code-review max).
            //
            // 다만 rename은 FSEvents에 새 경로의 file-level 이벤트로 잡히고, `fileTreeChanged`가 그걸
            // 외부 변경으로 보고 reload를 걸어 무손실 계약을 깨뜨린다. 저장이 쓰는 self-write grace latch를
            // 같은 목적으로 무장해 그 echo를 우리 이벤트로 소비한다.
            if (entry.disk_content_hash_valid) {
                entry.self_write_grace_ticks = @intCast(@min(self.ticksForMs(2_000), std.math.maxInt(u16)));
                entry.self_write_hash = entry.disk_content_hash; // rename은 내용을 안 바꾼다 — 해시가 그대로다.
                entry.self_write_verifications = 0;
            } else {
                // 아직 내용을 읽은 적이 없어 대조 기준선이 없다(예: readSelfImage 경로). echo를 우리 것으로
                // 증명할 수 없으므로 억제하지 않고 기존 외부변경 reload에 맡긴다(안전 쪽).
                queueFileTreeReload(self, old_surface, false);
            }
        }
    }
    // A supported file renamed to an unsupported extension remains on disk and selected in the
    // project tree, but no longer has a file-panel capability. Remove only those clean reserved
    // entries after every allocation and path swap has succeeded.
    {
        // 대상을 먼저 수집한 뒤 닫는다 — close가 pane 트리를 변형하므로 순회 중에 닫으면 어긋난다.
        var doomed: [dock_panel.max_entries]*dock_panel.Entry = undefined;
        var doomed_len: usize = 0;
        var prune_it = fileEntries(self);
        while (prune_it.next()) |entry| {
            if (!file_tree_mutation.pathWithin(entry.path, new_path) or file_panel_bridge.openKindForPath(entry.path) != null) continue;
            if (doomed_len >= doomed.len) break;
            doomed[doomed_len] = entry;
            doomed_len += 1;
        }
        for (doomed[0..doomed_len]) |entry| {
            // 위 루프가 신뢰 kind rename에서 surface를 **유지**하게 된 뒤로, 여기 도달하는 entry가 live
            // surface를 들고 있을 수 있다(예: `notes.md` → `notes.docx` — kind는 그대로라 재생성 대상이 아닌데
            // 확장자가 비지원이라 접힌다). teardown 없이 지우면 capability·pane grant가 새고 focus가 죽은
            // surface를 가리킨다(code-review max).
            retireFilePanelSurface(self, entry, &retired_focus);
            _ = closeFileTermForEntry(self, entry);
        }
    }
    normalizeEmptyDockGroups(self);
    if (retired_focus) {
        // FP16: "focused group의 active entry" 자리를 활성 pane의 활성 Term이 대신한다.
        const restore_surface = blk: {
            const active_term = pane_ops.activePane(self).activeTerm();
            const active_entry = active_term.file_entry orelse break :blk null;
            break :blk if (active_entry.surface_id != 0) active_entry.surface_id else null;
        };
        self.focus_owner = .{ .file_tree = .{ .restore_surface = restore_surface } };
        self.file_tree_focus_pending = true;
    }
    plan.committed = true;
    plan.deinit(self.allocator);
    self.pending_rename_remap = null;
    return true;
}

pub fn verifySelfWriteEvent(self: *AppSession, entry: *dock_panel.Entry) bool {
    const owned = self.allocator.dupe(u8, entry.path) catch return false;
    if (!self.file_tree_backend.submitFileHash(owned)) {
        self.allocator.free(owned);
        return false;
    }
    entry.self_write_verifications +|= 1;
    return true;
}

/// `exclude`는 **지금 닫는 중이라 이미 상태를 해소한** entry다. 그 entry 자신이 종료를 막으면
/// "닫혔다고 보고했는데 창은 그대로"인 유령 상태가 되므로(2단계 close가 끝난 뒤라 잃을 게 없다)
/// 게이트에서 뺀다. 그 밖의 파일이 막는 것은 그대로 막는다.
pub fn hasProtectedFilePanelsForExitExcluding(self: *const AppSession, exclude: ?*const dock_panel.Entry) bool {
    if (self.pending_file_panel_close != null or self.file_panel_save_close_pending != null) {
        // 지금 닫는 중인 그 entry의 transition은 제외 대상과 같은 이유로 무시한다.
        const own = if (exclude) |e| blk: {
            const pending = self.pending_file_panel_close orelse break :blk false;
            break :blk pending.surface_id == e.surface_id;
        } else false;
        if (!own or self.file_panel_save_close_pending != null) return true;
    }
    if (self.file_tree_mutation_waiting_request != null or self.file_tree_edit_inflight or
        self.file_tree_delete_inflight or (self.file_tree_initialized and self.file_tree_mutation_backend.pendingCount() != 0) or
        self.file_tree_trash_queue_len != 0 or self.file_tree_manual_recovery_paths_len != 0 or
        self.file_tree_manual_recovery_unknown or
        self.file_tree_mutation_editor_locks_len != 0) return true;
    if (!self.dock_initialized) return false;
    var entry_it3 = fileEntriesConst(self);
    while (entry_it3.next()) |entry| {
        if (exclude) |e| if (entry == e) continue;
        if (filePanelEntryNeedsDirtyProtection(entry.*)) return true;
    }
    return false;
}

pub fn scopeHasProtectedFilePanel(self: *AppSession, scope: CloseScope) bool {
    return switch (scope) {
        .none => false,
        .term => termHasProtectedFilePanel(pane_ops.activePane(self).activeTerm()),
        .pane => paneHasProtectedFilePanel(pane_ops.activePane(self)),
        .tab => |idx| tabHasProtectedFilePanel(self.tabs.items[idx]),
        // ⌘Q는 복구 기회가 없어 보수적으로 — 편집 가능 mode만으로도 막는다(hasProtectedFilePanelsForExit).
        .session => hasProtectedFilePanelsForExit(self),
    };
}

pub fn clearFileTreeMutationReservation(self: *AppSession, request_id: u64) void {
    if (!self.dock_initialized or request_id == 0) return;
    var entry_it11 = fileEntries(self);
    while (entry_it11.next()) |entry| {
        if (entry.mutation_pending_id == request_id) entry.mutation_pending_id = 0;
    }
}

/// 파일 entry를 든 Term을 닫는다. **true를 돌려줬으면 Term은 실제로 사라졌다** — 호출자는 반환 뒤
/// `entry` 포인터를 다시 읽으면 안 되고, false면 아무것도 바뀌지 않았다고 믿어도 된다.
pub fn closeFileTermForEntry(self: *AppSession, entry: *const dock_panel.Entry) bool {
    for (self.tabs.items, 0..) |tab, tab_index| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items, 0..) |term, term_index| {
                if (term.file_entry != entry) continue;
                // 이 Term이 창에 하나뿐이면 닫는 것이 곧 창을 닫는 것이다(터미널 Term과 같은 계약 —
                // closeTermAt → closeTab → latchSessionClose). 그런데 latch는 **다른** 보호 파일이 있으면
                // 조용히 no-op이므로, 그 상태에서 Term을 먼저 파괴하면 "닫혔다"고 보고해 놓고 창은 그대로
                // 남는 유령이 된다(code-review max). 그래서 파괴 **전에** 종료 가능 여부를 먼저 묻고,
                // 막히면 아무것도 안 한 채 false를 돌려준다. 자기 자신은 이미 2단계 close로 상태를
                // 해소했으므로 게이트에서 뺀다.
                if (pane.terms.items.len <= 1 and tab.panes.items.len <= 1 and self.tabs.items.len <= 1) {
                    // 이 Term이 창에 하나뿐이면 닫는 것이 곧 창을 닫는 것이다. **구조는 건드리지 않고
                    // 종료 latch만 건다** — Term을 먼저 빼면 pane이 Term 0개가 되어 모델 불변식이 깨지고,
                    // latch가 그 직후 `activeSurface()`(방금 free된 대표 surface)에 쓴다. closeTab이
                    // 마지막 탭에 대해 하는 것과 같은 계약이다: 정리는 deinit이 한다.
                    //
                    // 아래 게이트를 **먼저** 통과했으므로 latch는 반드시 실효한다 — 그래서 true가
                    // "닫혔다"는 뜻으로 정직하다(유령 성공이 아니다).
                    if (filePanelsBlockCloseExcluding(self, entry)) {
                        self.showNoticeKey(.common_unsaved_tabs_first);
                        return false;
                    }
                    self.ended_seen = true;
                    term_ops.activeSurface(self).process_state = .exited;
                    self.metal_dirty = true;
                    return true;
                }
                // 정규 경로에 위임한다 — 직접 orderedRemove하면 배경 탭의 surface_ptrs 재바인딩과 active
                // 시프트 보정, pane collapse, 마지막 탭의 종료 latch를 빠뜨린다(전부 closeTermAt이 소유).
                term_ops.closeTermAt(self, tab_index, pane, term_index);
                self.metal_dirty = true;
                return true;
            }
        }
    }
    return false;
}

pub fn queueFileTreeReload(self: *AppSession, surface_id: u64, conflict: bool) void {
    if (surface_id == 0) return;
    for (self.file_tree_reload_actions[0..self.file_tree_reload_actions_len]) |*queued| {
        if (queued.surface_id == surface_id) {
            queued.conflict = queued.conflict or conflict;
            return;
        }
    }
    if (self.file_tree_reload_actions_len >= self.file_tree_reload_actions.len) return;
    self.file_tree_reload_actions[self.file_tree_reload_actions_len] = .{ .surface_id = surface_id, .conflict = conflict };
    self.file_tree_reload_actions_len += 1;
}

pub fn rebuildFileTreeFromDock(self: *AppSession) !void {
    if (!self.file_tree_initialized) return;
    self.file_tree_backend.deinit();
    self.file_tree.deinit();
    self.file_tree = file_tree.Tree.init(self.allocator);
    self.file_tree_backend = try file_tree_backend.Backend.init(self.allocator, self.io);
    self.file_tree_rows.clearRetainingCapacity();
    self.file_tree_rows_dirty = true;
    self.file_tree_watch_reset_pending = true;
    var entry_it16 = fileEntries(self);
    while (entry_it16.next()) |entry| {
        const root = try file_tree_backend.projectRootForFile(self.allocator, self.io, entry.path);
        defer self.allocator.free(root);
        try self.file_tree.recordOpened(entry.path, root);
    }
}

pub fn openFilePanelPathFromValidatedRow(
    self: *AppSession,
    path: []const u8,
    file: std.Io.File,
    identity: file_tree.Identity,
) FilePanelOpenPathResult {
    if (fileTreeFileMutationBusy(self) or !self.dock_initialized or path.len == 0 or !std.fs.path.isAbsolute(path) or
        !std.unicode.utf8ValidateSlice(path)) return .failed;
    const open_kind = file_panel_bridge.openKindForPath(path) orelse return .unsupported;
    const stat = file.stat(self.io) catch return .failed;
    if (stat.kind != .file) return .failed;
    return openFilePanelPathAfterValidation(self, path, open_kind, identity);
}

/// A dirty/source-edit file opened through a symlink alias can be outside the target's lexical
/// prefix while still residing below the target directory by inode. Until dock entries persist a
/// canonical ancestor chain, fail closed for directory mutations when any protected file panel
/// exists in any project root. Cross-root symlinks make a lexical-root restriction unsafe.
pub fn fileTreeDirectoryAliasRisk(self: *const AppSession, target_path: []const u8, root: []const u8) bool {
    _ = target_path;
    _ = root;
    var entry_it9 = fileEntriesConst(self);
    while (entry_it9.next()) |entry| {
        if (filePanelEntryNeedsDirtyProtection(entry.*)) return true;
    }
    return false;
}

pub fn startFileTreeEdit(self: *AppSession, edit_kind: FileTreeEditKind) void {
    if (fileTreeNamespaceMutationBusy(self)) {
        self.showNoticeKey(.fp_mutation_in_progress);
        return;
    }
    const target = selectedFileTreeMutationTarget(self) orelse {
        self.showNoticeKey(.fp_select_first);
        return;
    };
    if (edit_kind == .rename and target.kind == .root) {
        self.showNoticeKey(.fp_root_rename_denied);
        return;
    }
    if (edit_kind != .rename and target.symlink and (target.kind == .root or target.kind == .directory)) {
        self.showNoticeKey(.fp_symlink_dir_create_denied);
        return;
    }
    const copied = copyFileTreeEditTarget(target, edit_kind) orelse {
        self.showNoticeKey(.fp_path_too_long);
        return;
    };
    settings_ops.startRename(self, .{ .file_tree = copied });
}

pub fn updateFileTree(self: *AppSession) !void {
    if (!self.file_tree_initialized) return;
    var changed = false;
    while (self.file_tree_backend.takeResult()) |owned_result| {
        var result = owned_result;
        defer result.deinit(self.allocator, self.io);
        if (result.kind == .root_validation) {
            root_result: {
                const pending = self.file_tree_root_validation orelse break :root_result;
                // **자동 전환이면 이 블록의 모든 알림을 끈다.** submit 시점 one-shot은 그때 소비돼 여기까진
                // 안 온다 — 그대로 두면 사용자가 고른 적 없는 전환이 실패했을 때 "선택한 폴더를 열 수
                // 없습니다"가 뜬다(고른 적이 없으니 무엇을 잘못했는지 알 수 없는 알림이다).
                const restore_auto = self.file_tree_root_auto_follow;
                self.file_tree_root_auto_follow = pending.auto;
                defer self.file_tree_root_auto_follow = restore_auto;
                if (pending.request_id != result.request_id or
                    pending.expected_root_generation != result.expected_root_generation or
                    @intFromEnum(pending.operation) != result.root_operation or
                    pending.round != result.root_validation_round) break :root_result;
                if (self.file_tree.rootGeneration() != pending.expected_root_generation) {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .stale_generation, .fp_root_stale_generation);
                    break :root_result;
                }
                if (!result.ok) {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .validation_failed, .fp_root_open_failed);
                    break :root_result;
                }
                if (pending.round == 0) {
                    const identity = result.identity orelse {
                        self.file_tree_root_validation = null;
                        reportFileTreeRootOutcome(self, .identity_missing, .fp_root_identity_unknown);
                        break :root_result;
                    };
                    const canonical = self.allocator.dupe(u8, result.path) catch {
                        self.file_tree_root_validation = null;
                        reportFileTreeRootOutcome(self, .allocation_failed, .fp_root_revalidate_alloc_failed);
                        break :root_result;
                    };
                    if (!self.file_tree_backend.submitRootValidation(
                        canonical,
                        pending.request_id,
                        pending.expected_root_generation,
                        @intFromEnum(pending.operation),
                        1,
                    )) {
                        self.allocator.free(canonical);
                        self.file_tree_root_validation = null;
                        reportFileTreeRootOutcome(self, .backend_busy, .fp_root_revalidate_start_failed);
                        break :root_result;
                    }
                    self.file_tree_root_validation.?.round = 1;
                    // root 검증도 같은 `fstat` 축이지만, root 계열(RootCapability·pin·mutation 가드)은
                    // 아직 타입이 안 따라왔다 — 여기서 명시적으로 풀어 그 사실이 보이게 둔다(후속 범위).
                    self.file_tree_root_validation.?.identity = identity.value;
                    break :root_result;
                }
                const expected_identity = pending.identity orelse {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .identity_missing, .fp_root_revalidate_invalid);
                    break :root_result;
                };
                const actual_identity = result.identity orelse {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .identity_missing, .fp_root_identity_gone);
                    break :root_result;
                };
                const validated_dir = result.validated_dir orelse {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .identity_missing, .fp_root_capability_gone);
                    break :root_result;
                };
                // 양변 다 `fstat` 축이다(기대값은 1라운드에서 같은 검증이 남긴 값) — root 계열이
                // 아직 타입을 안 입어 여기서 풀어 비교한다(후속 범위).
                if (!expected_identity.eql(actual_identity.value)) {
                    self.file_tree_root_validation = null;
                    reportFileTreeRootOutcome(self, .identity_changed, .fp_root_identity_changed);
                    break :root_result;
                }
                self.file_tree_root_validation = null;
                var candidate = self.file_tree.cloneForRootTransaction() catch {
                    reportFileTreeRootOutcome(self, .allocation_failed, .fp_root_change_alloc_failed);
                    break :root_result;
                };
                defer candidate.deinit();
                const roots = [_][]const u8{result.path};
                switch (pending.operation) {
                    .replace => candidate.replaceExplicitRoots(&roots) catch {
                        reportFileTreeRootOutcome(self, .model_stage_failed, .fp_root_replace_failed);
                        break :root_result;
                    },
                    .add => candidate.addExplicitRoot(result.path) catch {
                        reportFileTreeRootOutcome(self, .model_stage_failed, .fp_root_add_failed);
                        break :root_result;
                    },
                    .none => break :root_result,
                }
                // pin 도 `fstat` 축을 받는다(`openValidatedFileTreeRow` 가 같은 축으로 다시 잰다) — root
                // 계열이 아직 타입을 안 입어 풀어 넘긴다(후속 범위).
                if (result.identity) |identity| _ = candidate.pinRootIdentity(result.path, identity.value);
                resetFileTreeWatchRootsFor(self, &candidate, null) catch {
                    reportFileTreeRootOutcome(self, .watcher_stage_failed, .fp_root_watch_change_failed);
                    break :root_result;
                };
                var candidate_rows: std.ArrayList(file_tree.Row) = .empty;
                defer candidate_rows.deinit(self.allocator);
                prepareFileTreeRowStaging(self, &candidate_rows, 0) catch {
                    reportFileTreeRootOutcome(self, .row_stage_failed, .fp_root_rows_change_failed);
                    break :root_result;
                };
                buildPreparedFileTreeRows(self, &candidate, &candidate_rows);
                const validated_scan_path = candidate.takeScanRequestForPath(result.path) orelse {
                    reportFileTreeRootOutcome(self, .model_stage_failed, .fp_root_first_scan_alloc_failed);
                    break :root_result;
                };
                if (!self.file_tree_backend.submitValidatedRootScan(
                    validated_scan_path,
                    candidate.rootGeneration(),
                    validated_dir,
                )) {
                    candidate.requeueScan(validated_scan_path) catch {};
                    self.allocator.free(validated_scan_path);
                    reportFileTreeRootOutcome(self, .backend_busy, .fp_root_scan_start_failed);
                    break :root_result;
                }
                result.validated_dir = null; // first scan worker now owns the descriptor capability.
                commitFileTreeCandidate(self, &candidate, &candidate_rows);
                if (!pending.auto) self.workspaceChanged(.explorer_roots);
                reportFileTreeRootOutcome(self, switch (pending.operation) {
                    .replace => .committed_replace,
                    .add => .committed_add,
                    .none => .model_stage_failed,
                }, null);
                self.dock.presented = true;
                self.dock.collapsed = false;
                self.file_tree_scroll.reset();
                clearFileTreeSelection(self);
                self.file_tree_rows_dirty = true;
                changed = true;
            }
            break; // at most one root validation/revalidation completion per frame tick.
        }
        if (result.kind == .file_hash) {
            hash_groups: {
                var hash_it = fileEntries(self);
                while (hash_it.next()) |entry| {
                    if (!std.mem.eql(u8, entry.path, result.path) or entry.self_write_verifications == 0) continue;
                    if (!result.ok or result.file_hash != entry.self_write_hash) {
                        entry.self_write_verifications = 0;
                        entry.self_write_grace_ticks = 0;
                        entry.self_write_hash = 0;
                        markExternalFileChange(self, entry);
                    } else {
                        entry.self_write_verifications -= 1;
                        if (entry.self_write_verifications == 0) {
                            entry.self_write_grace_ticks = 0;
                            entry.self_write_hash = 0;
                        }
                    }
                    break :hash_groups;
                }
            }
            changed = true;
            continue;
        }
        // ── 원격 결과(RF3a)는 원격 모델로 — 로컬과 섞이면 같은 철자의 경로가 남의 트리에 박힌다.
        if (result.was_remote) {
            const re = &self.remote_explorer;
            if (result.expected_root_generation != re.tree.rootGeneration()) continue;
            if (!result.ok) {
                // §2.5 — 침묵이 아니라 「못 읽는다」다. **root 실패는 트리를 비워 안내 행(.empty)이
                // 서게 한다** — root 행을 남겨 두면 «펼쳐진 빈 폴더» 로 보여 실패가 화면에 없다.
                // 하위 실패는 그 노드만 접는다(트리 전체를 안내로 바꾸면 멀쩡한 형제가 사라진다).
                if (std.mem.eql(u8, result.path, re.root.items)) {
                    re.tree.replaceExplicitRoots(&.{}) catch {};
                } else {
                    re.tree.failSnapshot(result.path);
                }
                setRemoteExplorerError(self, result.remote_error orelse "remote listing failed");
                changed = true;
                continue;
            }
            setRemoteExplorerError(self, null);
            self.file_tree_entry_inputs.clearRetainingCapacity();
            self.file_tree_entry_inputs.ensureTotalCapacity(self.allocator, result.entries.items.len) catch {
                re.tree.failSnapshot(result.path);
                re.tree.requeueScan(result.path) catch {};
                self.file_tree_rows_dirty = true;
                continue;
            };
            for (result.entries.items) |entry| self.file_tree_entry_inputs.appendAssumeCapacity(.{
                .name = entry.name,
                .kind = entry.kind,
                .identity = entry.identity,
            });
            re.tree.applySnapshotWithIdentity(result.path, result.identity, self.file_tree_entry_inputs.items) catch |err| switch (err) {
                error.NotFound => {}, // root 가 그 사이 이관된 정상 race(따라가기가 cd 를 쫓는다)
                error.IdentityMismatch => re.tree.failSnapshot(result.path),
                else => {
                    re.tree.failSnapshot(result.path);
                    re.tree.requeueScan(result.path) catch {};
                },
            };
            // 로컬과 달리 여기서 안 하는 둘: git check-ignore(로컬 git 에 원격 경로를 대는 §2.4 위반)와
            // watcher(로컬 감시자에 원격 경로를 등록하는 같은 위반). 감시 축은 RF5 다.
            changed = true;
            continue;
        }
        // Directory results belong to the exact root snapshot that queued them. Comparing only
        // the path is insufficient for A -> B -> A because the same bytes can name a new root
        // authority after two replacements.
        if (result.expected_root_generation != self.file_tree.rootGeneration()) continue;
        if (!result.ok) {
            self.file_tree.failSnapshot(result.path);
            changed = true;
            continue;
        }
        self.file_tree_entry_inputs.clearRetainingCapacity();
        self.file_tree_entry_inputs.ensureTotalCapacity(self.allocator, result.entries.items.len) catch |err| {
            self.file_tree.failSnapshot(result.path);
            self.file_tree.requeueScan(result.path) catch {};
            self.file_tree_rows_dirty = true;
            return err;
        };
        for (result.entries.items) |entry| self.file_tree_entry_inputs.appendAssumeCapacity(.{
            .name = entry.name,
            .kind = entry.kind,
            .identity = entry.identity,
        });
        self.file_tree.applySnapshotWithIdentity(result.path, result.identity, self.file_tree_entry_inputs.items) catch |err| switch (err) {
            error.NotFound => {}, // watcher refresh 중 부모가 사라졌거나 root가 이관된 정상 race.
            error.IdentityMismatch => {
                self.file_tree.failSnapshot(result.path);
                self.showNoticeKey(.fp_dir_changed_reopen);
            },
            else => {
                self.file_tree.failSnapshot(result.path);
                self.file_tree.requeueScan(result.path) catch {};
                self.file_tree_rows_dirty = true;
                return err;
            },
        };
        // 방금 읽은 디렉터리의 항목들을 git 에 물어 **무시 여부**를 표시한다(사용자 결정 2026-08-18).
        // 여기가 자리인 이유: 그 목록이 지금 손에 있고, "펼쳐 보이는 것"만 묻는다는 규칙이 자연히 지켜진다.
        // 거절되거나 실패하면 그 화면은 판정 없이 남는다 — 모르면 흐리게 하지 않는다.
        git_ops.requestIgnoredForPaths(self, result.path, result.entries.items);
        changed = true;
    }

    // 원격 파일 열기 결말(RF4) — 워커가 남긴 결과를 tick 이 가져간다.
    {
        self.remote_file_mutex.lockUncancelable(self.io);
        const got = self.remote_file_outcome;
        self.remote_file_outcome = null;
        self.remote_file_mutex.unlock(self.io);
        if (got) |outcome| finishRemoteFileOpen(self, outcome);
    }

    // follow 가 펌프보다 **먼저다**(적대적 검증 3 회차): 적용이 이번 tick 의 ctl·스캔 요청을 세우고
    // 같은 tick 의 펌프가 그것을 쏜다 — 뒤에 두면 첫 활성화가 한 프레임 늦고, ctl 갱신도 한 tick
    // 낡은 것을 쓴다.
    followRemoteExplorer(self);

    var submitted: usize = 0;
    while (submitted < file_tree_backend.max_inflight) {
        const path = self.file_tree.takeScanRequest() orelse break;
        if (!self.file_tree_backend.submit(path, self.file_tree.rootGeneration())) {
            self.file_tree.requeueScan(path) catch {};
            self.allocator.free(path);
            break;
        }
        submitted += 1;
    }

    // 원격 스캔 펌프(RF3a). 상한이 로컬과 **따로**다(§2.2.1 — 원격이 로컬 슬롯을 굶기지 않는다).
    // ctl 이 비면 안 쏜다(적대적 검증 1 회차 — 빈 ctl 은 ssh 직결 폴백이다).
    if (self.remote_explorer.active and self.remote_explorer.ctl.items.len != 0) {
        var remote_submitted: usize = 0;
        while (remote_submitted < file_tree_backend.max_remote_inflight) {
            const path = self.remote_explorer.tree.takeScanRequest() orelse break;
            if (!self.file_tree_backend.submitRemoteDirectory(
                path,
                self.remote_explorer.dest.items,
                self.remote_explorer.ctl.items,
                self.remote_explorer.tree.rootGeneration(),
            )) {
                self.remote_explorer.tree.requeueScan(path) catch {};
                self.allocator.free(path);
                break;
            }
            remote_submitted += 1;
        }
    }

    followActiveTerminalCwd(self);

    if (changed) self.file_tree_rows_dirty = true;
    if (self.file_tree_rows_dirty) {
        try projectFileTreeOpenStates(self);
        // 발행 행 목록은 하나다 — 원격이 활성이면 원격 모델이 그 목록을 채운다(선택·스크롤·호버는
        // 발행 목록 기준이라 그대로 동작한다). open 상태는 **로컬 파일**의 것이므로 원격 행에 물리면
        // 같은 철자의 남의 파일이 「열린 것처럼」 빛난다 — 빈 목록을 준다.
        if (self.remote_explorer.active) {
            try self.remote_explorer.tree.buildRows(self.allocator, &.{}, &self.file_tree_rows);
        } else {
            try self.file_tree.buildRows(self.allocator, self.file_tree_open_states.items, &self.file_tree_rows);
        }
        // **발행 출처를 행과 함께 굳힌다**(적대적 검증 2 회차). 펜스가 «지금 모드» 를 보면, 원격이
        // 내려간 뒤 재빌드 전 한 프레임(또는 뷰 게이트로 follow 가 늦는 동안) 낡은 원격 행이 로컬
        // 갈래로 들어간다 — 같은 철자의 로컬 파일이 열리는 §2.4 그 구멍이다. 행을 쓴 쪽이 키다.
        self.file_tree_rows_remote = self.remote_explorer.active;
        classifyFileTreeRows(self.file_tree_rows.items);
        reconcileFileTreeSelection(self);
        clampFileTreeScroll(self);
        clearFileTreeHover(self);
        scrollFileTreeToFollowedCwd(self); // ET-CWD: 재투영된 행 기준으로 뷰포트 보정(file-explorer §1 정책 4)
        advanceFileTreeProjectionGeneration(self);
        self.file_tree_rows_dirty = false;
        self.metal_dirty = true;
    }
}

/// 이 창(AppSession)의 라이브 상태를 workspace restore 모델(maru.session.workspace.Window)로 캡처한다(R3). 탭→pane
/// split 트리→Term→surface를 걸어 선언적 상태만 모은다 — live PTY/process/grid는 안 담는다. cwd/title은 host 또는
/// in-process backend의 runtime observation, command는 spawn argv[0](surface.command). split 트리는 *Pane leaf를
/// pane 인덱스로 환원해 preorder TreeNode로 평탄화(직렬화 모델과 같은 형태). 멀티 창 전체 모델은 호출자(R5)가
/// 각 세션의 Window를 모아 만든다. 모든 슬라이스·문자열은 `arena`가 소유한다(호출자가 deinit).
/// is_active = 이 창이 저장 시점 key(활성) 창인가(Swift `window.isKeyWindow`). 재시작 복원 loop가 이 마커로
/// 활성 창을 다시 focus한다(M3e — docs/window-surface-mobility.md §8A.8). false면 workspace.v1 옵션-키가
/// 생략돼(group-collapsed 패턴) 옛 파일과 flat 동일하다.
/// frame = 이 창의 픽셀(점) frame(Swift `window.frame`, 전역 스크린 좌표). null이면 win-* 키 생략(옛 파일 flat 동일)
/// → 복원이 cascade 기본 위치. 있으면 재시작 시 그 위치·크기·모니터로 복원한다(M3f — §8A.8). frame은 AppKit
/// NSWindow 영역이라 Swift가 읽어 ABI로 넘긴다(Zig는 창 픽셀 좌표를 모른다).
/// 열린 파일 목록을 workspace 파일에 실을 형태로 뽑는다. FP16에서 entry가 Term 소유가 된 뒤로
/// `DockPanel.persistedState`(그룹 순회)는 항상 빈 목록을 돌려주므로, 창구 순회가 유일한 출처다.
/// 도크 자체의 배치(side/size/collapsed/presented)는 여전히 `self.dock`이 든다.
pub fn persistFilePanelState(self: *AppSession, arena: std.mem.Allocator) !dock_panel.PersistedState {
    const count = fileEntryCount(self);
    if (count > dock_panel.max_entries) return error.InvalidPersistedState;
    const entries = try arena.alloc(dock_panel.PersistedEntry, count);
    // 와이어 불변식: entry가 있으면 **정확히 하나**가 active다(workspace.validateDockState). 지금 창의
    // 활성 Term이 터미널이면 활성 파일이 없으므로 첫 파일을 활성으로 싣는다 — 안 그러면 직렬화가
    // 거부되고 Swift가 checkpoint 전체를 포기해 **모든 창**이 다음 실행에서 사라진다(code-review max).
    const active = activeFileEntry(self);
    var active_index: usize = 0;
    var i: usize = 0;
    var it = fileEntries(self);
    while (it.next()) |entry| {
        if (!entry.mode.allowedFor(entry.kind)) return error.InvalidPersistedState;
        if (active != null and entry == active.?) active_index = i;
        entries[i] = .{
            .path = entry.path,
            .kind = entry.kind,
            .mode = entry.mode,
            .active = false,
        };
        i += 1;
    }
    if (count > 0) entries[active_index].active = true;
    return .{
        .side = self.dock.side,
        .size = self.dock.size,
        .collapsed = self.dock.collapsed,
        .presented = self.dock.presented,
        .view = self.dock.view,
        .entries = entries,
    };
}

/// 파일 entry가 들고 있던 live surface를 정리한다. rename 재생성과 "비지원 확장자로 바뀌어 entry를 접는"
/// 경로가 **같은 teardown**을 쓰게 하는 단일 출처다. 이 정리를 빠뜨리면 `onAppSessionSurfaceClosed`가 안 돌아
/// capability·pane grant가 없는 surface에 남고, `focus_owner`가 다음 tick에 파괴될 WKWebView를 계속 가리켜
/// Esc/Enter가 죽은 surface로 포커스를 보낸다(code-review max).
/// kind가 바뀐 rename처럼 **뷰를 새로 만들어야** 하는 경우, 그 파일 Term의 web surface를 새 panel kind로
/// 다시 만든다. surface_id는 재사용하지 않으므로(§3) 새 id가 발급되고, entry 소유는 그대로 옮겨간다.
/// 실패하면 옛 Term이 그대로 남아 호출자가 본 상태가 변하지 않는다.
pub fn rebuildFileTermSurface(self: *AppSession, entry: *dock_panel.Entry) !void {
    for (self.tabs.items, 0..) |tab, tab_index| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items, 0..) |term, term_index| {
                if (term.file_entry != entry) continue;
                const replacement = try web_ops.createWebTerm(self, panelKindForEntryKind(entry.kind));
                // 소유를 먼저 떼어 destroyTerm이 entry·path까지 해제하지 않게 한다.
                term.file_entry = null;
                term_ops.destroyTerm(self, term);
                replacement.file_entry = entry;
                entry.surface_id = replacement.surfaceId();
                pane.terms.items[term_index] = replacement;
                // 대표 surface·leaf rect 재바인딩(닫힌 Term을 가리키던 stale 포인터 방지).
                term_ops.refreshAfterReap(self, tab_index);
                self.metal_dirty = true;
                return;
            }
        }
    }
}

pub fn pinInitialFilePanelIdentity(
    self: *AppSession,
    opened: FileOpenResult,
    identity: ?file_tree.Identity,
) void {
    _ = self;
    const entry = opened.term.file_entry orelse return;
    if (!opened.created or !entry.usesEditorBridge()) return;
    const expected = identity orelse return;
    entry.initial_file_identity_device = expected.device;
    entry.initial_file_identity_inode = expected.inode;
    entry.initial_file_identity_kind = expected.kind;
    entry.initial_file_identity_pending = true;
}

/// 닫힐 scope 안에 **보호 상태의 파일 Term**(dirty·dirty-sync 대기·external conflict·mutation pending·
/// 편집 모드)이 있나. FP16 전에는 파일이 pane 트리 밖이라 일반 close cascade가 파일에 닿을 수 없었고
/// 보호는 `session` scope(⌘Q·창 닫기)에만 필요했다. 이제 파일이 pane 탭이므로 ⌘W·탭바 ✕·close_tab·
/// reap cascade가 전부 파일 Term을 파괴할 수 있어 **모든 scope**가 이 게이트를 지나야 한다 —
/// 안 그러면 미저장 버퍼가 프롬프트 없이 사라진다(code-review max).
/// 에이전트 행 ✕는 **활성과 다른 Term**을 닫을 수 있다 — `scopeHasProtectedFilePanel`의 .term/.pane 가지는
/// 활성 기준이라 그대로 쓰면 "워크스페이스 A의 dirty 파일 때문에 워크스페이스 B의 에이전트 행 ✕가 거부"된다.
/// `closeTargetHasRunningJob`이 같은 함정에 이미 인덱스 경로 override를 둔 것과 동형이다(code-review max).
pub fn closeTargetHasProtectedFilePanel(self: *AppSession, target: PendingClose, scope: CloseScope) bool {
    if (target == .agent_term) {
        const a = target.agent_term;
        if (a.tab < self.tabs.items.len) {
            const t = self.tabs.items[a.tab];
            if (a.pane < t.panes.items.len) {
                const pane = t.panes.items[a.pane];
                switch (scope) {
                    .term => if (a.term < pane.terms.items.len)
                        return termHasProtectedFilePanel(pane.terms.items[a.term]),
                    .pane => return paneHasProtectedFilePanel(pane),
                    else => {},
                }
            }
        }
    }
    return scopeHasProtectedFilePanel(self, scope);
}

pub fn discardPendingDeleteRoot(self: *AppSession, id: u64) void {
    if (takePendingDeleteRoot(self, id)) |root| self.allocator.free(root);
}

pub fn openProjectedFileTreePath(
    self: *AppSession,
    path: []const u8,
    supported: bool,
    expected_leaf_identity: ?file_tree.Identity,
) void {
    const leaf_identity = expected_leaf_identity orelse return;
    const root = self.file_tree.rootCapabilityForPath(path) orelse return;
    var validated = file_tree_backend.openValidatedFileTreeRow(
        self.allocator,
        self.io,
        root.path,
        root.identity,
        path,
        leaf_identity,
    ) orelse return;
    defer validated.deinit(self.io);
    if (supported) {
        const tree_owner: ?FileTreeFocusOwner = switch (self.focus_owner) {
            .file_tree => |owner| owner,
            else => null,
        };
        _ = openFilePanelPathFromValidatedRow(self, path, validated.file, leaf_identity);
        if (tree_owner) |owner| {
            self.focus_owner = .{ .file_tree = owner };
            self.file_tree_focus_pending = true;
            self.workspace_focus_pending = false;
        }
        return;
    }
    // The exact regular-file capability stays open through admission into the native one-shot.
    // Subsequent same-UID namespace mutation after this queue boundary is the external opener's race.
    openFileTreePath(self, path, false);
}

/// background scan 완료를 snapshot에 적용하고 다음 lazy scan을 제출한다. 호출부는 frame tick이지만 blocking
/// path lookup/read는 worker에만 있고, main actor는 queue/snapshot 작업과 result descriptor close만 수행한다.
/// ET-CWD(docs/file-explorer.md §1): 탐색기 root를 **활성 pane 터미널의 cwd와 같게** 유지한다.
///
/// **`cd` 하면 그 폴더가 트리 최상위가 된다**(2026-08-31 사용자 결정). 규칙은 그것 하나다 — 저장소 루트로
/// 올려 세우지도, 홈이나 `/`를 예외로 빼지도 않는다. 그 앞의 두 판(root를 안 건드리는 reveal, root 밖일
/// 때만 저장소 루트로 교체)은 홈이 root가 되는 순간 홈 아래 전부가 "root 안"이 되어 **거기서 빠져나오지
/// 못하는** 상태를 만들었다. 새 탭이 홈에서 뜨는 것만으로 그 상태에 들어갔다.
///
/// 정책 넷을 여기서 전부 집행한다: 도크가 보일 때만 / 활성 pane·활성 Term의 cwd만 / cwd가 없으면 직전
/// 값 유지 / 변화 시에만(관측은 폴링이라 같은 값이 매 tick 온다).
/// **원격 탐색기 상태**(RF3a — [계획](../../../docs/plans/remote-file-tree.md) §10.4). 로컬 트리를
/// 대체하지 않고 **얹힌다**: 별도 `Tree` 인스턴스라 로컬의 접힘·스크롤·영속이 안 다치고, 경로가 같은
/// 두 기계가 한 모델 안에서 충돌할 일도 없다(§2.1 — 경로는 두 기계 사이에서 키가 아니다).
///
/// v1 은 **비영속**이다: 재시작하면 따라가기가 원격 cwd 에서 다시 세운다(원격 SCM 과 같은 흐름).
/// `dock-tree-roots` 를 (host, path) 쌍으로 넓히는 마이그레이션은 명시적 원격 root 고정이 생길 때
/// 함께 간다 — 지금 넓히면 아무도 안 쓰는 포맷 갈래가 생긴다.
/// 원격 감시자의 트리거를 받아 **펼쳐 둔 디렉터리를 다시 읽는다**(RF5a — [계획](../../../docs/plans/remote-file-tree.md) ③).
///
/// 감시자는 `change` 한 줄만 낸다 — 어디가 바뀌었는지 안 싣는다. 그래서 무효화가 거칠고, 그 거칢을
/// **모델이 유계로 만든다**: 펼친 것만 넣고(`invalidateExpanded`), 큐가 중복을 제거하며, 발사는 원격
/// 슬롯 상한이 잡는다. 예약만 하고 실제 왕복은 `updateFileTree` 의 원격 펌프가 다음 tick 에 한다 —
/// 여기서 쏘면 상한을 두 곳이 나눠 갖게 된다.
pub fn invalidateRemoteExplorerExpanded(self: *AppSession) void {
    if (comptime builtin.os.tag != .macos) return;
    if (!self.remote_explorer.active) return;
    const any = self.remote_explorer.tree.invalidateExpanded() catch return;
    if (!any) return;
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

pub const RemoteExplorer = struct {
    tree: file_tree.Tree,
    active: bool = false,
    dest: std.ArrayListUnmanaged(u8) = .empty,
    /// 이번 tick 의 control socket — follow 가 매 tick 갱신한다(`maru ssh` 가 끊기면 사라지는 값이라
    /// 굳혀 두면 죽은 소켓으로 계속 쏜다).
    ctl: std.ArrayListUnmanaged(u8) = .empty,
    root: std.ArrayListUnmanaged(u8) = .empty,
    /// 「원격이라 못 읽는다」(§2.5)의 기계 사유. null 이면 문제 없음. 표시는 i18n 키가 하고 이 값은
    /// 진단용이다 — 조용한 실패가 §2.5 가 금지한 그것이라 버리지 않는다.
    err: ?[]u8 = null,

    pub fn deinit(self: *RemoteExplorer, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        self.dest.deinit(allocator);
        self.ctl.deinit(allocator);
        self.root.deinit(allocator);
        if (self.err) |e| allocator.free(e);
    }
};

/// 탐색기가 지금 **원격 모델을 그리고 있는가.** 상호작용 펜스(열기·변경·접기)가 전부 이 판정
/// 하나를 본다 — 판정이 흩어지면 §2.4 의 새는 길이 된다.
pub fn explorerRemoteActive(self: *const AppSession) bool {
    return self.remote_explorer.active;
}

fn setRemoteExplorerError(self: *AppSession, reason: ?[]const u8) void {
    const re = &self.remote_explorer;
    if (re.err) |old| self.allocator.free(old);
    re.err = if (reason) |r| self.allocator.dupe(u8, r) catch null else null;
}

/// 원격 파일 읽기 작업(RF4). 한 번에 하나 — 파일 열기는 사용자 클릭 단발이라 큐가 필요 없고,
/// 슬롯이 차 있으면 안내로 거절한다(조용한 드롭이 아니라 — §2.5).
pub const RemoteFileJob = struct {
    session: *AppSession,
    /// 원격 절대 경로(작업 소유).
    path: []u8,
    dest: []u8,
    ctl: []u8,
    /// 행이 판정한 «편집기가 여는 종류인가»(확장자 축) — 결말이 로컬 열기와 같은 분기를 타야
    /// 원격 .png 가 텍스트로 열리지 않는다(적대적 검증 C).
    supported: bool,
};

pub const RemoteFileOutcome = struct {
    path: []u8,
    bytes: []u8,
    exit_code: c_int,
    supported: bool = true,
};

/// 원격 트리의 파일 행을 **읽기 전용으로** 연다(RF4 — [계획](../../../docs/plans/remote-file-tree.md) §10.6).
///
/// 흐름: 백그라운드 워커가 `buildRemoteFileRead`(인용·상한 SSOT — RS3 의 그 명령) argv 를
/// `runArgvCapped` 로 실행 → tick 이 `finishRemoteFileOpen` 으로 결말을 낸다. 내용은 **로컬 임시
/// 미러**(`$HOME/.cache/maru/remote-view/…`)에 내려 기존 열기 파이프라인(신원 pin 포함)을 그대로
/// 태우고, 문서를 read_only 로 만든다 — 저장 축이 없는 것이 v1 의 계약이다(⑤).
pub fn openRemoteFileReadOnly(self: *AppSession, remote_path: []const u8, supported: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    const re = &self.remote_explorer;
    if (!re.active or re.ctl.items.len == 0) {
        // 낡은 원격 행(연결이 막 죽은 창)에서의 클릭이다 — 침묵이 아니라 «못 읽는다» 다(§2.5).
        self.showNoticeKey(.fp_remote_file_read_failed);
        return;
    }
    if (self.remote_file_open_inflight) {
        self.showNoticeKey(.fp_remote_file_busy);
        return;
    }
    const job = self.allocator.create(RemoteFileJob) catch return;
    job.* = .{
        .session = self,
        .supported = supported,
        .path = self.allocator.dupe(u8, remote_path) catch {
            self.allocator.destroy(job);
            return;
        },
        .dest = self.allocator.dupe(u8, re.dest.items) catch {
            self.allocator.free(job.path);
            self.allocator.destroy(job);
            return;
        },
        .ctl = self.allocator.dupe(u8, re.ctl.items) catch {
            self.allocator.free(job.dest);
            self.allocator.free(job.path);
            self.allocator.destroy(job);
            return;
        },
    };
    self.remote_file_open_inflight = true;
    const thread = std.Thread.spawn(.{}, remoteFileWorker, .{job}) catch {
        self.remote_file_open_inflight = false;
        self.allocator.free(job.ctl);
        self.allocator.free(job.dest);
        self.allocator.free(job.path);
        self.allocator.destroy(job);
        self.showNoticeKey(.fp_remote_file_read_failed);
        return;
    };
    thread.detach();
}

/// 백그라운드: 원격 파일 바이트를 받아 결과 슬롯에 둔다. **std.Io 를 안 만진다**(ssh_upload 규율).
fn remoteFileWorker(job: *RemoteFileJob) void {
    const self = job.session;
    const allocator = self.allocator;
    defer {
        allocator.free(job.ctl);
        allocator.free(job.dest);
        allocator.destroy(job);
    }
    var bytes: []u8 = &.{};
    var code: c_int = -1;
    build: {
        var argv_buf: [git_command.max_argv][]const u8 = undefined;
        var cmd_buf: [remote_shell.max_command_bytes]u8 = undefined;
        const argv = git_command.buildRemoteFileRead(job.path, .{
            .dest = job.dest,
            .control_path = job.ctl,
        }, &argv_buf, &cmd_buf) orelse break :build;
        // 상한+1 로 읽어 「정확히 상한」과 「상한에서 잘림」을 가른다 — head 는 상한만큼 주고 끝나므로
        // len >= max 가 곧 잘림 신호다(RS3a 가 diff 에서 같은 판정을 쓴다).
        code = ssh_upload.runArgvCapped(allocator, argv, git_command.max_remote_file_bytes + 1, &bytes) catch -1;
    }
    self.remote_file_mutex.lockUncancelable(self.io);
    self.remote_file_outcome = .{ .path = job.path, .bytes = bytes, .exit_code = code, .supported = job.supported };
    self.remote_file_mutex.unlock(self.io);
}

/// tick 이 워커의 결말을 낸다(드레인). **판정자가 직접 부르는 제품 함수**이기도 하다 — 전송 없이
/// 「결말→미러→열기→read_only」 수직을 실물로 태운다(RF3a 의 pushResultForTest 와 같은 결이되,
/// 이쪽은 제품 경로 그 자체라 test-only 표식도 필요 없다).
pub fn finishRemoteFileOpen(self: *AppSession, outcome: RemoteFileOutcome) void {
    defer {
        self.allocator.free(outcome.path);
        self.allocator.free(outcome.bytes);
    }
    self.remote_file_open_inflight = false;
    if (outcome.exit_code != 0) {
        self.showNoticeKey(.fp_remote_file_read_failed);
        return;
    }
    if (outcome.bytes.len >= git_command.max_remote_file_bytes) {
        // ⑤ 확정: 잘린 파일은 **열지 않는다** — 잘린 내용이 온전한 척 뜨는 것이 최악이고, 장차 저장
        // 축이 열리면 잘린 저장이 원격 파일을 자른다.
        self.showNoticeKey(.fp_remote_file_too_large);
        return;
    }
    const mirror = writeRemoteMirror(self, outcome.path, outcome.bytes) orelse {
        self.showNoticeKey(.fp_remote_file_read_failed);
        return;
    };
    defer self.allocator.free(mirror);
    openFileTreePath(self, mirror, outcome.supported);
    // read_only 는 여기서 다시 세우지 않는다 — 근거가 경로 접두(`remoteViewPathIsReadOnly`)라 문서
    // 열기 지점 한 곳이 소유한다(두 벌이면 한쪽만 고쳐진다).
}

/// 원격 바이트를 로컬 임시 미러에 내린다. 반환 경로는 호출자 소유.
///
/// 자리: `$HOME/.cache/maru/remote-view/<dest·부모 해시>/<basename>` — basename 을 지켜 탭·트리 라벨이
/// 원격과 같게 보이고, 해시 디렉터리가 「다른 기계·다른 폴더의 같은 이름」 충돌을 막는다. wire 가
/// `/`·NUL 없는 이름만 통과시키므로(UnsafeName) basename 은 파일명으로 안전하다.
/// 미러 루트. **`/tmp` 가 아니다**(적대적 검증 1 회차) — `/tmp` 는 모두가 쓰는 곳이라 예측 가능한
/// 이름은 디렉터리 선점·심볼릭 링크 공격면이 된다(다른 로컬 사용자가 그 이름을 링크로 만들어 두면
/// 우리 write 가 남이 고른 자리로 간다). `$HOME/.cache/maru` 는 0700 홈 아래의 maru 전용 디렉터리라
/// 그 면이 없다(업로드·감시자 설치와 같은 자리 규율 — §5·§9.5).
pub const remote_view_subdir = ".cache/maru/remote-view";

/// 이 경로가 원격 미러인가 — **경로 접두가 곧 read_only 근거다**(적대적 검증 2 회차). 문서 열기가
/// 이 판정 하나를 지나므로, 리로드·재열기·workspace 복원 어느 길로 열려도 원격 미러는 읽기 전용이다.
/// entry 플래그로 들면 그 세 길마다 배선이 필요하고 하나만 빠져도 편집이 열린다.
pub fn remoteViewPathIsReadOnly(path: []const u8) bool {
    const home = trimmedHome() orelse return false;
    return remoteViewPathIsReadOnlyForHome(path, home);
}

/// 순수 판정(판정자용 분리). ⚠️ `home` 은 **꼬리 `/` 를 뗀** 값이어야 한다 — `trimmedHome` 이 그
/// 계약의 유일한 공급자다(적대적 검증 A: `HOME=/Users/x/` 이면 접두 판정이 자기 미러를 못 알아봐
/// read_only 가 조용히 풀린다 — `controlSocketPath` 가 같은 함정을 trimEnd 로 막은 선례).
pub fn remoteViewPathIsReadOnlyForHome(path: []const u8, home: []const u8) bool {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return false;
    const rest = path[home.len..];
    if (rest.len == 0 or rest[0] != '/') return false;
    return std.mem.startsWith(u8, rest[1..], remote_view_subdir ++ "/");
}

/// HOME 을 꼬리 `/` 없이 — 판정과 미러 쓰기가 **같은 철자**를 봐야 한다(두 벌이면 쓴 쪽은 되고
/// 읽기 전용만 빠지는, 눈에 안 보이는 갈림이 된다).
fn trimmedHome() ?[]const u8 {
    const home_z = std.c.getenv("HOME") orelse return null;
    const home = std.mem.trimEnd(u8, std.mem.span(home_z), "/");
    return if (home.len == 0) null else home;
}

fn writeRemoteMirror(self: *AppSession, remote_path: []const u8, bytes: []const u8) ?[]u8 {
    const basename = std.fs.path.basename(remote_path);
    if (basename.len == 0) return null;
    const parent = std.fs.path.dirname(remote_path) orelse "/";
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(self.remote_explorer.dest.items);
    hasher.update(&.{0});
    hasher.update(parent);
    const home = trimmedHome() orelse return null;
    const dir_path = std.fmt.allocPrint(self.allocator, "{s}/" ++ remote_view_subdir ++ "/{x}", .{
        home, hasher.final(),
    }) catch return null;
    defer self.allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(self.io, dir_path) catch return null;
    const full = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, basename }) catch return null;
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = full, .data = bytes }) catch {
        self.allocator.free(full);
        return null;
    };
    return full;
}

/// 활성 pane 이 원격이면 그 기계의 cwd 를 원격 트리 root 로 세운다(열린 질문 ② = ㉮, 로컬과 같은
/// 규칙 — 근거는 2026-08-31 「root 는 cwd 폴더 그 자체」와 §3.5 「두 뷰가 같은 곳을 본다」다.
/// SCM 도크는 RS6 부터 원격 cwd 를 따라가므로 트리만 안 따라가면 그 불변식이 깨진다).
///
/// 판정은 `remoteScmTarget` 재사용이다 — 목적지·**살아 있는** control socket·원격 cwd 를 한 번에
/// 주고, 그 판정이 SCM 과 같아야 「도크의 두 뷰가 다른 기계를 보는」 상태가 원리적으로 안 생긴다.
fn followRemoteExplorer(self: *AppSession) void {
    if (comptime builtin.os.tag != .macos) return;
    // 로컬 따라가기와 같은 가시성 게이트(§1.1) + 탐색기 뷰 한정 — 원격 왕복은 로컬 스캔보다 비싸다.
    if (!dock_ops.dockVisible(self) or self.dock.view != .explorer) return;
    var dest_buf: [git_ops.max_remote_dest_bytes]u8 = undefined;
    var ctl_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = git_ops.remoteScmTarget(self, &dest_buf, &ctl_buf, &cwd_buf) orelse {
        deactivateRemoteExplorer(self);
        return;
    };
    // 헬퍼 설치(판 3 이 `list` 를 보증한다) — RW 펌프가 그 축의 단일 소유자라 여기서는 **재사용**만
    // 한다(멱등: 이미 돌거나 답이 있으면 무동작). drain 도 같이 — SCM 뷰 펌프는 소스컨트롤 뷰에서만
    // 돌아서, 탐색기만 쓰는 세션은 여기가 유일한 drain 자리다.
    if (self.remote_watch.install == .unknown) self.beginWatchInstall(target.ctl, target.dest);
    self.drainWatchInstall();
    applyRemoteExplorerTarget(self, target.dest, target.ctl, target.cwd);
}

/// 원격 pane 이 아니게 되면(로컬 복귀·소켓 사망) 원격 모델을 화면에서 내린다. 모델 자체는 남는다 —
/// 같은 자리로 돌아오면 접힘이 살아 있는 편이 낫고, 다른 root 로 가면 replace 가 어차피 버린다.
pub fn deactivateRemoteExplorer(self: *AppSession) void {
    const re = &self.remote_explorer;
    if (!re.active) return;
    re.active = false;
    self.file_tree_rows_dirty = true;
}

/// follow 가 고른 원격 대상을 모델에 적용한다. follow(가시성 게이트·판정·설치)와 적용을 가른 것은
/// 판정자 때문이다 — `remoteScmTarget` 은 살아 있는 control socket 을 요구해 단위에서 못 세우고,
/// 적용·펌프·오류 표시의 수직은 이 함수부터 실물로 태울 수 있다(RS6 의 `remoteCwd` 분리와 같은 결).
pub fn applyRemoteExplorerTarget(self: *AppSession, dest: []const u8, ctl: []const u8, cwd: []const u8) void {
    const re = &self.remote_explorer;
    // control socket 은 매 tick 갱신 — 끊겼다 다시 붙으면 경로가 그대로여도 내용이 새 소켓이다.
    // ⚠️ 어떤 실패든 **활성 채로 두지 않는다**(적대적 검증 1 회차): 빈/낡은 ctl 로 활성이 남으면
    // 펌프가 `ssh -S ''` 를 띄우고, ssh 는 소켓이 없으면 **직접 접속으로 폴백**한다 — 비밀번호를
    // 묻는 자식이 붙박인다(§2.2 ⑸ 가 remoteScmTarget 에서 막은 바로 그것).
    re.ctl.clearRetainingCapacity();
    re.ctl.appendSlice(self.allocator, ctl) catch {
        deactivateRemoteExplorer(self);
        return;
    };

    const same_dest = std.mem.eql(u8, re.dest.items, dest);
    const same_root = std.mem.eql(u8, re.root.items, cwd);
    if (re.active and same_dest and same_root) return; // 바뀔 때만(§1 정책 ⑵)

    re.dest.clearRetainingCapacity();
    re.dest.appendSlice(self.allocator, dest) catch {
        deactivateRemoteExplorer(self);
        return;
    };
    re.root.clearRetainingCapacity();
    re.root.appendSlice(self.allocator, cwd) catch {
        deactivateRemoteExplorer(self);
        return;
    };
    // 원격 root 는 로컬 검증 파이프라인(realpath·capability)을 **못 탄다**(§2.2 — 갈래는 둘이다).
    // 이 갈래의 증거는 첫 목록이 가져오는 D 신원이고, `applySnapshotWithIdentity` 가 그것을 pin 한다.
    const roots = [_][]const u8{cwd};
    re.tree.replaceExplicitRoots(&roots) catch {
        setRemoteExplorerError(self, "root replace failed");
        deactivateRemoteExplorer(self);
        return;
    };
    setRemoteExplorerError(self, null);
    re.active = true;
    self.file_tree_rows_dirty = true;
}

pub fn followActiveTerminalCwd(self: *AppSession) void {
    if (!dock_ops.dockVisible(self)) return;
    if (self.tabs.items.len == 0) return;
    // cwd 해석은 **소스 컨트롤 뷰와 같은 지점**(`git_ops.activeTerminalCwd`)을 쓴다. 축이 갈리면 트리가 선
    // 자리와 목록이 보는 저장소가 서로 다른 곳을 가리킨다. 그 함수가 observation 갱신(OSC 7)과 커널 폴백을
    // 둘 다 맡으므로, bash/fish나 claude·codex가 떠 있어 OSC 7이 없는 터미널에서도 따라가기가 동작한다.
    // 파일·브라우저 탭은 cwd가 없어 null이고 → **직전 값 유지**(문서를 보다 터미널로 돌아왔을 때 리셋되면 안 된다).
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = git_ops.activeTerminalCwd(self, &cwd_buf) orelse return;
    if (self.file_tree_followed_cwd) |prev| if (std.mem.eql(u8, prev, cwd)) return;
    // **이미 그 자리면 아무것도 하지 않는다.** 이 가드가 없으면 복원된 root가 마침 터미널 cwd와 같을 때
    // 시작하자마자 재스캔과 watcher 재등록이 한 번 헛돈다 — 사용자에게는 트리가 이유 없이 깜빡이는 것으로
    // 보인다. 기억만 남겨 다음 tick부터 조용하게 만든다.
    if (!self.file_tree.rootIsExactly(cwd) and !followRootSwitch(self, cwd)) {
        // 검증 슬롯이 차 있거나 지금 트리를 보고 있지 않아 **못 걸었다**. 여기서 `followed_cwd`를 갱신하면
        // 이 cwd는 "따라간 것"으로 표시돼 다음 `cd` 전까지 영영 재시도되지 않는다 — 시작 직후 복원 검증이
        // 도는 동안 첫 따라가기가 통째로 사라지는 것이 그 경로다. 갱신하지 않고 두면 다음 tick이 다시 시도한다.
        //
        // **scroll pending은 끄고 나간다.** 살려 두면 지금 cwd와 무관한 **옛 대상으로 스크롤**한다.
        self.file_tree_follow_scroll_pending = false;
        return;
    }
    // 여기서부터는 이 cwd를 "따라간 것"으로 기록한다 — 그때 처음 복사한다(매 tick dupe+free를 피한다).
    const owned = self.allocator.dupe(u8, cwd) catch return;
    if (self.file_tree_followed_cwd) |prev| self.allocator.free(prev);
    self.file_tree_followed_cwd = owned;
    // 교체는 비동기라 이 tick의 트리는 아직 옛 root다. 그래도 pending을 세워 두면 새 root가 커밋돼 행이
    // 다시 투영될 때 `scrollFileTreeToFollowedCwd`가 그 행을 잡는다(정책 4 — 이미 보이면 안 뺏는다).
    self.file_tree_rows_dirty = true;
    self.file_tree_follow_scroll_pending = true;
}

/// 활성 터미널이 **다른 폴더로 갔을 때** 탐색기 root를 그쪽으로 갈아끼운다(file-explorer.md §1).
///
/// **무엇을 root로 세우나**: **cwd 폴더 그 자체**다. 2026-08-11~08-31 사이에는 그 cwd를 품은 저장소 루트로
/// 올려 세웠는데, 저장소가 아닌 곳(홈이 대표적이다)에서는 어차피 cwd로 떨어지면서 "root 안이면 그대로 둔다"
/// 규칙과 겹쳐 홈을 빠져나올 수 없는 상태를 만들었다. 규칙을 하나로 줄여 그 상호작용을 없앤다.
///
/// **제품 picker와 같은 경로로 보낸다**(`provideFileTreeRootPick` + `.replace`). 여기서 `replaceExplicitRoots`를
/// 직접 부르면 realpath·identity pinning·watcher union 재구성·영속이 전부 빠진 반쪽 전환이 된다 — 그 배관은
/// 이미 root 검증 파이프라인이 갖고 있다. 원격(`maru ssh`)이나 지워진 경로가 걸러지는 자리도 거기다.
///
/// **in-flight면 건너뛴다.** 검증은 비동기라 tick마다 다시 밀어 넣으면 요청이 쌓인다. 호출자가 `followed_cwd`를
/// 이미 갱신했으므로 같은 cwd로는 다시 오지 않고, 다음 `cd`가 자연히 재시도가 된다.
///
/// **반환값은 "제출을 시도했다"가 아니라 "검증이 실제로 걸렸다"다.** `provideFileTreeRootPick`은 backend busy·
/// 할당 실패·request id 소진에서 검증을 세우지 않고 조용히 빠져나온다(자동 경로라 알림도 없다). 그때 true를
/// 돌려주면 호출자가 이 cwd를 "따라간 것"으로 표시해 **다음 `cd` 전까지 영영 재시도되지 않는다** — §1.1이
/// mutation busy에 대해 정한 규율과 같은 상황인데 실패 지점만 한 단계 안쪽인 것이다(적대적 검증 2회차).
fn followRootSwitch(self: *AppSession, cwd: []const u8) bool {
    // **탐색기를 보고 있을 때만 바꾼다.** 도크는 보이지만 view가 소스 컨트롤·에이전트면 트리는 화면에
    // 없다. 그때 root를 갈면 **보이지도 않는 트리**의 접힘·스크롤을 버리고 `dock-tree-roots` 영속까지
    // 덮는다 — 사용자가 탐색기를 열어 본 적도 없는데. 여기서 false를 돌려주면 `followed_cwd`가 갱신되지
    // 않아, 탐색기로 돌아온 tick이 자연히 전환한다.
    if (self.dock.view != .explorer) return false;
    // **사용자 picker와 같은 busy 판정을 쓴다.** 손으로 세 조건만 적었더니 파일 mutation(이름 변경·삭제·
    // 휴지통 롤백·수동 복구)이 빠져, 그 도중에도 root가 갈릴 수 있었다 — 문서가 "그때는 replace/add/remove
    // commit을 거부한다"고 정한 바로 그 상황이다(file-explorer.md §2). 판정을 재구현하지 않고 그대로 쓴다.
    if (fileTreeNamespaceMutationBusy(self)) return false;
    self.file_tree_root_picker_inflight = .replace;
    self.file_tree_root_auto_follow = true;
    provideFileTreeRootPick(self, cwd);
    return self.file_tree_root_validation != null;
}

/// 이 Term이 **browser 웹 패널**인가(파일 패널 web Term은 제외). browser 전용 기능(nav 단축키·주소창 밴드·
/// 터미널 링크 착지·닫기 확인)이 공유하는 **유일한 판정**이다. 인라인 복사가 늘면 `web_panel_kind`가 늘어날 때
/// 한 곳을 놓쳐 "안 보이는 WKWebView에 링크가 로드되는" 류의 버그가 난다(코드리뷰 지적) — 그래서 이 함수 밖에서
/// `web_panel_kind == .browser`를 직접 비교하지 않는다.
///
/// **의도적 예외 하나**: WKWebView **trust config 파생**(control-plane §8.1)은 "browser 기능인가"가 아니라
/// "격리 config를 쓰는가"를 묻는 별개 질문이라 이 술어를 쓰지 않는다. 파일 패널의 `.html`/`.pdf`도 거기서는
/// untrusted가 맞다.
///
/// **FP16 확장 지점**(docs/file-panel.md §8): 파일 entry가 `Term`으로 옮겨오면 `.html`/`.pdf` 파일 Term이
/// 격리 config 때문에 `web_panel_kind == .browser`를 갖게 된다. 그때 이 술어에 "파일 entry 없음" 조건을 더하면
/// 주소창·nav 단축키가 로컬 HTML 파일 뷰에 잘못 걸리는 것을 **한 곳에서** 막는다. 지금 통합해 두는 이유가 그것이다.
/// 이 Term이 **browser 웹 패널**인가(파일 패널 web Term은 제외). browser 전용 기능(nav 단축키·주소창 밴드·
/// 터미널 링크 착지·닫기 확인)이 공유하는 **유일한 판정**이다. 인라인 복사가 늘면 `web_panel_kind`가 늘어날 때
/// 한 곳을 놓쳐 "안 보이는 WKWebView에 링크가 로드되는" 류의 버그가 난다(코드리뷰 지적) — 그래서 이 함수 밖에서
/// `web_panel_kind == .browser`를 직접 비교하지 않는다.
///
/// **의도적 예외 하나**: WKWebView **trust config 파생**(control-plane §8.1)은 "browser 기능인가"가 아니라
/// "격리 config를 쓰는가"를 묻는 별개 질문이라 이 술어를 쓰지 않는다. 파일 패널의 `.html`/`.pdf`도 거기서는
/// untrusted가 맞다.
///
/// **FP16 확장 지점**(docs/file-panel.md §8): 파일 entry가 `Term`으로 옮겨오면 `.html`/`.pdf` 파일 Term이
/// 격리 config 때문에 `web_panel_kind == .browser`를 갖게 된다. 그때 이 술어에 "파일 entry 없음" 조건을 더하면
/// 주소창·nav 단축키가 로컬 HTML 파일 뷰에 잘못 걸리는 것을 **한 곳에서** 막는다. 지금 통합해 두는 이유가 그것이다.
/// 이 파일 kind가 **격리 config**(filePanelKind=2, `loadFileURL`)를 쓰는가. 신뢰 shell(=1)과 갈리는
/// 유일한 축이며 Swift의 `WKWebViewConfiguration` 선택과 같은 판정이다(app_host_abi.zig `file_panel_entry`).
/// rename이 뷰를 다시 세워야 하는지도 이 값으로 정한다(FP16 §1 ⑶).
pub fn filePanelKindIsIsolated(kind: dock_panel.EntryKind) bool {
    // 같은 분할이 세 곳에 있다: 여기, `maru_macos_app_session_file_panel_entry`(app_host_abi.zig, 1/2 반환),
    // `collectWebSurfaces`(.markdown/.browser 매핑). 셋 다 exhaustive switch라 **새 EntryKind를 더하면**
    // 컴파일러가 세 곳을 모두 잡아 준다. 반대로 **기존 kind의 소속만 한 곳에서 바꾸면** 컴파일은 통과한 채
    // trust config와 재생성 판정이 갈라지므로, 이 분할을 옮길 때는 세 곳을 함께 고친다(code-review max).
    return switch (kind) {
        // FP14b: image도 격리 loadFileURL(WebKit image document + 주입 뷰어 스크립트) — 신뢰 shell로
        // 바이트를 옮기던 readSelfImage 경로를 걷어냈다(§2.2 "왜 FP14의 신뢰 shell을 걷어냈나").
        .html, .image, .media, .pdf => true,
        // diff는 신뢰 shell(=1)이다 — 격리 loadFileURL로는 두 문서를 나란히 못 세우고 브리지도 못 쓴다.
        .markdown, .text, .svg, .diff => false,
    };
}

/// nonblocking으로 연 file descriptor에서 kind/크기 확인과 읽기를 끝내 경로 검사와 사용 사이의 재-open 경쟁을 없앤다.
pub fn readOpenedFile(self: *AppSession, gpa: std.mem.Allocator, file: std.Io.File) FilePanelReadError![]u8 {
    const stat = file.stat(self.io) catch return error.NotFound;
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > file_panel_bridge.max_file_bytes) return error.TooLarge;

    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(self.io, &read_buf);
    const bytes = reader.interface.allocRemaining(
        gpa,
        .limited(file_panel_bridge.max_file_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.TooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    if (bytes.len > file_panel_bridge.max_file_bytes) {
        gpa.free(bytes);
        return error.TooLarge;
    }
    return bytes;
}

pub fn removeDeletedDockEntries(self: *AppSession, removed_path: []const u8) FileTreeDockRemovalStats {
    // Trash completion은 AppKit main actor에서 오므로 entry마다 tree를 처음부터 다시 찾지 않는다. group tree는
    // bulk commit 끝까지 그대로 두고 각 entry를 정확히 한 번 방문한 뒤 empty leaf를 한 번만 정규화한다.
    var stats: FileTreeDockRemovalStats = .{};
    var removed_surfaces: DeletedSurfaceSet = .{};
    var removed_any = false;
    var removed_input_owner = false;
    var removed_tree_restore = false;
    // FP16: 대상 entry를 **먼저 수집**한 뒤 처리한다 — close가 pane 트리를 변형하므로 순회 중에 닫으면
    // 이터레이터가 어긋난다. 창당 max_entries가 수집 버퍼의 bound다.
    var doomed: [dock_panel.max_entries]dock_panel.Entry = undefined;
    var doomed_len: usize = 0;
    {
        var scan = fileEntries(self);
        while (scan.next()) |candidate| {
            stats.entry_visits += 1;
            if (!file_tree_mutation.pathWithin(candidate.path, removed_path)) continue;
            if (doomed_len >= doomed.len) break;
            doomed[doomed_len] = candidate.*;
            doomed_len += 1;
        }
    }
    {
        for (doomed[0..doomed_len]) |entry| {
            removed_any = true;

            const pending_owned = if (self.pending_dock_focus) |pending| pending.entry_id == entry.id else false;
            const entry_owned = switch (self.focus_owner) {
                .dock_pending => pending_owned, // FP16: group 개념이 사라져 pending 소유만 본다
                .workspace, .file_tree => fileSurfaceOwnsInput(self, entry.surface_id),
            };
            if (entry_owned) removed_input_owner = true;
            if (fileTreeFocused(self) and self.focus_owner.file_tree.restore_surface == entry.surface_id and entry.surface_id != 0)
                removed_tree_restore = true;

            if (entry.surface_id != 0) {
                removed_surfaces.insert(entry.surface_id);
                if (self.pending_file_panel_close != null and self.pending_file_panel_close.?.surface_id == entry.surface_id)
                    clearFilePanelCloseWithoutUnlock(self);
            } else if (pending_owned) {
                dock_ops.cancelPendingDockFocus(self);
            }
        }
    }
    if (!removed_any) return stats;

    removeFilePanelQueuedActionsBulk(self, &removed_surfaces, &stats);
    // queued one-shots를 먼저 없앤 뒤 native callback을 낸다. callback이 browser control completion을
    // 동기 직렬화하더라도 retired surface action을 다시 관측할 수 없다.
    // FP16: notifySurfaceClosed는 destroyTerm이 낸다 — 여기서 따로 부르면 같은 surface가 두 번 통지된다.
    // teardown은 queued one-shot 제거 **뒤**라야 retired surface action을 다시 관측하지 않는다.
    for (doomed[0..doomed_len]) |entry| {
        if (fileEntryForId(self, entry.id)) |live| _ = closeFileTermForEntry(self, live); // Term이 entry·path 소유를 회수한다(FP16)
    }

    if (removed_input_owner) {
        if (fileEntryCount(self) == 0) {
            self.focusWorkspaceInput();
            self.workspace_focus_pending = true;
        } else {
            // FP16: 파일이 pane 탭이라 "다음 도크 entry로 승계"가 아니라 pane의 active_term 승계가
            // 이미 일어났다(closeTermAt). 입력은 그 pane(=workspace)으로 간다.
            self.focusWorkspaceInput();
            self.workspace_focus_pending = true;
        }
    } else if (removed_tree_restore and fileTreeFocused(self)) {
        self.focus_owner = .{ .file_tree = .{ .restore_surface = null } };
        self.file_tree_restore_surface_pending = null;
    }
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
    return stats;
}

pub fn beginFileTreeMutationEditorLocks(self: *AppSession, mutation_id: u64, source: []const u8) !bool {
    var needed: usize = 0;
    var entry_it12 = fileEntries(self);
    while (entry_it12.next()) |entry| {
        if (file_tree_mutation.pathWithin(entry.path, source) and entry.mode.isEditable()) {
            if (entry.surface_id == 0) return error.SurfaceMissing;
            needed += 1;
        }
    }
    if (needed == 0) return false;
    if (self.file_tree_mutation_editor_locks_len + needed > self.file_tree_mutation_editor_locks.len or
        self.file_panel_dirty_sync_actions_len + needed > self.file_panel_dirty_sync_actions.len or
        self.file_panel_close_request_id + needed > max_file_panel_close_request_id) return error.Capacity;

    var entry_it13 = fileEntries(self);
    while (entry_it13.next()) |entry| {
        if (!file_tree_mutation.pathWithin(entry.path, source) or !entry.mode.isEditable()) continue;
        self.file_panel_close_request_id += 1;
        const request_id = self.file_panel_close_request_id;
        self.file_tree_mutation_editor_locks[self.file_tree_mutation_editor_locks_len] = .{
            .mutation_id = mutation_id,
            .surface_id = entry.surface_id,
            .request_id = request_id,
        };
        self.file_tree_mutation_editor_locks_len += 1;
        entry.dirty_sync_pending = true;
        queueFilePanelDirtySyncAction(self, entry.surface_id, request_id);
    }
    self.file_tree_rows_dirty = true;
    refreshFileTreeWatchRoots(self) catch {};
    self.metal_dirty = true;
    return true;
}

pub fn paneHasProtectedFilePanel(pane: *Pane) bool {
    for (pane.terms.items) |t| if (termHasProtectedFilePanel(t)) return true;
    return false;
}

pub fn activateFileTreeRow(self: *AppSession, index: usize) void {
    if (index >= self.file_tree_rows.items.len) return;
    const row = self.file_tree_rows.items[index];
    // **원격 펜스**(RF3a — §2.4). 키는 «지금 모드» 가 아니라 **이 행들을 쓴 출처**다(적대적 검증
    // 2 회차 — 원격이 내려간 뒤 재빌드 전의 낡은 원격 행이 로컬 갈래로 들어가는 창을 닫는다).
    // 접기/펼치기는 원격 모델로 가고, 파일 열기는 RF4 전까지 **안내로 거절**한다(§2.5).
    if (self.file_tree_rows_remote) {
        switch (row) {
            .root => |v| _ = self.remote_explorer.tree.toggleDirectory(v.path) catch false,
            .directory => |v| _ = self.remote_explorer.tree.toggleDirectory(v.path) catch false,
            .file => |v| openRemoteFileReadOnly(self, v.path, v.supported),
            .recent_file => {}, // 원격 모델은 recent 를 만들지 않는다 — 오면 무동작이 정직하다

            .recent_header, .empty => {},
        }
        self.file_tree_rows_dirty = true;
        updateFileTree(self) catch {};
        self.metal_dirty = true;
        return;
    }
    switch (row) {
        .recent_header => self.file_tree.toggleRecent(),
        .root => |v| _ = self.file_tree.toggleDirectory(v.path) catch false,
        .directory => |v| _ = self.file_tree.toggleDirectory(v.path) catch false,
        .recent_file => |v| openFileTreePath(self, v.path, v.supported),
        .file => |v| openProjectedFileTreePath(self, v.path, v.supported, v.identity),
        .empty => {},
    }
    self.file_tree_rows_dirty = true;
    updateFileTree(self) catch {};
    self.metal_dirty = true;
}

pub fn finishOpenFilePanel(self: *AppSession, opened: FileOpenResult) FilePanelOpenPathResult {
    // 떠나게 된 직전 활성 Term이 편집 중인 파일이었으면 dirty 스냅샷을 요청한다(§3.2 two-phase).
    if (opened.previous_active_term) |prev| if (prev != opened.term) {
        if (prev.file_entry) |prev_entry| _ = markFilePanelDirtySyncPending(self, prev_entry);
    };
    const active_entry = opened.term.file_entry orelse return .failed;
    dock_ops.requestDockEntryFocus(self, active_entry);
    self.dock.collapsed = false;
    if (self.surface_initialized) {
        for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
        pane_ops.recomputeActivePaneRect(self);
        self.last_resize_size = null;
    }
    self.metal_dirty = true;
    if (opened.created) self.workspaceChanged(.persisted_surface);
    return .opened;
}

pub fn blockSessionExitForFilePanels(self: *AppSession) bool {
    if (!hasProtectedFilePanelsForExit(self)) return false;
    self.showNoticeKey(.common_unsaved_tabs_first);
    return true;
}

pub fn retireFilePanelSurface(self: *AppSession, entry: *dock_panel.Entry, retired_focus: *bool) void {
    const surface_id = entry.surface_id;
    if (surface_id == 0) return;
    retired_focus.* = retired_focus.* or fileSurfaceOwnsInput(self, surface_id);
    removeFilePanelQueuedActions(self, surface_id);
    term_ops.notifySurfaceClosed(self, surface_id);
    entry.surface_id = 0;
}

pub fn selectedFileTreeMutationTarget(self: *const AppSession) ?file_tree_mutation.Target {
    // **원격 변경은 RF6 전까지 없다**(§2.4 — 로컬 mutation backend 에 원격 경로가 가면 같은 철자의
    // 로컬 파일이 지워진다). 키는 발행 출처다 — 선택 행이 그 목록에서 나오므로(적대적 검증 2 회차).
    if (self.file_tree_rows_remote) return null;
    const index = selectedFileTreeRow(self) orelse return null;
    if (index >= self.file_tree_rows.items.len) return null;
    var target = fileTreeMutationTarget(self.file_tree_rows.items[index]) orelse return null;
    if (file_tree.parentIndex(self.file_tree_rows.items, index)) |parent_index|
        target.parent_identity = rowFileIdentity(self.file_tree_rows.items[parent_index]);
    if (self.file_tree.rootForMutation(target.path)) |root_path| {
        for (self.file_tree_rows.items) |row| switch (row) {
            .root => |root| if (std.mem.eql(u8, root.path, root_path)) {
                target.root_identity = root.identity;
                break;
            },
            else => {},
        };
    }
    return target;
}

pub fn fileEntryCount(self: *AppSession) usize {
    var n: usize = 0;
    var it = fileEntries(self);
    while (it.next()) |_| n += 1;
    return n;
}

pub fn requestDeleteSelectedFileTreeEntry(self: *AppSession) void {
    if (fileTreeNamespaceMutationBusy(self)) {
        self.showNoticeKey(.fp_trash_in_progress);
        return;
    }
    if (self.file_tree_trash_queue_len >= self.file_tree_trash_queue.len) {
        self.showNoticeKey(.fp_trash_queue_full);
        return;
    }
    const target = selectedFileTreeMutationTarget(self) orelse {
        self.showNoticeKey(.fp_select_to_delete);
        return;
    };
    if (target.kind == .root) {
        self.showNoticeKey(.fp_root_delete_denied);
        return;
    }
    var protections: [dock_panel.max_entries]file_tree_mutation.Protection = undefined;
    const protection_len = fillFileTreeProtections(self, &protections);
    const root = self.file_tree.rootForMutation(target.path) orelse return;
    if (target.kind == .directory and fileTreeDirectoryAliasRisk(self, target.path, root)) {
        self.showNoticeKey(.fp_symlink_alias_delete_blocked);
        return;
    }
    const roots = [_][]const u8{root};
    _ = file_tree_mutation.planDelete(&roots, target, protections[0..protection_len]) catch |err| {
        self.showNoticeKey(if (err == error.ProtectedEntry) .fp_delete_protected else .fp_delete_denied);
        return;
    };
    self.pending_file_tree_delete = copyPendingFileTreeDelete(target, self.file_tree.rootGeneration()) orelse return;
    self.showConfirmKeys(.file_tree_delete, .fp_trash_confirm, .{ .confirm = .btn_move_to_trash });
}

pub fn takePendingTrashStaged(self: *AppSession, id: u64) ?[]u8 {
    for (self.file_tree_trash_queue[0..self.file_tree_trash_queue_len]) |*pending| {
        if (pending.id != id) continue;
        const staged = pending.staged;
        pending.staged = staged[0..0];
        return staged;
    }
    return null;
}

pub fn ageFilePanelSelfWriteLatches(self: *AppSession) void {
    if (!self.dock_initialized) return;
    var entry_it5 = fileEntries(self);
    while (entry_it5.next()) |entry| if (entry.self_write_verifications == 0) {
        entry.self_write_grace_ticks -|= 1;
        if (entry.self_write_grace_ticks == 0) entry.self_write_hash = 0;
    };
}

/// surface-less close와 bulk rename/delete처럼 `closeFilePanelSurfaceNow`를 거치지 않는 제거 경로의 공용
/// empty-leaf 정규화. L2가 tree/focused_group을 고치고 L4는 사라진 구조 owner만 content/workspace로 재파생한다.
pub fn normalizeEmptyDockGroups(self: *AppSession) void {
    if (!self.dock_initialized) return;
    // FP16: entry가 Term으로 옮겨가 "빈 leaf"라는 구조가 없다. 남은 일은 사라진 파일을 가리키는
    // publish barrier owner를 workspace로 되돌리는 것뿐이다 — pane의 active_term 승계는 이미
    // closeTermAt이 끝냈다.
    const owned_entry_id = switch (self.focus_owner) {
        .dock_pending => |entry_id| entry_id,
        else => return,
    };
    if (fileEntryForId(self, owned_entry_id) != null) return;
    self.focusWorkspaceInput();
    self.workspace_focus_pending = true;
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

/// FIFO/device/socket가 open 자체에서 대기하지 않도록 nonblocking으로 descriptor를 얻는다.
/// 호출자는 같은 fd를 fstat한 뒤 정규 파일일 때만 읽으므로, 일반 파일에서는 NONBLOCK이 의미를 바꾸지 않는다.
pub fn openFilePanelRead(dir: std.Io.Dir, path: []const u8, follow_symlinks: bool) FilePanelReadError!std.Io.File {
    const fd = std.posix.openat(dir.handle, path, .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = !follow_symlinks,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.IsDir => return error.NotRegularFile,
        error.SymLinkLoop => return error.OutsideRoot,
        else => return error.NotFound,
    };
    return .{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
}

pub fn reserveFileTreeMutation(self: *AppSession, request_id: u64, source: []const u8) bool {
    var reserved: [dock_panel.max_entries]*dock_panel.Entry = undefined;
    var n: usize = 0;
    var entry_it10 = fileEntries(self);
    while (entry_it10.next()) |entry| {
        if (!file_tree_mutation.pathWithin(entry.path, source)) continue;
        if (entry.mutation_pending_id != 0) {
            for (reserved[0..n]) |prior| prior.mutation_pending_id = 0;
            return false;
        }
        entry.mutation_pending_id = request_id;
        reserved[n] = entry;
        n += 1;
    }
    return true;
}

/// 목록이 짧아졌을 때 offset을 창 안으로 당긴다. **호출부에 인라인으로 두면 테스트가 이 산술을
/// 복제하게 되고, 복제본은 호출부를 판정하지 못한다** — 실제로 그랬다(적대적 검증에서 clamp 변이가
/// 복제 기반 단언을 통과했다).
pub fn clampFileTreeScroll(self: *AppSession) void {
    self.file_tree_scroll.clamp(fileTreeScrollExtent(self).max_offset_px);
}

pub fn swapPinnedFilePanelNames(parent: std.Io.Dir, from: []const u8, to: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    var from_buf: [std.fs.max_path_bytes]u8 = undefined;
    var to_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (from.len + 1 > from_buf.len or to.len + 1 > to_buf.len) return false;
    @memcpy(from_buf[0..from.len], from);
    from_buf[from.len] = 0;
    @memcpy(to_buf[0..to.len], to);
    to_buf[to.len] = 0;
    return FilePanelTestC.renameatx_np(
        @intCast(parent.handle),
        @ptrCast(from_buf[0..from.len :0]),
        @intCast(parent.handle),
        @ptrCast(to_buf[0..to.len :0]),
        rename_swap,
    ) == 0;
}

pub fn removeFilePanelDirtySyncAction(self: *AppSession, surface_id: u64) void {
    var i: usize = 0;
    while (i < self.file_panel_dirty_sync_actions_len) : (i += 1) {
        if (self.file_panel_dirty_sync_actions[i].surface_id != surface_id) continue;
        const last = self.file_panel_dirty_sync_actions_len - 1;
        self.file_panel_dirty_sync_actions[i] = self.file_panel_dirty_sync_actions[last];
        self.file_panel_dirty_sync_actions_len = last;
        return;
    }
}

pub fn fileEntryForSurfaceId(self: *AppSession, surface_id: u64) ?*dock_panel.Entry {
    if (surface_id == 0) return null;
    var it = fileEntries(self);
    while (it.next()) |entry| {
        if (entry.surface_id == surface_id) return entry;
    }
    return null;
}

pub fn buildFileTreeContextMenuItems(self: *AppSession) []const []const u8 {
    const target = self.file_tree_context_target orelse return &.{};
    var n: usize = 0;
    if (!(target.symlink and (target.row_kind == .root or target.row_kind == .directory))) {
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_new_file);
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_new_folder);
        n += 1;
    }
    if (target.row_kind == .file or target.row_kind == .directory) {
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_rename);
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_move_to_trash);
        n += 1;
    }
    if (target.row_kind == .root) {
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_open_file);
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_open_folder);
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_add_folder_to_workspace);
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_remove_folder_from_workspace);
        n += 1;
    }
    self.context_menu_items_len = n;
    return self.context_menu_items_buf[0..n];
}

pub fn buildFileTreeBackgroundMenuItems(self: *AppSession) []const []const u8 {
    self.context_menu_items_buf[0] = maru.i18n.t(.ctx_open_file);
    self.context_menu_items_buf[1] = maru.i18n.t(.ctx_open_folder);
    self.context_menu_items_buf[2] = maru.i18n.t(.ctx_add_folder_to_workspace);
    self.context_menu_items_len = 3;
    return self.context_menu_items_buf[0..3];
}

pub fn openedFileIdentity(self: *AppSession, file: std.Io.File) FilePanelReadError!file_tree.Identity {
    if (comptime builtin.os.tag == .macos) {
        var stat: std.posix.Stat = undefined;
        if (std.c.fstat(file.handle, &stat) != 0) return error.NotFound;
        return .{
            .device = @intCast(stat.dev),
            .inode = @intCast(stat.ino),
            .kind = @intFromEnum(if (std.posix.S.ISREG(stat.mode))
                file_tree.IdentityKind.regular
            else if (std.posix.S.ISDIR(stat.mode))
                file_tree.IdentityKind.directory
            else if (std.posix.S.ISLNK(stat.mode))
                file_tree.IdentityKind.symlink
            else
                file_tree.IdentityKind.other),
        };
    }
    const stat = file.stat(self.io) catch return error.NotFound;
    return .{
        .device = 0,
        .inode = @intCast(stat.inode),
        .kind = @intFromEnum(switch (stat.kind) {
            .file => file_tree.IdentityKind.regular,
            .directory => file_tree.IdentityKind.directory,
            .sym_link => file_tree.IdentityKind.symlink,
            else => file_tree.IdentityKind.other,
        }),
    };
}

pub fn fileTreeScrollTree(self: *const AppSession) chrome.ui.tree.UiRectTree {
    return .{
        .entries = self.dock_list_scroll_entries[0..self.dock_list_scroll_entry_count],
        .generation = self.dock_list_scroll_generation,
    };
}

pub fn prepareFileTreeRowStaging(self: *AppSession, rows: *std.ArrayList(file_tree.Row), extra_entries: usize) !void {
    try self.file_tree_open_states.ensureTotalCapacity(self.allocator, fileEntryCount(self) + extra_entries);
    try rows.ensureTotalCapacity(self.allocator, file_tree.max_materialized_nodes + file_tree.max_recent + file_tree.max_roots + 1);
}

pub fn swapPinnedFilePanelNamesIfPair(
    io: std.Io,
    parent: std.Io.Dir,
    from: []const u8,
    from_inode: std.Io.File.INode,
    to: []const u8,
    to_inode: std.Io.File.INode,
) bool {
    if (!pinnedFilePanelNameHasInode(io, parent, from, from_inode) or
        !pinnedFilePanelNameHasInode(io, parent, to, to_inode)) return false;
    return swapPinnedFilePanelNames(parent, from, to);
}

pub fn openFilePanelPathAfterValidation(
    self: *AppSession,
    path: []const u8,
    open_kind: file_panel_bridge.OpenKind,
    initial_identity: ?file_tree.Identity,
) FilePanelOpenPathResult {
    if (self.file_tree_initialized) {
        const root = file_tree_backend.projectRootForFile(self.allocator, self.io, path) catch return .failed;
        defer self.allocator.free(root);
        var candidate = self.file_tree.clone() catch return .failed;
        defer candidate.deinit();
        candidate.recordOpened(path, root) catch return .failed;
        resetFileTreeWatchRootsFor(self, &candidate, path) catch return .failed;
        var candidate_rows: std.ArrayList(file_tree.Row) = .empty;
        defer candidate_rows.deinit(self.allocator);
        prepareFileTreeRowStaging(self, &candidate_rows, 1) catch return .failed;
        const kind = entryKindForOpenKind(open_kind);
        const opened = pane_ops.openFileTermInActivePane(self, path, kind) catch return .failed;
        pinInitialFilePanelIdentity(self, opened, initial_identity);
        buildPreparedFileTreeRows(self, &candidate, &candidate_rows);
        commitFileTreeCandidate(self, &candidate, &candidate_rows);
        return finishOpenFilePanel(self, opened);
    }
    const kind = entryKindForOpenKind(open_kind);
    const opened = pane_ops.openFileTermInActivePane(self, path, kind) catch return .failed;
    pinInitialFilePanelIdentity(self, opened, initial_identity);
    return finishOpenFilePanel(self, opened);
}

pub fn closeFilePanelSurfaceNow(self: *AppSession, surface_id: u64) bool {
    if (surface_id == 0) return false;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return false;
    const owned_focus = switch (self.focus_owner) {
        .workspace => fileSurfaceOwnsInput(self, surface_id),
        .file_tree => |owner| owner.restore_surface == surface_id,
        // publish 대기 barrier도 입력 소유다 — 그 파일을 닫으면 barrier가 가리킬 대상이 사라지므로
        // 아래에서 승계 대상으로 다시 발급해야 한다(안 하면 입력이 죽은 owner에 묶인다).
        .dock_pending => |entry_id| entry_id == entry.id,
    };
    // Term이 entry·path 소유를 회수하고 destroyTerm이 notifySurfaceClosed까지 부른다(FP16) — 옛
    // `group.remove` + `free(path)` + 명시적 notify 삼중 쌍을 대체한다.
    //
    // **close를 먼저 시도한다.** 거부될 수 있는데 트랜잭션을 먼저 파기하면, CM6은 close lock이 걸린
    // 채인데 unlock one-shot은 버려져 그 파일을 영영 편집할 수 없게 된다(code-review max).
    if (!closeFileTermForEntry(self, entry)) return false;
    removeFilePanelQueuedActions(self, surface_id);
    if (self.pending_file_panel_close != null and self.pending_file_panel_close.?.surface_id == surface_id)
        clearFilePanelCloseWithoutUnlock(self);
    // 입력 소유가 이 파일에 있었으면 workspace로 돌린다. 파일이 이제 pane 탭이라 "다음 도크 entry로 승계"라는
    // 옛 규칙은 성립하지 않는다 — pane의 active_term 승계는 closeFileTermForEntry가 이미 했고, 키 입력은
    // 그 pane(=workspace)으로 간다.
    if (owned_focus) {
        if (fileTreeFocused(self)) {
            // tree는 project/recent history로 계속 조작할 수 있다. 사라진 WebView만 Esc restore capability에서 제거한다.
            self.focus_owner = .{ .file_tree = .{ .restore_surface = null } };
            self.file_tree_restore_surface_pending = null;
        } else if (activeFileEntry(self)) |successor| {
            // 승계 Term이 또 다른 파일이면 그 파일로 typed focus를 다시 발급한다(옛 "다음 도크 entry로
            // 승계"와 같은 사용자 경험). 승계가 터미널이면 workspace로 간다.
            dock_ops.requestDockEntryFocus(self, successor);
        } else {
            self.focusWorkspaceInput();
            self.workspace_focus_pending = true;
        }
    }
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
    self.workspaceChanged(.persisted_surface);
    return true;
}

/// 방문 수를 계측하는 변형(성능 gate가 소비 — docs/performance-budget.md).
pub fn fileEntryForIdCounted(
    self: *AppSession,
    entry_id: dock_panel.EntryId,
    counters: ?*EntryLookupCounters,
) ?*dock_panel.Entry {
    if (entry_id == 0) return null;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (counters) |c| c.entry_visits += 1;
                if (entry.id == entry_id) return entry;
            }
        }
    }
    return null;
}

pub fn pinnedFilePanelNameHasInode(io: std.Io, parent: std.Io.Dir, name: []const u8, inode: std.Io.File.INode) bool {
    var file = openFilePanelRead(parent, name, false) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    return stat.kind == .file and stat.inode == inode;
}

pub fn handleFileTreeDefaultKey(self: *AppSession, event: terminal.KeyEvent) void {
    if (event.key == .escape) {
        restoreFileTreeFocus(self);
        return;
    }
    if (event.key == .function and event.key.function == 2) {
        self.dispatchAppAction(.rename_file_tree_entry);
        return;
    }
    if (event.key == .backspace and event.modifiers.command) {
        self.dispatchAppAction(.delete_file_tree_entry);
        return;
    }
    if (selectedFileTreeRow(self) == null) selectFirstFileTreeRow(self);
    const selected = selectedFileTreeRow(self) orelse return;
    const intent = fileTreeNavigationIntent(event) orelse return;
    switch (file_tree_navigation.navigate(
        self.file_tree_rows.items,
        selected,
        intent,
        fileTreeVisibleRows(self),
    )) {
        .none => {},
        .select => |index| _ = setFileTreeSelection(self, index),
        .activate => |index| activateFileTreeRow(self, index),
    }
    self.metal_dirty = true;
}

pub fn copyFileTreeEditTarget(target: file_tree_mutation.Target, edit_kind: FileTreeEditKind) ?FileTreeEditTarget {
    if (target.path.len > std.fs.max_path_bytes) return null;
    var out = FileTreeEditTarget{
        .row_kind = target.kind,
        .symlink = target.symlink,
        .edit_kind = edit_kind,
        .identity = target.identity,
        .parent_identity = target.parent_identity,
        .root_identity = target.root_identity,
    };
    @memcpy(out.path_buf[0..target.path.len], target.path);
    out.path_len = target.path.len;
    return out;
}

/// **탭 하나를 닫을 때** 그 파일이 잃을 상태를 들고 있나. `filePanelEntryNeedsDirtyProtection`과 달리
/// `mode.isEditable()`을 보지 **않는다** — 그 조건은 "source-edit는 native dirty가 최신 CM6 revision보다
/// 늦을 수 있다"는 이유로 **⌘Q 종료** 게이트가 쓰는 것이고, 거기서는 복구 기회가 없어 보수적으로 막는 게 맞다.
/// 탭 닫기는 다르다 — `requestFilePanelClose`의 revision-pinned 2단계 스냅샷이 그 지연을 해소하므로,
/// mode만으로 막으면 **깨끗한 `.py`/`.json` 탭이 영원히 안 닫힌다**(.text의 기본 mode가 source_edit이다).
pub fn filePanelEntryBlocksClose(entry: dock_panel.Entry) bool {
    return entry.dirty or entry.dirty_sync_pending or entry.external_change or
        entry.conflict_reload_pending or entry.mutation_pending_id != 0;
}

/// 드래그 중에 잡은 thumb을 **계속 잡고 있어도 되는가**. 스크롤 위치(`thumb_y`)는 드래그가 바꾸는
/// 값이라 비교에서 빠지고, 그 밖의 것이 하나라도 달라지면 다른 목록·다른 기하를 가리키므로 끊는다.
pub fn fileTreeScrollbarSameSnapshot(
    a: chrome.ui.scroll_area.ScrollbarGeometry,
    b: chrome.ui.scroll_area.ScrollbarGeometry,
) bool {
    return a.track_x == b.track_x and a.track_y == b.track_y and
        a.track_w == b.track_w and a.track_h == b.track_h and
        a.thumb_h == b.thumb_h and a.max_offset_px == b.max_offset_px;
}

pub fn classifyFileTreeRows(rows: []file_tree.Row) void {
    classifyFileTreeRowsCounted(rows, null);
}

/// watcher union은 "표시 root ∪ 열린 파일의 부모"다(§7). 입력이 dock 구조일 이유가 없어 **entry 슬라이스**를
/// 받는다 — 복원 중에는 staged 목록이, 라이브에서는 창구 순회 결과가 들어온다(FP16 2-2r).
pub fn resetFileTreeWatchRootsForEntries(
    tree: *file_tree.Tree,
    entries: []const dock_panel.Entry,
    extra_open_path: ?[]const u8,
) !void {
    var extras: [dock_panel.max_entries + 1][]const u8 = undefined;
    var count: usize = 0;
    for (entries) |entry| {
        const parent = std.fs.path.dirname(entry.path) orelse continue;
        extras[count] = parent;
        count += 1;
    }
    if (extra_open_path) |path| if (std.fs.path.dirname(path)) |parent| {
        extras[count] = parent;
        count += 1;
    };
    try tree.resetWatchRequests(extras[0..count]);
}

pub fn abortStaleFilePanelClose(self: *AppSession) void {
    cancelFilePanelClose(self);
    self.showNoticeKey(.fp_tab_state_changed_close_cancel);
}

/// root/watch/rows의 모든 allocation이 끝난 뒤 세 authority를 한 번에 무실패 교체한다.
///
/// ⚠️ **선택을 지우지 않는다.** 이 함수는 2026-07-20 에 **root 교체 전용**으로 태어나(`220c09dd`) 첫 줄에서
/// `clearFileTreeSelection` 을 불렀는데, 그때도 호출자가 직후에 같은 clear 를 한 번 더 부르는 **중복**이었다.
/// 그 뒤 파일 열기(`openFilePanelPathAfterValidation`)가 같은 헬퍼를 재사용하면서 **root 교체용 정책만
/// 따라왔다**: 파일을 열 때마다 선택이 사라지고, 트리에 포커스가 있으면 `reconcileFileTreeSelection` 이
/// 「첫 행」규칙으로 떨어져 **스크롤이 맨 위로 튀었다**(사용자 보고 2026-08-27 — "열면 맨 위로 팅겨서요").
///
/// **지울 필요가 없다**: 선택은 신원 기반이라(`file_tree_navigation.Selection`) 행 배열이 통째로 바뀌어도
/// `reconcile` 이 새 목록에서 같은 항목을 찾고, **없으면 스스로 지운다**. 그래서 root 를 갈아끼워 그 항목이
/// 사라진 경우는 여기서 손대지 않아도 옳게 비워진다 — 초기화가 **정책**인 자리(root 교체·제거)는 그
/// 호출자가 계속 자기 손으로 부른다.
pub fn commitFileTreeCandidate(self: *AppSession, candidate: *file_tree.Tree, candidate_rows: *std.ArrayList(file_tree.Row)) void {
    const old_tree = self.file_tree;
    const old_rows = self.file_tree_rows;
    self.file_tree = candidate.*;
    self.file_tree_rows = candidate_rows.*;
    candidate.* = old_tree;
    candidate_rows.* = old_rows;
    candidate_rows.deinit(self.allocator);
    candidate_rows.* = .empty;
    candidate.deinit();
    candidate.* = file_tree.Tree.init(self.allocator);
    advanceFileTreeProjectionGeneration(self);
    self.file_tree_rows_dirty = false;
    self.file_tree_watch_reset_pending = true;
}

pub fn advanceFileTreeProjectionGeneration(self: *AppSession) void {
    self.file_tree_projection_generation +%= 1;
    if (self.file_tree_projection_generation == 0) self.file_tree_projection_generation = 1;
    self.dock_list_scroll_entry_count = 0;
    self.dock_list_scrollbar_hovered = false;
    self.sidebar_scrollbar_hovered = false;
    if (scroll_ops.scrollbarCaptureActive(self)) scroll_ops.endScrollbarCapture(self);
}

pub fn advanceDockAsyncEpoch(self: *AppSession) void {
    self.pending_dock_focus = null;
    self.pending_dock_focus_action = false;
    if (self.dock_async_epoch != std.math.maxInt(u64)) {
        self.dock_async_epoch += 1;
    } else {
        // Epoch exhaustion must never make an old callback current again. Saturation keeps all
        // subsequently issued tokens at the terminal epoch while EntryId/surface/revision still
        // provide independent identity barriers.
        self.dock_async_epoch = std.math.maxInt(u64);
    }
}

pub fn clearFileTreeSelection(self: *AppSession) void {
    self.file_tree_selection.clear();
}

pub fn openFileTreePath(self: *AppSession, path: []const u8, supported: bool) void {
    if (supported) {
        const tree_owner: ?FileTreeFocusOwner = switch (self.focus_owner) {
            .file_tree => |owner| owner,
            else => null,
        };
        _ = openFilePanelPath(self, path);
        if (tree_owner) |owner| {
            self.focus_owner = .{ .file_tree = owner };
            self.file_tree_focus_pending = true;
            self.workspace_focus_pending = false;
        }
        return;
    }
    const owned = self.allocator.dupe(u8, path) catch return;
    if (self.file_tree_external_open) |old| self.allocator.free(old);
    self.file_tree_external_open = owned;
}

pub fn nextFileTreeMutationRequestId(self: *AppSession) ?u64 {
    if (self.file_tree_mutation_request_id == std.math.maxInt(u64)) return null;
    self.file_tree_mutation_request_id += 1;
    return self.file_tree_mutation_request_id;
}

/// 창 전체에서 그 `EntryId`의 파일 Term.
pub fn fileTermForId(self: *AppSession, entry_id: dock_panel.EntryId) ?*Term {
    if (entry_id == 0) return null;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (entry.id == entry_id) return term;
            }
        }
    }
    return null;
}

/// 아직 `self.tabs`에 설치되지 않은 복원 pane이 이미 그 경로의 파일 Term을 들고 있나(마이그레이션 dedup).
pub fn restoredPaneHasPath(self: *AppSession, pane: *Pane, path: []const u8) bool {
    _ = self;
    for (pane.terms.items) |term| {
        const entry = term.file_entry orelse continue;
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

pub fn activateFilePanelDockControl(self: *AppSession) void {
    const action = filePanelDockControlAction(self) orelse return;
    const old_presented = self.dock.presented;
    const old_collapsed = self.dock.collapsed;
    // A collapsed right dock has no consumer for archive work.  Withdraw the current
    // generation before changing geometry so reopening can request a fresh snapshot.
    if (action == .collapse and self.dock.view == .agent_sessions) agent_dock.cancelAgentSessionArchive(self);
    // 열기/접기/펴기 어느 것도 도크 **내용**을 누른 게 아니다. 접었다 편 뒤 클릭 없이 Enter가
    // 도크로 가지 않도록 소유권을 놓는다(게이트의 `dock_ops.dockVisible`만으로는 재표시 때 되살아난다).
    agent_dock.releaseAgentSessionDockKeyFocus(self);
    switch (action) {
        .open => {
            self.dock.presented = true;
            self.dock.collapsed = false;
        },
        .collapse => self.dock.collapsed = true,
        .expand => self.dock.collapsed = false,
    }
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    self.last_resize_size = null;
    self.metal_dirty = true;
    if (old_presented != self.dock.presented or old_collapsed != self.dock.collapsed)
        self.workspaceChanged(.dock);
}

pub fn reportFileTreeRootOutcome(self: *AppSession, outcome: FileTreeRootOutcome, message: ?maru.i18n.Key) void {
    self.file_tree_root_outcome = outcome;
    // **자동 따라가기의 실패는 조용하다.** 사용자가 시킨 적 없는 동작인데 "선택한 폴더를 열 수 없습니다"가 뜨면
    // 무엇을 잘못했는지 알 수 없는 알림이 된다. outcome은 남기므로 진단·테스트는 그대로 볼 수 있다.
    if (self.file_tree_root_auto_follow) return;
    // 문자열이 아니라 **키**를 받는다(docs/i18n.md §7.2 1차) — 이 자리에 리터럴을 넘기면 컴파일되지 않는다.
    // 표시 문자열로의 해석은 여기 한 곳에서만 한다.
    if (message) |key| self.showNotice(maru.i18n.t(key));
}

pub fn showFilePanelCloseChoices(self: *AppSession, pending: PendingFilePanelClose, entry: *const dock_panel.Entry) void {
    self.pending_file_panel_close = pending;
    if (entry.external_change) {
        self.showConfirmKeys(.file_panel_close, .fp_close_external_confirm, .{ .confirm = .btn_discard_changes });
        var next = pending;
        next.phase = .confirm_conflict;
        self.pending_file_panel_close = next;
    } else {
        self.showConfirmChoiceKeys(.file_panel_close, .fp_unsaved_confirm, .{ .primary = .btn_save, .alternate = .btn_discard_changes });
        var next = pending;
        next.phase = .confirm_dirty;
        self.pending_file_panel_close = next;
    }
}

/// Trash bulk commit용 queue cleanup. 삭제 surface set을 fixed open-address table로 한 번 만든 뒤 각 bounded
/// action array를 정확히 한 번 compact한다. 단일-tab close는 위의 작은 targeted helper를 계속 쓴다.
pub fn removeFilePanelQueuedActionsBulk(self: *AppSession, removed: *const DeletedSurfaceSet, stats: *FileTreeDockRemovalStats) void {
    if (self.file_panel_mode_pending) |surface_id| {
        if (removed.contains(surface_id)) self.file_panel_mode_pending = null;
    }
    if (self.pending_dock_focus) |pending| {
        if (pending.expected_surface_id) |surface_id| {
            if (removed.contains(surface_id)) dock_ops.cancelPendingDockFocus(self);
        }
    }
    if (self.file_panel_save_close_pending) |pending| {
        if (removed.contains(pending.surface_id)) self.file_panel_save_close_pending = null;
    }

    var write: usize = 0;
    for (self.file_panel_dirty_sync_actions[0..self.file_panel_dirty_sync_actions_len]) |action| {
        stats.dirty_sync_visits += 1;
        if (removed.contains(action.surface_id)) continue;
        self.file_panel_dirty_sync_actions[write] = action;
        write += 1;
    }
    self.file_panel_dirty_sync_actions_len = write;

    write = 0;
    for (self.file_panel_close_unlock_actions[0..self.file_panel_close_unlock_actions_len]) |action| {
        stats.unlock_visits += 1;
        if (removed.contains(action.surface_id)) continue;
        self.file_panel_close_unlock_actions[write] = action;
        write += 1;
    }
    self.file_panel_close_unlock_actions_len = write;

    write = 0;
    for (self.file_tree_reload_actions[0..self.file_tree_reload_actions_len]) |action| {
        stats.reload_visits += 1;
        if (removed.contains(action.surface_id)) continue;
        self.file_tree_reload_actions[write] = action;
        write += 1;
    }
    self.file_tree_reload_actions_len = write;
}

/// prepareFileTreeRowStaging 뒤에만 호출한다. capacity가 고정돼 도크 commit 이후에도 allocation/OOM 없이
/// live open/dirty/active 상태를 후보 Tree row로 투영한다.
pub fn buildPreparedFileTreeRows(self: *AppSession, tree: *const file_tree.Tree, rows: *std.ArrayList(file_tree.Row)) void {
    projectFileTreeOpenStatesAssumeCapacity(self);
    tree.buildRows(self.allocator, self.file_tree_open_states.items, rows) catch unreachable;
    classifyFileTreeRows(rows.items);
}

pub fn enqueueFileTreeRenameRollback(self: *AppSession, result: file_tree_mutation_backend.Result) bool {
    const root = self.file_tree.rootForMutation(result.source) orelse return false;
    const plan: file_tree_mutation.Plan = .{
        .operation = .rename,
        .root = root,
        .source = result.target,
        .parent = std.fs.path.dirname(result.source) orelse return false,
        .name = std.fs.path.basename(result.source),
    };
    var request = file_tree_mutation_backend.Request.init(self.allocator, result.id, plan) catch return false;
    const identity = result.identity orelse {
        request.deinit(self.allocator);
        return false;
    };
    request.identity = .{ .device = identity.device, .inode = identity.inode, .kind = @intCast(identity.kind) };
    request.parent_identity = result.parent_identity;
    request.root_identity = result.root_identity;
    request.row_kind = result.row_kind;
    request.selection_generation = result.selection_generation;
    if (!self.file_tree_mutation_backend.submit(request)) {
        request.deinit(self.allocator);
        return false;
    }
    self.file_tree_rename_rollback_id = result.id;
    self.file_tree_mutation_backend.pump();
    return true;
}

pub fn restoreFileTreeFocus(self: *AppSession) void {
    const owner = switch (self.focus_owner) {
        .file_tree => |owner| owner,
        else => return,
    };
    self.file_tree_focus_pending = false;
    if (owner.restore_surface) |surface_id| {
        if (activateFilePanelSurfaceForRestore(self, surface_id)) {
            // 복원 대상은 트리로 들어가기 **전에** 이미 publish된 surface다(가시성으로 재확인) — 새 barrier가
            // 아니라 곧바로 owner다. 다만 그 사이에 걸린 다른 파일의 pending은 취소해야 늦은 ack가
            // 사용자가 되돌아온 이 surface에서 focus를 뺏지 않는다.
            dock_ops.cancelPendingDockFocus(self);
            self.focus_owner = .workspace;
            self.file_tree_restore_surface_pending = surface_id;
            self.workspace_focus_pending = false;
            self.metal_dirty = true;
            return;
        }
    }
    self.focus_owner = .workspace;
    self.file_tree_restore_surface_pending = null;
    self.workspace_focus_pending = true;
    self.metal_dirty = true;
}

pub fn queueFilePanelDirtySyncAction(self: *AppSession, surface_id: u64, request_id: u64) void {
    if (surface_id == 0) return;
    for (self.file_panel_dirty_sync_actions[0..self.file_panel_dirty_sync_actions_len]) |*queued| {
        if (queued.surface_id != surface_id) continue;
        if (request_id != 0) queued.request_id = request_id;
        return;
    }
    if (self.file_panel_dirty_sync_actions_len >= self.file_panel_dirty_sync_actions.len) return;
    self.file_panel_dirty_sync_actions[self.file_panel_dirty_sync_actions_len] = .{ .surface_id = surface_id, .request_id = request_id };
    self.file_panel_dirty_sync_actions_len += 1;
}

pub fn submitWaitingFileTreeMutation(self: *AppSession, mutation_id: u64) bool {
    if (!mutationEditorLocksAcknowledged(self, mutation_id)) return false;
    const request = self.file_tree_mutation_waiting_request orelse return false;
    if (request.id != mutation_id) return false;
    self.file_tree_mutation_waiting_request = null;
    std.debug.assert(self.file_tree_mutation_queue_reserved);
    self.file_tree_mutation_backend.submitReserved(request);
    self.file_tree_mutation_queue_reserved = false;
    for (self.file_tree_mutation_editor_locks[0..self.file_tree_mutation_editor_locks_len]) |*lock| {
        if (lock.mutation_id == mutation_id) lock.phase = .submitted;
    }
    self.file_tree_mutation_backend.pump();
    return true;
}

/// 좌표 → 행 인덱스를 **산술로** 푼다.
///
/// **제품 클릭 경로는 더 이상 이것을 쓰지 않는다**(FT2 — 발행된 rect 를 보는
/// `file_tree_dock.fileTreeRowAtPublished`). 그런데도 남기는 이유는 둘이다: ⑴ 같은 산술을 Windows
/// chrome 낮추기가 쓰고(`session/file_tree_layout.rowAtLocalY`), ⑵ **두 답이 같은지**를 테스트가
/// 대조하는 축이 필요하다. 그 대조가 없으면 published rect 와 창 산술이 조용히 갈려도 아무도 모른다.
pub fn fileTreeRowAt(self: *const AppSession, x_px: f64, y_px: f64) ?usize {
    // 다른 뷰를 보는 중이면 트리 행은 화면에 없다 — 좌표가 같은 rect 안이어도 hit이 되면 안 된다(§3.5).
    if (self.dock.view != .explorer) return null;
    if (!dock_ops.dockVisible(self) or self.cell_height_px == 0) return null;
    const tree_rect = dock_ops.dockGeometry(self).tree_content;
    if (!layout_math.pointInRect(x_px, y_px, tree_rect)) return null;
    if (dock_ops.dockListScrollbarGeometry(self)) |geometry| if (geometry.trackContains(x_px, y_px)) return null;
    // 산술은 `session/file_tree_layout.zig` 가 단일 출처다 — `fileTreeDrawWindow` 와 **같은 함수 쌍**이라
    // 그린 자리를 누르면 그 행이 나온다(그 짝은 그쪽 테스트가 조합을 훑어 못 박는다).
    return file_tree_layout.rowAtLocalY(
        file_tree_dock_ops.fileTreeRowHeightPx(self),
        fileTreeEffectiveScrollPx(self),
        y_px - @as(f64, @floatFromInt(tree_rect.y)),
        self.file_tree_rows.items.len,
    );
}

pub fn fileTreeSelectionPath(self: *const AppSession) ?[]const u8 {
    return self.file_tree_selection.path();
}

/// FP9 왕복 포커스 action. 구조 포커스의 단일 출처인 `FocusOwner`만 바꾸고 AppKit에는 기존 pending
/// one-shot으로 responder 전이를 요청한다. 빈 도크에서 picker를 암묵적으로 열지 않아 단축키 재바인딩도
/// 예측 가능하게 유지한다.
/// 활성 파일 Term의 표시 모드를 그 kind가 허용하는 다음 모드로 넘긴다(읽기 ↔ 소스). 헤더 mode 선택기
/// 클릭과 같은 `setFilePanelMode` 경로를 써서 pending action·web 통지가 동일하게 흐른다. 모드가 하나뿐인
/// kind(text·image·media·pdf)와 파일이 아닌 Term은 무동작이다.
pub fn toggleActiveFilePanelMode(self: *AppSession) void {
    const pane = pane_ops.activePane(self);
    if (pane.terms.items.len == 0) return;
    const entry = pane.activeTerm().file_entry orelse {
        self.showNoticeKey(.fp_file_tab_only);
        return;
    };
    const modes = dock_layout.modesForKind(entry.kind);
    if (modes.len < 2) return; // 선택지가 없으면 조용히 무동작(알림이 오히려 방해다).
    var next = modes[0].mode;
    for (modes, 0..) |descriptor, i| {
        if (descriptor.mode == entry.mode) {
            next = modes[(i + 1) % modes.len].mode;
            break;
        }
    }
    setFilePanelMode(self, entry, next);
    self.metal_dirty = true;
}

/// 창 전체에서 **그 경로의 비-diff 파일 Term**. diff는 같은 경로로 따로 존재할 수 있어(§3.5 유일성 키가
/// `(경로, kind, base)`) 여기서 제외한다 — 안 그러면 탐색기에서 파일을 열 때 열려 있던 diff Term이 활성화된다.
pub fn fileTermForPath(self: *AppSession, path: []const u8) ?*Term {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                const entry = term.file_entry orelse continue;
                if (entry.kind == .diff) continue;
                if (std.mem.eql(u8, entry.path, path)) return term;
            }
        }
    }
    return null;
}

pub fn dockHasContent(self: *const AppSession) bool {
    return fileEntryCountConst(self) > 0 or (self.file_tree_initialized and self.file_tree.hasContent());
}

pub fn isFileTreeDefaultKey(event: terminal.KeyEvent) bool {
    const no_modifiers = !event.modifiers.command and !event.modifiers.control and
        !event.modifiers.option and !event.modifiers.shift;
    if (no_modifiers) return switch (event.key) {
        .arrow_up, .arrow_down, .arrow_left, .arrow_right, .enter, .home, .end, .page_up, .page_down, .escape => true,
        .function => |n| n == 2,
        else => false,
    };
    return event.key == .backspace and event.modifiers.command and !event.modifiers.control and
        !event.modifiers.option and !event.modifiers.shift;
}

/// `.dock_pending`은 영속 owner가 아니라 PendingDockFocus와 정확히 일치하는 짧은 publish barrier다.
/// key routing, native responder override, paste 차단과 focus border가 모두 이 validator를 공유한다.
/// 그 파일 entry가 지금 **키를 받을 자리**인가 — 활성 탭 → 활성 pane → 활성 Term. `fileSurfaceIsVisible`
/// (활성 탭의 어느 pane에서든 보인다)보다 좁다: 보이는 것과 입력을 갖는 것은 split에서 다르다.
pub fn fileEntryIsFocusTarget(self: *const AppSession, entry: *const dock_panel.Entry) bool {
    if (self.tabs.items.len == 0) return false;
    const tab = self.tabs.items[self.app_window.active_tab];
    if (tab.panes.items.len == 0) return false;
    const pane = tab.panes.items[@min(tab.active_pane, tab.panes.items.len - 1)];
    if (pane.terms.items.len == 0) return false;
    return pane.activeTerm().file_entry == entry;
}

/// workspace.v1은 외부 입력이므로, DockPanel의 구조 검증 뒤에도 라이브 open과 같은 파일 capability 검증을 다시
/// 적용한다. kind↔확장자·절대 UTF-8 경로·regular-file을 모두 만족하지 않는 entry만 버리고 terminal workspace는
/// 계속 복원한다. 원래 active entry가 버려지면 첫 유효 entry를 활성화하며, 전부 버려지면 빈 도크다.
/// 반환은 **버린 entry 수**다. 호출자(applyWorkspaceWindow)가 이 값을 checkpoint 차단 판정에 쓴다 — 조용히 버리고
/// apply를 성공으로 반환하면 다음 Quit이 버려진 도크를 파일에 커밋해 사용자가 배치를 영구히 잃는다.
pub fn pruneInvalidRestoredFilePanelEntries(self: *AppSession, panel: *dock_panel.DockPanel) usize {
    const old_active = panel.restored_active;
    const original_len = panel.restored.items.len;
    var original_index: usize = 0;
    var current_index: usize = 0;
    var new_active: ?usize = null;
    while (original_index < original_len) : (original_index += 1) {
        const entry = panel.restored.items[current_index];
        const open_kind = file_panel_bridge.openKindForPath(entry.path) orelse {
            const removed = panel.restored.orderedRemove(current_index);
            self.allocator.free(removed.path);
            continue;
        };
        const expected_kind = entryKindForOpenKind(open_kind);
        const valid = std.fs.path.isAbsolute(entry.path) and
            std.unicode.utf8ValidateSlice(entry.path) and
            expected_kind == entry.kind and
            blk: {
                const stat = std.Io.Dir.cwd().statFile(self.io, entry.path, .{}) catch break :blk false;
                break :blk stat.kind == .file;
            };
        if (!valid) {
            const removed = panel.restored.orderedRemove(current_index);
            self.allocator.free(removed.path);
            continue;
        }
        if (old_active == original_index) new_active = current_index;
        current_index += 1;
    }
    panel.restored_active = if (panel.restored.items.len == 0) null else new_active orelse 0;
    return original_len - panel.restored.items.len;
}

pub fn fileEntriesConst(self: *const AppSession) FileEntryConstIterator {
    return .{ .session = self };
}

pub fn fileTreeRootOutcome(self: *const AppSession) FileTreeRootOutcome {
    return self.file_tree_root_outcome;
}

pub fn resetFilePanelTransientStateForDockReplacement(self: *AppSession) void {
    self.cancelPointerGesture();
    advanceDockAsyncEpoch(self);
    if (self.pending_confirm == .file_panel_close) {
        self.pending_confirm = .none;
        self.chrome_host.confirm.dismiss();
    }
    clearFilePanelCloseWithoutUnlock(self);
    self.file_panel_mode_pending = null;
    self.file_panel_dirty_sync_actions_len = 0;
    self.file_panel_close_unlock_actions_len = 0;
    self.file_tree_reload_actions_len = 0;
    clearFileTreeSelection(self);
    self.focus_owner = .workspace;
    self.workspace_focus_pending = true;
    self.file_tree_focus_pending = false;
    self.file_tree_restore_surface_pending = null;
}

/// 파일 패널(문서 안 링크) 전용 정책: `file-panel.external-link-target`(+`⌘⇧` 강제)에 따라 **새** browser Term을
/// 만들거나 시스템 브라우저로 보낸다. 재사용 개념이 없다(문서에서 따라간 링크는 새 탭이 자연스럽다).
/// 터미널 화면 링크는 정책이 달라(`input.link-open-target` — 재사용 우선) `openTerminalWebLink`가 소유하고,
/// 둘 다 아래 `queueExternalLinkAction` 실행 경로를 공유한다.
pub fn queueExternalLink(
    self: *AppSession,
    href: []const u8,
    force_system: bool,
) FilePanelLinkError!void {
    if (!file_panel_bridge.isExplicitHttpLink(href)) return error.InvalidLink;
    if (self.external_link_kind != null) return error.LinkBusy;

    const use_system = force_system or self.loaded_config.config.file_panel.external_link_target == .system;
    const surface_id = if (use_system) 0 else pane_ops.appendWebTermInActivePane(self, .browser) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.OpenFailed,
    };
    return self.queueExternalLinkAction(href, surface_id);
}

pub fn enqueueFileTreeEdit(self: *AppSession, target: FileTreeEditTarget, name: []const u8) bool {
    if (fileTreeNamespaceMutationBusy(self)) {
        self.showNoticeKey(.fp_mutation_in_progress);
        return false;
    }
    const root = self.file_tree.rootForMutation(target.path()) orelse {
        self.showNoticeKey(.fp_outside_root_denied);
        return false;
    };
    const roots = [_][]const u8{root};
    var protections: [dock_panel.max_entries]file_tree_mutation.Protection = undefined;
    const protection_len = fillFileTreeProtections(self, &protections);
    const policy_target: file_tree_mutation.Target = .{
        .kind = target.row_kind,
        .path = target.path(),
        .symlink = target.symlink,
        .identity = target.identity,
        .parent_identity = target.parent_identity,
        .root_identity = target.root_identity,
    };
    if (target.edit_kind == .rename and policy_target.kind == .directory and
        fileTreeDirectoryAliasRisk(self, policy_target.path, root))
    {
        self.showNoticeKey(.fp_symlink_alias_rename_blocked);
        return false;
    }
    const plan = switch (target.edit_kind) {
        .create_file => file_tree_mutation.planCreate(&roots, policy_target, name, false),
        .create_directory => file_tree_mutation.planCreate(&roots, policy_target, name, true),
        .rename => file_tree_mutation.planRename(&roots, policy_target, name, protections[0..protection_len]),
    } catch |err| {
        self.showNoticeKey(switch (err) {
            error.InvalidName => .fp_name_invalid,
            error.ProtectedEntry => .fp_change_protected,
            error.SymlinkContainer => .fp_symlink_dir_create_denied,
            error.Unchanged => .fp_name_unchanged,
            else => .fp_change_denied,
        });
        return false;
    };
    if (plan.root_identity == null or plan.parent_identity == null or
        (plan.operation == .rename and plan.identity == null))
    {
        self.showNoticeKey(.fp_identity_not_ready);
        return false;
    }
    if (!self.file_tree_mutation_backend.tryReserve()) {
        self.showNoticeKey(.fp_mutation_queue_full);
        return false;
    }
    self.file_tree_mutation_queue_reserved = true;
    var keep_queue_reservation = false;
    defer if (self.file_tree_mutation_queue_reserved and !keep_queue_reservation) {
        self.file_tree_mutation_backend.cancelReservation();
        self.file_tree_mutation_queue_reserved = false;
    };
    const id = nextFileTreeMutationRequestId(self) orelse {
        self.showNoticeKey(.fp_mutation_id_exhausted);
        return false;
    };
    var request = file_tree_mutation_backend.Request.init(self.allocator, id, plan) catch {
        self.showNoticeKey(.fp_mutation_prepare_failed);
        return false;
    };
    request.selection_generation = self.file_tree_selection.generation;
    const reserved = target.edit_kind == .rename;
    if (reserved) {
        const new_path = path_shape.joinNeutral(self.allocator, plan.parent, plan.name) catch {
            request.deinit(self.allocator);
            self.showNoticeKey(.fp_rename_plan_failed);
            return false;
        };
        defer self.allocator.free(new_path);
        prepareFileTreeRenameRemap(self, id, target.path(), new_path) catch {
            request.deinit(self.allocator);
            self.showNoticeKey(.fp_rename_plan_failed);
            return false;
        };
    }
    if (reserved and !reserveFileTreeMutation(self, id, target.path())) {
        request.deinit(self.allocator);
        discardPendingRenameRemap(self, id);
        self.showNoticeKey(.fp_entry_busy);
        return false;
    }
    if (reserved) {
        const waiting = beginFileTreeMutationEditorLocks(self, id, target.path()) catch {
            request.deinit(self.allocator);
            clearFileTreeMutationReservation(self, id);
            discardPendingRenameRemap(self, id);
            self.showNoticeKey(.fp_editor_lock_rename_failed);
            return false;
        };
        if (waiting) {
            self.file_tree_mutation_waiting_request = request;
            self.file_tree_edit_inflight = true;
            keep_queue_reservation = true;
            return true;
        }
    }
    self.file_tree_mutation_backend.submitReserved(request);
    self.file_tree_mutation_queue_reserved = false;
    self.file_tree_edit_inflight = true;
    self.file_tree_mutation_backend.pump();
    return true;
}

/// 열린 파일 마커(경로·활성·dirty·외부변경)를 Term 창구에서 `file_tree_open_states`로 투영한다.
/// 트리를 새로 그리는 모든 경로가 이 한 함수를 공유한다(정상 갱신·후보 트리 준비 양쪽).
/// `prepareFileTreeRowStaging`이 이미 capacity를 잡아 둔 뒤에만 부른다 — 무할당이다.
pub fn projectFileTreeOpenStatesAssumeCapacity(self: *AppSession) void {
    self.file_tree_open_states.clearRetainingCapacity();
    const active = activeFileEntry(self);
    var it = fileEntries(self);
    while (it.next()) |entry| self.file_tree_open_states.appendAssumeCapacity(.{
        .path = entry.path,
        .active = entry == active,
        .dirty = entry.dirty,
        .external_change = entry.external_change,
    });
}

pub fn fileTreeFocused(self: *const AppSession) bool {
    return self.focus_owner == .file_tree;
}

pub fn enqueueFileTreeDeleteRestore(
    self: *AppSession,
    id: u64,
    root: []const u8,
    staged: []const u8,
    original: []const u8,
    identity: file_tree_mutation_backend.Identity,
    parent_identity: ?file_tree.Identity,
    root_identity: ?file_tree.Identity,
) bool {
    var restore = file_tree_mutation_backend.Request.initRestore(
        self.allocator,
        id,
        root,
        staged,
        original,
        identity,
        parent_identity,
        root_identity,
    ) catch return false;
    if (!self.file_tree_mutation_backend.submit(restore)) {
        restore.deinit(self.allocator);
        return false;
    }
    self.file_tree_mutation_backend.pump();
    return true;
}

pub fn projectFileTreeOpenStates(self: *AppSession) !void {
    try self.file_tree_open_states.ensureTotalCapacity(self.allocator, fileEntryCount(self));
    projectFileTreeOpenStatesAssumeCapacity(self);
}

/// 닫기가 **CM6 스냅샷을 기다려야 하나**. `mode.isEditable()`을 브리지 조건과 묶어 두는 이유는,
/// 네이티브 편집기로 연 `.text`가 편집 모드인 채 브리지를 안 쓰기 때문이다 — 묶지 않으면 오지 않을
/// 응답을 기다리다 **탭이 안 닫힌다**. 나머지 항목(dirty·external_change 등)은 네이티브에서 서지
/// 않으므로 그대로 둔다.
pub fn filePanelEntryNeedsDirtyProtection(entry: dock_panel.Entry) bool {
    return entry.dirty or entry.dirty_sync_pending or entry.external_change or
        entry.conflict_reload_pending or (entry.usesEditorBridge() and entry.mode.isEditable()) or
        entry.mutation_pending_id != 0;
}

pub fn tabHasProtectedFilePanel(tab: *Tab) bool {
    for (tab.panes.items) |pane| if (paneHasProtectedFilePanel(pane)) return true;
    return false;
}

pub fn fileTreePathProtectedNow(self: *const AppSession, path: []const u8, request_id: u64) bool {
    var entry_it7 = fileEntriesConst(self);
    while (entry_it7.next()) |entry| {
        if (!file_tree_mutation.pathWithin(entry.path, path)) continue;
        if (entry.mutation_pending_id != 0 and entry.mutation_pending_id != request_id) return true;
        const editor_locked = if (entry.mode.isEditable()) blk: {
            for (self.file_tree_mutation_editor_locks[0..self.file_tree_mutation_editor_locks_len]) |lock| {
                if (lock.mutation_id == request_id and lock.surface_id == entry.surface_id and lock.acknowledged) break :blk true;
            }
            break :blk false;
        } else true;
        if (entry.dirty or entry.dirty_sync_pending or entry.external_change or
            entry.conflict_reload_pending or !editor_locked) return true;
    }
    return false;
}

pub fn markExternalFileChange(self: *AppSession, entry: *dock_panel.Entry) void {
    bumpExternalFileChange(entry);
    if (entry.dirty or entry.dirty_sync_pending or entry.external_change) {
        entry.external_change = true;
    } else {
        queueFileTreeReload(self, entry.surface_id, false);
    }
    self.metal_dirty = true;
    self.file_tree_rows_dirty = true;
}

/// `fileEntryForId`의 const 변형(순수 술어용).
pub fn fileEntryForIdConst(self: *const AppSession, entry_id: dock_panel.EntryId) ?*const dock_panel.Entry {
    if (entry_id == 0) return null;
    var it = fileEntriesConst(self);
    while (it.next()) |entry| {
        if (entry.id == entry_id) return entry;
    }
    return null;
}

pub fn retainFileTreeUnknownRecovery(self: *AppSession) void {
    if (!builtin.is_test) std.log.err("file tree Trash mutation requires manual recovery; destination path unavailable", .{});
    self.file_tree_manual_recovery_unknown = true;
    self.showNoticeKey(.fp_trash_verify_failed);
}

/// `.pane`/`.tab`처럼 **Term을 통째로 파괴하는** scope가 쓰는 판정. `mode.isEditable()`은 보지 **않는다**
/// — `.text`의 기본 mode가 `source_edit`이라, 보면 손도 안 댄 `script.py` 탭 하나가 그 pane과
/// 워크스페이스를 영영 닫을 수 없게 만든다(code-review max). 대신 `.pane`/`.tab` 경로는 파괴 전에
/// `syncDirtyBeforeScopeClose`로 편집 중 버퍼의 스냅샷을 먼저 요청해, native dirty 지연 때문에
/// 잃는 경우를 막는다. `.session`(⌘Q)은 복구 기회가 없어 여전히 넓은 술어를 쓴다.
pub fn termHasProtectedFilePanel(term: *Term) bool {
    const entry = term.file_entry orelse return false;
    // `dirty_sync_pending`은 **한 번 물어본 뒤에는** 차단 사유가 아니다. 스냅샷을 요청해 두고 그것이
    // 영영 안 오면(브릿지 죽음) 그 pane·워크스페이스가 영원히 안 닫히기 때문이다. 답이 왔다면
    // `entry.dirty`가 서 있어 아래 술어가 정상적으로 막는다(code-review max).
    if (entry.close_snapshot_requested and entry.dirty_sync_pending and !entry.dirty)
        return entry.external_change or entry.conflict_reload_pending or entry.mutation_pending_id != 0;
    return filePanelEntryBlocksClose(entry.*);
}

/// 창 전체에서 그 `EntryId`의 파일 entry.
pub fn fileEntryForId(self: *AppSession, entry_id: dock_panel.EntryId) ?*dock_panel.Entry {
    return fileEntryForIdCounted(self, entry_id, null);
}

/// 창 병합 시 파일 **entry 자체는 옮기지 않는다** — FP16에서 entry는 Term 소유라 워크스페이스(탭)와
/// 함께 자동으로 이동한다. 여기서 하는 일은 그 이동이 destination의 불변식을 깨지 않게 만드는 것뿐이다:
/// 창당 상한·경로 유일성 admission, destination 탐색기/watch 재구성, source-lifetime 래치 정리.
///
/// 창당 경로 유일성(§1)은 여전히 지켜야 한다. 두 창에 같은 파일이 열려 있으면 병합 뒤 한 창에 같은 경로가
/// 두 Term으로 공존하므로 한쪽을 닫는다. **양쪽 다** 잃을 상태를 들고 있으면 어느 내용을 살릴지 자동으로
/// 정하지 않고 병합 자체를 거부하고, 한쪽만 들고 있으면 그 편집을 보존하고 **깨끗한 쪽**을 닫는다.
/// 둘 다 깨끗하면 옮겨오는 쪽(source)을 닫아 destination 배치를 유지한다(§4).
///
/// 실패 가능한 일(admission·트리 후보)을 전부 먼저 끝낸 뒤 무실패 commit으로 넘어가므로, 어느
/// allocation이 실패해도 양쪽 창이 원상 유지된다.
pub fn mergeFilePanelStateInto(src: *AppSession, dst: *AppSession) !void {
    // 1) 창당 상한 admission. 병합 결과가 max_entries를 넘으면 고정 크기 배열을 쓰는 순회들이 넘친다.
    var unique: usize = 0;
    var count_it = fileEntries(src);
    while (count_it.next()) |src_entry| {
        if (fileEntryForPath(dst, src_entry.path) == null) unique += 1;
    }
    if (fileEntryCount(dst) + unique > dock_panel.max_entries) return error.UnsupportedMove;

    // 2) 중복 경로 admission — **닫을 쪽을 여기서 정하고, 정할 수 없으면 모델을 건드리기 전에 거부한다.**
    //    ⓐ 거부 조건은 **양쪽 다 잃을 상태**(`filePanelEntryBlocksClose`)일 때다. 넓은 술어를 쓰면
    //       손도 안 댄 편집 가능 파일(`.text`의 기본 mode가 source_edit)이 창 병합을 막는다(§4).
    //    ⓑ 닫을 쪽이 그 창의 **마지막 Term이 되면** 그 close는 창 닫기라 병합 중에 할 수 없다.
    //       판정은 스냅샷이 아니라 **이번 계획이 그 창에서 몇 개를 닫는지 누적**해서 한다 — 스냅샷으로
    //       보면 같은 창의 두 번째 중복에서 pane이 비고 adoptTab이 빈 pane을 읽어 크래시한다(code-review max).
    const DoomedSide = struct { owner: *AppSession, entry: *dock_panel.Entry };
    var doomed_plan: [dock_panel.max_entries]DoomedSide = undefined;
    var doomed_len: usize = 0;
    const src_terms = workspace_ops.windowTermCount(src);
    const dst_terms = workspace_ops.windowTermCount(dst);
    var src_planned: usize = 0;
    var dst_planned: usize = 0;
    var dup_it = fileEntries(src);
    while (dup_it.next()) |src_entry| {
        const dup = fileEntryForPath(dst, src_entry.path) orelse continue;
        const src_blocks = filePanelEntryBlocksClose(src_entry.*);
        const dst_blocks = filePanelEntryBlocksClose(dup.*);
        if (src_blocks and dst_blocks) return error.UnsupportedMove;
        const prefer_src_doomed = !src_blocks;
        const first: DoomedSide = if (prefer_src_doomed) .{ .owner = src, .entry = src_entry } else .{ .owner = dst, .entry = dup };
        const second: DoomedSide = if (prefer_src_doomed) .{ .owner = dst, .entry = dup } else .{ .owner = src, .entry = src_entry };
        const first_survives = (if (first.owner == src) src_terms - src_planned else dst_terms - dst_planned) > 1;
        const second_blocks = filePanelEntryBlocksClose(second.entry.*);
        const second_survives = (if (second.owner == src) src_terms - src_planned else dst_terms - dst_planned) > 1;
        const chosen = if (first_survives)
            first
        else if (!second_blocks and second_survives)
            second
        else
            return error.UnsupportedMove;
        if (doomed_len >= doomed_plan.len) return error.UnsupportedMove;
        doomed_plan[doomed_len] = chosen;
        doomed_len += 1;
        if (chosen.owner == src) src_planned += 1 else dst_planned += 1;
    }

    // 3) destination 탐색기 후보를 만든다. 옮겨오는 파일이 destination의 recent/watch 집합에 없으면
    //    병합 뒤 그 파일의 외부 변경을 감지하지 못하고 최근 목록에도 안 뜬다.
    //    explorer root/recent **권위는 destination**이다 — source root를 흡수하지 않는다. 다만 양쪽이
    //    inferred면 source가 파일을 열 때 정한 project root가 dirname보다 정확하므로 그걸 쓴다
    //    (`/repo/sub/file.md`가 `/repo`에서 `/repo/sub`로 줄어드는 것을 막는다).
    // 도크에 남은 건 탐색기(트리)뿐이므로 여기서 다루는 "권위"는 root/recent 하나다.
    // destination 탐색기가 **비어 있으면**(root도 recent도 없음) 그건 권위가 아니라 부재다 —
    // 그대로 두면 옮겨온 파일 탭이 자기 프로젝트 루트 없이 도착하므로 source 것을 채택한다.
    // 비어 있지 않으면 destination이 권위다(파일 탭 유무가 아니라 트리 내용이 기준).
    var dst_tree = if (dst.file_tree.hasContent())
        try dst.file_tree.clone()
    else
        try src.file_tree.clone();
    defer dst_tree.deinit(); // commit은 후보를 빈 Tree로 되돌려 준다(단일 출처 commitFileTreeCandidate)
    var watch_extras: [dock_panel.max_entries][]const u8 = undefined;
    var watch_count: usize = 0;
    var dst_watch_it = fileEntries(dst);
    while (dst_watch_it.next()) |entry| if (std.fs.path.dirname(entry.path)) |parent| {
        watch_extras[watch_count] = parent;
        watch_count += 1;
    };
    var incoming_it = fileEntries(src);
    while (incoming_it.next()) |entry| {
        if (fileEntryForPath(dst, entry.path) != null) continue; // clean 중복은 아래에서 닫는다
        const parent = std.fs.path.dirname(entry.path) orelse continue;
        var inferred_root = parent;
        if (dst_tree.rootMode() == .inferred and src.file_tree.rootMode() == .inferred) {
            var source_authority: ?[]const u8 = null;
            for (0..src.file_tree.rootCount()) |root_index| {
                const source_root = src.file_tree.rootAt(root_index).?;
                if (!file_tree.Tree.pathWithinRoot(entry.path, source_root)) continue;
                if (source_authority == null or source_root.len > source_authority.?.len)
                    source_authority = source_root;
            }
            if (source_authority) |root| inferred_root = root;
        }
        try dst_tree.recordOpened(entry.path, inferred_root);
        watch_extras[watch_count] = parent;
        watch_count += 1;
    }
    try dst_tree.resetWatchRequests(watch_extras[0..watch_count]);
    var dst_rows: std.ArrayList(file_tree.Row) = .empty;
    defer dst_rows.deinit(dst.allocator);
    try prepareFileTreeRowStaging(dst, &dst_rows, unique);

    // ── 여기부터 무실패 commit ───────────────────────────────────────────────
    // 4) admission이 정해 둔 계획을 그대로 실행한다(여기서 다시 고르지 않는다).
    for (doomed_plan[0..doomed_len]) |planned| {
        const entry = planned.entry;
        const owner = planned.owner;
        // destination 쪽을 닫을 때는 그 surface를 가리키던 destination one-shot을 **살아남는 쪽**으로
        // 다시 겨눈다. 안 하면 병합 뒤 mode 갱신·typed focus가 방금 사라진 surface를 기다리며 멈춘다.
        const survivor: ?*const dock_panel.Entry = if (owner == dst)
            fileEntryForPath(src, entry.path)
        else
            null;
        const retired_surface = entry.surface_id;
        // 한 번 retire하면 removeFilePanelQueuedActions가 one-shot을 지우므로 **먼저** 읽어 둔다.
        const had_mode_pending = dst.file_panel_mode_pending == retired_surface;
        const had_restore_pending = dst.file_tree_restore_surface_pending == retired_surface;
        const had_focus_pending = if (dst.pending_dock_focus) |pending|
            pending.expected_surface_id == retired_surface
        else
            false;
        // 통지는 destroyTerm 하나만 낸다 — retire까지 통지하면 같은 surface가 두 번 닫힘으로 보고된다.
        var retired_focus = false;
        noteRetiredFilePanelFocus(owner, entry, &retired_focus);
        removeFilePanelQueuedActions(owner, entry.surface_id);
        // admission이 "닫을 수 있는 쪽"만 골랐으므로 여기서는 성공한다.
        _ = closeFileTermForEntry(owner, entry);
        // 닫은 파일이 그 창의 입력 소유였으면 workspace로 되돌린다 — 안 하면 focus_owner가 파괴된
        // surface를 가리킨 채 남아 키가 아무 데도 가지 않는다(code-review max).
        if (retired_focus) {
            owner.focusWorkspaceInput();
            owner.workspace_focus_pending = true;
        }
        if (survivor) |replacement| {
            if (had_mode_pending) dst.file_panel_mode_pending = replacement.surface_id;
            if (had_restore_pending) dst.file_tree_restore_surface_pending = null;
            if (had_focus_pending) dock_ops.queuePendingDockFocus(dst, replacement);
        }
    }
    // 5) source 창 수명에 묶여 있던 래치를 비운다 — 그 큐는 source와 함께 사라지므로, 그대로 옮기면
    //    destination에서 완료해 줄 주체가 없어 reload가 영영 멈춘다.
    var latch_it = fileEntries(src);
    while (latch_it.next()) |entry| {
        entry.conflict_reload_pending = false;
        entry.conflict_reload_generation = 0;
    }
    buildPreparedFileTreeRows(dst, &dst_tree, &dst_rows);
    commitFileTreeCandidate(dst, &dst_tree, &dst_rows);
    // 표시 의도(presented)만 OR로 합친다.
    if (src.dock.presented) dst.dock.presented = true;
    dst.file_tree_rows_dirty = true;
    dst.metal_dirty = true;
}

pub fn requestFilePanelPick(self: *AppSession) void {
    self.file_panel_pick_pending = true;
}

/// 키보드 Page 이동이 쓰는 "온전히 보이는 행 수". 창(`fileTreeDrawWindow`)과 달리 **부분 행을 세지
/// 않는다** — 반쯤 걸친 행까지 한 페이지로 치면 Page Down이 그 행을 건너뛴다.
pub fn fileTreeVisibleRows(self: *const AppSession) usize {
    // 행 높이는 **컴포넌트가 소유한다**(FT1) — 예전에는 `cell_height_px`라 터미널 폰트를 바꾸면
    // 페이지 단위까지 따라 움직였다(docs/plans/file-tree-component.md §1).
    const row_h = file_tree_dock_ops.fileTreeRowHeightPx(self);
    if (row_h == 0) return 0;
    return dock_ops.dockGeometry(self).tree_content.h / row_h;
}

/// 이 entry의 surface가 입력·복원 소유였는지만 기록한다(통지·큐 정리 없음). Term teardown이 통지를
/// 낼 경로에서 쓴다 — 통지를 두 번 내지 않기 위해서다.
pub fn noteRetiredFilePanelFocus(self: *AppSession, entry: *dock_panel.Entry, retired_focus: *bool) void {
    const surface_id = entry.surface_id;
    if (surface_id == 0) return;
    retired_focus.* = retired_focus.* or fileSurfaceOwnsInput(self, surface_id);
}

pub fn takePendingDeleteRoot(self: *AppSession, id: u64) ?[]u8 {
    const pending = self.pending_delete_root orelse return null;
    if (pending.id != id) return null;
    self.pending_delete_root = null;
    return pending.root;
}

pub fn releaseFileTreeMutationEditorLocks(self: *AppSession, mutation_id: u64, unlock: bool) void {
    var write: usize = 0;
    for (self.file_tree_mutation_editor_locks[0..self.file_tree_mutation_editor_locks_len]) |lock| {
        if (lock.mutation_id == mutation_id) {
            removeFilePanelDirtySyncAction(self, lock.surface_id);
            if (fileEntryForSurfaceId(self, lock.surface_id)) |entry| entry.dirty_sync_pending = false;
            if (unlock) queueFilePanelCloseUnlock(self, lock.surface_id, lock.request_id);
            continue;
        }
        self.file_tree_mutation_editor_locks[write] = lock;
        write += 1;
    }
    self.file_tree_mutation_editor_locks_len = write;
}

/// 렌더가 draw list에 넘기는 창. **호출부에 인라인으로 두면 테스트가 그 산술을 복제하게 되고,
/// 복제본은 호출부를 판정하지 못한다** — 실제로 호출부를 상수로 바꾸는 변이가 복제 기반 단언을
/// 통과했다(§10.1).
///
/// 세 값이 한 쌍이다. `origin_shift_px`는 첫 행이 뷰포트 위로 밀려 나간 양이고, 렌더는 pane
/// origin을 그만큼 **올려** 그 행을 부분적으로 보이게 한다. 그래서 `count`는 뷰포트를 덮는 데
/// 필요한 행 수(위·아래 부분 행 포함)이며, 삐져나온 몫은 pane clip이 자른다.
///
/// 행 높이가 균일(`file_tree_dock_ops.fileTreeRowHeightPx`)하므로 `scroll_area.project`의 walk 대신 나눗셈으로 같은 답을
/// 낸다 — 탐색기 행은 수천 개가 될 수 있고 창은 매 프레임 필요하다. 그 둘이 같은 답이라는 것은
/// 테스트가 `project`와 대조해 고정한다(도크는 카드 높이가 가변이라 walk가 필수다).
pub fn fileTreeDrawWindow(self: *const AppSession) file_tree_layout.DrawWindow {
    // 산술은 `session/file_tree_layout.zig` 가 단일 출처다 — 히트테스트와 **같은 함수 쌍**을 써야
    // 누른 행과 강조되는 행이 안 갈린다(그 짝은 그쪽 테스트가 못 박는다).
    return file_tree_layout.drawWindow(
        file_tree_dock_ops.fileTreeRowHeightPx(self),
        fileTreeEffectiveScrollPx(self),
        dock_ops.dockGeometry(self).tree_content.h,
        self.file_tree_rows.items.len,
    );
}

/// 호버를 **버린다**(값을 넣는 setter 는 없다 — FT2 이후 호버의 주인은 `InteractionState` 하나다).
///
/// 목록이 다시 투영되거나 스크롤로 자리가 바뀌면 예전 노드 id 는 다른 행을 가리킨다. 그때 호버를
/// 들고 있으면 **마우스를 움직이지 않았는데 엉뚱한 행이 밝아진다**. capture 는 건드리지 않는다 —
/// 누르고 있는 손가락은 목록 갱신과 무관하게 이어져야 하고, 그 취소는 발행 경로가 tree 가 실제로
/// 바뀌었을 때만 한다.
pub fn clearFileTreeHover(self: *AppSession) void {
    if (self.file_tree_interaction.hovered == null) return;
    self.file_tree_interaction.hovered = null;
    self.metal_dirty = true;
}

pub fn prepareFileTreeRenameRemap(self: *AppSession, id: u64, old_path: []const u8, new_path: []const u8) !void {
    var plan = PendingRenameRemap{ .id = id };
    errdefer plan.deinit(self.allocator);
    var entry_it6 = fileEntries(self);
    while (entry_it6.next()) |entry| {
        const replacement = (try file_tree_mutation.remapPath(self.allocator, entry.path, old_path, new_path)) orelse continue;
        const expected = try self.allocator.dupe(u8, entry.path);
        const new_kind: ?dock_panel.EntryKind = if (file_panel_bridge.openKindForPath(replacement)) |k|
            entryKindForOpenKind(k)
        else
            null;
        plan.dock_items[plan.dock_len] = .{
            .expected = expected,
            .replacement = replacement,
            .new_kind = new_kind,
        };
        plan.dock_len += 1;
    }
    // No supported open can enter while the mutation is in flight, so conflicts only need to be
    // rejected once at admission. Completion re-resolves each item by its **expected path** and
    // re-checks the `mutation_pending_id` stamp, so an unrelated close/reorder — or a close followed
    // by a reopen of the same path — cannot redirect the delayed rename acknowledgement (FP16 §1 ⑷).
    for (plan.dock_items[0..plan.dock_len]) |item| if (fileEntryForPath(self, item.replacement) != null)
        return error.PathConflict;
    for (0..self.file_tree.recentCount()) |index| {
        const recent = self.file_tree.recentAt(index).?;
        const replacement = (try file_tree_mutation.remapPath(self.allocator, recent, old_path, new_path)) orelse continue;
        const expected = try self.allocator.dupe(u8, recent);
        plan.recent_items[plan.recent_len] = .{ .index = index, .expected = expected, .replacement = replacement };
        plan.recent_len += 1;
    }
    if (self.pending_rename_remap) |*old| old.deinit(self.allocator);
    self.pending_rename_remap = plan;
}

pub fn confirmFileTreeDelete(self: *AppSession) void {
    const pending = self.pending_file_tree_delete orelse return;
    self.pending_file_tree_delete = null;
    if (pending.root_generation != self.file_tree.rootGeneration()) {
        self.showNoticeKey(.fp_root_changed_delete_cancel);
        return;
    }
    const target: file_tree_mutation.Target = .{
        .kind = pending.row_kind,
        .path = pending.path(),
        .symlink = pending.symlink,
        .identity = pending.identity,
        .parent_identity = pending.parent_identity,
        .root_identity = pending.root_identity,
    };
    const root = self.file_tree.rootForMutation(target.path) orelse return;
    if (target.kind == .directory and fileTreeDirectoryAliasRisk(self, target.path, root)) {
        self.showNoticeKey(.fp_state_changed_dir_delete_cancel);
        return;
    }
    const roots = [_][]const u8{root};
    var protections: [dock_panel.max_entries]file_tree_mutation.Protection = undefined;
    const protection_len = fillFileTreeProtections(self, &protections);
    const plan = file_tree_mutation.planDelete(&roots, target, protections[0..protection_len]) catch {
        self.showNoticeKey(.fp_state_changed_delete_cancel);
        return;
    };
    if (plan.identity == null or plan.parent_identity == null or plan.root_identity == null) {
        self.showNoticeKey(.fp_identity_not_ready);
        return;
    }
    if (!self.file_tree_mutation_backend.tryReserve()) {
        self.showNoticeKey(.fp_mutation_queue_full);
        return;
    }
    self.file_tree_mutation_queue_reserved = true;
    var keep_queue_reservation = false;
    defer if (self.file_tree_mutation_queue_reserved and !keep_queue_reservation) {
        self.file_tree_mutation_backend.cancelReservation();
        self.file_tree_mutation_queue_reserved = false;
    };
    const id = nextFileTreeMutationRequestId(self) orelse return;
    var request = file_tree_mutation_backend.Request.init(self.allocator, id, plan) catch return;
    request.selection_generation = self.file_tree_selection.generation;
    const owned_root = self.allocator.dupe(u8, root) catch {
        request.deinit(self.allocator);
        self.showNoticeKey(.fp_delete_recovery_prepare_failed);
        return;
    };
    std.debug.assert(self.pending_delete_root == null);
    self.pending_delete_root = .{ .id = id, .root = owned_root };
    if (!reserveFileTreeMutation(self, id, target.path)) {
        request.deinit(self.allocator);
        discardPendingDeleteRoot(self, id);
        self.showNoticeKey(.fp_entry_busy);
        return;
    }
    const waiting = beginFileTreeMutationEditorLocks(self, id, target.path) catch {
        request.deinit(self.allocator);
        clearFileTreeMutationReservation(self, id);
        discardPendingDeleteRoot(self, id);
        self.showNoticeKey(.fp_editor_lock_trash_failed);
        return;
    };
    if (waiting) {
        self.file_tree_mutation_waiting_request = request;
        self.file_tree_delete_inflight = true;
        keep_queue_reservation = true;
        return;
    }
    self.file_tree_mutation_backend.submitReserved(request);
    self.file_tree_mutation_queue_reserved = false;
    self.file_tree_delete_inflight = true;
    self.file_tree_mutation_backend.pump();
}

pub fn classifyFileTreeRowsCounted(rows: []file_tree.Row, counters: ?*FileTreePerfCounters) void {
    // **분류 자체는 공유 모듈이 소유한다**(`cell_text.classifyFileTreeRows`) — Windows 트리도 같은
    // 것을 쓴다. 여기 남는 것은 계측뿐이다.
    if (counters) |value| {
        value.row_visits += rows.len;
        // `.empty` 행은 분류를 안 탄다 — 그 하나만 빼고 센다(옛 per-row 계측과 같은 수).
        for (rows) |row| if (row != .empty) {
            value.classifier_calls += 1;
        };
    }
    maru.cell_text.classifyFileTreeRows(rows);
}

/// 절대 경로의 부모를 root fd부터 component별 openat(NO_FOLLOW)으로 걷는다. 이후 원본 검사·temp 생성·commit은
/// 모두 이 동일 directory capability와 basename에 상대적으로 수행하므로, 검사 뒤 parent path가 symlink/다른
/// directory로 교체돼도 새 경로를 다시 열어 엉뚱한 파일을 덮지 않는다.
pub fn openPinnedFilePanelParent(io: std.Io, absolute_path: []const u8) FilePanelWriteError!PinnedFilePanelParent {
    if (!std.fs.path.isAbsolute(absolute_path)) return error.NotFound;
    const parent_path = std.fs.path.dirname(absolute_path) orelse return error.NotFound;
    const basename = std.fs.path.basename(absolute_path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.NotFound;

    var current = std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false }) catch return error.NotFound;
    errdefer current.close(io);
    var components = std.mem.tokenizeScalar(u8, if (parent_path.len > 0) parent_path[1..] else parent_path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.NotFound;
        const next = current.openDir(io, component, .{ .follow_symlinks = false }) catch return error.NotFound;
        current.close(io);
        current = next;
    }
    return .{ .dir = current, .basename = basename };
}

pub fn fileTreeScrollExtent(self: *const AppSession) FileTreeScrollExtent {
    // 행 높이는 컴포넌트가 소유한다(FT1). 여기서 셀 높이를 쓰면 스크롤 상한이 **그린 행 높이와 다른**
    // 축으로 계산돼, 목록 끝에서 몇 행이 영영 안 보이거나 빈 공간이 남는다.
    const row_h = file_tree_dock_ops.fileTreeRowHeightPx(self);
    const viewport = dock_ops.dockGeometry(self).tree_content.h;
    const content: u32 = @intCast(@min(
        @as(u64, self.file_tree_rows.items.len) * @as(u64, row_h),
        @as(u64, std.math.maxInt(u32)),
    ));
    return .{ .content_h_px = content, .viewport_h_px = viewport, .max_offset_px = content -| viewport };
}

/// 재투영 뒤 선택을 신원으로 되찾는다. **아직 보여 준 적 없는 선택일 때만** 그 행으로 스크롤한다.
///
/// ⚠️ 그 조건이 이 함수의 본체다. 재투영은 사용자 조작과 무관하게 돈다 — FSEvents, 배경 스캔 완료,
/// git ignore 판정 도착, 활성 파일 변경이 전부 `file_tree_rows_dirty`를 세우고 `updateFileTree`가 매
/// frame tick 그것을 본다. 그때마다 `scrollFileTreeRowIntoView`를 걸면 **사용자가 내려둔 목록이 선택 행
/// 자리로 되감긴다**(2026-08-28 사용자 보고 — "선택한 것보다 밑으로 내려가면 스크롤이 원복된다").
/// 스크롤은 필요할 때만 뺏는다는 규칙(file-explorer.md §1 정책 4)에서 "필요할 때"는 **그 선택을 아직
/// 안 보여 준 때**이지 목록을 다시 그린 때가 아니다.
///
/// 반환값으로는 그것을 못 가른다: `Selection.reconcile`은 제자리 exact match 에서도 인덱스를 준다
/// (그것이 `reconcileIdentity`의 첫 갈래다). `generation` 만으로도 부족하다 — 생성·이름변경은 행이
/// 투영되기 **전에** `setIdentity`로 선택을 예약해 그 시점에 generation 을 올리므로, "바뀌었나"로
/// 물으면 정작 새 항목이 도착했을 때가 "제자리"로 보여 뷰포트 밖에 조용히 남는다. 그래서 축을 하나 더
/// 두고(`file_tree_revealed_selection_generation`) **보여 준 신원**을 기억한다.
pub fn reconcileFileTreeSelection(self: *AppSession) void {
    if (self.file_tree_selection.kind == null) {
        if (fileTreeFocused(self)) selectFirstFileTreeRow(self);
        return;
    }
    const resolved = self.file_tree_selection.reconcile(self.file_tree_rows.items) orelse return;
    if (self.file_tree_revealed_selection_generation == self.file_tree_selection.generation) return; // 이미 보여 줬다 — 스크롤은 사용자 것이다
    if (scrollFileTreeRowIntoView(self, resolved))
        self.file_tree_revealed_selection_generation = self.file_tree_selection.generation;
}

pub fn openCreatedFilePanel(self: *AppSession, path: []const u8, root: []const u8) void {
    const open_kind = file_panel_bridge.openKindForPath(path) orelse return;
    var candidate = self.file_tree.clone() catch return;
    defer candidate.deinit();
    candidate.recordOpened(path, root) catch return;
    resetFileTreeWatchRootsFor(self, &candidate, path) catch return;
    var candidate_rows: std.ArrayList(file_tree.Row) = .empty;
    defer candidate_rows.deinit(self.allocator);
    prepareFileTreeRowStaging(self, &candidate_rows, 1) catch return;
    const kind = entryKindForOpenKind(open_kind);
    // FP16: 생성 경로도 Term을 만든다. 옛 `dock.open`을 그대로 두면 창구(pane 트리 walk)가 못 보는
    // orphan entry가 생겨 같은 파일을 트리에서 다시 열 때 중복 Term이 만들어진다(code-review max).
    const opened = pane_ops.openFileTermInActivePane(self, path, kind) catch return;
    buildPreparedFileTreeRows(self, &candidate, &candidate_rows);
    commitFileTreeCandidate(self, &candidate, &candidate_rows);
    if (opened.previous_active_term) |prev| if (prev != opened.term) {
        if (prev.file_entry) |prev_entry| _ = markFilePanelDirtySyncPending(self, prev_entry);
    };
    const entry = opened.term.file_entry orelse return;
    // Creation was initiated from the tree: keep tree keyboard ownership while the new WebView is
    // created, so subsequent arrows/F2 do not unexpectedly type into CM6.
    self.focus_owner = .{ .file_tree = .{ .restore_surface = entry.surface_id } };
    self.file_tree_focus_pending = true;
    self.file_panel_mode_pending = entry.surface_id;
    self.dock.collapsed = false;
}

/// 그 EntryId가 **활성 워크스페이스**의 파일인가. publish 대기 barrier가 보이지 않는 파일을 가리킨 채
/// 입력을 삼키지 않게 하는 게이트다.
pub fn activeTabHasFileEntry(self: *const AppSession, entry_id: dock_panel.EntryId) bool {
    if (self.tabs.items.len == 0) return false;
    const tab = self.tabs.items[self.app_window.active_tab];
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            const entry = term.file_entry orelse continue;
            if (entry.id == entry_id) return true;
        }
    }
    return false;
}

pub fn focusFileTree(self: *AppSession) void {
    if (!self.dock_initialized or !self.dock.presented) return;
    dock_ops.cancelPendingDockFocus(self);
    if (self.dock.collapsed) activateFilePanelDockControl(self);
    // 다른 뷰를 보는 중이면 먼저 탐색기로 되돌린다 — 보이지 않는 트리에 키 입력이 가면 안 된다
    // (docs/file-explorer.md §3.5). 접힘 해제와 같은 급의 "포커스 전에 보이게 만든다" 처리다.
    if (self.dock.view != .explorer) {
        self.dock.view = .explorer;
        self.metal_dirty = true;
    }
    const restore_surface: ?u64 = switch (self.focus_owner) {
        .file_tree => |owner| owner.restore_surface,
        // workspace 소유 중 활성 Term이 파일이면 그 surface가 Esc 복원 대상이다(옛 `.dock_surface`).
        .workspace => self.focusedDockSurface(),
        .dock_pending => null,
    };
    self.focus_owner = .{ .file_tree = .{ .restore_surface = restore_surface } };
    self.workspace_focus_pending = false;
    self.file_tree_restore_surface_pending = null;
    self.file_tree_focus_pending = true;
    if (selectedFileTreeRow(self) == null) selectFirstFileTreeRow(self);
    self.metal_dirty = true;
}

pub fn fileTreeNamespaceMutationBusy(self: *const AppSession) bool {
    return fileTreeFileMutationBusy(self) or
        self.file_tree_root_pick_pending != .none or self.file_tree_root_picker_inflight != .none or
        self.file_tree_root_validation != null;
}

/// 헤더 밴드에서 mode를 고른다. 허용되지 않는 조합(§2.2 `Mode.allowedFor`)이나 무변화는 무동작이고,
/// 바뀌면 shell에 한 번 전달할 one-shot을 세운다(`takeFilePanelModeAction`).
pub fn setFilePanelMode(self: *AppSession, entry: *dock_panel.Entry, mode: dock_panel.Mode) void {
    if (entry.mode == mode or !mode.allowedFor(entry.kind)) return;
    entry.mode = mode;
    self.file_panel_mode_pending = entry.surface_id;
    self.file_tree_rows_dirty = true;
    self.workspaceChanged(.persisted_surface);
}

pub fn updateFileTreeMutations(self: *AppSession) void {
    self.file_tree_mutation_backend.pump();
    var result = self.file_tree_mutation_backend.takeResult() orelse return; // max one completion per frame
    defer result.deinit(self.allocator);
    if (!result.ok) {
        if (result.recovery_required) {
            if (result.operation == .stage_delete) {
                self.file_tree_delete_inflight = false;
                discardPendingDeleteRoot(self, result.id);
            }
            retainFileTreeRecoveryPath(self, result.target);
            result.target_transferred = true;
            return;
        }
        if (result.operation == .rename and self.file_tree_rename_rollback_id == result.id) {
            // The filesystem remains at the post-rename path. Keep reservation/editor locks and
            // exact model plan fail-closed; transfer the worker-owned path without allocating.
            self.file_tree_rename_rollback_id = null;
            retainFileTreeRecoveryPath(self, result.source);
            result.source_transferred = true;
            return;
        }
        if (result.operation == .stage_delete) {
            self.file_tree_delete_inflight = false;
            discardPendingDeleteRoot(self, result.id);
        }
        if (result.operation == .create_file or result.operation == .create_directory or result.operation == .rename)
            self.file_tree_edit_inflight = false;
        if (result.operation == .rename) discardPendingRenameRemap(self, result.id);
        if (self.file_tree_rename_rollback_id == result.id) self.file_tree_rename_rollback_id = null;
        if (result.operation == .stage_delete or result.operation == .restore_delete or result.operation == .rename) {
            clearFileTreeMutationReservation(self, result.id);
            releaseFileTreeMutationEditorLocks(self, result.id, true);
        }
        if (result.operation == .restore_delete) {
            finishPendingTrashRecord(self, result.id);
            retainFileTreeRecoveryPath(self, result.source);
            result.source_transferred = true;
            return;
        }
        self.showNoticeKey(switch (result.failure) {
            .collision => .fp_mutation_collision,
            .not_found => .fp_mutation_not_found,
            .denied => .fp_mutation_denied,
            else => .fp_mutation_failed,
        });
        return;
    }
    const parent = std.fs.path.dirname(if (result.operation == .stage_delete) result.source else result.target) orelse return;
    switch (result.operation) {
        .create_file, .create_directory => {
            self.file_tree_edit_inflight = false;
            self.file_tree.invalidatePath(parent) catch {};
            const kind: file_tree.RowKind = if (result.operation == .create_directory) .directory else .file;
            if (self.file_tree_selection.generation == result.selection_generation)
                _ = self.file_tree_selection.setIdentity(kind, result.target, self.file_tree_selection.index_hint);
            if (result.operation == .create_file) if (self.file_tree.rootForMutation(result.target)) |root|
                openCreatedFilePanel(self, result.target, root);
        },
        .rename => {
            if (self.file_tree_rename_rollback_id == result.id) {
                self.file_tree_rename_rollback_id = null;
                self.file_tree_edit_inflight = false;
                clearFileTreeMutationReservation(self, result.id);
                releaseFileTreeMutationEditorLocks(self, result.id, true);
                discardPendingRenameRemap(self, result.id);
                self.file_tree.invalidatePath(std.fs.path.dirname(result.target) orelse result.target) catch {};
                self.showNoticeKey(.fp_edit_state_changed_rename_cancel);
                return;
            }
            if (fileTreePathProtectedNow(self, result.source, result.id)) {
                if (!enqueueFileTreeRenameRollback(self, result)) {
                    retainFileTreeRecoveryPath(self, result.target);
                    result.target_transferred = true;
                }
                return;
            }
            if (!applyFileTreeRename(self, result.id, result.target)) {
                if (!enqueueFileTreeRenameRollback(self, result)) {
                    retainFileTreeRecoveryPath(self, result.target);
                    result.target_transferred = true;
                }
                return;
            }
            self.file_tree_edit_inflight = false;
            clearFileTreeMutationReservation(self, result.id);
            releaseFileTreeMutationEditorLocks(self, result.id, false);
            self.file_tree.invalidatePath(parent) catch {};
            if (self.file_tree_selection.generation == result.selection_generation)
                _ = self.file_tree_selection.setIdentity(result.row_kind, result.target, self.file_tree_selection.index_hint);
        },
        .stage_delete => {
            self.file_tree_delete_inflight = false;
            const owned_root = takePendingDeleteRoot(self, result.id) orelse {
                clearFileTreeMutationReservation(self, result.id);
                releaseFileTreeMutationEditorLocks(self, result.id, true);
                retainFileTreeRecoveryPath(self, result.target);
                result.target_transferred = true;
                return;
            };
            const identity = result.identity orelse {
                self.allocator.free(owned_root);
                clearFileTreeMutationReservation(self, result.id);
                releaseFileTreeMutationEditorLocks(self, result.id, true);
                retainFileTreeRecoveryPath(self, result.target);
                result.target_transferred = true;
                return;
            };
            // A source editor may have become dirty while the worker was pinning/staging. Restore instead
            // of handing the staged URL to AppKit in that case.
            if (fileTreePathProtectedNow(self, result.source, result.id)) {
                const restoring = enqueueFileTreeDeleteRestore(
                    self,
                    result.id,
                    owned_root,
                    result.target,
                    result.source,
                    identity,
                    result.parent_identity,
                    result.root_identity,
                );
                self.allocator.free(owned_root);
                if (restoring) {
                    self.showNoticeKey(.fp_edit_state_changed_trash_cancel);
                } else {
                    clearFileTreeMutationReservation(self, result.id);
                    releaseFileTreeMutationEditorLocks(self, result.id, true);
                    retainFileTreeRecoveryPath(self, result.target);
                    result.target_transferred = true;
                }
                return;
            }
            if (self.file_tree_trash_queue_len >= self.file_tree_trash_queue.len) {
                const restoring = enqueueFileTreeDeleteRestore(
                    self,
                    result.id,
                    owned_root,
                    result.target,
                    result.source,
                    identity,
                    result.parent_identity,
                    result.root_identity,
                );
                self.allocator.free(owned_root);
                if (restoring) {
                    self.showNoticeKey(.fp_trash_adapter_queue_full);
                } else {
                    clearFileTreeMutationReservation(self, result.id);
                    releaseFileTreeMutationEditorLocks(self, result.id, true);
                    retainFileTreeRecoveryPath(self, result.target);
                    result.target_transferred = true;
                }
                return;
            }
            self.file_tree_trash_queue[self.file_tree_trash_queue_len] = .{
                .id = result.id,
                .root = owned_root,
                .original = result.source,
                .staged = result.target,
                .identity = identity,
                .parent_identity = result.parent_identity,
                .root_identity = result.root_identity,
                .row_kind = result.row_kind,
                .selection_generation = result.selection_generation,
            };
            self.file_tree_trash_queue_len += 1;
            result.source_transferred = true;
            result.target_transferred = true;
        },
        .restore_delete => {
            clearFileTreeMutationReservation(self, result.id);
            releaseFileTreeMutationEditorLocks(self, result.id, true);
            finishPendingTrashRecord(self, result.id);
            self.showNoticeKey(.fp_trash_failed_restored);
        },
    }
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

/// 그 surface의 파일 Term이 **지금 화면에 있나** — 활성 탭의 어느 pane에서든 그 pane의 활성 Term이면
/// 보인다(split이면 여러 개가 동시에 보일 수 있다). 옛 도크의 "group의 active entry" 재증명 자리다.
pub fn fileSurfaceIsVisible(self: *const AppSession, surface_id: u64) bool {
    if (surface_id == 0 or self.tabs.items.len == 0) return false;
    const tab = self.tabs.items[self.app_window.active_tab];
    for (tab.panes.items) |pane| {
        if (pane.terms.items.len == 0) continue;
        const entry = pane.activeTerm().file_entry orelse continue;
        if (entry.surface_id == surface_id) return true;
    }
    return false;
}

pub fn filePanelDockControlAction(self: *const AppSession) ?FilePanelDockControlAction {
    if (!self.dock_initialized) return null;
    if (!self.dock.presented) return .open;
    return if (self.dock.collapsed) .expand else .collapse;
}

pub fn copyPendingFileTreeDelete(target: file_tree_mutation.Target, root_generation: u64) ?PendingFileTreeDelete {
    if (target.path.len > std.fs.max_path_bytes) return null;
    var out = PendingFileTreeDelete{
        .row_kind = target.kind,
        .symlink = target.symlink,
        .identity = target.identity,
        .parent_identity = target.parent_identity,
        .root_identity = target.root_identity,
        .root_generation = root_generation,
    };
    @memcpy(out.path_buf[0..target.path.len], target.path);
    out.path_len = target.path.len;
    return out;
}

/// 이미 핀한 parent와 original fd를 사용해 저장한다. macOS에서는 temp↔leaf를 RENAME_SWAP 한 뒤 양쪽 inode가
/// 예상한 original/replacement인지 검증한다. leaf가 검사 뒤 교체됐으면 swap을 되돌려 경쟁 파일을 보존하고
/// ExternalConflict로 실패한다. 다른 플랫폼의 헤드리스 빌드는 같은 pinned parent에서 std atomic replace를 쓴다.
pub fn writePinnedFilePanel(
    io: std.Io,
    parent: std.Io.Dir,
    basename: []const u8,
    original: std.Io.File,
    original_stat: std.Io.File.Stat,
    expected_content_hash: u64,
    content: []const u8,
) FilePanelWriteError!void {
    if (builtin.os.tag != .macos) {
        var atomic = parent.createFileAtomic(io, basename, .{
            .permissions = original_stat.permissions,
            .replace = true,
        }) catch return error.WriteFailed;
        defer atomic.deinit(io);
        atomic.file.writeStreamingAll(io, content) catch return error.WriteFailed;
        atomic.file.sync(io) catch return error.WriteFailed;
        atomic.replace(io) catch return error.WriteFailed;
        return;
    }

    var random: u64 = undefined;
    io.random(std.mem.asBytes(&random));
    var temp_name_buf: [40]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_name_buf, ".maru-save-{x}", .{random}) catch return error.WriteFailed;
    var replacement = parent.createFile(io, temp_name, .{
        .exclusive = true,
        .permissions = original_stat.permissions,
    }) catch return error.WriteFailed;
    defer replacement.close(io);
    const created_stat = replacement.stat(io) catch return error.WriteFailed;
    var temp_owned_inode: ?std.Io.File.INode = created_stat.inode;
    defer if (temp_owned_inode) |inode| deletePinnedFilePanelNameIfInode(io, parent, temp_name, inode);

    // rename-replace는 새 inode가 되므로 원본 ACL/xattr/owner를 temp fd로 먼저 복사한다. metadata 복사가 실패하면
    // 원본을 그대로 두고 저장 자체를 실패시켜 quarantine·Finder tag 등을 조용히 잃지 않는다.
    if (std.c.fcopyfile(original.handle, replacement.handle, null, .{
        .ACL = true,
        .STAT = true,
        .XATTR = true,
    }) != 0) return error.WriteFailed;
    replacement.writeStreamingAll(io, content) catch return error.WriteFailed;
    replacement.sync(io) catch return error.WriteFailed;
    const replacement_stat = replacement.stat(io) catch return error.WriteFailed;

    // temp 작성 중 같은 inode가 외부에서 in-place 수정됐는지도 content token으로 잡는다. stat-before/hash/
    // stat-after가 안정된 동일 inode만 허용하고, 여기서 swap까지의 최소 namespace gap만 플랫폼 한계로 남긴다.
    var current = openFilePanelRead(parent, basename, false) catch return error.ExternalConflict;
    defer current.close(io);
    const current_hash = try stableOpenedFileHash(io, current, original_stat.inode);
    if (current_hash != expected_content_hash) return error.ExternalConflict;

    // 최초 commit도 이름만 믿지 않는다. temp가 우리가 만든 replacement이고 leaf가 처음 연 original인 pair가
    // 직전까지 유지될 때만 swap한다. 외부 leaf/temp 교체를 관측하면 namespace를 전혀 바꾸지 않고 conflict.
    if (!swapPinnedFilePanelNamesIfPair(
        io,
        parent,
        temp_name,
        replacement_stat.inode,
        basename,
        original_stat.inode,
    )) return error.ExternalConflict;
    // swap 뒤 temp 이름은 더 이상 우리가 만든 inode라고 가정할 수 없다. 양쪽 identity 검증 또는 성공한 rollback
    // 전에는 defer가 임의 경쟁 파일을 지우지 않게 소유권을 내린다.
    temp_owned_inode = null;
    const committed_pair_valid = validate: {
        var committed = openFilePanelRead(parent, basename, false) catch break :validate false;
        defer committed.close(io);
        var displaced = openFilePanelRead(parent, temp_name, false) catch break :validate false;
        defer displaced.close(io);
        const committed_stat = committed.stat(io) catch break :validate false;
        const displaced_stat = displaced.stat(io) catch break :validate false;
        break :validate committed_stat.kind == .file and displaced_stat.kind == .file and
            committed_stat.inode == replacement_stat.inode and displaced_stat.inode == original_stat.inode;
    };
    if (!committed_pair_valid) {
        // rollback 권위는 관측된 임의 inode가 아니라 original/replacement 고정 pair뿐이다. pair가 달라졌으면
        // 경쟁자가 둔 temp를 leaf로 승격하지 않고 추가 namespace mutation 없이 conflict로 남긴다.
        if (swapPinnedFilePanelNamesIfPair(
            io,
            parent,
            temp_name,
            original_stat.inode,
            basename,
            replacement_stat.inode,
        )) temp_owned_inode = replacement_stat.inode;
        return error.ExternalConflict;
    }
    temp_owned_inode = original_stat.inode; // 검증된 displaced original만 commit 완료 뒤 제거한다.
}

/// 따라간 cwd의 행을 뷰포트 안으로 **최소한만** 민다(file-explorer §1 정책 4 — 이미 보이면 스크롤을 안 뺏는다).
pub fn scrollFileTreeToFollowedCwd(self: *AppSession) void {
    if (!self.file_tree_follow_scroll_pending) return;
    const target = self.file_tree_followed_cwd orelse {
        self.file_tree_follow_scroll_pending = false;
        return;
    };
    if (self.cell_height_px == 0) return; // 렌더 전 — 다음 tick에 다시 본다(pending 유지)
    if (fileTreeScrollExtent(self).viewport_h_px == 0) return;
    const row_index = blk: {
        for (self.file_tree_rows.items, 0..) |row, i| {
            const path = maru.session.file_tree.rowPath(row) orelse continue;
            if (std.mem.eql(u8, path, target)) break :blk i;
        }
        break :blk null;
    } orelse return; // 아직 그 행이 안 보인다(lazy scan 진행 중) — pending 유지, 다음 재투영에서 다시 본다
    self.file_tree_follow_scroll_pending = false;
    // 키보드 anchor와 **같은** 최소 이동을 쓴다. 예전에는 여기 산술이 따로 있었고, 픽셀로 옮기면
    // 두 벌이 각각 갈릴 자리였다.
    _ = scrollFileTreeRowIntoView(self, row_index); // 위 두 게이트가 이미 같은 조건을 봤다
}

pub fn removeFilePanelQueuedActions(self: *AppSession, surface_id: u64) void {
    removeFilePanelDirtySyncAction(self, surface_id);
    if (self.file_panel_mode_pending == surface_id) self.file_panel_mode_pending = null;
    if (self.pending_dock_focus) |pending| {
        if (pending.expected_surface_id == surface_id) {
            self.pending_dock_focus = null;
            self.pending_dock_focus_action = false;
        }
    }
    if (self.file_panel_save_close_pending) |pending| {
        if (pending.surface_id == surface_id) self.file_panel_save_close_pending = null;
    }
    var unlock_i: usize = 0;
    while (unlock_i < self.file_panel_close_unlock_actions_len) {
        if (self.file_panel_close_unlock_actions[unlock_i].surface_id != surface_id) {
            unlock_i += 1;
            continue;
        }
        const last = self.file_panel_close_unlock_actions_len - 1;
        self.file_panel_close_unlock_actions[unlock_i] = self.file_panel_close_unlock_actions[last];
        self.file_panel_close_unlock_actions_len = last;
    }
    var i: usize = 0;
    while (i < self.file_tree_reload_actions_len) {
        if (self.file_tree_reload_actions[i].surface_id != surface_id) {
            i += 1;
            continue;
        }
        const last = self.file_tree_reload_actions_len - 1;
        self.file_tree_reload_actions[i] = self.file_tree_reload_actions[last];
        self.file_tree_reload_actions_len = last;
    }
}

/// close transaction의 모든 예약을 한 곳에서 회수한다. sync one-shot이 아직 queue에 있든 이미 WebKit으로
/// 넘어갔든 entry protection을 즉시 내리고 request-scoped unlock을 보낸다. 늦은 success/failure ack는
/// pending request id가 없어 닫기를 진행하지 못한다.
pub fn cancelFilePanelClose(self: *AppSession) void {
    const pending = self.pending_file_panel_close orelse return;
    // 보호 플래그는 unlock된 editor가 request_id=0 최신 snapshot을 보고할 때까지 유지한다. 여기서 내리면
    // native clean이 stale인 상태에서 비활성 WKWebView가 LRU eviction되어 미저장 buffer를 잃을 수 있다.
    removeFilePanelDirtySyncAction(self, pending.surface_id);
    if (self.file_panel_save_close_pending) |save| {
        if (save.surface_id == pending.surface_id and save.request_id == pending.request_id) {
            self.file_panel_save_close_pending = null;
        }
    }
    queueFilePanelCloseUnlock(self, pending.surface_id, pending.request_id);
    clearFilePanelCloseWithoutUnlock(self);
}

/// staged 목록의 entry들을 대상 pane에 파일 Term으로 **이관**한다. 실패 지점이 없어야 부분 이관이 안 남으므로
/// Term 생성과 capacity 예약을 먼저 끝내고 마지막에 무실패로 붙인다(기존 swap 구간과 같은 규율).
/// staged 목록의 entry들을 대상 pane에 파일 Term으로 **이관**한다. 부분 이관이 남으면 안 되므로
/// **할 수 있는 실패를 모두 앞에서 끝낸다** — Term·heap Entry 생성과 capacity 예약을 마친 뒤, 마지막 루프는
/// 실패 지점이 하나도 없다(기존 swap 구간의 "teardown 뒤 append는 무실패" 규율과 같다).
pub fn transferRestoredFileEntries(
    self: *AppSession,
    entries: *RestoredFileEntries,
    pane: *Pane,
) !void {
    // §5.0 마이그레이션 규칙: 옛 `dock-entry`를 이어 붙이는 중에도 **창당 경로 유일성**을 강제한다.
    // 이 시점 `self.tabs`는 아직 옛 것이지만 `pane`은 새로 만든 탭의 것이므로, 이미 배치된 새 탭들의
    // 파일 Term을 기준으로 본다. 중복은 첫 번째(pane이 자기 `file-term`으로 들고 온 것)만 남긴다.
    {
        var i: usize = 0;
        while (i < entries.items.items.len) {
            const candidate = entries.items.items[i];
            if (restoredPaneHasPath(self, pane, candidate.path)) {
                _ = entries.items.orderedRemove(i);
                self.allocator.free(candidate.path);
                if (entries.active_index) |ai| {
                    if (ai == i) entries.active_index = null else if (ai > i) entries.active_index = ai - 1;
                }
                continue;
            }
            i += 1;
        }
    }
    var had_file_terms = false;
    for (pane.terms.items) |term| {
        if (term.file_entry != null) had_file_terms = true;
    }
    const count = entries.items.items.len;
    if (count == 0) return;

    const Pending = struct { term: *Term, heap: *dock_panel.Entry };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(self.allocator);
    try pending.ensureTotalCapacity(self.allocator, count);
    errdefer for (pending.items) |p| {
        term_ops.destroyTerm(self, p.term); // term.file_entry는 아직 null이라 heap을 건드리지 않는다
        self.allocator.destroy(p.heap);
    };
    try pane.terms.ensureUnusedCapacity(self.allocator, count);

    for (entries.items.items) |entry| {
        const heap = try self.allocator.create(dock_panel.Entry);
        errdefer self.allocator.destroy(heap);
        const term = try web_ops.createWebTerm(self, panelKindForEntryKind(entry.kind));
        heap.* = entry; // path 소유가 목록에서 heap Entry로 이동
        pending.appendAssumeCapacity(.{ .term = term, .heap = heap });
    }

    // ── 여기부터 무실패 ──
    const first_index = pane.terms.items.len;
    for (pending.items) |p| {
        p.heap.surface_id = p.term.surfaceId();
        p.term.file_entry = p.heap;
        pane.terms.appendAssumeCapacity(p.term);
    }
    // 호출자(applyWorkspaceWindow)가 이미 "비어 있지 않으면 하나는 활성"으로 정규화해 둔다.
    // 단, 이 pane이 **이미 새 포맷(`file-term`)으로 자기 파일 탭을 들고 왔으면** 그 `active-term`이
    // 권위다 — legacy `dock-entry` 마이그레이션은 **이어 붙이기**지 활성 전환이 아니다(§5.0).
    const active_index = entries.active_index orelse 0;
    if (!had_file_terms and first_index + active_index < pane.terms.items.len) {
        pane.active_term = first_index + active_index;
    }
    // 목록은 더 이상 path를 소유하지 않는다(heap Entry로 이동) — 해제 없이 비운다.
    entries.items.clearRetainingCapacity();
    entries.active_index = null;
}

/// CM6 문서 변경 상태를 도크 모델에 미러한다. Markdown surface만 허용하고 값이 바뀔 때만 redraw한다.
pub fn setFilePanelDirty(self: *AppSession, surface_id: u64, dirty: bool) FilePanelWriteError!void {
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    return reportFilePanelDirty(self, surface_id, .{ .dirty = dirty, .editor_epoch = entry.editor_epoch, .revision = entry.editor_revision +| 1, .request_id = 0 });
}

pub fn deletePinnedFilePanelNameIfInode(io: std.Io, parent: std.Io.Dir, name: []const u8, inode: std.Io.File.INode) void {
    if (!pinnedFilePanelNameHasInode(io, parent, name, inode)) return;
    parent.deleteFile(io, name) catch {};
}

/// 스크롤 위치를 확정하는 모든 입구(스크롤바 드래그·track click·키보드 anchor·reveal)가 지나는 한
/// 자리. 상한은 스크롤바 기하가 아니라 `fileTreeScrollExtent`가 준다 — 스크롤바는 넘치지 않는
/// 목록에 아예 발행되지 않으므로, 기하를 상한의 출처로 쓰면 "아직 발행 전"과 "스크롤할 것 없음"이
/// 구분되지 않는다.
pub fn setFileTreeScrollOffsetPx(self: *AppSession, offset_px: i64) void {
    const extent = fileTreeScrollExtent(self);
    if (!self.file_tree_scroll.setOffsetPx(offset_px, extent.max_offset_px)) return;
    // 옮긴 **직후**의 thumb을 지금 알아야 이어지는 드래그의 grab 기준점이 튀지 않는다. tree를 다시
    // 내면 track/thumb rect가 새 offset을 반영한다 — 기하를 두 번째로 만들지 않는다.
    dock_ops.buildDockListScrollTree(self);
    clearFileTreeHover(self);
    self.dock_list_scrollbar_idle_ticks = 0;
    self.dock_list_scrollbar_last_offset_px = self.file_tree_scroll.offset_y_px;
    self.metal_dirty = true;
}

pub fn removeFileTreeRoot(self: *AppSession, path: []const u8) void {
    if (fileTreeNamespaceMutationBusy(self)) {
        reportFileTreeRootOutcome(self, .busy, .fp_root_busy_retry);
        return;
    }
    var candidate = self.file_tree.cloneForRootTransaction() catch {
        reportFileTreeRootOutcome(self, .allocation_failed, .fp_root_remove_alloc_failed);
        return;
    };
    defer candidate.deinit();
    const removed = candidate.removeExplicitRoot(path) catch {
        reportFileTreeRootOutcome(self, .model_stage_failed, .fp_root_remove_failed);
        return;
    };
    if (!removed) {
        reportFileTreeRootOutcome(self, .root_missing, .fp_root_missing);
        return;
    }
    resetFileTreeWatchRootsFor(self, &candidate, null) catch {
        reportFileTreeRootOutcome(self, .watcher_stage_failed, .fp_root_watch_remove_failed);
        return;
    };
    var candidate_rows: std.ArrayList(file_tree.Row) = .empty;
    defer candidate_rows.deinit(self.allocator);
    prepareFileTreeRowStaging(self, &candidate_rows, 0) catch {
        reportFileTreeRootOutcome(self, .row_stage_failed, .fp_root_rows_remove_failed);
        return;
    };
    buildPreparedFileTreeRows(self, &candidate, &candidate_rows);
    commitFileTreeCandidate(self, &candidate, &candidate_rows);
    reportFileTreeRootOutcome(self, .committed_remove, null);
    self.file_tree_scroll.reset();
    self.metal_dirty = true;
    self.workspaceChanged(.explorer_roots);
}

/// surface_id로 파일 entry를 찾는다(창 전체).
/// 창의 열린 파일 수. 옛 `dock.entryCountTotal()`의 Term판이다.
pub fn fileEntryCountConst(self: *const AppSession) usize {
    var n: usize = 0;
    var it = fileEntriesConst(self);
    while (it.next()) |_| n += 1;
    return n;
}

/// 복원 뒤 이 파일 surface를 화면에 올린다. FP16에서 "활성화"는 도크 그룹의 active index가 아니라
/// 그 파일 **Term이 있는 pane/워크스페이스로 이동**하는 것이다 — activateExistingFileTerm이 그 단일 출처다.
/// 트리에서 Esc로 빠져나올 때 **직전에 보고 있던** 파일 WebView로 입력을 되돌린다. 그 사이 다른 파일을
/// 열었으면 그 pane의 탭을 되돌려야 하므로 pane 안 활성 탭까지는 바꾼다. 다만 **워크스페이스는 넘지
/// 않는다** — 같은 surface가 다른 탭에 있다고 그리로 점프하면 사용자가 보던 화면이 통째로 바뀐다
/// (code-review max). 활성 워크스페이스 밖이면 복원 capability가 만료된 것이라 실패로 돌려주고,
/// 호출자가 workspace로 되돌린다.
pub fn activateFilePanelSurfaceForRestore(self: *AppSession, surface_id: u64) bool {
    if (surface_id == 0 or self.tabs.items.len == 0) return false;
    if (fileEntryForSurfaceId(self, surface_id) == null) return false;
    const tab = self.tabs.items[self.app_window.active_tab];
    for (tab.panes.items, 0..) |pane, pane_index| {
        for (pane.terms.items, 0..) |term, term_index| {
            const entry = term.file_entry orelse continue;
            if (entry.surface_id != surface_id) continue;
            // 떠나게 되는 활성 Term이 편집 중인 파일이면 dirty 스냅샷을 먼저 요청한다(§3.2 two-phase).
            // 열기 경로(`activateExistingFileTerm`)와 같은 계약이라 복원만 예외가 되면 안 된다.
            if (pane.terms.items.len > 0) {
                const leaving = pane.activeTerm();
                if (leaving != term) if (leaving.file_entry) |leaving_entry| {
                    _ = markFilePanelDirtySyncPending(self, leaving_entry);
                };
            }
            if (tab.active_pane != pane_index) pane_ops.focusPane(self, pane_index);
            self.focusTerm(term_index);
            self.file_panel_mode_pending = surface_id;
            self.file_tree_rows_dirty = true;
            return true;
        }
    }
    return false;
}

/// 트리의 열림/활성/dirty 마커는 entry 집합만 있으면 만들 수 있다 — dock 구조가 입력일 이유가 없다(FP16 2-2r).
/// `active_index`는 복원 목록의 활성 entry(라이브에서는 활성 파일 Term)를 가리킨다.
pub fn buildFileTreeRowsForEntries(
    allocator: std.mem.Allocator,
    entries: []const dock_panel.Entry,
    active_index: ?usize,
    tree: *const file_tree.Tree,
    open_states: *std.ArrayList(file_tree.OpenState),
    rows: *std.ArrayList(file_tree.Row),
) !void {
    try open_states.ensureTotalCapacity(allocator, entries.len);
    {
        for (entries, 0..) |entry, i| open_states.appendAssumeCapacity(.{
            .path = entry.path,
            .active = active_index != null and active_index.? == i,
            .dirty = entry.dirty,
            .external_change = entry.external_change,
        });
    }
    try rows.ensureTotalCapacity(allocator, file_tree.max_materialized_nodes + file_tree.max_recent + file_tree.max_roots + 1);
    try tree.buildRows(allocator, open_states.items, rows);
    classifyFileTreeRows(rows.items);
}

/// 창 전체에서 그 경로의 파일 entry. 경로 유일성은 pane별이 아니라 **창 전체** 불변식이다(§1).
pub fn fileEntryForPath(self: *AppSession, path: []const u8) ?*dock_panel.Entry {
    const term = fileTermForPath(self, path) orelse return null;
    return term.file_entry;
}

pub fn mutationEditorLocksAcknowledged(self: *const AppSession, mutation_id: u64) bool {
    var found = false;
    for (self.file_tree_mutation_editor_locks[0..self.file_tree_mutation_editor_locks_len]) |lock| {
        if (lock.mutation_id != mutation_id) continue;
        found = true;
        if (!lock.acknowledged) return false;
    }
    return found;
}

pub fn fillFileTreeProtections(self: *const AppSession, out: []file_tree_mutation.Protection) usize {
    var n: usize = 0;
    if (!self.dock_initialized) return 0;
    var entry_it8 = fileEntriesConst(self);
    while (entry_it8.next()) |entry| {
        if (n >= out.len) return n;
        out[n] = .{
            .path = entry.path,
            .dirty = entry.dirty,
            // A native-clean source editor is not trusted yet: enqueueFileTreeEdit/delete reserve it,
            // acquire a request-scoped CM6 read-only lock and only submit after the matching snapshot.
            .dirty_sync_pending = entry.dirty_sync_pending or entry.mutation_pending_id != 0,
            .external_change = entry.external_change,
            .conflict_reload_pending = entry.conflict_reload_pending,
        };
        n += 1;
    }
    return n;
}

/// 발행·hit-test·렌더가 읽는 유일한 스크롤 값. 상태의 `offset_y_px`를 직접 읽지 않는 이유는
/// 목록이 짧아진 뒤 `clamp`가 돌기 전 tick에도 창이 유계여야 하기 때문이다.
pub fn fileTreeEffectiveScrollPx(self: *const AppSession) u32 {
    return @min(self.file_tree_scroll.offset_y_px, fileTreeScrollExtent(self).max_offset_px);
}

pub fn filePanelDockControlRect(self: *const AppSession) ?maru.session.SplitRect {
    // titlebar 띠의 파일 도크 진입점은 빈 시작 상태에도 유지한다. 내용이 있으면 접기/펴기, 없으면 기존
    // open_file_panel과 같은 파일 선택 요청을 내므로 사용자가 첫 파일을 열 진입점을 잃지 않는다.
    if (!self.dock_initialized or self.chrome_minimal or self.cell_width_px == 0) return null;
    const w = @min(2 * self.cell_width_px, self.backing_width_px);
    // 렌더러의 1.7× quad가 큰 글꼴에서 titlebar 띠 아래로 보일 수 있으므로 hit/hover rect도 실제
    // visual bottom까지 포함한다. 가로는 2셀 rect 안에 1.7셀 glyph를 중앙 배치해 이미 전부 포함한다.
    const h = @min(@max(dockToggleVisualBottomPx(self.cell_height_px, self.titlebar_strip_px), self.titlebar_strip_px), self.backing_height_px);
    if (w == 0 or h == 0) return null;
    // 창 우측 상단이 macOS 둥근 코너라, 토글을 코너에 flush로 두면 코너 마스크가 글리프를 자른다(신호등 옆 사이드바
    // ◧처럼 코너 클리어런스가 필요). 한 셀 여백으론 코너 반경(≈12px)을 못 벗어나 여전히 잘려(사용자 피드백) —
    // **두 셀** 우측 여백을 둬 라운드가 끝난 직선 구간부터 아이콘이 오게 한다. render·hit·drag-region이 모두 이 rect를
    // 쓰므로 함께 정합한다.
    const margin = @min(2 * self.cell_width_px, self.backing_width_px -| w);
    return .{ .x = self.backing_width_px -| w -| margin, .y = 0, .w = w, .h = h };
}

pub fn resetFileTreeWatchRootsFor(self: *const AppSession, tree: *file_tree.Tree, extra_open_path: ?[]const u8) !void {
    // 라이브 경로: 창구 순회 결과를 고정 버퍼에 모아 슬라이스로 넘긴다(창당 max_entries 상한이 bound).
    var buf: [dock_panel.max_entries]dock_panel.Entry = undefined;
    var n: usize = 0;
    var it = fileEntriesConst(self);
    while (it.next()) |entry| {
        if (n >= buf.len) break;
        buf[n] = entry.*;
        n += 1;
    }
    return resetFileTreeWatchRootsForEntries(tree, buf[0..n], extra_open_path);
}

pub fn clearFilePanelCloseWithoutUnlock(self: *AppSession) void {
    if (self.pending_file_panel_close) |pending| self.allocator.free(pending.expected_path);
    self.pending_file_panel_close = null;
    self.file_panel_save_close_pending = null;
}

pub fn hasFilePanelCloseTransition(self: *const AppSession) bool {
    if (self.pending_file_panel_close != null or self.file_panel_save_close_pending != null or
        self.file_panel_close_unlock_actions_len != 0) return true;
    if (!self.dock_initialized) return false;
    var entry_it4 = fileEntriesConst(self);
    while (entry_it4.next()) |entry| if (entry.dirty_sync_pending) return true;
    return false;
}

/// 이 파일 하나를 닫는 것이 창 닫기가 될 때 쓰는 게이트. **다른 파일이 잃을 상태를 들고 있나**만 본다 —
/// `hasProtectedFilePanelsForExit`의 file-tree mutation 항목까지 보면, 이 close를 **일으킨 바로 그**
/// rename/delete 작업이 자기 자신을 막아 항상 거부된다(code-review max).
pub fn filePanelsBlockCloseExcluding(self: *const AppSession, exclude: *const dock_panel.Entry) bool {
    if (!self.dock_initialized) return false;
    var it = fileEntriesConst(self);
    while (it.next()) |entry| {
        if (entry == exclude) continue;
        if (filePanelEntryNeedsDirtyProtection(entry.*)) return true;
    }
    return false;
}

pub fn requestFilePanelClose(self: *AppSession, surface_id: u64) void {
    if (self.pending_file_panel_close != null) return;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return;
    if (entry.mutation_pending_id != 0) {
        self.showNoticeKey(.fp_close_after_mutation);
        return;
    }
    // HTML과 안정된 native-clean Markdown/text read entry만 즉시 닫는다. source editor를 떠나도 CM6 buffer는
    // 살아 있으므로 dirty/pending/conflict인 편집 브리지 kind는 mode와 무관하게 revision-pinned coordinator를 거친다.
    if (entry.usesEditorBridge() and filePanelEntryNeedsDirtyProtection(entry.*)) {
        if (self.file_panel_close_request_id >= max_file_panel_close_request_id) {
            self.showNoticeKey(.fp_close_id_exhausted);
            return;
        }
        self.file_panel_close_request_id += 1;
        const request_id = self.file_panel_close_request_id;
        const expected_path = self.allocator.dupe(u8, entry.path) catch {
            self.showNoticeKey(.fp_close_prepare_failed);
            return;
        };
        self.pending_file_panel_close = .{
            .surface_id = surface_id,
            .surface_generation = surface_id,
            .request_id = request_id,
            .expected_path = expected_path,
            .state_generation = entry.external_change_generation,
            .phase = .syncing,
        };
        markFilePanelCloseDirtySyncPending(self, entry, request_id);
        return;
    }
    _ = closeFilePanelSurfaceNow(self, surface_id);
}

pub fn retainFileTreeRecoveryPath(self: *AppSession, recovery_path: []u8) void {
    if (!builtin.is_test) std.log.err("file tree mutation requires manual recovery: {s}", .{recovery_path});
    // Namespace mutations are globally blocked once any manual recovery exists, so admission
    // guarantees this preallocated slot is available. Transfer existing ownership: no OOM gap.
    std.debug.assert(self.file_tree_manual_recovery_paths_len < self.file_tree_manual_recovery_paths.len);
    self.file_tree_manual_recovery_paths[self.file_tree_manual_recovery_paths_len] = recovery_path;
    self.file_tree_manual_recovery_paths_len += 1;
    // 경로가 끼는 유일한 notice. **여기는 폴백 키를 둔다**(계약 §6.3) — 경로가 잘리면 어느 파일인지
    // 알려 주지 못하므로, 잘릴 상황에서는 "로그의 recovery 경로를 보라"는 **다른 행동**을 안내한다.
    // 다른 보간 자리들이 폴백 없이 절단에 맡기는 것과 갈리는 지점이다(그쪽은 축약해도 뜻이 같다).
    const tmpl = maru.i18n.t(.fp_manual_recovery);
    if (tmpl.len + recovery_path.len > app_session_mod.notice_message_cap) {
        self.showNoticeKey(.fp_manual_recovery_fallback);
    } else {
        self.showNoticeFmt(.fp_manual_recovery, &.{.{ .s = recovery_path }});
    }
}

pub fn selectFirstFileTreeRow(self: *AppSession) void {
    for (self.file_tree_rows.items, 0..) |row, index| if (file_tree.rowIdentity(row) != null) {
        _ = setFileTreeSelection(self, index);
        return;
    };
}

pub fn toggleFilePanelFocus(self: *AppSession) void {
    switch (self.focus_owner) {
        .workspace => {
            if (!self.dock_initialized or !dockHasContent(self)) {
                self.showNoticeKey(.fp_nothing_to_focus);
                return;
            }
            focusFileTree(self);
        },
        .dock_pending, .file_tree => self.focusWorkspaceInput(),
    }
    if (self.focus_owner == .workspace) self.workspace_focus_pending = true;
}

pub fn requestFileTreeRootPick(self: *AppSession, operation: FileTreeRootOperation) void {
    // **사용자가 자동 따라가기보다 먼저다.** `cd` 직후 자동 전환이 검증 슬롯을 잡고 있는 동안 폴더 열기를
    // busy로 거절하면, 사용자는 자기가 누른 메뉴가 왜 안 먹는지 알 수 없다. 자동 검증뿐이면 그것을 버리고
    // 자리를 내준다 — 뒤늦게 도착한 그 결과는 `request_id` 대조에서 이미 걸러진다(완료 처리 참고).
    if (self.file_tree_root_validation) |pending| if (pending.auto) {
        self.file_tree_root_validation = null;
    };
    if (operation == .none or fileTreeNamespaceMutationBusy(self)) {
        reportFileTreeRootOutcome(self, .busy, .fp_root_busy_retry);
        return;
    }
    self.file_tree_root_pick_pending = operation;
    reportFileTreeRootOutcome(self, .picker_requested, null);
}

pub fn discardPendingRenameRemap(self: *AppSession, id: u64) void {
    if (self.pending_rename_remap) |*plan| {
        if (plan.id != id) return;
        plan.deinit(self.allocator);
        self.pending_rename_remap = null;
    }
}

pub fn selectedFileTreeRow(self: *const AppSession) ?usize {
    return self.file_tree_selection.index(self.file_tree_rows.items);
}

/// 스냅샷 요청이 실제로 나갔으면 true. 호출자가 "요청했으니 기다린다"와 "보낼 대상이 없다"를 구분해야
/// 하는 자리(scope close 지연)가 있어 결과를 돌려준다.
pub fn markFilePanelDirtySyncPending(self: *AppSession, entry: *dock_panel.Entry) bool {
    if (!entry.usesEditorBridge() or !entry.mode.isEditable() or entry.surface_id == 0) return false;
    entry.dirty_sync_pending = true;
    queueFilePanelDirtySyncAction(self, entry.surface_id, 0);
    return true;
}

pub fn abortWaitingFileTreeMutation(self: *AppSession, mutation_id: u64, message: maru.i18n.Key) void {
    if (self.file_tree_mutation_waiting_request) |*request| {
        if (request.id == mutation_id) {
            request.deinit(self.allocator);
            self.file_tree_mutation_waiting_request = null;
        }
    }
    if (self.file_tree_mutation_queue_reserved) {
        self.file_tree_mutation_backend.cancelReservation();
        self.file_tree_mutation_queue_reserved = false;
    }
    clearFileTreeMutationReservation(self, mutation_id);
    discardPendingDeleteRoot(self, mutation_id);
    releaseFileTreeMutationEditorLocks(self, mutation_id, true);
    self.file_tree_edit_inflight = false;
    self.file_tree_delete_inflight = false;
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
    self.showNoticeKey(message);
}

pub fn fileTreeFileMutationBusy(self: *const AppSession) bool {
    return self.pending_file_tree_delete != null or self.file_tree_edit_inflight or self.file_tree_delete_inflight or
        self.file_tree_mutation_waiting_request != null or self.file_tree_trash_queue_len != 0 or
        self.file_tree_manual_recovery_paths_len != 0 or self.file_tree_manual_recovery_unknown;
}

pub fn fileTreeNavigationIntent(event: terminal.KeyEvent) ?file_tree_navigation.Intent {
    return switch (event.key) {
        .arrow_up => .previous,
        .arrow_down => .next,
        .arrow_left => .collapse_or_parent,
        .arrow_right => .expand_or_child,
        .enter => .activate,
        .home => .first,
        .end => .last,
        .page_up => .page_up,
        .page_down => .page_down,
        else => null,
    };
}

/// 창의 모든 파일 entry에 surface id를 발급한다. **상한이 없다** — FP16의 §1 불변식("파일 Term의 surface는
/// eviction으로 해제하지 않는다")대로 LRU를 제거했으므로, entry는 만들어질 때 id를 받고 닫힐 때까지 유지한다.
/// 0은 미할당 sentinel이라 이미 받은 entry는 건너뛴다(재발급 금지 — id는 앱 전역 비재사용).
/// surface가 없는 파일 entry에 새 sid를 발급한다(창 전체). rename으로 surface가 retire된 entry도
/// 여기서 다시 살아난다 — FP16 전에는 도크 group 순회였고, 지금은 Term 창구가 유일한 출처다.
pub fn assignDockSurfaceIds(self: *AppSession) void {
    var it = fileEntries(self);
    while (it.next()) |entry| {
        if (entry.surface_id == 0) entry.surface_id = self.surface_ids.next();
    }
}

pub fn dockHasLiveSurface(self: *AppSession) bool {
    var it = fileEntries(self);
    while (it.next()) |entry| {
        if (entry.surface_id != 0) return true;
    }
    return false;
}

/// 재투영 지점. 계측은 여기 있다 — `dock_ops.buildDockListScrollTree`는 down/move에서도 불리므로 그것까지
/// 세면 "프레임당 몇 번 투영했는가"라는 예산의 의미가 달라진다.
pub fn refreshDockListScrollbar(self: *AppSession) void {
    if (self.file_tree_perf_counters) |counters| {
        counters.projected_frames += 1;
        counters.geometry_builds += 1;
    }
    dock_ops.buildDockListScrollTree(self);
}

pub fn requeuePendingDockFocus(self: *AppSession, old: PendingDockFocus) void {
    const entry = (fileEntryForId(self, old.entry_id) orelse return);
    const expected_surface_id = old.expected_surface_id orelse return;
    if (entry.surface_id != expected_surface_id or entry.editor_revision != old.request_or_entry_revision) return;
    dock_ops.queuePendingDockFocus(self, entry);
    // restore/window merge 뒤에도 typed ack 전 fail-close owner를 함께 재파생한다. token만 이관하고
    // workspace/옛 surface owner를 남기면 늦은 native publish 전 PTY·paste·close가 잘못 라우팅된다.
    // 아직 ack 전이므로 `.dock_surface`(승격)가 아니라 barrier 그대로 재파생한다.
    self.focus_owner = .{ .dock_pending = entry.id };
    self.workspace_focus_pending = false;
    self.file_tree_focus_pending = false;
    self.file_tree_restore_surface_pending = null;
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

pub const file_tree_mutation = maru.session.file_tree_mutation;

pub const file_tree_icon = chrome.file_tree_icon;

pub const FilePanelTestC = struct {
    pub extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;
    pub extern "c" fn renameatx_np(
        from_dir_fd: c_int,
        from: [*:0]const u8,
        to_dir_fd: c_int,
        to: [*:0]const u8,
        flags: c_uint,
    ) c_int;
};

pub const rename_swap: c_uint = 0x00000002;

/// titlebar 안에 중앙 배치한 한 셀 glyph를 header_icon_scale만큼 확대한 뒤 화면에 보이는 아래쪽 경계.
/// filePanelDockControlRect의 hit/hover 높이와 collectShaped raster 크기가 같은 scale 계약을 소비한다.
pub fn dockToggleVisualBottomPx(cell_height_px: u32, titlebar_strip_px: u32) u32 {
    if (cell_height_px == 0) return titlebar_strip_px;
    const origin_y = if (titlebar_strip_px > cell_height_px) (titlebar_strip_px - cell_height_px) / 2 else 0;
    const raster_height_px = headerIconRasterExtentPx(cell_height_px);
    const bottom = @as(u64, origin_y) + (@as(u64, cell_height_px) + raster_height_px + 1) / 2;
    return @intCast(@min(bottom, std.math.maxInt(u32)));
}

// JavaScript bridge arguments are IEEE-754 numbers. Keep close request IDs inside the exact integer range so the
// request echoed by CM6 cannot alias a different native request after conversion through NSNumber/JavaScript.
pub const max_file_panel_close_request_id = maru.session.control_bridge.max_js_safe_integer;

pub const DeletedSurfaceSet = struct {
    const slot_count = dock_panel.max_entries * 2;
    keys: [slot_count]u64 = [_]u64{0} ** slot_count,

    fn start(surface_id: u64) usize {
        return @as(usize, @truncate(surface_id *% 0x9e3779b97f4a7c15)) & (slot_count - 1);
    }

    pub fn insert(self: *@This(), surface_id: u64) void {
        std.debug.assert(surface_id != 0);
        var slot = start(surface_id);
        for (0..slot_count) |_| {
            if (self.keys[slot] == 0 or self.keys[slot] == surface_id) {
                self.keys[slot] = surface_id;
                return;
            }
            slot = (slot + 1) & (slot_count - 1);
        }
        unreachable; // 최대 256개를 512-slot table에 넣으므로 full은 모델 cap 위반이다.
    }

    pub fn contains(self: *const @This(), surface_id: u64) bool {
        if (surface_id == 0) return false;
        var slot = start(surface_id);
        for (0..slot_count) |_| {
            const candidate = self.keys[slot];
            if (candidate == 0) return false;
            if (candidate == surface_id) return true;
            slot = (slot + 1) & (slot_count - 1);
        }
        return false;
    }
};

/// `fileEntryForIdCounted`의 방문 수 계측(성능 gate 소비 — docs/performance-budget.md).
/// FP16 전에는 `DockPanel.EntryLookupCounters`였다 — 조회가 도크에서 Term 창구로 옮겨오며 함께 왔다.
pub const EntryLookupCounters = struct { entry_visits: usize = 0 };

pub const FileTreeDockRemovalStats = struct {
    entry_visits: usize = 0,
    dirty_sync_visits: usize = 0,
    unlock_visits: usize = 0,
    reload_visits: usize = 0,
};

// --- 호출 그래프로 소유가 확인돼 옮겨 온 함수 ---
// 이름에 도메인 단어가 없어 F 시리즈가 못 잡았고, 이 그룹을 과반으로 부르며 만지는 상태도 이 그룹이다.

pub fn provideFileTreeRootPick(self: *AppSession, path: []const u8) void {
    const operation = self.file_tree_root_picker_inflight;
    self.file_tree_root_picker_inflight = .none;
    // one-shot 소비: 아래 모든 이탈 경로에서 꺼진 채로 끝나야 다음 사용자 조작이 조용해지지 않는다.
    const auto = self.file_tree_root_auto_follow;
    defer self.file_tree_root_auto_follow = false;
    if (operation == .none or path.len == 0) {
        reportFileTreeRootOutcome(self, .picker_canceled, null);
        return;
    }
    if (path.len > std.fs.max_path_bytes or !std.fs.path.isAbsolute(path) or !std.unicode.utf8ValidateSlice(path)) {
        reportFileTreeRootOutcome(self, .invalid_path, .fp_root_invalid_path);
        return;
    }
    if (self.file_tree_root_request_id == std.math.maxInt(u64)) {
        reportFileTreeRootOutcome(self, .request_id_exhausted, .fp_root_request_id_exhausted);
        return;
    }
    const owned = self.allocator.dupe(u8, path) catch {
        reportFileTreeRootOutcome(self, .allocation_failed, .fp_root_picker_alloc_failed);
        return;
    };
    self.file_tree_root_request_id += 1;
    const pending: PendingFileTreeRootValidation = .{
        .request_id = self.file_tree_root_request_id,
        .expected_root_generation = self.file_tree.rootGeneration(),
        .operation = operation,
        .auto = auto,
    };
    if (!self.file_tree_backend.submitRootValidation(
        owned,
        pending.request_id,
        pending.expected_root_generation,
        @intFromEnum(operation),
        0,
    )) {
        self.allocator.free(owned);
        reportFileTreeRootOutcome(self, .backend_busy, .fp_root_validate_busy);
        return;
    }
    self.file_tree_root_validation = pending;
}

pub fn takeFileTreeReloadAction(self: *AppSession) ?FileTreeReloadAction {
    while (self.file_tree_reload_actions_len != 0) {
        self.file_tree_reload_actions_len -= 1;
        const action = self.file_tree_reload_actions[self.file_tree_reload_actions_len];
        if (action.conflict) return action;
        const entry = fileEntryForSurfaceId(self, action.surface_id) orelse continue;
        if (entry.dirty or entry.dirty_sync_pending or entry.external_change) {
            markExternalFileChange(self, entry);
            continue;
        }
        return action;
    }
    return null;
}

pub fn beginFileConflictReload(self: *AppSession, surface_id: u64) void {
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return;
    if (!entry.external_change or entry.conflict_reload_pending) return;
    entry.conflict_reload_pending = true;
    entry.conflict_reload_generation = entry.external_change_generation;
    queueFileTreeReload(self, surface_id, true);
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

/// web shell이 실제 read + editor replacement를 마친 뒤에만 conflict 보호를 해제한다. 실패 ack는 pending만
/// 내리고 원래 dirty buffer/conflict/save guard를 그대로 둬 사용자가 재시도하거나 복사할 수 있게 한다.
pub fn completeFileConflictReload(self: *AppSession, surface_id: u64, success: bool) FilePanelWriteError!void {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (!entry.usesEditorBridge()) return error.WrongKind;
    if (!entry.conflict_reload_pending) {
        if (!success) self.latchExternalFileChange(entry); // clean auto-reload가 편집 중단/실패를 보고한 보수적 latch.
        return;
    }
    entry.conflict_reload_pending = false;
    const unchanged = entry.external_change_generation == entry.conflict_reload_generation;
    entry.conflict_reload_generation = 0;
    if (success and unchanged) {
        entry.dirty = false;
        entry.dirty_sync_pending = false;
        entry.external_change = false;
        removeFilePanelDirtySyncAction(self, surface_id);
    }
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

pub fn completeFileTreeTrash(
    self: *AppSession,
    id: u64,
    outcome: FileTreeTrashOutcome,
    recovery_path: ?[]const u8,
) void {
    if (self.file_tree_trash_queue_len == 0) return;
    const pending = self.file_tree_trash_queue[0];
    // Only the native adapter that took the head action may acknowledge it. This rejects stale,
    // guessed, or duplicate callbacks without releasing the namespace reservation early.
    if (pending.id != id or !pending.taken or pending.restoring) return;
    if (outcome == .moved_verified) {
        clearFileTreeMutationReservation(self, pending.id);
        const protected_now = fileTreePathProtectedNow(self, pending.original, pending.id);
        if (protected_now) {
            // The native destination mapping proves the staged object reached Trash, but a
            // late editor/external-change signal means closing the buffer could lose data. Reflect
            // the filesystem removal while keeping the protected tab available for recovery/save.
            releaseFileTreeMutationEditorLocks(self, pending.id, true);
            self.showNoticeKey(.fp_trash_done_tab_kept);
        } else {
            _ = removeDeletedDockEntries(self, pending.original);
            releaseFileTreeMutationEditorLocks(self, pending.id, false);
        }
        self.file_tree.removeRecentWithin(pending.original);
        if (std.fs.path.dirname(pending.original)) |parent| self.file_tree.invalidatePath(parent) catch {};
        if (self.file_tree_selection.generation == pending.selection_generation) {
            const selected_path = self.file_tree_selection.path();
            if (self.file_tree_selection.kind == pending.row_kind and selected_path != null and
                std.mem.eql(u8, selected_path.?, pending.original)) clearFileTreeSelection(self);
        }
    } else if (outcome == .not_moved) {
        if (!enqueueFileTreeDeleteRestore(
            self,
            pending.id,
            pending.root,
            pending.staged,
            pending.original,
            pending.identity,
            pending.parent_identity,
            pending.root_identity,
        )) {
            clearFileTreeMutationReservation(self, pending.id);
            releaseFileTreeMutationEditorLocks(self, pending.id, true);
            const retained = takePendingTrashStaged(self, pending.id) orelse return;
            finishPendingTrashRecord(self, pending.id);
            retainFileTreeRecoveryPath(self, retained);
            return;
        }
        self.file_tree_trash_queue[0].restoring = true;
        self.file_tree_mutation_backend.pump();
        return;
    } else {
        // The OS moved some directory entry but its destination identity could not be proven. Never
        // roll back the now-ambiguous staged path: preserve the destination if known and keep the
        // session fail-closed without pretending a nonexistent source is recoverable.
        const owned_recovery = if (recovery_path) |path|
            if (path.len != 0) self.allocator.dupe(u8, path) catch null else null
        else
            null;
        finishPendingTrashRecord(self, pending.id);
        if (owned_recovery) |path| {
            retainFileTreeRecoveryPath(self, path);
        } else {
            retainFileTreeUnknownRecovery(self);
        }
        self.file_tree_rows_dirty = true;
        self.metal_dirty = true;
        return;
    }
    finishPendingTrashRecord(self, pending.id);
    self.file_tree_mutation_backend.pump();
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
}

/// 터미널 링크와 NSOpenPanel이 공유하는 FP5 열기 단일 경로. 호출자는 절대경로만 넘기며, 확장자와 regular-file
/// 판정은 여기서 다시 확인한다. 기존 entry면 DockPanel.open이 새 surface를 만들지 않고 그 탭만 활성화한다.
pub fn openFilePanelPath(self: *AppSession, path: []const u8) FilePanelOpenPathResult {
    if (fileTreeFileMutationBusy(self) or !self.dock_initialized or path.len == 0 or !std.fs.path.isAbsolute(path) or
        !std.unicode.utf8ValidateSlice(path)) return .failed;
    const open_kind = file_panel_bridge.openKindForPath(path) orelse return .unsupported;
    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return .failed;
    if (stat.kind != .file) return .failed;
    return openFilePanelPathAfterValidation(self, path, open_kind, null);
}

/// 격리 Markdown renderer 또는 로컬 HTML delegate가 활성화한 링크를 source surface에 고정해 처리한다.
/// 명시적 HTTP(S)는 config/⌘⇧ disposition에 따라 browser Term 또는 시스템 브라우저 action으로 보내고,
/// Markdown의 로컬 문서 링크는 source group에서 연다. 최종 regular-file 검증은 공용 open 경로가 맡는다.
pub fn openFilePanelLink(
    self: *AppSession,
    surface_id: u64,
    href: []const u8,
    force_system: bool,
) FilePanelLinkError!void {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const source = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (file_panel_bridge.isExplicitHttpLink(href)) return queueExternalLink(self, href, force_system);
    if (source.kind != .markdown) return error.WrongKind;
    const target = file_panel_bridge.resolveMarkdownFileLink(self.allocator, source.path, href) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLink => return error.InvalidLink,
    };
    defer self.allocator.free(target);
    if (openFilePanelPath(self, target) != .opened) return error.OpenFailed;
}

/// request-scoped unlock 자체를 실행할 panel/JS가 사라졌을 때의 terminal ack. 같은 surface의 새 close가 이미
/// 시작됐으면 이전 request 실패는 무시하고, 아니면 clean으로 추정하지 않도록 dirty를 보수적으로 latch한 뒤
/// sync reservation만 회수한다.
pub fn failFilePanelCloseUnlock(self: *AppSession, surface_id: u64, request_id: u64) void {
    if (self.pending_file_panel_close) |pending| {
        if (pending.surface_id == surface_id and pending.request_id != request_id) return;
    }
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return;
    entry.dirty = true;
    entry.dirty_sync_pending = false;
    removeFilePanelDirtySyncAction(self, surface_id);
    self.file_tree_rows_dirty = true;
    self.metal_dirty = true;
    self.showNoticeKey(.fp_edit_state_recheck_failed);
}

pub fn takeFilePanelSaveCloseAction(self: *AppSession) ?FilePanelSaveCloseAction {
    const action = self.file_panel_save_close_pending orelse return null;
    self.file_panel_save_close_pending = null;
    const pending = self.pending_file_panel_close orelse return null;
    if (pending.surface_id != action.surface_id or pending.request_id != action.request_id or
        pending.phase != .saving) return null;
    if (filePanelCloseEntry(self, pending) == null) {
        abortStaleFilePanelClose(self);
        return null;
    }
    return action;
}

pub fn completeFilePanelSaveClose(self: *AppSession, surface_id: u64, request_id: u64, revision: u64, success: bool) void {
    const pending = self.pending_file_panel_close orelse return;
    if (pending.surface_id != surface_id or pending.request_id != request_id or pending.phase != .saving) return;
    if (filePanelCloseEntry(self, pending) == null) {
        abortStaleFilePanelClose(self);
        return;
    }
    if (!success) {
        cancelFilePanelClose(self);
        self.showNoticeKey(.fp_save_failed_tab_kept);
        return;
    }
    const entry = fileEntryForSurfaceId(self, surface_id) orelse {
        cancelFilePanelClose(self);
        return;
    };
    if (entry.editor_revision != revision or entry.dirty or entry.dirty_sync_pending or entry.external_change) {
        cancelFilePanelClose(self);
        self.showNoticeKey(.fp_post_save_check_failed);
        return;
    }
    _ = closeFilePanelSurfaceNow(self, surface_id);
}

/// surface가 핀한 Markdown 파일을 읽는다. web 쪽에서 경로를 지정할 수 없고, 단일 파일 상한은 8 MiB다.
pub fn readFilePanel(self: *AppSession, gpa: std.mem.Allocator, surface_id: u64, editor_epoch: u64) FilePanelReadError![]u8 {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (!entry.usesEditorBridge()) return error.WrongKind;
    if (!entry.editor_document_active or entry.editor_epoch != editor_epoch) return error.StaleDocument;
    if (entry.editor_recovery_required) return error.RecoveryRequired;
    if (entry.mutation_pending_id != 0) return error.MutationPending;

    const cwd = std.Io.Dir.cwd();
    const file = try openFilePanelRead(cwd, entry.path, !entry.initial_file_identity_pending);
    defer file.close(self.io);
    if (entry.initial_file_identity_pending) {
        const actual = try openedFileIdentity(self, file);
        const expected: file_tree.Identity = .{
            .device = entry.initial_file_identity_device,
            .inode = entry.initial_file_identity_inode,
            .kind = entry.initial_file_identity_kind,
        };
        if (!actual.eql(expected)) return error.NotFound;
    }
    const before = file.stat(self.io) catch return error.NotFound;
    const bytes = try readOpenedFile(self, gpa, file);
    errdefer gpa.free(bytes);
    const after = file.stat(self.io) catch return error.NotFound;
    if (before.kind != .file or after.kind != .file or before.inode != after.inode or before.size != after.size or
        !std.meta.eql(before.mtime, after.mtime) or !std.meta.eql(before.ctime, after.ctime)) return error.NotFound;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    // size-query/fill 사이에 새 document가 시작되거나 WebContent가 종료됐으면 이전 read가 새 save baseline을
    // 덮지 못한다. byte 반환과 token commit을 같은 epoch/active 검사로 묶는다.
    if (!entry.editor_document_active or entry.editor_epoch != editor_epoch) return error.StaleDocument;
    if (entry.editor_recovery_required) return error.RecoveryRequired;
    entry.initial_file_identity_pending = false;
    entry.initial_file_identity_device = 0;
    entry.initial_file_identity_inode = 0;
    entry.initial_file_identity_kind = 0;
    entry.disk_content_hash = std.hash.Wyhash.hash(0, bytes);
    entry.disk_content_hash_valid = true;
    return bytes;
}

/// 신뢰 shell document가 새로 생길 때마다 발급하는 generation. surface id는 WebContent reload에서 유지되므로
/// revision만으로는 이전 document와 새 document를 구분할 수 없다.
pub fn beginFilePanelDocument(self: *AppSession, surface_id: u64, document_id: u64) FilePanelWriteError!u64 {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (!entry.usesEditorBridge()) return error.WrongKind;
    if (document_id == 0) return error.StaleDocument;

    // stale/멱등 begin은 close transaction을 포함한 어떤 상태도 바꾸지 않는다. 동일 active document의
    // 재시도는 namespace mutation 중에도 새 문서를 만들지 않으므로 기존 epoch만 반환할 수 있다.
    if (entry.editor_surface_id == surface_id) {
        if (document_id < entry.editor_document_id or
            (document_id == entry.editor_document_id and !entry.editor_document_active)) return error.StaleDocument;
        if (document_id == entry.editor_document_id) return entry.editor_epoch;
    }
    if (entry.mutation_pending_id != 0) return error.MutationPending;
    if (entry.editor_epoch >= maru.session.control_bridge.max_js_safe_integer) return error.IdentityExhausted;

    // document_id는 surface-local이다. LRU/rename으로 새 surface id가 생기면 이전 WebView의 request는 이미
    // surface lookup에서 거부되므로 새 surface는 1부터 다시 시작할 수 있다.
    if (entry.editor_surface_id != surface_id) {
        entry.editor_surface_id = surface_id;
        entry.editor_document_id = 0;
        entry.editor_document_active = false;
    }
    // 여기부터는 실제 새 document 승인이다. 이전 close의 lock/snapshot 예약은 새 page가 소유할 수 없으므로
    // 이 전이에서만 취소한다.
    if (self.pending_file_panel_close) |pending| if (pending.surface_id == surface_id)
        cancelFilePanelClose(self);

    const had_editor_document = entry.editor_document_active;
    entry.editor_document_id = document_id;
    entry.editor_document_active = true;
    entry.editor_epoch += 1;
    entry.editor_revision = 0;
    // 새 document가 자신의 epoch-scoped read를 끝내기 전에는 이전 document의 disk token으로 저장할 수 없다.
    entry.disk_content_hash_valid = false;
    // 새 document 교체는 crash와 같은 데이터 수명 경계다. editable mode에서는 마지막 CM6 transaction이 아직
    // native dirty ACK에 도달하지 않았을 수 있으므로 native mirror가 clean이어도 보수적으로 recovery한다.
    // read mode도 이전 editable buffer의 dirty/pending 보호가 남아 있으면 동일하게 latch한다.
    if (had_editor_document and (entry.mode.isEditable() or entry.dirty or entry.dirty_sync_pending)) {
        entry.editor_recovery_required = true;
        entry.dirty = true;
        entry.dirty_sync_pending = true;
        self.showNoticeKey(.fp_web_content_restarted);
    }
    return entry.editor_epoch;
}

/// 정확히 현재 surface의 editable WebContent가 종료되면 page→native dirty ACK 직전 편집도 보존 대상으로 본다.
/// 새 document begin 전까지 active=false로 이전 page의 모든 read/write/ACK를 즉시 무효화한다.
pub fn filePanelDocumentTerminated(self: *AppSession, surface_id: u64) u32 {
    if (!self.dock_initialized) return 0;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return 0;
    if (!entry.usesEditorBridge()) return 0;
    // LRU/rename이 새 surface id를 발급한 뒤 첫 begin 전이면 Entry에 남은 active flag는 이전 surface 문서다.
    // 새 WebView의 조기 종료를 그 문서 손실로 오인하지 않고 safe reload만 허용한다.
    if (entry.editor_surface_id != surface_id) return 1;
    // 최초 begin 전 crash는 잃을 editor가 없어 reload만 허용한다. 이미 종료 처리한 document의 중복 callback은
    // 다시 reload하지 않는다.
    if (!entry.editor_document_active) return if (entry.editor_document_id == 0) 1 else 0;
    entry.editor_document_active = false;
    // read 전환은 CM6 buffer를 파괴하지 않으며 dirty snapshot ACK 전 pending 보호도 유지한다. 현재 표시 mode만
    // 보고 safe reload로 분류하면 source/live→read 직후 crash에서 편집을 잃으므로 보호 상태도 함께 본다.
    if (!entry.mode.isEditable() and !entry.dirty and !entry.dirty_sync_pending) return 1;
    entry.editor_recovery_required = true;
    entry.dirty = true;
    entry.dirty_sync_pending = true;
    if (self.pending_file_panel_close) |pending| if (pending.surface_id == surface_id)
        cancelFilePanelClose(self);
    self.showNoticeKey(.fp_web_content_terminated);
    self.metal_dirty = true;
    return 2;
}

/// 신뢰 shell이 핀한 Markdown 파일 하나만 원자 교체한다. 웹 요청에는 경로 인자가 없고 surface→entry 경로를
/// 여기서 다시 해소한다. 원본 권한을 보존한 동일 디렉터리 임시 파일을 fsync한 뒤 rename-replace하므로 실패 시
/// 기존 파일이 부분 내용으로 노출되지 않는다. dirty 최종값은 저장 중 재편집과 직렬화한 shell의 setDirty가 내리며,
/// write 자체는 true를 false로 바꾸지 않아 저장 완료와 재편집 사이 eviction race를 만들지 않는다.
pub fn writeFilePanel(self: *AppSession, surface_id: u64, editor_epoch: u64, content: []const u8) FilePanelWriteError!void {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (!entry.usesEditorBridge()) return error.WrongKind;
    if (!entry.editor_document_active or entry.editor_epoch != editor_epoch) return error.StaleDocument;
    if (entry.editor_recovery_required) return error.RecoveryRequired;
    if (entry.mutation_pending_id != 0) return error.MutationPending;
    if (entry.external_change) return error.ExternalConflict;
    if (content.len > file_panel_bridge.max_file_bytes) return error.TooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidContent;
    if (!entry.disk_content_hash_valid) return error.ExternalConflict;

    const pinned = try openPinnedFilePanelParent(self.io, entry.path);
    defer pinned.dir.close(self.io);
    var original = openFilePanelRead(pinned.dir, pinned.basename, false) catch return error.NotFound;
    defer original.close(self.io);
    const stat = original.stat(self.io) catch return error.NotFound;
    if (stat.kind != .file) return error.NotRegularFile;
    try writePinnedFilePanel(self.io, pinned.dir, pinned.basename, original, stat, entry.disk_content_hash, content);
    entry.self_write_grace_ticks = @intCast(@min(self.ticksForMs(2_000), std.math.maxInt(u16)));
    entry.self_write_hash = std.hash.Wyhash.hash(0, content);
    entry.disk_content_hash = entry.self_write_hash;
    entry.disk_content_hash_valid = true;
    entry.self_write_verifications = 0;
    self.metal_dirty = true;
}

pub fn reportFilePanelDirty(self: *AppSession, surface_id: u64, report: maru.session.control_bridge.DirtyReport) FilePanelWriteError!void {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (!entry.usesEditorBridge()) return error.WrongKind;
    // 기존 headless policy fixtures만 zero/zero sentinel을 쓴다. 제품 빌드에는 이 seam 자체가 없고 JSON bridge도
    // non-positive epoch을 거부한다.
    const test_unbound = builtin.is_test and report.editor_epoch == 0 and entry.editor_epoch == 0 and !entry.editor_document_active;
    if (!test_unbound and (!entry.editor_document_active or report.editor_epoch != entry.editor_epoch))
        return error.StaleDocument;
    if (entry.editor_recovery_required) return error.RecoveryRequired;
    const mutation_lock = if (report.request_id != 0) fileTreeMutationEditorLock(self, surface_id, report.request_id) else null;
    if (entry.mutation_pending_id != 0 and mutation_lock == null) return error.MutationPending;
    var close_pending: ?PendingFilePanelClose = null;
    if (report.request_id != 0 and mutation_lock == null) {
        const pending = self.pending_file_panel_close orelse return;
        if (pending.surface_id != surface_id or pending.phase != .syncing or pending.request_id != report.request_id) return;
        if (filePanelCloseEntry(self, pending) == null) {
            abortStaleFilePanelClose(self);
            return;
        }
        close_pending = pending;
    }
    if (report.revision < entry.editor_revision) return error.StaleDocument;
    entry.editor_revision = report.revision;
    const protected_clean_ack = entry.external_change and !report.dirty;
    const changed = (!protected_clean_ack and entry.dirty != report.dirty) or entry.dirty_sync_pending;
    if (!protected_clean_ack) entry.dirty = report.dirty;
    const close_match = close_pending != null;
    if (self.pending_file_panel_close == null or self.pending_file_panel_close.?.surface_id != surface_id or close_match) {
        entry.dirty_sync_pending = false;
        removeFilePanelDirtySyncAction(self, surface_id);
    }
    if (changed) self.metal_dirty = true;
    if (changed) self.file_tree_rows_dirty = true;
    if (mutation_lock) |lock| {
        if (entry.external_change or report.dirty) {
            const mutation_id = lock.mutation_id;
            abortWaitingFileTreeMutation(self, mutation_id, .fp_abort_unsaved);
            return;
        }
        lock.acknowledged = true;
        _ = submitWaitingFileTreeMutation(self, lock.mutation_id);
        return;
    }
    if (close_pending) |pending| {
        var pinned = pending;
        pinned.revision = report.revision;
        if (!entry.dirty and !entry.external_change) {
            _ = closeFilePanelSurfaceNow(self, surface_id);
            return;
        }
        showFilePanelCloseChoices(self, pinned, entry);
    }
}

pub fn failFilePanelDirtySync(self: *AppSession, surface_id: u64, request_id: u64) void {
    if (fileTreeMutationEditorLock(self, surface_id, request_id)) |lock| {
        const mutation_id = lock.mutation_id;
        abortWaitingFileTreeMutation(self, mutation_id, .fp_abort_edit_check);
        return;
    }
    const pending = self.pending_file_panel_close orelse return;
    if (pending.surface_id != surface_id or pending.request_id != request_id or pending.phase != .syncing) return;
    cancelFilePanelClose(self);
    self.showNoticeKey(.fp_edit_state_check_failed);
}

/// 핀된 Markdown 경로의 lexical parent도 root fd부터 component별 no-follow로 연 뒤, 상대 asset의 모든 하위
/// component를 같은 capability 아래에서 순회한다. 최초 parent 재개방까지 symlink를 거부해야 열린 문서의
/// ancestor가 교체된 뒤에도 새 namespace나 root 밖 파일을 읽지 않는다.
pub fn readFilePanelAsset(
    self: *AppSession,
    gpa: std.mem.Allocator,
    surface_id: u64,
    raw_path: []const u8,
) FilePanelReadError![]u8 {
    if (!self.dock_initialized) return error.SurfaceNotFound;
    const entry = fileEntryForSurfaceId(self, surface_id) orelse return error.SurfaceNotFound;
    if (entry.kind != .markdown) return error.WrongKind;

    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = file_panel_bridge.normalizeAssetPath(raw_path, &normalized_buf) catch return error.InvalidPath;
    const pinned = openPinnedFilePanelParent(self.io, entry.path) catch return error.OutsideRoot;
    defer pinned.dir.close(self.io);

    var opened_dirs: [std.fs.max_path_bytes / 2]std.Io.Dir = undefined;
    var opened_count: usize = 0;
    defer while (opened_count > 0) {
        opened_count -= 1;
        opened_dirs[opened_count].close(self.io);
    };

    var current = pinned.dir;
    if (std.fs.path.dirname(normalized)) |subdir| {
        var components = std.mem.splitScalar(u8, subdir, '/');
        while (components.next()) |component| {
            const next = current.openDir(self.io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return error.NotFound,
                else => return error.OutsideRoot,
            };
            opened_dirs[opened_count] = next;
            opened_count += 1;
            current = next;
        }
    }

    const file = try openFilePanelRead(current, std.fs.path.basename(normalized), false);
    defer file.close(self.io);
    return readOpenedFile(self, gpa, file);
}

/// 파일 entry를 닫는다 = 그 파일 **Term을 닫는다**(FP16). entry의 소유가 Term이므로 `destroyTerm`이
/// entry·path까지 해제한다 — 옛 `group.remove` + `allocator.free(path)` 쌍을 대체한다.
///
/// pane의 마지막 Term이면 닫지 않고 false를 돌려준다. pane은 항상 Term ≥1이라는 모델 불변식
/// (`session_model.Pane`)을 파일 경로가 깨면 안 되고, 그 경우의 cascade(빈 pane collapse·워크스페이스 닫기)는
/// `executeClose`가 소유하는 별도 정책이다.
/// 창 간 이동으로 들어오는 파일들을 이 창의 탐색기 recent·watch 집합에 등록한다. 실패하면 아무것도
/// 바꾸지 않는다(후보 트리에 다 쓴 뒤 무실패 commit) — 호출자는 detach 전에 이걸 부른다.
pub fn adoptMovedFileTermsIntoExplorer(dst: *AppSession, tab: *Tab, src: *AppSession) !void {
    var candidate = try dst.file_tree.clone();
    defer candidate.deinit();
    var extras: [dock_panel.max_entries]([]const u8) = undefined;
    var extra_count: usize = 0;
    var dst_it = fileEntries(dst);
    while (dst_it.next()) |entry| if (std.fs.path.dirname(entry.path)) |parent| {
        if (extra_count >= extras.len) break;
        extras[extra_count] = parent;
        extra_count += 1;
    };
    for (tab.panes.items) |pane| {
        for (pane.terms.items) |term| {
            const entry = term.file_entry orelse continue;
            const parent = std.fs.path.dirname(entry.path) orelse continue;
            // 양쪽이 inferred면 source가 파일을 열 때 정한 project root가 dirname보다 정확하다.
            var inferred_root = parent;
            if (candidate.rootMode() == .inferred and src.file_tree.rootMode() == .inferred) {
                var authority: ?[]const u8 = null;
                for (0..src.file_tree.rootCount()) |ri| {
                    const root = src.file_tree.rootAt(ri).?;
                    if (!file_tree.Tree.pathWithinRoot(entry.path, root)) continue;
                    if (authority == null or root.len > authority.?.len) authority = root;
                }
                if (authority) |root| inferred_root = root;
            }
            try candidate.recordOpened(entry.path, inferred_root);
            if (extra_count < extras.len) {
                extras[extra_count] = parent;
                extra_count += 1;
            }
        }
    }
    try candidate.resetWatchRequests(extras[0..extra_count]);
    var rows: std.ArrayList(file_tree.Row) = .empty;
    defer rows.deinit(dst.allocator);
    try prepareFileTreeRowStaging(dst, &rows, countTabFileEntries(tab));
    buildPreparedFileTreeRows(dst, &candidate, &rows);
    commitFileTreeCandidate(dst, &candidate, &rows);
    dst.file_tree_rows_dirty = true;
}
