# Save As 네이티브 대화상자와 파일 생성 검증

상태: native 파일명·덮어쓰기·취소 GUI와 독립 파일/모델 검증 완료. 제품 소스·저장 정책 변경 없음.

## 기존 증거와 이번 범위

PR #4519는 본문에서 실제 두벌식 조합 중 Save As를 시작해 원본 `foo` 보존, 목적지 `foo한`,
dirty 해제, Undo/Redo와 입력 소스 복원을 확인했다. PR #4583은 rename 공용 입력 문맥의 범위·후보
Return과 workspace 이름 변경을 검증했다. 그 문서의 「Save As 파일 생성 GUI 미수행」은 #4583의
증거 범위이며, 이전 Save As 파일 생성 검증 전체가 없었다는 뜻으로 확대하지 않는다.

이번에는 최신 main에서 **이름 있는 문서의 native NSSavePanel**을 거쳐 한글·한자 파일명을 선택하고,
실제 생성·덮어쓰기 수락/거부·저장 대화상자 취소와 원본 보존을 검증한다. 이름 없는 문서의 inline 첫 저장,
원격 저장, 저장 형식/정규화/예약·충돌 정책 변경은 별도 범위다.

## 계약

- 기존 Save As actor·대상 예약·writer·완료 승인·Undo/Redo 정책을 그대로 사용한다.
- source와 destination은 모두 사유 임시 디렉터리 아래 둔다. 실제 사용자 문서·설정·신뢰 파일은 쓰지 않는다.
- native 이름 필드/Save·Cancel·Replace 확인은 실제 대상 프로세스의 AppKit/접근성 경로로 조작한다.
  직접 모델/파일 쓰기로 GUI 완료를 대신하지 않는다. 한글·한자 입력의 실제 HID 여부는 따로 기록한다.
- 파일의 실제 bytes, 저장 후 문서 path/dirty와 pending 정산, Undo/Redo, 취소 시 목적지 미생성 또는 기존
  bytes 보존을 독립적으로 확인한다. native 대화상자의 승인과 actor 완료를 서로 다른 단계로 본다.
- 파일시스템이 Unicode 표기를 바꿀 수 있으므로 요청 UI 이름·실제 이름의 원문과 정규화 비교를 함께 남긴다.
  제품의 이름 정규화 정책을 새로 추가하지 않는다.

## 검증 순서

기존 ASCII 저장 GUI를 정상 대조군으로 재실행한 뒤 한글·한자 새 파일, 기존 목적지 덮어쓰기 수락,
덮어쓰기 거부 후 저장 대화상자 취소, 새/기존 목적지의 저장 취소를 확인한다. NFD 이름도 대조한다.
기존 저장/취소 회귀와 검사기 손상·정상 대조군을 포함해 서로 다른 20개 이상 조건을 검증한다.
필요한 수정이 발견되면 해당 범위의 실패를 보존하고 수정 뒤 영향받는 검증을 다시 실행한다.

기존 `tools/editor-project-search-app`의 제품 observer·GUI runner와 이미 허용된 별도 native 창 캡처 앱을
재사용한다. 도구가 native 저장을 완료한 기록, 디스크 bytes, 모델과 PNG를 묶어 보존한다.
화면 기록 권한이 있는 기존 캡처 앱은 바꾸지 않고 재사용하며, 원시 증거와 PNG는 저장소 밖에 두고
이미지는 PR 본문에만 업로드한다.

## 도구 API와 기존 진입점 분리

기존 검색 도구는 ASCII Save As 대조군에서도 검색 입력 단계에서 기다려 저장에 도달하지 못했다.
실패한 실행은 `~/Library/Caches/maru-verification/save-as-lifecycle-20261027-control`에 보존한다.
저장 검증은 `--save-as-only`로 사유 root 준비 뒤 바로 Save As 단계로 들어가며 검색 검증 완료를 주장하지 않는다.
기존 검색 실행의 기본 동작은 유지한다.

추가 옵션은 `--save-as-name`(단일 사유 파일명), `--save-as-existing-target`(고정 sentinel 사전 생성),
`--save-as-overwrite-choice accept|cancel`, `--save-as-filename-input ax|korean|hanja`다.
기존 인자 없이 실행하는 저장 시나리오는 이전 ASCII 기본 이름과 동작을 유지한다.
파일명은 도구에서만 단일 component·길이·제어문자·source 충돌을 제한한다. 이는 제품 파일 정책이 아니다.
실제 filename HID 모드는 native 필드에서 조합·한자 선택을 확인하고, ASCII 확장자를 붙이는 접근성 입력과
물리 키 입력을 구분해 기록한다. 입력 소스 복원은 기존 공용 정책을 재사용한다.

