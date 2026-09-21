#!/bin/sh
# 훅 인라인 커맨드가 **실제 셸에서** 계약대로 도는지 본다(docs/agent-hooks.md §4.1).
#
# 왜 별도 게이트인가: `agent_hook_command.zig` 의 단위 테스트는 만들어진 **문자열**만 본다. 그 문자열이
# `/bin/sh` 에서 실제로 stdin 을 삼키고, 가드에서 빠져나가고, 상한을 접고, 언제나 0 으로 끝나는지는
# 셸을 돌려야만 안다. 훅이 이 계약 중 하나라도 어기면 **에이전트 턴이 멈춘다** — 그래서 문자열 검사로
# 끝내지 않는다.
#
# 커맨드는 fixture(tests/golden/agent_hook_command.sh)를 쓴다. 그 fixture 가 낡지 않았는지는 아래에서
# 빌더의 표식 상수와 대조해 본다(zig 쪽은 `@embedFile` 이 패키지 경로 밖을 못 읽어 파일 비교를 못 한다).
# 역할 분담: zig 테스트는 «빌더가 뱉는 구조», 이 게이트는 «셸에서 실제로 도는 동작».
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
golden="$root/tests/golden/agent_hook_command.sh"
[ -r "$golden" ] || { echo "FAIL: golden 이 없다: $golden" >&2; exit 1; }

fail_early() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/maru-hook-cmd.XXXXXX")
trap 'rm -rf "$work"' EXIT
logdir="$work/events"
# 커맨드는 `<base>/<인스턴스>/<pane>.ndjson` 에 쓴다 — maru 를 두 개 띄워도 이름이 안 겹치게 하는 칸이다.
inst=42
evdir="$logdir/$inst"
mkdir -p "$evdir"

# golden 이 낡지 않았는지 본다 — 빌더의 표식 버전이 올라가면 fixture 도 함께 갱신돼야 한다.
# (파일 대 파일 비교를 zig 쪽에서 못 하는 것은 `@embedFile` 이 패키지 경로 밖을 못 읽기 때문이다.
#  zig 테스트는 구조 불변식을, 이 게이트는 신선도와 실제 셸 동작을 본다.)
src="$root/src/session/agent_hook_command.zig"
zig_marker=$(sed -n 's/^pub const marker = "\([^"]*\)";$/\1/p' "$src")
[ -n "$zig_marker" ] || fail_early "빌더에서 표식 상수를 찾지 못했다: $src"
grep -q "$zig_marker" "$golden" || fail_early "golden 이 낡았다 — 빌더 표식은 '$zig_marker' 인데 fixture 에 없다"
# 표식만 보면 **표식을 안 올린 로직 변경**을 통째로 놓친다(상한을 바꿔도 표식은 그대로다). 커맨드에 박히는
# 값도 함께 대조한다 — 여기서 걸리면 fixture 를 다시 뽑아야 한다는 뜻이다.
# 커맨드가 박는 상한은 **줄 상한에서 접두를 뺀 값**이다(`max_payload_bytes`) — 줄 상한 자체가 아니다.
# 그 관계를 여기서도 그대로 계산한다. 셸이 zig 상수를 읽는 자리라 취약하지만, 못 찾으면 조용히 넘어가지
# 않고 «fixture 를 다시 뽑아라» 로 멈춘다.
ev_src="$root/src/session/agent_hook_event.zig"
zig_kib=$(sed -n 's/^pub const max_line_bytes: usize = \([0-9]*\) \* 1024;$/\1/p' "$ev_src")
zig_provider=$(sed -n 's/^pub const max_provider_len: usize = \([0-9]*\);$/\1/p' "$ev_src")
[ -n "$zig_kib" ] || fail_early "줄 상한 상수를 찾지 못했다: $ev_src"
[ -n "$zig_provider" ] || fail_early "provider 이름 상한 상수를 찾지 못했다: $ev_src"
zig_limit=$((zig_kib * 1024 - zig_provider - 1))
grep -q "gt $zig_limit" "$golden" || fail_early "golden 이 낡았다 — payload 상한이 $zig_limit 인데 fixture 와 다르다"
# 표식·상한만 보면 **둘 다 안 건드리는 로직 변경**을 놓친다 — 실제로 그렇게 골든이 조용히 낡았다(상한
# 초과 시 이름을 살리는 `case` 사슬을 넣었는데 두 앵커가 다 그대로였다). 커맨드는 이제 세트의 이름을
# 전부 담으므로 그것을 세 번째 앵커로 쓴다: 세트가 바뀌거나 그 사슬이 사라지면 여기서 멈춘다.
ev_names=$(sed -n 's/^[[:space:]]*\.{ \.name = "\([A-Za-z]*\)".*/\1/p' "$src" | sort -u)
[ -n "$ev_names" ] || fail_early "빌더에서 이벤트 이름을 찾지 못했다: $src"
for ev_name in $ev_names; do
  grep -q "\"$ev_name\"" "$golden" || fail_early "golden 이 낡았다 — 세트의 '$ev_name' 이 fixture 에 없다"
