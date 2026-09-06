//! 기본 `test` 그래프에 **셸을 부르는 단계**가 조용히 늘지 않는다.
//!
//! **무엇을 막나.** `zig build test` 는 이 저장소에서 «회귀가 보이는 유일한 그물»이다 — Windows 러너를
//! 두지 않기로 했으므로(계획서) 그 호스트에서는 **개발자가 로컬에서 돌리는 것**이 전부다. 그런데 그
//! 그래프에 `addSystemCommand(&.{ "sh"|"bash", … })` 가 하나 붙고 그 스크립트가 어떤 호스트에서 안
//! 돌면, **계약과 아무 상관 없는 이유로 게이트가 통째로 빨개진다.** 그러면 진짜 실패가 그 잡음에 묻힌다.
//!
//! **실제로 그렇게 됐다(§2m.111).** `tools/test-session-host-release-attestation-action.sh` 가 붙은 날
//! Windows 게이트가 깨졌고 **22 커밋 동안 아무도 몰랐다.** 그것을 넣은 사람에게는 알 방법이 없었다 —
//! 그 호스트에서 돌려 볼 이유가 없기 때문이다.
//!
//! **그래서 개수가 아니라 «명단»이다.** 새 단계를 붙이면 이 원장을 함께 고쳐야 하고, 그 순간 이
//! 주석을 읽게 된다. 이 게이트가 하는 일은 **결정을 강제하는 것**이지 셸을 금지하는 것이 아니다 —
//! 셋은 지금도 Windows 에서 잘 돈다(실측).
//!
//! **원장을 고칠 때 물어야 할 것.** *"이 스크립트가 모든 개발 호스트에서 도는가?"*
//!
//!   - **돈다** → `.every_host` 로 적는다. 근거는 그 호스트에서 한 번 돌려 본 것이어야 한다.
//!   - **안 돈다** → `build.zig` 에서 `posix_host_tests` 로 가리고 `.posix_only` 로 적는다. 그러면
//!     그 계약은 **그 호스트에서 안 재진다** — 그 사실을 알고 적는 것이 이 원장의 요점이다.
//!   - **못 재겠다** → 「안 됐다」가 아니라 **「못 쟀다」**로 적는 길이 스크립트 쪽에 있다(§2m.108 의
//!     `SKIP`). 그쪽이 대개 낫다: 나머지 검사를 안 잃는다.
//!
//! **이 게이트가 막지 못하는 것 — 정직하게.**
//!   - **`.every_host` 가 참인지는 못 본다.** 그것은 사람이 한 번 돌려 보고 적는 값이다. 이 판정은
//!     *"누가 그 질문에 답했는가"* 까지만 강제한다.
//!   - **`build.zig` 밖의 셸 의존은 못 본다** — `.mise.toml` 의 태스크가 그렇다(별도 자리).
//!   - 인터프리터 이름이 `sh`·`bash` 가 아니면 못 본다(`python3` 등은 이 원장의 대상이 아니다).

const std = @import("std");

/// 이 단계가 **어느 호스트에서 도는가**.
const Reach = enum {
    /// 모든 개발 호스트에서 돈다(Windows 포함) — 실측으로 확인하고 적는다.
    every_host,
    /// POSIX 호스트에서만 돈다. `build.zig` 가 `posix_host_tests` 로 가려야 한다.
    posix_only,
};

const Entry = struct { script: []const u8, reach: Reach };

/// **원장.** 기본 `test` 그래프에 붙은 셸 단계 전부.
///
/// 실측(2026-09-04, Windows/Git Bash): 앞의 셋은 `EXIT=0`, 마지막 하나는 `EXIT=1` 이다 —
/// `pin-subject.sh` 가 `case $(uname -s)` 에서 모르는 OS 를 `*) return 1` 로 닫는다(§2m.111).
const ledger = [_]Entry{
    .{ .script = "tools/check-agent-hook-command.sh", .reach = .every_host },
    .{ .script = "tools/test-release-version.sh", .reach = .every_host },
    .{ .script = "tools/test-github-release-publication.sh", .reach = .every_host },
    .{ .script = "tools/ci/session-host-release-dmg-authority.sh", .reach = .posix_only },
    .{ .script = "tools/test-session-host-release-attestation-action.sh", .reach = .posix_only },
    .{ .script = "tools/test-session-host-release-authored-attestation-action.sh", .reach = .posix_only },
    // POSIX 권한을 쓰는 자리(`mkdir -m`)라 NTFS 에서 죽는다 — 실측 2026-09-04.
    // **이 항목이 이 게이트의 첫 수확이다**: 원장을 넣는 PR 이 열려 있는 동안 main 에 들어왔고,
    // CI 가 머지 결과에서 잡았다(§2m.111).
    .{ .script = "tests/session-host-baseline-child-paths.sh", .reach = .posix_only },
};