## 결과와 발견한 문제

실제 앱에서 ASCII, 실제 두벌식 `한.txt`, 한자 변환 `韓.txt`, 기존 목적지 덮어쓰기 수락/거부,
새/기존 목적지의 저장 취소, NFD `한.txt`, 저장 중 추가 편집을 확인했다. 원본은 모두 `foo`로
보존됐다. 수락 시 목적지는 `foo!`이고 문서 경로가 채택되며 dirty가 해제된다. 저장 중 추가 편집은
디스크 `foo!`와 메모리 `foo!?`를 구분해 dirty를 유지한다. 거부/취소는 기존 경로·dirty를 유지하고
새 목적지를 만들지 않거나 기존 sentinel을 보존한다. 모든 장면에서 pending=0과 Undo/Redo를 확인한다.

이번에 수정한 것은 검증 도구의 두 결함이다. 기존 검색 장면에 묶여 Save As에 도달하지 못하던 진입을
분리했고, 기존 파일의 Save에서 AX가 `-25205`를 반환해도 실제 Replace 창이 열리는 경우를 확인했다.
기존 대상에 한해 이 반환값 뒤 실제 대상 파일명이 있는 Replace UI를 반드시 확인하며, 이후 파일 bytes와
모델을 따로 검증한다. 오류 반환을 무조건 성공으로 바꾸지 않는다. 확인창이 없으면 실패한다.
제품 저장 경로에서는 이 매트릭스가 드러낸 결함이 없었다.

원시 자료는 저장소 밖 `~/Library/Caches/maru-verification/save-as-lifecycle-20261027-final-*`에 보존한다.
초기 검색 진입 실패(`...-control`)와 AX 반환값 판정 실패(`...-overwrite-accept`, `...-overwrite-accept-v2`)도
성공 결과로 덮어쓰지 않고 별도로 남긴다. PNG는 PR 본문에만 업로드한다.

검사기에는 정상 Unicode·취소·덮어쓰기·추가 편집 대조군과 30개 기록 손상 조건을 둔다.
PID·schema·pending·surface·history·본문·dirty·경로·창 연결·PNG hash/크기·입력/취소/Replace 결정·
실제 키 기록·입력 소스 복원의 불일치, 원본/목적지 bytes 변경·취소 후 잘못 생성·기존 파일 훼손·symlink를 거절한다.
이는 합성 기록 손상 검증이며 실제 GUI 성공 횟수나 제품 결함 주입으로 부르지 않는다. 검사기의 pending·PID·목적지 bytes·물리 키·캡처 창 연결 판정 다섯 곳을 각각 제거한 문법 유효 사본도 실행했고, 해당 손상을 놓치는 사본은 모두 테스트가 실패시켰다. 원본 검사기의 정상 대조군은 통과했다.

## 재검증과 한계

`manifest.json`의 `save_as_case`·`save_as_lifecycle.pid`를 확인해 독립 재검증한다. 예를 들어 한자 장면은
`python3 tools/editor-project-search-app/save_as_lifecycle.py <실행 root> --pid <기록 PID> --name 韓.txt --input-mode hanja`다.
이 명령은 보관 증거의 일관성을 재검증하며 종료한 프로세스가 지금도 실행 중임을 주장하지 않는다.
`mise exec -- zig build test-save-as-gui-oracles test-editor-save-as-command test-editor-save-as-policy test-editor-save-as-reservation test-editor-save-as-write -j2`는
독립 검사기와 기존 저장 회귀를 함께 실행한다.

후보 목록 자체의 OCR·VoiceOver·원격 저장·이름 없는 문서 inline 첫 저장·여러 파일시스템과 OS 언어는
이번 증거에 포함하지 않는다. native 이름 필드의 결과와 PNG를 확인했으며, 실제 한글/한자 키 입력,
AX 확장자 입력, AppKit 단축키를 서로 구분한다. 캡처 소유 PID는 native sheet helper일 수 있으므로
무조건 앱 PID와 같다고 단정하지 않고 panel window ID로 연결한다. PNG 검사는 해시·IHDR 크기와
실제 이미지 확인을 사용하며 완전한 PNG 디코더나 OCR 판정자가 아니다.
