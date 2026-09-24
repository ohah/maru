//! `check-boundaries` 는 두 모드 루프 안의 판정자를 **Debug 로만** 돈다 — 그 규칙이 다시 새지 않게 센다.
//!
//! **왜 있나.** 규칙 자체는 2026-08-17 에 섰다(build.zig 의 `boundary_step` 선언 위 주석): 판정자 대부분이
//! 소스를 문자열로 읽어 수를 세므로 최적화 모드가 답을 바꿀 수 없고, ReleaseFast 사본은 같은 답을 내려고
//! 바이너리를 한 번 더 링크하는 비용일 뿐이다 — 그때 `check` job 14분이 사실상 이 비용이었다.
//! 그런데 규칙만 적혀 있어서 **루프 안 등록 38 개가 두 모드로 붙어 있었다**(2026-09-25 실측 — 소스를 세는 판정자
//! 20 개는 다시 걸렀고, 나머지 18 개는 아래 동작 테스트다). 이 판정자가
//! 그 되돌아감을 실패로 만든다.
//!
//! **규칙**: `for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |x| { … }` 안의
//! `boundary_step.dependOn(&run.step)` 은 `if (x == .Debug)` 로 걸러야 한다. 예외는 아래 `behavior_runs` —
//! 소스를 세는 판정자가 아니라 제품 모듈을 import 해 **동작을 돌리는** 테스트라, ReleaseFast 에서만 드러나는
//! 결함을 잡을 수 있다(`session host macOS (ReleaseFast)` 잡은 수동 실행 전용이다). 그 목록은 **줄어들기만** 한다.
//!
//! **조용히 초록이 되지 않게**: 루프도, 거른 등록도 하나도 못 찾으면 실패한다 — 서식이 바뀌어 스캐너가
//! 아무것도 못 보면 「위반 0」과 구별되지 않기 때문이다.

const std = @import("std");
const build_source = @import("build_graph").source;

/// 두 모드로 check-boundaries 에 붙는 **동작 테스트**. 이름은 run 변수. 줄어들기만 한다.
const behavior_runs = [_][]const u8{
    "run_live_workflow_aggregate_event_tests",
    "run_live_timing_artifact_tests",
    "run_live_timing_record_tests",
    "run_live_timing_transport_tests",
    "run_live_timing_verifier_tests",
    "run_remote_release_assets_tests",
    "run_remote_release_fence_tests",
    "run_remote_release_metadata_tests",
    "run_remote_release_observation_tests",
    "run_remote_release_pass_artifact_tests",
    "run_remote_release_pass_auditor_tests",
    "run_remote_release_pass_file_tests",
    "run_remote_release_pass_record_tests",
    "run_remote_release_pass_transport_tests",
    "run_remote_release_semantic_files_tests",
    "run_remote_release_semantics_tests",
    "run_remote_release_verdict_tests",
    "run_remote_release_verifier_tests",
};

const loop_prefix = "for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseFast }) |";
const attach_prefix = "boundary_step.dependOn(&";

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn isBehaviorRun(name: []const u8) bool {
    for (behavior_runs) |run| if (std.mem.eql(u8, run, name)) return true;
    return false;
}

test "두 모드 루프 안의 boundary 등록은 Debug 로 거르거나 동작 테스트 목록에 있다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try build_source.read(arena);

    // 열린 루프: 변수 이름과 들여쓰기. zig fmt 가 닫는 `}` 를 여는 줄과 같은 들여쓰기에 둔다.
    var loop_vars: std.ArrayList([]const u8) = .empty;
    var loop_indents: std.ArrayList(usize) = .empty;
    var loops: usize = 0;
    var guarded: usize = 0;
    var behavior_seen: usize = 0;
    var violations: std.ArrayList([]const u8) = .empty;

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        // 루프 머리는 줄 맨 앞(`for (…`)일 수도, 조건 뒤(`if (macos_host_tests) for (…`)일 수도 있다.
        if (std.mem.indexOf(u8, trimmed, loop_prefix)) |loop_at| {
            const rest = trimmed[loop_at + loop_prefix.len ..];
            const bar = std.mem.indexOfScalar(u8, rest, '|') orelse return error.MalformedLoop;
            try loop_vars.append(arena, rest[0..bar]);
            try loop_indents.append(arena, indentOf(line));
            loops += 1;
            continue;
        }
        // 닫는 줄은 `}` — 조건 뒤 루프(`if (…) for …`)는 문장이라 `};` 로 닫힌다.
        if (loop_indents.items.len > 0 and (std.mem.eql(u8, trimmed, "}") or std.mem.eql(u8, trimmed, "};")) and
            indentOf(line) == loop_indents.items[loop_indents.items.len - 1])
        {
            _ = loop_vars.pop();
            _ = loop_indents.pop();
            continue;
        }
        if (loop_vars.items.len == 0) continue;
        const at = std.mem.indexOf(u8, trimmed, attach_prefix) orelse continue;
        const after = trimmed[at + attach_prefix.len ..];
        const end = std.mem.indexOf(u8, after, ".step)") orelse return error.MalformedAttach;
        const run = after[0..end];
        const loop_var = loop_vars.items[loop_vars.items.len - 1];
        const guard = try std.fmt.allocPrint(arena, "if ({s} == .Debug) ", .{loop_var});
        if (std.mem.startsWith(u8, trimmed, guard)) {
            guarded += 1;
        } else if (isBehaviorRun(run)) {
            behavior_seen += 1;
        } else {
            try violations.append(arena, run);
        }
    }

    for (violations.items) |run| std.debug.print("두 모드로 check-boundaries 에 붙음: {s}\n", .{run});
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 목록의 이름은 전부 실제로 있어야 한다 — 옮기거나 걸렀으면 목록에서도 뺀다(줄어들기만).
    try std.testing.expectEqual(behavior_runs.len, behavior_seen);
    // 스캐너가 실제로 무언가를 보았다(서식이 바뀌어 0 개를 보고 통과하는 것을 막는다).
    try std.testing.expect(loops >= 50);
    try std.testing.expect(guarded >= 50);
}
