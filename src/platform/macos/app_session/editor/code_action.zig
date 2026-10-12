//! code action(docs/editor-surface-tooling.md §8.2h) — `⌘.`/팔레트로 `textDocument/codeAction` 을 묻고(범위 + 겹치는 진단), `edit` 이 있거나
//! resolve 할 수 있는 항목만 **컨텍스트 메뉴**(`context_menu` 의 `code_action_menu` 갈래)로 caret 아래에 낸다. 고르면 `edit` 을 §8.2f 의
//! `apply` 로(WorkspaceEdit 의 두 번째 소비자 — 전부 검증·저장 정책·기록), `edit` 이 없으면 `codeAction/resolve` 를 보내고 그 응답의 `edit` 을
//! 같은 길로. `command` 는 실행하지 않는다(§8.2 seam).
//!
//! 요청은 `7e8+seq`(resolve 는 `8e8+seq`) — 응답은 지금 기다리는 (서버, seq) 일 때만. 항목은 **복사**해 든다(title 과 원래 JSON 텍스트 —
//! resolve 에 그대로 되돌려 주려고).
//!
//! **서버가 여럿이면 각자에 묻고 합친다**(보조 언어 서버 §8.2u): 그 문서의 code action 을 하는 클라이언트마다(주 서버 먼저) 그 서버의 진단을
//! 문맥으로 묻고, 모두 답하거나 **첫 답 뒤 `aux_grace_ms`** 가 지나면 받은 것을 주 서버 먼저로 합쳐 낸다(늦은 서버 하나가 메뉴를 붙잡지
//! 않게). 항목은 그 서버의 이름을 든다 — 고르면 그 서버에 resolve 하고, 그 서버의 위치 인코딩으로 적용한다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const editor_lsp = @import("lsp.zig");
const editor_rename = @import("rename.zig");
const editor_wse = @import("workspace_edit.zig");
const pane_ops = @import("../pane.zig");
const settings_ops = @import("../settings.zig");
const term_ops = @import("../term.zig");
const lsp = maru.session.editor.lsp;

/// 메뉴 항목 상한. **버퍼 크기가 아니라 이 메뉴가 스스로 정한 상한**이다(버퍼는 `ctx_menu_buf_len`
/// 이고 이보다 크다). 예전엔 `ctx_menu_count` 가 두 뜻을 겸해 「버퍼 크기」라고 적혀 있었는데,
/// 2026-09-21 에 리소스 행을 늘리려고 그 상수를 키웠더니 이 메뉴의 항목 수까지 따라 커져
/// 판정자가 빨개졌다 — 그래서 뜻을 갈랐다. 여기는 탭 메뉴와 같은 수를 상한으로 쓴다.
pub const max_items: usize = app_session_mod.ctx_menu_count;

pub const Owned = struct {
    title: []u8,
    /// 원래 항목의 JSON 텍스트 — `edit` 이 없을 때 resolve 에 그대로.
    raw: []u8,
    has_edit: bool,
    /// 그 항목을 낸 서버(서버 표의 정적 이름 — §8.2u)와 그 서버의 순서(주 서버 0 — 합칠 때 앞).
    exe: []const u8 = "",
    origin: u8 = 0,

    fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.raw);
    }
};

/// 첫 답 뒤 나머지 서버를 기다리는 시간(§8.2u). 판정자가 바꾼다.
pub var aux_grace_ms: u64 = 500;

pub const Wait = struct { exe: []const u8, seq: u32, done: bool = false };

