//! L2 session core 파사드. **OS-중립** 세션 로직을 담는다 — 현재는 입력/재정렬 수학(input_math). 후속 슬라이스가
//! workspace 모델·직렬화·복원, split/tab/pane 모델·연산, IME 결정을 platform/macos/app_dev_session에서 마저
//! 추출한다(docs/layering-and-portability.md §3 — 2차 추출). chrome(L3)이 props로 읽고 platform(L4)이 구현/
//! 투영한다. 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 새지 않는다 — tests/boundary/imports.zig가 강제.

pub const input_math = @import("session/input_math.zig");
pub const ime = @import("session/ime.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
