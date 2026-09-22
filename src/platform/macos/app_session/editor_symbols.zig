//! 심볼 2층 — 제품 배선(docs/editor-surface-tooling.md §8.2o · native-editor-ui.md §7.5). 접힘 3층(`editor_fold_lsp`)과 같은 시계·같은 대조:
//! 문서 단위로 한 번 묻고, 응답은 요청 때의 `editor_lsp_version` 과 같을 때만 든다.
//!
//! **편집이 나면 버린다.** 2층 범위는 응답 시점의 것이라 편집 뒤엔 낡는데, 심볼 체인은 「지금 어디 있나」를 말하는 자리라 낡은 값이 곧
//! 거짓말이다(색과 갈리는 자리 — semantic 2층은 민다). 1층(tree-sitter)은 증분 파싱이라 즉시 옳으므로 **그 사이는 1층**이다.
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const syntax = @import("syntax");
const lsp = maru.session.editor.lsp;
const symbols = lsp.symbols;

/// 마지막 편집 뒤 이만큼 조용해야 묻는다(§8.2o — 접힘 3층과 같은 시계).
pub const quiet_ms: u64 = 120;

pub const State = struct {
    /// 응답을 푼 자리(순수 모듈의 꼴). 곧바로 `list` 로 옮기고 비운다.
    decoded: symbols.Symbols = .{},
    /// 든 목록 — **1층과 같은 타입**이라 소비자(밴드 체인·피커·형제 목록)가 분기하지 않는다. 비어 있으면 2층이 없다.
    list: std.ArrayList(syntax.Provider.Symbol) = .empty,
    /// 목록이 말하는 문서 version(응답 때의 것).
    version: u64 = 0,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    dirty: bool = false,
    last_edit_ms: u64 = 0,
    /// 관측 카운터.
    sent: u64 = 0,
    applied: u64 = 0,
    applied_empty: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_error: u64 = 0,
    cleared_by_edit: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.decoded.deinit(allocator);
        self.list.deinit(allocator);
        self.* = .{};
    }
};

/// 이 Term 의 2층이 **지금 문서에 유효한가**. 소비자(밴드 체인·피커·형제 목록)가 층을 고르는 유일한 물음이다.
/// (`version` 검사는 **이중 방어**다 — 적대적 B6: 편집이 목록을 비우고 낡은 응답은 `onResponse` 가 decode 전에 버리므로 「목록이 차 있는데
/// version 이 낡은」 상태가 오늘은 못 생긴다. 뜻으로 둔다 — 이 함수 하나만 읽고도 「지금 문서의 것인가」를 알 수 있어야 한다.)
pub fn fresh(term: *Term) bool {
    const st = &term.rt.editor_symbols;
    return st.list.items.len > 0 and st.version != 0 and st.version == term.rt.editor_lsp_version;
}

/// 지금 쓸 심볼 목록 — 2층이 유효하면 그것, 아니면 `null`(호출자가 1층을 만든다).
pub fn list(term: *Term) ?[]const syntax.Provider.Symbol {
    if (!fresh(term)) return null;
    return term.rt.editor_symbols.list.items;
}

/// 프레임마다(색 만들기와 같은 자리) — 물을 때인지 판정해 보낸다.
pub fn tick(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_symbols;
    if (st.waiting) return;
    if (term.rt.editor_doc == null) return;
    const version = term.rt.editor_lsp_version;
    if (version == 0) return; // 아직 서버에 안 열었다
    if (st.version == version and !st.dirty) return;
    const now = self.awakeMs();
    if (st.last_edit_ms != 0 and now -| st.last_edit_ms < quiet_ms) return;
    const seq = editor_lsp.requestDocumentSymbols(self, term) orelse return; // 서버·provider 검사는 요청이 한다
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_version = version;
    st.dirty = false;
    st.sent += 1;
}

/// 응답(`editor_lsp` 가 부른다). 낡은 seq·낡은 version·오류는 버린다.
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool, enc: lsp.rpc.PositionEncoding) void {
    const st = &term.rt.editor_symbols;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error or result == null) {
        st.dropped_error += 1;
        st.dirty = true;
        st.last_edit_ms = self.awakeMs(); // 곧바로 되묻지 않는다(조용 뒤)
        return;
    }
    if (st.waiting_version != term.rt.editor_lsp_version) {
        st.dropped_stale += 1;
        st.dirty = true;
        return;
    }
    const doc = term.rt.editor_doc orelse return;
    symbols.decode(self.allocator, result, doc.file.content, doc.file.lines, enc, &st.decoded) catch {
        st.dirty = true;
        return;
    };
    // **1층 타입으로 옮긴다** — 필드 뜻이 같아 그대로 베낀다(소비자가 층을 안 가른다). 응답 때 한 번이라 프레임 비용이 없다.
    st.list.clearRetainingCapacity();
    st.list.ensureTotalCapacity(self.allocator, st.decoded.items.items.len) catch {
        st.dirty = true;
        return;
    };
    for (st.decoded.items.items) |sym| st.list.appendAssumeCapacity(.{
        .name_start = sym.name_start,
        .name_end = sym.name_end,
        .start = sym.start,
        .end = sym.end,
        .start_row = sym.start_row,
        .depth = sym.depth,
        .kind = sym.kind,
    });
    st.decoded.clear();
    if (st.list.items.len == 0) {
        // 빈 목록·평탄 꼴 — **1층을 그대로 둔다**(§8.2o). 다시 묻지 않는다: 이 version 에 대한 답은 받았다.
        st.applied_empty += 1;
        st.version = st.waiting_version;
        return;
    }
    st.version = st.waiting_version;
    st.applied += 1;
    self.metal_dirty = true;
}

/// 편집 통지(§8.2o 「편집 중」) — **버린다**(밀지 않는다). 다음 조용에서 다시 묻는다.
pub fn onEdit(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_symbols;
    st.last_edit_ms = self.awakeMs();
    if (st.list.items.len > 0) {
        st.list.clearRetainingCapacity();
        st.cleared_by_edit += 1;
        self.metal_dirty = true;
    }
    st.version = 0; // 이중 방어(적대적 B2 — 위 비움만으로 `fresh` 는 이미 거짓이다; version 은 단조 증가라 되돌아오지 않는다)
    st.dirty = true;
}
