# 실제 언어 서버 편집 회귀

Rust·Go·Kotlin·Dart·Scala의 실제 SDK를 Maru의 AppSession에 연결한다.
별도 시험용 LSP 클라이언트나 만들어 낸 응답으로 제품 동작을 대신하지 않는다.
`real_lsp_judge.zig`는 test 블록에서만 불리며 제품 실행 정책을 바꾸지 않는다.

각 언어에서 실제 문서 편집·저장 → 오류 진단 발생 → 복원·저장 → 오류 해소,
함수 호버 표시, 같은 파일의 함수 정의로 이동과 뒤로 가기,
서버가 보낸 지역 변수 자동완성의 Enter 적용과 한 번의 Undo를 검사한다.
한글·이모지가 요청 위치 앞에 있어 협상한 UTF-8/UTF-16 위치 변환도 거친다.
초기 분석 준비 후 읽기 요청은 제한 시간 안에서 재시도하며 모든 응답과 시도 수를 남긴다.
제품에 자동 재시도 정책을 추가한 것은 아니다.

## 실행

macOS, 저장소의 mise Zig 0.17, Python 3와 사용할 실제 SDK가 필요하다.
SDK 자동 설치는 없다. Rust는 rust-src와 같은 toolchain의 rust-analyzer,
Go는 Go SDK와 gopls, Kotlin은 JDK와 kotlin-language-server,
Dart는 SDK, Scala는 JDK·Metals와 BSP 프로젝트가 필요하다.
Scala CLI jar를 지정하면 runner가 소유한 새 프로젝트에만 `setup-ide`를 실행한다.
서버가 자신의 의존성을 내려받을 수 있으므로 네트워크 없는 CI는 순수 판정자만 실행한다.

```sh
# SDK 없이 동작하는 음성 대조군·정상 대조군: 기본 zig build test에도 포함
mise exec -- zig build test-editor-real-lsp-oracles

# 사용자 환경에 맞게 절대 경로를 지정한 servers.json 준비 후 실행
python3 tools/editor-lsp-real/run.py --build --optimize Debug \
  --servers-json /absolute/path/servers.json \
  --output "$HOME/.cache/maru-agent-artifacts/lsp-real-debug-unique"
python3 tools/editor-lsp-real/run.py --build --optimize ReleaseFast \
  --servers-json /absolute/path/servers.json \
  --output "$HOME/.cache/maru-agent-artifacts/lsp-real-fast-unique"

# SDK를 다시 실행하지 않고 저장한 증거 재검사
python3 tools/editor-lsp-real/verify.py /absolute/path/saved-output
# 같은 결과 디렉터리에 보관한 판정기로도 재검사 가능
python3 /absolute/path/saved-output/tool-sources/verify.py /absolute/path/saved-output
```

`--languages rust go`로 일부만 고를 수 있다. 기본은 다섯 언어이며 하나라도 실패하면 종료 코드가 0이 아니다.
`--phase-timeout`은 단계별 1~180초(기본 90초)다. 출력은 체크아웃 밖에 존재하지 않는 새 디렉터리여야 한다.
`--judge`로 미리 만든 바이너리를 주면 실제 컴파일 모드와 일곱 소스 지문을 확인한다.
SDK 설정 예시(경로와 버전은 환경에 맞춘다):

```json
{
  "rust": {"argv": ["/absolute/bin/rust-analyzer"], "environment": {"PATH": "/absolute/rust/bin:/usr/bin:/bin"}},
  "go": {"argv": ["/absolute/bin/gopls"], "environment": {"PATH": "/absolute/go/bin:/usr/bin:/bin"}},
  "kotlin": {"argv": ["/absolute/bin/kotlin-language-server"], "environment": {"JAVA_HOME": "/absolute/jdk", "PATH": "/absolute/jdk/bin:/usr/bin:/bin"}},
  "dart": {"argv": ["/absolute/bin/dart", "language-server", "--protocol=lsp"]},
  "scala": {"argv": ["/absolute/bin/metals"], "java": "/absolute/jdk/bin/java", "scala_cli": "/absolute/scala-cli.jar", "scala_version": "3.3.7", "environment": {"JAVA_HOME": "/absolute/jdk"}}
}
```