done
# 경로의 두 칸이 앵커다 — 빠지면 두 maru 인스턴스가 같은 파일 이름을 쓰던 시절로 조용히 되돌아간다.
grep -q 'MARU_HOOK_INSTANCE' "$golden" || fail_early "golden 이 낡았다 — 인스턴스 가드/경로가 fixture 에 없다"
# pane 칸은 control-plane selector 와 **갈라진** 변수다(계약 §4). 다시 `MARU_PANE_ID` 로 돌아가면 host 가
# 띄운 자식은 훅 신원을 실을 수 없으므로, 그 회귀를 여기서 멈춘다.
grep -q 'MARU_HOOK_PANE' "$golden" || fail_early "golden 이 낡았다 — pane 칸이 MARU_HOOK_PANE 이 아니다"
grep -q 'MARU_PANE_ID' "$golden" && fail_early "golden 이 낡았다 — 훅이 control-plane selector 를 다시 읽는다"
# 문자 클래스의 **모양**도 앵커다. 두 가지를 본다.
#
# ⑴ 범위 표기(`a-z`)가 없어야 한다. 셸 bracket 의 범위는 **로케일 collation 을 따르므로** 사용자 로케일에서
#    가드가 조용히 느슨해진다 — 실측(2026-08-24): `[!0-9a-z_]` 이 en_US.UTF-8·ko_KR.UTF-8 에서 `HOST_AA` 를
#    통과시켰다(C 에서는 거부). 훅은 provider 가 주는 환경에서 돌아 `LC_ALL` 을 정할 수 없다.
# ⑵ 우리가 만드는 이름의 알파벳을 실제로 담아야 한다. 넓어지거나 좁아지면 fixture 를 다시 뽑아야 한다.
for guard_class in $(sed -n 's/.*\[!\([0-9a-z_]*\)\].*/\1/p' "$golden"); do
  case "$guard_class" in
    *-*) fail_early "golden 이 낡았다 — 가드가 범위 표기('$guard_class')를 쓴다(로케일을 탄다)" ;;
  esac
done
grep -q '\[!0123456789abcdef\]' "$golden" || fail_early "golden 이 낡았다 — pane 칸 알파벳(hex)이 fixture 와 다르다"
grep -q '\[!0123456789abcdefghijklmnopqrstuvwxyz_\]' "$golden" || fail_early "golden 이 낡았다 — 인스턴스 칸 알파벳이 fixture 와 다르다"

# 커맨드는 하나고 자리 둘을 env 로 고른다(RA8) — 원격 자리(`<remote>/<nonce>[_t<pane>].ndjson`)도 같은 fixture 에 있다.
remotedir="$work/remote-events"
mkdir -p "$remotedir"
grep -q '__REMOTE_LOG_DIR__' "$golden" || fail_early "golden 이 낡았다 — 원격 자리(RA8)가 fixture 에 없다"
grep -q 'LC_MARU_PANE' "$golden" || fail_early "golden 이 낡았다 — 원격 pane 칸이 fixture 에 없다"
cmd=$(sed "s|__LOG_DIR__|$logdir|g; s|__REMOTE_LOG_DIR__|$remotedir|g" "$golden")

fail() { echo "FAIL: $1" >&2; exit 1; }
# **개수는 세고 적지 않는다.** 손으로 적은 수는 검사를 더할 때마다 어긋나고("계약 6개"라고 적힌 채 7개를
# 돌고 있었다), 그러면 «몇 개가 도는지»를 아무도 믿지 않게 된다.
checks=0
pass() { checks=$((checks + 1)); echo "  ok  $1"; }
# **건너뛴 것은 초록이 아니다.** 안 잰 검사를 `ok` 로 적으면 다음 사람이 «여기는 지켜진다» 로 읽는다.
# 그래서 세지 않고 다른 낱말로 적는다.
skip() { echo "  SKIP $1"; }

# 이 호스트가 POSIX 파일 권한을 갖는가. Git Bash/MSYS 는 NTFS 위라 `chmod`·`umask` 가 `ls -l` 에
# 반영되지 않는다(실측: `umask 022` 로 돌린 커맨드의 결과가 `rw-r--r--` 로 보인다 — 커맨드가
# `umask 077` 을 하든 말든 같다). 그 자리는 **셸 검사로 증명할 수도 반증할 수도 없다.**
posix_modes=yes
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) posix_modes=no ;;
esac

payload='{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"끝"}'

echo "1) pane 식별자가 있으면 한 줄로 append 한다"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=7 /bin/sh -c "$cmd" || fail "정상 경로가 0 으로 끝나지 않았다"
[ -f "$evdir/7.ndjson" ] || fail "로그 파일이 생기지 않았다"
[ "$(wc -l < "$evdir/7.ndjson")" -eq 1 ] || fail "줄이 하나가 아니다"
grep -q "^claude	{" "$evdir/7.ndjson" || fail "provider 표식과 payload 사이가 탭이 아니다"
grep -q '"hook_event_name":"Stop"' "$evdir/7.ndjson" || fail "payload 가 그대로 실리지 않았다"
pass "append 형식"

