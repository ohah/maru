//! CLI 서브커맨드 구현 모듈(facade barrel).
//!
//! `main.zig`는 얇은 디스패처로 두고, 실질 로직(인자 파싱·셸 스크립트·exec argv 조립처럼 테스트
//! 가능한 부분)은 여기 하위 모듈에 둔다 — "파일도 목적별로 나눈다"(docs/project-rules.md). 모듈:
//! `ssh`(원격 terminfo 전파), `install`(maru CLI를 PATH에 설치), `terminfo`(로컬 terminfo 캐시 관리).
//! 구조는 docs/project-structure.md의 `src/cli/` 항목을 단일 출처로 둔다.
pub const ssh = @import("cli/ssh.zig");
pub const install = @import("cli/install.zig");
pub const terminfo = @import("cli/terminfo.zig");

test {
    // 하위 모듈을 참조해 `zig build test`가 그 안의 test 블록을 수집하게 한다 — barrel 관례.
    @import("std").testing.refAllDecls(@This());
}
