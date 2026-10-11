//! LSP 요청 규율(docs/editor-surface-tooling.md §8.2 — 물을 때인가 · 응답을 받을까 · 실패 뒤 언제 다시)의 **순수 판정**. 다섯
//! 클라이언트(L4 `app_session/editor` 의 `fold_lsp`·`highlight`·`inlay`·`semantic`·`symbols`)가 같은 규율을 손으로 다섯 번 적던
//! 것을 한 자리로 모은다 — 그 다섯 벌이 서로 어긋나 할당 실패 뒤 조용 시계 없이 곧바로 되묻는 결함이 넷에서 났다(결함 11).
//! 요청 보내기·응답 풀기·적용은 호출자가 하고, 시계는 인자(`now`, ms)로 받는다.
//!
//! **상태 모양은 클라이언트가 그대로 든다** — 판정자가 상태 필드를 직접 세우는 자리가 많아 모양을 안 바꾸는 쪽을 골랐다. 클라이언트는
//! 자기 필드를 가리키는 `Gate` 를 넘긴다(반사 없이 — 어느 필드를 만지는지가 그 한 줄에 다 보인다). 조용 시계는 편집 시계
//! (`last_edit_ms`)이거나 caret 시계(`last_move_ms` — 강조)이고, `dirty` 가 없는 상태(강조 — 낱말 키로 다시 묻는다)는 `null` 이다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");

/// 한 클라이언트의 요청 상태 — 그 필드들을 가리킨다.
pub const Gate = struct {
    waiting: *bool,
    waiting_seq: *u32,
    waiting_version: *u64,
    /// 다시 물을 표시. 없으면(강조) 다른 키가 다시 묻게 한다.
    dirty: ?*bool,
    /// 조용 시계 — 마지막 활동(편집·caret 이동·실패) 시각. 0 = 아직 활동이 없었다.
    clock: *u64,
    sent: *u64,
    dropped_error: *u64,
    dropped_stale: *u64,

    fn markDirty(g: Gate) void {
        if (g.dirty) |d| d.* = true;
    }
};

/// 응답 하나를 어떻게 읽을까.
pub const Verdict = enum {
    /// 기다리던 응답이 아니다(낡은 seq 이거나 이미 놓았다) — 아무것도 안 바꾼다.
    ignore,
    /// 오류·`null` — 버렸다. 호출자가 조용 뒤에 다시 묻게 한다(`retry` — 곧바로 되묻지 않는다).
    failed,
    /// 요청 뒤 문서가 바뀌었다 — 버리고 `dirty` 를 세웠다(새 version 으로 곧 다시 묻는다).
    stale,
    /// 받는다 — 호출자가 풀어 갈아 끼운다(풀다 실패하면 `retry`).
    take,
};

/// **조용 시계가 찼는가**(편집·caret 이 멈춘 뒤 `quiet_ms`). 0 = 아직 활동이 없었다 — 곧바로 묻는다.
pub fn quiet(g: Gate, now: u64, quiet_ms: u64) bool {
    const last = g.clock.*;
    return last == 0 or now -| last >= quiet_ms;
}

/// 요청을 보냈다 — 응답이 오기까지 새 요청을 막는다.
pub fn sent(g: Gate, seq: u32, version: u64) void {
    g.waiting.* = true;
    g.waiting_seq.* = seq;
    g.waiting_version.* = version;
    if (g.dirty) |d| d.* = false;
    g.sent.* += 1;
}

/// 응답이 왔다. **기다리던 seq 일 때만** 막음을 푼다 — 낡은 응답이 새 요청의 막음을 풀면 그 응답도 받게 된다.
pub fn receive(g: Gate, seq: u32, failed: bool, current_version: u64) Verdict {
    if (!g.waiting.* or seq != g.waiting_seq.*) return .ignore;
    g.waiting.* = false;
    if (failed) {
        g.dropped_error.* += 1;
        return .failed;
    }
    if (g.waiting_version.* != current_version) {
        g.dropped_stale.* += 1;
        g.markDirty();
        return .stale;
    }
    return .take;
}