echo "1b) 로그 파일 권한이 0600 이다 — payload 에 소스와 명령 원문이 실린다"
# **넉넉한 umask 에서 돌린다.** 기본 umask 가 이미 077 인 환경에서 돌리면 커맨드에 `umask` 가 없어도
# 통과해 검사가 아무것도 증명하지 못한다(같은 함정을 동시 append 검사에서 한 번 겪었다).
if [ "$posix_modes" = no ]; then
  # **«안 된다» 가 아니라 «못 잰다» 다.** Windows 에서 이 성질이 지켜지는지는 이 게이트가 답할 수
  # 없다 — 답하려면 ACL 을 봐야 하고, 그것은 훅 커맨드의 계약을 다시 정하는 일이다(보고만 한다).
  skip "로그 파일 권한 — 이 호스트에 POSIX 모드가 없다(Windows 에서 지켜지는지는 **안 쟀다**)"
else
  rm -f "$evdir/9.ndjson"
  printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=9 /bin/sh -c "umask 022; $cmd" || fail "정상 경로가 0 으로 끝나지 않았다"
  mode=$(ls -l "$evdir/9.ndjson" | cut -c2-10)
  [ "$mode" = "rw-------" ] || fail "로그 파일 권한이 rw------- 여야 하는데 $mode 다(umask 가 빠졌다)"
  rm -f "$evdir/9.ndjson"
  pass "로그 파일 권한(넉넉한 umask 에서도 0600)"
fi

echo "2) pane 식별자가 없으면 아무것도 쓰지 않고 0 으로 끝난다"
printf '%s\n' "$payload" | env -u MARU_HOOK_PANE MARU_HOOK_INSTANCE=$inst /bin/sh -c "$cmd" || fail "가드 경로가 0 으로 끝나지 않았다"
[ "$(ls "$evdir" | wc -l)" -eq 1 ] || fail "maru 밖 세션이 파일을 남겼다"
pass "가드 경로"

echo "3) stdin 을 끝까지 삼킨다 — 안 그러면 provider 파이프가 막힌다"
# 여러 줄을 밀어 넣고 쓰기 쪽이 SIGPIPE 로 죽지 않는지 본다.
big=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "line-%d\n", i }')
printf '%s\n%s\n' "$payload" "$big" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=8 /bin/sh -c "$cmd" || fail "stdin 드레인 중 실패했다"
[ "$(wc -l < "$evdir/8.ndjson")" -eq 1 ] || fail "첫 줄만 기록해야 한다"
pass "stdin 드레인"

echo "4) 상한을 넘긴 payload 는 접히되 **이름은 살아남는다** — 턴 끝을 잃으면 배지가 안 풀린다"
huge=$(awk 'BEGIN { printf "{\"hook_event_name\":\"Stop\",\"x\":\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"}" }')
printf '%s\n' "$huge" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=9 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
# **이름이 살아야 한다.** `Stop` 은 최종 답변 전문을 실어 상한을 넘길 수 있는데(실사용에서 codex payload
# 하나가 실제로 넘겼다), 이름까지 버리면 그 턴의 끝을 못 보고 배지가 «진행 중» 에 멈춘다.
grep -q '"hook_event_name":"Stop"' "$evdir/9.ndjson" || fail "상한을 넘겼다고 이름까지 버렸다"
if grep -q '__oversized__' "$evdir/9.ndjson"; then fail "이름을 알 수 있는데 표식으로 접었다"; fi
[ "$(wc -c < "$evdir/9.ndjson")" -lt 200 ] || fail "상한을 넘긴 원문이 그대로 실렸다"
pass "상한 접기(이름 보존)"

echo "4b) 이름을 모르면 표식으로 접는다 — 모르는 것을 지어내지 않는다"
huge2=$(awk 'BEGIN { printf "{\"hook_event_name\":\"NoSuchEvent\",\"x\":\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"}" }')
printf '%s\n' "$huge2" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=11 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '__oversized__' "$evdir/11.ndjson" || fail "모르는 이름인데 표식이 없다"
pass "상한 접기(미지 이름)"

