//! 화면 청크를 큐에 붙이는 **모든** 자리가 배치 끝 표식을 정한다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-20 실측 — host 로그의 `err=PartialFrame` 6 건을 쫓다가, 그 오류를 내는 조건을 유닛
//! 픽스처로 **만들 수가 없었다**. 화면 청크를 큐에 넣는 제품 경로가 전부 `screen_batch_end` 를
//! 달아서 `beginPressureInvalidation` 이 항상 배치 끝을 찾았기 때문이다.
//!
//! **그 「전부」를 함수 이름으로 셌던 것이 틀렸다.** `enqueue(.screen` · `enqueueOwned(.screen` 로
//! 세면 네 곳인데, 다섯째가 그 둘을 **안 거치고** 청크 배열에 직접 붙는다 —
//! `commitPreparedControlAndScreenBatch`(resize 발행) → `appendOwnedBatchChunk`. 거기가 표식을
//! 안 달아 기본값 `false` 로 남았고, 그게 `PartialFrame` 의 생산자였다.
//!
//! 표식이 없으면 압력 회수가 `PartialFrame` 으로 **연결을 통째로 닫는다** — 한 화면 때문에 그
//! 소켓의 화면 전부(최대 256)가 detach 된다.
//!
//! 순수 판정자는 「지금 있는 다섯」을 잰다. **여섯째가 표식 없이 새로 생기는 것**은 못 보므로
//! 여기서 센다. 그리고 함수 이름이 아니라 **청크를 붙이는 행위**를 센다 — 이름으로 세다 틀린 것이
//! 이 축이 생긴 이유다.

const std = @import("std");

const slot_path = "src/platform/macos/session_host/connection_slot.zig";
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

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

