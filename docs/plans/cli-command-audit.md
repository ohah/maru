# CLI 명령 전수 점검

## 상태와 기준

2026-10-09 최초 점검과 재현 완료. 아래 발견 사항은 수정 전 동작이며, 승인된 수정 결과는 마지막 절에 기록한다. PR #4258은 머지됐다
(`7d1fcf1d396d5e9652447857c19641d0c67c7be3`). 독립 worktree에서 점검했으며,
해당 merge commit과 최초 점검 source의 `src/cli` 및 `src/main.zig` 내용이 동일함을 확인했다.

기준 source는 `fbedbe1527dafc0086fcd4a22ac5457f3f9c0538`(PR #4258 head), 해당 checkout에서
새로 빌드한 CLI SHA256은 `631b729dfbbd98d8b9871066786912c33814b1d1d4ea5e1b88f2cbf06fea9479`다.
이 문서는 그 snapshot의 결과이며 미래 main 또는 모든 플랫폼의 제품 E2E 통과를 뜻하지 않는다.

루트 dispatcher의 literal route 38개와 private child route 2개, 모든 공개 제품 CLI group 16개를
대조했다. 제품 CLI의 bare/help/반복 명령, 각 verb의 help와 의심 경로를 실제 process로 검사했다.
진단 명령은 source·root help·platform gate를 확인했고, Windows GUI나 PTY soak를 새로 실행하지 않았다.

## 명령 구조 재고

| 루트 | 현재 형태 | 점검 판단 |
| --- | --- | --- |
| editor | open, lsp trust list/revoke/forget | 에디터 제품 명령이 같은 namespace다. `-l`/`-c`와 long alias 지원. 반복 editor는 거부한다. |
| lsp | trust list/revoke/forget | editor lsp와 같은 helper를 쓰는 명시적 호환 별칭. 다른 editor 기능을 여기에 추가하지 않는다. |
| browser | list, navigate, get-url, exec, get-cookies, set-cookie, delete-cookie, get-local-storage, set-local-storage, remove-local-storage, clear-storage, click, type, scroll, wait, screenshot, snapshot, console | 18개 verb가 browser namespace 및 자체 help에 있다. root description은 옛 4개 verb만 적어 설명이 낡았다. |
| sessions | list | surface 목록 계약의 독립 명령. session과 singular/plural 구분이 문서화돼 있다. |
| session | get | surface 하나 조회. 위 명령과 임의 통합하면 기존 CLI 계약을 바꾼다. |
| host | status | persistent host 관리 namespace. |
| runtime | list, get, end | persistent runtime 관리 namespace. surface 조회 session과 다른 자원이다. |
| attach | runtime-id와 mode flags | TTY attach의 명시적 진입점. mode 충돌·중복과 ID 오류를 거부한다. |
| incidents | list | 로컬 incident 기록 조회. root help에 빠졌다. |
| trace | anonymize | namespace는 맞지만 argv 상한·help 처리가 부족하다. |
| terminfo | status/refresh/clear/path flags | 단일 목적 local cache 명령. 모르는 인자를 거부하나 help flag는 지원하지 않는다. |
| install-cli | 무인자 설치 | 인자 자체를 검사하지 않아 help·반복 명령도 설치로 처리한다. |
| ssh | SSH argv passthrough, --terminfo-only | 대상 이름 ssh도 정상 remote destination이다. 중복 namespace 오류로 분류하지 않는다. --help는 wrapper 소유 help가 아닌 SSH argv로 전달된다. |
| control | --stdio | remote control transport 진입점. source 계약이 별도로 있으며 root help에는 없다. |
| agent-events | --stdio와 stream flags | 원격 event stream 계약. root help에는 없다. |
| agent-hooks | install/uninstall와 remote provider flags | 원격 hook 관리 계약. root help에는 없다. |

개발 진단 route 20개는 demo, app-* 및 win32-/d3d11-/dwrite- smoke/draw 명령이다. root help에
없는 항목은 `win32-git-smoke`, `win32-scm-draw-smoke`, `win32-scm-write-smoke`,
`win32-file-tree-draw-smoke`, `win32-editor-draw-smoke`, `win32-file-tree-smoke`, `win32-terminal`이다.
private route는 `__session-host`와 `__notification-release-runtime`이며 숨김은 source에 명시된 의도다.
이 child 프로토콜을 일반 사용자 namespace로 옮기지 않는다.

## 재현된 문제와 수정 우선순위

### 1. 설치 명령이 help와 잘못된 argv에서도 파일을 바꾼다

`install-cli --help`, `install-cli install-cli`가 exit 0으로 설치를 실행한다. 무인자 install
dispatcher가 나머지 argv를 검사하거나 소비하지 않고 `runInstallCli`를 호출하는 것이 원인이다.

격리 HOME의 `.local/bin/maru`에 일반 sentinel 파일을 만든 뒤 `install-cli --help`를 실행했다.
기존 파일이 삭제되고 현재 CLI로 향하는 symlink가 생겼다. `runInstallCli`의 unconditional
unlink가 help 요청에서도 실행된다. 사용자의 실제 PATH/파일은 변경하지 않았다.

우선 parser/help를 I/O 앞에 연결하고, unknown/extra argv는 설치 시작 전에 거부해야 한다.
정상 무인자 설치의 양성 대조군도 함께 유지한다.

### 2. trace anonymize가 초과 인자를 무시하고 출력 파일을 덮어쓴다

`trace anonymize in.trace out.trace unexpected-extra`가 exit 0이며 기존 out.trace를 덮어쓴다.
`cli.trace.parse`가 args.len >= 3이면 세 번째 인자만 output으로 취하고 이후 인자를 무시한다.
최소 trace header fixture와 sentinel output으로 실제 write를 재현했다.

지원된 인자 개수 밖의 요청은 read/write 전에 거부해야 한다. 정상 input+output과 stdout 출력은
양성 대조군으로 유지한다. trace --help/trace anonymize --help도 별도 도움말 계약을 정리한다.

### 3. 일부 RPC 오류가 성공 종료로 반환된다

격리 fake Unix socket의 정상/JSON-RPC 오류/malformed JSON 대조에서:

| 명령 | 정상 응답 | RPC error | malformed JSON |
| --- | --- | --- | --- |
| sessions list | exit 0, 정상 목록 표시 | error 표시 후 exit 0 | error 표시 후 exit 0 |
| browser get-url | exit 0, 정상 URL 표시 | error 표시 후 exit 0 | error 표시 후 exit 0 |
| editor lsp trust list | exit 0 | exit 1 | exit 1 |

sessions.renderResponse/browser.renderResponse가 오류를 글자로 출력한 뒤 void success로 반환하고,
caller가 이를 process failure로 옮기지 않는다. shell 자동화는 오류를 성공으로 오인할 수 있다.
LSP의 명시적 outcome→exit 정책과 같이 응답 오류를 nonzero로 전파할 필요가 있다. browser의
exec/screenshot/streaming/wrapped-result 경로 전체를 이 표만으로 같은 결함이라고 주장하지 않는다.

### 4. root help의 공개 명령 누락과 help 규칙 불일치

incidents/control/agent-events/agent-hooks는 dispatcher·독립 계약이 있지만 root help에 없다.
root -h는 unknown command로 exit 1이다. terminfo/control/trace --help도 exit 1이며,
host status --help와 runtime list/get/end --help는 usage error다. root help에서 지원하는
문법과 실제 parser를 맞추고, 사람용 help와 remote transport용 entrypoint의 표시 범위를 정리한다.

browser root description의 4개 verb 목록과 실제 18개 verb도 맞지 않는다. 명령 자체의 browser
help는 현재 verb를 나열하므로 root 안내를 갱신하면 된다.

### 5. 중복 대상 옵션은 마지막 값을 취한다 — 정책 정리 필요

실제 private socket에 보내진 request를 검사했다:

- sessions list --window 1 --window=2 → window 2.
- browser get-url --surface 1 --surface=2 → surface id 2.
- editor lsp trust revoke /fixture/repository --volume a --volume=b → volume b.

현재 parser는 이전 값 유무를 검사하지 않고 필드를 덮어쓴다. editor open·attach·runtime의 일부
옵션은 중복을 거부하므로 공통 원칙이 갈린다. last-wins를 쓰는 자동 호출의 호환성부터 확인한 뒤,
특히 변경 대상/권한 대상 selector의 중복을 거부할지 결정해야 한다. 이를 승인된 문서의 명시적
중복 거부 정책 위반이나 보안 우회로 단정하지 않는다. agent-hooks/agent-events/incidents에도
source상 값 옵션을 덮어쓰는 경로가 있으나 여기서는 live provider 변경/stream 실행을 하지 않았다.

## 이상이 없었던 경계와 한계

- editor editor, editor editor open file, editor lsp editor는 무전달 오류다.
- editor open editor와 editor open -- --help는 해당 이름의 파일 요청이다.
- UINT64_MAX surface/window 값, UINT32_MAX+1 editor line, usize overflow incident limit은
  검사한 process에서 nonzero로 거부됐고 panic하지 않았다. cast 존재만으로 overflow 결함을 판정하지 않는다.
- host/runtime/attach, sessions/session, remote agent/helper 명령은 소유 자원과 기존 계약이 다르다.
  같은 CLI라는 이유만으로 전부 editor에 넣지 않는다. agent namespace 통합은 별도 UX/호환성 결정이다.
- 모든 테스트는 private HOME/cache와 생성 파일, fake endpoint를 사용한다. SSH exec는 test-only
  DYLD interposer로 차단했으며 remote 연결·hook 설치·실제 신뢰 표 변경·실제 browser 동작은 하지 않았다.
- 전체 CLI의 실제 업무 기능/모든 정상 payload/모든 OS/GUI/TTY/long stream 검증을 새로 끝낸 것은 아니다.
  이번 전수 범위는 route/namespace/help/기본 입력 경계와 재현된 의심 경로다.

## 로컬 증거

`~/.cache/maru-cli-command-audit-20261009/`:

- audit.py, result.json: root inventory와 실제 process 사례.
- cases/: 각 private HOME, argv/stdout/stderr/exit 및 파일 write 결과.
- duplicate-targets-confirm.json: 중복 selector의 실제 wire 및 RPC 오류 exit.
- response-status.json: 정상/RPC 오류/malformed JSON 대조군.
- numeric-results.json: 숫자 상한 process 검사.

문서에는 생성 fixture 설명과 재현 명령만 적고 원본 artifact·PNG는 커밋하지 않는다.

## 적대적 재검증 결과

독립 HOME/cache와 fake socket을 매회 새로 생성해 전체 입력 점검과 RPC·selector 대조를
5회 반복했다. 매회 99개 실제 CLI process를 실행했다. 잘못된 install-cli 인자의 symlink
교체, trace 초과 인자의 sentinel 덮어쓰기, sessions/browser의 RPC 오류·malformed JSON
성공 종료, root help 누락과 중복 selector의 last-wins가 모두 동일하게 재현됐다.
정상 무인자 설치·정상 trace 출력·정상 RPC 응답 및 LSP 오류의 nonzero 종료 대조군도 확인했다.
검사 범위 안에서 추가 결함은 발견하지 못했다. 발견 사항의 제품 수정은 아직 하지 않았다.

반복 harness와 요약은 기존 증거 디렉터리의 `repeat-five.py`, `five-repeat-results.json`,
개별 증거는 `/tmp/maru-cli-hostile-{1..5}-20261009/`에 있다. CLI artifact는 위 SHA256과 같다.

## 승인된 수정 계약

사용자 요청에 따라 설치·trace의 인자 검증을 I/O 앞에 두고, sessions/browser의 표시된
응답 오류는 exit 1로 전파한다. 정상 응답과 정상 설치·익명화는 유지한다. install-cli는
무인자만 설치하며 단독 --help/-h는 exit 0으로 안내한다. trace는 namespace/verb help를
지원하고 anonymize의 input 및 optional output 밖 토큰을 거부한다. root help에 공개
제품 명령을 추가하고 browser 설명을 실제 namespace에 맞춘다. 중복 selector의 last-wins는
이번 수정에 포함하지 않으며 별도 호환성 검토 대상이다.

## 수정 결과

설치 인자 검증과 trace parser 상한·help를 I/O 전에 연결했다. sessions/browser renderer는
표시한 응답 오류를 false outcome으로 반환하고 runner가 기존 graceful exit 1 경로로
전달한다. 빈 목록·빈 snapshot/console는 true outcome이다. root help에 incidents/control/
agent-events/agent-hooks와 browser usage를 추가하고 browser 설명을 갱신했다.

`tools/test-cli-failure-contract.py --repeat 5`의 실제 process 회귀 검증에서 매회 35개
검사가 통과했다. 일반 파일·설치된 symlink와 기존 trace 출력의 보존, 정상 설치·파일/
stdout trace 익명화, RPC 오류·malformed JSON·notification만 보낸 뒤 EOF의 nonzero,
정상 RPC·빈 wrapped result의 성공을 함께 확인했다. 순수 CLI suite도 Debug/ReleaseFast에서
107 passed, 1 skipped로 통과했다. 중복 selector 정책 및 모든 namespace의 help flag
일괄 변경은 이 수정 범위 밖이다.

수정 전 native CLI를 동일한 process 판정자에 넣은 음성 대조군은 install help의 파일 보존
단언에서 실패했다. 순수 suite는 전체 test에 포함되며 `test-cli-failure-process`는 POSIX
실제 process 검증의 opt-in build step이다.

## CI 컴파일 회귀 보완

PR CI의 file explorer 및 macOS-only 잡은 같은 누락으로 실패했다. renderer를 !bool로
바꾸면서 macOS control_socket의 RoundTripHarness 호출이 반환값을 처리하지 않았다.
성공·의도된 RPC 오류의 표시 문자열을 모두 검사하는 harness이므로 outcome을 명시적으로
버리고 기존 문자열 검사를 유지한다. 제품 runner의 실패 종료 전파는 유지한다.
`zig build test-macos-control-socket`으로 실제 socket 왕복 suite를 직접 실행할 수 있게 했다.
수정 전 이 명령에서 CI와 같은 bool ignored 컴파일 오류를 재현했다.

## browser 단일 대상 정책 적용

2026-10-10 사용자 결정에 따라 browser의 대상 surface는 한 호출에서 한 번만 지정한다.
같은 ID 반복과 `--surface N`/`--surface=N` 혼용도 DuplicateSurface로 거부한다.
대상이 필요한 17개 verb의 일곱 parser 경로가 공통 assignSurface로 값을 설정하며
socket runner 전에 종료한다. browser list의 무대상 계약은 유지한다. sessions --window
및 LSP --volume는 이 surface 수정 범위에 포함하지 않았다.

Debug 및 ReleaseFast 순수 suite는 108 passed/1 skipped다. 실제 process 회귀 검증
5회에서 매회 171개 검사가 통과했다. 접근 가능한 private socket을 두고 136개 중복
호출의 exit 1, 명확한 진단, 연결 0건 및 screenshot 출력 sentinel 보존을 확인했다.
정상 호출과 기존 오류 종료 대조군도 유지했다. assignSurface의 중복 방어를 제거한
변형은 새 판정자에서 실패했다. script/text/파일명 값의 --surface 문자열은 옵션으로
다시 해석하지 않는다.

## CLI 도움말 통일 계약

2026-10-10 사용자 승인: root -h를 --help 별칭으로 지원한다. terminfo와 control은
단독 --help/-h를 exit 0 안내로 처리하며 캐시/소켓/relay I/O를 시작하지 않는다.
host status 및 runtime list/get/end의 leaf help도 exit 0이다. get/end help는 ID 없이도
볼 수 있다. 알려진 verb의 유효한 ID/옵션과 함께 요청한 help는 작업을 실행하지 않는다.
알 수 없는 verb/옵션, 잘못된 ID 및 중복 옵션은 help로 숨기지 않고 오류로 거부한다.
SSH의 외부 argv 전달 및 개발용 진단 명령의 계약은 유지한다. --window/--volume의
중복 정책은 별도 작업이다.

도움말 수정의 실제 process 회귀 검증은 5회 각각 203개 검사가 통과했다. 파일 내용과
symlink를 포함한 상태가 보존됐으며 접근 가능한 fake control endpoint에 연결하지 않았다.
Debug/ReleaseFast 순수 suite는 126 passed/1 skipped다. relay suite는 기존 9개와 새
help 테스트 1개 및 실제 모듈 그래프의 anonymous block 23개를 확인해 총 33개 기록을
갱신했다(32 passed/1 skipped). 도움말 판정을 무력화한 runtime 변형은 leaf help 테스트에서
UnknownOption으로 실패했다. 다른 selector의 중복 정책은 이번 구현에서 바꾸지 않았다.

## window·volume 단일 대상 계약

사용자 승인된 후속 작업: 실행 요청에서 sessions list의 --window 및 LSP revoke/forget의
--volume도 각 한 번만 지정한다. 같은 값, 0, 정규화하면 같은 숫자 및 공백/= 표기 혼용
모두 중복으로 거부하며 socket 연결/auth/request 전에 exit 1이다. canonical editor lsp와
기존 lsp 별칭에 같은 parser·계약을 적용한다. 정상 단일 대상, 생략 가능한 대상 옵션,
기존 도움말 및 wire/auth 의미는 유지한다. 여러 대상은 별도 호출로 실행한다.

window·volume 수정 전의 private socket 재현은 /tmp/maru-selector-baseline-*/result.json에
기록했다. 창 0→2 및 canonical/legacy LSP 볼륨 0→A가 실제 wire에서 마지막 값으로
바뀌었다. 수정 후 Debug/ReleaseFast 순수 suite는 137 passed/1 skipped다. 실제 process
회귀 5회는 매회 342개 검사가 통과했다. 새 중복 120개(window 24, 양쪽 LSP alias의
revoke/forget 96개)는 정상 접속 가능한 endpoint에 연결하지 않았고, 정상 단일/생략 요청의
wire 및 inherited pane 환경에서도 LSP auth selector 없는 계약을 대조했다. 각 중복 방어를
제거한 변형은 해당 순수 판정자에서 실패했다. artifact는 저장소에 넣지 않았다.

## 실제 CLI process CI 게이트

사용자 승인된 후속 작업: 기존 Ubuntu check 잡의 코드 변경 경로에서
`zig build test-cli-failure-process`를 한 번 실행한다. 기본 순수 test와 별도로 실제 native
CLI artifact를 실행하며 설치된 zig-out 또는 사용자 PATH의 CLI를 재사용하지 않는다.
private /tmp HOME·cache·socket으로 도움말/잘못된 인자의 부작용 부재와 정상·오류 RPC의
종료 상태를 대조한다. GUI/TCC나 실 session host는 필요하지 않다. 새 matrix는 추가하지 않는다.
성공·실패 호출 기록은 tests/artifacts/cli-failure 아래 JSON으로 보존해 기존 check artifact가
업로드한다. 검증 실패 전까지의 기록도 남긴다. /tmp의 짧은 socket 경로는 유지한다.

CI 배선 검증에서 실제 native CLI의 342개 process 검사가 통과했다. 기록을 매 호출마다
남기면서 help 파일 보존 판정에 검증 도구 자신의 results.json 변경이 섞이는 문제가 발견돼,
그 정확한 기록 파일만 비교에서 제외했다. 사용자 상태 파일·symlink 검사는 유지한다.
실패 실행 파일 음성 대조군은 nonzero로 종료했고 첫 실패 호출 JSON이 보존됐다.

추가 실패 경로 검증에서 첫 subprocess가 timeout/spawn 예외를 내면 JSON이 없음을 재현했다.
이제 timeout의 partial stdout/stderr 및 spawn 진단을 exit=null과 failure 종류로 기록한 뒤
원래 예외를 전파한다. 성공 exit 0으로 바꾸지 않는다. 문서 충돌은 upstream 내용을 보존하고
CLI 검증 절을 상단 CLI 관련 절에 배치해 해결했다.

최종 변경의 적대적 검증은 5회 독립 루트에서 실제 CLI 342개 호출과 exit mismatch,
help 파일 변경, 첫 timeout, 첫 spawn 실패, panic 출력 및 0/음수 반복 거부를 대조했다.
모든 정상 대조군이 통과했고 변형은 의도한 실패로 검출됐다. timeout/spawn의 실패 JSON과
partial output 보존도 확인했다. 검증 artifact는 저장소에 커밋하지 않는다.

## agent-hooks 단일 옵션 계약

사용자 승인된 후속 작업: agent-hooks install/uninstall의 --provider=, --dir=, --scope=는
각 한 번만 지정한다. 같은 값 반복과 다른 값 반복 모두 usage 오류(exit 2)로 거부한다.
provider 설정·trust 파일 읽기/쓰기·락·로그 디렉터리 생성 전에 종료한다. 기존 = 문법,
필수 옵션·provider/scope 값·절대 경로 규칙 및 정상 설치/삭제는 유지한다. 기존 help 선행
판정은 유지하며 중복 옵션과 help를 함께 주더라도 설정 변경 없는 도움말(exit 0)이다.
agent-events/incidents와 원격 셸 커맨드 생성·provider 훅 바이트는 이 범위 밖이다.

검증 계획: private HOME뿐 아니라 CLAUDE_CONFIG_DIR/CODEX_HOME도 격리한다.
중복 provider·dir·scope의 같은/다른 값, 옵션 순열과 옵션처럼 보이는 경로를 검사한다.
정상 install/uninstall과 재설치의 대조군을 두고 설정 및 trust 파일·디렉터리 상태 보존을
실제 CLI 프로세스로 확인한다. 기존 process CI gate에 포함하고 방어 제거 변이도 검출한다.

수정 전 native CLI의 private HOME/CLAUDE_CONFIG_DIR/CODEX_HOME 재현에서 중복 provider는
마지막 codex의 hooks.json·config.toml을 썼고, 중복 dir는 마지막 로그 경로를 만들었다.
같은 scope 반복도 설치가 실행됐다. 증거는 /tmp/maru-hooks-baseline-ielm5mu7/results.json이다.
수정은 순수 parseArgs의 각 필드 할당 전에 존재 여부를 검사하며 기존 usage 오류 경로를 쓴다.

Debug/ReleaseFast 순수 suite가 통과했고 실제 process gate는 없는 설정과 설치된 설정 모두에서
중복 요청의 exit 2 및 설정/trust bytes·디렉터리 권한 보존을 확인한다. 양 provider의 정상 설치,
무변경 재설치, 삭제와 사용자 설정 sentinel 보존을 같은 자리에서 대조한다. provider 환경 변수도
명시적으로 private 경로로 고정했다. 수정 전 CLI는 새 process 판정자에서 중복 설치의 exit 0으로
실패했다. provider·dir·scope 방어 각각을 무력화한 세 변형은 컴파일 후 새 테스트에서 실패했고,
동등 provider 검사 변형은 통과했다(/tmp/maru-hooks-mutations-vkbtzh9r/results.json).

실제 CLI 회귀 검증 5회에서 매회 608개 호출이 통과했다. 새 검사는 hook/trust 생성·삭제를
명시적인 정상 대조군으로 확인하고, 초기/설치된 상태의 중복 요청과 help가 이를 바꾸지 않는지
검사한다. 기존 CI process 게이트에 포함되며 별도 provider 또는 SSH 실행은 하지 않는다.
구현은 완료됐고 최종 PR CI 결과는 해당 checks로 추적한다.

## agent-events 단일 값 옵션 계약

사용자 승인된 후속 작업: agent-events의 --dir=, --heartbeat-ms=, --resume=는 각각 한 번만
지정한다. 같은 값, 0 heartbeat, 빈 resume 및 정규화하면 같은 숫자도 반복은 usage 오류(exit 1)다.
hello 출력·로그 디렉터리 열기·정리·이어읽기·하트비트 루프 전에 종료한다. 필수 --stdio와
절대 경로, 기존 = 문법 및 생략 시 기본값은 유지한다. --stdio 반복의 기존 idempotent 동작은
값 옵션 변경 범위 밖이다. help의 기존 좌→우 판정을 유지한다: help 전에 오류를 만나면 실패,
help를 먼저 만나면 exit 0 안내다. resume 사양 내부의 항목 정책은 별도 범위다.

검증 계획: private HOME/cache/logs 및 직접 소유한 자식 CLI만 사용한다. 중복 요청은 빠르게
exit 1이며 stdout/hello 없음과 파일·디렉터리 mode/bytes 보존을 확인한다. 정상 스트림은
hello·로그 event·이어읽기 cursor·heartbeat를 실제 pipe로 검사하고 항상 종료·회수한다.
GUI/provider/SSH/tmux는 사용하지 않는다. 기본 CLI process CI gate에 포함하며 세 방어 제거
변이와 정상/동등 대조군을 확인한다.

수정 전 실제 CLI에서 중복 dir의 마지막 로그가 출력됐고, heartbeat 0→200은 heartbeat를
다시 활성화했으며 resume a:23→a:0은 앞 이벤트를 재생했다. 자식은 재현 도구가 소유하고
종료·회수했다. 증거는 /tmp/maru-events-baseline-0q8fo6pg/results.json이다.

parseArgs가 dir 존재와 heartbeat/resume의 별도 seen bit를 할당 전에 검사한다. 0과 빈 문자열도
지정된 값으로 센다. main은 기존 usage 오류(exit 1)를 hello와 로그 정리 전에 전파하며,
도움말에는 기존 지원 옵션인 resume와 값 옵션 단일 지정 안내를 추가했다.
Debug/ReleaseFast 순수 검증은 304 passed/1 skipped로 통과했다. 실제 process 판정자는 24개
옵션 순열과 7개 중복값의 거부, 오래된 로그 보존, help 순서, 정상 hello/event/cursor/heartbeat,
이어읽기 중간/끝 위치를 확인한다. 스트림은 테스트 도구가 직접 종료·회수하며 JSON에 이를
표시한다. tmux 옆 파일·SSH·provider 프로세스는 사용하지 않는다.

dir/heartbeat/resume 방어 각각을 무력화한 변형은 컴파일 후 새 순수 판정자에서 실패했고,
동등 dir 검사 변형은 통과했다(/tmp/maru-events-mutations-x4sw5nsm/results.json).
수정 전 CLI는 새 process 판정자에서 중복 옵션인데 스트림이 시작돼 timeout으로 실패했다.
hello 출력도 함께 기록됐다(/tmp/maru-events-old-negative-lgnmu8xr).

최종 실제 CLI 검증 5회에서 매회 788개 프로세스 검사가 통과했다. 기본 CLI CI 게이트가
같은 중복 거부와 정상 스트림 대조군을 실행한다. 구현은 완료됐고 최종 CI 결과는 PR에서
추적한다. 도움말의 기존 순서와 boolean stdio 반복은 유지한다.

## incidents limit 단일 지정 계약

사용자 승인된 후속 작업: incidents list의 --limit은 한 번만 지정한다. 같은 값과 다른 값,
앞자리 0 및 기본값과 같은 값 반복도 usage 오류(exit 2)로 거부한다. parser 단계에서
디렉터리 열거·incident 파일 읽기·digest 검사 전에 종료한다. 기존 --limit N 문법과
양수 usize 상한, 생략 시 default_limit, boolean --json 반복은 유지한다. --limit=N은 기존처럼
지원하지 않는다. help의 기존 순서 판정을 유지해 중복보다 help가 먼저면 exit 0 안내,
중복이 먼저면 오류다. 새로운 문법/종료 코드 정책은 추가하지 않는다.

검증 계획: private HOME/cache의 유효한 incident 봉투 여러 개를 사용해 실제 CLI가 최신순으로
단일 limit만큼 조회하는지 대조한다. 기본 조회·빈 목록·손상된 artifact 처리도 유지한다.
중복은 stdout 없이 즉시 실패하고 파일 조회 진단에 도달하지 않는지 확인한다. artifact bytes와
mode는 보존하고 기존 실제 process CI gate에 포함한다. 방어 제거 변이와 정상/동등 대조군도
확인한다. 부모 PR #4288은 최종 CI 통과 후 머지됐고, 이 수정은 최신 main으로 리베이스했다.

구현은 limit_seen으로 첫 지정 여부를 기억한다. default_limit과 같은 값을 첫 인자로 준
경우도 명시적 지정이며, 중복은 DuplicateLimit으로 값 소비 전에 거부한다. main의 기존
usage 경로(exit 2)와 인자 순서에 따른 help 동작을 유지한다.

검증 도구의 현재 encoding_version=1 golden 봉투 3개는 Maru EmergencyRing.publish로
생성했다. Python에서 Blake3 writer를 재구현하거나 새 의존성을 추가하지 않는다. 각 봉투의
sequence/timestamp는 1, 2, 3이며 파일 mtime은 반대로 설정해 봉인된 시간의 최신순 정렬을
독립 기대값으로 검사한다. 정상 단일 limit·기본값·최대 usize, 빈/없는 디렉터리, wrong-size와
digest 손상 제외를 실제 CLI에서 대조한다. 중복 요청은 stdout 없이 exit 2로 실패하고 없는
디렉터리 진단에도 도달하지 않는다. artifact bytes/mode는 보존된다.

Debug/ReleaseFast 순수 판정자는 344 passed/1 skipped로 통과했다. 중복 방어를 무력화한
변형은 컴파일 후 새 테스트에서 실패하고 동등 조건 변형은 통과했다
(/tmp/maru-incidents-mutations-50fkwv_b/results.json). 수정 전 native CLI도 새 process
판정자에서 중복 요청의 exit 0과 파일 조회 진단으로 실패했다
(/tmp/maru-incidents-old-negative-rixonaa3). 생성·재현 결과 파일은 저장소에 커밋하지 않는다.

실제 CLI 검증은 독립 HOME/cache에서 5회 반복해 매회 936개 검사가 통과했다.
새 limit 검사들은 기존 CI process 게이트에 포함된다. 정상 조회와 오류의 기대값은 고정
sequence 순서로 대조하며 incident codec/digest 자체를 이번 수정에서 변경하지 않는다.

## incidents CI libc 링크 보완

PR #4289의 Ubuntu check는 새 incidents import가 수집한 connection_incident의 POSIX
fork/getpid 소유권 테스트를 컴파일하며 실패했다. cli_failure_tests에 libc 링크 선언이
없었고 macOS에서는 시스템 라이브러리의 암묵적 링크 때문에 로컬 검증으로 드러나지 않았다.
Linux target 컴파일에서 같은 오류를 재현했다. Linux/macOS의 해당 테스트 모듈에 libc를
명시적으로 링크한다. core 테스트를 빼거나 skip하지 않으며 제품 parser/writer는 바꾸지 않는다.
Linux target의 링크 누락 오류를 수정 전 컴파일에서 재현하고, libc 명시 후 같은 모듈을
컴파일했다. Ubuntu 24.04 ARM64 컨테이너에 해당 테스트 실행 파일과 소스를 읽기 전용으로
전달해 실제 Linux POSIX fork 검증을 포함한 344개 테스트가 통과했다(1개 건너뜀).
이 로컬 검증은 실행 중 네트워크를 끄고 private tmp만 쓰며, CI 의존성이나 사용자 설정은 바꾸지 않는다.

## agent-events 내부 중복 커서 — 구현 완료

사용자 승인 후속 작업: 하나의 `--resume=` 목록에서 파일 이름은 한 번만 지정한다. 같은
offset, 다른 offset, 앞뒤 순서, 숫자의 선행 0과 무관하게 동일 이름은 usage 오류(exit 1)다.
서로 다른 이름, 접두 관계 이름과 빈 목록은 유지한다. 이름은 기존 토큰의 정확한 바이트로 비교한다.
help가 선택되면 목록 검증이나 디스크 접근 없이 종료하는 기존 우선순위를 유지한다.

실제 CLI에서 `--resume=a:23,a:0`은 first·second를 재출력하고, 역순은 second만 출력했다.
원인은 runAgentEvents의 getOrPut 이후 found_existing에도 offset을 다시 쓰는 초기화다.
기존 커서 맵을 hello 전에 초기화해 중복을 거부한다. 별도 개수 제한이나 의존성을 추가하지
않으며 쌍별 비교를 피한다. 할당 실패도 이벤트 재생으로 대체하지 않고 출력 전에 실패한다.

검증: 동일/다른 offset·비인접 중복·접두 이름·여러 독립 파일·빈 resume·help 순서,
거부 전후 stale 및 대형 로그 보존, 실제 스트림의 독립 파일 이어읽기, 할당 실패와
중복 가드 무력화 돌연변이를 확인한다.

검증 결과: Debug·ReleaseFast에서 346 pass/1 skip, 실제 CLI 959개 검사 반복 실행 통과,
Ubuntu 24.04 ARM64에서 동일 단위 검사 통과. `seedResumeCursors` 중복 가드를 무력화한
컴파일 가능한 변형은 TestExpectedError로 실패하고, 등가 비교 변형은 통과했다.
문서 링크와 행 인용 검사 통과. 기존 help·빈 목록·파일별 이어읽기를 유지하며
중복 커서는 stdout 없이 종료하고 stale·대형 로그의 바이트를 보존했다.

## agent-events 회전·출력 실패 검증 — 구현 완료

실제 CLI의 private 로그와 소유한 stdout pipe로 축소 회전, 새 파일 생성, 재접속 및
대형 로그 절단 전 출력 실패를 재현한다. 스트림 생성 이후 대형 로그를 넣어 기존 시작 시
정리 정책과 분리한다. 파일별 cursor와 event 순서를 독립적인 기대값으로 대조한다.
정상 소비·절단·reset cursor는 양성 대조군이며 바이트와 권한 보존도 확인한다.

읽었다는 사실만으로 로그를 비우지 않는다. stdout 버퍼의 이벤트와 cursor가 flush에
성공한 뒤에만 소비 완료에 따른 절단을 허용한다. stdout 실패는 nonzero 종료하며,
절단 뒤 reset cursor의 출력 실패도 무시하지 않는다. 기존 wire version·시작 시 backlog
정리·크기 기반 회전 감지 정책은 유지한다. peer ACK 및 같은 크기 이상으로 재생성된
파일 세대의 식별은 현재 offset 프로토콜만으로 보장할 수 없으며 별도 설계 범위다.

수정 전 실제 CLI에서 1 MiB prefix 뒤의 짧은 미소비 tail을 읽도록 resume를 지정하고,
시작 시 정리가 끝난 뒤 stdout pipe를 닫고 로그를 넣었다. exit 1/WriteFailed였지만
1,048,598바이트 파일이 0바이트가 됐다. 기록은
`/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/maru-stream-baseline-7e3b7tjn/result.json`이다.
초기 heartbeat 200ms 실험은 다음 heartbeat 출력에서 먼저 실패해 이 경로에 도달하지
않았다. 회귀 하네스는 첫 heartbeat로 시작 시 정리 완료를 확인하고, heartbeat 주기
안에 로그를 넣어 작은 tail을 소비하게 한다.

`runAgentEvents`는 소비 완료 절단 직전에 stdout.flush를 try하며 실패면 로그를
보존한다. 절단 뒤 reset cursor 생성·출력·flush도 try로 전파한다.
`tools/agent_events_stream_recovery.py`를 기존 실제 CLI process 게이트에서 호출한다.
같은 크기 이상 파일 교체, 읽기와 append/절단 사이의 경쟁, transport 수락 후 peer
처리 실패는 offset만으로 원자성·정확히 한 번 전달을 보장하지 못하며 별도 설계 범위다.

검증 결과: Debug와 ReleaseFast에서 실제 CLI 965개 검사 통과, Debug 반복 실행 모두
통과, 단위 검사 346 pass/1 skip 및 전체 check-boundaries와 문서 검사 통과.
절단 전 flush를 `if (false)`로 무력화한 변형은 컴파일 뒤 실제 CLI 검사에서
`output failure erased log`로 실패했고 `if (true)` 등가 변형은 통과했다.
원본 소스를 복구하고 native CLI를 다시 빌드했다. 변형 증거는
`/tmp/maru-stream-mutations.json`이며 생성 파일은 커밋하지 않는다.
