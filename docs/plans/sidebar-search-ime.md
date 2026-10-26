# 사이드바 검색창 IME 범위 문맥

상태: 구현·호스트/중립 모델·변이·경계 검사 통과. 최종 고정 앱 실제 입력 진단 통과. 독립 후보창 PNG/OCR까지 통과. PR에서 CI 확인.

## 유지할 동작

사이드바 상주 검색의 OverlayInput과 기존 길이를 유지한다. 필터는 확정 검색어만 사용하고,
조합 중 후보 미리보기로 목록을 다시 고르지 않는다. Escape는 검색어를 비우고 종료하며,
별도로 누른 Return은 기존 첫 일치 세션 이동이다. 후보 확정 Return은 이 동작으로 재생하지 않는다.
blur는 입장 가능한 조합을 정산한 뒤 검색어를 보존하고 필터를 일시정지한다. 접기·숨김도
보이지 않는 입력이 키를 계속 소유하지 않게 한다. NFC 변환·중간 caret 편집 UX를 새로 추가하지 않는다.

## 연결 방식

중립 `overlay_input_ime.Projection`과 키 단위 deep snapshot을 재사용한다. 창의 활성 epoch와
active surface로 native owner를 구분하고, 모달·숨김·터미널 pin·초기화 전 상태는 owner를 내지 않는다.
키 밖 콜백도 동일한 원자적 문맥으로 반영하며 범위 오류/OOM에서는 텍스트·선택을 복구한다.
단조 증가 토큰은 포화 시 닫고 기존 다른 owner의 토큰과 겹치지 않게 bit 57을 예약한다.

표시는 canonical query와 preedit을 단순 이어 붙이지 않고 native 합성 문자열과 선택 위치를 쓴다.
중립 표시 helper가 기존 inline_edit grapheme/긴 줄 규칙을 재사용하며, 실제 caret과 후보 anchor는
같은 표시 문자열·CoreText offset을 읽는다. NFD·emoji의 의미 UTF-16 범위를 paint snap으로 바꾸지 않는다.
필터 게시와 사이드바 재투영은 host가 맡고 Unicode 편집 판정은 중립 adapter에 둔다.

## 구현·검증

1. `a😀z`의 UTF-16 `(1,2)`를 `韓`으로 바꾸는 실제 range 경로를 실패 검사로 재현한다.
2. 중립 표시의 중간 preedit·NFD·긴 줄·선택 caret과 할당 실패를 확인한다.
3. host에서 범위 교체·필터 보존·취소·확정 Return·독립 Return/Backspace·잘못된 범위·실패 원자성,
   A→B→A·모달·blur/close·접기·surface 변경·초기화 전·토큰 포화를 정상 대조군과 확인한다.
4. 서로 다른 적대적 조건 20개 이상과 guard/범위/rollback 변이를 확인한다. 기존 검색·Find·rename
   회귀, ABI·Swift·경계·문서·포맷을 검사한다.
5. 최종 고정 앱에서 실제 두벌식·한자 후보 취소 5회·선택·필터/탭 불변·터미널 복귀·입력 소스 복원과
   독립 PNG/OCR을 확인한다. 소스·관측·픽셀 성공을 구분하며 이미지·로그·빌드는 저장소 밖에 둔다.

#4601의 첫 Tab 과거 실패 원인은 여전히 미확정이다. 이 구현에서 이를 수정했다고 주장하지 않는다.

## 발견·수정과 현재 검증 경계

기존 range 경로에서 `a😀z`의 UTF-16 `(1,2)`를 `韓`으로 교체하면 `a😀z韓`을 만들었다.
새 연결 뒤 `a韓z`를 확인했다. 합성 텍스트와 내부 caret은 중립 표시 helper로 만들고, CoreText
control-font offset 측정은 프로젝트 검색과 공용 host helper로 추출해 두 소비자가 같은 함수를 쓴다.

새 문맥에서 소유자가 바뀐 키의 미확정 insert를 보존하면 다음 키가 그것을 게시할 수 있다.
stale key와 미완료 transaction의 projection을 폐기하고, 다음 키는 canonical query에서 다시 만든다.
키 실패는 deep snapshot으로 preedit·선택까지 복구하며 새 owner의 필드를 이전 snapshot으로 덮지 않는다.
호스트 36개(행동 31개)와 중립 표시 12개(행동 4개)를 Debug/ReleaseFast 대조군과 검사한다.
범위 무시·owner pin 무시·rollback 생략·stale pending 보존·caret 끝 고정 변이 다섯 개를 검출했다.

Return 대조군은 일치하는 세션이 있어야 잘못된 이동을 검출할 수 있다. 이 조건을 호스트에 추가했고,
실제 fixture도 `한`·`韓` 두 격리 세션을 사용한다. before/cancel은 첫 세션, 한자 확정 후 필터는 둘째
세션만 표시해야 하며 활성 세션은 그대로여야 한다. 목록 개수만 보지 않고 표시 세션 bitmask·라벨·
활성 Surface·workspace를 함께 읽는다. fixture 초기 배치와 이후 실제 HID 입력을 구분한다.

최종 GUI에서 두벌식·후보 취소 5회·한자 확정·canonical 필터/표시 세션 bitmask·활성 세션 불변·터미널 복귀·입력 소스 복원을 통과했다. 같은 고정 앱에서 실제 후보창 5개의 창 식별·PNG 해시·독립 OCR까지 통과했다. 기존 다른 입력창의 통과를 대신 세지 않는다.

일치하는 세션이 있는 후보 Return 대조군까지 보강했고, 후보 키를 재생하는 여섯 번째 변이도
검출했다. Debug/ReleaseFast 호스트와 기존 프로젝트 검색·Find·설정 검색·rename 회귀, ABI·Swift,
경계·문서 링크·소스 행 참조·포맷 검사를 통과했다.

`live-2`는 독립 후보창 PNG/OCR과 표시 세션 bitmask·활성 세션·터미널 복귀·입력 소스 복원을
통과했다. `live-1`의 macOS 추가 화면 접근 확인창에 따른 포커스 중단은 별도 보존하고 성공으로 세지 않는다.
메인 LSP 변경과의 리베이스는 문서 추가 충돌만 결합했으며 변경한 제품 11개 파일은 고정 앱 소스와 같다.