`editor-real-lsp-judge`는 SDK 없이 실행 파일만 설치한다.
`test-editor-real-lsp`는 `MARU_REAL_LSP_CASE`를 명시한 한 사례용이며 환경이 없으면 필수 통과 수 검사가 실패한다.
각 실행의 Zig 5 tests는 **실제 언어 사례 하나 + 모듈 참조 네 개**다. 다섯 언어의 의미가 아니다.
기본 test에서는 환경 없는 실제 SDK 사례를 skip하고, Python 판정/소유권 검사는 실행한다.

## 증거와 격리

`product.json`은 Maru가 표시한 호버, 이동 결과, 진단 카운터, 완성 전후 전체 본문,
Undo 전후 본문과 이력을 기록한다. 제품이 생성한 문서 버전도 기록한다.
프록시는 실제 SDK와 Maru 사이의 바이트를 변경하지 않고 `wire.ndjson`에 양방향 JSON-RPC를 관찰한다.
기존 gallery의 요약 로그 형식은 유지한다. 요청 ID는 방향과 JSON 타입을 구분한다.
16MiB 관찰 예산을 넘으면 실패하며 성공으로 축약하지 않는다.

독립 `oracle.py`가 실제 wire의 didChange를 순차 적용하고 협상 위치 단위로 hover·definition·completion을 검사한다.
완성 항목은 실제 서버 응답에 있어야 하며 버퍼 단어로 대체할 수 없다. textEdit/insertText의 적용 결과를
제품 본문과 대조한다. 근거는 [공개 LSP 3.17 명세](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)다.
서버 요청과 클라이언트 요청이 같은 숫자 ID를 사용하는 경우도 분리한다.

실행 바이너리 사본·SHA256, 컴파일 모드, 컴파일 시 내장한 일곱 컨트롤러 소스의 SHA256,
해당 소스 사본과 runner/oracle/verifier/proxy 사본을 함께 남긴다. verifier는 실행 성공 코드,
파일 해시와 내장 소스 지문을 확인해 다른 바이너리·누락·변조를 거부한다.
이 지문은 일곱 컨트롤러의 대응을 검증하며 전 저장소 재현 빌드를 증명하는 것은 아니다.
SDK entrypoint 경로와 해시도 기록한다. jar launcher의 해시는 내려받은 모든 SDK 의존성의 지문이 아니다.

각 프로젝트는 새 git root·nonce·전용 config/cache/state/trust를 쓴다.
자동 신뢰 답변은 test-only이며 runner 소유 문서에만 적용한다.
Maru에는 HOME/저장소·셸 환경 수집을 넘기지 않는다. SDK에는 제한된 SDK 환경과 manifest의 명시적 환경을 준다.
프로세스 종료는 제품이 소유한 그룹 및 현재 명령이 해당 fixture 프록시임을 확인한 그룹에 한한다.
실행 도중 취소/실패 로그도 남기며 다른 앱·서버 그룹을 종료하지 않는다.

## 검증 범위와 제한

이는 headless **실제 제품 컨트롤러 통합 검증**이다. AppKit 마우스·물리 IME·Metal 화면 캡처의 증거는 아니다.
같은 파일 내 정의 이동과 지역 변수의 평문 완성만 다룬다. 다른 파일 이동, autoimport, snippet,
다중 추가 편집, 원격 LSP, 모든 SDK 버전의 호환성은 별도다.

Rust는 협상된 pull 요청 시점의 version으로 bad/fixed를 대응하고, Go는 push 진단의 version을 검사한다.
Kotlin·Dart·Scala의 실제 응답은 version을 생략했다. 이 경우 wire의 편집/진단 순서와 제품 상태를 함께 확인한
`ordered unversioned plus native state`로 표시한다. 서버 내부 분석 버전까지 증명했다고 주장하지 않는다.

