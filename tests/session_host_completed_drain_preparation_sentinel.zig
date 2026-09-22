//! **완료 drain 준비의 «최종 주소» 들이 제자리에 있다** — drain 허가·의미 판정·종단 바인딩의
//! 목적지 필드와 봉인 필드 스물다섯을 comptime 으로 세고, 계약 버전이 밀리면 죽는다.
//! 행동 테스트가 아홉 개 미만이면 게이트가 빈 것으로 보고 실패한다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3c1**.

const std = @import("std");
const pump = @import("client_external_pump");

pub fn main() !void {
    comptime {
        if (pump.completed_drain_contract_version != 2)
            @compileError("F3c1 preparation contract version drifted");
        if (!@hasField(pump.ExternalRxTurnScratch, "whole_drain_permit") or
            !@hasField(pump.ExternalRxTurnScratch, "control_semantic_verdict") or
            !@hasField(pump.ExternalRxTurnScratch, "control_semantic_terminal"))
            @compileError("F3c1 final-address preparation destinations disappeared");
        const Permit = @FieldType(pump.ExternalRxTurnScratch, "whole_drain_permit");
        if (!@hasField(Permit, "drain_evidence_addr") or
            !@hasField(Permit, "drain_evidence_digest") or
            !@hasField(Permit, "completed_exception_digest"))
            @compileError("F3c1 drain evidence binding disappeared");
        if (!@hasField(pump.ExternalRxTurnScratch, "control_semantic_terminal_binding") or
            !@hasField(pump.ExternalRxTurnScratch, "control_terminal_response_take") or
            !@hasField(pump.ExternalRxTurnScratch, "control_terminal_frozen_response"))
            @compileError("F3c1 terminal binding final destinations disappeared");
        const Binding = @FieldType(
            pump.ExternalRxTurnScratch,
            "control_semantic_terminal_binding",
        );
        for (.{
            "saved_self_addr",
            "storage_addr",
            "lease_addr",
            "owner_incarnation",
            "operation_generation",
            "scratch_addr",
            "scratch_len",
            "turn_generation",
            "terminal_addr",
            "terminal_digest",
            "completed_owner_digest",
            "correlation_digest",
            "parser_seal",
            "drain_evidence_addr",
            "drain_evidence_digest",
            "completed_exception_digest",
            "authority_generation",
            "authority_seal_digest",
            "tx_queue_generation",
            "response_take_addr",
            "response_take_digest",
            "frozen_response_addr",
            "frozen_response_pristine_digest",
            "lifecycle",
            "digest",
        }) |field| if (!@hasField(Binding, field))
            @compileError("F3c1 terminal binding seal field disappeared");
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
    var tokenizer = std.zig.Tokenizer.init(source_z);
    var behavior_tests: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .keyword_test) continue;
        const name = tokenizer.next();
        if (name.tag != .string_literal) continue;
        const literal = source_z[name.loc.start + 1 .. name.loc.end - 1];
        if (std.mem.startsWith(u8, literal, "completed drain ")) behavior_tests += 1;
    }
    if (behavior_tests < 9)
        return error.F3c1BehaviorGateEmpty;
}
