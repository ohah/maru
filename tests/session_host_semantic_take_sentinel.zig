//! **의미 take 가 얇은 채로 남는다** — `control_semantic_take` 와 resize·resync·복구 스냅숏
//! 커밋 목적지가 제자리에 있고, take 래퍼가 네 필드를 그대로 드는지 comptime 으로 본다.
//! 그리고 그 행동을 재는 테스트들이 실재하는지 이름으로 확인한다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3c2**.

const std = @import("std");
const pump = @import("client_external_pump");

pub fn main() !void {
    comptime {
        if (pump.semantic_take_contract_version != 1)
            @compileError("F3c2 semantic take contract version drifted");
        for (.{
            "control_semantic_take",
            "resize_semantic_commit",
            "resync_semantic_commit",
            "projected_recovery_snapshot_commit",
        }) |field| if (!@hasField(pump.ExternalRxTurnScratch, field))
            @compileError("F3c2 final-address destination disappeared");

        const Take = @FieldType(
            pump.ExternalRxTurnScratch,
            "control_semantic_take",
        );
        for (.{
            "saved_self_addr",
            "branch",
            "lifecycle",
            "digest",
        }) |field| if (!@hasField(Take, field))
            @compileError("F3c2 thin semantic take wrapper drifted");
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/session_host/client_external_pump.zig",
        std.heap.page_allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.heap.page_allocator.free(source);
    const source_z = try std.heap.page_allocator.dupeZ(u8, source);
    defer std.heap.page_allocator.free(source_z);
    const intent_source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/session_host/external_rx_intent.zig",
        std.heap.page_allocator,
        .limited(1024 * 1024),
    );
    defer std.heap.page_allocator.free(intent_source);

    const required_behavior_names = [_][]const u8{
        "semantic take older and equal resize success consume owners exactly once while preserving current",
        "semantic take resize rejects coherently resealed response receipt splice",
        "semantic take destination range matrix accepts adjacent and rejects overlap escape and overflow",
        "semantic take resync wrapper rejects coherent copy splice cross-owner and optional tag flip",
        "semantic take detached recovery fixture restores every owner at allocation fail index",
        "semantic take resync candidate one rejects actual-token ABA then atomically consumes ACK and snapshot",
        "semantic take response cleanup reentry is busy and payload frees exactly once",
        "semantic take resync cleanup quarantines aggregate pointer drift without blessing stale digest",
        "semantic take resync cleanup rejects coherently resealed aggregate pointer drift",
        "semantic take resync cleanup rejects coherently resealed binding source drift",
        "semantic take resync cleanup rejects coherently resealed disposition destination drift",
        "semantic take resync cleanup quarantines ledger authority drift",
        "semantic take retirement callback cannot redirect response payload or allocator to 0x1",
        "semantic take resync semantic candidate capacity consumes one bind and all cleanup dispositions",
        "semantic take resync success sends duplicate wire to unsolicited protocol terminal",
        "semantic take maximum resync correlation retires without wrap and blocks next admission",
        "semantic take maximum request ID succeeds on wire then next admission emits no wire",
    };
    var required_behavior_found = [_]bool{false} ** required_behavior_names.len;
    var tokenizer = std.zig.Tokenizer.init(source_z);
    var behavior_tests: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .keyword_test) continue;
        const name = tokenizer.next();
        if (name.tag != .string_literal) continue;
        const literal = source_z[name.loc.start + 1 .. name.loc.end - 1];
        if (std.mem.startsWith(u8, literal, "semantic take ")) behavior_tests += 1;
        for (required_behavior_names, 0..) |required_name, index| {
            if (std.mem.eql(u8, literal, required_name)) {
                required_behavior_found[index] = true;
            }
        }
    }
    if (behavior_tests < 6) return error.F3c2BehaviorGateEmpty;
    for (required_behavior_found) |found|
        if (!found)
            return error.F3c2NamedBehaviorGateMissing;

    const required = [_][]const u8{
        "PreparedControlSemanticTake",
        "PreparedResizeSemanticCommit",
        "PreparedResyncSemanticCommit",
        "ProjectedRecoverySnapshotCommit",
        "publishResyncAckUnchecked",
        "invalid_precommit",
        "cleaned_with_invariant",
    };
    for (required) |needle| if (std.mem.indexOf(u8, source, needle) == null)
        return error.F3c2TransactionContractMissing;

    const suffix_begin = std.mem.indexOf(
        u8,
        source,
        "// MARU_F3C2_POST_FIRST_WRITE_BEGIN",
    ) orelse return error.F3c2PostWriteBoundaryMissing;
    const suffix_end = std.mem.indexOfPos(
        u8,
        source,
        suffix_begin,
        "// MARU_F3C2_POST_FIRST_WRITE_END",
    ) orelse return error.F3c2PostWriteBoundaryMissing;
    const suffix = source[suffix_begin..suffix_end];
    const forbidden_suffix_tokens = [_][]const u8{
        "@ptrFromInt",
        " try ",
        " catch ",
        " return ",
        " orelse ",
    };
    for (forbidden_suffix_tokens) |forbidden|
        if (std.mem.indexOf(u8, suffix, forbidden) != null)
            return error.F3c2PostWriteFallibleOperation;

    const projected_begin = std.mem.indexOf(
        u8,
        source,
        "// MARU_F3C2_PROJECTED_UNCHECKED_BEGIN",
    ) orelse return error.F3c2ProjectedSuffixBoundaryMissing;
    const projected_end = std.mem.indexOfPos(
        u8,
        source,
        projected_begin,
        "// MARU_F3C2_PROJECTED_UNCHECKED_END",
    ) orelse return error.F3c2ProjectedSuffixBoundaryMissing;
    const projected_suffix = source[projected_begin..projected_end];
    const forbidden_projected_tokens = [_][]const u8{
        "@ptrFromInt",
        " try ",
        " catch ",
        " return",
        " orelse ",
        "validate",
        "abort",
        ".deinit(",
        ".retire(",
    };
    for (forbidden_projected_tokens) |forbidden|
        if (std.mem.indexOf(u8, projected_suffix, forbidden) != null)
            return error.F3c2ProjectedSuffixFallibleOperation;

    const unchecked_regions = [_]struct {
        source: []const u8,
        begin: []const u8,
        end: []const u8,
    }{
        .{
            .source = source,
            .begin = "// MARU_F3C2_RETAINED_CLEANUP_UNCHECKED_BEGIN",
            .end = "// MARU_F3C2_RETAINED_CLEANUP_UNCHECKED_END",
        },
        .{
            .source = source,
            .begin = "// MARU_F3C2_COMBINED_CLEANUP_UNCHECKED_BEGIN",
            .end = "// MARU_F3C2_COMBINED_CLEANUP_UNCHECKED_END",
        },
        .{
            .source = intent_source,
            .begin = "// MARU_F3C2_INTENT_DESTROY_UNCHECKED_BEGIN",
            .end = "// MARU_F3C2_INTENT_DESTROY_UNCHECKED_END",
        },
    };
    const forbidden_transitive_tokens = [_][]const u8{
        "@ptrFromInt",
        "std.debug.assert",
        "validate",
        " try ",
        " catch ",
        " orelse ",
        " return ",
        ".alloc(",
        "clock",
        "c.recv",
        "c.send",
    };
    for (unchecked_regions) |region| {
        const begin = std.mem.indexOf(u8, region.source, region.begin) orelse
            return error.F3c2TransitiveSuffixBoundaryMissing;
        const end = std.mem.indexOfPos(u8, region.source, begin, region.end) orelse
            return error.F3c2TransitiveSuffixBoundaryMissing;
        const body = region.source[begin..end];
        for (forbidden_transitive_tokens) |forbidden|
            if (std.mem.indexOf(u8, body, forbidden) != null)
                return error.F3c2TransitiveSuffixFallibleOperation;
    }

    // F3c2 keeps one definition and F3d owns the sole product orchestration callsite.
    const first_test = std.mem.indexOf(u8, source, "test \"") orelse
        return error.F3c2BehaviorGateEmpty;
    const product_source = source[0..first_test];
    const component_entrypoints = [_][]const u8{
        "prepareResizeSemanticCommitUnderHeldLease(",
        "consumeResizeSemanticCommitUnderHeldLease(",
        "prepareResyncSemanticCommitUnderHeldLease(",
        "consumeResyncSemanticCommitUnderHeldLease(",
    };
    for (component_entrypoints) |entrypoint| {
        var count: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, product_source, cursor, entrypoint)) |found| {
            count += 1;
            cursor = found + entrypoint.len;
        }
        if (count != 2) return error.F3c2ProductBoundaryDrift;
    }
}
