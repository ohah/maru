//! 성능/스모크 JSON artifact를 **정확한 스키마·타입·값**으로 검증하는 build gate 도구다.
//!
//! 왜 필요한가: 이전 gate는 `sh`의 앵커 없는 `grep -Eq '"ticks"...1000'` 체인이라
//! `"ticks": 10000`이 `1000`을 부분 문자열로 포함해 **통과**했다(예산 10배 악화 false-green).
//! 여기서는 JSON을 실제로 파싱해 exact int/bool/string과 bound(≤/≥/range)로 판정하므로
//! 부분 문자열 매칭이 원천적으로 불가능하다.
//!
//! 베이스·의사결정: 리뷰가 지적한 substring false-green(build.zig의 grep 체인)을 제거하기 위한
//! Maru 독립 설계. `live-preview-macos` 스키마는 36개 키를 **전체 락**(누락·추가 키·타입·값 모두
//! 검사)하고, `mermaid-helper-summary`는 기존 grep이 검사하던 boolean invariant subset을 타입
//! 안전하게 이관한다(추가 키는 스모크 성장에 맞춰 허용).

const std = @import("std");

const Rule = union(enum) {
    exact_int: i64,
    at_most: i64,
    at_least: i64,
    range: struct { lo: i64, hi: i64 },
    exact_bool: bool,
    exact_string: []const u8,
};

const Field = struct { name: []const u8, rule: Rule };

const Schema = struct {
    name: []const u8,
    fields: []const Field,
    /// true면 object의 키 집합이 스키마와 **정확히 일치**해야 한다(누락·추가 모두 실패).
    exact_keys: bool,
};

// FP11f 제품 Mermaid tick 성능 artifact(`maru.live-preview-macos.v1`). 예산 상수는 exact,
// 실측 최댓값/카운트는 bound. 단일 출처 근거는 docs/performance-budget.md "FP11f Mermaid 계측 해석".
const live_preview_macos_fields = [_]Field{
    .{ .name = "accepted_svg_bytes_max", .rule = .{ .exact_int = 524288 } },
    .{ .name = "actual_svg", .rule = .{ .exact_bool = true } },
    .{ .name = "cold_response_deadline_ms", .rule = .{ .exact_int = 5000 } },
    .{ .name = "completion_drain_cap", .rule = .{ .exact_int = 8 } },
    .{ .name = "completion_drain_max", .rule = .{ .at_most = 8 } },
    .{ .name = "failure_latch_deadlines", .rule = .{ .exact_int = 3 } },
    .{ .name = "failure_latch_helper_starts", .rule = .{ .exact_int = 3 } },
    .{ .name = "failure_latch_product_completion_drain_max", .rule = .{ .at_most = 8 } },
    .{ .name = "failure_latch_product_tick_calls", .rule = .{ .at_least = 1 } },
    .{ .name = "failure_latched", .rule = .{ .exact_int = 1 } },
    .{ .name = "helper_physical_starts", .rule = .{ .exact_int = 1 } },
    .{ .name = "helper_result_drain_max", .rule = .{ .at_most = 8 } },
    .{ .name = "mermaid_accepted_svg_bytes_cap", .rule = .{ .exact_int = 2097152 } },
    .{ .name = "mermaid_pending_jobs_cap", .rule = .{ .exact_int = 32 } },
    .{ .name = "mermaid_pending_source_bytes_cap", .rule = .{ .exact_int = 1048576 } },
    .{ .name = "product_reply_delivered", .rule = .{ .exact_bool = true } },
    .{ .name = "product_reply_pending_after_delivery", .rule = .{ .exact_int = 0 } },
    // 512 KiB SVG + JSON envelope 오버헤드. 정확한 envelope 크기는 변할 수 있어 bound.
    .{ .name = "product_reply_serialized_bytes", .rule = .{ .range = .{ .lo = 524288, .hi = 1048576 } } },
    .{ .name = "product_tick_calls", .rule = .{ .exact_int = 1000 } },
    .{ .name = "product_tick_drain_calls", .rule = .{ .at_least = 1 } },
    .{ .name = "product_tick_max_elapsed_us", .rule = .{ .at_most = 20000 } },
    .{ .name = "product_tick_pump_calls", .rule = .{ .at_least = 1 } },
    .{ .name = "product_work_ticks", .rule = .{ .at_least = 1 } },
    .{ .name = "reply_fallback_grace_ms", .rule = .{ .exact_int = 250 } },
    .{ .name = "reply_fallback_ms", .rule = .{ .exact_int = 5250 } },
    .{ .name = "scenario", .rule = .{ .exact_string = "fp11f-mermaid-cold-start-restart-1000-ticks" } },
    .{ .name = "schema", .rule = .{ .exact_string = "maru.live-preview-macos.v1" } },
    .{ .name = "tick_blocking_wait", .rule = .{ .exact_int = 0 } },
    .{ .name = "tick_pipe_read_write", .rule = .{ .exact_int = 0 } },
    .{ .name = "tick_pipe_setup", .rule = .{ .exact_int = 0 } },
    .{ .name = "tick_process_spawn_terminate", .rule = .{ .exact_int = 0 } },
    .{ .name = "ticks", .rule = .{ .exact_int = 1000 } },
    .{ .name = "warm_response_deadline_ms", .rule = .{ .exact_int = 2000 } },
    .{ .name = "worker_result_bytes_cap", .rule = .{ .exact_int = 16777216 } },
    .{ .name = "worker_source_bytes_cap", .rule = .{ .exact_int = 67108864 } },
    .{ .name = "worker_token_cap", .rule = .{ .exact_int = 8 } },
};

