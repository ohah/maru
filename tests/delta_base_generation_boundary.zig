//! 제품 delta producer(`RuntimeManager.deltaOp`)가 **다른 세대의 base 를 delta 로 잇지 않는지** 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-28 — 런타임 16 개를 든 session host 가 GUI 연결을 통째로 닫았다(`site=delta_seq_mismatch`).
//! `computeDelta` 는 격자 크기·alt 화면만 비교하고 base 의 세대는 안 본다. registry 는 resize 마다 세대를
//! 1 올린다. 그래서 같은 스트림의 두 collect 사이에 resize 가 격자를 제자리로 돌려놓으면(A→B→A) 세대만
//! +2 인 delta 가 나가고, 서버는 스냅샷이 아닌 delta 의 세대 변화를 거절하며 **연결 전체**를 닫았다.
//!
//! 순수 판정자(`screen_snapshot.zig` 의 「delta base 세대」)는 `baseFrame` 과 그 위험의 존재를, 제품 경로
//! 회귀 판정자(`runtime_manager.zig`, 실제 PTY)는 결과를 잰다. 그런데 뒤쪽은 session-host 잡이라 **PR 에서
//! 안 돈다.** 그래서 `deltaOp` 의 배선을 여기서 글자로 잰다 — 「있다」가 아니라 「그 조건에서 그 길로 간다」를.

const std = @import("std");

const manager_path = "src/platform/macos/session_host/runtime_manager.zig";

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024 * 1024));
}

/// 주석을 지우고 공백 연속을 한 칸으로 줄인다 — 줄바꿈·들여쓰기는 의도가 아니므로 잠그지 않는다.
fn normalize(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var in_ws = false;
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |at| line[0..at] else line;
        for (code) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                in_ws = true;
                continue;
            }
            if (in_ws and out.items.len != 0) try out.append(allocator, ' ');
            in_ws = false;
            try out.append(allocator, ch);
        }
        in_ws = true;
    }
    return out.toOwnedSlice(allocator);
}

fn countAll(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |f| : (at = f + needle.len) n += 1;
    return n;
}

fn expectOnce(haystack: []const u8, needle: []const u8, what: []const u8) !usize {
    const n = countAll(haystack, needle);
    if (n != 1) {
        std.debug.print("{s}: «{s}» 가 {d} 번 — 정확히 한 번이어야 한다\n", .{ what, needle, n });
        return error.WiringChanged;
    }
    return std.mem.indexOf(u8, haystack, needle).?;
}

test "deltaOp 는 base 세대가 다르면 delta 대신 스냅샷을 내고, 격자가 같을 때만 그 순간을 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, manager_path);
    defer a.free(raw);
    const src = try normalize(a, raw);
    defer a.free(src);

    // 이 파일은 테스트가 제품 코드 사이에 섞여 있다 — 「첫 `test "` 앞」 같은 구간 가정은 틀린다.
    // 함수 구간(`fn deltaOp(` · `fn noteStaleBaseGeneration(`)으로 찾고, 호출 수는 파일 전체에서 센다.
    const product = src;
    const fn_at = std.mem.indexOf(u8, product, "fn deltaOp(") orelse return error.DeltaOpMissing;
    const fn_end = std.mem.indexOfPos(u8, product, fn_at, " fn ") orelse product.len;
    const body = product[fn_at..fn_end];

    // ① **판정이 있고, 세대를 opts 와 같은 값으로 비교한다.** 다른 변수(예: 요청 sequence)와 비교하거나
    //    비교를 뒤집으면 스냅샷이 엉뚱한 때 나가거나 영영 안 나간다.
    const opts_at = try expectOnce(body, "var opts = screen_snapshot.ProjectOptions{ .generation = generation, .sequence = sequence };", "opts");
    const judge_at = try expectOnce(body, "const base_generation_stale = if (screen_snapshot.baseFrame(base)) |frame| stale: { if (frame.generation == generation) break :stale false;", "세대 판정");
    _ = try expectOnce(body, "break :stale true; } else false;", "낡음 확정");
    try std.testing.expect(opts_at < judge_at);

    // ② **낡았으면 delta 를 계산하지 않고 스냅샷 갈래로 간다.** 판정만 하고 결과를 안 쓰면 초록인 채로
    //    예전 사고가 그대로 난다 — 그래서 판정 → 분기 → 같은 catch 갈래까지 한 줄로 잰다.
    const route_at = try expectOnce(
        body,
        "= if (base_generation_stale) error.SnapshotRequired else screen_snapshot.computeDeltaBounded( allocator, base, &surface.core, opts, protocol.max_viewport_snapshot, ); const result = delta_or_snapshot catch |e| switch (e) { error.SnapshotRequired => {",
        "스냅샷 분기",
    );
    try std.testing.expect(judge_at < route_at);
    // 판정은 core 락 **안에서** 한다 — 크기를 읽고 그 크기로 스냅샷을 만드는 사이에 격자가 바뀌지 않게.
    const lock_at = try expectOnce(body, "surface.lockCore(self.io); defer surface.unlockCore(self.io);", "core 락");
    try std.testing.expect(lock_at < judge_at);
    // delta 계산은 그 분기 안에서만 한다(분기를 우회하는 두 번째 호출이 없다).
    try std.testing.expectEqual(@as(usize, 1), countAll(body, "computeDeltaBounded("));
    // 스냅샷 갈래는 **지금 세대**로 찍힌다 — base 세대로 찍으면 서버가 다음 delta 를 또 거절한다.
    const snap_arm = body[route_at..];
    _ = try expectOnce(snap_arm, ".is_snapshot = true, .new_base = snap, .frontier = .{ .generation = generation, .sequence = sequence },", "스냅샷 frontier");

    // ③ **로그는 격자까지 같을 때만.** 크기가 다르면 원래 스냅샷이라 창 드래그마다 소음이 된다. 조건과
    //    호출을 한 덩어리로 잰다 — 조건을 빼면 소음, 뒤집으면 정작 그 순간을 못 남긴다.
    _ = try expectOnce(
        body,
        "if (frame.cols == size.cols and frame.rows == size.rows) noteStaleBaseGeneration(runtime_id, frame, generation);",
        "로그 조건",
    );
    try std.testing.expectEqual(@as(usize, 1), countAll(product, "noteStaleBaseGeneration(runtime_id,"));

    // ④ **로그가 base -> 지금 방향으로 그 값을 싣는다.** 인자 순서가 뒤집혀도 컴파일된다.
    const note_at = std.mem.indexOf(u8, product, "fn noteStaleBaseGeneration(") orelse return error.NoteMissing;
    const note_end = std.mem.indexOfPos(u8, product, note_at, " fn ") orelse product.len;
    const note = product[note_at..note_end];
    _ = try expectOnce(note, "gen={d}->{d} grid={d}x{d}", "로그 형식");
    _ = try expectOnce(note, ".{ runtime_id, frame.generation, generation, frame.cols, frame.rows }", "로그 인자");
    _ = try expectOnce(note, "host_log.line(", "로그 호출");

    // ⑤ 제품 경로 회귀 판정자가 **있다**(main 에서 돈다). 결과를 실제 PTY 로 재는 것은 그쪽이다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        raw,
        "test \"delta base 세대: 격자가 제자리로 돌아온 두 번의 resize 뒤 deltaOp 는 스냅샷을 낸다\"",
    ) != null);
}
