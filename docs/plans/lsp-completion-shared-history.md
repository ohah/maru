# 공유 뷰와 다른 문서의 자동완성 편집 격리

상태: 집중 및 최종 로컬 회귀 검증 통과.

## 계약

같은 창의 공유 분할 뷰에서 편집한 결과는 같은 문서의 자동완성에 반영된다.
다른 문서의 다시 읽기·Undo·Redo는 원본 자동완성의 대기·표시·prefetch·pending Enter를
취소하거나 적용 위치를 바꾸지 않는다. 창을 가르는 공유 뷰 이동은 기존 계약 밖이며
이번 작업에서 지원 정책을 변경하지 않는다.

## 재현과 대조

공유 peer에서 실제 디스크 다시 읽기·Undo·Redo를 수행하고 원본 목록/resolve의
positive/null 응답을 전달한다. 네 단계·세 편집·두 결과의 24조건에서 본문·선택·이력,
새 요청 확정/Undo와 실제 disk bytes를 대조한다.

서로 다른 문서에서도 같은 24조건을 대조하며 원본의 정상 확정/Undo와 다른 문서의
본문·선택·이력 보존을 확인한다. 직접 응답과 native controller/파일 관측은 실제
OS/HID/픽셀 검증과 구분한다. 문서 identity/revision/epoch를 임의로 바꾸지 않는다.
기존 보존 helper의 pending 시한 갱신은 명시적 clock seam으로 구분한다.

재현된 결함만 수정한다. 기존 공통 편집 경로와 L2 소유 판정을 유지한다. raw 로그와
조건별 관측은 외부 Library/Caches/maru-verification에 둔다.

## 집중 결과

공유 뷰 24조건과 다른 문서 24조건에서 추가 제품 결함은 재현되지 않았다.
집중 10개(행동 6개·초기화 4개)와 기존 단일 뷰 이력 7개가 Debug에서 통과했다.
공통 재현 helper에 실제 편집 actor를 분리했으며 기존 단일 뷰 검사는 같은 경로를 유지한다.
다른 문서의 null 응답은 정상적인 null 처리 뒤 fresh 요청의 확정/Undo로 대조한다.
제품 코드·ABI·소유 정책은 변경하지 않았다.

최종 Debug/ReleaseFast에서 집중 10개·기존 이력 7개·전체 자동완성 58개가 각각 통과했다.
Debug의 전체 경계·문서 링크·좌표와 포맷 검사도 통과했다. 초기화를 고유 합계로 더하지 않는다.
로컬 결과와 원격 CI·머지는 구분한다. 원시 기록은 외부 `lsp-completion-shared-history-*.log`,
조건별 관측은 `lsp-completion-shared-history-adversarial.json`에 보존한다.
