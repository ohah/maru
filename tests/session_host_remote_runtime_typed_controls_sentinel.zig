//! **RemoteRuntime 의 타입 있는 제어가 사라지지 않는다** — `resize` 와 `requestResync` 가
//! 선언에 남아 있는지 comptime 으로 못 박는다.
//!
//! **왜 실행 파일인가**: 컴파일 타임 필터가 걸린 Zig 테스트는 «0 개를 고르고도» 정상
//! 종료한다. 그래서 필터 게이트는 비어 있어도 초록이다. 이 실행 파일이 그 게이트를
//! 비지 않게 붙들고, 타입 모양이 사라지면 컴파일에서 죽는다.
//!
//! 계획 문서의 단계 라벨로는 **F3c0**.

const remote = @import("remote_runtime");

pub fn main() void {
    comptime {
        if (!@hasDecl(remote.RemoteRuntime, "resize"))
            @compileError("RemoteRuntime resize control disappeared");
        if (!@hasDecl(remote.RemoteRuntime, "requestResync"))
            @compileError("RemoteRuntime resync control disappeared");
    }
}
