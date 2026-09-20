//! 자동완성 팝업(docs/editor-surface-tooling.md §8.2g · native-editor-ui §8.2) — 식별자 글자·서버 트리거 글자·`⌃Space` 로 `textDocument/completion`
//! 을 묻고, 응답 목록을 **로컬 필터**(접두사 `[word_start, caret)`)로 좁혀 `suggest_box` 에 낸다. `↑↓` 고르기·`Enter`/`Tab` 확정·`Esc` 닫기만
//! 소비하고 나머지 키는 편집기로 흘린다(타이핑하면서 좁혀진다). 고르면 §3.6 — 주 편집(접두사 교체) + `additionalTextEdits` 가 `applyEditAsOne`
//! 하나다.
//!
//! 요청은 `6e8+seq` — 한 번에 하나, 대기 중 트리거는 `dirty` 로 응답 뒤 한 번 더(시그니처와 같은 규율). 응답의 항목은 **복사**해
//! 든다(트리는 사라진다) — `additionalTextEdits` 는 응답 시점 본문으로 byte 에 옮겨 두고, 확정 때 그 뒤 문서가 바뀌었으면 전부 `word_start`
//! 앞에서 끝날 때만 함께 적용한다(타이핑은 `word_start` 뒤에서만 일어나므로 그 앞의 offset 은 그대로다).

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const editor_rename = @import("editor_rename.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const lsp = maru.session.editor.lsp;
const completion = lsp.completion;
const suggest_box = chrome.components.suggest_box;
const suggest_docs = chrome.components.suggest_docs;
const hover_text = maru.session.editor.hover_text;

/// 응답에서 복사해 든 항목.
pub const Owned = struct {
    label: []u8,
    filter: []u8,
    sort: []u8,
    insert: []u8,
    detail: []u8,
    /// `labelDetails.detail` — label 뒤 꼬리(§8.2g-c). 버퍼 단어는 빈 문자열.
    label_detail: []u8 = &.{},
    /// `labelDetails.description` — 오른쪽 열(§8.2g-c); 비면 행은 `detail` 을 쓴다.
    description: []u8 = &.{},
    /// `documentation`(§8.2g-d) — 패널의 글(마크다운/평문). resolve 가 채우기도 한다.
    documentation: []u8 = &.{},
    preselect: bool,
    /// `textEdit.range.start` 를 byte 로(응답 시점 본문) — 낱말 시작을 이긴다.
    edit_start: ?usize,
    /// `additionalTextEdits` 를 byte 로(응답 시점 본문).
    additional: lsp.text_edits.Changes,
    /// LSP kind(버퍼 단어는 `word_kind`).
    kind: u8 = 0,
    /// 원래 항목 JSON 텍스트 — `completionItem/resolve` 에 그대로(버퍼 단어는 빈 문자열).
    raw: []u8 = &.{},
    /// resolve 가 끝났다(또는 필요 없다).
    resolved: bool = true,

    fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.filter);
        allocator.free(self.sort);
        allocator.free(self.insert);
        allocator.free(self.detail);
        if (self.label_detail.len > 0) allocator.free(self.label_detail);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.documentation.len > 0) allocator.free(self.documentation);
        self.additional.deinit(allocator);
        if (self.raw.len > 0) allocator.free(self.raw);
    }
};

