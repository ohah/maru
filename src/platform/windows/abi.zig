//! Win32/COM **호출 규약 한 자리**(W7 — 계약 §2c 보강).
//!
//! `callconv(.winapi)`는 타깃마다 다른 실제 규약으로 풀린다. Windows에서는 그것이 정답이지만, **다른
//! 타깃에서도 이 파일들의 타입 선언은 의미 분석된다** — 본문은 `builtin.os.tag` 비교로 막혀 있어도
//! extern 구조체의 함수 포인터 타입은 그 게이트 밖이기 때문이다(`main.zig`가 최상위에서 import하는
//! 이유와 짝이다).
//!
//! macOS(arm64)에서 `.winapi`는 `aarch64_aapcs_win`으로 풀리고 LLVM 백엔드가 그것을 거절한다 —
//! 로컬 전체 빌드(`zig build test`)가 그 자리에서 멈춘다. 실제로 그렇게 멈췄다(2026-08-18).
//!
//! 그래서 **Windows가 아니면 `.c`로 접는다.** 그 타깃에서 이 함수 포인터는 **절대 호출되지 않으므로**
//! 규약이 무엇이든 관측되지 않는다 — 관측되지 않는 값을 백엔드가 지원하는 것으로 두어 분석만 통과시킨다.
//! Windows 빌드의 ABI는 그대로다(같은 조건식이 `.winapi`를 준다).

const builtin = @import("builtin");
const std = @import("std");

pub const winapi: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
