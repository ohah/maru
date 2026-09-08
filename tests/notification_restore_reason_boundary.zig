//! exec 업그레이드의 **`stage=activate` 에서 무엇이 거부했는지** 로그가 말하는지 못 박는다.
//!
//! ## 왜 이 자리가 특별한가
//!
//! `restore_activation.activateValidated` → `runtime_manager.prepareRestoredGraph` 는 그래프를 세운 뒤
//! 알림 핸드오프 둘을 `try` 로 복원한다. 거기서 지면 host 가 죽고, **PTY 소유자가 사라져 셸 전체가
//! SIGHUP** 을 받는다. 즉 이 함수들의 `return` 하나가 사용자의 세션을 통째로 날린다.
//!
//! ## 두 번 같은 자리에서 눈이 멀었다
//!
//! - 2026-09-05: host 가 `stage=activate err=InvalidValue` 로 죽고 **세션 22 개**를 잃었다. 남은 것은 그
//!   한 줄뿐이라 어느 필드인지 몰랐다(`upgrade_bootstrap.decodeValidated` 주석).
//! - 그때 넣은 진단은 **decode 단계에만** 있었다. 그래서 2026-09-08 에 같은 오류로 또 죽었을 때도
//!   `restore stage failed: stage=activate err=InvalidValue` 두 줄 말고는 아무것도 없었다.
//!
//! 그날 확인한 것 — 새 이미지와 **롤백(옛 바이너리)이 같은 자리에서 같은 오류로** 졌다. 즉 코드 회귀가
//! 아니라 핸드오프 상태가 거부된 것이고, 그렇다면 **어느 필드가** 거부됐는지가 유일한 단서다.
//!
//! ## 무엇을 세는가
//!
//! 두 `restoreHandoff` 안에서 `InvalidValue` 하나에 조건 열여섯 개가 뭉쳐 있었다. 이 파일은 그것들이
//! 갈라진 채로 남아 있는지 본다.
//!
//! ## 왜 로그가 아니라 오류 이름인가
//!
//! `notification_journal` 은 **pure owner** 라 import 가 `std` 하나로 못 박혀 있다
//! (`tests/session_host_notification_journal_boundary.zig`). 처음에 `host_log` 를 들여와 사유를 찍으려다
//! 그 경계를 깨서 CI 가 잡았다. 대신 사유를 **오류 이름에** 실으면 `restore_activation` 이 이미 찍는
//! `stage=activate err={s}`(`@errorName`)가 그대로 사유를 내보낸다 — 새 import 도, 새 로그도 필요 없다.
//!
//! 대가는 **행 번호를 잃는 것**이다. 오류 이름은 값을 못 나른다. 어느 조건인지가 먼저이고, 행이
//! 필요해지면 그때 비-pure 쪽(`runtime_manager`)에서 따로 받는다.

const std = @import("std");

const journal_path = "src/platform/macos/session_host/notification_journal.zig";
const delivery_path = "src/platform/macos/session_host/notification_delivery.zig";
const max_source_bytes = 8 * 1024 * 1024;

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
}

/// 줄 주석을 벗긴다. **부정 단언은 반드시 이것을 지나야 한다** — 위 머리말과 코드 주석이 옛 모습을
/// 그대로 인용하므로, 벗기지 않으면 「설명하는 주석」이 「쓰는 코드」로 세어진다.
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

test "활성화 단계의 핸드오프 거부는 어느 조건이었는지 말한다" {
    const a = std.testing.allocator;
    const journal_raw = try read(a, journal_path);
    defer a.free(journal_raw);
    const journal = try stripComments(a, journal_raw);
    defer a.free(journal);

    const delivery_raw = try read(a, delivery_path);
    defer a.free(delivery_raw);
    const delivery = try stripComments(a, delivery_raw);
    defer a.free(delivery);

    // ① **pure owner 를 깨지 않는다.** 사유를 로그로 내려다 이 경계를 깼던 자리다.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, journal, "@import("));
    try std.testing.expect(std.mem.indexOf(u8, journal, "@import(\"std\")") != null);

    // ② 뭉쳐 있던 조건들이 각자 이름을 가진다 — 선언과 사용처 둘 다 있어야 한다.
    // `error.` 접두 대조는 comptime 연결이라 `inline for` 여야 한다.
    inline for ([_][]const u8{
        "ExhaustedFlagNotBool",
        "ExhaustedDisagreesWithLastEventId",
        "EventIdZero",
        "EventIdNotIncreasing",
        "EventIdExceedsLast",
        "RuntimeIdZero",
        "FlagsEmpty",
        "FlagsUnknownBits",
        "TitleNotUtf8",
        "BodyNotUtf8",
        "LabelNotUtf8",
        "ResidentMismatch",
    }) |reason| {
        try std.testing.expect(std.mem.indexOf(u8, journal, reason) != null);
        try std.testing.expect(std.mem.indexOf(u8, journal, "error." ++ reason) != null);
    }

    inline for ([_][]const u8{
        "EnabledFlagNotBool",
        "ConfigGenerationZeroWithState",
        "ControllerWithoutConfigGeneration",
        "LabelEmpty",
        "LabelTooLong",
        "LabelNotUtf8",
    }) |reason| {
        try std.testing.expect(std.mem.indexOf(u8, delivery, reason) != null);
        try std.testing.expect(std.mem.indexOf(u8, delivery, "error." ++ reason) != null);
    }

    // ③ 옛 뭉텅이가 되살아나면 빨개진다.
    for ([_][]const u8{
        "flags == 0 or flags & ~@as(u8, 0x03) != 0) return error.InvalidValue;",
        "!std.unicode.utf8ValidateSlice(label_source)) return error.InvalidValue;",
        "if (exhausted_raw > 1) return error.InvalidValue;",
    }) |old| try std.testing.expect(std.mem.indexOf(u8, journal, old) == null);
    for ([_][]const u8{
        "if (enabled_raw > 1) return error.InvalidValue;",
        "if (label_len == 0 or label_len > max_display_label_bytes) return error.InvalidValue;",
    }) |old| try std.testing.expect(std.mem.indexOf(u8, delivery, old) == null);
}
