//! Non-test-runner sentinel for the 2b2e ACK and actual-token integration gate.

const std = @import("std");
const pump = @import("client_external_pump");

pub fn main() !void {
    comptime {
        if (pump.integration_2b2e_contract_version != 2)
            @compileError("2b2e integration contract version drifted");
        for (.{
            "resync_ack_transition",
            "resync_ack_response_take",
            "resync_ack_frozen_response",
        }) |field| if (!@hasField(pump.ExternalRxTurnScratch, field))
            @compileError("2b2e ACK final-address destination disappeared");
        const Transition = @FieldType(
            pump.ExternalRxTurnScratch,
            "resync_ack_transition",
        );
        for (.{
            "saved_self_addr",
            "storage_addr",
            "scratch_addr",
            "lease_addr",
            "owner_incarnation",
            "operation_generation",
            "turn_generation",
            "parser_generation",
            "parser_seal",
            "sampled_now_ns",
            "recovery_deadline_ns",
            "authority_state",
            "authority_generation",
            "authority_seal_digest",
            "permit_addr",
            "permit_digest",
            "verdict_addr",
            "verdict_digest",
            "completed_owner_digest",
            "correlation_digest",
            "tx_queue_generation",
            "recovery_barrier_absolute",
            "next_state",
            "response_take_addr",
            "response_take_digest",
            "frozen_response_addr",
            "frozen_response_pristine_digest",
            "lifecycle",
            "digest",
        }) |field| if (!@hasField(Transition, field))
            @compileError("2b2e ACK transition seal field disappeared");
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        "src/platform/macos/session_host/client_external_pump.zig",
        std.heap.page_allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.heap.page_allocator.free(source);
    if (std.mem.count(u8, source, "test \"2b2e integration ") < 7)
        return error.IntegrationBehaviorGateEmpty;
    const required = [_][]const u8{
        "commitRecoveryTransportSideIntentUnderHeldLease",
        "already_committed",
        "claimCommittedLiveOutputUnchecked",
        "committed_semantic_digest",
        "binding_next_state",
        "prepared_live_commit_digest",
        "cleanup_final",
        "cleanup_destination_digest",
        "binding_destination_pristine_digest",
        "ledger_authority_digest",
        "source_discriminator",
        "ack_transition_digest",
        "consumed_tombstone",
        "quarantinePublishedStorageAfterCallbackDrift",
    };
    for (required) |needle| if (std.mem.indexOf(u8, source, needle) == null)
        return error.IntegrationTransactionContractMissing;
}
