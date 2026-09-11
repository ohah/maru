//! **attach 가 왜 거절됐는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 실측 — 복구 세션 23 개 중 `terminal-browser-pane` **하나**가 끝내 붙지 않았고, 누를 때마다
//! GUI 연결이 통째로 끊겼다(`client poison` 57 회). host 가 남긴 것은 `why=resource_exhausted` 한 줄뿐이다.
//!
//! 그 한 줄로는 **네 자리 중 어디인지** 갈리지 않아, 수신 한도(`inbound_resident_cap`)를 의심해 상수 세
//! 개의 정합성을 파고 있었다 — `header_size + max_binary_chunk` 와 `turn_bytes` 가 32 B 어긋난 것까지
//! 찾아냈다. **전부 헛짚었다.** 그 자리에 진단을 넣고 재현하니 **한 줄도 안 찍혔고**, 반환 주소를
//! `atos` 로 풀어서야 `adoptPreparedAttach+228` 로 좁혀졌다.
//!
//! 그 자리는 `tryAdoptSubscriptionTurn` 의 결과가 `.admitted` 가 아니면 **연결을 끊는다.** 그런데 그
//! 열거형은 네 값이고 성격이 정반대다:
//!
//!   - `deferred_global_pressure` / `deferred_resync` — 「지금은 안 됨, 나중에」 (일시적)
//!   - `rejected` — 영구
//!
//! 어느 쪽인지 모르면 **고칠 방향조차 못 정한다** — 일시적이면 재시도가 답이고, 영구면 예산·검증을
//! 봐야 한다. 한 줄이면 갈린다.

const std = @import("std");

const source_path = "src/platform/macos/session_host/connection_turn.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

fn stripComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const keep = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        try out.appendSlice(allocator, keep);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "attach 거절은 어느 판정이었는지와 프레임 수를 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 네 값을 **이름으로** 낸다. 숫자나 bool 로 접으면 `deferred_*` 와 `rejected` 가 다시 뭉친다.
    try std.testing.expect(std.mem.indexOf(u8, src, "@tagName(adopted)") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "session host attach not admitted: adoption={s} frames={d}",
    ) != null);

    // ② **연결을 끊기 «전에»** 남긴다. 뒤에 두면 끊김 경로가 먼저 돌아 안 찍힐 수 있다.
    const note_at = std.mem.indexOf(u8, src, "noteAttachAdoption(adopted, frame_count);") orelse
        return error.AdoptionNoteMissing;
    const close_at = std.mem.indexOfPos(u8, src, note_at, "beginClose(.resource_exhausted)") orelse
        return error.CloseSiteMissing;
    try std.testing.expect(note_at < close_at);

    // ③ 프레임 수는 `takeFrames()` **전에** 읽는다 — 가져간 뒤에는 비어 있어 항상 0 이 찍힌다.
    const count_at = std.mem.indexOf(u8, src, "const frame_count = prepared.output.frames.len;") orelse
        return error.FrameCountMissing;
    const take_at = std.mem.indexOfPos(u8, src, count_at, "prepared.output.takeFrames()") orelse
        return error.TakeFramesMissing;
    try std.testing.expect(count_at < take_at);

    // ④ 조용한 옛 모습이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (adopted != .admitted) {\n            prepared.output.rollback(&self.connection);",
    ) == null);
}