pub const State = struct {
    waiting: bool = false,
    waiting_surface: u64 = 0,
    /// 물은 서버들(주 서버 먼저 — 순서가 곧 `Owned.origin`).
    waits: [editor_lsp.max_doc_clients]Wait = undefined,
    waits_len: usize = 0,
    /// 첫 답이 온 시각(0 = 아직 — 그 전에는 시한이 없다, 서버 하나일 때와 같다).
    first_answer_ms: u64 = 0,
    /// 오류로 답한 서버의 첫 메시지(받은 항목이 없을 때만 알린다).
    error_buf: [256]u8 = undefined,
    error_len: usize = 0,
    any_error: bool = false,
    /// 모으는 중인 항목 — 다 모으면 `items` 와 바꾼다(열린 메뉴가 `items` 의 제목을 빌린다).
    pending: std.ArrayList(Owned) = .empty,
    resolve_waiting: bool = false,
    resolve_seq: u32 = 0,
    resolve_exe: []const u8 = "",
    /// 요청 시점의 열린 문서 revision(§8.2f 검증).
    snaps: [64]editor_wse.VersionSnap = undefined,
    snaps_len: usize = 0,
    /// 메뉴의 주인 문서.
    surface_id: u64 = 0,
    items: std.ArrayList(Owned) = .empty,
    /// 판정자 관측.
    opened_count: u64 = 0,
    notified_none: u64 = 0,
    notified_error: u64 = 0,
    applied: u64 = 0,
    resolved: u64 = 0,
    hidden: u64 = 0,
    /// 기다리는 사이 사용자가 다른 오버레이를 열어 버린 응답 수(`AppSession.interactiveOverlayOpen`).
    dropped_behind_overlay: u64 = 0,

    pub fn clearItems(self: *State, allocator: std.mem.Allocator) void {
        for (self.items.items) |*it| it.deinit(allocator);
        self.items.clearRetainingCapacity();
    }

    fn clearPending(self: *State, allocator: std.mem.Allocator) void {
        for (self.pending.items) |*it| it.deinit(allocator);
        self.pending.clearRetainingCapacity();
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearItems(allocator);
        self.items.deinit(allocator);
        self.clearPending(allocator);
        self.pending.deinit(allocator);
    }
};

pub fn deinit(self: *AppSession) void {
    self.editor_code_action.deinit(self.allocator);
}

/// `quick_fix` 명령·`⌘.` — 활성 편집기의 선택(없으면 caret)에서. 보냈으면 true.
pub fn quickFix(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editorDocument().opened orelse return false;
    if (doc.file.read_only) return false;
    const sel = term.rt.editor_selection orelse return false;
    const st = &self.editor_code_action;
    var buf: [editor_lsp.max_doc_clients]*editor_lsp.Client = undefined;
    const lo = @min(sel.start(), doc.file.content.len);
    const hi = @min(sel.end(), doc.file.content.len);
    var n: usize = 0;
    for (editor_lsp.codeActionClients(self, term, &buf)) |c| {
        const seq = editor_lsp.requestCodeAction(self, c, term, lo, hi) orelse continue;
        st.waits[n] = .{ .exe = c.server.exe, .seq = seq };
        n += 1;
    }
    if (n == 0) return false;
    st.waits_len = n;
    st.waiting = true;
    st.waiting_surface = term.surface.id;
    st.first_answer_ms = 0;
    st.any_error = false;
    st.error_len = 0;
    st.clearPending(self.allocator);
    snapshotVersions(self);
    return true;
}

/// codeAction 응답(`editor_lsp` 가 부른다). 기다리는 (서버, seq) 가 아니면 버린다. 모은다 — 다 모이면(또는 시한) `finish`.
pub fn onResponse(self: *AppSession, c: *editor_lsp.Client, seq: u32, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8) void {
    const st = &self.editor_code_action;
    if (!st.waiting) return;
    const w = for (st.waits[0..st.waits_len], 0..) |*w, i| {
        if (!w.done and w.seq == seq and std.mem.eql(u8, w.exe, c.server.exe)) break .{ w, i };
    } else return;
    w[0].done = true;
    if (st.first_answer_ms == 0) st.first_answer_ms = @max(self.awakeMs(), 1);
    if (is_error) {
        if (!st.any_error) {
            const m = error_message orelse "";
            st.error_len = @min(m.len, st.error_buf.len);
            @memcpy(st.error_buf[0..st.error_len], m[0..st.error_len]);
        }
        st.any_error = true;
    } else if (lsp.code_action.parse(self.allocator, result, c.code_action_caps.resolve)) |parsed| {
        var list = parsed;
        defer list.deinit(self.allocator);
        st.hidden += list.hidden;
        for (list.items) |it| {
            if (st.pending.items.len >= max_items) break;
            const raw = std.json.Stringify.valueAlloc(self.allocator, it.raw, .{}) catch break;
            const title = self.allocator.dupe(u8, it.title) catch {
                self.allocator.free(raw);
                break;
            };
            st.pending.append(self.allocator, .{ .title = title, .raw = raw, .has_edit = it.edit != null, .exe = c.server.exe, .origin = @intCast(w[1]) }) catch {
                self.allocator.free(raw);
                self.allocator.free(title);
                break;
            };
        }
    } else |_| {}
    for (st.waits[0..st.waits_len]) |x| if (!x.done) return;
    finish(self);
}

