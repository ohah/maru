//! 저장 시 code action(docs/editor-surface-tooling.md §8.2s — 계획 docs/plans/editor-code-actions-on-save.md). 사용자의 `⌘S` 가 설정
//! `editor.code-actions-on-save` 의 kind 를 **적힌 순서대로 하나씩** 묻고(`textDocument/codeAction` — `only` 에 그 kind, 문서 전체,
//! `triggerKind: 2`), 그 kind 에 드는 첫 항목(`isPreferred` 가 앞)을 그 문서에 적용한 뒤 다음 kind 로 간다. 다 돌면 저장 시 포맷(§8.2r —
//! `format.continueSave`)으로 넘긴다 — VS Code 와 같이 code action 이 포맷보다 먼저다.
//!
//! - **그 문서만 고친다**(2026-10-11 사용자 결정): edit 이 다른 파일·파일 연산을 건드리면 그 항목을 건너뛴다 — `⌘S` 하나가 화면에 없는
//!   파일을 디스크에 쓰지 않는다.
//! - `edit` 이 없으면 `codeAction/resolve` 로 받는다(§8.2h 와 같다). `command` 는 실행하지 않는다(§8.2 seam).
//! - 요청마다 시한(`format.save_format_timeout_ms` — 같은 1 초)이 있다. 넘기면 남은 kind 를 건너뛰고 알린 뒤 포맷·저장으로 간다. 응답 뒤
//!   문서가 바뀌었으면(기다리는 사이 타이핑) 남은 kind 를 건너뛰고 알린 뒤 포맷·저장으로 간다 — 저장은 code action 때문에 사라지지 않는다.
//! - 각 적용은 되돌리기 하나다(포맷과 따로).
//! - **서버가 여럿이면**(보조 언어 서버 §8.2u) kind 마다 그 kind 를 알린 서버(`codeActionKinds` 가 덮는 것 — 알리지 않았으면 무엇이든)에
//!   **주 서버 먼저** 차례로 묻는다. 하나를 적용하면 revision 이 올라 다음 서버의 요청이 새 본문을 본다. 서버마다 시한이 따로다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const editor_lsp = @import("lsp.zig");
const format_client = @import("format.zig");
const term_ops = @import("../term.zig");
const lsp = maru.session.editor.lsp;

pub const State = struct {
    /// 이 문서의 저장이 code action 단계에 있다.
    active: bool = false,
    surface: u64 = 0,
    /// `⌘S` 순간의 설정 목록 **사본** — 기다리는 사이 Reload Config(파일 감시 자동 reload 포함)가 설정 문자열을 바꾸거나 풀어도 이
    /// 저장은 누른 순간의 목록을 끝까지 돈다(처음엔 설정 문자열 안의 위치만 들어, 바뀐 문자열의 엉뚱한 자리부터 읽었다 — 적대적 검증
    /// 2회차). 넘치면 들어가는 데까지(그 뒤 kind 는 묻지 않는다 — 512 바이트면 kind 스무 개가 넘는다).
    list_buf: [512]u8 = undefined,
    list_len: usize = 0,
    /// 사본에서 다음 kind 를 읽을 자리(`code_action.nextKind`).
    kind_pos: usize = 0,
    /// 지금 묻는 kind(사본 안) — 응답의 항목을 거른다.
    kind_start: usize = 0,
    kind_len: usize = 0,
    stage: Stage = .request,
    waiting_seq: u32 = 0,
    /// 지금 kind 를 물을 서버들(그 문서의 code action 클라이언트 — 주 서버 먼저, 이름으로 든다)과 다음 자리.
    targets: [editor_lsp.max_doc_clients][]const u8 = undefined,
    targets_len: usize = 0,
    target_pos: usize = 0,
    /// 지금 기다리는 서버 — 응답은 이 서버의 것이어야 한다(seq 는 클라이언트마다 따로 센다).
    waiting_exe: []const u8 = "",
    asked_version: u64 = 0,
    deadline_ms: u64 = 0,
    /// 판정자 관측.
    applied: u64 = 0,
    skipped_other_files: u64 = 0,
    rejected: u64 = 0,
    stale: u64 = 0,
    timeouts: u64 = 0,

    pub const Stage = enum { request, resolve };

    fn kind(self: *const State) []const u8 {
        return self.list_buf[self.kind_start..][0..self.kind_len];
    }

    fn list(self: *const State) []const u8 {
        return self.list_buf[0..self.list_len];
    }
};

