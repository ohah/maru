# `maru editor open` 구현 계획

## 계약

`maru editor open <file> [-l N | --line N] [-c N | --column N]`은 macOS의 기본 `maru` URL handler에
파일 하나를 전달한다. `--help`는 모든 플랫폼에서 지원하고 실행은 macOS에 한정한다.
줄·열은 앱 URL의 1-based/u32·UTF-16 계약을 따른다. column은 line과 함께만 허용한다.
`maru editor`와 `maru editor --help`는 명령 목록을, `maru editor open --help`는 파일 열기 도움말을 표시한다.
`--line`/`-l`과 `--column`/`-c`는 같은 옵션이며 긴/짧은 형태를 섞어 중복해도 거부한다.
옵션은 파일 앞뒤에 둘 수 있고, `--` 뒤에는 옵션처럼 보이는 파일명도 받는다.
중복 옵션·빈 경로·여러 파일·알 수 없는 옵션·0/음수/overflow는 전달 전에 거부한다.

절대 경로는 그대로 두고 상대 경로는 실제 CLI cwd와 연결한다. `..`나 symlink를 미리
정규화하지 않는다. cwd 취득은 main의 I/O 경계가 소유한다. 파일 existence/stat은 CLI가
검사하지 않는다. 앱이 기존 동일 descriptor의 regular-file 검사와 native 열기를 소유한다.
경로는 URL unreserved byte만 그대로 두고 나머지는 percent-encode한다. 앱 parser의
path/URL 상한과 UTF-8/control 거부를 재사용한다. 전달 argv는 `/usr/bin/open`, URL 두
항목이며 shell·`-a`·handler 변경·trust 승인·workspace 등록이 없다.

종료 0은 OS 전달 도구의 성공을 뜻하며 앱의 파일 열기 완료 ACK가 아니다. `/usr/bin/open`의
종료 코드는 그대로 전달한다. CLI 사용 오류와 지원하지 않는 플랫폼은 기존 CLI의 exit 1
정책과 짧은 stderr 안내를 따른다. ACK·다중 파일·wait·새 창은 이 계약 밖이다.

## 단계와 검증

1. 순수 parse/URL builder failing test, URL parser roundtrip 및 독립 기대 문자열.
2. 순수 namespace `src/cli/editor.zig` 및 `src/cli/editor/open.zig`와 얇은 main dispatch/exec 어댑터.
3. 실제 CLI help/오류/특수 경로 전달, 독립 oracle과 변이/동등 대조군, ReleaseFast,
   build/check-boundaries. OS 수신은 격리 HOME의 앱 receipt로 확인한다.
4. README·명령·구조·검증 문서와 PR을 갱신한다. 이미지 파일은 커밋하지 않는다.

## 설계 공격에서 확인한 경계

- shell injection: exec argv만 사용한다. `$()`·backtick·quote·newline 중 newline은 앱 정책으로 거부.
- option injection: 경로 자체를 open 인자로 넘기지 않고 고정 scheme의 URL로 전달한다.
- double decoding: `%`도 인코딩하여 파일의 literal `%2F`를 보존한다.
- symlink/`..`: lexical resolve/realpath(file)로 다른 파일을 선택하지 않는다.
- 가짜 성공: exit 0과 문서 열기 receipt를 분리한다. 없는 파일도 전달 성공일 수 있다.
- default handler: 설치 경로나 특정 빌드에 고정하지 않고 사용자의 OS 기본 연결을 따른다.
- 실패/OOM: URL 소유 메모리 정산과 parser roundtrip으로 한계 우회를 검사한다.

## 상태

구현과 로컬 검증 완료. required CI는 PR에서 별도로 확인한다.

## 구현 중 발견과 수정

실제 CLI에서 `Dir.cwd().realPath`가 macOS의 AT_FDCWD를 F_GETPATH에 넘겨 실패했다.
기존 CLI의 libc `getcwd` 방식으로 바꿔 상대 경로 기준을 실제 process cwd에서 얻는다.
OS handoff는 기존 사용자 앱에 테스트 문서를 주입하지 않고, test-only DYLD interposer로
실제 CLI의 exec argv와 실행 거부를 검사한다. 기존 설치본 URL 수신 gate와 구분한다.

