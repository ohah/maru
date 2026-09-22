//! **저장하려는데 파일이 밖에서 바뀌었다 — 고르게 한다**(C1a).
//! 계약은 [editor-surface.md](../../../docs/editor-surface.md) §4 가 소유한다.
//!
//! **왜 따로 있나.** C0 이 「충돌이었다」를 이유로 올렸고(§3.9d), 이 파일은 그 이유에 **행동 둘**을
//! 붙인다: 덮어쓰기(디스크의 변경을 버린다)와 다시 읽기(방금 친 것을 버린다 — `⌘Z` 로 돌아온다).
//! 그 둘은 `saveDocument` 의 갈래가 아니라 **사용자의 답**이라, 확인 상자를 사이에 두고 뒤에 온다.
//!
//! **들고 있는 것은 surface id 하나뿐이다**(`PendingConfirm.save_conflict`). 내용을 들고 있으면 상자가
//! 떠 있는 동안 친 글자가 조용히 사라진다 — §4 의 「고른 순간의 내용으로 쓴다」가 그 규칙이다.

const std = @import("std");
const maru = @import("maru");

const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_diff_ops = @import("editor_diff.zig");
const git_ops = @import("git.zig");
const git_backend_mod = @import("../git_backend.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const dock_panel = maru.session.dock_panel;

/// 저장이 충돌로 멈췄다 — **행동 셋과 「계속 편집」**을 띄운다(§4).
///
/// **`primary` 는 비교다.** 셋 중 **아무것도 버리지 않는 유일한 선택**이고, 상자는 열 때 `primary` 에
/// 포커스를 두므로 **Enter 가 안전하다**. 파괴적인 둘은 `alternate`(덮어쓰기)·`extra`(다시 읽기)에
/// 서고, `cancel`(Esc·바깥 클릭)은 아무 일도 안 한다 — 그 자리에 행동을 놓을 수 없는 이유가 그것이다.
pub fn ask(self: *AppSession, term: *Term) void {
    // 편집기 문서가 아니면 물을 것이 없다 — 이 자리에 오는 길은 `saveDocument` 의 `ExternalConflict`
    // 하나뿐이고 그것은 문서가 있을 때만 난다. 그래도 확인해 둔다: 상자가 뜨면 **키를 먹으므로**
    // 대상 없는 상자는 입력을 삼키는 빈 모달이 된다.
    if (term.kind != .editor or term.rt.editor_doc == null) return;
    self.showConfirmChoiceKeys(
        .{ .save_conflict = term.surface.id },
        .editor_save_conflict_choose,
        .{
            .primary = .btn_compare,
            .alternate = .btn_overwrite,
            .extra = .btn_reload,
            .cancel = .btn_keep_editing,
        },
    );
}

/// 「비교」 — **두 쪽을 그 자리에서 연다**(§4). `primary` 라 Enter 가 이것을 실행한다.
///
/// ⚠️ **답은 아직 «안 한» 것이다.** 상자를 닫고 탭을 열 뿐 **디스크도 버퍼도 그대로**이고 문서는
/// dirty 로 남는다 — 사용자는 보고 나서 다시 `⌘S` 를 눌러 고른다. 상자를 비교 위에 띄워 둘 수는
/// 없다: 모달이 그 화면을 읽지 못하게 막는다.
pub fn confirmCompare(self: *AppSession, surface_id: u64) void {
    const term = term_ops.termBySurfaceId(self, surface_id) orelse return;
    if (term.kind != .editor) return;
    if (term.rt.editor_doc == null) return;
    const path = term.rt.editor_path orelse return;
    openCompare(self, term, path) catch {
        // 탭을 못 열었으면 **그 사실을 말한다** — 조용히 아무 일도 안 하면 사용자는 버튼이 죽은 줄 안다.
        self.showNoticeKey(.editor_compare_failed);
    };
}

/// 저장 충돌 비교 Term 을 열고(있으면 그것을 쓰고) 두 쪽을 **다시** 채운다.
///
/// **이미 열린 비교는 `openDiffTerm` 이 활성화만 하고 돌아간다** — 그래서 두 번째 저장 시도가 첫
/// 번째의 비교를 보여 준다. 여기서는 열든 재사용하든 **채움을 한 번 더** 지난다.
fn openCompare(self: *AppSession, term: *Term, path: []const u8) !void {
    const existing = git_ops.diffTermFor(self, path, .save_conflict);
    const diff_term = existing orelse blk: {
        const opened = try pane_ops.openFileTermInActivePane(self, path, .diff);
        const entry = opened.term.file_entry orelse return error.NoEntry;
        entry.diff_base = .save_conflict;
        break :blk opened.term;
    };
    if (existing != null) _ = self.activateExistingFileTerm(diff_term);
    const entry = diff_term.file_entry orelse return error.NoEntry;
    // **주인은 surface id 로 든다** — 경로로 다시 찾으면 entry 가 없는 문서 Term 을 놓친다(§4).
    entry.diff_buffer_surface_id = term.surface.id;
    self.requestDiffContent(entry);
    editor_diff_ops.markRequested(self, diff_term);
    self.metal_dirty = true;
}

/// 저장 충돌 비교의 **두 쪽을 채운다** — 왼쪽은 그 순간의 디스크 바이트, 오른쪽은 편집기 버퍼의 사본.
///
/// **`requestDiffContent` 가 머리에서 이것으로 갈린다.** 그 함수는 `diff_repo` 가 비면 실패로 표시하고
/// git 을 부르는데, 이 비교에는 저장소가 없다. 새로 고치는 자리 둘(`fileChanged`·tick 폴링)이 전부 그
/// 함수를 지나므로 **가르는 자리도 하나**다.
///
/// **두 쪽을 `worker_allocator` 로 만든다** — 해제하는 쪽(`freeDiffContent`)이 그것으로 풀기 때문이다.
/// 소유자 표시 필드를 새로 더하면 해제 규칙이 둘이 되고, 둘이 되면 한쪽이 낡는다.
pub fn fillCompare(self: *AppSession, entry: *dock_panel.Entry) void {
    entry.diff_ready = false;
    entry.diff_failed = false;
    entry.diff_truncated = false;
    entry.diff_request_id = 0;
    // ⚠️ **옛 두 쪽을 먼저 놓는다 — 실패로 끝나는 갈래에서도.** 남겨 두면 문서 탭을 닫은 뒤에도
    // **사라진 편집이 「내 편집」으로 계속 보인다**(판정자 C1b-4 가 그것을 잡았다). 행 배열이 그
    // 버퍼를 빌리므로 `invalidate` 가 **먼저** 와야 한다(git 결과 처리와 같은 순서·같은 이유).
    if (termForEntry(self, entry)) |t| editor_diff_ops.invalidate(self, t);
    self.freeDiffContent(entry);

    // **주제가 사라졌으면 실패다** — 그 문서 Term 이 없으면 「내 편집」이라고 보여 줄 것이 없다.
    const owner = term_ops.termBySurfaceId(self, entry.diff_buffer_surface_id) orelse {
        entry.diff_failed = true;
        return;
    };
    const doc = owner.rt.editor_doc orelse {
        entry.diff_failed = true;
        return;
    };
    const alloc = git_backend_mod.worker_allocator;
    const disk = readDiskSide(self, entry.path, alloc) catch {
        entry.diff_failed = true;
        return;
    };
    const mine = alloc.dupe(u8, doc.file.content) catch {
        alloc.free(disk);
        entry.diff_failed = true;
        return;
    };
    entry.diff_original = disk;
    entry.diff_modified = mine;
    entry.diff_ready = true;
}

/// **그 문서를 주제로 삼은 저장 충돌 비교를 실패로 만든다** — 문서 Term 이 사라질 때 부른다.
///
/// ⚠️ **새로 고침을 기다릴 수 없다.** tick 폴링은 `diff_ready` 인 entry 를 건너뛰고, 파일이 또 바뀌지
/// 않으면 `fileChanged` 도 오지 않는다 — 그러면 **사라진 편집이 「내 편집」으로 영영 남는다**
/// (적대적 2회차에서 드러났다). 주제가 사라진 그 순간이 그것을 말할 유일한 자리다.
pub fn invalidateCompareFor(self: *AppSession, term: *Term) void {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |t| {
                const entry = t.file_entry orelse continue;
                if (entry.kind != .diff or entry.diff_base != .save_conflict) continue;
                if (entry.diff_buffer_surface_id != term.surface.id) continue;
                editor_diff_ops.invalidate(self, t);
                self.freeDiffContent(entry);
                entry.diff_ready = false;
                entry.diff_failed = true;
                self.metal_dirty = true;
            }
        }
    }
}

