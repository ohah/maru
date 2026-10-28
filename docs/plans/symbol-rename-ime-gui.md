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

## 후속: 실제 clangd GUI 연결 (완료)

기존 제어 서버 장면은 그대로 유지하고, 명시적 `--clangd /absolute/path` opt-in을 추가한다.
자동 설치 없이 로컬 SDK 바이너리·버전·해시를 기록하고 같은 raw proxy와 실제 HID 경로를 사용한다.
사유 프로젝트에 명시적인 함수 선언이 있는 두 C11 파일의 compilation database를 두어 닫힌 파일의 참조도 서버가
인덱싱할 수 있게 한다. 실제 서버 준비/분석 지연이나 응답 실패는 성공으로 완화하지 않고 보존한다.
실제 한자/한글 적용·취소·stale와 두 파일 저장/Undo를 확인하며, 강제 서버 오류는 기존 제어 장면에만 둔다.
검사기는 서버가 보낸 renameProvider의 합법적인 bool/options 형태와 WorkspaceEdit 양식을 읽되,
정확한 요청 이름·두 소유 URI·응답의 독립 적용·버퍼/디스크/Undo 검사를 유지한다. 실제 SDK의 서버 식별과
실행 지문은 제어 서버와 명시적으로 구분하며 다른 SDK/원격/모든 Unicode 범위로 확대하지 않는다.


Apple clangd 17.0.0(clang-1700.6.3.2) 고정 실행 파일로 실제 한자·한글 적용, 취소, stale의 네 장면을
통과했다. 후보 선택 Return에는 요청이 없고 별도 Enter에서만 정확한 newName 한 건이 나갔다.
실제 서버가 반환한 두 파일의 선언·정의·호출을 독립 적용해 버퍼/디스크와 대조했고 제품 Workspace
Undo 뒤 두 파일 복원을 확인했다. 취소와 stale는 wire에서도 요청 0건이다. 새 제품 결함은 발견되지 않았다.
기존 고정 instrumented 앱을 재사용했으며 제품 소스/ABI는 변경하지 않았다.

최초 실패는 한 파일만 반환한 서버 응답을 두 파일 성공으로 처리하지 않고 보존한 결과다. canonical
compilation database 경로로 바꾸니 배경 인덱싱이 시작됐고, 닫힌 C11 파일에 명시적인 함수 선언을
추가하니 두 파일 편집 응답이 나왔다. 제품 저장/Undo 정책을 바꾸거나 판정의 두 파일 조건을 낮추지 않았다.
근거는 [clangd 인덱스 설계](https://clangd.llvm.org/design/indexing.html)와 해당 실행의 서버 stderr/wire다.
서버 provenance와 실행 argv·편집 양식/두 파일 저장·복원의 서로 다른 손상 20개, 합법 bool/options
capability 및 changes/documentChanges 대조군을 확인했다. 새 판정 다섯을 제거한 Python 사본도 모두
실패했고 원본 전후 대조는 통과했다. 이는 합성/검사기 변이이며 제품 결함 주입으로 세지 않는다.

새 증거는 `~/Library/Caches/maru-verification/symbol-rename-real-20261028-final-*`와 `...-matrix.json`,
`...-independent-final.json`, `...-mutations`에 둔다. 실패는 `...-control`과 `...-control-v2`, 최초 통제
성공은 `...-control-v3`에 보존한다. 이전 제어 서버의 다섯 장면도 최신 검사기로 별도 재검사한다.
실제 SDK는 opt-in이고 SDK 없는 기본 테스트에 실행/다운로드를 추가하지 않는다. 다른 SDK, 원격,
비ASCII 원문 위치 전체와 후보 OCR/VoiceOver 검증은 이번 범위에 포함하지 않는다.

## 후속: 비ASCII 원문 위치 (완료)

실제 clangd opt-in에 `--unicode-prefix`를 추가한다. 정의와 닫힌 파일의 선언/호출 앞 같은 줄에
`/* 한😀 */ ` 주석을 두어 UTF-8 byte·Unicode scalar·UTF-16 code unit 위치가 모두 달라지게 한다.
원문 이름 `base`와 실제 한글/한자 newName은 그대로 유지한다. 실제 서버가 협상한 위치 단위에서
요청 위치를 독립 byte offset으로 해석하고, 응답 편집도 기존 독립 적용으로 검증한다. UTF-8/UTF-16
합성 대조군은 별도로 두며 실제 SDK가 협상하지 않은 단위를 실제 GUI 증거로 주장하지 않는다.
private driver만 같은 prefix를 인지하도록 빌드하며 제품 소스/ABI·Unicode 저장 정책은 바꾸지 않는다.
정상 ASCII 경로·두 파일 적용/저장·Undo와 취소/stale 회귀를 유지한다.


새 private 앱의 전체 빌드 후 실제 clangd로 한자/한글 적용·취소·stale와 ASCII 정상 대조의 다섯 장면이
통과했다. 실제 협상 결과는 기본 UTF-16이며, prefix 뒤 심볼의 요청 character는 14다. 같은 자리는
UTF-8 byte 18, Unicode scalar 13이므로 잘못된 단위가 우연히 같은 자리로 통과하지 않는다.
응답의 정의·선언·호출 세 편집을 독립 적용하고 두 파일 저장·Workspace Undo 복원을 확인했다.
조합 중 문서/version/이력 불변, 후보 Return 무송신, 취소/stale 무송신과 원문 보존도 확인했다.
적용·Undo Metal PNG를 직접 확인했고 새 제품 결함은 발견되지 않았다.

UTF-8/UTF-16의 합법 응답 양식과 네 장면 정상 대조, 서로 다른 Unicode 손상 조건 20개를 통과했다.
단위 혼동·surrogate 분할·주석 편집·prefix 소실·디스크 불일치·잘못된 encoding은 거부한다.
모드·요청 위치·조기 본문·응답 적용·Undo 판정을 제거한 컴파일 가능한 검사기 사본 다섯도 모두
실패했고 원본 전후 대조군은 통과했다. 합성 UTF-8은 실제 SDK의 UTF-8 협상 증거가 아니다.

증거는 `~/Library/Caches/maru-verification/symbol-rename-unicode-20261028-final-*`, `...-matrix.json`,
`...-independent-final.json`, `...-mutations`, `...-app-build.log`에 보존한다. 이전 실제 SDK 네 장면과
제어 서버 다섯 장면도 최신 검사기로 각각 재검사했다. 구현은 opt-in 검증 도구/private driver에만
있으며 제품 소스/ABI는 바뀌지 않았다. 비ASCII 원문 전체나 모든 SDK/플랫폼의 완료를 뜻하지 않는다.