echo "4c) 상한을 넘겨도 tool_use_id 는 살아남는다 — 없으면 셸 구간을 닫을 수 없다(AT3b-1)"
# `PostToolUse(Bash)` 는 명령 출력을 실어 0.1% 가 상한을 넘긴다. 이름만 남기면 그 구간은 짝지을 id 가
# 없어 턴 끝까지 열린 채 사용자 편집을 끌어들인다. 파라미터 확장뿐이라 프로세스는 늘지 않는다.
huge3=$(awk 'BEGIN { printf "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"},\"tool_use_id\":\"toolu_01GxMwqMfHbwqq1dbuxDCwFB\"}" }')
printf '%s\n' "$huge3" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=12 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '"hook_event_name":"PostToolUse","tool_use_id":"toolu_01GxMwqMfHbwqq1dbuxDCwFB"' "$evdir/12.ndjson" || fail "상한을 넘겼다고 tool_use_id 까지 버렸다: $(cat "$evdir/12.ndjson")"
[ "$(wc -c < "$evdir/12.ndjson")" -lt 200 ] || fail "상한을 넘긴 원문이 그대로 실렸다"
# **값은 화이트리스트를 지나야 실린다.** 우리가 만드는 JSON 안에 그대로 들어가므로 따옴표가 섞인 id 를
# 실으면 파서가 그 줄을 통째로 버려 이름까지 잃는다 — 그때는 id 를 버리고 이름만 남긴다.
huge4=$(awk 'BEGIN { printf "{\"hook_event_name\":\"PostToolUseFailure\",\"tool_use_id\":\"ab\\\"c\",\"x\":\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"}" }')
printf '%s\n' "$huge4" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=13 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '^claude	{"hook_event_name":"PostToolUseFailure"}$' "$evdir/13.ndjson" || fail "검증을 안 지난 id 가 실렸다: $(cat "$evdir/13.ndjson")"
# **값 안의 같은 낱말에 안 걸린다.** stdout 에 `"tool_use_id":"FAKE"` 가 들어 있어도 JSON 안에서는 따옴표가
# `\"` 로 이스케이프돼 있어 패턴(`"tool_use_id":"`)과 다르다 — 그래서 첫 일치가 진짜 키다. 이 저장소의
# 에이전트는 훅 로그를 `cat` 하므로(실사용) 가상의 경우가 아니다.
huge5=$(awk 'BEGIN { printf "{\"hook_event_name\":\"PostToolUse\",\"tool_response\":{\"stdout\":\"\\\"tool_use_id\\\":\\\"FAKE\\\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"},\"tool_use_id\":\"toolu_real\"}" }')
printf '%s\n' "$huge5" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=14 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '"tool_use_id":"toolu_real"' "$evdir/14.ndjson" || fail "stdout 안의 가짜 id 에 걸렸다: $(cat "$evdir/14.ndjson")"
# id 가 없는 이벤트(`Stop`)는 예전 모양 그대로다 — 4) 가 그것을 본다.
pass "상한 접기(tool_use_id 보존·검증)"

echo "4d) 상한을 넘긴 PostToolUse(Bash) 에서 hunks 만 잘라내고 changedFiles 는 살린다 (AT3b-2)"
# `bashEditDiff` 는 `files`(hunks)·`moreFiles`·`changedFiles` 순이다(실측 528/528). hunks 가 상한을 밀어내면
# 귀속 근거(`changedFiles`)까지 함께 잃으므로 그 절만 잘라낸다. stdout 안의 `\"files\":` 는 이스케이프라 안 걸린다.
huge6=$(awk 'BEGIN { big=""; for (i = 0; i < 40000; i++) big = big "x"; printf "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"\\\"files\\\":[1]\",\"bashEditDiff\":{\"files\":[{\"filePath\":\"/r/a\",\"hunks\":[{\"lines\":[\"+%s\"]}]}],\"moreFiles\":2,\"changedFiles\":[\"/r/a\",\"/r/b c\"]}},\"tool_use_id\":\"toolu_big\"}", big }')
printf '%s\n' "$huge6" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=15 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
line15=$(cat "$evdir/15.ndjson")
case "$line15" in *'"bashEditDiff":{"moreFiles":2,"changedFiles":["/r/a","/r/b c"]}'*) ;; *) fail "changedFiles 가 살아남지 않았다: $(printf '%s' "$line15" | cut -c1-200)" ;; esac
case "$line15" in *'"hunks"'*) fail "hunks 가 남았다" ;; esac
case "$line15" in *'"tool_use_id":"toolu_big"'*) ;; *) fail "id 를 잃었다" ;; esac
case "$line15" in *'"stdout":"\"files\":[1]"'*) ;; *) fail "stdout 의 이스케이프된 글자를 건드렸다" ;; esac
[ "$(wc -c < "$evdir/15.ndjson")" -lt 400 ] || fail "잘라낸 뒤에도 상한 근처다"
# **키 순서가 다르면 지어내지 않는다** — 잘라낸 결과에 `changedFiles` 가 없으면 이름+id 로 접는다.
huge7=$(awk 'BEGIN { big=""; for (i = 0; i < 40000; i++) big = big "x"; printf "{\"hook_event_name\":\"PostToolUse\",\"tool_response\":{\"bashEditDiff\":{\"files\":[{\"lines\":[\"+%s\"]}],\"changedFiles\":[\"/r/a\"],\"moreFiles\":0}},\"tool_use_id\":\"toolu_rev\"}", big }')
printf '%s\n' "$huge7" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=16 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '^claude	{"hook_event_name":"PostToolUse","tool_use_id":"toolu_rev"}$' "$evdir/16.ndjson" || fail "순서가 다른데 잘라낸 것을 실었다: $(cut -c1-200 "$evdir/16.ndjson")"
pass "상한 접기(hunks 만 잘라내기·순서 가드)"

