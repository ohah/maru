# 설정 검색창 IME 범위 문맥

상태: 구현·실제 입력 diagnostic·집중/적대적 검증 통과. 실제 후보창 PNG/OCR 권한 대기.

## 현재 원인과 범위

설정 검색은 `settings.State`의 64바이트 확정 버퍼와 32바이트 조합 버퍼를 사용한다.
`input.imeSetPreedit`는 조합 문자열만 전달하고, 범위·selected/marked/substring projection에는
연결되지 않는다. 현재 입력줄은 query 뒤에 preedit를 붙이므로 중간 재변환과 caret 위치를
표현할 수 없다. 설정 값 인라인 편집·키 녹음·색상 picker·dropdown은 별도 owner다.

## 보존할 계약

- 고정 버퍼와 무할당 검색 모델, 64/32바이트 상한, NFD 원문 보존을 유지한다. 기존
  legacy setSearchPreedit의 UTF-8 경계 절단과 commit 경로는 회귀로 보존한다.
- 범위가 있는 새 native IME 콜백은 잘못된 UTF-16 범위·손상 UTF-8·용량 초과를 원자적으로
  거절한다. 원래 검색어/조합/선택/필터가 반쪽으로 갱신되지 않게 한다.
- 검색 필터는 기존처럼 확정 검색어를 소비한다. 후보 미리보기를 확정 검색어로 필터하지 않는다.
- 공통 `inline_text_input`의 범위·재변환 로직을 재사용하고 고정 저장 용량만 매개변수화한다.
  설정 검색용 중립 adapter가 snapshot·rollback·확정 시점을 소유하고 macOS는 owner만 연결한다.
- 검색 시작/종료·설정 닫기/다시 열기·섹션 전환 및 다른 설정 컨트롤로 전환된 이전 키의
  콜백은 소비한다. 검색 전용 문맥은 값 편집이나 키 녹음으로 샐 수 없다.
- 후보 Enter는 검색 결과 행 활성화를 실행하지 않는다. 별도 Enter의 기존 행 활성화는 유지한다.
- 입력줄과 후보 anchor는 동일한 projected caret을 소비한다. NFD/emoji grapheme을 caret으로
  쪼개지 않는다. 새 선택 UI나 좌우 이동 UX는 추가하지 않는다.

## 순서와 검증

고정 용량 공통 문맥과 설정 adapter의 실패 검사를 먼저 실행한다. 중간/접미사 재변환,
비-BMP·surrogate 내부·NFD, 용량 63/64/65 및 31/32/33바이트, 여러 콜백 중 하나 실패 후
rollback·blur·다음 키 회복을 확인한다. component 렌더/anchor와 host source pin을 연결한 뒤
설정 일반 키·기존 주소창/rename 회귀를 실행한다.

독립 손상 기록·제품 결함 주입을 포함해 서로 다른 적대적 검증 20개 이상과 정상 대조군을
확인한다. 실제 앱에서는 후보 취소 5회·한자 선택·검색어와 필터의 확정 경계·다른 입력창으로
복귀·입력 소스 복원을 확인하고 독립 PNG/OCR을 실행한다. diagnostic과 실제 pixel 통과를
구분한다. 로그·PNG·빌드는 저장소 밖에 두며 이미지는 PR 본문에만 업로드한다.

저장 구조 변경에 따른 ABI는 구현 시 최신 main과 대조한다. 다른 검색창 전원 이관,
설정 값 편집의 완전 IME, 식별 정보가 없는 key 해석 밖 지연 콜백은 이번 범위 밖이다.

## 구현 중 확인과 수정

빈 marked 콜백이 후보 미리보기만 삭제하면 retained committed word가 표시 문맥에서
사라지는 것을 실패 검사로 재현했다. 확정 단어·접미사·caret을 함께 복원하도록 수정했다.

고정 용량은 중립 adapter가 소유하는 상수로 통합했다. 기존 공통 Context의 기본 용량과
동적 저장은 바꾸지 않는다. 새 settings owner는 bit 60을 쓰고 고정 Session Dock owner는
그 아래 범위로 제한한다. 상태·캐시 추가에 따라 macOS ABI는 237이다.

집중 중립 검증 18개(Debug/ReleaseFast), 설정 host 8개, 기존 주소창·rename·고정/동적
문맥 회귀와 기존 저장 152개가 통과했다. 독립 검증기는 20개 손상 기록을 거절했다.
제품 사본의 용량 확대·rollback 제거·빈 후보 취소 복원 제거·replacement 무시·거절 blur
허용·NFD caret 분할 결함 7개는 모두 실제 회귀 검사가 실패했고 복원 대조군은 통과했다.

실제 입력 diagnostic은 `maru-settings-ime-20261025/diagnostic-3`에서 통과했다.
후보 취소 5회·한자 선택·검색 종료·설정 닫기·터미널 복귀·입력 소스 복원을 확인했다.
고정 앱 SHA-256은 `47aac4debff03c35e326ee98dc2103842cb707fd12223e2901f4e8afc306edc8`이다.
화면 기록 preflight=false여서 실제 후보창 PNG/OCR은 권한 대기이며 merge gate로 유지한다. 계획에 없는 전체 설정 값
편집의 IME 보장이나 다른 검색창 전체를 완료로 주장하지 않는다.

컨트롤 전환 검사에서는 검색 중 값 편집에 들어갈 때 검색 preedit가 남고, legacy 값 편집
조합이 검색 버퍼로 유입될 수 있음을 재현했다. 검색 모드 판정을 공통화하고 mode 전환에서
검색 조합을 비우도록 수정했다. 값 편집 자체에 새 IME 문맥을 제공하는 변경은 아니다.
