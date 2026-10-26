# 실제 SDK 다중 파일 회귀

`run.py --scenario multi-file`은 Rust·Go의 실제 서버를 기존 AppSession 경로에 연결한다.
제품의 정의 이동·여러 열린 문서 동기화·완성 편집을 검증하는 opt-in 도구다.
SDK 응답을 합성하거나 다른 LSP 클라이언트로 제품을 대신하지 않는다.

## 실행

기존 [servers.json 형식](README.md)을 그대로 사용한다. Rust·Go SDK는 사용자가 준비하며
기본 test/CI가 SDK를 설치하거나 발견하지 않는다.

```sh
python3 tools/editor-lsp-real/run.py --scenario multi-file --build \
  --optimize Debug --languages rust go --servers-json /absolute/path/servers.json \
  --output "$HOME/.cache/maru-agent-artifacts/lsp-multi-debug-new"
python3 tools/editor-lsp-real/run.py --scenario multi-file --build \
  --optimize ReleaseFast --languages rust go --servers-json /absolute/path/servers.json \
  --output "$HOME/.cache/maru-agent-artifacts/lsp-multi-fast-new"
python3 tools/editor-lsp-real/verify.py /absolute/path/saved-output
```

빌드만 하면 `zig build editor-real-lsp-multi-judge`다. 실행 파일은
`zig-out/bin/maru-real-lsp-multi-test`이고 `--judge`로 별도의 고정 사본을 줄 수 있다.
`test-editor-real-lsp-multi`는 명시한 `MARU_REAL_LSP_CASE` 한 건을 실행한다.
제품 시험 하나와 모듈 참조 넷, 총 다섯이 모두 통과해야 하므로 사례 환경이 없으면 실패한다.
기본 전체 테스트는 SDK 사례를 skip하며 Python 판정기는 SDK 없이 실행한다.

`--scenario`를 생략하면 기존 single-file 모드다. 기존 다섯 언어·실행 파일·저장된 v1
증거의 판정을 유지한다. multi-file의 기본 언어는 Rust·Go이고 다른 언어는 출력 생성 전에 거절한다.

## 제품이 하는 일

1. 주 파일만 연 상태에서 분석을 기다린다. UTF-8 한글·emoji 뒤의 호출 자리에서 정의를
   요청해 `values.rs`/`values.go`를 실제로 열고, 뒤로 가기로 원래 문서와 caret에 돌아온다.
   초기 정의 없음 알림은 기존 `acknowledgeDefinitionMiss`의 실제 Escape 경로만 사용한다.
2. 이미 열린 보조 파일의 반환형을 정수에서 문자열로 바꾸고 저장한다. 주 파일은
   편집하거나 저장하지 않는다. 주 파일 호출 자리의 오류 발생을 기다린다.
3. 보조 파일을 원래대로 복원·저장한 뒤 주 파일의 오류 해소를 기다린다. 주 파일의
   본문과 LSP version은 두 단계 내내 그대로여야 한다.
4. 그 뒤에만 주 파일에 미완성 타입 이름을 넣고 실제 서버의 완성을 고른다.
   Rust는 `types.rs`의 unit struct `ImportedToken`, Go는 `time.Duration`이다.
   snippet을 요구하지 않는 타입 완성으로 primary edit와 import의 추가 편집을 검사한다.
5. 팝업이 실제 프레임에서 열린 뒤 Enter로 적용한다. import와 이름 치환이 Undo
   하나여야 하고 한 번의 Undo로 import 없는 미완성 원문으로 돌아와야 한다.
   다른 열린 파일은 완성/Undo로 바뀌면 안 된다.

네이티브 judge는 `real_lsp_multi_judge.zig`다. 제품 정책·ABI·서버 설정을 바꾸는 기능은
아니며 실제 컨트롤러를 호출하는 검증기다. 각 단계의 시한과 저장 증거는 유지하고,
실패한 전체 사례를 자동 재실행해 성공으로 덮지 않는다. 다중 파일의 열 가지 순차
대기 예산이 runner의 전체 프로세스 예산에 들어가도록 한다.

## 독립 증거 판정

`multi_oracle.py`는 원본 양방향 wire를 URI마다 본문·version으로 추적한다. 실제 다른
파일의 정의 응답과 보조 파일의 bad/fixed 편집·주 파일의 오류/빈 보고를 대응한다.
주 파일의 편집이나 저장으로 진단 재발행을 강제한 증거는 거절한다. 오류 보고는 보조
파일 복원 전에 관측돼야 하고, 해소 뒤 다시 오류가 오면 해소로 남기지 않는다.

Rust는 pull 협상과 주 파일 진단 요청 시점의 보조 문서 snapshot을 검사한다. Go의
push는 보조 편집/응답 순서와 제품의 실제 상태를 함께 확인한다. Go 서버 내부의 분석
snapshot까지 증명하는 것은 아니다. 두 경우 모두 주 파일은 보조 편집 중 같은 version이다.

실제 completion 항목과 정확히 같은 원문으로 보낸 resolve만 연결한다. primary edit와
비어 있지 않은 `additionalTextEdits`를 독립 적용한 결과가 제품 본문과 같아야 한다.
보이는 서버 항목·import 선언·세 번의 주 파일 변경(미완성→완성→Undo)과 단일 Undo
이력을 함께 검사한다. 버퍼 단어·추가 편집 없는 완성·다른 resolve data로 대체할 수 없다.

v1 run/product 형식에 `scenario=multi-file`을 더하고 네이티브 세부 결과를 `result`에 둔다.
기존 컨트롤러 7개와 새 judge, 총 8개 소스의 컴파일 지문을 검사한다. 도구 사본에는
기존 4개와 `multi_fixture.py`, `multi_oracle.py`를 보존한다. 이 지문은 해당 컨트롤러의
대응이며 전체 저장소 재현 빌드의 증거는 아니다. 기존 단일 모드의 7개/4개 계약은 유지한다.

## 회귀와 한계

`python3 -m unittest discover -s tools/editor-lsp-real -p 'test_*.py'`는 기존 검사와 함께
다중 파일 정상 Rust/Go·양방향 ID 충돌·소스/도구 누락·잘못된 scenario·언어를 검사한다.
잘못된 target/URI/줄·보조 편집/보고 누락·복원 뒤 늦은 오류·주 파일 강제 저장·빈 완성·
다른 resolve data·import 누락·잘못된 편집/Undo·버전/이력의 bool 위장을 거절한다.
정상 대조군과 20개 이상의 서로 다른 파손 입력을 SDK 없이 확인한다.

제품 AppSession과 프레임 준비의 headless 증거다. 물리 GUI 입력·IME·화면 픽셀·원격 LSP·
다른 SDK 버전·snippet·추가 편집이 다른 문서를 바꾸는 WorkspaceEdit는 이 시나리오의 범위가 아니다.
