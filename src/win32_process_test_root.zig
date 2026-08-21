//! `win32_process.zig` **단독 테스트 아티팩트의 모듈 루트**.
//!
//! 그 파일을 직접 루트로 걸면 컴파일이 안 된다 — 루트의 디렉터리가 곧 **모듈 경로**라
//! `src/platform/windows/` 가 되고, 그 파일이 쓰는 `../../path_shape.zig`·
//! `../../pty/windows_spawn.zig` 가 모듈 밖이 된다("import of file outside module path").
//!
//! `maru.zig` 안에서는 같은 상대 경로가 잘 도는데, 그때는 모듈 경로가 `src/` 라서다. 그래서 루트를
//! `src/` 로 올리는 이 얇은 파일 하나면 족하다. **모듈을 따로 만들어 붙이는 길은 안 쓴다** —
//! `path_shape` 가 한 컴파일 안에 두 벌 생겨 타입 동일성이 깨진다.
//!
//! **CI 가 이 결함을 못 잡았다.** 그 아티팩트는 `build.zig` 가 Windows 호스트에서만 거는데
//! (`kernel32` 를 직접 부른다) CI 는 macOS 라 "시끄럽게 건너뛰기" 만 하고 지나갔다. 즉 이 자리는
//! **Windows 호스트에서 `zig build test` 를 돌려야만** 검증된다.

comptime {
    _ = @import("platform/windows/win32_process.zig");
}
