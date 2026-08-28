#!/bin/sh
# **내장 SSH 클라이언트의 실서버 스모크**(계획 S8). 진짜 sshd 를 띄우고 우리 코드로 한 번 왕복한다.
#
# **왜 필요한가.** `src/session/ssh/` 는 전부 sans-io 라 스스로는 아무 데도 못 붙는다. 그리고 서버
# 구현마다 관대함이 달라 상호운용은 명세만으로 안 닫힌다 — 진짜 sshd 와의 왕복이 유일한 판정자다.
#
# **사용자의 실제 키와 sshd 를 쓰지 않는다.** 이 스크립트가 **일회용 호스트키·클라이언트키**를
# 새로 만들고 **자기 sshd 를 높은 포트에 띄운다**. Remote Login 을 켤 필요가 없고, `~/.ssh` 를
# 건드리지 않으며, 남의 `known_hosts` 에도 안 들어간다. 끝나면 전부 지운다.
#
# **대량 출력을 요구한다.** 짧은 출력은 초기 윈도 안에서 끝나 흐름 제어(S7b)가 한 번도 안 돈다 —
# 계약 §3.1 이 말한 "대량 출력이 도중에 멈춘다" 를 재현도 반증도 못 한다. 그래서 서버가 우리
# 윈도(기본 2MiB)의 **네 배인 8MiB** 를 쏟게 하고, 드라이버가 그만큼 받았는지와 **보충이 실제로
# 돌았는지**를 둘 다 본다.
#
# **1MiB 로는 안 된다**(실측): 절반에서 채우는 정책이라 2MiB 윈도에서 1MiB 는 정확히 경계라 한 번도
# 안 돈다. 그때도 전송은 성공하므로 "보충이 돌았나" 를 따로 안 보면 이 스모크는 **아무것도 안 재면서
# 초록**이 된다.
#
# 기본 `mise run check` 에 안 넣는다 — `sshd` 바이너리와 포트가 필요해 환경 의존이다(없으면 SKIP).
#
# **SKIP 은 조용한 통과라 위험하다.** sshd 가 없거나 포트가 막혀도 `exit 0` 이면, 이것을 CI 에
# 올리는 순간 **아무것도 안 재면서 초록**이 된다(적대적 검증이 실측으로 확인했다 — 이 스모크가
# "보충 0 회로도 초록" 이던 것과 같은 부류다). 그래서 `MARU_SSH_SMOKE_REQUIRE=1` 이면 SKIP 이
# **실패**가 된다 — CI 에 올릴 때는 그 변수를 켠다.
set -eu