echo "4e) 상한은 바이트로 센다 — UTF-8 로케일에서 한글 payload 가 글자 수로 상한 안이어도 접힌다 (AT3b-2)"
# macOS `/bin/sh`(bash 3.2)는 UTF-8 로케일에서 `${#var}` 를 글자 수로 센다. 그러면 60 KB 짜리 한글 payload 가
# 검사를 지나 통째로 적히고, 파서의 바이트 상한이 그 줄을 **통째로** 버린다(이름·id 까지). 개발자 환경이
# `LC_ALL=ko_KR.UTF-8` 이라 가상의 경우가 아니다 — 실제 bashEditDiff 563건 중 15건이 이 틈에 있었다.
hangul=$(awk 'BEGIN { printf "{\"hook_event_name\":\"PostToolUse\",\"tool_use_id\":\"toolu_hangul\",\"tool_response\":{\"stdout\":\""; for (i = 0; i < 20000; i++) printf "한"; printf "\"}}" }')
printf '%s\n' "$hangul" | env LANG=ko_KR.UTF-8 LC_ALL=ko_KR.UTF-8 MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=17 /bin/sh -c "$cmd" || fail "한글 상한 경로가 0 으로 끝나지 않았다"
[ "$(wc -c < "$evdir/17.ndjson")" -lt 200 ] || fail "한글 payload 가 글자 수로 세어져 통째로 적혔다($(wc -c < "$evdir/17.ndjson") 바이트)"
grep -q '"hook_event_name":"PostToolUse","tool_use_id":"toolu_hangul"' "$evdir/17.ndjson" || fail "접힌 모양이 아니다: $(cut -c1-120 "$evdir/17.ndjson")"
pass "상한을 바이트로 센다(UTF-8 로케일)"

echo "5) 로그 디렉터리가 없어도 조용히 0 으로 끝난다"
# **stderr 까지 조용해야 한다.** `printf … 2>/dev/null` 은 printf 자신의 stderr 만 막고 리다이렉션 대상이
# 없을 때 셸이 내는 `No such file or directory` 는 못 막는다 — 실제로 그 메시지가 새는 것을 이 검사가
# 잡았다. 훅의 stderr 는 provider 화면으로 간다.
rm -rf "$logdir"
err="$work/stderr.txt"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=7 /bin/sh -c "$cmd" 2>"$err" || fail "디렉터리가 없을 때 0 이 아니었다"
[ ! -s "$err" ] || fail "디렉터리가 없을 때 stderr 가 샜다: $(cat "$err")"
mkdir -p "$evdir"
pass "디렉터리 부재(조용함 포함)"

echo "5b) pane 식별자가 숫자가 아니면 로그 디렉터리 밖에 쓰지 않는다"
# 검증이 없을 때 이 입력이 실제로 디렉터리 밖에 파일을 만들었다(실측).
escape_dir="$work/outside"
rm -rf "$escape_dir" "$logdir"
mkdir -p "$escape_dir" "$evdir"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE='../outside/pwned' /bin/sh -c "$cmd" || fail "탈출 입력에서 0 이 아니었다"
[ ! -e "$escape_dir/pwned.ndjson" ] || fail "로그 디렉터리 밖에 파일이 생겼다"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE='7; rm -rf /' /bin/sh -c "$cmd" || fail "주입 입력에서 0 이 아니었다"
# **앞 단계의 부작용에 기대지 않는다** — 5)가 디렉터리를 지웠다 만든 덕에 비어 있었을 뿐이라, 그쪽을 고치면
# 여기가 조용히 깨진다. 이 검사가 필요한 상태를 스스로 만든다.
[ "$(ls "$evdir" | wc -l | tr -d ' ')" -eq 0 ] || fail "예상 밖 파일이 생겼다: $(ls "$evdir")"
pass "pane 식별자 검증"

echo "5c) 인스턴스 식별자도 같은 규율로 막는다 — 두 maru 가 서로의 로그를 물지 않게"
# 인스턴스 칸이 비면 아무것도 쓰지 않는다(maru 밖 세션과 같은 취급).
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE MARU_HOOK_PANE=7 /bin/sh -c "$cmd" || fail "인스턴스 부재에서 0 이 아니었다"
[ "$(ls "$evdir" | wc -l | tr -d ' ')" -eq 0 ] || fail "인스턴스 없이 파일이 생겼다: $(ls "$evdir")"
# 그리고 그 값으로도 경로를 벗어날 수 없다.
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE='../outside' MARU_HOOK_PANE=pwned /bin/sh -c "$cmd" || fail "탈출 입력에서 0 이 아니었다"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE='../outside' MARU_HOOK_PANE=7 /bin/sh -c "$cmd" || fail "탈출 입력에서 0 이 아니었다"
[ ! -e "$escape_dir/7.ndjson" ] || fail "인스턴스 칸으로 디렉터리 밖에 파일이 생겼다"
[ "$(ls "$evdir" | wc -l | tr -d ' ')" -eq 0 ] || fail "탈출 입력이 파일을 남겼다: $(ls "$evdir")"
pass "인스턴스 식별자 검증"

