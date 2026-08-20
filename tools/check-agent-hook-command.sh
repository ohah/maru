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
mkdir -p "$logdir"

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

cmd=$(sed "s|__LOG_DIR__|$logdir|g" "$golden")

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ok  $1"; }

payload='{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"끝"}'

echo "1) pane 식별자가 있으면 한 줄로 append 한다"
printf '%s\n' "$payload" | env MARU_PANE_ID=7 /bin/sh -c "$cmd" || fail "정상 경로가 0 으로 끝나지 않았다"
[ -f "$logdir/7.ndjson" ] || fail "로그 파일이 생기지 않았다"
[ "$(wc -l < "$logdir/7.ndjson")" -eq 1 ] || fail "줄이 하나가 아니다"
grep -q "^claude	{" "$logdir/7.ndjson" || fail "provider 표식과 payload 사이가 탭이 아니다"
grep -q '"hook_event_name":"Stop"' "$logdir/7.ndjson" || fail "payload 가 그대로 실리지 않았다"
pass "append 형식"

echo "2) pane 식별자가 없으면 아무것도 쓰지 않고 0 으로 끝난다"
printf '%s\n' "$payload" | env -u MARU_PANE_ID /bin/sh -c "$cmd" || fail "가드 경로가 0 으로 끝나지 않았다"
[ "$(ls "$logdir" | wc -l)" -eq 1 ] || fail "maru 밖 세션이 파일을 남겼다"
pass "가드 경로"

echo "3) stdin 을 끝까지 삼킨다 — 안 그러면 provider 파이프가 막힌다"
# 여러 줄을 밀어 넣고 쓰기 쪽이 SIGPIPE 로 죽지 않는지 본다.
big=$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "line-%d\n", i }')
printf '%s\n%s\n' "$payload" "$big" | env MARU_PANE_ID=8 /bin/sh -c "$cmd" || fail "stdin 드레인 중 실패했다"
[ "$(wc -l < "$logdir/8.ndjson")" -eq 1 ] || fail "첫 줄만 기록해야 한다"
pass "stdin 드레인"

echo "4) 상한을 넘긴 payload 는 표식으로 접힌다 — 조용히 사라지지 않는다"
huge=$(awk 'BEGIN { printf "{\"hook_event_name\":\"Stop\",\"x\":\""; for (i = 0; i < 40000; i++) printf "x"; printf "\"}" }')
printf '%s\n' "$huge" | env MARU_PANE_ID=9 /bin/sh -c "$cmd" || fail "상한 경로가 0 으로 끝나지 않았다"
grep -q '__oversized__' "$logdir/9.ndjson" || fail "상한 표식이 없다"
[ "$(wc -c < "$logdir/9.ndjson")" -lt 200 ] || fail "상한을 넘긴 원문이 그대로 실렸다"
pass "상한 접기"

echo "5) 로그 디렉터리가 없어도 조용히 0 으로 끝난다"
# **stderr 까지 조용해야 한다.** `printf … 2>/dev/null` 은 printf 자신의 stderr 만 막고 리다이렉션 대상이
# 없을 때 셸이 내는 `No such file or directory` 는 못 막는다 — 실제로 그 메시지가 새는 것을 이 검사가
# 잡았다. 훅의 stderr 는 provider 화면으로 간다.
rm -rf "$logdir"
err="$work/stderr.txt"
printf '%s\n' "$payload" | env MARU_PANE_ID=7 /bin/sh -c "$cmd" 2>"$err" || fail "디렉터리가 없을 때 0 이 아니었다"
[ ! -s "$err" ] || fail "디렉터리가 없을 때 stderr 가 샜다: $(cat "$err")"
mkdir -p "$logdir"
pass "디렉터리 부재(조용함 포함)"

echo "5b) pane 식별자가 숫자가 아니면 로그 디렉터리 밖에 쓰지 않는다"
# 검증이 없을 때 이 입력이 실제로 디렉터리 밖에 파일을 만들었다(실측).
escape_dir="$work/outside"
rm -rf "$escape_dir" "$logdir"
mkdir -p "$escape_dir" "$logdir"
printf '%s\n' "$payload" | env MARU_PANE_ID='../outside/pwned' /bin/sh -c "$cmd" || fail "탈출 입력에서 0 이 아니었다"
[ ! -e "$escape_dir/pwned.ndjson" ] || fail "로그 디렉터리 밖에 파일이 생겼다"
printf '%s\n' "$payload" | env MARU_PANE_ID='7; rm -rf /' /bin/sh -c "$cmd" || fail "주입 입력에서 0 이 아니었다"
# **앞 단계의 부작용에 기대지 않는다** — 5)가 디렉터리를 지웠다 만든 덕에 비어 있었을 뿐이라, 그쪽을 고치면
# 여기가 조용히 깨진다. 이 검사가 필요한 상태를 스스로 만든다.
[ "$(ls "$logdir" | wc -l | tr -d ' ')" -eq 0 ] || fail "예상 밖 파일이 생겼다: $(ls "$logdir")"
pass "pane 식별자 검증"

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
  printf '%s\n' "$fat" | env MARU_PANE_ID=11 /bin/sh -c "$cmd" &
  i=$((i + 1))
done
wait
lines=$(wc -l < "$logdir/11.ndjson" | tr -d ' ')
bytes=$(wc -c < "$logdir/11.ndjson" | tr -d ' ')
[ "$lines" -eq "$runs" ] || fail "개행이 $runs 개여야 하는데 $lines 개다(이벤트를 잃었다)"
[ "$bytes" -eq "$expect_bytes" ] || fail "바이트가 $expect_bytes 여야 하는데 $bytes 다(파일이 잘렸다)"
intact=$(grep -c '^claude	{.*}$' "$logdir/11.ndjson" 2>/dev/null || true)
pass "동시 append(줄당 $fat_size B x $runs, 온전한 줄 $intact/$runs)"

echo "OK: 훅 커맨드가 실제 셸에서 계약 6개를 지킨다"