pub const State = struct {
    active: bool = false,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_surface: u64 = 0,
    /// 대기 중에 온 트리거 — 응답 뒤 한 번 더 묻는다.
    dirty: bool = false,
    dirty_trigger: ?u8 = null,
    /// 요청 때의 낱말 시작(접두사의 왼쪽 끝)과 트리거 글자로 열렸는가(그때는 빈 접두사가 정상이다).
    asked_word_start: usize = 0,
    asked_by_trigger: bool = false,
    opened_by_trigger: bool = false,
    /// 팝업의 주인 문서와 낱말 시작·응답 시점 revision.
    surface_id: u64 = 0,
    word_start: usize = 0,
    response_version: u64 = 0,
    incomplete: bool = false,
    items: std.ArrayList(Owned) = .empty,
    /// 필터·정렬된 첨자(`items` 의).
    order: std.ArrayList(usize) = .empty,
    /// 마지막으로 필터한 접두사(바뀌었을 때만 다시 센다).
    last_prefix: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(suggest_box.Row) = .empty,
    /// 문서 패널의 줄(§8.2g-d) — 글은 우리 소유(`docs_texts`). `docs_item` 항목의 것; 강조·응답마다 다시 만든다.
    docs_lines: std.ArrayList(suggest_docs.Line) = .empty,
    docs_item: ?usize = null,
    /// 강조가 이 항목으로 온 시각(ms) — 미해결이면 250 ms 뒤에야 로딩 줄을 세운다.
    docs_since_ms: u64 = 0,
    docs_loading: bool = false,
    /// 줄이 그 항목의 최종본이다(풀린 뒤 세움). resolve 응답에서 내릴 필요는 없다 — 풀리기 전엔 참이 될 수 없다(적대적 2회차 B11: 그 줄은 등가라 뺐다).
    docs_ready: bool = false,
    docs_built: u64 = 0,
    /// resolve(§8.2g-b): 나가 있는 요청의 seq 와 그 항목(`items` 첨자), 확정이 그 응답을 기다리는가와 기다리기 시작한 시각.
    resolve_waiting: bool = false,
    resolve_seq: u32 = 0,
    resolve_item: usize = 0,
    pending_accept: bool = false,
    pending_since_ms: u64 = 0,
    /// 서버 없이 버퍼 단어만으로 열렸다(재요청·resolve 없음).
    words_only: bool = false,
    /// 판정자 관측.
    opened_count: u64 = 0,
    resolved_count: u64 = 0,
    accepted_after_resolve: u64 = 0,
    accepted_on_timeout: u64 = 0,
    docs_toggles: u64 = 0,
    words_opened: u64 = 0,
    closed_empty: u64 = 0,
    accepted: u64 = 0,
    accepted_with_additional: u64 = 0,
    dropped_additional: u64 = 0,
    refetched: u64 = 0,

    pub fn clearItems(self: *State, allocator: std.mem.Allocator) void {
        for (self.items.items) |*it| it.deinit(allocator);
        self.items.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.last_prefix.clearRetainingCapacity();
        self.clearDocs(allocator);
    }

    pub fn clearDocs(self: *State, allocator: std.mem.Allocator) void {
        for (self.docs_lines.items) |l| allocator.free(l.text);
        self.docs_lines.clearRetainingCapacity();
        self.docs_item = null;
        self.docs_loading = false;
        self.docs_ready = false;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearItems(allocator);
        self.items.deinit(allocator);
        self.order.deinit(allocator);
        self.rows.deinit(allocator);
        self.docs_lines.deinit(allocator);
        self.last_prefix.deinit(allocator);
    }
};

pub fn deinit(self: *AppSession) void {
    self.editor_completion.deinit(self.allocator);
}

fn enabled(self: *const AppSession) bool {
    return self.loaded_config.config.editor.quick_suggestions;
}

pub fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// 타이핑(`insertText`)의 마지막 byte — 서버 트리거 글자면 묻는다(설정과 무관), 식별자 글자면 설정이 켜졌을 때 묻는다(열려 있으면 `refresh`
/// 가 접두사로 좁힌다). 그 밖의 글자는 `refresh` 가 접두사 불일치로 닫는다.
pub fn noteTyped(self: *AppSession, term: *Term, last: u8) void {
    const st = &self.editor_completion;
    const triggers = editor_lsp.completionTriggersFor(self, term);
    const server = triggers != null and triggers.?.supported;
    if (server and triggers.?.isTrigger(last)) {
        _ = ask(self, term, last);
        return;
    }
    if (!isIdent(last) or !enabled(self)) return;
    if (st.active and st.surface_id == term.surface.id) return; // 열려 있다 — 프레임의 refresh 가 좁힌다(isIncomplete 면 거기서 다시 묻는다)
    if (server) {
        _ = ask(self, term, null);
    } else {
        // 서버가 없다 — 버퍼 단어만으로 그 자리에서 연다(§8.2g-b · ui §8.2 「LSP 가 없다고 자동완성이 없는 상태가 되지는 않는다」).
        _ = openWordsOnly(self, term, null);
    }
}

/// `trigger_suggest` 명령·`⌃Space`·`⌥Esc` — 설정을 꺼도 온다. 보냈으면 true.
pub fn triggerManual(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    if (term.rt.editor_selection == null) return false;
    // 목록이 보이고 강조 항목이 있으면 같은 키가 문서 패널을 토글한다(§8.2g-d — VS Code 의 `⌃Space` 와 같다).
    const st = &self.editor_completion;
    if (st.active and self.chrome_host.suggest_box.open and st.order.items.len > 0) {
        self.chrome_host.suggest_docs.toggle();
        st.docs_toggles += 1;
        st.docs_item = null; // 다음 프레임이 다시 만든다(접었으면 비운다)
        self.metal_dirty = true;
        return true;
    }
    const triggers = editor_lsp.completionTriggersFor(self, term);
    if (triggers != null and triggers.?.supported) return ask(self, term, null);
    return openWordsOnly(self, term, null);
}

