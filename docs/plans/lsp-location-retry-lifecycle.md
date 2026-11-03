# 위치 검색 재시도 수명 검증

상태: 회귀 검증 추가 및 최종 Debug/ReleaseFast·전체 경계 검사 통과. 제품 결함은 발견하지 않았다.

참조·구현·타입 정의·선언 검색의 기존 400ms 간격·8회 상한을 실제 host 진입점에서
확인한다. 이번 범위는 새 정책을 만드는 일이 아니라 기존 계약의 회귀 검증이다.

네 검색 종류마다 예약 시각 전/후, 재전송 뒤 중복 tick, 상한 소진, 재시도 불가 오류,
새 종류의 명령으로 교체, 실제 다른 문서 활성화의 여섯 조건을 대조한다. 마지막 조건은
기존 원본 정책을 유지하며 상대 문서로 요청이 이동하지 않는지 확인한다. 정상 응답은
실제 picker 게시로 확인하고 파일 bytes·Undo·불필요한 탐색과 안내도 검사한다.

실제 fake LSP의 ready 상태에서 요청을 전송하되 `REFSTALL`로 응답을 보류하고 callback을
직접 전달해 순서를 고정한다. 시한은 명시적 clock seam으로 앞당기므로 벽시계 지연이나
실제 OS 입력기·HID·픽셀 증거가 아니다. 결함을 재현하면 원인과 수정 범위를 별도로 남긴다.

집중 gate를 macOS CI에 등록하고 Debug/ReleaseFast 및 기존 읽기 원본·결과 종류 검사를
실행한다. 문서 링크·포맷·전체 경계도 확인한다. 원시 로그는 저장소 밖
`~/Library/Caches/maru-verification/location-retry-*.log`에 보존한다.

## 확인한 결과

네 검색 종류 × 여섯 조건, 총 24개의 서로 다른 조건이 Debug/ReleaseFast 모두 통과했다.
행동 4개와 모듈 초기화 4개를 합친 집중 gate는 8개이며, 기존 읽기 원본 15개와
결과 종류 8개도 두 모드에서 통과했다. 실제 파일 bytes·Undo·불필요한 탐색/안내와
새 대기 보존을 확인했다. 상대 문서 준비가 tick을 돌릴 수 있어 미래 시한으로 고정한 뒤
명시적으로 시한을 당겨 원본 전환의 취소 경계만 판정한다.

제품의 `st.retries < max_retries`를 일시적으로 `<=`로 바꾸면 네 종류 모두
`expected 8, found 9`로 거절한다. 컴파일 실패가 아닌 실제 행동 검사의 실패이며,
원본 소스를 복구한 뒤 최종 Debug/ReleaseFast를 다시 실행했다. 제품 재시도 정책·
상태·ABI 253은 바꾸지 않았다. 제품 결함을 발견한 PR로 설명하지 않는다.

Debug의 문서 링크·좌표·전체 `check-boundaries`와 Zig 포맷·diff 검사가 통과했다.
최종 원시 로그는 `location-retry-final-debug.log`·`location-retry-final-releasefast.log`,
조건별 실제 관측은 `location-retry-final-cases.json`, 변이 실패/복구는
`location-retry-mutant-limit.log`·`location-retry-mutant-limit.json`이다.
로컬 통과와 원격 CI·머지 완료는 별도로 확인한다.
