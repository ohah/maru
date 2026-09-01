#!/bin/sh
# 원격 SCM 판정자를 **실물 SSH 위에서** 돌린다.
#
# ## 왜 필요한가
#
# RS1~RS4 의 원격 판정자는 전부 `SkipZigTest` 였다 — control socket 이 없으면 건너뛰기 때문이다.
# 그 말은 **원격 SCM 전체가 CI 커버리지 0** 이라는 뜻이고, 실제로 그 축의 결함 여섯이 사람이 손으로
# 잰 뒤에야 나왔다(계획 §7·§8·§9.2). 이 하네스가 그 자리를 메운다.
#
# ## p5d 하네스와 갈린 이유
#
# `tools/session-host/p5d_ssh_smoke.sh` 도 localhost sshd 를 띄우지만 **서명된 앱 번들**을 요구하는
# 릴리스급 게이트다(codesign · Developer ID · hardened runtime). 원격 SCM 은 argv 와 파이프의 문제라
# 번들이 필요 없다 — 무거운 게이트에 얹으면 그 게이트가 빨간 동안 이 축도 못 돈다.
#
# ## 이 하네스가 소유하는 것
#
# 키·sshd·저장소·HOME 전부. **사용자의 `~/.ssh` 도 실행 중인 agent 도 건드리지 않는다** —
# `BatchMode` 와 harness 키만 쓴다.
set -eu

if [ "$#" -lt 1 ]; then
	echo "usage: $0 <remote-scm-test-binary>" >&2
	exit 2
fi
TEST_BIN=$1
shift

SSHD=/usr/sbin/sshd
SSH=/usr/bin/ssh
SSH_KEYGEN=/usr/bin/ssh-keygen
GIT=/usr/bin/git
for tool in "$SSHD" "$SSH" "$SSH_KEYGEN" "$GIT"; do
	[ -x "$tool" ] || { echo "remote-scm: required executable missing: $tool" >&2; exit 1; }
done
TEST_BIN=$(CDPATH= cd -- "$(dirname -- "$TEST_BIN")" && pwd -P)/$(basename -- "$TEST_BIN")
[ -x "$TEST_BIN" ] || { echo "remote-scm: test binary is not executable: $TEST_BIN" >&2; exit 1; }

# ⚠️ **경로를 짧게 잡는다.** unix socket 의 `sun_path` 는 104 바이트다(macOS). `mktemp -d` 의 기본
# 위치(`/var/folders/…`)나 워크트리 아래에 두면 control socket 경로가 그 한도를 넘어 `ssh` 가
# `ControlPath too long` 으로 거절한다 — 실측으로 한 번 그렇게 막혔다.
RUN_DIR=/tmp/maru-rscm.$$
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

SSHD_PID=
cleanup() {
	# ControlMaster 를 먼저 닫는다 — 남으면 다음 실행이 그 소켓을 재사용해 **새 sshd 를 안 거친다.**
	[ -n "${CTL:-}" ] && "$SSH" -S "$CTL" -O exit 127.0.0.1 >/dev/null 2>&1 || true
	[ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null || true
	rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

"$SSH_KEYGEN" -q -t ed25519 -f "$RUN_DIR/hostkey" -N '' -C harness
"$SSH_KEYGEN" -q -t ed25519 -f "$RUN_DIR/userkey" -N '' -C harness
cat "$RUN_DIR/userkey.pub" > "$RUN_DIR/authorized_keys"
chmod 600 "$RUN_DIR/authorized_keys" "$RUN_DIR/hostkey" "$RUN_DIR/userkey"

# 포트를 훑는다 — 러너에서 무엇이 잡혀 있는지 모른다.
PORT=
_try=0
while [ "$_try" -lt 40 ]; do
	_candidate=$((22800 + _try))
	cat >"$RUN_DIR/sshd_config" <<EOF
Port $_candidate
ListenAddress 127.0.0.1
HostKey $RUN_DIR/hostkey
PidFile $RUN_DIR/sshd.pid
LogLevel ERROR
StrictModes no
UsePAM no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $RUN_DIR/authorized_keys
PermitRootLogin no
PermitUserRC no
PermitUserEnvironment no
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
EOF
	rm -f "$RUN_DIR/sshd.pid"
	"$SSHD" -f "$RUN_DIR/sshd_config" -E "$RUN_DIR/sshd.log" 2>/dev/null || true
	_i=0
	while [ ! -s "$RUN_DIR/sshd.pid" ] && [ "$_i" -lt 50 ]; do
		_i=$((_i + 1))
		sleep 0.02
	done
	if [ -s "$RUN_DIR/sshd.pid" ]; then
		PORT=$_candidate
		SSHD_PID=$(cat "$RUN_DIR/sshd.pid")
		break
	fi
	_try=$((_try + 1))
done
[ -n "$PORT" ] || {
	sed -n '1,20p' "$RUN_DIR/sshd.log" >&2 || true
	echo "remote-scm: sshd did not start" >&2
	exit 1
}

CTL=$RUN_DIR/c
"$SSH" -o BatchMode=yes \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o IdentitiesOnly=yes \
	-i "$RUN_DIR/userkey" \
	-M -S "$CTL" -fN -p "$PORT" 127.0.0.1 2>"$RUN_DIR/ssh.log" || {
	sed -n '1,20p' "$RUN_DIR/ssh.log" >&2 || true
	echo "remote-scm: ControlMaster did not connect" >&2
	exit 1
}
"$SSH" -S "$CTL" 127.0.0.1 true || { echo "remote-scm: control socket is not usable" >&2; exit 1; }

# 원격 저장소. **loopback 이라 같은 파일시스템**이지만, 판정자는 그 사실을 쓰지 않고 ssh 로만 만진다 —
# 결과 대조에서만 직접 읽는다(그 자리는 「원격이 실제로 그렇게 됐나」를 보는 유일한 길이다).
REPO=$RUN_DIR/repo
mkdir -p "$REPO"
"$GIT" -C "$REPO" init -q .
"$GIT" -C "$REPO" config user.email harness@maru.test
"$GIT" -C "$REPO" config user.name "Maru Harness"
"$GIT" -C "$REPO" config commit.gpgsign false
echo seed > "$REPO/seed.txt"
"$GIT" -C "$REPO" add seed.txt
"$GIT" -C "$REPO" -c commit.gpgsign=false commit -q -m seed

MARU_REMOTE_SCM_DEST=127.0.0.1 \
MARU_REMOTE_SCM_CTL=$CTL \
MARU_REMOTE_SCM_REPO=$REPO \
	"$TEST_BIN" "$@"
