//! L2 session core 파사드. **OS-중립** 세션 로직을 담는다 — 입력/재정렬 수학(input_math)·IME 판정(ime)·
//! agent transcript 상태(agent_transcript)·세션 모델(session_model: Term/Pane/Tab/PaneTree + workspace 트리
//! 변환 + pane hit-test). S2(2차)로 세션 모델을, 3차(D1·D2)로 src/app 순수 모델(split_tree·workspace·surface·window·core_command)을
//! session으로 이동 완료 — session→app=0을 check-boundaries 가드로 고정(docs/layering-and-portability.md §3.1·§3.2). chrome(L3)이
//! props로 읽고 platform(L4)이 구현/투영한다. 이 레이어엔 OS 타입(Metal·CoreText·AppKit·PTY)이 새지 않는다
//! — tests/boundary/imports.zig가 강제.

pub const input_math = @import("session/input_math.zig");
pub const layout_math = @import("session/layout_math.zig");
pub const ime = @import("session/ime.zig");
pub const keyhint_hold = @import("session/keyhint_hold.zig"); // 단축키 힌트 홀드 gesture 정책(OS-중립, platform이 alias로 참조)
pub const agent_transcript = @import("session/agent_transcript.zig");
pub const session_model = @import("session/session_model.zig");
pub const split_tree = @import("session/split_tree.zig");
pub const workspace = @import("session/workspace.zig");

// split_tree 헬퍼 re-export(app.zig에서 D1로 이동 — divider·app_session이 쓴다). SplitTree는 leaf-generic이라
// platform이 `session.SplitTree(*Pane)`으로 인스턴스화한다.
pub const SplitTree = split_tree.SplitTree;
pub const SplitDirection = split_tree.SplitDirection;
pub const SplitRect = split_tree.Rect;
pub const splitRect = split_tree.splitRect; // leaf-독립 헬퍼(생성용 a/b rect)
pub const clampRatio = split_tree.clampRatio; // divider 드래그가 layout과 같은 ratio 한도를 쓰게(단일 출처)
pub const surface = @import("session/surface.zig");
pub const window = @import("session/window.zig");
pub const core_command = @import("session/core_command.zig");

// surface/window 헬퍼 re-export(app.zig에서 D2로 이동 — platform이 쓴다).
pub const Surface = surface.Surface;
pub const RestorableSurfaceMetadata = surface.RestorableSurfaceMetadata;
pub const ProcessState = surface.ProcessState;
pub const AppWindow = window.AppWindow;

test {
    @import("std").testing.refAllDecls(@This());
}
