//! **런타임 테스트로 못 닿는 두 방어**를 소스 수준으로 고정한다.
//!
//! `handoff_codec` 의 레이아웃 조각 계약은 대부분 라운드트립 테스트가 잡는다(적대적 검증 S1·S2·S4~S7
//! 사망). 그런데 둘은 못 닿는다:
//!
//!   - **디코더 상한**: 인코더가 과대 조각을 막으므로 정상 경로로는 그런 레코드를 못 만든다. 길이 필드만
//!     키우면 본문이 섹션을 넘어 **절단 오류가 먼저** 나 상한 검사에 닿지 않는다(S3 생존).
//!   - **태그 12 중복 가드**: 중복 TLV 를 끼우려면 바깥 섹션 길이까지 다시 써야 해 손으로 만들 수 없다(S8 생존).
//!
//! 둘 다 「우리가 아닌 쪽」(손상된 디스크 레코드, 구/신 host 의 어긋남)을 막는 방어라 지워지면 런타임당
//! 무제한 할당이나 조용한 덮어쓰기가 된다. 실행으로 못 잡으면 **존재라도 고정한다.**

const std = @import("std");

const source_path = "src/platform/macos/session_host/handoff_codec.zig";
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

test "레이아웃 조각: 디코더 상한과 중복 가드가 소스에 남아 있다" {
    const a = std.testing.allocator;
    const raw = try read(a, source_path);
    defer a.free(raw);
    const src = try stripComments(a, raw);
    defer a.free(src);

    // ① 디코더가 자기 상한을 본다 — 인코더 검사만 남으면 손상 레코드가 무제한 할당을 만든다.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "if (field.bytes.len > max_layout_blob_bytes) return error.LimitExceeded;",
    ) != null);

    // ② 태그 12 가 두 번 오면 거절한다 — 없으면 뒤엣것이 앞엣것을 조용히 덮는다.
    try std.testing.expect(std.mem.indexOf(u8, src, "if (layout_seen) return error.DuplicateField;") != null);

    // ③ 태그 12 는 **optional 로만** 쓴다. 필수로 두면 구 host 가 신 레코드를 거부해 롤백이 막힌다.
    try std.testing.expect(std.mem.indexOf(u8, src, "beginTlv(12, flag_optional)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "beginTlv(12, 0)") == null);

    // ④ 상한 상수가 하나뿐이다 — 인코더와 디코더가 서로 다른 숫자를 보면 한쪽만 고쳐도 안 빨개진다.
    var seen: usize = 0;
    var at: usize = 0;
    const decl = "const max_layout_blob_bytes: usize";
    while (std.mem.indexOfPos(u8, src, at, decl)) |found| : (at = found + decl.len) seen += 1;
    try std.testing.expectEqual(@as(usize, 1), seen);
}
