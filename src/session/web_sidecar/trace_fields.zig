//! 성능 trace 메시지(W9e② — wire 26: `trace` 141·`trace_state` 83·`trace_data` 84·`trace_frames` 85)의 닫힌 필드 규칙과 몸통 쓰기·읽기.
//! encode 와 decode 가 **같은 검사 함수**를 지나야 한쪽만 느슨해지지 않는다(`emu_fields.zig` 와 같은 규율). maru 와 sidecar 가 같은 파일을 쓴다.
//!
//! 시험이 증명하는 것(시험은 `codec.zig` 에): 세대 0·모르는 동작·`start` 밖의 길이·스크린샷·새로고침 표시, 길이 범위(1–30 초), 상태마다 쓸 수
//! 있는 까닭만(끝은 왜 멈췄나, 버림은 sidecar 가 버린 까닭, 실패는 실패 까닭), 시작 전 상태의 바이트·프레임 수가 0, 자름 표시는 끝에만, 조각의 크기(1..16 KiB)와 끝이
//! 16 MiB 를 넘지 않음, 프레임 id 의 수(1..64)·글자(16 진 1..64 자)·남은 칸이 비었음. 브라우저 탭에서 중요한 이유 — sidecar 는 신뢰할 수 없는
//! 웹을 띄우는 프로세스라 maru 는 이 바이트를 공격 입력으로 본다: 프레임 id 는 maru 의 거르기(F3)가 집합으로 쥐고, gzip 조각은 maru 가 모아
//! 풀어 본다.

const std = @import("std");
const wire = @import("wire.zig");
const message = @import("message.zig");
const fields = @import("fields.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;

fn readEnum(comptime E: type, cursor: *ReadCursor) Error!E {
    return std.enums.fromInt(E, try cursor.readByte()) orelse error.InvalidTrace;
}

// ── trace ────────────────────────────────────────────────────────────────────────────────────────────────

pub fn checkTrace(v: message.Trace) Error!void {
    if (v.generation == 0) return error.InvalidTrace;
    switch (v.action) {
        .start => if (v.duration_ms < message.min_trace_duration_ms or v.duration_ms > message.max_trace_duration_ms) return error.InvalidTrace,
        .stop, .abort => if (v.duration_ms != 0 or v.screenshots or v.reload) return error.InvalidTrace,
    }
}

pub fn writeTrace(cursor: *Cursor, v: message.Trace) Error!void {
    try checkTrace(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@backingInt(v.action));
    try cursor.writeU32(v.duration_ms);
    try cursor.writeByte(@intFromBool(v.screenshots));
    try cursor.writeByte(@intFromBool(v.reload));
}

pub fn readTrace(cursor: *ReadCursor) Error!message.Trace {
    const v: message.Trace = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .action = try readEnum(message.TraceAction, cursor),
        .duration_ms = try cursor.readU32(),
        .screenshots = try fields.readBool(cursor),
        .reload = try fields.readBool(cursor),
    };
    try checkTrace(v);
    return v;
}

// ── trace_state ──────────────────────────────────────────────────────────────────────────────────────────

/// 그 상태에 그 까닭을 쓸 수 있는가. 시작 중·기록 중·받는 중은 까닭이 없고, 끝은 왜 멈췄나(요청·시간·버퍼), 버림은 sidecar 가 버린 까닭,
/// 실패는 실패 까닭이다 — 받는 쪽이 「끝인데 까닭이 실패」 를 어떻게 읽을지 고르지 않게.
pub fn reasonFits(state: message.TraceStateKind, reason: message.TraceReason) bool {
    return switch (state) {
        .starting, .recording, .receiving => reason == .none,
        .done => reason == .requested or reason == .duration or reason == .buffer_full,
        .discarded => reason == .human_input or reason == .frames_overflow or reason == .aborted,
        .failed => switch (reason) {
            .busy, .tab_closed, .cdp_error, .read_timeout, .too_large, .start_timeout, .not_found => true,
            else => false,
        },
    };
}

pub fn checkState(v: message.TraceState) Error!void {
    if (v.generation == 0) return error.InvalidTrace;
    if (!reasonFits(v.state, v.reason)) return error.InvalidTrace;
    if (v.gz_bytes > message.max_trace_gz_bytes or v.frames > message.max_trace_frames_total) return error.InvalidTrace;
    // 덮은 시간은 길이(≤ 30 s)에 멈춤의 늦음을 더한 것 — 두 배를 넘으면 망가진 값이다(maru 의 셈이 넘치지 않게 — 구현 적대 리뷰 2 회차 L-b).
    if (v.covered_ms > 2 * message.max_trace_duration_ms) return error.InvalidTrace;
    // 시작 전에는 보낸 것이 없다.
    if ((v.state == .starting or v.state == .recording) and (v.gz_bytes != 0 or v.frames != 0 or v.data_loss)) return error.InvalidTrace;
    // 자름은 끝(`done`)에만 있다 — 버림·실패에 실리면 받는 쪽이 「잘렸지만 남았다」 로 읽을 수 있다.
    if (v.truncated and v.state != .done) return error.InvalidTrace;
    // 프로세스 나눔(결정 12)도 끝에만 — 거르기가 끝난 trace 에만 쓴다.
    if (v.shared_process and v.state != .done) return error.InvalidTrace;
}

