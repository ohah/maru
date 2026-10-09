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
