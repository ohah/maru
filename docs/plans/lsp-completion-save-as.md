# Save As 중 자동완성 원본 수명

상태: 재현·수정과 최종 로컬 검증 완료.

## 계약과 가설

같은 surface/primary라도 실제 Save As가 성공하면 저장 대상 epoch와 URI가 바뀐다.
목록 응답 또는 prefetch/Enter resolve가 이전 URI를 기준으로 계산됐을 때, 변경 뒤에
그 결과를 표시하거나 import와 함께 확정할 수 있는지 실제 Save As로 확인한다.
취소/실패해 대상이 바뀌지 않았다면 정상 요청은 유지해야 한다.

재현되면 실제 성공한 대상 전환 경계에서 이전 원본의 자동완성 transaction을 기존
cancel로 종료하는 안을 우선 검토한다. callback별 새 상태 필드를 늘리기 전에 모든
뷰의 동일 문서 소유 관계와 기존 target epoch 경계를 확인한다. 순수 소유 판정은 기존
L2 규칙을 사용하며, 새 정책/ABI가 필요하면 근거와 범위를 먼저 보고한다.

경계 확인 결과 adopt 성공 뒤의 문서별 publish loop를 사용한다.
completion.onSaveTargetChanged(session, term)는 같은 waiting_surface만 해제하고,
같은 표시/resolve surface만 hide한다. 다른 문서의 대기를 지우지 않도록 전체 cancel과
구분하며, 동일성은 기존 L2 sourceMatches를 사용한다. 취소/쓰기 실패와 adopt 전에는
호출하지 않는다. 공유 문서의 모든 view/window에 기존 loop가 전달한다. 새 ABI 필드는 없다.

## 검증

COMPSTALL과 RESOLVESTALL, 실제 Save As 완료 대기와 디스크 bytes를 사용한다.
목록 대기·표시된 목록·미해결 prefetch·pending Enter를 구분하고 이전 positive/null 결과,
새 요청과 정상 확정/Undo, 다른 문서와 공유 뷰, Save As 취소/실패를 대조한다.
직접 결과 전달과 native controller/실제 파일 쓰기는 SDK/HID/native panel/pixel과 구분한다.
원시 로그와 적대적 조건은 외부 Library/Caches/maru-verification에 둔다.

## 발견과 대조

수정 전 컴파일된 5개 중 목록 대기 행동 검사가 실패했고 초기화 4개만 통과했다.
단순 대기 잔존과 구분하기 위해 새 URI에 같은 primary가 재결합할 때까지 실제 pump한
대조에서도 이전 URI의 positive가 목록을 열었다. surface/현재 client 검사만으로는 대상
수명이 바뀐 요청을 가릴 수 없었다. 성공한 adopt 뒤의 view loop에서 대상별 대기를 정리했다.

CMPSAVEAS1/2는 목록·표시·prefetch·pending 각각 이전 positive/null과 새 요청/확정/Undo를
검사한다. CMPSAVEAS3은 다른 공유 view에서의 실제 Save As를, CMPSAVEAS4는 취소와
선택 뒤 목적지가 외부에서 생긴 실제 worker 충돌 실패를 대조한다. 실패/cancel은 이전
요청을 유지하고 정상 확정할 수 있다. CMPSAVEAS5는 다른 문서 저장을, CMPSAVEAS6은
A의 표시를 종료하면서 B의 새 목록 대기를 유지하는 혼합 상태를 확인한다.

보존 대조의 pending callback에서는 시한만 갱신하는 명시적 clock seam을 사용한다.
문서 identity/revision/epoch/선택은 바꾸지 않으며 시한 정책 자체는 기존 중립 계약이 검사한다.
성공 후에는 새 경로/epoch와 이전·새 파일 disk bytes, model·Undo/Redo 및 새 URI binding을
각각 대조한다. native panel callback은 actor take/reply로 구동하며 실제 OS 패널 증거가 아니다.

Debug에서 집중 10개(행동 6개, 초기화 4개), 기존 Save As 명령 16개, 전체 completion 49개,
원자적 계약 32개, resolve stop 9개, focused source 9개, pointer source 10개가 통과했다.
ABI 라이브러리·전체 경계·문서 링크/좌표 검사도 통과했다. ReleaseFast에서도 집중 10개,
Save As 명령 16개와 전체 completion 49개가 통과했다. 중복 초기화는 고유 행동 수로 합산하지 않는다.
적대적 조건은 25개이며 새 상태가 없어
ABI는 252다. 원시 실패/보강/최종 로그는 `lsp-completion-save-as-*.log`, 적대적 조건과
정상 대조는 외부 `lsp-completion-save-as-adversarial.json`에 보존한다.
