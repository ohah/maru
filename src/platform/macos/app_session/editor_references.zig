//! 참조 피커(docs/editor-surface-tooling.md §8.2l) — `textDocument/references` 를 보내고 응답의 위치 **전부**를 팔레트 기반 피커(native-editor-ui
//! §7.5 의 세 번째 소비자)에 행으로 세운다. 트리거는 `⇧F12`(caret)·팔레트. 고르면 **닫고 나서** §5.2 의 `navigateTo` 하나로 간다(정의로 이동과
//! 같은 길 — 연 뒤 그 문서로 offset 을 푼다).
//!
//! 요청은 `12e8+seq`(§8.2a id 표) — 응답은 **지금 기다리는 seq** 일 때만 열고 낡은 것은 버린다. 서버가 없거나 ready 아니면 무동작. 결과가
//! `null`/빈 배열이면 알림 「참조를 찾지 못했습니다」, **하나면 목록 없이 이동**, 둘 이상이면 피커. root 밖 행은 보이되 고르면 알림(§5.2
//! 「표시와 접근을 가른다」). 행 굳히기(정렬·중복·상한·미리보기)는 `platform/macos/reference_picker.zig` 가 소유한다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const pane_ops = @import("pane.zig");
const reference_picker = @import("../reference_picker.zig");
const lsp = maru.session.editor.lsp;

/// 「지금은 못 답한다」(content modified·server cancelled) 뒤 되묻기 — 간격과 횟수 상한(§8.2l). rust-analyzer 는 작업 공간을 읽는 동안
/// `-32801` 을 낸다(캡처 실측 — 첫 답이 늘 그것이었다).
pub const retry_ms: u64 = 400;
pub const max_retries: u8 = 8;

pub const State = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    /// 되묻기 예약(`retry_at_ms` 에 caret 자리로 다시). 사용자가 새로 부르면 지워진다.
    retry_at_ms: u64 = 0,
    retries: u8 = 0,
    /// 응답 때 쓸 인코딩(요청한 클라이언트의 것) — 행의 `character` 를 `navigateTo` 가 그 인코딩으로 푼다.
    enc: lsp.rpc.PositionEncoding = .utf16,
    /// 판정자 관측.
    opened: u64 = 0,
    retried: u64 = 0,
    navigated: u64 = 0,
    notified_none: u64 = 0,
    notified_outside: u64 = 0,
    dropped_stale: u64 = 0,
};

/// `goto_references` 명령·`⇧F12` — 활성 편집기의 caret 자리에서. 보냈으면 true.
pub fn gotoReferencesAtCaret(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    const sel = term.rt.editor_selection orelse return false;
    const st = &self.editor_references;
    st.retry_at_ms = 0;
    st.retries = 0;
    return request(self, term, @min(sel.focus, doc.file.content.len));
}

fn request(self: *AppSession, term: *Term, offset: usize) bool {
    const st = &self.editor_references;
    const seq = editor_lsp.requestReferences(self, term, offset) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.enc = (editor_lsp.readyClientFor(self, term) orelse return false).encoding;
    return true;
}

/// 세션 tick — 예약된 되묻기가 익으면 caret 자리로 다시 보낸다.
pub fn tick(self: *AppSession) void {
    const st = &self.editor_references;
    if (st.retry_at_ms == 0 or st.waiting) return;
    if (self.awakeMs() < st.retry_at_ms) return;
    st.retry_at_ms = 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return;
    const doc = term.rt.editor_doc orelse return;
    const sel = term.rt.editor_selection orelse return;
    st.retried += 1;
    if (!request(self, term, @min(sel.focus, doc.file.content.len))) {
        st.notified_none += 1;
        self.showNoticeKey(.ref_none);
    }
}

/// 디스크에서 미리보기 본문을 읽는다(root 안 파일만 — 호출자가 걸렀다). 상한을 넘거나 못 읽으면 `null`. 읽은 것은 arena 소유.
const DiskReader = struct {
    session: *AppSession,
    arena: std.mem.Allocator,
    pub fn read(self: *DiskReader, path: []const u8) ?[]const u8 {
        var file = std.Io.Dir.cwd().openFile(self.session.io, path, .{}) catch return null;
        defer file.close(self.session.io);
        const stat = file.stat(self.session.io) catch return null;
        if (stat.size > reference_picker.max_preview_bytes) return null;
        const buf = self.arena.alloc(u8, @intCast(stat.size)) catch return null;
        const n = file.readPositionalAll(self.session.io, buf, 0) catch return null;
        return buf[0..n];
    }
};

/// 행이 쓸 수 있는 표시 폭 — 패널 60 − 행 들여쓰기 2 − 스크롤 gutter 2. 제목과 보조 텍스트의 나눔은 `reference_picker.build` 가 한다.
fn rowCols() usize {
    return 60 - 2 - 2;
}