/// 시한(`editor_lsp.pump` 가 tick 마다) — 첫 답 뒤 `aux_grace_ms` 가 지났으면 받은 것으로 낸다.
pub fn tick(self: *AppSession, now_ms: u64) void {
    const st = &self.editor_code_action;
    if (!st.waiting or st.first_answer_ms == 0 or now_ms < st.first_answer_ms + aux_grace_ms) return;
    finish(self);
}

/// 모은 항목을 주 서버 먼저로 합쳐 낸다. 낼 것이 없으면 알림(오류로 답한 서버가 있으면 그 이유), 있으면 메뉴.
fn finish(self: *AppSession) void {
    const st = &self.editor_code_action;
    st.waiting = false;
    // **기다리는 사이 사용자가 다른 오버레이를 열었으면 버린다** — 메뉴도, 「없습니다」·오류 알림도(알림은 열린 오버레이를
    // 닫는다). 응답은 키를 누른 순간이 아니라 도착한 순간이라, 안 버리면 메뉴가 알림 패널·설정과 함께 열렸다(2026-10-08 재현).
    if (self.interactiveOverlayOpen()) {
        st.dropped_behind_overlay += 1;
        st.clearPending(self.allocator);
        return;
    }
    if (st.pending.items.len == 0) {
        if (st.any_error) {
            st.notified_error += 1;
            self.showNoticeFmt(.ca_error, &.{.{ .s = st.error_buf[0..st.error_len] }});
        } else {
            st.notified_none += 1;
            self.showNoticeKey(.ca_none);
        }
        return;
    }
    const term = visibleEditorTerm(self, st.waiting_surface) orelse {
        st.clearPending(self.allocator);
        return;
    };
    // 주 서버 먼저 — 같은 서버 안의 순서는 그 서버의 것(안정 정렬).
    std.mem.sort(Owned, st.pending.items, {}, struct {
        fn lt(_: void, a: Owned, b: Owned) bool {
            return a.origin < b.origin;
        }
    }.lt);
    // 열린 메뉴가 옛 `items` 의 제목을 빌린다 — 닫고 바꾼다.
    settings_ops.closeContextMenu(self);
    st.clearItems(self.allocator);
    std.mem.swap(std.ArrayList(Owned), &st.items, &st.pending);
    // 메뉴 — caret 셀 **아래**(`at_anchor` 는 앵커에서 시작하므로 한 셀 내리고, 모달 quad 의 padding 이 caret 줄을 덮지 않게 그만큼 더 띄운다 —
    // 호버 상자와 같은 간격, 캡처 실측). 앵커가 없으면(아직 안 그려짐) 화면 원점 근처.
    const sel = term.rt.editor_selection orelse return;
    const a = editor_rename.anchorAt(term, @min(sel.focus, term.rt.editorDocument().opened.?.file.content.len)) orelse editor_rename.Anchor{ .x = 0, .y = 0, .h = 0 };
    const gap: i32 = @intCast(self.buildChromeProps().shape.modal_padding_px);
    for (st.items.items, 0..) |it, i| self.context_menu_items_buf[i] = it.title;
    self.context_menu_items_len = st.items.items.len;
    st.surface_id = term.surface.id;
    self.code_action_menu = true;
    self.chrome_host.context_menu.show(a.x, a.y + @as(i32, @intCast(a.h)) + gap, st.items.items.len);
    st.opened_count += 1;
    self.metal_dirty = true;
}