pub fn writeState(cursor: *Cursor, v: message.TraceState) Error!void {
    try checkState(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(@backingInt(v.state));
    try cursor.writeByte(@backingInt(v.reason));
    try cursor.writeByte(@as(u8, @intFromBool(v.focus_emulated)) | (@as(u8, @intFromBool(v.data_loss)) << 1) | (@as(u8, @intFromBool(v.truncated)) << 2) | (@as(u8, @intFromBool(v.shared_process)) << 3));
    try cursor.writeU32(v.covered_ms);
    try cursor.writeU32(v.gz_bytes);
    try cursor.writeU32(v.frames);
}

pub fn readState(cursor: *ReadCursor) Error!message.TraceState {
    var v: message.TraceState = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .state = try readEnum(message.TraceStateKind, cursor),
        .reason = try readEnum(message.TraceReason, cursor),
    };
    const bits = try cursor.readByte();
    if (bits & ~@as(u8, 0b1111) != 0) return error.InvalidTrace;
    v.focus_emulated = bits & 1 != 0;
    v.data_loss = bits & 2 != 0;
    v.truncated = bits & 4 != 0;
    v.shared_process = bits & 8 != 0;
    v.covered_ms = try cursor.readU32();
    v.gz_bytes = try cursor.readU32();
    v.frames = try cursor.readU32();
    try checkState(v);
    return v;
}

// ── trace_data ───────────────────────────────────────────────────────────────────────────────────────────

pub fn checkData(v: message.TraceData) Error!void {
    if (v.generation == 0 or v.bytes.len == 0 or v.bytes.len > message.trace_chunk_bytes) return error.InvalidTrace;
    if (@as(u64, v.offset) + v.bytes.len > message.max_trace_gz_bytes) return error.InvalidTrace;
}

pub fn writeData(cursor: *Cursor, v: message.TraceData) Error!void {
    try checkData(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeU32(v.offset);
    try cursor.writeU16(@intCast(v.bytes.len));
    try cursor.writeBytes(v.bytes);
}

pub fn readData(cursor: *ReadCursor) Error!message.TraceData {
    var v: message.TraceData = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .offset = try cursor.readU32(),
        .bytes = "",
    };
    const len = try cursor.readU16();
    if (len > message.trace_chunk_bytes) return error.InvalidTrace;
    v.bytes = try cursor.readBytes(len);
    try checkData(v);
    return v;
}

// ── trace_frames ─────────────────────────────────────────────────────────────────────────────────────────

/// DevTools 프레임 id 의 모양 — 16 진 글자 1..64 개(Chromium 은 32 자 대문자 16 진을 낸다).
pub fn frameIdOk(id: []const u8) bool {
    if (id.len == 0 or id.len > message.max_trace_frame_id_bytes) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn checkFrames(v: message.TraceFrames) Error!void {
    if (v.generation == 0 or v.count == 0 or v.count > message.max_trace_frame_ids) return error.InvalidTrace;
    for (v.ids[0..v.count]) |id| if (!frameIdOk(id)) return error.InvalidTrace;
    for (v.ids[v.count..]) |id| if (id.len != 0) return error.InvalidTrace;
}

pub fn writeFrames(cursor: *Cursor, v: message.TraceFrames) Error!void {
    try checkFrames(v);
    try fields.writeBrowser(cursor, v.browser);
    try cursor.writeU32(v.generation);
    try cursor.writeByte(v.count);
    for (v.ids[0..v.count]) |id| {
        try cursor.writeByte(@intCast(id.len));
        try cursor.writeBytes(id);
    }
}

pub fn readFrames(cursor: *ReadCursor) Error!message.TraceFrames {
    var v: message.TraceFrames = .{
        .browser = try fields.readBrowser(cursor),
        .generation = try cursor.readU32(),
        .count = try cursor.readByte(),
    };
    if (v.count > message.max_trace_frame_ids) return error.InvalidTrace;
    for (v.ids[0..v.count]) |*id| id.* = try cursor.readBytes(try cursor.readByte());
    try checkFrames(v);
    return v;
}

/// 가장 큰 trace 몸통(머리 빼고) — codec 의 comptime 이 frame 상한 안인지 본다.
pub const max_frames_body_bytes: usize = 8 + 4 + 1 + message.max_trace_frame_ids * (1 + message.max_trace_frame_id_bytes);
pub const max_data_body_bytes: usize = 8 + 4 + 4 + 2 + message.trace_chunk_bytes;
