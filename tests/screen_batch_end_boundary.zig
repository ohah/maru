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
    const appends = countAll(product, "chunk_len += 1");
    if (appends < 3) {
        std.debug.print("청크를 붙이는 자리가 {d} 곳뿐이다 — 셋이던 자리다\n", .{appends});
        return error.TooFewAppendSites;
    }

    // ② **직접 붙이는 자리는 표식을 명시한다.** `appendOwnedBatchChunk` 가 기본값에 기대면
    //    화면 청크가 끝 없이 남는다. 인자로 받아야 호출자가 **고르지 않을 수 없다**.
    const fn_at = std.mem.indexOf(u8, product, "fn appendOwnedBatchChunk(") orelse
        return error.AppendHelperMissing;
    const fn_end = std.mem.indexOfPos(u8, product, fn_at, "\n}\n") orelse product.len;
    const body = product[fn_at..fn_end];
    if (std.mem.indexOf(u8, body, "screen_batch_end: bool") == null) {
        std.debug.print("appendOwnedBatchChunk 가 표식을 인자로 안 받는다 — 기본값 false 로 샌다\n", .{});
        return error.AppendHelperDefaultsBatchEnd;
    }
    try std.testing.expect(std.mem.indexOf(u8, body, ".screen_batch_end = screen_batch_end") != null);

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
}