echo "5d) host 가 소유하는 신원도 같은 커맨드로 도착한다 — 이 계약의 목적이 그것이다"
# host-backed 터미널의 칸은 `host_<32 hex host_id>` / `<32 hex runtime_id>` 다(계약 §4). GUI 소유 칸(십진
# pid·surface id)과 **한 커맨드**가 둘 다 받아야 한다 — 받지 못하면 그 터미널은 훅 모드 밖에 남는다.
host_inst=host_0000000000000000000000000000000a
host_pane=0000000000000000000000000000002a
# 이 검사가 필요한 상태를 스스로 만들고, **뒤 단계가 쓰는 칸을 없애지 않는다**(게이트 규율: 앞뒤 단계의
# 부작용에 기대지도, 남기지도 않는다).
mkdir -p "$evdir" "$logdir/$host_inst"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$host_inst MARU_HOOK_PANE=$host_pane /bin/sh -c "$cmd" || fail "host 신원에서 0 이 아니었다"
[ -f "$logdir/$host_inst/$host_pane.ndjson" ] || fail "host 신원으로 로그 파일이 생기지 않았다"
grep -q '"hook_event_name":"Stop"' "$logdir/$host_inst/$host_pane.ndjson" || fail "host 신원 경로에 payload 가 없다"
# 그리고 그 모양으로도 경로를 벗어날 수 없다 — 접두가 있다고 검사가 느슨해지면 안 된다.
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE='host_../outside' MARU_HOOK_PANE=$host_pane /bin/sh -c "$cmd" || fail "탈출 입력에서 0 이 아니었다"
[ ! -e "$escape_dir/$host_pane.ndjson" ] || fail "host 접두를 붙인 탈출 입력이 디렉터리 밖에 파일을 만들었다"
# 대문자 같은 «우리가 안 만드는» 모양은 우리 세션이 아니라고 보고 나간다. **넉넉한 로케일에서 확인한다** —
# 셸 bracket 의 범위 표기는 collation 을 따라 en_US.UTF-8 에서 대문자를 통과시켰다(실측 2026-08-24). C 로케일
# 에서만 돌리는 검사는 그 함정을 증명하지 못한다(1b 가 umask 022 를 쓰는 것과 같은 이유).
mkdir -p "$logdir/HOST_AA"
for guard_locale in C en_US.UTF-8; do
  printf '%s\n' "$payload" | env LC_ALL=$guard_locale MARU_HOOK_INSTANCE='HOST_AA' MARU_HOOK_PANE=$host_pane /bin/sh -c "$cmd" || fail "낯선 모양에서 0 이 아니었다($guard_locale)"
  [ "$(ls "$logdir/HOST_AA" | wc -l | tr -d ' ')" -eq 0 ] || fail "낯선 인스턴스 모양이 파일을 남겼다($guard_locale)"
  printf '%s\n' "$payload" | env LC_ALL=$guard_locale MARU_HOOK_INSTANCE=$host_inst MARU_HOOK_PANE='ABCDEF' /bin/sh -c "$cmd" || fail "낯선 pane 모양에서 0 이 아니었다($guard_locale)"
  [ ! -e "$logdir/$host_inst/ABCDEF.ndjson" ] || fail "낯선 pane 모양이 파일을 만들었다($guard_locale)"
done
pass "host 소유 신원"

echo "6) 동시 append 가 이벤트를 잃지도, 파일을 자르지도 않는다"
# **«줄이 안 깨진다»고 단언하지 않는다.** 실측(2026-08-20)에서 24개 동시 쓰기의 인터리브는 **간헐적**이었다 —
# 같은 크기로 돌려도 어떤 회차는 2줄이 섞이고 어떤 회차는 0줄이었다. `printf` 가 큰 출력을 여러 write 로
# 쪼개면 O_APPEND 가 각 write 의 오프셋만 원자적으로 잡아 주기 때문이고, 그 쪼갬은 구현·버퍼 상태를 탄다.
# 그것을 «절대 안 깨진다»로 고정하면 게이트가 무작위로 빨개진다(flaky).
#
# 그래서 계약이 실제로 약속하는 것만 본다: ⑴ **개행 수가 보존된다**(이벤트를 통째로 잃지 않는다),
# ⑵ **바이트가 보존된다**(파일이 잘리지 않는다). 섞인 줄을 버리는 것은 파서의 몫이고, 그 동작은
# `agent_hook_event.zig` 의 단위 테스트가 고정한다.
fat=$(awk 'BEGIN { printf "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"pad\":\""; for (i = 0; i < 8000; i++) printf "p"; printf "\"}" }')
fat_size=$(printf '%s' "$fat" | wc -c | tr -d ' ')
runs=24
# 한 줄 = provider("claude") + TAB + payload + 개행
expect_bytes=$(( (6 + 1 + fat_size + 1) * runs ))
i=0
while [ "$i" -lt "$runs" ]; do
  printf '%s\n' "$fat" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=11 /bin/sh -c "$cmd" &
  i=$((i + 1))
done
wait
lines=$(wc -l < "$evdir/11.ndjson" | tr -d ' ')
bytes=$(wc -c < "$evdir/11.ndjson" | tr -d ' ')
[ "$lines" -eq "$runs" ] || fail "개행이 $runs 개여야 하는데 $lines 개다(이벤트를 잃었다)"
[ "$bytes" -eq "$expect_bytes" ] || fail "바이트가 $expect_bytes 여야 하는데 $bytes 다(파일이 잘렸다)"
intact=$(grep -c '^claude	{.*}$' "$evdir/11.ndjson" 2>/dev/null || true)
pass "동시 append(줄당 $fat_size B x $runs, 온전한 줄 $intact/$runs)"

