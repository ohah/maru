#!/bin/sh
# P5d product-path gate. It owns every SSH input (keys, sshd, HOME and known-hosts state) and
# drives the existing current-product PTY oracle through `/usr/bin/ssh -tt`.
set -eu

if [ "$#" -ne 3 ]; then
	echo "usage: $0 <bundle-cli> <attach-product-e2e-test> <ssh-upload-product-e2e-test>" >&2
	exit 2
fi

BUNDLE_CLI=$1
PRODUCT_TEST=$2
UPLOAD_TEST=$3
SSHD=/usr/sbin/sshd
SSH=/usr/bin/ssh
SSH_KEYGEN=/usr/bin/ssh-keygen

for tool in "$SSHD" "$SSH" "$SSH_KEYGEN" /usr/bin/codesign; do
	[ -x "$tool" ] || { echo "p5d: required executable missing: $tool" >&2; exit 1; }
done
[ -f "$BUNDLE_CLI" ] && [ ! -L "$BUNDLE_CLI" ] && [ -x "$BUNDLE_CLI" ] || {
	echo "p5d: bundle CLI is not a regular executable: $BUNDLE_CLI" >&2
	exit 1
}
BUNDLE_CLI=$(CDPATH= cd -- "$(dirname -- "$BUNDLE_CLI")" && pwd -P)/$(basename -- "$BUNDLE_CLI")
PRODUCT_TEST=$(CDPATH= cd -- "$(dirname -- "$PRODUCT_TEST")" && pwd)/$(basename -- "$PRODUCT_TEST")
[ -x "$PRODUCT_TEST" ] || { echo "p5d: product E2E driver is not executable" >&2; exit 1; }
UPLOAD_TEST=$(CDPATH= cd -- "$(dirname -- "$UPLOAD_TEST")" && pwd)/$(basename -- "$UPLOAD_TEST")
[ -x "$UPLOAD_TEST" ] || { echo "p5d: SSH upload product E2E driver is not executable" >&2; exit 1; }

APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$BUNDLE_CLI")/../.." && pwd)
/usr/bin/codesign --verify --strict "$BUNDLE_CLI"
/usr/bin/codesign --verify --strict --deep "$APP_ROOT"

signature_detail() {
	/usr/bin/codesign -d --verbose=4 "$1" 2>&1
}

if [ "${MARU_P5D_REQUIRE_DEVELOPER_ID:-0}" = 1 ]; then
	GUI_BIN=$APP_ROOT/Contents/MacOS/maru-macos-app
	HELPER_BIN=$APP_ROOT/Contents/Helpers/MaruMermaidRenderer.app/Contents/MacOS/maru-mermaid-renderer
	for signed_bin in "$BUNDLE_CLI" "$GUI_BIN" "$HELPER_BIN"; do
		[ -f "$signed_bin" ] && [ ! -L "$signed_bin" ] && [ -x "$signed_bin" ] || {
			echo "p5d: signed executable missing or indirect: $signed_bin" >&2
			exit 1
		}
		detail=$(signature_detail "$signed_bin")
		echo "$detail" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
			echo "p5d: executable lacks Developer ID Application authority: $signed_bin" >&2
			exit 1
		}
		echo "$detail" | /usr/bin/grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' || {
			echo "p5d: executable lacks hardened runtime: $signed_bin" >&2
			exit 1
		}
	done
	APP_TEAM=$(signature_detail "$APP_ROOT" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
	[ -n "$APP_TEAM" ] && [ "$APP_TEAM" != "not set" ] || {
		echo "p5d: app TeamIdentifier is unavailable" >&2
		exit 1
	}
	signature_detail "$APP_ROOT" | /usr/bin/grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)' || {
		echo "p5d: app lacks hardened runtime" >&2
		exit 1
	}
	for signed_bin in "$BUNDLE_CLI" "$GUI_BIN" "$HELPER_BIN"; do
		BIN_TEAM=$(signature_detail "$signed_bin" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
		[ "$BIN_TEAM" = "$APP_TEAM" ] || {
			echo "p5d: TeamIdentifier mismatch: $signed_bin" >&2
			exit 1
		}
	done
	ARCHS=$(/usr/bin/lipo -archs "$BUNDLE_CLI")
	echo "$ARCHS" | /usr/bin/grep -qw arm64 || { echo "p5d: signed CLI lacks arm64: $ARCHS" >&2; exit 1; }
	echo "$ARCHS" | /usr/bin/grep -qw x86_64 || { echo "p5d: signed CLI lacks x86_64: $ARCHS" >&2; exit 1; }
	echo "p5d: signed release identity team=$APP_TEAM archs=$ARCHS"
else
	echo "p5d: signed release artifact gate=not_provisioned"
fi

RUN_DIR=$(mktemp -d /tmp/maru-p5d.XXXXXX)
case "$RUN_DIR" in
	/tmp/maru-p5d.*) ;;
	*) echo "p5d: unsafe temporary directory: $RUN_DIR" >&2; exit 1 ;;