// 격리 Mermaid helper lifecycle 스모크 요약(`mermaid-helper.summary.json`). 기존 grep이 검사하던
// boolean invariant를 그대로 이관한다. `passed`는 스모크 내부 AND 집계지만, 개별 invariant도
// 명시 검사해 집계가 잘못 계산돼도 잡는다.
const mermaid_helper_summary_fields = [_]Field{
    .{ .name = "passed", .rule = .{ .exact_bool = true } },
    .{ .name = "blank_document_base_url_is_nil", .rule = .{ .exact_bool = true } },
    .{ .name = "actual_mermaid_svg", .rule = .{ .exact_bool = true } },
    .{ .name = "actual_mermaid_sanitized", .rule = .{ .exact_bool = true } },
    .{ .name = "normal_external_api_attempts_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "normal_external_csp_violations_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "normal_external_navigation_attempts_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "external_api_probe_counted_and_rejected", .rule = .{ .exact_bool = true } },
    .{ .name = "external_counter_is_per_render_on_same_helper", .rule = .{ .exact_bool = true } },
    .{ .name = "external_subresource_csp_probe_counted_and_rejected", .rule = .{ .exact_bool = true } },
    .{ .name = "external_navigation_probe_counted_and_rejected", .rule = .{ .exact_bool = true } },
    .{ .name = "renderer_script_exact_digest_accepted", .rule = .{ .exact_bool = true } },
    .{ .name = "renderer_script_digest_mismatch_rejected", .rule = .{ .exact_bool = true } },
    .{ .name = "renderer_script_symlink_rejected", .rule = .{ .exact_bool = true } },
    .{ .name = "helper_starts_at_most_three", .rule = .{ .exact_bool = true } },
    .{ .name = "termination_acknowledged_exactly", .rule = .{ .exact_bool = true } },
    .{ .name = "no_read_shutdown_bounded", .rule = .{ .exact_bool = true } },
    .{ .name = "closed_pipe_eof_once", .rule = .{ .exact_bool = true } },
    .{ .name = "delayed_start_physical_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "path_aba_result_commit_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "path_aba_capability_frames_zero", .rule = .{ .exact_bool = true } },
    .{ .name = "path_aba_a_restored_before_pid_check", .rule = .{ .exact_bool = true } },
    .{ .name = "tampered_bundle_seal_rejected_before_spawn", .rule = .{ .exact_bool = true } },
    .{ .name = "digest_mismatch_permanent_after_one_start", .rule = .{ .exact_bool = true } },
    .{ .name = "coalesce_old_reply_terminal_exactly_once", .rule = .{ .exact_bool = true } },
    .{ .name = "coalesce_late_old_timeout_keeps_replacement", .rule = .{ .exact_bool = true } },
    .{ .name = "deadline_terminal_reply_immediate_once", .rule = .{ .exact_bool = true } },
    .{ .name = "deadline_late_result_and_timer_noop", .rule = .{ .exact_bool = true } },
    .{ .name = "transient_terminal_reply_immediate_once", .rule = .{ .exact_bool = true } },
    .{ .name = "integrity_terminals_running_and_pending_once", .rule = .{ .exact_bool = true } },
    .{ .name = "integrity_late_failure_and_result_noop", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_wrong_identity_exact_revoke", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_unknown_duplicate_one_shot", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_superseded_requires_exact_identity", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_deliver_timeout_race_one_shot", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_targeted_finish_and_cancel", .rule = .{ .exact_bool = true } },
    .{ .name = "reply_cap_plus_one_rejected_without_mutation", .rule = .{ .exact_bool = true } },
    .{ .name = "shutdown_barrier_no_late_callbacks", .rule = .{ .exact_bool = true } },
    .{ .name = "slow_cold_result_before_five_seconds_accepted", .rule = .{ .exact_bool = true } },
};

const live_preview_macos_schema = Schema{
    .name = "live-preview-macos",
    .fields = &live_preview_macos_fields,
    .exact_keys = true,
};

const mermaid_helper_summary_schema = Schema{
    .name = "mermaid-helper-summary",
    .fields = &mermaid_helper_summary_fields,
    .exact_keys = false,
};

fn schemaFor(mode: []const u8) ?Schema {
    if (std.mem.eql(u8, mode, "live-preview-macos")) return live_preview_macos_schema;
    if (std.mem.eql(u8, mode, "mermaid-helper-summary")) return mermaid_helper_summary_schema;
    return null;
}

fn asInt(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

fn schemaHasKey(schema: Schema, key: []const u8) bool {
    for (schema.fields) |f| {
        if (std.mem.eql(u8, f.name, key)) return true;
    }
    return false;
}

/// 실패 메시지를 `failures`에 allocPrint로 쌓는다(caller가 소유·free). 0개면 통과.
fn collectFailures(
    alloc: std.mem.Allocator,
    schema: Schema,
    bytes: []const u8,
    failures: *std.ArrayList([]const u8),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        try failures.append(alloc, try std.fmt.allocPrint(alloc, "JSON 파싱 실패", .{}));
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try failures.append(alloc, try std.fmt.allocPrint(alloc, "최상위가 object가 아님", .{}));
        return;
    }
    const obj = root.object;

    if (schema.exact_keys) {
        for (obj.keys()) |k| {
            if (!schemaHasKey(schema, k)) {
                try failures.append(alloc, try std.fmt.allocPrint(alloc, "예상 밖 키: {s}", .{k}));
            }
        }
    }

    for (schema.fields) |field| {
        const v = obj.get(field.name) orelse {
            try failures.append(alloc, try std.fmt.allocPrint(alloc, "누락 키: {s}", .{field.name}));
            continue;
        };
        switch (field.rule) {
            .exact_int => |want| {
                const got = asInt(v) orelse {
                    try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 정수 아님", .{field.name}));
                    continue;
                };
                if (got != want) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 기대 {d}, 실제 {d}", .{ field.name, want, got }));
            },
            .at_most => |max| {
                const got = asInt(v) orelse {
                    try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 정수 아님", .{field.name}));
                    continue;
                };
                if (got > max) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {d} > 상한 {d}", .{ field.name, got, max }));
            },
            .at_least => |min| {
                const got = asInt(v) orelse {
                    try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 정수 아님", .{field.name}));
                    continue;
                };
                if (got < min) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {d} < 하한 {d}", .{ field.name, got, min }));
            },
            .range => |r| {
                const got = asInt(v) orelse {
                    try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 정수 아님", .{field.name}));
                    continue;
                };
                if (got < r.lo or got > r.hi) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {d} 범위 밖 [{d}, {d}]", .{ field.name, got, r.lo, r.hi }));
            },
            .exact_bool => |want| {
                switch (v) {
                    .bool => |b| {
                        if (b != want) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 기대 {}, 실제 {}", .{ field.name, want, b }));
                    },
                    else => try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: bool 아님", .{field.name})),
                }
            },
            .exact_string => |want| {
                switch (v) {
                    .string => |s| {
                        if (!std.mem.eql(u8, s, want)) try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: 기대 \"{s}\", 실제 \"{s}\"", .{ field.name, want, s }));
                    },
                    else => try failures.append(alloc, try std.fmt.allocPrint(alloc, "{s}: string 아님", .{field.name})),
                }
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // argv[0]
    const mode = args.next() orelse return usage(stderr);
    const path = args.next() orelse return usage(stderr);

    const schema = schemaFor(mode) orelse {
        try stderr.print("알 수 없는 스키마: {s}\n", .{mode});
        try stderr.flush();
        std.process.exit(2);
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch |e| {
        try stderr.print("artifact 읽기 실패 '{s}' ({s})\n", .{ path, @errorName(e) });
        try stderr.flush();
        std.process.exit(1);
    };
    defer alloc.free(bytes);

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |m| alloc.free(m);
        failures.deinit(alloc);
    }
    try collectFailures(alloc, schema, bytes, &failures);

    if (failures.items.len != 0) {
        try stderr.print("perf artifact 검증 실패 [{s}] {s}:\n", .{ schema.name, path });
        for (failures.items) |m| try stderr.print("  - {s}\n", .{m});
        try stderr.flush();
        std.process.exit(1);
    }
}

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("usage: maru-perf-validate <live-preview-macos|mermaid-helper-summary> <artifact.json>\n");
    try stderr.flush();
    std.process.exit(2);
}

// ---- 테스트: 부분 문자열 false-green 회귀와 스키마 락 ----

const testing = std.testing;

fn countFailures(schema: Schema, bytes: []const u8) !usize {
    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |m| testing.allocator.free(m);
        failures.deinit(testing.allocator);
    }
    try collectFailures(testing.allocator, schema, bytes, &failures);
    return failures.items.len;
}

// 실제 artifact와 같은 형태의 최소 유효 baseline(모든 키 present·기대값).
const good_live_preview =
    \\{
    \\  "accepted_svg_bytes_max": 524288,
    \\  "actual_svg": true,
    \\  "cold_response_deadline_ms": 5000,
    \\  "completion_drain_cap": 8,
    \\  "completion_drain_max": 1,
    \\  "failure_latch_deadlines": 3,
    \\  "failure_latch_helper_starts": 3,
    \\  "failure_latch_product_completion_drain_max": 8,
    \\  "failure_latch_product_tick_calls": 1129,
    \\  "failure_latched": 1,
    \\  "helper_physical_starts": 1,
    \\  "helper_result_drain_max": 1,
    \\  "mermaid_accepted_svg_bytes_cap": 2097152,
    \\  "mermaid_pending_jobs_cap": 32,
    \\  "mermaid_pending_source_bytes_cap": 1048576,
    \\  "product_reply_delivered": true,
    \\  "product_reply_pending_after_delivery": 0,
    \\  "product_reply_serialized_bytes": 524350,
    \\  "product_tick_calls": 1000,
    \\  "product_tick_drain_calls": 8,
    \\  "product_tick_max_elapsed_us": 1135,
    \\  "product_tick_pump_calls": 8,
    \\  "product_work_ticks": 8,
    \\  "reply_fallback_grace_ms": 250,
    \\  "reply_fallback_ms": 5250,
    \\  "scenario": "fp11f-mermaid-cold-start-restart-1000-ticks",
    \\  "schema": "maru.live-preview-macos.v1",
    \\  "tick_blocking_wait": 0,
    \\  "tick_pipe_read_write": 0,
    \\  "tick_pipe_setup": 0,
    \\  "tick_process_spawn_terminate": 0,
    \\  "ticks": 1000,
    \\  "warm_response_deadline_ms": 2000,
    \\  "worker_result_bytes_cap": 16777216,
    \\  "worker_source_bytes_cap": 67108864,
    \\  "worker_token_cap": 8
    \\}
;

test "live-preview baseline passes" {
    try testing.expectEqual(@as(usize, 0), try countFailures(live_preview_macos_schema, good_live_preview));
}

test "10x ticks fails (부분 문자열 false-green 회귀)" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "\"ticks\": 1000", "\"ticks\": 10000");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "10x accepted_svg_bytes_max fails" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "524288", "5242880");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "10x cold deadline fails" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "\"cold_response_deadline_ms\": 5000", "\"cold_response_deadline_ms\": 50000");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "tick counter nonzero fails" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "\"tick_blocking_wait\": 0", "\"tick_blocking_wait\": 1");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "elapsed over budget fails" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "\"product_tick_max_elapsed_us\": 1135", "\"product_tick_max_elapsed_us\": 20001");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "missing key fails" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "  \"ticks\": 1000,\n", "");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "extra key fails (schema lock)" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "  \"ticks\": 1000,\n", "  \"ticks\": 1000,\n  \"surprise\": 1,\n");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "wrong type fails (bool로 바뀐 int)" {
    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_live_preview, "\"ticks\": 1000", "\"ticks\": true");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(live_preview_macos_schema, bad) > 0);
}

