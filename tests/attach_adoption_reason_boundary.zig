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
    //    **닫는 괄호까지 잠그지 않는다.** 같은 호출에 배치 크기를 더하자 이 단언이 개선을 막았다
    //    (2026-09-12, 이 축에서 다섯 번째). 고정할 의도는 「그 자리가 «진짜 오류 값»을 넘긴다」이지
    //    인자 개수가 아니다 — 고정 문자열로 바꿔치면 아래 접두가 그대로 잡아낸다.
    //    인자 뒤 **구분자까지** 본다. `, err` 만 보면 `, error.Stale` 같은 고정 값도 접두가 같아
    //    통과한다(적대적 검증에서 생존했다). 인자 개수는 여전히 자유롭다.
    const site_call = "notePreparedAttachRejectedErr(\"screen_batch_enqueue\", err";
    const site_at = std.mem.indexOf(u8, src, site_call) orelse return error.EnqueueSiteCallMissing;
    const after_err = src[site_at + site_call.len ..];
    try std.testing.expect(after_err.len != 0 and (after_err[0] == ',' or after_err[0] == ')'));

    // ⑦ 조용한 옛 모습이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (adopted != .admitted) {\n            prepared.output.rollback(&self.connection);",
    ) == null);
}

test "prepared attach 는 전송이 깨진 게 아니면 연결 대신 스트림만 무효화한다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // **범위를 함수 본문으로 좁힌다.** 파일 어딘가에 `invalidateSubscriptionOutput` 이 있기만 하면
    // 통과하던 판정자는, 평상시 턴에 이미 그 호출이 있어서 항상 초록이다.
    const fn_at = std.mem.indexOf(u8, src, "fn adoptPreparedAttach(") orelse
        return error.PreparedAttachMissing;
    const fn_end = std.mem.indexOfPos(u8, src, fn_at, "\n    fn adoptFrameBatch(") orelse src.len;
    const body = src[fn_at..fn_end];

    // ① 거절을 **복구 가능한 상태로** 남긴다. 스트림을 무효화하면 클라이언트가 `snapshot.invalidated`
    //    를 받고 `runtime.resync` 로 되물어, 첫 화면이 연성 상한을 넘는 세션도 17 MiB 재동기화 차선을
    //    탈 수 있다. 이 호출이 없으면 그 세션은 누를 때마다 끊기기만 한다.
    const invalidate_at = std.mem.indexOf(u8, body, "invalidateSubscriptionOutput(") orelse
        return error.RecoveryPathMissing;

    // ② 복구하는 길에서는 attach 를 **되돌리지 않는다.** 되돌리면 구동부가 훑는 `localStreams` 에서
    //    빠져 재동기화를 돌릴 주체가 사라진다 — 연결만 살아 있고 화면은 영영 안 온다.
    //    (되돌리기는 트래커를 못 찾은 «진짜» 고장 갈래에만 남는다. 그 갈래는 무효화 앞에 있다.)
    //    **되돌리기 자체를 금지하지는 않는다.** 복구 통지조차 못 넣어 결국 닫히는 경우(슬롯이 청크로
    //    가득 참)에는 되돌려야 «매달린 attachment» 가 안 남는다. 금지할 것은 **조건 없는** 되돌리기다.
    if (std.mem.indexOfPos(u8, body, invalidate_at, "rollbackPreparedAttach(")) |after| {
        const between = body[invalidate_at..after];
        if (std.mem.indexOf(u8, between, "isClosing()") == null) {
            std.debug.print("복구 뒤 되돌리기가 무조건이다(+{d}) — 재동기화 주체가 사라진다\n", .{after});
            return error.RecoveryRollsBackAttach;
        }
    }

    // ③ 거절 배치의 **크기**를 남긴다. `ScreenInvalidated` 는 연성 상한 초과와 길이 0 청크 둘에서
    //    나오고 고칠 곳이 다르다. 숫자 없이는 또 추측한다 — 이 축에서 네 번 틀렸다.
    //    값이 아니라 **프레임에서 잰다는 것**을 고정한다(상수로 바꿔치면 잡힌다).
    const note_fn_at = std.mem.indexOf(u8, src, "fn notePreparedAttachRejectedErr(") orelse
        return error.ErrorAccessorMissing;
    const note_fn_end = std.mem.indexOfPos(u8, src, note_fn_at, "\n}\n") orelse src.len;
    try std.testing.expect(
        std.mem.indexOf(u8, src[note_fn_at..note_fn_end], "batch_bytes") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, src, "bytes={d}") != null);
    const enqueue_site = std.mem.indexOf(u8, src, "\"screen_batch_enqueue\"") orelse
        return error.EnqueueSiteMissing;
    const measure_from = if (enqueue_site > 400) enqueue_site - 400 else 0;
    try std.testing.expect(
        std.mem.indexOf(u8, src[measure_from..enqueue_site], "|bytes| batch_bytes") != null,
    );
}