/// `editor_save`(`⌘S`). 설정한 kind 가 있고 그 문서의 서버가 code action 을 하면 묻기 시작한다. 아니면 곧바로 저장 시 포맷 단계로
/// (`format.saveCommand` — 그쪽이 포맷 여부와 저장을 정한다). 같은 문서가 이미 이 단계면 무동작(시한 안에 끝난다); 다른 문서가 이
/// 단계면 그 문서의 남은 kind 를 건너뛰고 포맷·저장으로 먼저 보낸다(자리가 하나다 — 누른 저장을 잃지 않는다).
pub fn saveCommand(self: *AppSession, term: *Term) void {
    if (@import("save/as.zig").deferCommand(self, term)) return;
    const st = &self.editor_save_actions;
    if (st.active) {
        if (st.surface == term.surface.id) return;
        finish(self, false);
    }
    if (eligible(self, term)) {
        st.* = .{ .active = true, .surface = term.surface.id, .applied = st.applied, .skipped_other_files = st.skipped_other_files, .rejected = st.rejected, .stale = st.stale, .timeouts = st.timeouts };
        const cfg = self.loaded_config.config.editor.code_actions_on_save;
        st.list_len = @min(cfg.len, st.list_buf.len);
        @memcpy(st.list_buf[0..st.list_len], cfg[0..st.list_len]);
        if (next(self, term)) return;
        st.active = false;
    }
    format_client.saveCommand(self, term);
}

/// 설정이 비었는지는 따로 보지 않는다 — 빈 목록이면 `next` 가 kind 를 못 찾아 곧바로 포맷 단계로 간다(변이 S11 이 등가를 드러냈다).
fn eligible(self: *AppSession, term: *Term) bool {
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editorDocument().opened orelse return false;
    if (doc.file.read_only) return false;
    var buf: [editor_lsp.max_doc_clients]*editor_lsp.Client = undefined;
    return editor_lsp.codeActionClients(self, term, &buf).len > 0;
}

/// 다음 kind 를 묻는다. 보냈으면 true, 더 물을 것이 없으면(목록 끝·보내지 못함) false.
fn next(self: *AppSession, term: *Term) bool {
    const st = &self.editor_save_actions;
    while (true) {
        // 이 kind 의 남은 서버 — 그 kind 를 알린 것에만 묻는다.
        while (st.target_pos < st.targets_len) {
            const exe = st.targets[st.target_pos];
            st.target_pos += 1;
            const c = editor_lsp.docClientByExe(self, term, exe) orelse continue;
            if (!c.code_action_caps.covers(st.kind())) continue;
            const seq = editor_lsp.requestCodeActionOnSave(self, c, term, st.kind()) orelse continue;
            st.stage = .request;
            st.waiting_seq = seq;
            st.waiting_exe = c.server.exe;
            st.asked_version = term.rt.editorDocument().notifications.lsp_version;
            st.deadline_ms = self.awakeMs() + format_client.save_format_timeout_ms;
            return true;
        }
        // 다음 kind — 그 문서의 code action 서버를 주 서버 먼저로 다시 센다.
        const k = lsp.code_action.nextKind(st.list(), &st.kind_pos) orelse return false;
        st.kind_start = @intFromPtr(k.ptr) - @intFromPtr(&st.list_buf);
        st.kind_len = k.len;
        var buf: [editor_lsp.max_doc_clients]*editor_lsp.Client = undefined;
        const cs = editor_lsp.codeActionClients(self, term, &buf);
        for (cs, 0..) |c, i| st.targets[i] = c.server.exe;
        st.targets_len = cs.len;
        st.target_pos = 0;
    }
}

/// code action 단계를 끝내고 포맷·저장으로 넘긴다. `late` — 응답·시한 뒤(실패 알림은 늦은 응답의 규칙). 문서가 닫혔으면 할 것이 없다.
fn finish(self: *AppSession, late: bool) void {
    const st = &self.editor_save_actions;
    st.active = false;
    const term = editorTerm(self, st.surface) orelse return;
    if (late) format_client.continueSave(self, term) else format_client.saveCommand(self, term);
}

/// 시한(`editor_lsp.pump` 가 tick 마다 — 언어 서버를 꺼도). 넘겼으면 남은 kind 를 건너뛰고 알린 뒤 포맷·저장으로.
pub fn tick(self: *AppSession, now_ms: u64) void {
    const st = &self.editor_save_actions;
    if (!st.active or now_ms < st.deadline_ms) return;
    st.timeouts += 1;
    self.showResponseNotice(.csa_timeout, &.{});
    finish(self, true);
}

/// codeAction 응답의 입구(`editor_lsp` 가 부른다). 이 단계가 기다리는 응답이면 받고 true — 아니면 false(메뉴 §8.2h 의 것이다). 응답을 보낸
/// 서버가 그 문서를 연 서버여야 한다(seq 는 클라이언트마다 따로 센다 — 포맷의 `onClientResponse` 와 같은 규율).
pub fn onClientResponse(self: *AppSession, c: *editor_lsp.Client, seq: u32, result: ?std.json.Value) bool {
    const st = &self.editor_save_actions;
    if (!st.active or st.stage != .request or seq != st.waiting_seq or !std.mem.eql(u8, c.server.exe, st.waiting_exe)) return false;
    const term = editorTerm(self, st.surface) orelse {
        st.active = false;
        return true;
    };
    if (c.findDoc(term) == null) return false;
    if (!sameRevision(self, term)) return true;
    var list = lsp.code_action.parse(self.allocator, result, c.code_action_caps.resolve) catch lsp.code_action.List{};
    defer list.deinit(self.allocator);
    for (list.items) |it| {
        if (!lsp.code_action.kindMatches(it.kind, st.kind())) continue;
        if (it.edit) |edit| {
            applyToDoc(self, c, term, edit);
            break;
        }
        // `edit` 이 없다 — resolve(§8.2h 와 같다). 항목 JSON 그대로.
        const raw = std.json.Stringify.valueAlloc(self.allocator, it.raw, .{}) catch break;
        defer self.allocator.free(raw);
        const rseq = editor_lsp.requestCodeActionResolve(self, c, raw) orelse break;
        st.stage = .resolve;
        st.waiting_seq = rseq;
        st.deadline_ms = self.awakeMs() + format_client.save_format_timeout_ms;
        return true;
    }
    advance(self, term);
    return true;
}