# SKIP 을 실패로 바꾼다(CI 용).
REQUIRE=${MARU_SSH_SMOKE_REQUIRE:-0}
skip_or_fail() {
	if [ "$REQUIRE" = "1" ]; then
		echo "[ssh-client-smoke] FAIL: $1 (MARU_SSH_SMOKE_REQUIRE=1)" >&2
		exit 1
	fi
	echo "[ssh-client-smoke] SKIP: $1"
	exit 0
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DRIVER="$ROOT/zig-out/bin/ssh-client-smoke"
# 모바일 ABI 로만 붙는 드라이버(S9-2). 같은 sshd 를 쓰되 진입점이 다르다.
ABI_DRIVER="$ROOT/zig-out/bin/ssh-abi-smoke"
# 두 host 가 쓸 C 펌프를 그대로 링크한 드라이버(S9-3).
PUMP_DRIVER="$ROOT/zig-out/bin/ssh-pump-smoke"
# **포트를 고정하지 않는다.** 고정이면 두 실행이 겹칠 때 뒤엣것이 "안 떴다" 며 SKIP 하고
# **조용히 통과**한다(실측: 동시에 둘 돌리니 하나는 3 회차 OK, 다른 하나는 0 회차에 EXIT=0).
# CI 가 잡을 병렬로 돌리거나 사람이 두 번 돌리면 한쪽이 아무것도 안 재고 초록이 된다.
# PID 로 흩고, 그래도 겹치면 다음 짝을 시도한다.
PORT_BASE=${MARU_SSH_SMOKE_PORT:-$((20000 + ($$ % 20000)))}
PORT_TRIES=${MARU_SSH_SMOKE_PORT_TRIES:-20}
EXPECT_BYTES=8388608
# **stderr 도 같은 윈도를 먹는다**(RFC 4254 §5.2). 안 내보내면 확장 데이터 경로를 아예 안 타서,
# 그 회계가 빠져도 스모크가 초록이 된다(실측으로 확인한 구멍이다).
EXPECT_STDERR=65536
# **백슬래시를 안 쓴다.** `tr '\\0'` 같은 것은 heredoc·sed·원격 셸을 거치며 세 번 해석돼
# 조용히 다른 명령이 된다(실측: `tr ' '` 이 되어 stderr 가 안 나왔다).
BULK_CMD="yes A | head -c $EXPECT_BYTES; yes E | head -c $EXPECT_STDERR >&2"

# sshd 를 찾는다. 리눅스는 PATH 에 없을 수 있어 흔한 자리를 같이 본다.
SSHD=""
for candidate in /usr/sbin/sshd /usr/local/sbin/sshd "$(command -v sshd 2>/dev/null || true)"; do
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then SSHD="$candidate"; break; fi
done
if [ -z "$SSHD" ]; then
	skip_or_fail "sshd 바이너리가 없다 (openssh-server 필요)"
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
	skip_or_fail "ssh-keygen 이 없다"
fi
# **드라이버를 여기서 짓는다.** 예전에는 "없으면 실패" 만 봤는데, 있기만 하면 **낡았어도** 그대로
# 돌았다 — 방금 고친 코드가 아니라 옛 바이너리를 재고 초록이 난다(실측으로 겪었다: 상태기계를
# 바꾼 뒤 이 스크립트를 직접 돌려 통과했는데, 돌아간 것은 옛 바이너리였다).
if command -v zig >/dev/null 2>&1; then
	if ! (cd "$ROOT" && zig build ssh-client-smoke); then
		echo "[ssh-client-smoke] FAIL: 드라이버 빌드 실패" >&2
		exit 1
	fi
fi
if [ ! -x "$DRIVER" ]; then
	echo "[ssh-client-smoke] FAIL: $DRIVER 없음 — 'zig build ssh-client-smoke' 먼저." >&2
	exit 1
fi

# **임시 디렉터리 이름에 소유 스크립트의 pid 를 박는다.** 아래 `reap_dead_owners` 가 "이 sshd 를 띄운
# 스크립트가 아직 사는가" 를 그 이름 하나로 판정한다 — 그것 말고는 띄운 쪽과 띄워진 쪽을 이을 실마리가
# 없다(sshd 는 daemonize 하며 setsid 로 떨어져 나가 부모도, 프로세스 그룹도 남지 않는다).
SMOKE_TAG=maru-ssh-smoke
DIR=$(mktemp -d "${TMPDIR:-/tmp}/$SMOKE_TAG.$$.XXXXXX")
PIDFILE="$DIR/sshd.pid"
# `start_sshd` 가 지금까지 쓴 pid 파일 목록. 같은 자리를 두 번 쓰는 것을 그 자리에서 죽이는 데만 쓴다.
USED_PIDFILES="$DIR/.used-pidfiles"

# **앞선 실행이 남긴 sshd 를 거둔다.** 아래 `trap` 은 EXIT/INT/TERM 에서만 돌고 **SIGKILL 이나 프로세스
# 그룹 kill 에는 안 돈다** — 게이트가 타임아웃으로 죽거나 Ctrl-C 가 에스컬레이션되면 그 자리에서
# listener 가 고아로 남는다. 그 구멍은 trap 으로 막을 수 없으므로(SIGKILL 은 가로챌 수 없다) **다음
# 실행이 치우는 쪽**으로 닫는다.
#
# 실측(2026-08-28): 그렇게 남은 sshd 가 **19 개**, 최고 **9 일째** localhost 포트를 하나씩 물고 있었다.
# CPU 0 · 메모리 448KB 라 눈에 안 띄는데, **포트는 계속 먹으므로** 다음 실행이 `PORT_TRIES` 를 헛돌게
# 하고 그만큼 조용한 SKIP 에 가까워진다.
#
# ⚠️ **살아 있는 소유자의 sshd 는 절대 안 건드린다.** 이 스크립트는 병렬로 돌 수 있고(포트를 pid 로
# 흩는 이유가 그것이다), 남의 실행을 죽이면 그쪽이 영문 모를 실패를 한다. 그래서 판정은 소유자 pid 의
# 생존 하나뿐이다 — **pid 재사용은 "안 죽인다" 쪽으로만 틀린다**(죽은 소유자의 번호를 남이 물려받으면
# 우리는 살아 있다고 보고 그냥 지나간다). 안전한 방향으로만 틀리는 판정이라 이 정도면 충분하다.
reap_dead_owners() {
	_tmp_root=${TMPDIR:-/tmp}
	ps -Ao pid=,command= 2>/dev/null | grep "[s]shd -f " | while read -r _dead_pid _dead_rest; do
		# **공백 있는 경로에서 잘리지 않게 태그에 앵커해서 뽑는다.** 예전 판은 `-f` 뒤의 공백 없는
		# 토큰만 잘라 왔는데, `$TMPDIR` 에 공백이 하나라도 있으면 태그 앞에서 끊겨 **조용히 아무것도
		# 안 하는** 상태가 된다(이 저장소가 가장 싫어하는 형태다). 우리가 만드는 이름 모양
		# (`태그.pid.6자`) 자체를 패턴으로 삼으면 공백과 무관하고, 덤으로 모양 검사까지 겸한다.
		_dead_dir=$(printf '%s\n' "$_dead_rest" |
			sed -n "s|.*-f \(.*/$SMOKE_TAG\.[0-9][0-9]*\.[A-Za-z0-9]*\)/[^/]*.*|\1|p")
		[ -n "$_dead_dir" ] || continue
		# ⚠️ **`ps` 출력은 아무 프로세스나 지어낼 수 있다.** 여기서 하는 일이 `kill` 과 `rm -rf` 라
		# 경로를 그대로 믿으면 안 된다 — 적대적 입력을 먹여 보니 `sshd -f /etc/maru-ssh-smoke.1./x`
		# 가 통과해 `/etc/...` 를 지우려 들었다. 그래서 **우리가 실제로 만들 수 있는 자리**로 좁힌다:
		# `mktemp` 에 준 것과 **같은 식으로 지은 접두**만 받는다. `$TMPDIR` 이 그때와 다르면 못 거두는데,
		# 그건 "남의 것을 지우는 것" 보다 훨씬 나은 실패 방향이다.
		case "$_dead_dir" in
		"$_tmp_root"/"$SMOKE_TAG".*) ;;
		*) continue ;;
		esac
		# 디렉터리 존재는 조건에 안 넣는다 — OS 의 임시 청소기가 이미 지웠어도 `ps` 는 원래 경로를
		# 그대로 보여 주므로, 파일 존재를 요구하면 **가장 오래된 시체를 못 거둔다**.
		_dead_owner=$(basename "$_dead_dir" | sed -n "s/^$SMOKE_TAG\.\([0-9][0-9]*\)\..*/\1/p")
		[ -n "$_dead_owner" ] || continue
		if kill -0 "$_dead_owner" 2>/dev/null; then continue; fi
		kill "$_dead_pid" 2>/dev/null || true
		rm -rf "$_dead_dir" 2>/dev/null || true
	done
}
reap_dead_owners