test "summary baseline passes / false는 실패" {
    const good_summary =
        \\{ "passed": true, "blank_document_base_url_is_nil": true, "actual_mermaid_svg": true,
        \\  "actual_mermaid_sanitized": true, "normal_external_api_attempts_zero": true,
        \\  "normal_external_csp_violations_zero": true, "normal_external_navigation_attempts_zero": true,
        \\  "external_api_probe_counted_and_rejected": true, "external_counter_is_per_render_on_same_helper": true,
        \\  "external_subresource_csp_probe_counted_and_rejected": true, "external_navigation_probe_counted_and_rejected": true,
        \\  "renderer_script_exact_digest_accepted": true, "renderer_script_digest_mismatch_rejected": true,
        \\  "renderer_script_symlink_rejected": true, "helper_starts_at_most_three": true,
        \\  "termination_acknowledged_exactly": true, "no_read_shutdown_bounded": true, "closed_pipe_eof_once": true,
        \\  "delayed_start_physical_zero": true, "path_aba_result_commit_zero": true, "path_aba_capability_frames_zero": true,
        \\  "path_aba_a_restored_before_pid_check": true, "tampered_bundle_seal_rejected_before_spawn": true,
        \\  "digest_mismatch_permanent_after_one_start": true, "coalesce_old_reply_terminal_exactly_once": true,
        \\  "coalesce_late_old_timeout_keeps_replacement": true, "deadline_terminal_reply_immediate_once": true,
        \\  "deadline_late_result_and_timer_noop": true, "transient_terminal_reply_immediate_once": true,
        \\  "integrity_terminals_running_and_pending_once": true, "integrity_late_failure_and_result_noop": true,
        \\  "reply_wrong_identity_exact_revoke": true, "reply_unknown_duplicate_one_shot": true,
        \\  "reply_superseded_requires_exact_identity": true, "reply_deliver_timeout_race_one_shot": true,
        \\  "reply_targeted_finish_and_cancel": true, "reply_cap_plus_one_rejected_without_mutation": true,
        \\  "shutdown_barrier_no_late_callbacks": true, "slow_cold_result_before_five_seconds_accepted": true,
        \\  "extra_forward_compat_field": 7 }
    ;
    try testing.expectEqual(@as(usize, 0), try countFailures(mermaid_helper_summary_schema, good_summary));

    const bad = try std.mem.replaceOwned(u8, testing.allocator, good_summary, "\"passed\": true", "\"passed\": false");
    defer testing.allocator.free(bad);
    try testing.expect(try countFailures(mermaid_helper_summary_schema, bad) > 0);
}
