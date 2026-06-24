//! L2 session core 파사드. **OS-중립** 세션 로직을 담는다 — 입력/재정렬 수학(input_math)·IME 판정(ime)·
//! agent transcript 상태(agent_transcript)·세션 모델(session_model: Term/Pane/Tab/PaneTree + workspace 트리
//! 변환 + pane hit-test). S2로 세션 모델을 platform/macos/app_session에서 이동 완료(docs/layering-and-portability.md
//! §3.1 — 2차 추출). 남은 src/app 중립 모델(surface 등)을 마저 모으는 정리는 §3.2(3차 추출, 계획). chrome(L3)이
//! props로 읽고 platform(L4)이 구현/투영한다. 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 새지 않는다
//! — tests/boundary/imports.zig가 강제.

pub const input_math = @import("session/input_math.zig");
pub const ime = @import("session/ime.zig");
pub const agent_transcript = @import("session/agent_transcript.zig");
pub const session_model = @import("session/session_model.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