음성 대조군 20개는 서로 다른 결함을 주입해 모두 거부되는지 검사한다:
잘못된 root, initialized 누락, 다른 열린 문서, null hover, 잘못된 hover 위치,
다른 정의 URI, 다른 정의 줄, 오류 진단 누락, 지난 오류 버전, 오류 편집 누락,
진단 해소 누락, 지난 해소 버전, 해소 후 오류 잔류, 빈 완성,
버퍼 단어 대체, 다른 선택 항목, 문서 밖 편집, 제품 적용 본문 불일치,
Undo 본문 불일치, Undo 이력 두 개 증가.
기존 단일 모드의 정상 대조군과 UTF 경계·ID 충돌·비정상 종료·오래된 바이너리·소유권 실패에
다중 파일 검사도 더한다. 현재 전체 Python 판정은 66개 시험 함수다(파손 입력 subtest 포함).

첫 실물 실행에서 Rust가 initialize 직후 정의 요청에 null을 반환했다.
실패를 숨기지 않고 baseline 진단 준비 대기와 제한된 읽기 재시도로 바꿨다.
완성 Enter 전 suggest widget을 실제 프레임에서 열지 않았던 하니스 오류도 수정했다.
제품 동작 오류로 분류하지 않았다. 프록시의 양방향 ID 충돌은 관찰기 오류로 수정했다.

최신 main 반영 후 병렬 검증 한 번에서 Rust는 bad version의 didChange/didSave를 보냈으나
60초 안에 오류 진단을 내지 않아 `TypeErrorNotPublished`로 실패했다. 같은 바이너리의 별도
Rust 실행은 통과했다. 당시에는 초기 분석·저장 시점의 간헐적 차이로 의심했으며 원인을 확정하지 못했다.
실패 산출물은 보존하며 runner가 전체 사례를 자동 재시도해 성공으로 덮지 않는다.
후속 조사에서 SDK의 취소·push 재발행 생략과 Maru의 push 전용 조합을 확인했다.
재현·대조와 수정 방향은 [Rust 진단 미수신 조사](rust-diagnostics.md)를 참조한다.

ReleaseFast의 Rust 완성 요청도 한 번 null을 반환했다. 호버·정의와 같은 제한된
변경 없는 읽기 재시도를 완성에도 적용하고 시도 수와 모든 null 응답을 기록한다.
진단 발생을 위한 변경·저장은 자동으로 반복하지 않는다.

Rust는 `diagnostic_transport=pull`이어야 runner가 성공한다. 실제 요청의 본문 version과 URI로
진단 응답을 독립 대응하며 협상한 서버의 push로 이를 대체할 수 없다.
서버 취소/버전/늦은 push의 제품 회귀는 `mise exec -- zig build test-editor-rust-pull`로 실행한다.

## 정의 재시도와 자동완성 차단

초기 정의 null을 읽기 재시도로 복구할 때는 그 요청이 만든 `nav_no_definition` notice만
실제 Escape 경로로 확인한다. 다른 오류나 신뢰 확인창을 자동으로 닫지 않는다.
`product.json`의 `definition_notices_acknowledged`와 `completion_observation`에 그 과정과
팝업이 열리지 않은 상태를 보존한다. [원인·전후 재생·20개 상태 회귀](completion-retry.md)를
참조한다. SDK 없는 회귀는 `mise exec -- zig build test-editor-real-lsp-retry`로 실행한다.

## 다중 파일 회귀

`--scenario multi-file`은 Rust·Go에서 다른 파일 정의/복귀, 주 파일을 바꾸거나 저장하지
않는 연관 진단 갱신, 실제 autoimport 추가 편집과 한 번의 Undo를 검사한다.
기본 단일 모드와 별도 opt-in judge를 사용한다. [실행·원문/버전 대응·한계](multi-file.md)를 따른다.
