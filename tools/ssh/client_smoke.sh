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
cat >"$DIR/sshd_config.tmpl" <<EOF
Port 0
ListenAddress 127.0.0.1
HostKey $DIR/hostkey
PidFile $PIDFILE
LogLevel ERROR
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $DIR/authorized_keys
PermitRootLogin no
ForceCommand head -c $EXPECT_BYTES /dev/zero | tr '\\0' 'A'; head -c $EXPECT_STDERR /dev/zero | tr '\\0' 'E' >&2
EOF
chmod 600 "$DIR/sshd_config.tmpl"

# 포트가 빌 때까지 짝(주 포트 + echo 포트)을 옮겨 가며 시도한다.
try=0
PORT=""
while [ $try -lt "$PORT_TRIES" ]; do
	try_port=$((PORT_BASE + try * 2))
	sed -e "s|^Port .*|Port $try_port|" "$DIR/sshd_config.tmpl" >"$DIR/sshd_config"
	chmod 600 "$DIR/sshd_config"
	rm -f "$PIDFILE"
	"$SSHD" -f "$DIR/sshd_config" -E "$DIR/sshd.log" 2>/dev/null || true
	i=0
	while [ ! -s "$PIDFILE" ] && [ $i -lt 30 ]; do
		i=$((i + 1))
		sleep 0.1
	done
	if [ -s "$PIDFILE" ]; then
		PORT=$try_port
		break
	fi
	try=$((try + 1))
done
[ -n "$PORT" ] || {
	sed -n '1,5p' "$DIR/sshd.log" >&2 2>/dev/null || true
	skip_or_fail "sshd 를 어느 포트에도 못 띄웠다($PORT_TRIES 번 시도, $PORT_BASE 부터)"
}

# 3) 우리 클라이언트로 **두 번** 붙는다.
#
#    **한 번으로는 둘 다 못 본다**(실측): `pty-req` 를 하면 서버가 stderr 를 pty 로 합쳐
#    `CHANNEL_DATA` 로 보내므로 확장 데이터 경로가 아예 안 돈다. 그 회계가 빠져도 스모크가
#    초록이 되는 구멍이었다.
#
#      - `pty`   : `pty-req`·`window-change` 를 태운다. stderr 는 합쳐지므로 0 을 기대한다.
#      - `no-pty`: 확장 데이터(stderr)를 태운다.
USER_NAME=$(id -un)
"$DRIVER" "$PORT" "$USER_NAME" "$DIR/clientkey" "$EXPECT_BYTES" 0 pty
"$DRIVER" "$PORT" "$USER_NAME" "$DIR/clientkey" "$EXPECT_BYTES" "$EXPECT_STDERR" no-pty

# 4) **보내는 쪽**을 태우는 회차. 서버를 `cat` 으로 바꿔 우리가 보낸 것이 그대로 돌아오게 한다 —
#    나머지 회차는 받기만 해서 보내는 쪽 흐름 제어가 선 위에서 한 번도 안 돈다(그 검사를 지워도
#    스모크가 초록이었다 — 실측). 초기 윈도가 0 이라 **기다렸다 보내는 것**도 여기서 증명된다.
ECHO_PORT=$((PORT + 1))
sed -e "s|^Port .*|Port $ECHO_PORT|" -e "s|^PidFile .*|PidFile $DIR/sshd2.pid|" -e "s|^ForceCommand .*|ForceCommand cat|" "$DIR/sshd_config.tmpl" >"$DIR/sshd_config2"
chmod 600 "$DIR/sshd_config2"
"$SSHD" -f "$DIR/sshd_config2" -E "$DIR/sshd2.log" || {
	skip_or_fail "echo 회차용 sshd 를 못 띄웠다"
}
i=0
while [ ! -s "$DIR/sshd2.pid" ] && [ $i -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
[ -s "$DIR/sshd2.pid" ] || skip_or_fail "echo 회차용 sshd 가 포트 $ECHO_PORT 에 안 떴다"
ECHO_BYTES=4194304
"$DRIVER" "$ECHO_PORT" "$USER_NAME" "$DIR/clientkey" "$ECHO_BYTES" 0 echo
