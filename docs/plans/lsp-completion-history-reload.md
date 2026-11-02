# 자동완성 대기 중 다시 읽기와 Undo/Redo

상태: 집중 및 전체 로컬 회귀 검증 통과.

## 계약과 가설

실제 외부 파일 다시 읽기와 Undo/Redo는 편집 경로를 거쳐 기존 자동완성의 위치와 대기를 갱신한다.
이 경로가 직접 입력과 동일하게 pending Enter를 취소하고 이전 prefetch의 import를 막는지 검증한다.
목록 대기 중의 정상 접두사 갱신은 유지하며, 오래된 응답으로 문서나 이력을 덮지 않아야 한다.

## 재현 순서

COMPSTALL/RESOLVESTALL의 실제 primary 서버를 사용한다. 목록 대기·표시된 목록·prefetch·pending
Enter를 구분한다. 디스크를 바꾸고 실제 confirmReload를 호출하거나 실제 history Undo/Redo를 호출한다.
이전 positive/null 응답을 전달한 전후의 본문·선택·이력·디스크 bytes와 fresh 요청의 정상 확정을 대조한다.
문서 identity/revision/epoch는 테스트에서 바꾸지 않는다. 직접 응답은 OS/HID/서버 타이밍 증거와 구분한다.

## 적대적 조건

- 다시 읽기: 네 단계별 positive/null, 8조건.
- Undo: 네 단계별 positive/null, 8조건.
- Redo: 네 단계별 positive/null, 8조건.
- 각 조건에서 새 요청의 정상 확정·Undo와 실제 disk bytes를 대조한다.

재현된 결함만 수정한다. 기존 L2 계약과 공통 편집 알림을 재사용하고 새 정책이 필요하면 먼저 보고한다.
원시 실패·최종 로그와 조건별 관측은 저장소 밖에 보존한다. 제품 경로 검증은 실제 파일/네이티브 controller
범위이며 실제 OS 패널·HID·픽셀 검증을 주장하지 않는다.

## 집중 결과

세 행동 검사 안의 24조건과 초기화 4개, 합계 7개가 Debug에서 통과했다.
기존 제품 코드의 공통 편집 알림이 prefetch를 해제하고 pending Enter를 취소했다.
이전 positive/null 전달 전후 본문·선택·Undo/Redo가 같았고 새 요청은 정상 확정됐다.
제품 코드는 변경하지 않았다. `test-editor-completion-history`가 이 회귀 경로를 고정한다.

Debug/ReleaseFast 집중 7개·전체 자동완성 52개가 통과했다. Debug의 전체 경계·문서
링크·좌표 검사도 통과했다. 선행 PR 머지 후 최신 main에 리베이스하고 같은 검사를
모두 재실행해 통과했다. 원격 CI·머지와 로컬 결과는 구분한다.