echo "7) 원격 자리 — 로컬 두 칸이 비면 LC_MARU_PANE 으로 평평한 경로에 적는다 (RA8)"
# ⚠️ 이 게이트 자체가 tmux 안에서 돌 수 있다(개발자 셸) — «tmux 밖» 을 재려면 `TMUX_PANE` 을 명시적으로 뺀다.
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE -u TMUX_PANE -u TMUX LC_MARU_PANE=4331_7 /bin/sh -c "$cmd" || fail "원격 경로가 0 으로 끝나지 않았다"
[ -f "$remotedir/4331_7.ndjson" ] || fail "원격 파일이 생기지 않았다"
grep -q "^claude	{" "$remotedir/4331_7.ndjson" || fail "원격 줄 형식이 로컬과 다르다"
[ -f "$remotedir/4331_7.tmux" ] || fail "tmux 옆 파일이 없다(tmux 밖이면 빈 파일로 남아야 한다)"
# tmux 밖이면 두 변수가 비어 옆 파일은 `\t\n` 두 바이트다 — 순수 층이 그것을 `direct` 로 접는다.
[ "$(wc -c < "$remotedir/4331_7.tmux" | tr -d ' ')" -eq 2 ] || fail "tmux 밖인데 옆 파일에 좌표가 있다"
[ "$(ls "$evdir" | wc -l)" -eq "$(ls "$evdir" | wc -l)" ] && [ ! -f "$evdir/4331_7.ndjson" ] || fail "원격 이벤트가 로컬 자리에도 적혔다"
pass "원격 자리(평평한 경로·옆 파일)"

echo "7b) tmux 안이면 pane 칸이 붙고 옆 파일에 좌표가 남는다 — nonce 가 비어도 적는다 (RA6)"
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE LC_MARU_PANE=4331_7 TMUX_PANE='%3' TMUX='/tmp/tmux-x/default,1,0' /bin/sh -c "$cmd" || fail "원격 tmux 경로가 0 으로 끝나지 않았다"
[ -f "$remotedir/4331_7_t3.ndjson" ] || fail "tmux 칸이 이름에 안 붙었다"
grep -q "^/tmp/tmux-x/default,1,0	%3$" "$remotedir/4331_7_t3.tmux" || fail "옆 파일에 tmux 좌표가 없다"
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE -u LC_MARU_PANE TMUX_PANE='%5' TMUX='/tmp/tmux-x/default,1,0' /bin/sh -c "$cmd" || fail "빈 nonce 경로가 0 으로 끝나지 않았다"
[ -f "$remotedir/t5.ndjson" ] || fail "빈 nonce + tmux 가 t<pane> 으로 안 적혔다"
pass "원격 tmux 칸·옆 파일·빈 nonce"

echo "7c) 클래스를 못 지난 nonce 는 비운다 — 옛 커맨드는 로그 디렉터리 밖에 파일을 만들었다 (RA8 공격 K, 실측)"
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE LC_MARU_PANE='../evil' TMUX_PANE='%3' TMUX='/tmp/tmux-x/default,1,0' /bin/sh -c "$cmd" || fail "탈출 시도 경로가 0 으로 끝나지 않았다"
[ ! -e "$work/evil_t3.ndjson" ] && [ ! -e "$work/evil_t3.tmux" ] || fail "nonce 의 '../' 가 로그 디렉터리 밖에 파일을 만들었다"
[ "$(find "$work" -name '*evil*' | wc -l)" -eq 0 ] || fail "evil 이름이 어딘가에 남았다"
# 못 지난 nonce 는 비고, tmux 칸만으로 적힌다(빈 nonce 규칙과 같다).
[ "$(wc -l < "$remotedir/t3.ndjson")" -eq 1 ] || fail "못 지난 nonce 가 빈 nonce 로 접히지 않았다"
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE -u TMUX_PANE -u TMUX LC_MARU_PANE='../evil' /bin/sh -c "$cmd" || fail "탈출 시도(tmux 밖) 경로가 0 으로 끝나지 않았다"
[ "$(find "$work" -name '*evil*' | wc -l)" -eq 0 ] || fail "tmux 밖에서 evil 이름이 남았다"
pass "원격 nonce 검증(경로 탈출 없음)"

echo "7d) 로컬 두 칸이 있으면 로컬이 이긴다 — 로컬 pane 안의 로컬 tmux 가 원격으로 새지 않는다 (RA8 공격 B)"
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE=12 TMUX_PANE='%9' TMUX='/tmp/tmux-x/default,1,0' LC_MARU_PANE=4331_7 /bin/sh -c "$cmd" || fail "둘 다 있는 경로가 0 으로 끝나지 않았다"
[ -f "$evdir/12.ndjson" ] || fail "로컬 두 칸이 있는데 로컬에 안 적혔다"
[ ! -f "$remotedir/4331_7_t9.ndjson" ] || fail "로컬 두 칸이 있는데 원격에도 적혔다"
pass "로컬 우선"