/// 그 entry 를 든 Term(비교 Term). 행 배열이 두 쪽을 빌리므로 내용을 갈기 전에 그 Term 의 캐시를 놓아야 한다.
fn termForEntry(self: *AppSession, entry: *dock_panel.Entry) ?*Term {
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |t| {
                if (t.file_entry == entry) return t;
            }
        }
    }
    return null;
}

/// 왼쪽 쪽(디스크)을 읽는다 — **비교는 못 읽는 파일에서도 실패로 서야 한다**(지워졌을 수 있다).
fn readDiskSide(self: *AppSession, path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var fresh = try editor_ops.openPath(self.io, self.allocator, path);
    defer fresh.deinit(self.allocator);
    return alloc.dupe(u8, fresh.file.content);
}

/// 「덮어쓰기」 — **CAS 를 건너뛰고** 지금 버퍼를 쓴다.
///
/// 건너뛰지 않으면 그 사이 파일이 또 바뀐 경우 같은 물음이 되풀이돼 **영영 저장하지 못한다**(§4).
/// 그 대가는 분명하다: 사용자가 본 적 없는 변경까지 지운다. 그래서 이 함수는 **사용자가 명시로 고른
/// 자리 하나**에서만 불린다 — 자동 재시도·일괄 저장은 부르지 않는다.
pub fn confirmOverwrite(self: *AppSession, surface_id: u64) void {
    // **지금 다시 찾는다.** 상자가 떠 있는 동안 그 Term 이 닫혔으면 아무 일도 하지 않는다.
    const term = term_ops.termBySurfaceId(self, surface_id) orelse return;
    editor_ops.overwriteDocument(self, term) catch |e| switch (e) {
        // 덮어쓰기는 CAS 를 건너뛰므로 충돌이 다시 올 수 없다. 나머지 이유는 §3.9d 의 그 표가 말한다 —
        // 여기서 문구를 다시 고르면 표가 둘이 된다.
        error.AskName, error.NotAnEditor, error.ReadOnly => {},
        else => self.showNoticeKey(editor_ops.saveFailureNoticeKey(@errorCast(e))),
    };
}