/// 서버 없이 버퍼 단어만으로 목록을 세운다(§8.2g-b). 열렸으면 true.
fn openWordsOnly(self: *AppSession, term: *Term, trigger_char: ?u8) bool {
    const st = &self.editor_completion;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    const sel = term.rt.editor_selection orelse return false;
    const caret = @min(sel.focus, doc.file.content.len);
    st.waiting = false;
    st.dirty = false;
    st.asked_word_start = wordStart(doc.file.content, caret);
    st.asked_by_trigger = trigger_char != null;
    if (!installItems(self, term, &.{}, false, .utf8)) return false;
    st.words_only = true;
    st.words_opened += 1;
    return true;
}

fn ask(self: *AppSession, term: *Term, trigger_char: ?u8) bool {
    const st = &self.editor_completion;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    const sel = term.rt.editor_selection orelse return false;
    const caret = @min(sel.focus, doc.file.content.len);
    if (st.waiting) {
        st.dirty = true;
        st.dirty_trigger = trigger_char;
        return true;
    }
    const seq = editor_lsp.requestCompletion(self, term, caret, trigger_char) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_surface = term.surface.id;
    st.asked_word_start = wordStart(doc.file.content, caret);
    st.asked_by_trigger = trigger_char != null;
    st.dirty = false;
    return true;
}

/// caret 앞 식별자 구간의 시작 — 트리거 글자 뒤라면 caret 그대로.
pub fn wordStart(content: []const u8, caret: usize) usize {
    var s = @min(caret, content.len);
    while (s > 0 and isIdent(content[s - 1])) s -= 1;
    return s;
}

/// 응답(`editor_lsp` 가 부른다). 낡은 seq 는 버린다. 목록을 복사해 들고 접두사로 좁혀 연다(0 이면 닫힌 채).
pub fn onResponse(self: *AppSession, seq: u32, result: ?std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_completion;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    defer if (st.dirty) {
        st.dirty = false;
        if (visibleEditorTerm(self, st.waiting_surface)) |t| _ = ask(self, t, st.dirty_trigger);
    };
    const term = visibleEditorTerm(self, st.waiting_surface) orelse {
        hide(self);
        return;
    };
    const doc = term.rt.editor_doc orelse {
        hide(self);
        return;
    };
    var list = completion.parse(self.allocator, result) catch {
        hide(self);
        return;
    };
    defer list.deinit(self.allocator);
    _ = doc;
    _ = installItems(self, term, list.items, list.incomplete, enc); // words_only 는 그 안에서 지운다(적대적 4회차 B23v: 여기 있던 중복이 판정자를 가렸다)
}

/// LSP 항목(있으면) + 버퍼 단어를 병합해 목록을 세운다(§8.2g-b). 항목은 복사한다. 0 이면 닫힌 채 false.
fn installItems(self: *AppSession, term: *Term, lsp_items: []const completion.Item, incomplete: bool, enc: lsp.rpc.PositionEncoding) bool {
    const st = &self.editor_completion;
    const doc = term.rt.editor_doc orelse return false;
    const content = doc.file.content;
    const sel = term.rt.editor_selection orelse return false;
    const caret = @min(sel.focus, content.len);
    const typing = content[@min(st.asked_word_start, caret)..caret];
    const words = completion.bufferWords(self.allocator, content, typing) catch return false;
    defer self.allocator.free(words);
    var merged = completion.mergeSources(self.allocator, lsp_items, words, incomplete) catch return false;
    defer merged.deinit(self.allocator);
    st.clearItems(self.allocator);
    const can_resolve = if (editor_lsp.completionTriggersFor(self, term)) |t| t.resolve else false;
    for (merged.list.items) |it| {
        // 부분 실패(할당 하나가 실패)는 앞서 든 것을 놓고 멈춘다 — `FailingAllocator` 판정자(EDIT6)가 이 길을 지난다.
        var owned = ownedFrom(self.allocator, it, content, doc.file.lines, enc, can_resolve) catch break;
        st.items.append(self.allocator, owned) catch {
            owned.deinit(self.allocator);
            break;
        };
    }
    st.surface_id = term.surface.id;
    st.word_start = st.asked_word_start;
    st.opened_by_trigger = st.asked_by_trigger;
    st.response_version = term.rt.editor_lsp_version;
    st.incomplete = incomplete;
    st.resolve_waiting = false;
    st.pending_accept = false;
    st.words_only = false; // 서버 목록이 섰다 — `openWordsOnly` 가 뒤에 다시 세운다(적대적 2회차 B23: hide 의 것만으론 판정자가 못 봤다)
    const was_active = st.active;
    st.active = true;
    if (!refilter(self, term, true)) {
        hide(self);
        return false;
    }
    if (!was_active) st.opened_count += 1;
    resolveHighlighted(self, term);
    return true;
}

