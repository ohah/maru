# 심볼 rename 응답의 출처와 문서 수명

상태: 구현·컨트롤러 회귀와 순수 판정 검증 완료. PR CI는 별도 확인.

서버마다 rename seq를 따로 생성하지만 전역 rename 대기는 seq만 비교한다. 라우터가 응답의 Client를
버리므로 서로 다른 서버의 같은 번호 응답이 현재 대기를 해제하거나 다른 편집을 적용할 수 있다.
응답 출처를 끝까지 전달하고, 요청한 surface·문서 객체·저장 대상 epoch를 함께 붙인다. Client 배열의
재할당으로 포인터가 움직이므로 요청 당시 Client 포인터를 저장하지 않고 응답 시 문서의 현재 primary
Client와 실제 응답 Client를 비교한다. seq와 소유 수명 판정은 중립 순수 잎에 두고 L4는 identity만 만든다.
외부 Client의 응답은 대기/notice/편집에 손대지 않는다. 소유 문서가 닫히거나 Save As된 응답은 적용하지
않고 대기를 정리한다. 문서 revision과 다중 파일 적용 검증은 기존 WorkspaceEdit 계약을 유지한다.

기존 RNM/WorkspaceEdit 제품 회귀를 재실행하고 다른 Client의 같은 seq 오류/정상 응답, 올바른 Client,
낡은 seq·문서 수명·중립 판정과 정상 대조를 확인한다. UI는 바꾸지 않으며 실제 OS/실제 SDK/네트워크
재현으로 과장하지 않고 컨트롤러 주입과 기존 독립 프로세스 fixture를 구분한다. 상태 크기 변경은 ABI를
같이 올린다. 새 런타임 의존성이나 프로토콜/UX 정책 변경은 없다.


## 결과와 증거 경계

원래 라우터가 출처 Client를 버렸고, 처리기의 대조는 waiting/seq뿐이었다. RNM12는 실제 독립 fake 서버로
요청을 보낸 뒤 같은 서버/root/process 메타데이터를 가진 별도 Client 값을 만들어 같은 seq의 성공/오류
응답을 컨트롤러에 주입한다. 수정 뒤 이 응답은 대기/notice/본문을 바꾸지 않는다. 올바른 Client의 오류는
정상 정산되고 중복/낡은 seq는 무시된다. 저장 대상 epoch 변경 응답도 적용하지 않는다. 두 실제 서버의
동시 네트워크 경쟁을 재현한 증거는 아니며 실제 OS/새 SDK 검증으로 세지 않는다.

기존 RNM/WorkspaceEdit 21개 테스트와 순수 소유 판정이 통과했다. 다중 파일 저장/Undo, stale/revision,
root 밖·파일 연산·겹침·메모리 부족·공유 뷰·입력 owner 경계와 새 응답 출처/수명의 20개 이상 서로 다른
가설을 정상 대조와 함께 검사했다. `~/Library/Caches/maru-verification/rename-response-origin-hostile.json`에
조건과 gate를 기록한다. 순수 판정의 출처·waiting·seq·수명·owner 누락 방어를 각각 무력화한 컴파일 가능한
Zig 사본 다섯은 모두 단언이 실패했고 원본 전후 대조군은 통과했다. 사본/로그는 `...-mutations`에 둔다.

상태 크기 변경에 따라 ABI는 248이다. 전체 경계 검사에서 기존 CR6d 판정자의 247 고정 기대값이 실패한
원인을 확인하고 C 헤더·Zig ABI test·해당 판정자·trust picker ABI 변이 도구를 248에 동기화했다.
수정한 CR6d 판정자 네 테스트는 재실행해 통과했다. 이전 전체 검사 실패를 통과로 덮어쓰지 않고
`...-boundaries.log`에 보존한다. 전체 집계의 최종 통과는 PR CI에서 별도로 확인한다.
제품 rename/WorkspaceEdit 회귀 로그는 `...-origin-final.log`, 순수 검사는 `...-pure.log`, ABI 판정자는
`...-abi-boundary.log`, host 빌드는 `...-host-build.log`이며 모두 같은 상위 캐시 디렉터리에 있다.
UI 배치·렌더·입력 경로는 바꾸지 않는다. 실제 GUI 증거를 새로 실행했다고 주장하지 않는다.
