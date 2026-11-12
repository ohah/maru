//! 웹 OSR sidecar 중 CEF 를 모르는 부분의 시험 입구(W1b·W1c·W2) — 명령 상자·명령 처리·브라우저 목록·제목 조절·링 알림 검사·링 알림 권리·대화상자 표(W5a)·콘솔 조절(W9c①)·네트워크 문(W9d①)·본문 기록의 표와 보내는 줄(W9d②)·요청 막기의 표·서비스 워커 길 판정·Network 도메인 주인(W9d③)·사용자 이동의 예외 표·가짜 응답의 표(W9d④)·기기 흉내의 명령 열과 위치 한 칸(W9e①). 링 시험은 실제 mach·IOSurface 를 쓴다(CEF 는 안 쓴다). CEF SDK 없이 기본 `zig build test`
//! 에서 돈다(build/web_sidecar.zig 가 시험 수를 잠근다).

test {
    _ = @import("inbox.zig");
    _ = @import("dispatch.zig");
    _ = @import("registry.zig");
    _ = @import("title_gate.zig");
    _ = @import("ring_receiver.zig");
    _ = @import("ring_producer.zig");
    _ = @import("input_map.zig");
    _ = @import("dialog_table.zig");
    _ = @import("unsandboxed_policy.zig");
    _ = @import("datalist_page.zig");
    _ = @import("devtools_table.zig");
    _ = @import("console_gate.zig");
    _ = @import("net_gate.zig");
    _ = @import("net_body_table.zig");
    _ = @import("net_body_sw.zig");
    _ = @import("out_queue.zig");
    _ = @import("net_block_table.zig");
    _ = @import("sw_share.zig");
    _ = @import("net_domain.zig");
    _ = @import("net_block_review_tests.zig");
    _ = @import("net_block_review_b4_tests.zig"); // W9d③ 4 차 검증 B4 탐침
    _ = @import("net_block_review_a5_tests.zig"); // W9d③ 5 차 검증 A5 탐침
    _ = @import("net_block_review_a6_tests.zig"); // W9d③ 6 차 검증 A6 탐침
    _ = @import("net_block_review_a7_tests.zig"); // W9d③ 7 차 검증 A7 탐침
    _ = @import("nav_exempt.zig"); // W9d④ Q2 사람 입력 창
    _ = @import("net_mock_table.zig"); // W9d④ 가짜 규칙 묶음·본문 덩어리
    _ = @import("emu_plan.zig"); // W9e① 기기 흉내 계획
    _ = @import("geo_slot.zig"); // W9e① 위치 한 칸
}