fn ownedFrom(allocator: std.mem.Allocator, it: completion.Item, content: []const u8, lines: maru.session.editor.line_index.LineIndex, enc: lsp.rpc.PositionEncoding, can_resolve: bool) error{OutOfMemory}!Owned {
    const label = try allocator.dupe(u8, it.label);
    errdefer allocator.free(label);
    const filter = try allocator.dupe(u8, it.filter);
    errdefer allocator.free(filter);
    const sort = try allocator.dupe(u8, it.sort);
    errdefer allocator.free(sort);
    const insert = try allocator.dupe(u8, it.insert);
    errdefer allocator.free(insert);
    const detail = try allocator.dupe(u8, it.detail orelse "");
    errdefer allocator.free(detail);
    // 빈 것은 복사하지 않는다(빈 슬라이스는 놓지 않는다 — `deinit` 과 짝). 빈 dupe 도 0 바이트라 누수는 아니다(적대적 2회차 B8: 등가) — 뜻을 위해 남긴다.
    const label_detail: []u8 = if (it.label_detail) |ld| (if (ld.len > 0) try allocator.dupe(u8, ld) else &.{}) else &.{};
    errdefer if (label_detail.len > 0) allocator.free(label_detail);
    const description: []u8 = if (it.description) |d| (if (d.len > 0) try allocator.dupe(u8, d) else &.{}) else &.{};
    errdefer if (description.len > 0) allocator.free(description);
    const documentation: []u8 = if (it.documentation) |d| (if (d.len > 0) try allocator.dupe(u8, d) else &.{}) else &.{};
    errdefer if (documentation.len > 0) allocator.free(documentation);
    var additional: lsp.text_edits.Changes = .{};
    if (it.additional) |ad| {
        additional = lsp.text_edits.toChanges(allocator, .{ .array = .{ .items = ad, .capacity = ad.len, .allocator = allocator } }, content, lines, enc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{},
        };
    }
    errdefer additional.deinit(allocator);
    var raw: []u8 = &.{};
    var resolved = true;
    // resolve 가 되는 서버의 LSP 항목은 additional 이 아직 없을 수 있다 — 강조될 때 묻는다.
    if (can_resolve and it.raw != null and it.additional == null) {
        raw = try std.json.Stringify.valueAlloc(allocator, it.raw.?, .{});
        resolved = false;
    }
    return .{
        .label = label,
        .filter = filter,
        .sort = sort,
        .insert = insert,
        .detail = detail,
        .label_detail = label_detail,
        .description = description,
        .documentation = documentation,
        .preselect = it.preselect,
        .edit_start = if (it.edit_range) |r| lsp.position.offsetOf(content, lines, r.start.line, r.start.character, enc) else null,
        .additional = additional,
        .kind = it.kind,
        .raw = raw,
        .resolved = resolved,
    };
}

/// 강조된 항목이 아직 안 풀렸으면 `completionItem/resolve` 를 보낸다(한 번에 하나 — 나가 있으면 다음 강조 때).
fn resolveHighlighted(self: *AppSession, term: *Term) void {
    const st = &self.editor_completion;
    if (st.resolve_waiting or st.order.items.len == 0) return;
    const pick = @min(self.chrome_host.suggest_box.selected, st.order.items.len - 1);
    const idx = st.order.items[pick];
    const item = st.items.items[idx];
    if (item.resolved or item.raw.len == 0) return;
    const seq = editor_lsp.requestCompletionResolve(self, term, item.raw) orelse {
        st.items.items[idx].resolved = true; // 못 보내면 그대로 쓴다 — 동작상 등가(Enter 는 어차피 다시 못 보내고 적용한다), 강조마다 되묻지 않게 하는 표시(적대적 2회차 B10)
        return;
    };
    st.resolve_waiting = true;
    st.resolve_seq = seq;
    st.resolve_item = idx;
}

/// resolve 응답(`editor_lsp` 가 부른다) — 그 항목에 합치고, 확정이 기다리고 있었으면 지금 적용한다.
pub fn onResolveResponse(self: *AppSession, seq: u32, result: ?std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_completion;
    if (!st.resolve_waiting or seq != st.resolve_seq) return;
    st.resolve_waiting = false;
    if (!st.active or st.resolve_item >= st.items.items.len) return;
    const term = visibleEditorTerm(self, st.surface_id) orelse return;
    const doc = term.rt.editor_doc orelse return;
    var item = &st.items.items[st.resolve_item];
    item.resolved = true;
    if (result) |r| if (r == .object) {
        // 순수 `applyResolved` 로 합친 뒤 우리 소유로 복사한다.
        var view: completion.Item = .{ .label = item.label, .filter = item.filter, .sort = item.sort, .insert = item.insert };
        completion.applyResolved(&view, r);
        if (view.additional) |ad| {
            item.additional.deinit(self.allocator);
            item.additional = lsp.text_edits.toChanges(self.allocator, .{ .array = .{ .items = ad, .capacity = ad.len, .allocator = self.allocator } }, doc.file.content, doc.file.lines, enc) catch .{};
        }
        if (!std.mem.eql(u8, view.insert, item.insert)) {
            if (self.allocator.dupe(u8, view.insert)) |ni| {
                self.allocator.free(item.insert);
                item.insert = ni;
            } else |_| {}
        }
        if (view.documentation) |d| if (!std.mem.eql(u8, d, item.documentation)) {
            if (self.allocator.dupe(u8, d)) |nd| {
                if (item.documentation.len > 0) self.allocator.free(item.documentation);
                item.documentation = nd;
            } else |_| {}
        };
        if (view.detail) |d| if (!std.mem.eql(u8, d, item.detail)) {
            if (self.allocator.dupe(u8, d)) |nd| {
                self.allocator.free(item.detail);
                item.detail = nd;
                _ = rebuildRows(self); // rows 가 detail 조각을 빌린다 — 선택은 그대로 두고 행만 다시
            } else |_| {}
        };
        st.resolved_count += 1;
    };
    if (st.pending_accept) {
        st.pending_accept = false;
        st.accepted_after_resolve += 1;
        accept(self);
    } else {
        resolveHighlighted(self, term);
    }
}