/// codeAction/resolve 응답의 입구 — 이 단계가 기다리는 것이면 받고 true.
pub fn onClientResolveResponse(self: *AppSession, c: *editor_lsp.Client, seq: u32, result: ?std.json.Value) bool {
    const st = &self.editor_save_actions;
    if (!st.active or st.stage != .resolve or seq != st.waiting_seq or !std.mem.eql(u8, c.server.exe, st.waiting_exe)) return false;
    const term = editorTerm(self, st.surface) orelse {
        st.active = false;
        return true;
    };
    if (c.findDoc(term) == null) return false;
    if (!sameRevision(self, term)) return true;
    if (result) |r| if (r == .object) if (r.object.get("edit")) |edit| applyToDoc(self, c, term, edit);
    advance(self, term);
    return true;
}

/// 요청 뒤 문서가 바뀌었으면(기다리는 사이 타이핑·다른 적용) 남은 kind 를 건너뛰고 알린 뒤 포맷·저장으로 — 결과는 그 문서의 것이 아니다.
fn sameRevision(self: *AppSession, term: *Term) bool {
    const st = &self.editor_save_actions;
    if (term.rt.editorDocument().notifications.lsp_version == st.asked_version) return true;
    st.stale += 1;
    self.showResponseNotice(.csa_stale, &.{});
    finish(self, true);
    return false;
}

/// 다음 kind 로 — 없으면 포맷·저장으로.
fn advance(self: *AppSession, term: *Term) void {
    if (next(self, term)) return;
    finish(self, true);
}

/// `WorkspaceEdit` 을 **그 문서에만** 적용한다. 다른 파일·파일 연산을 건드리면 건너뛰고 알린다(2026-10-11 사용자 결정). 겹치거나 모양이
/// 틀리면 거부하고 알린다(아무것도 적용하지 않는다 — §8.2e 와 같다).
fn applyToDoc(self: *AppSession, c: *editor_lsp.Client, term: *Term, edit: std.json.Value) void {
    const st = &self.editor_save_actions;
    const d = c.findDoc(term) orelse return;
    var parsed = lsp.workspace_edit.parse(self.allocator, edit) catch |err| switch (err) {
        error.Unsupported => {
            st.skipped_other_files += 1;
            self.showResponseNotice(.csa_other_files, &.{.{ .s = st.kind() }});
            return;
        },
        error.Malformed => {
            st.rejected += 1;
            self.showResponseNotice(.csa_rejected, &.{.{ .s = st.kind() }});
            return;
        },
        error.OutOfMemory => return,
    };
    defer parsed.deinit(self.allocator);
    for (parsed.files) |f| if (!std.mem.eql(u8, f.uri, d.uri)) {
        st.skipped_other_files += 1;
        self.showResponseNotice(.csa_other_files, &.{.{ .s = st.kind() }});
        return;
    };
    // 같은 uri 는 `parse` 가 한 항목으로 이어 붙인다 — 남은 것은 그 문서 하나다.
    if (parsed.files.len == 0) return;
    const f = parsed.files[0];
    const doc = term.rt.editorDocument().opened orelse return;
    var changes = lsp.text_edits.toChanges(self.allocator, .{ .array = .{ .items = f.edits, .capacity = f.edits.len, .allocator = self.allocator, .pointer_stability = .{} } }, doc.file.content, doc.file.lines, c.encoding) catch |err| switch (err) {
        error.Overlap, error.Malformed => {
            st.rejected += 1;
            self.showResponseNotice(.csa_rejected, &.{.{ .s = st.kind() }});
            return;
        },
        error.OutOfMemory => return,
    };
    defer changes.deinit(self.allocator);
    if (changes.items.len == 0) return;
    // `WithUndo` — 선택이 없는 문서도 적용한다(§8.2r 「선택 없는 문서」와 같다). 적용하면 revision 이 올라 다음 kind 의 요청이 새 본문을 본다.
    if (editor_ops.applyEditAsOneWithUndo(self, term, changes.items)) st.applied += 1;
}

fn editorTerm(self: *AppSession, surface_id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, surface_id, struct {
        fn pred(want: u64, t: *Term) bool {
            return t.kind == .editor and t.surface.id == want;
        }
    }.pred) orelse return null;
    return loc.pane.terms.items[loc.term_index];
}
