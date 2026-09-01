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

cmd=$(sed "s|__LOG_DIR__|$logdir|g" "$golden")

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

echo "OK: 훅 커맨드가 실제 셸에서 계약 $checks 개를 지킨다"