/// 접두사로 다시 좁힌다. `force` 면 접두사가 같아도 다시(목록이 갈아 끼워졌다). 결과가 0 이면 false(호출자가 닫는다).
fn refilter(self: *AppSession, term: *Term, force: bool) bool {
    const st = &self.editor_completion;
    const doc = term.rt.editor_doc orelse return false;
    const sel = term.rt.editor_selection orelse return false;
    const caret = @min(sel.focus, doc.file.content.len);
    if (caret < st.word_start) return false;
    const prefix = doc.file.content[st.word_start..caret];
    if (!force and std.mem.eql(u8, prefix, st.last_prefix.items)) return st.order.items.len > 0;
    st.last_prefix.clearRetainingCapacity();
    st.last_prefix.appendSlice(self.allocator, prefix) catch return false;
    // 순수 필터를 쓰기 위해 빌린 항목 뷰를 만든다.
    var view = self.allocator.alloc(completion.Item, st.items.items.len) catch return false;
    defer self.allocator.free(view);
    for (st.items.items, 0..) |it, i| view[i] = .{ .label = it.label, .filter = it.filter, .sort = it.sort, .insert = it.insert, .preselect = it.preselect, .kind = it.kind };
    const list: completion.List = .{ .items = view, .incomplete = st.incomplete };
    const order = completion.filterSort(self.allocator, list, prefix) catch return false;
    defer self.allocator.free(order);
    st.order.clearRetainingCapacity();
    st.order.appendSlice(self.allocator, order) catch return false;
    if (!rebuildRows(self)) return false;
    if (st.order.items.len == 0) return false;
    self.chrome_host.suggest_box.reset(completion.preselectIndex(list, order), st.order.items.len);
    return true;
}

/// `order` 로 표시 행을 다시 세운다(선택은 건드리지 않는다 — resolve 가 detail 만 바꿀 때 쓴다).
fn rebuildRows(self: *AppSession) bool {
    const st = &self.editor_completion;
    st.rows.clearRetainingCapacity();
    for (st.order.items) |idx| {
        const it = st.items.items[idx];
        // 오른쪽 열은 description 이 있으면 그것, 없으면 detail(§8.2g-c) — resolve 가 detail 을 채우면 description 없는 항목의 오른쪽이 바뀐다.
        st.rows.append(self.allocator, .{ .label = it.label, .label_detail = it.label_detail, .detail = if (it.description.len > 0) it.description else it.detail, .kind = completion.kindGlyph(it.kind) }) catch return false;
    }
    return true;
}