실제 process에서 빈 도움말 출력도 발견해 stdout flush를 추가했다.
Debug/ReleaseFast, argv/exec 실패, 변이 및 동등 대조군, 전체 check-boundaries를 통과했다.
격리 앱의 실제 OS event는 독립 byte 11/5/5와 동일 문서 재사용을 확인했다.
OS 하네스는 test-only adapter로 앱과 HOME을 고정하며 기본 handler 선택과 종료 확인 UX는 별도다.
GUI launchd의 Documents 접근 실패는 byte-identical CLI를 캐시에 staging해 해결했다.
사용자 앱과 기본 연결을 유지하며 새 bundle ID의 fixture만 정리한다.

로컬 증거:
- `~/.cache/maru-editor-open-cli-process-v4-20261009/result.json`
- `~/.cache/maru-editor-open-cli-adversarial-20261009/results.json`
- `~/.cache/maru-editor-open-cli-os-reviewed-20261009/result.json`

사용자 피드백에 따라 기존 `maru browser`와 같은 namespace로 `maru editor open`을 선택하고
`-l`/`-c` alias를 추가했다. 이번 PR에서 아직 배포하지 않은 루트 `maru open` alias는 제공하지 않는다.

## main 리베이스와 namespace 검증

main `f2de9882c`에 리베이스했다. 검증 문서의 충돌은 main의 최신 검색 도크 내용과
에디터 CLI 절을 모두 보존해 해소했다. root/editor/open 도움말의 실제 stdout, short/long
alias와 혼합 중복 거부, unknown subcommand 무전달, 기존 루트 open 거부를 process에서 검사했다.
새 namespace의 OS receipt는 byte 11/5/5와 동일 surface를 유지했다.
현재 검증 증거는 `~/.cache/maru-editor-cli-namespace-process-20261009/result.json`과
`~/.cache/maru-editor-cli-namespace-os-20261009/result.json`이다.

적대적 반복 검증은 새 빈 디렉터리와 독립 캐시로 5회 실행했다. 인코딩·좌표·중복 옵션·cwd·
receiver validation·short line 오해 변이는 assertion에서 거부됐고 정상/동등 대조군은 통과했다.
추가 제품 결함은 발견되지 않았다. source SHA에 귀속된 로컬 집계는
`~/.cache/maru-editor-cli-rebase-adversarial-20261009/summary.json`이다.

LSP 신뢰 관리의 canonical 명령은 `maru editor lsp trust list|revoke|forget …`이며,
기존 `maru lsp …`는 동일한 parser와 request 실행 경로를 쓰는 호환 별칭이다.
`maru editor lsp --help`와 기존 별칭의 도움말은 canonical 사용법을 표시한다.

LSP namespace는 기존 신뢰 정책과 wire 메서드를 바꾸지 않는다. 실제 process의 격리 fake socket에서
list/revoke/forget의 canonical·legacy 요청 바이트와 결과가 같고 auth selector가 없는 것을 확인했다.
실제 앱의 신뢰 표는 변경하지 않았다. `editor editor`는 무전달 오류이며 `editor open editor`는
파일명 editor로 전달한다. 로컬 증거: `~/.cache/maru-editor-lsp-process-final-20261009/result.json`과
같은 폴더의 `lsp-wire.json`. namespace 자체의 topic 누락과 unknown command 허용 변이를 추가했다.

최종 LSP namespace도 독립 캐시의 적대적 검증 5회와 Debug/ReleaseFast·전체 boundary·Windows 교차 빌드를
통과했다. 추가 제품 결함은 없으며 topic 전달 훼손과 unknown namespace 허용 변이는 assertion에서 거부됐다.
집계: `~/.cache/maru-editor-lsp-adversarial-20261009/summary.json`.
