# SCM 커밋 메시지 IME 문맥

상태: range 교체·owner·실패 복구 구현, host 및 중립 모델 검증 통과. 실제 입력·후보창 진단과 저장된 원본의 독립 PNG/OCR 재판정 통과.

## 유지할 계약

TextField의 여러 줄 메시지·탭·NFD 원문·선택·caret·시각 행 이동·스크롤과 저장소별 초안을 유지한다.
확정 입력은 기존처럼 CR·금지 C0·DEL·손상 UTF-8을 제거하고 LF와 TAB은 보존한다.
marked 텍스트의 UTF-16 선택은 입력기가 준 원문을 기준으로 유지한다. 필터 결과가 빈 입력은
기존처럼 선택을 지우지 않는 no-op이며, 명시적인 빈 문자열 range 교체는 native 삭제 편집이다.
후보 확정 Return은 개행/커밋으로 재생하지 않는다. 독립 Return 개행과 명시적 커밋 명령의
기존 실행 조건·신뢰 확인·쓰기 경로는 그대로 둔다. IME callback은 Git 작업을 시작하지 않는다.

## 소유와 표시

공유 `text_field_ime.State`를 verbatim으로 사용한다. 저장소 focus·draft restore의 epoch와
활성 surface로 owner를 구분하고 bit 56을 예약한다. 기존 Session Dock low token 범위와 겹치지 않는다.
저장소 A→B→A·blur·도크 숨김/탭 전환·모달·초기화 전·포화는 이전 키와 late proxy callback을
차단한다. 실패한 키는 deep snapshot으로 text·preedit·선택을 복구하고 destination 초안을 덮지 않는다.

확정 입력 위생의 순수 부분은 중립 모듈로 추출해 기존 insert 경로와 native range 경로가 함께 쓴다.
marked 내부 caret은 기존 조합 문자열/랩과 같은 위치를 쓴다. 공용 paint caret 계산을 기존 프로젝트
검색과 SCM 표시가 재사용하며 실제 UTF-16 의미 범위를 grapheme paint snap으로 바꾸지 않는다.
백그라운드 저장소 발견이 현재 편집 중인 다른 저장소의 메시지를 교체하지 않아야 한다.

## 구현과 검증

1. `a😀z` UTF-16 `(1,2)` 교체의 실제 range fallback 결과를 실패 검사로 기록한다.
2. 중립 위생·빈 결과·LF/TAB·NFD·손상 UTF-8·OOM과 내부 caret 표시를 정상 대조군과 확인한다.
3. 서로 다른 20개 이상 host 조건: 범위·selection·cancel·Return/일반 Return·명시적 명령,
   저장소 전환·A→B→A·background discovery·blur/hidden/modal·bootstrap·token 포화·키 OOM·
   부분 실패·stale rollback·긴 여러 줄/내부 caret을 검사한다. guard/range/rollback/key 소비 변이도 확인한다.
4. 기존 SCM 편집·초안·쓰기 경계와 다른 IME 회귀, ABI/Swift·경계·포맷·문서를 검사한다.
5. 격리된 Git fixture에서 실제 두벌식·후보 취소 5회·한자 확정·개행/쓰기 시도 없음·HEAD/index/작업트리
   불변·터미널 복귀·입력 소스 복원과 독립 창/PNG/OCR을 확인한다. 명시적인 커밋은 fixture에서만 검증한다.

픽셀·진단·host 성공을 구분하고 PNG/로그/빌드는 저장소 밖에 둔다. 최종 앱을 고정한 뒤 화면 기록을 확인한다.

## 현재 확인한 결과

UTF-16 중간 범위를 무시해 `a😀z韓`로 덧붙이던 회귀를 재현했고 `a韓z`로 교체하도록 수정했다.
현재 집중 gate는 host 행동 31개·기존 초안 회귀 3개와 discovery 5개, Debug/ReleaseFast 각각 위생 4개·표시 10개를 통과했다.
후보 Return 소비와 일반 Return 개행, 저장소별 초안 복원, 백그라운드 발견에 의한 초안 덮어쓰기 방지,
잘못된 범위의 전체 키 복구와 스크롤 복구를 포함한다. 기존 사이드바·프로젝트 검색·주소창·이름 변경 IME
회귀, Swift 호스트 검사, 경계 검사와 문서 링크·좌표 검사를 통과했다. 전체 ABI 테스트 집합과 CI 성공을
대신하는 결과는 아니다. 범위 무시·owner pin 제거·rollback 제거·후보 Return 재생·입력 위생 우회의 제품 변이는
모두 컴파일 성공 뒤 테스트 assertion 실패로 검출했다. 로그는 `/private/tmp/maru-scm-ime-mutation-results`에 둔다.

독립 검증기는 커밋 시도·개행·초안 유실·owner 재사용·터미널 입력 누출·잘못된 창 geometry를
손상시킨 대조군을 거절한다. Git fixture는 HEAD와 실제 branch ref, HEAD reflog, index, 파일을
각각 해시로 확인한다. fixture 생성은 부모 runner가 수행하며, 앱 내부 observer는 쓰기 진입 시도만 센다.

실제 입력 진단(`/private/tmp/maru-scm-ime-diagnostic-20261026-e`)은 두벌식·후보 취소 5회·한자 확정·
터미널 복귀와 geometry, 커밋 호출 0, Git 해시 불변을 확인했다. `full_validation=false`이며
이 진단 실행은 픽셀 성공을 주장하지 않는다. 최종 검증 앱 SHA-256은
`bb2b244739439310642fb458dd2be7ef12ea1d7c3717477c3e0a8d90b2d4dcfe`다.

실제 live 원본(`/private/tmp/maru-scm-ime-live-20261026-b/run`)은 후보창 5개, 한자 확정,
터미널 복귀와 저장소 해시 검사를 통과했다. 첫 독립 픽셀 판정은 새 SCM schema 미등록으로 거절됐고,
등록 뒤 원본 PNG·transcript를 변경하지 않고 다시 검사해 해시·OCR을 통과했다.
`revalidation.json`이 원본 파일 해시와 판정기 소스 해시를 연결한다.
추가 실행 `...-c`는 녹화 중 새로 나타난 WindowServer 표시 창 때문에 `CandidateNotClosed`로
거절됐으며 실패 기록을 그대로 보존했다. 공유 창 판정의 조건을 완화하지 않았다.

## CI 초안 회귀 보완

전체 ABI CI는 기존 초안 테스트 두 개가 조회 저장소 변경(`rememberGitRepo`)을 입력 owner 전환으로
취급하던 전제를 검출했다. 선택한 상자의 포커스는 그대로 둔 채 조회만 바꾸면 편집 초안도 유지해야 한다.
기존 빈 초안·저장소별 복원 기대값은 유지하고 실제 `focusCommitRepo` 전환을 수행하도록 세 테스트를
수정했다. 조회 변경 직후에는 글과 focus가 유지되는지도 추가 확인한다.
이 세 테스트를 `test-scm-commit-ime`에 포함해 host/discovery 합계 39개를 고정했다.
수정 전 두 실패를 로컬 재현했고 수정 후 39개를 통과했다. 제품 입력 코드와 고정 GUI 앱은 변경하지 않았다.