/// `build.zig` 에서 셸 단계 하나가 묶이는 모양.
const Found = struct {
    binding: []const u8,
    script: []const u8,
    on_test_step: bool = false,
    guarded: bool = false,
};

/// 이 이름이 줄에 있으면 «호스트로 가렸다» 로 본다. `build.zig` 가 그 술어를 소유한다.
const guard_names = [_][]const u8{ "posix_host_tests", "macos_host_tests" };

fn scan(arena: std.mem.Allocator, source: []const u8) ![]Found {
    var out: std.ArrayList(Found) = .empty;

    // ① `const <name> = b.addSystemCommand(&.{ "<sh|bash>", "<script>" …` 를 걷는다.
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const cmd_at = std.mem.indexOf(u8, line, "b.addSystemCommand(&.{") orelse continue;
        const const_at = std.mem.indexOf(u8, line, "const ") orelse continue;
        if (const_at > cmd_at) continue;
        const name_start = const_at + "const ".len;
        const name_end = std.mem.indexOfPos(u8, line, name_start, " =") orelse continue;
        const binding = line[name_start..name_end];

        // 첫 인자가 셸 인터프리터인가.
        var rest = line[cmd_at..];
        const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        rest = rest[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const interp = rest[0..q2];
        if (!std.mem.eql(u8, interp, "sh") and !std.mem.eql(u8, interp, "bash")) continue;

        // 그다음 문자열이 스크립트 경로다.
        rest = rest[q2 + 1 ..];
        const q3 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        rest = rest[q3 + 1 ..];
        const q4 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        try out.append(arena, .{ .binding = try arena.dupe(u8, binding), .script = try arena.dupe(u8, rest[0..q4]) });
    }

    // ② 각 바인딩이 `test_step` 에 붙었는가, 그리고 그 줄이 가려져 있는가.
    for (out.items) |*f| {
        var needle: std.ArrayList(u8) = .empty;
        try needle.appendSlice(arena, "test_step.dependOn(&");
        try needle.appendSlice(arena, f.binding);
        try needle.appendSlice(arena, ".step)");

        var it2 = std.mem.splitScalar(u8, source, '\n');
        while (it2.next()) |line| {
            if (std.mem.indexOf(u8, line, needle.items) == null) continue;
            // `macos_only_test_step` 같은 다른 step 은 대상이 아니다 — 바로 앞 글자로 가른다.
            const at = std.mem.indexOf(u8, line, needle.items).?;
            if (at > 0 and (std.ascii.isAlphanumeric(line[at - 1]) or line[at - 1] == '_')) continue;
            f.on_test_step = true;
            for (guard_names) |g| if (std.mem.indexOf(u8, line, g) != null) {
                f.guarded = true;
            };
        }
    }
    return out.toOwnedSlice(arena);
}

