//! **수신 한도로 연결을 끊을 때 어느 자리에서 몇 바이트였는지** 남기는지 못 박는다.
//!
//! ## 무엇이 있었나
//!
//! 2026-09-11 실측 — 복구 세션 23 개 중 **22 개는 붙었고 1 개만** 이 경로로 GUI 연결을 끊었다
//! (`client poison: reason=connection_eof` → `transport_read_failure`, host 쪽 `why=resource_exhausted`).
//! 그 하나는 `terminal-browser-pane` — 화면을 프레임률로 꽉 채워 밀어내는 워크로드였다.
//!
//! 그런데 붙지 않는 이유를 확정할 수 없었다. `runtime.get` 응답이 성공한 21 개와 구별되지 않고
//! (필드 6 개, 272×72, 리스 없음), 닫힘 로그에는 `why=resource_exhausted` 한 줄뿐이라 **네 자리 중
//! 어디인지도, 몇 바이트였는지도** 남지 않았다. 넷은 고칠 곳이 전부 다르다 — 스트림 목록 할당 실패,
//! 턴 게이트, bounded push, 파서 OOM.
//!
//! `inbound_resident_cap` 은 `header_size + max_binary_chunk` 라 **최대 프레임 하나가 정확히 들어가는
//! 크기**고, 턴 게이트 검사는 `>=` 다. 최대 크기의 합법 프레임이 cap 과 같아져 걸리는지 아닌지가
//! 갈리지 않으면 고칠 수 없다. 실제 바이트 한 줄이면 즉시 갈린다.

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

test "수신 한도로 끊을 때 자리와 실제 바이트를 남긴다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 실제 바이트와 한도를 함께 남긴다. 자리 이름만으로는 「cap 과 같아서」인지 「훨씬 넘어서」인지
    //    갈리지 않는다 — 그 둘은 고칠 곳이 다르다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "session host inbound cap: site={s} buffered={d} cap={d}",
    ) != null);

    // ② 자리마다 **다른 이름**을 쓴다. 같은 이름으로 뭉치면 로그가 있어도 안 갈린다.
    for ([_][]const u8{ "\"turn_gate\"", "\"push_bounded\"" }) |site| {
        var seen: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, src, at, site)) |found| : (at = found + site.len) seen += 1;
        try std.testing.expectEqual(@as(usize, 1), seen);
    }

    // ③ 한도 검사 바로 옆에서 남긴다 — 멀어지면 다른 경로가 조용히 늘어난다.
    for ([_][]const u8{
        "noteResidentCap(\"turn_gate\", self.parser.bufferedBytes());",
        "noteResidentCap(\"push_bounded\", self.parser.bufferedBytes() + bytes.len);",
    }) |needle| try std.testing.expect(std.mem.indexOf(u8, src, needle) != null);

    // ④ 조용한 옛 모습이 되살아나면 빨개진다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "self.parser.pushBounded(bytes, inbound_resident_cap) catch\n                return self.beginClose(.resource_exhausted);",
    ) == null);
}
