# 이름 변경·다른 이름으로 저장의 IME 범위 문맥

상태: 구현·실제 입력 diagnostic·실패 주입 검증 완료. 실제 PNG/OCR 검증은 화면 기록 권한 대기.

## 원인과 범위

`rename_input`은 TextField지만 chrome IME generation/projection에는 연결되지 않는다.
범위 콜백이 일반 caret 삽입으로 돌아가므로 중간 재변환의 replacementRange를 적용할 수 없다.
생명주기는 `settings.startRename/closeRename` 한 곳에서 관리된다. workspace·group·pane·term·
file tree·symbol·untitled-save는 이 필드/생명주기를 공유한다. 선택 UI를 새로 추가하지 않는다.

## 보존할 계약

- rename은 기존처럼 NFD를 그대로 보존하고 CoreText로 그린다. 주소창만 Hangul NFC를 유지한다.
  공통 순수 TextField IME adapter에 저장 정책을 명시해 host에서 Unicode 편집 규칙을 복제하지 않는다.
- 기존 단축키·선택 없음·대상별 commit 동작을 유지한다. 후보 확인 Return은 이름 확정/파일 저장으로
  새지 않고, 별도의 실제 확정 키에서만 대상 작업을 실행한다.
- 시작마다 세대를 증가시키고 close/reopen/다른 owner 전환의 이전 키 콜백은 소비한다.
  start/close 외의 생산 target setter가 없는지 검사한다. key 해석 밖의 식별 불가능한 지연 콜백은 별도다.
- 호스트 glue는 주소창과 rename을 한 모듈에서 선택하고, range·snapshot·OOM·key 판정은 기존
  `text_field_ime.State`만 소비한다. 기존 주소창 glue를 복사해 두 정책을 만들지 않는다.
- inline 렌더는 preedit 안의 실제 caret 메타데이터를 사용하되 grapheme 안에 caret 글리프를 끼워
  NFD shaping을 끊지 않는다. 시각 caret/anchor는 같은 경계를 사용한다. 기존 미지정 callers는 유지한다.

## 순서와 검증

저장 정책·caret/NFD 순수 실패 검사를 먼저 작성하고 공통 adapter·host 연결을 구현한다.
workspace 중간 입력·범위 교체·candidate Return 부작용·target 세대·OOM·주소창 회귀를 확인한다.
별도 사본에서 정책과 guard를 공격하는 적대적 검증 20회와 정상 대조군을 전후 실행한다.
실제 검증은 먼저 입력 diagnostic을 마치고 같은 고정 앱에서 candidate PNG/OCR·취소·선택·
명시적인 이름 확정·터미널 복귀를 확인한다. Save As의 파일 생성 GUI까지 검증하지 않았다면
workspace GUI 증거로 대신 주장하지 않는다. 새 권한 요청은 diagnostic 후 고정 앱 기준으로만 한다.

새 런타임 의존성, TextField 전원 이관, rename 선택 UI, 파일 작업 정책 변경은 범위 밖이다.

## 구현 중 확인한 회귀

명시적인 Save As 재시도는 이전 오류 notice가 남아 있어도 실행될 수 있다. OS 콜백의
포커스 검사를 여기에 적용하면 정상 저장까지 막히므로, 명시적인 commit은 살아 있는 대상과
세대를 검사한다. OS 콜백은 계속 포커스까지 검사한다. 기존 저장 회귀 검증으로 확인한다.

## 구현과 현재 증거

주소창과 rename의 host identity glue는 `field_ime.zig`로 합쳤다. 범위 적용과 실패 처리는
`text_field_ime.State`가 소유하며 rename은 `.verbatim`, 주소창은 기존 Hangul NFC를 사용한다.
owner는 rename bit 61, 주소창 bit 62, palette bit 63으로 분리하고 고정 검색 owner는 bit 61
미만으로 제한한다. AppSession 소유 상태 추가에 따라 macOS ABI는 236이다.

중립 모델 검증은 Debug/ReleaseFast에서 NFD·UTF-16·잘못된 surrogate 범위·할당 실패·거절 후 blur를
다룬다. 기존 저장 152개와 주소창 회귀도 별도로 확인한다. 제품 사본에서 NFD 삽입/조합 정규화,
거절 guard 제거, grapheme 분할, replacement 무시 결함을 각각 주입했을 때 회귀 검사가 실패했다.
도구의 20가지 손상 기록 검사는 합성 대조군이며 실제 GUI/PNG 증거와 구분한다.

GUI 도구는 `tools/rename-ime`에 두고 공통 launcher·실제 HID·WindowServer reducer·PNG/OCR을
재사용한다. 긴 이름은 의도적인 tail clipping 때문에 caret이 같은 위치일 수 있어 이 장면에는
짧은 `a//z`를 사용한다. 실제 입력에서 `a/한/z`·`a/韓/z`와 대상 이름 불변을 확인하고, 추가
Return 뒤에만 대상 이름이 `a/韓/z`인지 검사한다. 긴 이름 렌더는 중립 clipping 회귀가 담당한다.
실제 입력 diagnostic은 `maru-rename-ime-20261025/diagnostic-3`에서 통과했다.
고정 앱 SHA-256은 `974af00a5afdbf32c7e5b83b02689ce59e10fff0fec6921b9cbe8659bcfc1c55`이다.
화면 기록 preflight=false여서 PNG/OCR 검증은 아직 미완료이며 이를 merge gate로 유지한다.
