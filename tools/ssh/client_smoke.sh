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
if [ ! -x "$DRIVER" ]; then
	echo "[ssh-client-smoke] FAIL: $DRIVER 없음 — 'zig build ssh-client-smoke' 먼저." >&2
	exit 1
fi

DIR=$(mktemp -d)
PIDFILE="$DIR/sshd.pid"

cleanup() {
	if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
	if [ -f "$DIR/sshd2.pid" ]; then kill "$(cat "$DIR/sshd2.pid")" 2>/dev/null || true; fi
	if [ -f "$DIR/sshd3.pid" ]; then kill "$(cat "$DIR/sshd3.pid")" 2>/dev/null || true; fi
	if [ -f "$DIR/sshd4.pid" ]; then kill "$(cat "$DIR/sshd4.pid")" 2>/dev/null || true; fi
	if [ -f "$DIR/sshd5.pid" ]; then kill "$(cat "$DIR/sshd5.pid")" 2>/dev/null || true; fi
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
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $DIR/authorized_keys
PermitRootLogin no
$_extra
ForceCommand $_cmd
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

# **회차 수를 못박는다.** 이 스모크에서 "조용히 통과" 가 네 번 나왔다(보충 0 회 · SKIP · 포트 충돌 ·
# 스크립트 버그). 그때마다 개별로 막았지만, 그 부류는 **아직 생각 못 한 이유로 또 생긴다**. 세 회차가
# 다 돌지 않으면 왜든 실패라고 여기서 한 번에 막는다.
if [ "$ROUNDS" -ne 7 ]; then
	echo "[ssh-client-smoke] FAIL: 회차가 7 이 아니라 $ROUNDS 이다 — 조용히 건너뛴 자리가 있다" >&2
	exit 1
fi
echo "[ssh-client-smoke] 일곱 회차 완주"
