# 위치 검색의 실제 서버 종료·재시작 검증

상태: 실제 프로세스 검증 추가 및 최종 로컬 검사 통과. 제품 결함은 발견하지 않았다.

참조·구현·타입 정의·선언 검색의 대기·예약·게시 결과를 실제 fake LSP 종료와 재시작으로
검증한다. 위치 검색은 시그니처와 달리 대기가 새 명령을 막지 않는다. 따라서 대기 필드가
남는 것만으로 결함이라고 판단하거나 새 취소 정책을 만들지 않고 실제 재검색·안내·탐색을 본다.

네 종류마다 응답 대기 중 primary 종료, 재시도 예약 중 primary 종료, 게시 결과를 둔 종료,
다른 root primary 종료, 대기 중 LSP 끄기/켜기, 예약 중 끄기/켜기를 대조한다. 종료 PID는
각 fixture가 소유한 프로세스에서만 얻는다. 다른 root의 종료는 유효한 대기를 보존해야 한다.

종료 후 ready 조회가 거절하는 동안 요청을 전송하지 않아야 한다. 예약 시한이 먼저 오면
기존 정책대로 해당 검색 종류의 안내 한 번으로 끝난다. backoff를 명시적으로 당겨 다른 PID가
ready가 된 뒤 새 명령과 실제 응답·정상 picker를 확인한다. 같은 Client의 이전 seq에 대한
positive/null/재시도 callback 재생은 별도 부정 대조이며 죽은 프로세스의 실제 전송이라고
설명하지 않는다. 해제된 Client 포인터는 재사용하지 않는다.

실제 파일 bytes·본문·Undo, 게시 결과의 독립 수명과 불필요한 탐색·안내를 관측한다.
실제 종료·wire 응답, 직접 callback, 시험 시계 seam을 구분한다. SDK·HID·픽셀 검증은 별도다.
재현한 제품 결함만 수정하고, 발견하지 않으면 회귀 검사와 문서만 보강한다.

집중 gate의 Debug/ReleaseFast, 기존 재시도·읽기 원본 검사, 문서·전체 경계를 실행한다.
원시 로그와 조건 관측은 저장소 밖 `~/Library/Caches/maru-verification/location-server-*.log`와
JSON에 보존한다.

## 결과

Debug/ReleaseFast의 네 종류 × 여섯 상황, 24조건이 모두 통과했다. 각 모드에서 재시작·
재활성화 20조건은 실제 원본 PID 교체를, 다른 root 종료 4조건은 현재 PID 보존을 확인했다.
fixture 소유 PID의 SIGKILL 16조건과 LSP 끄기/켜기 8조건을 구분한다. 새 서버의 실제
wire 응답이 정상 결과를 게시했고, 서버가 없는 동안 게시 결과를 고르는 기존 동작도 보존됐다.

대기가 남아도 새 명령은 정상 전송된다. 같은 Client가 유지되는 조건에서 새 요청을 낸 뒤
옛 seq의 positive/null/재시도 callback을 직접 재생해 새 대기와 결과를 보존했다.
재활성화로 해제한 Client 포인터는 재생하지 않았다. 예약은 서버 부재 시 기존 종류 안내로
끝났다. 원본 디스크는 그대로이며, marker를 의도적으로 제거한 이후의 본문·Undo도 보존했다.

새 명령에서도 옛 waiting_seq를 유지하는 변이는 실제 다른 PID가 ready된 뒤 네 행동 검사
모두 실패했다. 컴파일 오류가 아닌 요청 수명 검사의 실패다. 원본 소스와 SHA를 복구한 뒤
최종 Debug/ReleaseFast를 실행했다. 제품 코드·상태·ABI·재시도 정책을 수정하지 않았다.

최종 두 모드에서 집중 8개·기존 재시도 8개·읽기 원본 15개·결과 종류 8개가 통과했다.
각 gate의 모듈 초기화 검사를 고유 테스트 합계로 더하지 않는다. Debug의 전체 경계·문서
링크/좌표와 Zig 포맷·diff 검사도 통과했다. 원격 CI·머지는 로컬 검사와 별도로 확인한다.

원시 결과는 `location-server-final-debug.log`·`location-server-final-releasefast.log`,
조건별 PID·안내와 소스 SHA는 `location-server-final-cases.json`, 변이 실패와 복원은
`location-server-mutant-old-seq.log`·`location-server-mutant-old-seq.json`에 보존한다.