/// **매 프레임 다시 묻는다**: 그 문서가 보이는가 · 오버레이·rename 이 없는가 · caret 이 낱말 안인가. 접두사가 바뀌었으면 다시 좁히고,
/// `isIncomplete` 면 다시 묻는다. 열려 있고 그릴 수 있으면 true(앵커까지 세운다).
pub fn refresh(self: *AppSession) bool {
    const st = &self.editor_completion;
    if (!st.active) return false;
    if (self.anyOverlayOpen() or self.rename != null) {
        hide(self);
        return false;
    }
    const term = visibleEditorTerm(self, st.surface_id) orelse {
        hide(self);
        return false;
    };
    const doc = term.rt.editor_doc orelse {
        hide(self);
        return false;
    };
    const sel = term.rt.editor_selection orelse {
        hide(self);
        return false;
    };
    const caret = @min(sel.focus, doc.file.content.len);
    if (caret < st.word_start or doc.file.lines.lineAt(caret) != doc.file.lines.lineAt(st.word_start)) {
        hide(self);
        return false;
    }
    // 접두사 안에 식별자가 아닌 글자가 들어오면(`(`·공백) 낱말이 끝난 것이다. 접두사가 비면 닫힌다 — 트리거 글자로 연 것만 빈 채로 산다.
    // 앞 검사는 **거의 등가**다 — `a(` 로 시작하는 filterText 가 없는 한 아래 refilter 가 0 으로 닫는다(적대적 2회차 B17). 서버가 그런 filterText
    // 를 낼 수 있으므로(스니펫 라벨) 방어로 남긴다.
    for (doc.file.content[st.word_start..caret]) |b| if (!isIdent(b)) {
        hide(self);
        return false;
    };
    if (caret == st.word_start and !st.opened_by_trigger) {
        hide(self);
        return false;
    }
    // 확정이 resolve 를 기다리는 중 — 300 ms 안에 안 오면 additional 없이 적용한다(§8.2g-b).
    if (st.pending_accept and self.awakeMs() -| st.pending_since_ms >= resolve_wait_ms) {
        st.pending_accept = false;
        st.resolve_waiting = false;
        st.accepted_on_timeout += 1;
        accept(self); // `resolved` 표시는 안 한다 — accept 는 그 플래그를 안 보고 hide 가 항목을 비운다(적대적 2회차 B18: 죽은 표시였다)
        return false;
    }
    const changed = !std.mem.eql(u8, doc.file.content[st.word_start..caret], st.last_prefix.items);
    if (changed and st.incomplete and !st.waiting) { // words_only 는 `incomplete = false` 로 서므로 따로 거르지 않는다(적대적 2회차 B25)
        st.refetched += 1;
        _ = ask(self, term, null); // 응답이 목록을 갈아 끼운다 — 그동안은 지금 목록을 접두사로 좁혀 보인다
    }
    if (!refilter(self, term, false)) {
        st.closed_empty += 1;
        hide(self);
        return false;
    }
    if (changed) resolveHighlighted(self, term);
    const a = editor_rename.anchorAt(term, st.word_start) orelse return false; // 이 프레임엔 행이 없다 — 다음 프레임
    if (!self.chrome_host.suggest_box.open) {
        const sel_idx = self.chrome_host.suggest_box.selected;
        const scroll = self.chrome_host.suggest_box.scroll;
        self.chrome_host.suggest_box.show(a.x, a.y, a.h);
        self.chrome_host.suggest_box.selected = sel_idx;
        self.chrome_host.suggest_box.scroll = scroll;
    } else self.chrome_host.suggest_box.moveAnchor(a.x, a.y, a.h);
    refreshDocs(self);
    return true;
}

/// 로딩 줄까지의 유예(ms) — VS Code 의 250 ms 와 같다(§8.2g-d).
pub const docs_loading_ms: u64 = 250;

/// 문서 패널의 줄을 강조 항목에 맞춘다(§8.2g-d) — 매 프레임 `refresh` 끝에서. 접혀 있으면 비운다. 강조가 바뀌면 다시 세우되,
/// 미해결 항목은 `docs_loading_ms` 가 지나야 `…` 한 줄을 세우고, 풀린 뒤에는 detail 줄 + 빈 줄 + 문서 줄로 갈아 끼운다.
fn refreshDocs(self: *AppSession) void {
    const st = &self.editor_completion;
    const docs = &self.chrome_host.suggest_docs;
    if (!docs.expanded or st.order.items.len == 0) {
        if (st.docs_item != null or st.docs_lines.items.len > 0) st.clearDocs(self.allocator);
        return;
    }
    const pick = @min(self.chrome_host.suggest_box.selected, st.order.items.len - 1);
    const idx = st.order.items[pick];
    if (st.docs_item != idx) {
        st.clearDocs(self.allocator);
        st.docs_item = idx;
        st.docs_since_ms = self.awakeMs();
        docs.scroll_rows = 0;
    }
    const item = st.items.items[idx];
    if (!item.resolved) {
        if (st.docs_lines.items.len == 0 and self.awakeMs() -| st.docs_since_ms >= docs_loading_ms) {
            pushDocLine(self, "…") catch return;
            st.docs_loading = true;
            self.metal_dirty = true;
        }
        return;
    }
    if (st.docs_ready) return;
    // 풀렸다 — 로딩 줄이든 빈 것이든 진짜 줄로.
    for (st.docs_lines.items) |l| self.allocator.free(l.text);
    st.docs_lines.clearRetainingCapacity();
    st.docs_loading = false;
    st.docs_ready = true;
    st.docs_built += 1;
    if (item.detail.len > 0) pushDocLine(self, item.detail) catch return;
    if (item.documentation.len > 0) {
        if (st.docs_lines.items.len > 0) pushDocLine(self, "") catch return;
        var reduced = hover_text.reduce(self.allocator, item.documentation) catch return;
        defer reduced.deinit(self.allocator);
        for (reduced.items.items) |l| pushDocLine(self, l.text) catch return;
    }
    self.metal_dirty = true;
}