echo "7e) 로컬 칸이 있는데 틀리면 원격으로 흘리지 않고 나간다 — fail-closed (RA8 공격 L)"
before_remote=$(ls "$remotedir" | wc -l)
printf '%s\n' "$payload" | env MARU_HOOK_INSTANCE=$inst MARU_HOOK_PANE='../x' TMUX_PANE='%9' TMUX='/tmp/tmux-x/default,1,0' /bin/sh -c "$cmd" || fail "틀린 로컬 칸 경로가 0 으로 끝나지 않았다"
printf '%s\n' "$payload" | env -u MARU_HOOK_PANE MARU_HOOK_INSTANCE=$inst TMUX_PANE='%9' TMUX='/tmp/tmux-x/default,1,0' /bin/sh -c "$cmd" || fail "인스턴스만 있는 경로가 0 으로 끝나지 않았다"
[ "$(ls "$remotedir" | wc -l)" -eq "$before_remote" ] || fail "틀린 로컬 칸이 원격 자리에 적혔다"
[ "$(find "$work" -name '*x*.ndjson' | wc -l)" -eq 0 ] || fail "틀린 pane 칸이 어딘가에 적혔다"
pass "로컬 fail-closed"

echo "7f) 아무 칸도 없으면 아무것도 안 적는다"
before_all=$(find "$work" -type f | wc -l)
printf '%s\n' "$payload" | env -u MARU_HOOK_INSTANCE -u MARU_HOOK_PANE -u LC_MARU_PANE -u TMUX_PANE -u TMUX /bin/sh -c "$cmd" || fail "빈 env 경로가 0 으로 끝나지 않았다"
[ "$(find "$work" -type f | wc -l)" -eq "$before_all" ] || fail "빈 env 인데 파일이 생겼다"
pass "빈 env"

echo "8) 원격 설치기(maru agent-hooks)가 심는 바이트는 이 fixture 를 HOME 규칙으로 채운 것과 같다 — 핑퐁의 부재 (RA8)"
# 로컬 GUI 설치기는 빌더 + HOME 규칙으로 커맨드를 만들고 이 fixture 는 그 빌더에서 나온다. 원격 CLI 가 같은 바이트를
# 쓰는지는 **제품 바이너리**로만 알 수 있다. 바이너리가 없으면 «못 쟀다» 로 적는다(SKIP — 초록으로 세지 않는다).
maru_bin="$root/zig-out/bin/maru"
if [ -x "$maru_bin" ]; then
  cli_home="$work/cli-home"
  mkdir -p "$cli_home/.claude"
  printf '{}\n' > "$cli_home/.claude/settings.json"
  # 다른 기기의 스크립트가 보내는 그 인자 그대로(`install_all_script`).
  env HOME="$cli_home" XDG_CACHE_HOME="$work/should-be-ignored" \
    "$maru_bin" agent-hooks install --provider=claude --scope=remote --dir="$cli_home/.cache/maru/remote-agent-events" >/dev/null 2>"$work/cli.err" \
    || fail "maru agent-hooks 가 실패했다: $(cat "$work/cli.err")"
  expected=$(sed "s|__LOG_DIR__|$cli_home/.cache/maru/agent-turn-events|g; s|__REMOTE_LOG_DIR__|$cli_home/.cache/maru/remote-agent-events|g" "$golden")
  actual=$(python3 - "$cli_home/.claude/settings.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
cmds={h["command"] for arr in d.get("hooks",{}).values() for m in arr for h in m.get("hooks",[])}
assert len(cmds)==1, cmds
print(next(iter(cmds)), end="")
PY
)
  [ "$actual" = "$expected" ] || { printf '%s\n' "$actual" > "$work/actual.sh"; printf '%s\n' "$expected" > "$work/expected.sh"; diff "$work/expected.sh" "$work/actual.sh" | head -5 >&2; fail "원격 CLI 가 심은 커맨드가 HOME 규칙 fixture 와 다르다(핑퐁이 되살아난다)"; }
  # XDG 를 무시했다 — 그 자리는 안 만든다. 두 자리는 만든다(0700).
  [ ! -d "$work/should-be-ignored" ] || fail "원격 CLI 가 XDG_CACHE_HOME 을 봤다"
  [ -d "$cli_home/.cache/maru/agent-turn-events" ] || fail "원격 CLI 가 로컬 자리를 안 만들었다"
  [ -d "$cli_home/.cache/maru/remote-agent-events" ] || fail "원격 CLI 가 원격 자리를 안 만들었다"
  # 같은 인자로 한 번 더 돌리면 «그대로 둔다» — 파일이 바뀌지 않는다(설치기 판정이 자기 바이트를 알아본다).
  before_sum=$(cksum < "$cli_home/.claude/settings.json")
  env HOME="$cli_home" "$maru_bin" agent-hooks install --provider=claude --scope=remote --dir="$cli_home/.cache/maru/remote-agent-events" >/dev/null 2>&1 || fail "두 번째 설치가 실패했다"
  [ "$(cksum < "$cli_home/.claude/settings.json")" = "$before_sum" ] || fail "같은 바이트인데 두 번째 설치가 파일을 다시 썼다"
  pass "원격 CLI 바이트 = fixture(HOME 규칙) · XDG 무시 · 두 자리 생성 · 재설치 무변경"
else
  skip "원격 CLI 바이트 대조 — zig-out/bin/maru 가 없다(**안 쟀다**; \`zig build\` 뒤 다시 돌리면 잰다)"
fi

echo "OK: 훅 커맨드가 실제 셸에서 계약 $checks 개를 지킨다"
