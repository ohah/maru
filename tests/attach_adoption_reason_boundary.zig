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
    // 포맷을 통째로 잠그지 않는다 — 자리(`site`)를 더하자 이 단언이 개선을 막았다(2026-09-11, 같은 날
    // 두 번째). 고정할 의도는 「한 줄에 판정과 프레임 수가 함께 나온다」이지 문자열 전체가 아니다.
    try std.testing.expect(std.mem.indexOf(u8, src, "attach not admitted: adoption={s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "frames={d}") != null);

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

    // ④ **`rejected` 여덟 자리가 저마다 다른 이름으로 세어진다.**
    //
    //    2026-09-11 실측으로 `adoption=rejected frames=11` 까지는 나왔다 — 영구이고, 프레임이 11 개뿐이라
    //    예산이 아니라 검증이다. 그런데 그 여덟은 고칠 곳이 전부 다르다(배치 검증·슬롯·트래커·화면 상태·
    //    무효화 중 delta·resync OOM·resync stale·일반 enqueue). 이름이 없으면 또 추측하게 된다 —
    //    이 축에서 이미 세 번 틀렸다.
    for ([_][]const u8{
        "\"batch_validation\"",
        "\"slot_lookup\"",
        "\"tracker_missing\"",
        "\"screen_state\"",
        "\"delta_while_invalidated\"",
        "\"resync_enqueue_oom\"",
        "\"resync_stale\"",
        "\"screen_batch_enqueue\"",
    }) |site| {
        var seen: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, site)) |found| : (at = found + site.len) seen += 1;
        if (seen != 1) {
            std.debug.print("자리 «{s}» 가 {d} 번 — 정확히 1 번이어야 갈린다\n", .{ site, seen });
            return error.RejectSiteNotUnique;
        }
    }
    // ⑤ 로그가 자리를 **함께** 낸다. 판정만으로는 여덟이 뭉친다.
    //
    //    **조각으로 고정한다.** 포맷 문자열을 통째로 잠갔다가 오늘 세 번 개선을 막았다 — 자리(`site`)를
    //    더할 때, 오류 이름(`err`)을 더할 때. 고정할 의도는 「한 줄에 이것들이 함께 나온다」이지 문자열
    //    전체의 철자가 아니다.
    try std.testing.expect(std.mem.indexOf(u8, src, "attach not admitted:") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "site={s}") != null);

    // ⑥ **오류를 여럿 묶는 자리는 이름까지 낸다.** `screen_batch_enqueue` 는 `GlobalLimit` 을 뺀 다섯을
    //    한 이름으로 낸다(`ScreenInvalidated`·`SlotLimit`·`ChunkLimit`·`OutOfMemory`·`Stale`) — 고칠 곳이
    //    전부 다르다. 자리만으로는 거기서 또 막힌다.
    //    `@errorName` 이 파일 어딘가에 있기만 하면 통과하던 것을 **함수 안으로** 좁힌다 — 그 안에서
    //    고정 문자열로 바꿔치면 이름이 사라지는데 바깥만 보면 안 잡힌다(적대적 검증 X3 생존).
    const err_fn_at = std.mem.indexOf(u8, src, "fn notePreparedAttachRejectedErr(") orelse
        return error.ErrorAccessorMissing;
    const err_fn_end = std.mem.indexOfPos(u8, src, err_fn_at, "\n}\n") orelse src.len;
    try std.testing.expect(std.mem.indexOf(u8, src[err_fn_at..err_fn_end], "@errorName(err)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "err={s}") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "notePreparedAttachRejectedErr(\"screen_batch_enqueue\", err)",
    ) != null);

    // ⑦ 조용한 옛 모습이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (adopted != .admitted) {\n            prepared.output.rollback(&self.connection);",
    ) == null);
}