fn pushDocLine(self: *AppSession, text: []const u8) error{OutOfMemory}!void {
    const st = &self.editor_completion;
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    try st.docs_lines.append(self.allocator, .{ .text = owned, .role = .surface_fg });
}

/// 문서 패널의 줄(`ChromeHost.collectSuggestBoxDraws` 가 받는다).
pub fn docsLines(self: *AppSession) []const suggest_docs.Line {
    return self.editor_completion.docs_lines.items;
}

/// 휠 — 문서 패널 안이면 행 단위로 굴리고 삼킨다(true). 밖이면 흘린다(목록은 닫지 않는다 — 휠은 읽는 동작이다).
pub fn wheel(self: *AppSession, x_px: f64, y_px: f64, delta_y: f64) bool {
    const st = &self.editor_completion;
    if (!st.active or !self.chrome_host.suggest_box.open or st.docs_lines.items.len == 0) return false;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const p = self.buildChromeProps();
    const beside = suggest_box.boxRect(&self.chrome_host.suggest_box, st.rows.items, p) orelse return false;
    if (!suggest_docs.contains(&self.chrome_host.suggest_docs, st.docs_lines.items, beside, p, x_px, y_px)) return false;
    const rows_delta: i32 = if (delta_y > 0) -1 else if (delta_y < 0) 1 else 0;
    if (rows_delta != 0 and self.chrome_host.suggest_docs.scrollBy(rows_delta, st.docs_lines.items.len)) self.metal_dirty = true;
    return true;
}

pub fn rows(self: *AppSession) []const suggest_box.Row {
    return self.editor_completion.rows.items;
}

/// 편집기 키 경로가 먼저 부른다(열려 있을 때만 뜻이 있다). 소비했으면 true. `←→`·Home/End 등 caret 을 옮기는 키는 닫되 소비하지 않는다.
pub fn handleKey(self: *AppSession, key: maru.terminal.input.Key, mods: maru.terminal.input.ModifierSet) bool {
    const st = &self.editor_completion;
    if (!st.active) return false;
    if (mods.command or mods.control or mods.option) {
        // `trigger_suggest` 로 풀리는 chord(`⌃Space`·`⌥Esc`)는 **닫지 않는다** — 목록이 열린 채 흘러가 `triggerManual` 이 문서 패널을
        // 토글한다(§8.2g-d). 다른 수정자 chord 는 그대로 닫는다(§8.2g ⑻b).
        const ev: maru.terminal.KeyEvent = .{ .key = key, .modifiers = mods };
        const res = self.loaded_config.keyBindingResolver().resolveEditor(ev, false);
        if (res == .app_action and res.app_action == .trigger_suggest) return false;
        hide(self);
        return false;
    }
    switch (key) {
        .arrow_up => {
            self.chrome_host.suggest_box.move(-1, st.order.items.len);
            if (visibleEditorTerm(self, st.surface_id)) |t| resolveHighlighted(self, t);
            self.metal_dirty = true;
            return true;
        },
        .arrow_down => {
            self.chrome_host.suggest_box.move(1, st.order.items.len);
            if (visibleEditorTerm(self, st.surface_id)) |t| resolveHighlighted(self, t);
            self.metal_dirty = true;
            return true;
        },
        .enter, .tab => {
            // **보이지 않는 목록은 확정하지 않는다** — 응답은 왔지만 아직 프레임이 상자를 세우지 않았으면(캡처 실측: 그 사이 들어온 키가 보이지도
            // 않은 첫 항목을 넣었다) 키를 편집기로 흘린다(Enter 는 줄바꿈이 된다). VS Code 도 위젯이 보일 때만 받는다.
            if (!self.chrome_host.suggest_box.open or st.order.items.len == 0) {
                hide(self);
                return false;
            }
            if (st.pending_accept) return true; // 이미 기다리는 중
            // 강조된 항목이 아직 안 풀렸으면 응답을 기다렸다 한 번에 적용한다(§8.2g-b — undo 하나).
            const pick = @min(self.chrome_host.suggest_box.selected, st.order.items.len - 1);
            const idx = st.order.items[pick];
            if (!st.items.items[idx].resolved) {
                if (!st.resolve_waiting or st.resolve_item != idx) {
                    st.resolve_waiting = false; // 다른 항목의 것을 기다리던 중 — 버리고(낡은 응답은 seq 로 걸러진다) 이 항목을 새로 묻는다
                    if (visibleEditorTerm(self, st.surface_id)) |t| resolveHighlighted(self, t);
                }
                // 여기서 기다리는 중이면 그것은 이 항목의 것이다(위가 보장 — 적대적 2회차 B21 의 `resolve_item == idx` 는 등가라 뺐다).
                if (st.resolve_waiting) {
                    st.pending_accept = true;
                    st.pending_since_ms = self.awakeMs();
                    return true;
                }
            }
            accept(self);
            return true;
        },
        .escape => {
            hide(self);
            return true;
        },
        .arrow_left, .arrow_right, .home, .end, .page_up, .page_down => {
            hide(self);
            return false;
        },
        else => return false,
    }
}

