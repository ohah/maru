# 실제 SDK 저장 시 포맷 회귀

`run.py --scenario format-save`는 Rust·Go 실제 서버를 AppSession의 ⌘S 경로에 연결한다.
기존 제품의 format-on-save·비동기 저장·Undo·stale·1초 시한·설정 끔을 검사하며 정책은 바꾸지 않는다.

## 실행

[명시적 서버 설정](README.md)을 준비한다. SDK 설치·실행은 opt-in이며 기본 CI는 실행하지 않는다.

```sh
python3 tools/editor-lsp-real/run.py --scenario format-save --build --optimize Debug \
  --servers-json /absolute/path/servers.json --output /absolute/new/debug-output
python3 tools/editor-lsp-real/run.py --scenario format-save --build --optimize ReleaseFast \
  --servers-json /absolute/path/servers.json --output /absolute/new/fast-output
python3 tools/editor-lsp-real/verify.py /absolute/path/saved-output
```

빌드 타깃은 `editor-real-lsp-format-save-judge`, 실행 파일은
`zig-out/bin/maru-real-lsp-format-save-test`다. `--judge`로 고정 사본을 지정할 수 있다.
`test-editor-real-lsp-format-save`는 명시한 `MARU_REAL_LSP_CASE` 한 건용이다.
제품 사례 하나와 모듈 참조 넷, 다섯이 모두 통과해야 하며 사례 없는 skip은 성공이 아니다.
기본 언어는 Rust·Go이고 다른 언어는 출력 생성 전에 거절한다.

## 제품 경로

일부러 정렬하지 않은 한 파일에 한글·emoji 뒤의 호출을 둔다. 각 포맷 요청 전 실제 정의 조회가
성공해야 한다. `editor.formatter.<언어> = lsp`, format-on-save 켬, 저장 시 code action은 빈
설정으로 두어 언어 서버 포맷 경로를 검사한다. 외부 포매터 선택 정책을 대신 검증하지 않는다.

1. 디스크 원문과 다른 미저장 본문을 만든 뒤 실제 ⌘S를 누른다. 응답 전에는 디스크가
   원문이어야 한다. 같은 문서의 ⌘S와 ⇧⌥F는 기다리던 저장을 빼앗거나 새 요청을 보내면 안 된다.
2. 실제 `textDocument/formatting` 편집을 적용한 본문과 디스크가 같고 dirty가 해소돼야 한다.
   포맷만 Undo 하나이며 한 번의 Undo로 미저장 본문에 돌아온다. Undo는 디스크를 쓰지 않는다.
3. 다음 실제 포맷 응답을 관측하되 LSP pump는 잠시 진행하지 않는다. 로컬 본문을 바꾼 뒤
   처리하여 오래된 편집은 거절하고 **지금 본문을 저장**하는지 확인한다.
4. 또 다른 실제 응답을 제품의 1초 시한 안에 관측한다. 남은 시한까지 클라이언트 처리를
   미룬 뒤 정상 pump를 호출하여 포맷 없이 저장하고 늦은 편집을 적용하지 않는지 확인한다.
5. format-on-save를 끄고 다른 본문을 ⌘S로 저장한다. 포맷 요청이 추가되면 안 된다.

세 실제 포맷 요청, 네 실제 저장을 요구한다. 비동기 저장 완료와 didSave flush를 기다리고
before/dirty/waiting_normal/saved_normal/undone/waiting_stale/saved_stale/waiting_timeout/
saved_timeout/saved_disabled 열 단계의 buffer·disk·version·Undo·dirty를 보존한다.
열여섯 순차 대기의 예산을 외부 프로세스 시한에 포함한다. 실패한 전체 사례를 자동 재실행해
성공으로 덮지 않는다.

## 독립 판정과 시간

`format_save_oracle.py`는 원본 양방향 wire를 요청 ID의 타입과 방향으로 대응한다. 협상한
UTF-8/UTF-16으로 실제 서버 TextEdit를 독립 적용하며, 정상/낡은 응답의 결과가 고정된
기대 포맷인지 확인한다. 시한에 버리는 응답도 실제로 본문을 바꾸는 유효한 편집이어야 한다.
각 요청은 해당 version에서 정의 조회가 먼저 성공해야 한다. client/server ID가 겹쳐도
서버 요청의 응답을 클라이언트의 포맷 결과로 소비하지 않는다.

주 파일의 여섯 본문 변경과 네 didSave의 내용·version·순서를 대조한다. 응답 전에 저장하거나
Undo로 디스크를 쓰거나, 낡은 편집·늦은 편집이 본문에 섞이거나, 설정을 끈 뒤 포맷을 요청하는
증거는 성공이 아니다.

제품 시한 상수 1000ms와 응답 관측 시각 < 시한 ≤ 처리 재개 시각을 확인한다. wire는 한
observer의 단조 시계를 사용하므로, 실제 응답→해당 저장의 간격도 보고된 남은 대기 시간
이상이어야 한다(서로 다른 시계의 ms 양자화에 10ms 측정 여유를 둔다). 이 여유는 제품의
1초 시한을 바꾸지 않는다. 실제 기다림 없이 시한 처리했다고 보고하는 파손 증거를 거절한다.

이 검사는 **클라이언트의 응답 처리 시점**을 제어한다. proxy 바이트나 서버 결과를 바꾸지
않으며 서버 자체가 느렸다는 증거로 확장하지 않는다. 정상 포맷이 실제 1초 안에 적용되지
않으면 그 실행은 실패로 남긴다.

## 보관과 한계

컴파일된 컨트롤러 11개 지문과 도구 6개 사본, 고정 실행 파일·원본 wire·stderr를 보존한다.
`editor/real_lsp/format_save.zig`는 `sources/format_save_judge.zig`, `save/dispatch.zig`는
`sources/save_dispatch.zig`로 보관한다. 제품 `format.zig`와 `local_save.zig`도 포함한다.
이는 해당 컨트롤러의 대응이며 저장소 전체 재현 빌드의 증거는 아니다.

SDK 없는 Python 회귀는 정상 두 언어·두 인코딩·capability 객체·양방향 ID 충돌과 40개 이상의
파손 입력, 소스/도구 누락·잘못된 언어/모드·소유권·종료를 검사한다. 합성 fixture는 실제 SDK
실행 결과로 계산하지 않는다. 기존 single-file/multi-file/rename과 저장된 v1 증거는 유지한다.
Rust pull 요구는 두 진단 시나리오에 유지하며 진단을 검사하지 않는 rename/format-save에는 적용하지 않는다.

제품 AppSession과 프레임 준비의 headless 증거다. 물리 GUI·IME·화면 픽셀·원격 서버·다른
SDK 버전·외부 포매터·저장 시 code action·실제 서버 지연·디스크 쓰기 실패·앱 종료 중 저장은
검증 범위 밖이다. 기존 저장 파이프라인 제품 회귀와 구분한다.
