# 실제 IME 전환·peer 닫기 검증

`verification.json`은 동일 runner의 전환/닫기 각각 5회와 앱·제품 사본 SHA를 묶는다.
15개 실제 앱 프로세스에서 전환 구간 callback arrival은 0건이었다. 늦은 OS 콜백은 재현하지 못했다.
그 콜백에 대한 안전성·처리 완료를 주장하지 않는다. 제품 입력 정책/owner 구조는 변경하지 않았다.

`close-controls.json`은 HID Cmd+W를 포커스 이동으로 바꾼 실제 앱이 뷰 둘을 남겨 실패하고,
기본과 같은 close_focused를 명시한 앱은 통과한 결과다. 분석기의 실행 변이 6개는 실패하고
동등 구현 2개는 통과했다. `mutation_audit.py <새 빈 디렉터리>`로 재실행할 수 있다.
PNG는 PR 본문에만 첨부하며 저장소에는 실행 JSON·로그·SHA를 남긴다.