/// 마우스 down — 상자 안이면 그 행을 골라 확정(삼킨다), 밖이면 닫고 흘린다(그 클릭이 caret 을 옮긴다).
pub fn mouseDown(self: *AppSession, x_px: f64, y_px: f64) bool {
    const st = &self.editor_completion;
    if (!st.active or !self.chrome_host.suggest_box.open) return false;
    const p = self.buildChromeProps();
    const box = &self.chrome_host.suggest_box;
    if (suggest_box.boxRect(box, st.rows.items, p)) |rect| {
        if (std.math.isFinite(x_px) and std.math.isFinite(y_px)) {
            const x0: f64 = @floatFromInt(rect.x);
            const y0: f64 = @floatFromInt(rect.y);
            if (x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h))) {
                const ch: f64 = @floatFromInt(@max(p.metrics.cell_height_px, 1));
                const row: usize = @intFromFloat((y_px - y0) / ch);
                const start = @min(box.scroll, st.rows.items.len -| @min(st.rows.items.len, suggest_box.max_rows));
                box.selected = @min(start + row, st.order.items.len - 1);
                accept(self);
                return true;
            }
        }
        // 문서 패널 안 클릭은 삼킨다(닫지 않는다 — 읽는 동작).
        if (suggest_docs.contains(&self.chrome_host.suggest_docs, st.docs_lines.items, rect, p, x_px, y_px)) return true;
    }
    hide(self);
    return false;
}

/// 고른 항목을 §3.6 으로 적용한다 — 주 편집 `[start, caret)` → insert + additional(허용될 때) 이 `applyEditAsOne` 하나. caret 은 insert 끝.
pub fn accept(self: *AppSession) void {
    const st = &self.editor_completion;
    defer hide(self);
    const term = visibleEditorTerm(self, st.surface_id) orelse return;
    const doc = term.rt.editor_doc orelse return;
    const sel = term.rt.editor_selection orelse return;
    if (st.order.items.len == 0) return;
    const pick = @min(self.chrome_host.suggest_box.selected, st.order.items.len - 1);
    const item = st.items.items[st.order.items[pick]];
    const caret = @min(sel.focus, doc.file.content.len);
    var start = st.word_start;
    if (item.edit_start) |es| if (es <= caret) {
        start = es;
    };
    // 응답 뒤 문서가 바뀌었으면 additional 은 전부 낱말 앞에서 끝날 때만.
    var allow = term.rt.editor_lsp_version == st.response_version;
    if (!allow) {
        allow = true;
        for (item.additional.items) |c| if (c.end > start) {
            allow = false;
        };
    }
    if (!allow and item.additional.items.len > 0) st.dropped_additional += 1;
    var changes = completion.merge(self.allocator, if (allow) item.additional.items else &.{}, start, caret, item.insert) catch return;
    defer changes.deinit(self.allocator);
    // 다른 커서는 접는다 — 첫 조각은 primary 만(§8.2g).
    editor_ops.clearExtraSelections(self, term);
    if (!editor_ops.applyEditAsOne(self, term, changes.items)) return;
    // caret 을 insert 끝에 — delta 의 selection 매핑은 삭제 구간 안의 caret 을 시작으로 접는다.
    var shift: i64 = 0;
    for (changes.items) |c| {
        if (c.start < start) shift += @as(i64, @intCast(c.text.len)) - @as(i64, @intCast(c.end - c.start));
    }
    const end: usize = @intCast(@as(i64, @intCast(start)) + shift + @as(i64, @intCast(item.insert.len)));
    const clamped = @min(end, term.rt.editor_doc.?.file.content.len);
    term.rt.editor_selection = .{ .anchor_start = clamped, .anchor_end = clamped, .focus = clamped };
    st.accepted += 1;
    if (allow and item.additional.items.len > 0) st.accepted_with_additional += 1;
    self.metal_dirty = true;
}

pub const resolve_wait_ms: u64 = 300;

pub fn hide(self: *AppSession) void {
    const st = &self.editor_completion;
    if (!st.active and !self.chrome_host.suggest_box.open) return;
    st.active = false;
    st.pending_accept = false; // 등가(설치가 다시 지운다) — 방어(적대적 2회차 B22)
    st.resolve_waiting = false;
    st.words_only = false;
    st.clearItems(self.allocator);
    self.chrome_host.suggest_box.hide();
    self.metal_dirty = true;
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