test "화면 청크를 붙이는 자리는 배치 끝 표식을 스스로 정한다" {
    const a = std.testing.allocator;
    const raw = try read(a, slot_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // 제품 구간만 본다 — 픽스처가 만드는 상태까지 세면 개수가 부풀어 이 축이 무력해진다.
    const product_end = std.mem.indexOf(u8, src, "\ntest \"") orelse src.len;
    const product = src[0..product_end];

    // ① **청크를 «붙이는» 자리를 행위로 센다.** 큐에 새 청크가 생기는 곳은 `chunk_len += 1` 뿐이다.
    //    함수 이름으로 세면 그 둘을 안 거치는 자리를 놓친다 — 실제로 놓쳤다.
    //    **하한을 실제 개수로 둔다.** 처음에 `< 3` 으로 적었는데 제품 자리는 **넷**이라(배치·
    //    `enqueue`·`enqueueOwned`·`appendOwnedBatchChunk`) 하나를 지워도 통과했다 — 이 축이 막으려는
    //    「경로가 조용히 사라지거나 합쳐지는」 변경이 그대로 새는 하한이었다. 같은 실수를 이 세션에서
    //    두 번 했다(구독 무효화 축의 `< 5`).
    const appends = countAll(product, "chunk_len += 1");
    if (appends < 4) {
        std.debug.print("청크를 붙이는 자리가 {d} 곳뿐이다 — 넷이던 자리다\n", .{appends});
        return error.TooFewAppendSites;
    }

    // ② **붙이는 «모든» 자리가 표식을 인자로 받는다.**
    //
    //    첫 판은 `appendOwnedBatchChunk` 하나만 봤다. 그래서 축 이름이 「모든 자리」라고 말하는데
    //    실제로는 하나만 지켰고, **그때 이미 표식을 안 다는 화면 경로가 하나 더 있었는데도 초록**
    //    이었다(`enqueueOwnedScreen` → `enqueueOwned`). 축이 거짓 안전감을 준 것이다.
    //
    //    그래서 감시 대신 **구조**로 막는다: 청크를 붙이는 함수 셋이 전부 표식을 인자로 받는다.
    //    이제 화면 청크를 붙이는 쪽은 값을 고르지 않을 수 없다.
    const appenders = [_][]const u8{
        "fn enqueue(",
        "fn enqueueOwned(",
        "fn appendOwnedBatchChunk(",
    };
    for (appenders) |name| {
        const fn_at = std.mem.indexOf(u8, product, name) orelse {
            std.debug.print("붙이는 함수 «{s}» 를 못 찾는다\n", .{name});
            return error.AppendHelperMissing;
        };
        const fn_end = std.mem.indexOfPos(u8, product, fn_at, "\n    }\n") orelse
            std.mem.indexOfPos(u8, product, fn_at, "\n}\n") orelse product.len;
        const body = product[fn_at..fn_end];
        if (std.mem.indexOf(u8, body, "screen_batch_end: bool") == null) {
            std.debug.print("«{s}» 가 표식을 인자로 안 받는다 — 기본값 false 로 샌다\n", .{name});
            return error.AppendHelperDefaultsBatchEnd;
        }
        if (std.mem.indexOf(u8, body, ".screen_batch_end = screen_batch_end") == null) {
            std.debug.print("«{s}» 가 받은 표식을 청크에 안 싣는다\n", .{name});
            return error.AppendHelperDropsBatchEnd;
        }
    }

    // ②-b **붙인 뒤 «되짚어» 다는 관례가 남지 않는다.** 그 한 줄을 잊는 것이 이 결함의 원인이었고,
    //      두 곳에서 실제로 잊었다(resize 발행 · `enqueueOwnedScreen`). 한 자리라도 남으면 다음
    //      호출자가 그 관례를 따라 하고 같은 결함이 돌아온다.
    if (countAll(product, "chunks[tail].screen_batch_end =") != 0) {
        std.debug.print("붙인 뒤 되짚어 표식을 다는 자리가 남았다 — 잊을 수 있는 구조로 돌아갔다\n", .{});
        return error.PostHocBatchEndRemains;
    }

    // ③ **화면으로 붙이는 호출은 «끝» 로 붙인다.** 이 경로가 나르는 것은 `encodeFrame` 이 만든
    //    완결 프레임 한 장이라 그 자리에서 배치가 끝난다(`enqueueScreen` 과 같은 모양).
    //    `.control` 은 배치 문법이 없어 값이 무의미하다 — 화면 쪽만 못 박는다.
    var at: usize = 0;
    var screen_calls: usize = 0;
    while (std.mem.indexOfPos(u8, product, at, "appendOwnedBatchChunk(")) |call| {
        at = call + "appendOwnedBatchChunk(".len;
        if (call >= 3 and std.mem.eql(u8, product[call - 3 .. call], "fn ")) continue;
        const line_end = std.mem.indexOfScalarPos(u8, product, call, '\n') orelse product.len;
        const line = product[call..line_end];
        if (std.mem.indexOf(u8, line, ".screen,") == null) continue;
        screen_calls += 1;
        if (std.mem.indexOf(u8, line, "true") == null) {
            std.debug.print("화면 청크를 끝 표식 없이 붙인다: {s}\n", .{std.mem.trim(u8, line, " \t")});
            return error.ScreenAppendWithoutBatchEnd;
        }
    }
    if (screen_calls == 0) return error.NoScreenAppendFound;

    // ④ **배치를 여럿 붙이는 자리는 «마지막만» 끝이다.** 전부 끝으로 달면 한 배치가 여러 배치로
    //    보여 압력 회수가 배치 중간에서 끊는다. 그 자리들은 인덱스 비교로 정하고 있어야 한다.
    try std.testing.expect(countAll(product, "index + 1 == chunks.len") >= 3);

    // ⑤ **단일 완결 프레임을 붙이는 짝 둘은 같은 값을 쓴다.** `enqueueScreen`(복사)과
    //    `enqueueOwnedScreen`(소유권 이전)은 「소유권을 옮기느냐」만 달라야 하는데, 2026-09-20 까지
    //    **큐 문법이 달랐다** — 앞은 끝으로 달고 뒤는 안 달았다.
    const owned_at = std.mem.indexOf(u8, product, "pub fn enqueueOwnedScreen(") orelse
        return error.OwnedScreenMissing;
    const owned_end = std.mem.indexOfPos(u8, product, owned_at, "\n    }\n") orelse product.len;
    const owned = product[owned_at..owned_end];
    if (std.mem.indexOf(u8, owned, "screen_soft_bytes, true") == null) {
        std.debug.print("enqueueOwnedScreen 이 단일 프레임을 끝으로 안 단다 — 복사 짝과 문법이 갈린다\n", .{});
        return error.OwnedScreenNotBatchEnd;
    }
}
