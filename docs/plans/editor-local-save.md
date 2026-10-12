# 로컬 저장 — 자료 준비·쓰기·완료 분리

2026-10-12 사용자가 승인한 첫 단계다. 기존 저장을 세 단계로 분리하며 현재 호출은 계속 동기다. 준비 객체는 쓰기 성공 뒤에만 완료할 수 있고 완료 시도는 한 번만 소비한다.
비동기 큐·worker·종료/취소 정책은 [실측과 설계 검토](editor-project-replace-performance.md)의 미결 조건을 먼저 구체화한 뒤 연결한다.
이 단계는 UI 응답 지연 개선을 완료했다고 주장하지 않는다.

## 소유권과 호출

- 기존 `saveDocumentGuarded`가 편집기/diff/read-only 판정을 하고 remote·이름 없는 문서는 기존 경로로 보낸다.
- `editor/local_save.zig::Prepared.init`은 저장 bytes와 path를 독립 소유한다. 본문 전문을 한 벌 더 복사하지 않는다.
  `saveBytes`의 BOM prefix 길이로 논리 본문을 구분한다. bytes가 BOM으로 시작한다는 이유만으로 글자를 버리지 않는다.
- `writeBytes(io, path, bytes, expected_disk)`는 AppSession 값·Term·문서 상태를 받지 않는다.
  기존 pinned parent·내용/inode 검사·metadata 복사·sync·swap·후검증을 그대로 사용한다.
  `writeDocumentBytes`의 기존 caller는 이 쓰기 함수를 부르는 호환 입구를 유지한다.
- `finish`는 같은 문서 신원과 경로인 살아 있는 Term에만 결과를 반영한다. 순수 신원 판정은 L2 `ops/save_ops.zig`에 둔다. 공통 문서 신원은 registry가 소유하고 기존 검색 타입은 호환 alias를 유지한다.
  실제 저장한 논리 본문으로 saved hash·백업을 처리하고 raw bytes로 disk hash를 갱신한다.
  LSP 통지는 실제 저장한 본문을 사용하며 기존 marker 안내를 유지한다.
- 기존 저장 caller는 `prepare → write → finish` 사이에 이벤트를 처리하지 않는다. completion 거절은 디스크 쓰기 취소/롤백을 의미하지 않는다.
  완료 신원 검사만으로 Save As/rename/삭제와 이미 반영된 쓰기의 경합을 해결했다고 주장하지 않는다.

## 검증

`mise exec -- zig build test-editor-local-save`의 LSAVE1은 준비 할당 실패의 본문 보존과 준비 후 실제 재편집·원래 snapshot 쓰기·dirty 유지·다음 저장을 확인한다.
LSAVE2는 주소·owner·slot·generation·path의 각 축을 독립 대조한다.
BOM 유무, 바뀐 path의 완료 거절, 기존 CAS의 외부 수정 거절을 함께 검사한다.
`test-editor-project-replace-batch-ui`는 기존 배치의 저장 실패·뒤 파일 계속 저장·저장 재시도·Undo를 검사한다.
둘 다 Debug/ReleaseFast로 실행한다.

`python3 tools/test-editor-local-save-adversarial.py`는 BOM 경계·CAS·완료 대상·dirty 본문·raw disk hash의 결함을
격리 source에 넣어 실제 테스트 실패를 확인하고 정상/복원 대조군도 확인한다. 컴파일 실패를 결함 검출로 인정하지 않는다.

제품 경로는 기존 `tools/editor-project-search-app/run.py --replace-batch-save-retry --disk-files 2 --count 20`으로
충돌·뒤 파일 저장·재시도와 실제 AppKit/Metal 경로를 확인한다. UI 출력은 분리 전과 같은 계약이다.
물리 IME·VoiceOver·비동기 종료·watcher/rename 경합은 이 단계의 실행 검증 범위가 아니다.

추가 회귀 검사에서 기준 main `82ac9cacd`도 이름 없는 문서 고리의 원장 39/134와 실제 컴파일 41/142가 어긋났다.
같은 차이가 분리 후에도 유지됨을 확인하고 원장을 실제 개수로 갱신했으며, 41/142개가 모두 실제 통과하는지 검사했다.
검사를 제거하거나 SKIP을 허용하는 방식으로 우회하지 않았다.

집계 macOS CI에서 기존 LSPB22의 비동기 대기 누락이 드러났다. 첫 서버의 ready만 기다린 뒤
심링크 재판정 확인창이 이미 떠 있다고 가정하던 검사를, 확인창 도착도 별도로 기다리게 고쳤다.
제품의 신뢰 정책은 바꾸지 않으며 새 대상 경로·미실행·거부 기록 검사는 유지한다.
