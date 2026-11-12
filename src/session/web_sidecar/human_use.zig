//! maru 가 sidecar 에 보낸 메시지 가운데 **사람이 그 탭을 쓴 것**의 가름(W9e② — 사용자 결정 2 「trace 중 사람이 쓰면 버림」·「사람이 몰면 CPU·
//! 네트워크 조건을 푼다」). maru 와 sidecar 가 **같은 파일**을 쓴다: sidecar 는 받은 메시지로 trace 를 버리고 조건을 풀고, maru 는 보내는 순간 제
//! 설정에서도 조건을 푼다(W9e② 적대 검증 12 회차 — sidecar 가 풀고 그 알림을 maru 가 읽기 전에 죽으면, 다시 뜬 sidecar 에 maru 가 옛 설정을 재생해
//! 사람이 쓰던 탭에 조건이 다시 걸렸다; 두 쪽이 같은 가름으로 따로 풀면 그 창이 없다). 에이전트의 입력은 DevTools 길(`Input.*`)이라 이 메시지를
//! 지나지 않는다.
//!
//! 시험(sidecar 순수 시험 `nav_exempt.zig` — 이 파일은 그 러너가 닿는 모듈 밖이다)이 증명하는 것: 몸짓(누름·뗌·키(뗌 제외)·IME 확정), 쓴 것(몸짓 + 굴림·IME 조합·끝내기·편집 명령·놓음), 건드린 것(쓴 것 + 사람의 이동 —
//! 주소창의 `navigate{user}`·뒤로·앞으로·새로고침의 `nav_action{user}`, 멈춤은 아니다 — 그리고 사람의 답: 대화상자·파일·권한의 `{user}`·제안 목록
//! 고르기·알림 누름); 포인터 옮김·떠남·끌기 들어옴/위/나감·키 뗌·에이전트의 이동·에이전트와 maru 의 답(`user` 거짓)은 아니다.

const msg = @import("message.zig");

const BrowserId = msg.BrowserId;

/// 사람 입력 중 **몸짓**(W9d④ Q2 — 누름·뗌·키(뗌 제외)·IME 확정)의 탭. 그 뒤 창 안의 렌더러 이동을 사람의 것으로 묶는 데 쓴다(옮김·휠·떠남은
/// 몸짓을 만들지 않는다 — Chromium 의 사용자 활성화와 같다).
pub fn gestureOf(m: msg.Message) ?BrowserId {
    return switch (m) {
        .mouse => |v| if (v.kind == .down or v.kind == .up) v.browser else null,
        .key => |v| if (v.kind != .up) v.browser else null,
        .ime_commit_text => |v| v.browser,
        else => null,
    };
}

/// 사람 입력 중 **그 탭을 쓴 것** — 몸짓에 더해 굴림·IME 조합·IME 끝내기(조합한 글을 확정한다 — maru 는 조합 중일 때만 보낸다)·편집
/// 명령(⌘A·⌘V·⌘Z 등)·끌어 놓기(놓음)(적대 검증 3 회차 A3-1). 포인터 옮김·떠남·끌기 들어옴/위/나감은 지켜보는 일이라 빼다.
pub fn useOf(m: msg.Message) ?BrowserId {
    if (gestureOf(m)) |b| return b;
    return switch (m) {
        .wheel => |v| v.browser,
        .ime_set_composition => |v| v.browser,
        .ime_finish_composing => |v| v.browser,
        .edit_command => |v| v.browser,
        .drag_target => |v| if (v.kind == .drop) v.browser else null,
        else => null,
    };
}

/// 사람이 그 탭을 **건드렸다**(trace 를 버리고 조건을 푼다) — 쓴 것에 더해 사람의 이동(주소창 `navigate{user}`, 뒤로·앞으로·새로고침
/// `nav_action{user}` — 멈춤은 문서를 바꾸지 않는다), 그리고 사람의 **답**(W9e② 적대 검증 v20c N3 — 대화상자(alert·confirm·prompt·beforeunload)·
/// 파일 고름·권한의 sheet 답 `{user}`, 제안 목록 고르기, maru 알림 누름): prompt 에 사람이 친 글이 페이지로 가고, 답이 페이지를 다시 돌린다 —
/// 사용자 결정 2(사람이 쓰면 trace 를 버린다)·7(사람이 몰면 조건을 푼다). 에이전트의 `browser.handleDialog`·maru 의 자동 답은 `user` 가 거짓이다.
pub fn touchOf(m: msg.Message) ?BrowserId {
    if (useOf(m)) |b| return b;
    return switch (m) {
        .navigate => |v| if (v.user) v.browser else null,
        .nav_action => |v| if (v.user and v.action != .stop) v.browser else null,
        .dialog_reply => |v| if (v.user) v.browser else null,
        .file_dialog_reply => |v| if (v.user) v.browser else null,
        .permission_reply => |v| if (v.user) v.browser else null,
        // 사람만 낸다(maru 의 제안 목록 창·알림 — 에이전트에게는 그 길이 없다).
        .datalist_pick => |v| v.browser,
        .web_notification_click => |v| v.browser,
        else => null,
    };
}
