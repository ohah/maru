//! **제어 응답 코덱이 «기대한 종류» 만 받는다** — 맞는 기대 키로는 resync 응답을 풀고,
//! 종류가 다른 키(resize)로 같은 바이트를 주면 `Malformed` 로 거절한다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3c0**.

const std = @import("std");
const codec = @import("control_response_wire");

pub fn main() !void {
    const key = codec.ControlExpectation{ .resync = .{
        .owner_incarnation = 1,
        .origin = .client,
        .recovery_epoch = 2,
    } };
    try codec.decodeResyncResponse(
        std.heap.page_allocator,
        "{\"result\":{\"resync\":true}}",
        key,
    );
    if (codec.decodeResyncResponse(
        std.heap.page_allocator,
        "{\"result\":{\"resync\":true}}",
        .{ .resize = .{ .client_sequence = 1 } },
    )) |_| return error.WrongKindAccepted else |err| if (err != error.Malformed) return err;
}
