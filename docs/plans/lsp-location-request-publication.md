# 전송 실패한 위치 검색과 기존 응답 수명

상태: 원래 응답 유실 재현·수정 및 최종 로컬 검사 통과. 원격 CI·머지는 별도로 확인한다.

위치 검색은 요청 JSON 할당이나 전송에 실패하면 false를 반환한다. 새 요청이 실제로
나가지 않았는데 waiting_kind만 바뀌면 기존 요청의 응답이 종류 불일치로 버려질 수 있다.
실제 fake LSP의 기존 요청을 REFSTALL로 보류하고, 다음 명령의 메시지 할당을 실패시켜
기존 positive/null 응답과 새 정상 요청을 대조한다.

수정은 요청할 종류를 request 인자로 전달하고 전송 성공 뒤 seq·owner와 같은 경계에서
waiting_kind를 게시한다. 새 상태·ABI 필드는 추가하지 않는다. 명령을 다시 부르면 재시도
예약과 횟수를 초기화하는 기존 정책은 유지한다. 실패한 명령의 종류로 기존 대기를 설명하지
않는 것이 수정 범위이며 재시도 정책 변경은 아니다.

네 기존 종류 × 네 새 종류 × 기존 positive/null/예약 조건을 구분한다. 같은 종류의 실패도
정상 대조에 포함한다. 실제 native 명령·fake 요청·FailingAllocator와 직접 callback을 사용하고
본문·디스크 bytes·Undo·원본 대기와 다음 정상 결과/선택을 검사한다. OS/HID/픽셀 검증은 아니다.

집중 Debug/ReleaseFast, 기존 재시도·서버 재시작·결과 종류와 읽기 원본, ABI 라이브러리·
문서·전체 경계로 검증한다. 원시 로그와 조건별 증거는 저장소 밖
`~/Library/Caches/maru-verification/location-request-*.log`와 JSON에 보존한다.

## 발견과 수정

기존 요청을 실제 fake LSP에 보내고 새 명령에서만 할당을 실패시켰다. 실제 전송 수·기존
seq·원본은 그대로인데 다른 새 종류가 waiting_kind를 덮어썼다. 원래 positive 응답을
실제 onClientResponse로 전달하면 종류 불일치로 버려져 대기가 끝나지 않고 결과가 열리지
않았다. 네 종류 모두에서 재현했다. 단순 필드 비교의 최초 실패와 실제 응답 유실 실패는
각각 before·response-before 로그에 보존한다.

requestLocations 성공 뒤에만 요청 종류를 게시하도록 고쳤다. 새 수동 명령이 예약과 횟수를
초기화하는 기존 정책은 유지했다. 새 상태·ABI 필드가 없어 버전 253은 그대로다.
응답 guard는 완화하지 않았고, 파일·Undo나 탐색 정책을 바꾸지 않았다.

수정 후 48조건이 집중 검사와 최종 Debug/ReleaseFast 모두 통과했다. 같은 종류 12조건을
정상 대조로 포함한다. 기존 positive는 picker·native Enter 이동을, null은 원래 종류의
안내를 확인했다. 예약 조건은 실패한 수동 명령에서도 예약/횟수 reset을 유지했다. 모든
조건에서 다음 새 종류의 정상 요청·결과·offset 4 이동과 실제 파일·본문·Undo를 보존했다.

최종 두 모드에서 집중 8개·재시도 8개·서버 재시작 8개·결과 종류 8개·읽기 원본 15개가
통과했다. 각 gate의 모듈 초기화를 고유 테스트 합계로 더하지 않는다. Debug의 ABI
라이브러리 빌드·전체 경계·문서 링크/좌표와 Zig 포맷·diff 검사도 통과했다.

원시 로그는 `location-request-response-before.log`, `location-request-after.log`,
`location-request-final-debug.log`·`location-request-final-releasefast.log`, 조건별 실제
관측과 최종 소스 SHA는 `location-request-final-cases.json`에 보존한다. 실제 서버로
보낸 요청·직접 응답 순서 제어·allocator 실패 주입을 구분하며 전송 장치 오류나 모든
실제 SDK의 전수 검증으로 확대하지 않는다.