esac
SSHD_PID=""
kill_tree() {
	_parent=$1
	for _child in $(/usr/bin/pgrep -P "$_parent" 2>/dev/null || true); do
		kill_tree "$_child"
	done
	kill "$_parent" 2>/dev/null || true
}
cleanup() {
	if [ -n "$SSHD_PID" ]; then
		kill_tree "$SSHD_PID"
		_i=0
		while kill -0 "$SSHD_PID" 2>/dev/null && [ "$_i" -lt 100 ]; do
			_i=$((_i + 1))
			sleep 0.01
		done
		kill -9 "$SSHD_PID" 2>/dev/null || true
	fi
	rm -rf -- "$RUN_DIR"
}
trap cleanup EXIT INT TERM

HOME_DIR=$RUN_DIR/home
BIN_DIR=$HOME_DIR/.local/bin
mkdir -p "$HOME_DIR"
HOME=$HOME_DIR PATH=/usr/bin:/bin "$BUNDLE_CLI" install-cli >"$RUN_DIR/install.out"
[ -L "$BIN_DIR/maru" ] || { echo "p5d: install-cli did not create a symlink" >&2; exit 1; }
[ "$(readlink "$BIN_DIR/maru")" = "$BUNDLE_CLI" ] || {
	echo "p5d: install-cli target differs from bundle CLI" >&2
	exit 1
}
[ "$BIN_DIR/maru" -ef "$BUNDLE_CLI" ] || { echo "p5d: installed CLI inode differs" >&2; exit 1; }
MIN_PATH=$BIN_DIR:/usr/bin:/bin
[ "$(HOME=$HOME_DIR PATH=$MIN_PATH command -v maru)" = "$BIN_DIR/maru" ]
HOME=$HOME_DIR PATH=$MIN_PATH maru --help >"$RUN_DIR/help.out"
/usr/bin/grep -q 'attach.*runtime' "$RUN_DIR/help.out"

# A poisoned earlier PATH must win. This catches a harness that secretly invokes the absolute CLI.
FAKE_DIR=$RUN_DIR/fake-bin
mkdir "$FAKE_DIR"
FAKE_MARKER=$RUN_DIR/fake-marker
cat >"$FAKE_DIR/maru" <<EOF
#!/bin/sh
: >'$FAKE_MARKER'
EOF
chmod 700 "$FAKE_DIR/maru"
HOME=$HOME_DIR PATH=$FAKE_DIR:$MIN_PATH maru
[ -f "$FAKE_MARKER" ] || { echo "p5d: poisoned PATH was bypassed" >&2; exit 1; }

"$SSH_KEYGEN" -q -t ed25519 -N '' -f "$RUN_DIR/hostkey" -C p5d-host
"$SSH_KEYGEN" -q -t ed25519 -N '' -f "$RUN_DIR/clientkey" -C p5d-client
cp "$RUN_DIR/clientkey.pub" "$RUN_DIR/authorized_keys"
chmod 600 "$RUN_DIR/hostkey" "$RUN_DIR/clientkey" "$RUN_DIR/authorized_keys"
USER_NAME=$(/usr/bin/id -un)
case "$USER_NAME" in
	*[!A-Za-z0-9._-]*|'') echo "p5d: unsafe local account name" >&2; exit 1 ;;
esac
# sshd가 실행하는 명령도 harness HOME에 가둔다. uploadShellCommand의 `$HOME/.cache/maru/dropped`
# 가 개발자 계정의 실제 HOME으로 새면 테스트 자체가 권한 경계를 어기는 셈이다. SSH_ORIGINAL_COMMAND는
# OpenSSH가 제공하고, 명령 문자열은 제품의 uploadShellCommand 또는 아래 closed attach grammar에서만 온다.
REMOTE_COMMAND=$RUN_DIR/remote-command
cat >"$REMOTE_COMMAND" <<EOF
#!/bin/sh
set -eu
export HOME='$HOME_DIR'
exec /bin/sh -c "\${SSH_ORIGINAL_COMMAND:?}"
EOF
chmod 700 "$REMOTE_COMMAND"
PORT_BASE=$((24000 + ($$ % 12000)))
PORT=""
_try=0
while [ "$_try" -lt 30 ]; do
	_candidate=$((PORT_BASE + _try))
	cat >"$RUN_DIR/sshd_config" <<EOF