# **띄운 것을 하나도 안 남긴다.** 예전에는 pid 파일을 하나씩 적었는데, 회차를 늘리면서 새로
# 띄운 sshd 를 목록에 안 넣어 **listener 가 그대로 살아남았다**(실측: `pgrep sshd` 에 두 개).
# 목록은 잊히므로 전수로 돈다.
cleanup() {
	# `$PIDFILE` 은 글롭에도 걸려 두 번 돈다. 그 사이 sshd 가 제 pid 파일을 지우므로
	# `cat` 실패는 정상이다 — 조용히 넘긴다.
	for _pid in "$PIDFILE" "$DIR"/*.pid; do
		[ -f "$_pid" ] || continue
		kill "$(cat "$_pid" 2>/dev/null)" 2>/dev/null || true
	done
	rm -rf "$DIR"
}
trap cleanup EXIT INT TERM

# 1) 일회용 키 두 벌. **암호 없는 키를 쓴다** — 스모크가 사람에게 물을 수 없다.
ssh-keygen -q -t ed25519 -N '' -f "$DIR/hostkey" -C smoke-host
ssh-keygen -q -t ed25519 -N '' -f "$DIR/clientkey" -C smoke-client
cp "$DIR/clientkey.pub" "$DIR/authorized_keys"
chmod 600 "$DIR/hostkey" "$DIR/clientkey" "$DIR/authorized_keys"

# 2) 우리 sshd. **`ForceCommand` 로 1MiB 를 쏟게 한다** — 흐름 제어를 강제로 태우는 자리다.
#    `yes` 를 쓰지 않는 이유: 끝이 없으면 exit-status 를 못 본다.
# (설정은 `start_sshd` 가 포트마다 통째로 쓴다 — 아래.)

# 빈 포트를 찾아 sshd 를 띄운다. 뜬 포트를 `STARTED_PORT` 에 남긴다.
#
# **두 서버가 같은 함수를 쓴다.** 예전에는 echo 회차용 서버가 `PORT + 1` 을 고정으로 썼는데,
# 그 포트가 막혀 있으면 **앞 두 회차만 돌고 SKIP 으로 통과**했다 — 부분 실행이 성공으로 보고되는
# 자리다(이 스모크에서 네 번째로 나온 "조용히 통과").
start_sshd() {
	_pidfile=$1
	_base=$2
	_log=$3
	_cmd=$4
	_extra=${5:-}
	# **강제 명령을 안 거는 회차도 있다.** 컨트롤 채널(S10b-1)은 `exec` 으로 우리 명령을 돌리는데,
	# `ForceCommand` 가 걸린 서버는 그것을 **무시하고** 강제된 명령을 실행한다(계약 §4a 가 컨트롤
	# 축을 그런 서버에서 안 켜는 이유다). 빈 문자열을 주면 그 줄을 안 쓴다.
	_force=""
	if [ -n "$_cmd" ]; then
		_force="ForceCommand $_cmd"
	fi
	# **같은 pid 파일을 두 회차가 나눠 쓰면 앞의 sshd 를 잃는다** — 아래 `rm -f "$_pidfile"` 이 그
	# 자리를 지워서 `cleanup` 이 그 pid 를 영영 못 찾는다. 조용히 새는 대신 **여기서 죽는다**:
	# 실측으로 그렇게 성공한 실행마다 하나씩 남아 9 일치가 19 개로 쌓였고, CPU 가 0 이라 아무도
	# 눈치채지 못했다. 새 회차를 더하며 이름을 복사해 오는 것이 자연스러운 실수라 사람 대신 검사가 본다.
	if [ -f "$USED_PIDFILES" ] && grep -qxF "$_pidfile" "$USED_PIDFILES"; then
		echo "[ssh-client-smoke] FAIL: pid 파일을 두 번 썼다 — 앞 회차 sshd 를 잃는다: $_pidfile" >&2
		exit 1
	fi
	printf '%s\n' "$_pidfile" >>"$USED_PIDFILES"

	_conf="$_pidfile.conf"
	STARTED_PORT=""
	_try=0
	while [ $_try -lt "$PORT_TRIES" ]; do
		_port=$((_base + _try * 2))
		# **설정을 통째로 쓴다.** 예전에는 템플릿을 `sed` 로 갈아 끼웠는데, `ForceCommand` 안의
		# 파이프(`|`)가 `s|…|…|` 구분자와 충돌해 sed 가 죽었다 — 그리고 그 죽음이 "sshd 를 못
		# 띄웠다" 로 접혀 **조용히 통과**했다. 문자열을 끼워 넣지 않으면 그 부류가 아예 없다.
		cat >"$_conf" <<EOF
Port $_port
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
PidFile $_pidfile
LogLevel ERROR
# **회차별 설정이 먼저 온다 — sshd 는 먼저 나온 값이 이긴다.** 뒤에 두면 아래 기본값이 이겨
# 회차가 조용히 무력화된다(비밀번호 회차에서 `PasswordAuthentication yes` 가 그렇게 죽었다:
# 서버는 키만 받고, 드라이버는 "물어야 했는데 안 물었다" 로만 알 수 있었다).
$_extra
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $DIR/authorized_keys
PermitRootLogin no
$_force
EOF
		chmod 600 "$_conf"
		rm -f "$_pidfile"
		"$SSHD" -f "$_conf" -E "$_log" 2>/dev/null || true
		_i=0
		while [ ! -s "$_pidfile" ] && [ $_i -lt 30 ]; do
			_i=$((_i + 1))
			sleep 0.1
		done
		if [ -s "$_pidfile" ]; then
			STARTED_PORT=$_port
			return 0
		fi
		_try=$((_try + 1))
	done
	return 1
}

start_sshd "$PIDFILE" "$PORT_BASE" "$DIR/sshd.log" "$BULK_CMD" || {
	sed -n '1,5p' "$DIR/sshd.log" >&2 2>/dev/null || true
	skip_or_fail "sshd 를 어느 포트에도 못 띄웠다($PORT_TRIES 번 시도, $PORT_BASE 부터)"
}
PORT=$STARTED_PORT

# 3) 우리 클라이언트로 **두 번** 붙는다.
#
#    **한 번으로는 둘 다 못 본다**(실측): `pty-req` 를 하면 서버가 stderr 를 pty 로 합쳐
#    `CHANNEL_DATA` 로 보내므로 확장 데이터 경로가 아예 안 돈다. 그 회계가 빠져도 스모크가
#    초록이 되는 구멍이었다.
#
#      - `pty`   : `pty-req`·`window-change` 를 태운다. stderr 는 합쳐지므로 0 을 기대한다.
#      - `no-pty`: 확장 데이터(stderr)를 태운다.
USER_NAME=$(id -un)
ROUNDS=0
"$DRIVER" "$PORT" "$USER_NAME" "$DIR/clientkey" "$EXPECT_BYTES" 0 pty
ROUNDS=$((ROUNDS + 1))
"$DRIVER" "$PORT" "$USER_NAME" "$DIR/clientkey" "$EXPECT_BYTES" "$EXPECT_STDERR" no-pty
ROUNDS=$((ROUNDS + 1))

# 4) **보내는 쪽**을 태우는 회차. 서버를 `cat` 으로 바꿔 우리가 보낸 것이 그대로 돌아오게 한다 —
#    나머지 회차는 받기만 해서 보내는 쪽 흐름 제어가 선 위에서 한 번도 안 돈다(그 검사를 지워도
#    스모크가 초록이었다 — 실측). 초기 윈도가 0 이라 **기다렸다 보내는 것**도 여기서 증명된다.
start_sshd "$DIR/sshd2.pid" "$((PORT + 1))" "$DIR/sshd2.log" "cat" || {
	sed -n '1,5p' "$DIR/sshd2.log" >&2 2>/dev/null || true
	# **여기서는 SKIP 이 아니라 실패다.** 주 서버가 떴다는 것은 환경이 멀쩡하다는 뜻이라,
	# echo 회차만 못 띄우는 것은 건너뛸 일이 아니라 고칠 일이다.
	echo "[ssh-client-smoke] FAIL: echo 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
ECHO_BYTES=4194304
# ABI 회차는 같은 것을 재되 짧게 — 여기서 재는 것은 대역이 아니라 **배선이 도는가**다.
ABI_ECHO_BYTES=1048576
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$ECHO_BYTES" 0 echo
ROUNDS=$((ROUNDS + 1))

# 5) **재키잉 회차**(S7d). `RekeyLimit 1M` 로 띄운 서버는 8MiB 를 보내는 동안 열 번쯤 키를 갈자고
#    한다. 우리가 답하지 않으면 서로 기다리다 멈춘다 — 실측으로 917,504바이트에서 교착했다.
#    OpenSSH 기본은 1GB/1시간이라 **한 시간 넘는 세션이면 반드시** 이 자리를 지난다.
start_sshd "$DIR/sshd3.pid" "$((PORT + 2))" "$DIR/sshd3.log" "$BULK_CMD" "RekeyLimit 1M" || {
	sed -n '1,5p' "$DIR/sshd3.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 재키잉 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$EXPECT_BYTES" "$EXPECT_STDERR" rekey
REKEY_PORT=$STARTED_PORT
ROUNDS=$((ROUNDS + 1))

# 6) **보내면서 재키잉**(S7d × S7b). 앞 회차는 받기만 해서, 재키잉 중에 **미뤄 둔 채널 송신**이
#    선 위에서 한 번도 안 탄다 — `WINDOW_ADJUST` 를 재키잉 중에 보내면 연결이 죽는 자리다(실측).
#    `cat` + `RekeyLimit 1M` 이면 우리가 보내는 4MiB 동안 서버가 여러 번 키를 갈자고 한다.
start_sshd "$DIR/sshd4.pid" "$((REKEY_PORT + 2))" "$DIR/sshd4.log" "cat" "RekeyLimit 1M" || {
	sed -n '1,5p' "$DIR/sshd4.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 보내며-재키잉 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
# 윈도를 64KiB 로 좁혀 보충이 재키잉과 **결정적으로 겹치게** 한다.
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$ECHO_BYTES" 0 rekey-echo 65536
ROUNDS=$((ROUNDS + 1))

# 7) **우리가 시작하는 재키잉**. 서버가 시작하면 그쪽은 이미 송신을 멈춘 뒤라(§7.1) 재키잉 중에
#    데이터가 안 오고, 그래서 "미뤄 둔 채널 송신" 경로가 한 번도 안 탄다(실측: 미룸 0 회).
#    우리가 먼저 보내면 서버는 그것을 볼 때까지 계속 보내므로 그 자리가 열린다.
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$ECHO_BYTES" 0 self-rekey 65536
ROUNDS=$((ROUNDS + 1))

# 8) **배너 회차.** 서버가 `Banner` 를 켜면 `USERAUTH_BANNER` 가 온다(RFC 4252 §5.4 — 법적 고지).
#    그것을 걸러서 호출자에게 주는 경로는 여기 말고 소비자가 없어서, 이 회차가 없으면 아무도
#    `sanitizeBanner` 를 안 쓴다. 드라이버가 "배너를 받았나" 를 단언한다.
printf 'AUTHORIZED USE ONLY\nThis system is monitored.\n' >"$DIR/banner.txt"
start_sshd "$DIR/sshd5.pid" "$((PORT + 3))" "$DIR/sshd5.log" "echo MARU_BANNER_OK" "Banner $DIR/banner.txt" || {
	sed -n '1,5p' "$DIR/sshd5.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 배너 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" 1 0 banner
ROUNDS=$((ROUNDS + 1))

# 9) **서버가 끊는 회차.** `MaxAuthTries 0` 이면 sshd 는 인증을 한 번도 안 받고 `DISCONNECT` 를
#    보낸다(실측: 사유 2, "Too many authentication failures"). 사유·설명을 위로 올리는 경로는
#    여기 말고 실서버 소비자가 없어서, 이 회차가 없으면 그 경로는 단위 테스트에만 있다.
start_sshd "$DIR/sshd6.pid" "$((PORT + 5))" "$DIR/sshd6.log" "true" "MaxAuthTries 0" || {
	sed -n '1,5p' "$DIR/sshd6.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 끊김 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" 0 0 disconnect
ROUNDS=$((ROUNDS + 1))

# **여러 줄 설정은 변수에 담아 넘긴다.** 인자 안에 개행을 그대로 두면 셸이 그 뒤를 **명령으로**
# 읽는다(실측: `PasswordAuthentication: command not found` — 그러고도 sshd 는 떠서, 회차는
# "물어야 했는데 안 물었다" 로만 실패했다).
PASSWORD_ONLY='PubkeyAuthentication no
PasswordAuthentication yes'

# 9b) **비밀번호 회차.** 서버가 키를 안 받고 `password` 만 열어 두면(`PubkeyAuthentication no`),
#     코어는 `USERAUTH_FAILURE` 의 방법 목록을 보고 **멈춰서 물어야** 한다. 그 자리
#     (`password_needed`)는 실서버로 여기 말고 밟는 데가 없다 — 없으면 "서버가 열어 둔 문 앞에서
#     돌아서는" 결함이 다시 나도 아무도 모른다.
#
#     **붙는 것까지는 못 본다**: 진짜 계정 비밀번호가 필요한데 스모크는 그것을 모르고 사람에게
#     물을 수도 없다. 드라이버가 틀린 값을 한 번 보내고 **실패로 끝나는 것**(되묻는 고리가
#     아니다)까지 단언한다.
start_sshd "$DIR/sshd6b.pid" "$((PORT + 11))" "$DIR/sshd6b.log" "true" "$PASSWORD_ONLY" || {
	sed -n '1,5p' "$DIR/sshd6b.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 비밀번호 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" 0 0 password
ROUNDS=$((ROUNDS + 1))

# 9c) **키 없이 붙는 회차.** 키 파일이 아직 없는 기기(iOS)를 흉내 낸다 — 드라이버가 키를 안 넘기고
#     코어는 `none` 으로 방법 목록만 묻는다(RFC 4252 §5.2). 같은 서버를 그대로 쓴다:
#     "키가 없다고 시작조차 못 하면 비밀번호만 여는 서버에는 영영 못 붙는다" 가 이 회차의 뜻이다.
"$DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" 0 0 nokey
ROUNDS=$((ROUNDS + 1))

# 10) **모바일 ABI 회차(S9-2).** 위 아홉 회차는 코어(`client.zig`)를 직접 부르는 드라이버가
#     돌린다 — 그 사이에 낀 `maru_mobile_ssh_*` 는 한 줄도 안 지난다. 기기에서 "안 된다" 가
#     났을 때 가장 비싼 물음이 **프로토콜 탓이냐 배선 탓이냐**이고, ABI 만으로 한 번 붙여 두면
#     이후 실패가 host 쪽으로 좁혀진다.
if [ ! -x "$ABI_DRIVER" ]; then
	echo "[ssh-client-smoke] FAIL: $ABI_DRIVER 없음" >&2
	exit 1
fi
start_sshd "$DIR/sshd7.pid" "$((PORT + 7))" "$DIR/sshd7.log" "echo MARU_ABI_OK" || {
	sed -n '1,5p' "$DIR/sshd7.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: ABI 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$ABI_DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" MARU_ABI_OK 0
ROUNDS=$((ROUNDS + 1))

# 11) **ABI 로 보내는 회차.** 위 회차는 받기만 해서 `maru_mobile_ssh_write` 와 부분 전송
#     (`out_consume`)이 선 위에서 한 번도 안 돈다. 서버를 `cat` 으로 두고 보낸 것이 그대로
#     돌아오는지 본다 — 흐름 제어와 배압이 ABI 를 통해서도 도는지가 여기서 판정된다.
start_sshd "$DIR/sshd8.pid" "$((PORT + 9))" "$DIR/sshd8.log" "cat" || {
	sed -n '1,5p' "$DIR/sshd8.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: ABI 에코 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$ABI_DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" MARU_ABI_OK "$ABI_ECHO_BYTES"
ROUNDS=$((ROUNDS + 1))

# 12) **C 펌프 회차(S9-3).** 두 host 가 쓸 소켓 펌프(`src/platform/mobile_host/ssh_pump.c`)를
#     그대로 링크한 드라이버로 붙는다. 앞 회차들은 Zig 이 소켓을 들었으므로 기기가 쓸 C 코드는
#     한 줄도 안 지났다. **호스트키는 핀 고정**이라 지문을 먼저 뽑아 넘긴다 — 자동 승인이 없다는
#     계약을 이 자리에서도 지킨다.
if [ ! -x "$PUMP_DRIVER" ]; then
	echo "[ssh-client-smoke] FAIL: $PUMP_DRIVER 없음" >&2
	exit 1
fi
start_sshd "$DIR/sshd9.pid" "$((PORT + 11))" "$DIR/sshd9.log" "echo MARU_PUMP_OK" || {
	sed -n '1,5p' "$DIR/sshd9.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 펌프 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
HOSTKEY_FP=$(ssh-keygen -lf "$DIR/hostkey.pub" | awk '{print $2}')
"$PUMP_DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$HOSTKEY_FP" MARU_PUMP_OK
ROUNDS=$((ROUNDS + 1))

# 13) **핀이 틀리면 안 붙는다.** 위 회차가 초록이어도 핀 검사가 죽어 있으면 그것은 무검증
#     접속이다 — 일부러 틀린 지문을 주고 **실패해야** 통과로 본다.
pin_out=$("$PUMP_DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" \
	"SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" MARU_PUMP_OK 2>&1) && {
	echo "[ssh-client-smoke] FAIL: 틀린 지문으로도 붙었다 — 핀 검사가 안 돈다" >&2
	exit 1
}
# **이유까지 본다.** "무슨 이유로든 실패" 를 통과로 보면, 드라이버가 아예 안 떠도(경로 오타·
# 빌드 실패) 이 회차가 초록이 된다 — 이 저장소에서 그 부류를 여러 번 겪었다.
case "$pin_out" in
*host_key_mismatch*) : ;;
*)
	echo "[ssh-client-smoke] FAIL: 핀 불일치가 아닌 이유로 끝났다: $pin_out" >&2
	exit 1
	;;
esac
ROUNDS=$((ROUNDS + 1))

# 14) **펌프로 재키잉을 지난다.** 앞의 펌프 회차는 한 줄 받고 끝나서 키를 갈 일이 없다 —
#     그런데 모바일 세션은 길게 살아 **반드시** 재키잉을 만난다(OpenSSH 기본 1GB/1시간).
#     `RekeyLimit 1M` 서버에서 4MiB 를 받으면 그 길을 실제로 지난다.
start_sshd "$DIR/sshd10.pid" "$((PORT + 13))" "$DIR/sshd10.log" "$BULK_CMD" "RekeyLimit 1M" || {
	sed -n '1,5p' "$DIR/sshd10.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 펌프 재키잉 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$PUMP_DRIVER" "$STARTED_PORT" "$USER_NAME" "$DIR/clientkey" "$HOSTKEY_FP" MARU_PUMP_OK "$EXPECT_BYTES"
ROUNDS=$((ROUNDS + 1))

# 15) **기기에서 만든 키로 붙는다(S9c).** 계약 §3.4 는 "키는 앱이 만든다" 고 정했다 — 그 키가
#     진짜 OpenSSH 에 먹히는지는 **붙어 봐야** 안다(형식만 그럴싸한 공개키는 붙여 넣고서야
#     안 먹는 것을 알게 된다). 같은 씨앗을 두 번 넣어 한 번은 공개키 줄을 뽑고, 한 번은 그
#     키로 접속한다.
dd if=/dev/urandom of="$DIR/seed" bs=32 count=1 2>/dev/null
"$PUMP_DRIVER" 1 x "seed:$DIR/seed" x PRINT_PUBLIC_LINE > "$DIR/generated.pub"
case "$(cat "$DIR/generated.pub")" in
"ssh-ed25519 "*" maru") : ;;
*)
	echo "[ssh-client-smoke] FAIL: 만든 공개키 줄이 형식과 다르다: $(cat "$DIR/generated.pub")" >&2
	exit 1
	;;
esac
# **OpenSSH 가 그 줄을 읽는지 남의 도구로 판정한다.**
ssh-keygen -lf "$DIR/generated.pub" >/dev/null 2>&1 || {
	echo "[ssh-client-smoke] FAIL: ssh-keygen 이 우리가 만든 공개키를 못 읽는다" >&2
	exit 1
}
# **덮어쓰지 않고 덧붙인다.** 예전에는 `>` 로 갈아 끼웠는데, 그러면 **이 뒤에 오는 회차**가
# 원래 클라이언트 키로 못 붙는다 — 뒤에 회차를 하나 더 놓자마자 "인증 실패" 로 드러났고,
# 그 전까지는 이것이 마지막 회차라 아무도 안 밟았다. 서버 하나가 키 둘을 받는 것은 정상이다.
cat "$DIR/generated.pub" >> "$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"
start_sshd "$DIR/sshd11.pid" "$((PORT + 15))" "$DIR/sshd11.log" "echo MARU_GENKEY_OK" || {
	sed -n '1,5p' "$DIR/sshd11.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 생성키 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
"$PUMP_DRIVER" "$STARTED_PORT" "$USER_NAME" "seed:$DIR/seed" "$HOSTKEY_FP" MARU_GENKEY_OK
ROUNDS=$((ROUNDS + 1))

# 17) **컨트롤 채널 회차(S10b-1).** 같은 연결에 채널을 하나 더 열고 pty 없이 명령을 돌린다.
#     **강제 명령을 안 건 서버**라야 우리 `exec` 이 실제로 돈다 — 위 회차들의 서버는 전부
#     `ForceCommand` 라 우리 명령이 무시된다(그것이 계약 §4a 가 그런 서버에서 컨트롤 축을 안
#     켜는 이유이고, 여기서는 그 반대편을 잰다). 단위 테스트는 우리가 만든 답을 먹이므로
#     **진짜 sshd 가 `exec` 을 받아 주는지**는 이 회차 말고 밟는 데가 없다.
# ⚠️ **회차마다 pid 파일 이름이 달라야 한다.** 이 회차는 `sshd10` 을 재사용하고 있었는데,
# `start_sshd` 는 시작 전에 `rm -f "$_pidfile"` 을 하므로 **앞 회차(14번) sshd 의 pid 가 그 자리에서
# 사라졌다** — `cleanup` 은 pid 파일로만 거두니 그 listener 는 영영 안 죽는다. 실측: 성공한 실행
# 하나가 sshd 를 정확히 하나씩 남겼고, 그렇게 9 일치가 19 개로 쌓였다. 위 `cleanup` 주석이 "전수로
# 돈다" 고 적은 것은 **목록을 잊는 것**을 막을 뿐, **같은 자리를 덮어쓰는 것**은 못 막는다.
start_sshd "$DIR/sshd12.pid" "$((PORT + 10))" "$DIR/sshd12.log" "" || {
	sed -n '1,5p' "$DIR/sshd12.log" >&2 2>/dev/null || true
	echo "[ssh-client-smoke] FAIL: 컨트롤 회차용 sshd 를 어느 포트에도 못 띄웠다" >&2
	exit 1
}
CONTROL_PORT=$STARTED_PORT
"$DRIVER" "$CONTROL_PORT" "$USER_NAME" "$DIR/clientkey" 0 0 control
ROUNDS=$((ROUNDS + 1))

# 17b) **ABI 로 컨트롤 채널을 여는 회차(S10b-2).** 위 회차는 코어를 직접 부르는 드라이버가
#      돌린다 — 그 사이에 낀 `maru_mobile_ssh_*control*` 은 한 줄도 안 지난다. 기기에서 실패했을 때
#      프로토콜 탓인지 배선 탓인지 가르려면 이 회차가 있어야 한다(ABI 회차 9·10 과 같은 이유).
"$ABI_DRIVER" "$CONTROL_PORT" "$USER_NAME" "$DIR/clientkey" MARU_UNUSED_MARKER 0 control
ROUNDS=$((ROUNDS + 1))

# 17c) **펌프로 컨트롤 채널을 여는 회차(S10b-2).** 기기 두 대가 그대로 링크하는 C 가 두 번째
#      채널을 열고, 그 바이트를 **화면과 다른 훅**으로 올리는지 본다. 위 회차는 Zig 이 소켓을
#      들었으므로 이 길(C 펌프 + 컨트롤 훅)은 여기 말고 밟는 데가 없다.
"$PUMP_DRIVER" "$CONTROL_PORT" "$USER_NAME" "$DIR/clientkey" "$HOSTKEY_FP" MARU_UNUSED_MARKER 0 control
ROUNDS=$((ROUNDS + 1))

# 18) **없는 명령 회차.** 계약 §4a 는 "`maru` 가 없어도 채널 요청은 성공하고 셸이 127 을 내며
#     그것은 `exit-status` 로 온다" 고 적었다 — `CHANNEL_FAILURE` 를 기다리면 영영 안 온다.
#     그 값이 실서버에서 정말 그렇게 오는지는 실측이라야 안다.
"$DRIVER" "$CONTROL_PORT" "$USER_NAME" "$DIR/clientkey" 0 0 control-missing
ROUNDS=$((ROUNDS + 1))

# **회차 수를 못박는다.** 이 스모크에서 "조용히 통과" 가 네 번 나왔다(보충 0 회 · SKIP · 포트 충돌 ·
# 스크립트 버그). 그때마다 개별로 막았지만, 그 부류는 **아직 생각 못 한 이유로 또 생긴다**. 세 회차가
# 다 돌지 않으면 왜든 실패라고 여기서 한 번에 막는다.
if [ "$ROUNDS" -ne 20 ]; then
	echo "[ssh-client-smoke] FAIL: 회차가 20 이 아니라 $ROUNDS 이다 — 조용히 건너뛴 자리가 있다" >&2
	exit 1
fi
echo "[ssh-client-smoke] 스무 회차 완주"
