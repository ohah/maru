# LSP 심볼 이름 변경의 실제 IME 검증

상태: 실제 GUI 5개 장면·원본 wire·독립 버퍼/디스크/Undo 검증 완료. 제품 입력·LSP·WorkspaceEdit 소스 변경 없음.

## 범위와 증거 경계

workspace rename·named Save As·새 문서 첫 저장·파일 탐색기 rename은 별도 실제 GUI 증거가 있다.
`editor-lsp-real --scenario rename`은 실제 Rust/Go 서버의 다중 파일 편집·저장·Undo·stale 거절을
headless로 확인했으며 물리 GUI/IME를 주장하지 않는다. 이번에는 공용 `rename_input`의 마지막
심볼 owner를 실제 두벌식·한자 후보 입력부터 `textDocument/rename` 송신과 적용까지 확인한다.

서버는 기존 opt-in `tools/fake_lsp.zig`를 별도 프로세스로 사용한다. 실제 SDK 증거를 재실행하거나
대체했다고 말하지 않는다. 기존 proxy로 양방향 JSON-RPC 바이트를 변경 없이 기록하고 독립 검사기가
newName·요청 시점·응답 WorkspaceEdit·열린 버퍼와 닫힌 참조 파일을 대조한다. 프로토콜 테스트 서버
경로만 기존 override로 지정하며 제품 입력·LSP·WorkspaceEdit 정책/ABI는 바꾸지 않는다.

## 계약

private `.git` root 안에 `main.c`와 닫힌 `other.c`를 준비한다. fixture가 자체 root의 신뢰만 허용하고
서버 초기화와 didOpen 완료 뒤 caret의 `base` 심볼로 제품 rename 상자를 연다. 이후 이름 입력은
실제 OS 키다. `base한`·`base韓` 후보 취소/선택 Return 뒤에는 송신 횟수 0·본문과 파일 불변을 확인하고,
별도 Enter에서만 정확한 newName 요청 한 건이 나가야 한다. 다중 파일 적용은 기존 저장/Undo 계약을 따른다.

장면은 한자/한글 적용, 입력 취소, 서버 오류, 상자가 열린 뒤 문서가 바뀐 stale 확정 거절이다.
stale의 문서 변경은 명시적인 fixture 동작이며 물리 사용자 입력으로 세지 않는다. 사용자 파일/설정/
신뢰 저장소는 쓰지 않고 HOME·config·서버 상태·출력을 모두 사유 root에 둔다. 자체 trust 승인도
fixture 준비이며 일반 사용자 권한 승인 경로의 증거가 아니다.

기존 첫 저장 GUI의 source-copy·guarded HID·입력 소스 복원·native capture를 재사용한다.
PID·surface·rename 요청 수·본문/version·pending·Undo·dirty, 원본 wire와 실제 파일 bytes를 각각
검증한다. 후보/필드 픽셀은 창 ID·hash 및 직접 확인이며 후보 OCR·VoiceOver·실제 SDK·원격으로 확대하지 않는다.
정상 대조와 서로 다른 20개 이상 손상 조건을 포함하고 합성/결함 주입은 실제 GUI와 구분한다.
PNG와 원시 증거는 저장소 밖에 보존하며 이미지는 PR 본문에만 업로드한다.

## 결과

고정 앱의 한자/한글 적용, 취소, 서버 오류, stale 거절 5개가 모두 통과했다. 한자 장면은 후보를
취소하고 다시 열어 선택한다. 후보 Return 뒤 송신/본문/version/이력 불변을 확인하고 별도 Enter에서만
`base韓` 또는 `base한` 요청이 한 번 나갔다. 두 파일 적용·자동 저장·열린 버퍼의 단일 Undo 항목과
제품 Workspace Undo 뒤 두 파일 복원을 확인했다. Workspace Undo는 inverse 편집으로 이력을 하나
추가하는 기존 동작이며 로컬 Undo로 항목을 제거하는 동작과 구분한다.

취소와 stale는 wire에서도 rename 요청 0건이었다. stale의 fixture 편집은 새 version과 dirty 본문을
보존했고, 서버 오류는 요청/오류 응답 1건 및 원본 두 파일을 보존했다. 닫힌 `other.c`는 열리지 않았다.
원본 응답 WorkspaceEdit를 독립 적용해 실제 적용 모델/저장 bytes와 대조했다. 한자는 `changes`/UTF-8,
한글은 `documentChanges`/UTF-16이며 위치 범위는 원래 ASCII 구간이다. 실제 SDK의 Unicode 범위 전체나
의미 분석 증거로 확대하지 않는다. 현재 장면들에서 새 제품 심볼 rename 결함은 발견되지 않았다.

## 도구 준비에서 고친 사항

private fixture의 PendingConfirm/키 타입을 실제 API에 맞췄다. 신뢰 확인의 기본 Enter가 취소라는
기존 정책을 놓친 준비 단계 대기는 자체 root에만 기존 명시적 재확인 절차를 사용하도록 고쳤다.
사용자 신뢰 설정을 바꾸거나 제품 방어를 완화하지 않았다. GUI child가 repository의 Documents 파일을
직접 읽지 않도록 기존 proxy 사본과 bootstrap stderr도 private root에 둔다.

## 증거와 검사기 대조

`~/Library/Caches/maru-verification/symbol-rename-ime-20261028-final-*`에 5개 실제 장면을 보존했다.
`...-final-matrix.json`, `...-independent-final.json`에 실행 경로·결과·최종 검사기 해시를 기록했다.
초기 컴파일 실패는 `...-control/build.log`와 별도 rebuild 로그, 준비 단계 대기는
`...-control-v2`~`...-control-v4`에 남겨 성공 결과로 덮어쓰지 않았다. 첫 한자 통제 성공은 `...-control-v5`다.

정상 장면과 owner·문서/version·조기 요청·newName·위치·서버 초기화·편집 응답·적용/Undo·디스크/
실패 보존 손상 대조군을 통과했다. 조기 요청·요청 이름·원본 응답 적용·적용 모델·Workspace Undo 판정을
각각 제거한 Python 사본 5개도 모두 테스트가 실패시켰고 원본 전후 대조군은 통과했다.
`...-oracle-mutations`에 사본과 결과를 보존한다. 합성 대조/검사기 결함 주입은 실제 GUI/제품 결함 주입이 아니다.
기존 WorkspaceEdit·rename 회귀, private 앱 전체 빌드, Python 문법·Zig 형식·문서 링크 검사도 통과했다.
재실행·독립 검사 명령은 [도구 설명](../../tools/symbol-rename-ime/README.md)을 따른다.