/// 「다시 읽기」 — 디스크를 읽어 **편집 하나로** 문서에 넣는다.
///
/// **통짜 교체가 아니다.** §4 가 「외부 변경을 받아들일 때 통짜 model 교체로 undo/cursor 를 깨지
/// 않는다」고 정했고, 평범한 편집으로 넣으면 `⌘Z` 가 사용자의 편집을 되살린다 — 버리는 선택 중
/// **되돌릴 수 있는** 쪽이 되는 것이다.
///
/// **디스크를 읽는 길은 `openPath` 하나다.** 여기서 따로 읽으면 UTF-8 거절·상한·짧은 읽기 규칙이
/// 두 벌이 된다.
pub fn confirmReload(self: *AppSession, surface_id: u64) void {
    const term = term_ops.termBySurfaceId(self, surface_id) orelse return;
    if (term.kind != .editor) return;
    const doc = term.rt.editor_doc orelse return;
    const path = term.rt.editor_path orelse return;

    var fresh = editor_ops.openPath(self.io, self.allocator, path) catch |e| {
        self.showNoticeKey(reloadFailureNoticeKey(e));
        return;
    };
    defer fresh.deinit(self.allocator);

    // **커서가 없으면 편집이 들어가지 않는다**(`applyEditAsOne` 이 선택을 요구한다). LSP 일괄 편집이
    // dirty 로 만든 문서는 사용자가 커서를 둔 적이 없을 수 있어, 그 경우 문서 앞에 세운다.
    if (term.rt.editor_selection == null) {
        term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    }

    var changes = [_]maru.session.editor.delta.Change{.{
        .start = 0,
        .end = @intCast(doc.file.content.len),
        .text = fresh.file.content,
    }};
    if (!editor_ops.applyEditAsOne(self, term, &changes)) {
        self.showNoticeKey(.editor_reload_failed);
        return;
    }

    // **형식도 새로 읽은 것을 따른다** — 안 따르면 다음 저장이 낡은 관례(BOM·개행)로 쓴다.
    term.rt.editor_doc.?.file.format = fresh.file.format;
    // **이제 clean 이다.** 사용자가 「디스크를 받아들였다」고 답했고 내용이 그것과 같다 — 편집으로
    // 넣었다는 이유로 dirty 로 남으면 화면이 그 답과 어긋난다.
    term.rt.editor_doc.?.saved_hash = editor_ops.contentHash(fresh.file.content);
    term.rt.editor_doc.?.disk_hash = fresh.disk_hash;
    // 구문 트리·LSP 통지·줄 인덱스는 **편집 경로가 이미 한다** — `applyEditAsOne` 이 `refreshAfterEdit`
    // 를 지나므로(그 함수 주석: 「제품의 편집 경로 여섯이 전부 이 함수를 지난다」) 여기서 다시 부르면
    // 그 통지가 두 번 간다.
    self.metal_dirty = true;
}

/// **다시 읽기 실패의 이유 → 사용자에게 할 말.** §3.9d 의 저장 표와 **같은 규율**이고 **다른 표**다 —
/// 그쪽은 쓰기 실패이고 이쪽은 읽기 실패라, 사용자가 할 일이 다르다(그쪽은 다시 눌러 보는 것,
/// 이쪽은 파일이 왜 읽히지 않는지 보는 것). 뭉개지 않는다: 지워진 것과 글자가 아닌 것과 너무 커진
/// 것은 서로 다른 상황이다.
pub fn reloadFailureNoticeKey(e: editor_ops.OpenFileError) maru.i18n.Key {
    return switch (e) {
        error.Unreadable => .editor_reload_gone,
        error.NotUtf8 => .editor_reload_not_text,
        error.TooLarge => .editor_reload_too_large,
        error.OutOfMemory => .editor_reload_failed,
    };
}