test "기본 test 그래프의 셸 단계는 원장과 정확히 같다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig", arena, .limited(4 * 1024 * 1024));
    const found = try scan(arena, source);

    var failed = false;

    // ⑴ 원장에 없는 것이 붙었나.
    for (found) |f| {
        if (!f.on_test_step) continue;
        var known = false;
        for (ledger) |e| if (std.mem.eql(u8, e.script, f.script)) {
            known = true;
        };
        if (!known) {
            std.debug.print(
                \\
                \\build.zig: `{s}` 가 기본 `test` 그래프에 새로 붙었다 — 원장에 없다.
                \\  이 그래프는 Windows 에서 **개발자가 로컬로 돌리는 유일한 그물**이다. 그 호스트에서
                \\  이 스크립트가 안 돌면 계약과 무관한 이유로 게이트가 통째로 빨개진다(§2m.111).
                \\  → 그 호스트에서 한 번 돌려 보고 `tests/boundary/shell_gate_ledger.zig` 의 원장에
                \\    `.every_host` 또는 `.posix_only` 로 적는다. 단일 출처: docs/windows-platform.md §2m.111.
                \\
            , .{f.script});
            failed = true;
        }
    }

    // ⑵ 원장에 있는데 사라졌나(옮겼거나 지웠다 — 원장도 줄여야 한다).
    for (ledger) |e| {
        var seen = false;
        for (found) |f| if (f.on_test_step and std.mem.eql(u8, e.script, f.script)) {
            seen = true;
        };
        if (!seen) {
            std.debug.print("\nbuild.zig: 원장의 `{s}` 가 기본 `test` 그래프에 없다 — 원장에서 지운다.\n", .{e.script});
            failed = true;
        }
    }

    // ⑶ 원장이 `.posix_only` 라고 적은 것은 실제로 가려져 있어야 한다.
    for (ledger) |e| {
        if (e.reach != .posix_only) continue;
        for (found) |f| {
            if (!f.on_test_step or !std.mem.eql(u8, e.script, f.script)) continue;
            if (!f.guarded) {
                std.debug.print(
                    \\
                    \\build.zig: `{s}` 는 원장이 `.posix_only` 인데 가드가 없다.
                    \\  → `if (posix_host_tests) test_step.dependOn(…)` 로 감싼다.
                    \\
                , .{e.script});
                failed = true;
            }
        }
    }

    // ⑷ `.every_host` 라고 적은 것을 가드로 감싸면 원장이 거짓말이 된다.
    for (ledger) |e| {
        if (e.reach != .every_host) continue;
        for (found) |f| {
            if (!f.on_test_step or !std.mem.eql(u8, e.script, f.script)) continue;
            if (f.guarded) {
                std.debug.print(
                    \\
                    \\build.zig: `{s}` 는 가려져 있는데 원장은 `.every_host` 라고 말한다.
                    \\  → 원장을 `.posix_only` 로 고치거나 가드를 뺀다.
                    \\
                , .{e.script});
                failed = true;
            }
        }
    }

    try std.testing.expect(!failed);
}

test "스캐너가 셸 단계만 걷고, 다른 step 의 dependOn 을 test_step 으로 안 읽는다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // **판정이 비지 않는지부터 본다.** 스캐너가 형식을 못 읽으면 위 테스트는 «원장에 없는 것이 없다»
    // 로 조용히 통과한다 — 그 실패 모양이 초록과 같다.
    const fixture =
        \\    const a = b.addSystemCommand(&.{ "sh", "tools/x.sh" });
        \\    test_step.dependOn(&a.step);
        \\    const c = b.addSystemCommand(&.{ "bash", "tools/y.sh" });
        \\    if (posix_host_tests) test_step.dependOn(&c.step);
        \\    const d = b.addSystemCommand(&.{ "python3", "tools/z.py" });
        \\    test_step.dependOn(&d.step);
        \\    const e = b.addSystemCommand(&.{ "sh", "tools/w.sh" });
        \\    macos_only_test_step.dependOn(&e.step);
    ;
    const found = try scan(arena, fixture);

    // `python3` 은 이 원장의 대상이 아니다.
    try std.testing.expectEqual(@as(usize, 3), found.len);

    try std.testing.expectEqualStrings("tools/x.sh", found[0].script);
    try std.testing.expect(found[0].on_test_step and !found[0].guarded);

    try std.testing.expectEqualStrings("tools/y.sh", found[1].script);
    try std.testing.expect(found[1].on_test_step and found[1].guarded);

    // **`macos_only_test_step` 은 `test_step` 이 아니다.** 접미로 매칭하면 이것을 기본 그래프로 읽어
    // 원장이 엉뚱하게 커진다.
    try std.testing.expectEqualStrings("tools/w.sh", found[2].script);
    try std.testing.expect(!found[2].on_test_step);
}