/// **실패 뒤 다시 묻되 조용 뒤에** — 오류 응답과 할당 실패가 같은 규율이다. `dirty` 만 세우면 다음 프레임이 곧바로 같은 요청을
/// 다시 보내 메모리가 모자란 동안 매 프레임 되풀이한다(결함 11).
pub fn retry(g: Gate, now: u64) void {
    g.markDirty();
    g.clock.* = now;
}

/// 편집·caret 이동 — 조용 시계를 되감는다.
pub fn touch(g: Gate, now: u64) void {
    g.clock.* = now;
}

/// 서버가 내려갔다 — 응답은 오지 않으므로 막음을 풀고 다시 묻게 둔다. 안 풀면 그 문서는 **다시는 요청되지 않는다**.
pub fn release(g: Gate) void {
    if (!g.waiting.*) return;
    g.waiting.* = false;
    g.markDirty();
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeState = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_version: u64 = 0,
    dirty: bool = false,
    clock: u64 = 0,
    sent: u64 = 0,
    dropped_error: u64 = 0,
    dropped_stale: u64 = 0,

    fn gate(st: *FakeState, with_dirty: bool) Gate {
        return .{
            .waiting = &st.waiting,
            .waiting_seq = &st.waiting_seq,
            .waiting_version = &st.waiting_version,
            .dirty = if (with_dirty) &st.dirty else null,
            .clock = &st.clock,
            .sent = &st.sent,
            .dropped_error = &st.dropped_error,
            .dropped_stale = &st.dropped_stale,
        };
    }
};

test "조용 시계 — 0 이면 곧바로, 아니면 quiet 뒤에" {
    var st: FakeState = .{};
    const g = st.gate(true);
    try testing.expect(quiet(g, 5, 120));
    touch(g, 1000);
    try testing.expect(!quiet(g, 1119, 120));
    try testing.expect(quiet(g, 1120, 120));
}

test "보낸 뒤 응답 — 낡은 seq 는 막음을 안 풀고, 실패·낡음·받음을 가른다" {
    var st: FakeState = .{ .dirty = true };
    const g = st.gate(true);
    sent(g, 7, 3);
    try testing.expect(st.waiting and !st.dirty and st.sent == 1);
    try testing.expectEqual(Verdict.ignore, receive(g, 6, false, 3));
    try testing.expect(st.waiting);
    try testing.expectEqual(Verdict.take, receive(g, 7, false, 3));
    try testing.expect(!st.waiting);

    sent(g, 8, 3);
    try testing.expectEqual(Verdict.stale, receive(g, 8, false, 4));
    try testing.expect(st.dirty and st.dropped_stale == 1);

    sent(g, 9, 4);
    try testing.expectEqual(Verdict.failed, receive(g, 9, true, 4));
    try testing.expectEqual(@as(u64, 1), st.dropped_error);
}

test "결함 11 — 실패 뒤 다시는 조용 시계를 되감는다(곧바로 되묻지 않는다)" {
    var st: FakeState = .{};
    const g = st.gate(true);
    retry(g, 5000);
    try testing.expect(st.dirty);
    try testing.expect(!quiet(g, 5001, 120));
}

test "dirty 가 없는 상태(강조) — 같은 규율, dirty 는 건너뛴다" {
    var st: FakeState = .{};
    const g = st.gate(false);
    sent(g, 1, 1);
    try testing.expectEqual(Verdict.stale, receive(g, 1, false, 2));
    try testing.expect(!st.dirty);
    retry(g, 300);
    try testing.expect(!st.dirty and st.clock == 300);
    sent(g, 2, 2);
    release(g);
    try testing.expect(!st.waiting and !st.dirty);
}

test "서버가 내려가면 막음을 풀고 다시 묻게 둔다" {
    var st: FakeState = .{};
    const g = st.gate(true);
    release(g); // 기다리지 않으면 아무것도 안 바꾼다
    try testing.expect(!st.dirty);
    sent(g, 1, 1);
    release(g);
    try testing.expect(!st.waiting and st.dirty);
}
