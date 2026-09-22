//! **제어 수납은 타입으로만 한다** — `ControlAdmissionSpec` 에 `request` 가 있고 `payload` 는
//! 없다(날 JSON 수납이 돌아오면 컴파일에서 죽는다). 세운 spec 이 canonical 인지도 본다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3c0**.
//!
//! Compile-time filtered Zig tests may legally select zero tests. This executable keeps the gate
//! non-empty and checks the public typed admission/codec shape even if a component test is renamed.

const pump = @import("client_external_pump");

pub fn main() !void {
    comptime {
        if (!@hasField(pump.ControlAdmissionSpec, "request"))
            @compileError("F3c0 typed control request field disappeared");
        if (@hasField(pump.ControlAdmissionSpec, "payload"))
            @compileError("F3c0 raw JSON admission capability returned");
    }

    const spec = pump.ControlAdmissionSpec{
        .request = .{ .resize = .{
            .stream_id = 7,
            .cols = 80,
            .rows = 24,
            .client_sequence = 11,
        } },
        .expected_controller_generation = 13,
    };
    if (!spec.request.isCanonical()) return error.TypedContractDrift;
}