/// 메뉴에서 고른 항목(`acceptContextMenu` 가 부른다 — 메뉴는 이미 닫혔다).
pub fn accept(self: *AppSession, index: usize) void {
    const st = &self.editor_code_action;
    if (index >= st.items.items.len) return;
    const item = st.items.items[index];
    const term = visibleEditorTerm(self, st.surface_id) orelse return;
    // 그 항목을 낸 서버(§8.2u) — 그 사이 내려갔으면 할 수 없다.
    const c = editor_lsp.docClientByExe(self, term, item.exe) orelse {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    if (item.has_edit) {
        applyRaw(self, item.raw, c.encoding);
        return;
    }
    // resolve — 항목 JSON 그대로, 그 서버에.
    const seq = editor_lsp.requestCodeActionResolve(self, c, item.raw) orelse {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    st.resolve_waiting = true;
    st.resolve_seq = seq;
    st.resolve_exe = item.exe;
}

/// resolve 응답 — `edit` 을 같은 길로. 늦게 온 응답이라 알림은 `showResponseNotice` 로(사용자가 그사이 연 오버레이를 닫지 않는다).
pub fn onResolveResponse(self: *AppSession, c: *editor_lsp.Client, seq: u32, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8) void {
    const st = &self.editor_code_action;
    if (!st.resolve_waiting or seq != st.resolve_seq or !std.mem.eql(u8, c.server.exe, st.resolve_exe)) return;
    const enc = c.encoding;
    st.resolve_waiting = false;
    if (is_error) {
        st.notified_error += 1;
        self.showResponseNotice(.ca_error, &.{.{ .s = error_message orelse "" }});
        return;
    }
    const r = result orelse {
        st.notified_none += 1;
        self.showResponseNotice(.ca_none, &.{});
        return;
    };
    if (r != .object) return;
    const edit = r.object.get("edit") orelse {
        st.notified_none += 1;
        self.showResponseNotice(.ca_none, &.{});
        return;
    };
    st.resolved += 1;
    applyEdit(self, edit, enc);
}

/// 항목 JSON 텍스트의 `edit` 을 적용한다 — 그 항목을 낸 서버의 위치 인코딩으로.
fn applyRaw(self: *AppSession, raw: []const u8, enc: lsp.rpc.PositionEncoding) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const edit = parsed.value.object.get("edit") orelse return;
    applyEdit(self, edit, enc);
}

/// 편집 적용 + 결과 알림. 알림은 `showResponseNotice` — resolve 응답(늦게 온다)에서도 오고, 메뉴에서 고른 직후(메뉴는 이미 닫혔다)에는
/// 판정이 거짓이라 `showNotice` 와 같다.
fn applyEdit(self: *AppSession, edit: std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_code_action;
    var parsed = lsp.workspace_edit.parse(self.allocator, edit) catch |err| switch (err) {
        error.Unsupported, error.Malformed => {
            self.editor_workspace_edit.refused_rejected += 1;
            self.showResponseNotice(.rn_rejected, &.{.{ .s = if (err == error.Unsupported) "file operation" else "malformed" }});
            return;
        },
        error.OutOfMemory => return,
    };
    defer parsed.deinit(self.allocator);
    switch (editor_wse.apply(self, parsed, enc, st.snaps[0..st.snaps_len])) {
        .applied => |n| {
            st.applied += 1;
            self.showResponseNotice(.ca_applied, &.{.{ .d = @intCast(n) }});
        },
        .refused => |r| switch (r) {
            .outside_root => |p| self.showResponseNotice(.rn_outside_root, &.{.{ .s = p }}),
            .stale => self.showResponseNotice(.rn_stale, &.{}),
            .rejected => |p| self.showResponseNotice(.rn_rejected, &.{.{ .s = p }}),
            .out_of_memory => {},
        },
    }
}

fn snapshotVersions(self: *AppSession) void {
    const st = &self.editor_code_action;
    st.snaps_len = 0;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (t.kind != .editor or t.rt.editorDocument().opened == null) continue;
        if (st.snaps_len >= st.snaps.len) return;
        st.snaps[st.snaps_len] = .{ .surface_id = t.surface.id, .version = t.rt.editorDocument().notifications.lsp_version };
        st.snaps_len += 1;
    };
}

fn visibleEditorTerm(self: *AppSession, surface_id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, surface_id, struct {
        fn pred(want: u64, t: *Term) bool {
            return t.kind == .editor and t.surface.id == want;
        }
    }.pred) orelse return null;
    if (loc.tab_index != self.app_window.active_tab) return null;
    const term = loc.pane.terms.items[loc.term_index];
    if (loc.pane.activeTerm() != term) return null;
    return term;
}