Port $_candidate
ListenAddress 127.0.0.1
HostKey $RUN_DIR/hostkey
PidFile $RUN_DIR/sshd.pid
LogLevel VERBOSE
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
MaxAuthTries 1
ForceCommand $REMOTE_COMMAND
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
[ -n "$PORT" ] || { sed -n '1,20p' "$RUN_DIR/sshd.log" >&2 || true; echo "p5d: sshd did not start" >&2; exit 1; }

# Product upload invokes `ssh -S <computed path> <dest> <command>`. The alias supplies only
# harness-owned localhost credentials; the product still computes and selects the ControlPath.
mkdir -p "$HOME_DIR/.ssh" "$HOME_DIR/.cache/maru"
cat >"$HOME_DIR/.ssh/config" <<EOF
Host maru-p5d-upload maru-p5d-upload-a maru-p5d-upload-b
    HostName 127.0.0.1
    Port $PORT
    User $USER_NAME
    IdentityFile $RUN_DIR/clientkey
    BatchMode yes
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel QUIET
Host maru-p5d-upload-failure
    HostName 127.0.0.1
    Port 1
    User $USER_NAME
    IdentityFile $RUN_DIR/clientkey
    BatchMode yes
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ConnectTimeout 1
    ConnectionAttempts 1
    LogLevel QUIET
EOF
chmod 700 "$HOME_DIR/.ssh"
chmod 600 "$HOME_DIR/.ssh/config"
# OpenSSH는 일부 실행 경로에서 getenv(HOME)가 아니라 passwd home을 기준으로 기본 config를 찾는다.
# 제품은 의도대로 PATH의 `ssh`를 실행하고, 이 harness shim은 실제 OpenSSH에 격리 config만 명시한다.
cat >"$BIN_DIR/ssh" <<EOF
#!/bin/sh
exec '$SSH' -F '$HOME_DIR/.ssh/config' "\$@"
EOF
chmod 700 "$BIN_DIR/ssh"

# Every argument accepted here comes from the closed public attach grammar used by the Zig oracle.
# Rejecting anything else keeps OpenSSH's remote-shell command joining from becoming an injection path.
WRAPPER=$RUN_DIR/maru-over-ssh
cat >"$WRAPPER" <<EOF
#!/bin/sh
set -eu
for arg in "\$@"; do
	case "\$arg" in
		attach|--read-only|--take-over|[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) echo "p5d: rejected attach argument" >&2; exit 64 ;;
	esac
done
# registry 는 캐시가 아니라 전용 자리다 — 그 격리를 원격 CLI 까지 그대로 나른다.
remote_root=\${MARU_SESSION_HOST_ROOT:?}
exec '$SSH' -tt -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
	-i '$RUN_DIR/clientkey' -p '$PORT' '$USER_NAME@127.0.0.1' \
	env 'HOME=$HOME_DIR' "MARU_SESSION_HOST_ROOT=\$remote_root" 'PATH=$MIN_PATH' maru "\$@"
EOF
chmod 700 "$WRAPPER"

MARU_SESSION_HOST_PRODUCT_EXE=$BUNDLE_CLI \
MARU_SESSION_HOST_ATTACH_EXE=$WRAPPER \
"$PRODUCT_TEST" --maru-expect-tests=2

HOME=$HOME_DIR \
PATH=$MIN_PATH \
MARU_P5D_UPLOAD_DEST=maru-p5d-upload \
MARU_P5D_UPLOAD_FAILURE_DEST=maru-p5d-upload-failure \
MARU_P5D_UPLOAD_DEST_A=maru-p5d-upload-a \
MARU_P5D_UPLOAD_DEST_B=maru-p5d-upload-b \
MARU_P5D_UPLOAD_CLIENT_KEY=$RUN_DIR/clientkey \
"$UPLOAD_TEST" --maru-expect-tests=5

echo "p5d: bundle PATH, localhost sshd attach, and host-backed upload product gates passed"
