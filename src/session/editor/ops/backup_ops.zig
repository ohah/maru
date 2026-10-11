//! 미저장 편집 백업([문서 모델](../../../../docs/native-editor-document-model.md) §3.10)의 **순수 판정** — 레코드를
//! 되살려도 되는가. 디렉터리 찾기(환경 변수)·파일 읽기·쓰기와 적용은 호출자(L4 `app_session/editor/backup.zig`·
//! `recovery_store.zig`)가 한다. 레코드의 모양·이름·주기 정책은 옆 `../backup.zig` 가 소유한다.
//!
//! 이 폴더는 OS 를 부르지 않는다(`tests/boundary/editor_ops_sans_io.zig`).
const std = @import("std");
const backup = @import("../backup.zig");

/// 레코드가 말하는 신원 `got` 이 찾던 신원 `want` 와 같은가. **이름만 믿지 않는다** — 경로 레코드의 이름은 해시라
/// 충돌할 수 있고, 손으로 옮긴 파일은 이름과 신원이 다를 수 있다. 남의 내용을 되살리면 「조용히 다른 문서로 연다」가
/// 된다. 경로의 지문(`disk_hash`)은 대조하지 않는다 — 그것은 「그 사이 남이 고쳤나」를 묻는 축이다(§4 의 CAS).
pub fn identityMatches(want: backup.Doc, got: backup.Doc) bool {
    return switch (want) {
        .path => |w| switch (got) {
            .path => |p| std.mem.eql(u8, p.path, w.path),
            else => false,
        },
        .untitled => |n| switch (got) {
            .untitled => |m| m == n,
            else => false,
        },
        .remote => |w| switch (got) {
            .remote => |r| std.mem.eql(u8, r.dest, w.dest) and std.mem.eql(u8, r.path, w.path),
            else => false,
        },
    };
}

/// **되살릴 수 있는 내용인가.** 레코드는 앱 전용 자리에 있지만 파일이라 적대적 입력으로 본다(§3.8). 여는 경로는 UTF-8 을
/// 검증하지만 편집 경로는 검증하지 않으므로(IME·붙여넣기가 UTF-8 이다) 여기서 막는다. 저장 상한(`pause_bytes`)을 넘는
/// 내용은 `⌘S` 가 `TooLarge` 라, 되살리면 「지울 수도 저장할 수도 없는 dirty」가 된다(레코드 상한은 그보다 조금 크다).
pub fn admissible(content: []const u8) bool {
    return content.len <= backup.pause_bytes and std.unicode.utf8ValidateSlice(content);
}

pub const Restore = enum {
    /// 남의 레코드다 — 손대지 않는다.
    foreign,
    /// 되살릴 수 없는 내용이다 — 손상 레코드와 같은 대우(무시하고 파일 그대로).
    inadmissible,
    /// 내용이 이미 같다 — 되살릴 것이 없다(레코드만 걷는다. 이름 없는 문서는 저장 이력이 없어 dirty 로 남긴다).
    same,
    /// 한 편집으로 되살린다.
    apply,
};

/// 레코드 하나를 열린 문서(`current`)에 되살릴지(U4b·U4c). **순서가 계약이다**: 신원 → 내용 → 같은가 — 남의 레코드는
/// 내용을 보기 전에 버린다.
pub fn judgeRestore(want: backup.Doc, parsed: backup.Parsed, current: []const u8) Restore {
    if (!identityMatches(want, parsed.doc)) return .foreign;
    if (!admissible(parsed.content)) return .inadmissible;
    if (std.mem.eql(u8, parsed.content, current)) return .same;
    return .apply;
}

/// `u-<16진수>.bak` 의 번호. 그 모양이 아니거나 0 이면 null — 임시 파일·경로 레코드는 건너뛴다.
pub fn recordedUntitledNumber(name: []const u8) ?u32 {
    const prefix = "u-";
    const suffix = ".bak";
    if (name.len <= prefix.len + suffix.len) return null;
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    const n = std.fmt.parseInt(u32, name[prefix.len .. name.len - suffix.len], 16) catch return null;
    return if (n == 0) null else n;
}

// ── 판정자 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "identityMatches — 갈래와 값이 모두 같아야 하고, 경로의 지문은 대조하지 않는다" {
    try testing.expect(identityMatches(.{ .path = .{ .path = "/a" } }, .{ .path = .{ .path = "/a", .disk_hash = 7 } }));
    try testing.expect(!identityMatches(.{ .path = .{ .path = "/a" } }, .{ .path = .{ .path = "/b" } }));
    try testing.expect(!identityMatches(.{ .path = .{ .path = "/a" } }, .{ .untitled = 1 }));
    try testing.expect(identityMatches(.{ .untitled = 3 }, .{ .untitled = 3 }));
    try testing.expect(!identityMatches(.{ .untitled = 3 }, .{ .untitled = 4 }));
    try testing.expect(identityMatches(.{ .remote = .{ .dest = "h", .path = "/p" } }, .{ .remote = .{ .dest = "h", .path = "/p" } }));
    try testing.expect(!identityMatches(.{ .remote = .{ .dest = "h", .path = "/p" } }, .{ .remote = .{ .dest = "g", .path = "/p" } }));
}

test "judgeRestore — 신원 → 내용 → 같은가 순서로 가른다 (§3.10)" {
    const want: backup.Doc = .{ .path = .{ .path = "/a" } };
    try testing.expectEqual(Restore.foreign, judgeRestore(want, .{ .doc = .{ .path = .{ .path = "/b" } }, .content = "\xff" }, "x"));
    try testing.expectEqual(Restore.inadmissible, judgeRestore(want, .{ .doc = want, .content = "\xff" }, "x"));
    try testing.expectEqual(Restore.same, judgeRestore(want, .{ .doc = want, .content = "x" }, "x"));
    try testing.expectEqual(Restore.apply, judgeRestore(want, .{ .doc = want, .content = "y" }, "x"));
}

test "admissible — 저장 상한까지는 받고 넘으면 거절한다" {
    const big = try testing.allocator.alloc(u8, backup.pause_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect(admissible(big[0..backup.pause_bytes]));
    try testing.expect(!admissible(big));
    try testing.expect(!admissible("a\xc3"));
}

test "recordedUntitledNumber — 레코드 이름의 모양만 읽는다" {
    try testing.expectEqual(@as(?u32, 0x1f), recordedUntitledNumber("u-1f.bak"));
    var buf: [backup.max_file_name_len]u8 = undefined;
    try testing.expectEqual(@as(?u32, 0xabc), recordedUntitledNumber(backup.fileName(&buf, .{ .untitled = 0xabc })));
    for ([_][]const u8{ "u-0.bak", "u-.bak", "u-1.bak.tmp", "p-0123456789abcdef.bak" }) |name|
        try testing.expectEqual(@as(?u32, null), recordedUntitledNumber(name));
}
