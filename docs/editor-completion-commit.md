# 자동완성 resolve의 원자적 확정

2026-10-27 사용자 승인으로 §8.2g-b의 300ms 뒤 부분 확정을 제거했다.
서버 초기 분석이 느려도 이름만 먼저 들어가 import가 빠지는 결과를 만들지 않는다.

## 계약

- 이미 해결된 항목은 기존처럼 즉시 적용한다. 미해결 항목은 Enter/Tab/목록 클릭 때
  선택 항목과 resolve seq, surface·문서 identity·revision·저장 대상 epoch·primary/extra 선택을 고정한다.
- 원문과 Undo는 응답이 올 때까지 유지한다. 300ms는 적용 또는 취소의 경계가 아니다.
- 같은 요청의 정상 응답이 최종 5초 시한 전에 오고 문맥이 같을 때만 이름과
  additionalTextEdits를 기존 `applyEditAsOneWithUndo` 하나로 적용한다.
- 문서 편집, revision/선택/주인 변경, Escape·다른 키·목록 재선택, 오류/null 응답,
  잘못된 추가 편집, 전송/스냅샷 할당 실패 또는 최종 시한에는 적용하지 않는다.
  대기 확정의 편집 계획이 추가 편집 일부를 버려야 하는 경우도 완성 전체를 취소한다.
- Save As처럼 본문 revision을 바꾸지 않고 대상을 바꾸는 경우도 기존 `save_target_epoch`로 거절한다.
- 사용자 추가 입력은 그대로 처리한다. 취소한 Enter는 뒤늦은 응답으로 살아나지 않는다.
  새 입력이 새 자동완성 요청을 만드는 것은 별개다. 중복 Enter/Tab은 시한을 갱신하지 않는다.
- 순서가 다른 seq의 응답은 현재 대기를 끝내지 않는다. 같은 seq도 이미 취소했다면 무시한다.
- 목록과 resolve 응답은 seq뿐 아니라 해당 문서의 primary client 연결도 일치해야 한다.
  다른 서버가 같은 번호를 써도 현재 대기를 지우거나 편집을 적용하지 않는다. 위치 인코딩은 그 연결에서 받는다.
- 미리 보내는 resolve가 전송/할당 실패했다고 항목을 해결됨으로 표시하지 않는다.
  다음 선택/Enter에서 다시 요청하며, 그 요청도 실패하면 원문을 보존하고 취소한다.
- 팔레트·찾기 오버레이 아래에서도 tick이 시한을 검사한다. 해당 문서가 보이지 않으면 취소한다.

`src/session/editor/ops/completion_ops.zig`의 `pendingDecision`이 문맥/시한을 판정한다.
macOS 어댑터는 호스트 문맥과 소유한 extra 선택 사본을 넘기고 요청·적용·해제를 수행한다.
서버의 분석 시각을 고정하거나 서버 전체 준비를 기다린다는 계약이 아니다.

## 원인과 정책 선택

실제 Rust 조사에서는 완성 목록 반환 직후 cargo metadata가 끝나 크레이트 그래프를
재구성했고, resolve가 `CompletionContext::new → file_to_def`의 표준 라이브러리 분석을
기다렸다. 기존 300ms 확정은 문서를 바꿔 서버 분석 취소/재시도까지 유발했다.
지연 응답 자체는 정상 import 편집을 포함했다. 새 계약은 그 경쟁이 부분 편집으로
이어지는 경로를 없앤다. 시한만 늘리고 부분 확정을 유지한 수정이 아니다.

## 검증

- `zig build test-editor-completion-contract`: L2 문맥·시간 경계와 선택 필드별 거절.
- `zig build test-editor-completion`: 기존 완성/Undo와 `CMPAT`의 늦은 응답·다른 seq·
  중복 Enter·Escape·이동·시한·revision·선택·오류·hide·항목 유효성 대조.
- `zig build test-editor-completion-overlays`: 팔레트/찾기 중 정상 응답과 시한 뒤 원문 보존.
- `zig build test-editor-completion-send-failure`: prefetch 할당 실패 뒤 Enter의 재요청 성공/실패와 단일 Undo.
- `zig build test-editor-completion-origin`: 다른 primary client의 같은 seq가 목록 대기와 확정을 가로채지 못함.
- 위 명령은 mise Zig로 실행하며 `-Doptimize=ReleaseFast`도 지원한다.
- 실제 SDK `multi-file` 시나리오는 `accepted_after_resolve`, `accepted_on_timeout`,
  `enter_to_accept_ms`를 기록한다. 지연 사례를 정상 사례와 구분해 보관한다.
- headless AppSession 검증은 물리 GUI/HID·IME·화면 검증과 구분한다.
