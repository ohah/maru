//! 접힘 3층 — `textDocument/foldingRange` 제품 배선(docs/editor-surface-tooling.md §8.2j · visual-mapping §4 「세 소스가 층으로 쌓인다」).
//! 프레임마다 `tick`(승격과 같은 자리 — `syntaxColors`)이 「물을 때인가」를 판정해 문서 전체를 묻고, 응답은 요청 때의 `editor_lsp_version`
//! 과 같을 때만 받아 `editor_fold.Range` 로 갈아 끼운다(`editor.installFoldRanges` — 승격과 같은 마무리, 접어 둔 것은 푼다).
//! 편집은 오늘 이미 접힘을 통째로 놓고 들여쓰기로 다시 세우므로(`refreshAfterEdit` → `dropFoldState`) 여기서는 조용 시계만 되감는다.
//!
//! 요청은 `11e8+seq`(§8.2a id 표). 서버가 없거나 provider 가 없으면 아무것도 안 한다 — 1·2층만(저하, 실패 아님).
const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_lsp = @import("editor_lsp.zig");
const editor = @import("editor.zig");
const lsp = maru.session.editor.lsp;
const fold_range = lsp.fold_range;

/// 마지막 편집 뒤 이만큼 조용해야 묻는다(§8.2j 「시점」 — semantic 2층과 같은 시계).
pub const quiet_ms: u64 = 120;
/// 오류·`null`·빈 응답이 이어지면 조용 시계를 두 배씩 늘린다(상한 `quiet_ms << max_error_shift` = 7,680 ms) — 로드 중에 `content modified`
/// 오류뿐 아니라 **`null` 과 `[]` 도 내는** 서버(rust-analyzer 실측 2026-09-21: didOpen 뒤 0.3 s 에 `null`, 앱에서는 `[]`)에 120 ms 마다
/// 되묻지 않되, 큰 작업 공간의 로드(수십 초)가 끝나면 결국 묻는다. 접을 것이 정말 없는 문서는 이 주기로 계속 묻는다 — 작은 요청 하나.
pub const max_error_shift: u6 = 6;

pub const State = struct {
    /// 든 범위가 말하는 문서 version(응답 때의 것). 문서 version 과 다르면 다음 `tick` 이 다시 묻는다.
    version: u64 = 0,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    /// 대기 중에 문서가 바뀌었거나 응답을 버렸다 — 조용해지면 한 번 더.
    dirty: bool = false,
    last_edit_ms: u64 = 0,
    /// 잇단 「아직 아니다」 응답 수(오류·`null`·빈 배열 — 조용 시계 배수). 범위가 하나라도 오면 0.
    error_streak: u6 = 0,
    /// 관측 카운터.
    sent: u64 = 0,
    applied: u64 = 0,
    applied_empty: u64 = 0,
    dropped_stale: u64 = 0,
    dropped_error: u64 = 0,
};

fn quietFor(st: *const State) u64 {
    return quiet_ms << @min(st.error_streak, max_error_shift);
}

/// 프레임마다(승격과 같은 자리) — 물을 때인지 판정해 보낸다.
pub fn tick(self: *AppSession, term: *Term) void {
    const st = &term.rt.editor_fold_lsp;
    if (st.waiting) return;
    if (term.rt.editor_doc == null) return;
    const version = term.rt.editor_lsp_version;
    if (version == 0) return; // 아직 서버에 안 열었다
    if (st.version == version and !st.dirty) return;
    const now = self.awakeMs();
    if (st.last_edit_ms != 0 and now -| st.last_edit_ms < quietFor(st)) return; // 0 = 아직 편집이 없었다
    const seq = editor_lsp.requestFoldingRange(self, term) orelse return; // 서버·provider 검사는 요청이 한다
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_version = version;
    st.dirty = false;
    st.sent += 1;
}

/// 응답(`editor_lsp` 가 부른다). 낡은 seq·낡은 version·오류는 버린다(오류·낡음은 `dirty` 로 다시 묻는다).
pub fn onResponse(self: *AppSession, term: *Term, seq: u32, result: ?std.json.Value, is_error: bool) void {
    const st = &term.rt.editor_fold_lsp;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error or result == null) {
        st.dropped_error += 1;
        retryLater(self, st);
        return;
    }
    if (st.waiting_version != term.rt.editor_lsp_version) {
        st.dropped_stale += 1;
        st.dirty = true;
        return;
    }
    const doc = term.rt.editor_doc orelse return;
    const lines = editor.foldSourceLines(term);
    // **범위는 화면에 그리는 줄과 같은 문서에서 나와야 한다**(승격과 같은 방어) — 갈린 상태면 버리고 다음 프레임이 다시 묻는다.
    if (lines.len == 0 or lines.len != doc.file.lineCount()) {
        st.dirty = true;
        return;
    }
    const ranges = fold_range.decode(self.allocator, result, lines.len) catch {
        st.dirty = true; // 못 셌다 ≠ 접을 것 없음(§4.1f) — 래치하지 않고 다음에 다시
        return;
    };
    if (ranges.len == 0) {
        // **빈 것은 「아직 아니다」로 읽는다**(§8.2j 「응답 검증」 — 실측: rust-analyzer 가 로드 중 `[]` 을 낸다). 아래 층을 그대로 두고
        // 조용 시계를 두 배씩 늘려 되묻는다. 접을 것이 정말 없는 문서도 같은 길을 가지만 상한 주기에 작은 요청 하나다.
        st.applied_empty += 1;
        retryLater(self, st);
        return;
    }
    if (!editor.installFoldRanges(self, term, ranges)) {
        self.allocator.free(ranges);
        st.dirty = true;
        return;
    }
    term.rt.editor_fold_source = .lsp;
    st.error_streak = 0;
    st.version = st.waiting_version;
    st.applied += 1;
    self.metal_dirty = true;
}

/// 「아직 아니다」 응답 뒤 — 곧바로 되묻지 않는다(조용 뒤, 이어지면 더 길게).
fn retryLater(self: *AppSession, st: *State) void {
    st.dirty = true;
    st.error_streak +|= 1;
    st.last_edit_ms = self.awakeMs();
}

/// 편집 통지 — 조용 시계만 되감는다(범위는 `dropFoldState` 가 이미 놓았고, version 이 올라 `tick` 이 다시 묻는다).
pub fn onEdit(self: *AppSession, term: *Term) void {
    term.rt.editor_fold_lsp.last_edit_ms = self.awakeMs();
}