/// references 응답(`editor_lsp` 가 부른다). 지금 기다리는 seq 가 아니면 버린다. 되물을 수 있는 오류(`content modified` 등)면 잠시 뒤
/// 다시 — 상한을 넘기면 「찾지 못했습니다」.
pub fn onReferencesResponse(self: *AppSession, seq: u32, result: ?std.json.Value, retryable: bool) void {
    const st = &self.editor_references;
    if (!st.waiting or seq != st.waiting_seq) {
        st.dropped_stale += 1;
        return;
    }
    st.waiting = false;
    if (retryable and st.retries < max_retries) {
        st.retries += 1;
        st.retry_at_ms = self.awakeMs() + retry_ms;
        return;
    }
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor) return;
    const doc = term.rt.editor_doc orelse return;
    const current_path = term.rt.editor_path orelse "";

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const targets = lsp.rpc.locationsFromResult(arena, result) catch return;
    // URI → 경로. `file:` 이 아닌 것은 뺀다(열 수 없다).
    var locs: std.ArrayList(reference_picker.Loc) = .empty;
    for (targets) |t| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = lsp.rpc.pathFromFileUri(t.uri, &path_buf) orelse continue;
        locs.append(arena, .{ .path = arena.dupe(u8, p) catch return, .line = t.line, .character = t.character }) catch return;
    }
    if (locs.items.len == 0) {
        st.notified_none += 1;
        self.showNoticeKey(.ref_none);
        return;
    }
    const root: []const u8 = self.git_repo orelse (self.file_tree.rootAt(0) orelse "");
    self.dismissMessageOverlays(); // 단일-오버레이 불변식 — 행을 세우기 **전에**(열려 있던 피커를 닫으면 그 행이 놓인다)
    var reader = DiskReader{ .session = self, .arena = arena };
    reference_picker.build(self.allocator, locs.items, .{
        .root = root,
        .current_path = current_path,
        .current_content = doc.file.content,
        .row_cols = rowCols(),
        .outside_title = maru.i18n.t(.ref_outside_title),
    }, &reader, &self.reference_picker_rows) catch {
        self.reference_picker_rows.clear(self.allocator);
        return;
    };
    const rows = &self.reference_picker_rows;
    if (rows.all.items.len == 1) {
        // **하나면 목록 없이 간다**(§8.2l) — 고를 것이 없다.
        goToRow(self, &rows.all.items[0]);
        rows.clear(self.allocator);
        return;
    }
    self.chrome_host.reference_picker.show();
    self.reference_picker_scroll = .{};
    self.reference_picker_followed_selected = null;
    self.chrome_host.reference_picker.selected = 0;
    self.chrome_host.reference_picker.setResultCount(rows.shown.items.len);
    self.chrome_host.reference_picker.prompt = promptText(self, rows.total, rows.truncated);
    st.opened += 1;
    self.metal_dirty = true;
}

/// 프롬프트 「참조 N개」(상한을 넘겼으면 `N+`). 버퍼는 세션이 든다(문서를 빌리지 않는다).
fn promptText(self: *AppSession, total: usize, truncated: bool) []const u8 {
    var num: [24]u8 = undefined;
    const n = std.fmt.bufPrint(&num, "{d}{s}", .{ total, if (truncated) "+" else "" }) catch return "";
    return maru.i18n.format(&self.reference_picker_prompt, maru.i18n.t(.ref_prompt), &.{.{ .s = n }});
    // (`reference_picker_prompt` 는 세션의 고정 버퍼 — `palette.State.prompt` 가 빌린다)
}

/// 쿼리가 바뀌었다 — 좁힌다(선택은 맨 위, 팔레트와 같은 규율).
pub fn recompute(self: *AppSession) void {
    const rows = &self.reference_picker_rows;
    rows.applyFilter(self.allocator, self.chrome_host.reference_picker.input.query.items) catch {};
    self.chrome_host.reference_picker.selected = 0;
    self.chrome_host.reference_picker.setResultCount(rows.shown.items.len);
}

/// 고른 행으로 간다. **닫고 나서 간다**(§7.5). 일치가 없으면 닫기만 한다.
pub fn accept(self: *AppSession) void {
    const rows = &self.reference_picker_rows;
    const idx = self.chrome_host.reference_picker.selected;
    self.chrome_host.reference_picker.hide();
    if (rows.shownRow(idx)) |row| {
        var copy = row.*; // 이동이 목록을 비울 수 있으므로 값을 뜬다(경로는 아래에서 사본으로)
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (copy.path.len <= path_buf.len) {
            @memcpy(path_buf[0..copy.path.len], copy.path);
            copy.path = path_buf[0..copy.path.len];
            goToRow(self, &copy);
        }
    }
    rows.clear(self.allocator);
    self.metal_dirty = true;
}

/// 피커가 닫혔다(Esc·다른 오버레이) — 행을 놓는다.
pub fn closed(self: *AppSession) void {
    self.reference_picker_rows.clear(self.allocator);
    self.metal_dirty = true;
}

fn goToRow(self: *AppSession, row: *const reference_picker.Row) void {
    const st = &self.editor_references;
    // `outside` 검사는 방어다 — `navigateTo` 의 `withinNavRoot` 가 같은 답을 내어 이 갈래가 없어도 알림은 같다(적대적 B4: 등가). 뜻으로 둔다:
    // 행이 「루트 밖」이라고 말했으면 열기 시도 자체를 안 한다.
    if (row.outside) {
        st.notified_outside += 1;
        self.showNoticeFmt(.nav_outside_root, &.{.{ .s = row.path }});
        return;
    }
    if (editor_ops.navigateTo(self, .{ .path = row.path, .pos = .{ .line = row.line, .character = row.character, .enc = st.enc } })) |_| {
        st.navigated += 1;
    } else |err| switch (err) {
        error.OutsideRoot => {
            st.notified_outside += 1;
            self.showNoticeFmt(.nav_outside_root, &.{.{ .s = row.path }});
        },
        error.Unopenable, error.NoDocument => {
            st.notified_none += 1;
            self.showNoticeKey(.ref_none);
        },
    }
}
