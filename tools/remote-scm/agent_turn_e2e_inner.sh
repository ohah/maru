#!/bin/sh
# 에이전트 턴 축(AT3c 원격 스냅샷 · RA8 훅 커맨드 통일 · AT3d 겨냥 ∧ 목록)의 **실기 e2e** — 수동 검증 도구, 게이트가 아니다.
#
# 무엇을 하나: 이 Mac 에서 새 Maru.app 을 띄우고, 그 pane 이 `maru ssh` 로 **이 Mac 자신**(하네스 loopback sshd)에 들어가
# claude 를 한 턴 돌린다 — 사용자 워크플로(다른 기기의 GUI → ssh → 이 Mac)와 같은 경로다. 끝에 에이전트 탭을 찍는다.
#
# 전제(전부 사용자 소유라 게이트로 못 만든다):
#   - ssh 대상(= 이 Mac)의 PATH 에 있는 `maru`(`~/.local/bin/maru`)가 **이 빌드**여야 한다 — 원격 설치기가 그것을 돌린다.
#   - `claude` 가 로그인돼 있고 `$HOME/.claude/settings.json` 을 **실제로** 고친다(원격 훅 설치 — 사용자 워크플로가 하는 그 일).
#   - `zig build macos-app-bundle` 이 끝나 있다.
#
# 사용: sh tools/remote-scm/agent_turn_e2e.sh /tmp/agent-turn-e2e.png
#       MARU_E2E_TMUX_PANES=1|2 sh tools/remote-scm/agent_turn_e2e.sh <out.png>   # 원격 tmux 안(사용자 플로우) · 한 세션에 pane 둘(RA7)
# 결과: 스크린샷(에이전트 탭 «N개 파일 · ✎ AI 편집 N»), 원격 훅 로그(`~/.cache/maru/remote-agent-events/<pid>_<pane>.ndjson`),
#       원격 임시 index(`/tmp/maru-turn-<hash>.idx`), 하네스 저장소의 `git status`(index 불변), `settings.json` mtime(재설치 무변경).
# 2026-09-21 실기 결과는 계획 AT3d «수동 검증» 절에 있다.
set -eu
OUT=$1
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
APP=$ROOT/zig-out/Maru.app/Contents/MacOS/maru-macos-app
: "${MARU_REMOTE_SCM_DEST:?}"; : "${MARU_REMOTE_SCM_CTL:?}"; : "${MARU_REMOTE_SCM_REPO:?}"; : "${MARU_REMOTE_SCM_PORT:?}"; : "${MARU_REMOTE_SCM_KEY:?}"
CAP_HOME=/tmp/maru-e2e-home
rm -rf "$CAP_HOME"; mkdir -p "$CAP_HOME/.cache/maru" "$CAP_HOME/.config/maru"
# 원격 저장소(= 이 Mac 의 하네스 repo) — 커밋 하나 위에 편집 대상 둘.
GIT=/usr/bin/git
rm -rf "$MARU_REMOTE_SCM_REPO"; mkdir -p "$MARU_REMOTE_SCM_REPO"
"$GIT" -C "$MARU_REMOTE_SCM_REPO" init -q -b main .
printf 'line 1\nline 2\n' > "$MARU_REMOTE_SCM_REPO/capture1.txt"
printf 'old content\n' > "$MARU_REMOTE_SCM_REPO/capture2.txt"
"$GIT" -C "$MARU_REMOTE_SCM_REPO" add -A
GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@maru.test GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@maru.test \
  "$GIT" -C "$MARU_REMOTE_SCM_REPO" -c commit.gpgsign=false commit -q -m base
# pane 의 셸 = `maru ssh`(새 CLI)로 이 Mac 에 들어가서 새 훅 세트가 심길 때까지 기다린 뒤 claude 한 턴, 그리고 대기.
#
# `MARU_E2E_TMUX_PANES=0`(기본): 원격 셸에서 바로 claude — tmux 밖.
# `MARU_E2E_TMUX_PANES=1|2`: 원격에 **`LC_MARU_PANE` 없이** tmux 서버를 띄우고(사용자 워크플로 — 서버는 예전에 떠 있어 pane 에
#   값이 없고 RA6 역조회로 주인을 찾는다) `maru ssh -t … tmux attach` 로 붙는다. pane 마다 claude 를 한 턴씩(파일이 다르다).
#   2 면 한 tmux 세션에 pane 둘 — RA7 이 다루는 배치다.
PANES=${MARU_E2E_TMUX_PANES:-0}
WAIT_HOOKS="i=0; until grep -q '\"PreToolUse\"' \$HOME/.claude/settings.json; do i=\$((i+1)); [ \$i -lt 90 ] || break; sleep 1; done; echo \"hooks-ready after \$i s\""
CLAUDE_BIN="export PATH=\$HOME/.local/bin:\$PATH; claude_bin=\$(command -v claude || echo \$HOME/.local/bin/claude)"
PROMPT1='Use the Edit tool to change the text \"line 1\" to \"line 1 edited by maru e2e\" in capture1.txt, then use the Write tool to overwrite capture2.txt with exactly one line: written by maru e2e. Do not run any shell commands and do not explain.'
PROMPT2='Use the Write tool to create capture3.txt with exactly one line: pane two wrote this. Do not run any shell commands and do not explain.'
TURN1="\$claude_bin -p '$PROMPT1' --permission-mode acceptEdits --allowedTools Edit,Write,Read 2>&1 | tail -5; echo claude-done"
TURN2="\$claude_bin -p '$PROMPT2' --permission-mode acceptEdits --allowedTools Edit,Write,Read 2>&1 | tail -5; echo claude-done-2"
SSH_T=""
if [ "$PANES" = 0 ]; then
  REMOTE_CMD="cd $MARU_REMOTE_SCM_REPO && $WAIT_HOOKS; env | grep -E '^LC_MARU_PANE|^TMUX' || echo no-LC_MARU_PANE; $CLAUDE_BIN; $TURN1; sleep 900"
else
  SSH_T="-t"
  SOCK="/tmp/maru-e2e-tmux.\$\$"
  # 서버는 LC_MARU_PANE **없이** 뜬다(사용자의 서버가 그렇다). pane 셸은 훅 세트를 기다렸다가 claude 를 돌린다.
  PANE_SCRIPT1="cd $MARU_REMOTE_SCM_REPO; $WAIT_HOOKS; env | grep -E '^LC_MARU_PANE|^TMUX_PANE' || echo no-LC_MARU_PANE; $CLAUDE_BIN; $TURN1; sleep 900"
  PANE_SCRIPT2="cd $MARU_REMOTE_SCM_REPO; $WAIT_HOOKS; env | grep -E '^LC_MARU_PANE|^TMUX_PANE' || echo no-LC_MARU_PANE; $CLAUDE_BIN; $TURN2; sleep 900"
  P1_B64=$(printf '%s' "$PANE_SCRIPT1" | base64 | tr -d '\n')
  P2_B64=$(printf '%s' "$PANE_SCRIPT2" | base64 | tr -d '\n')
  # 비대화형 ssh 셸의 PATH 에는 homebrew 가 없다 — tmux 를 찾을 수 있게 앞에 붙인다.
  REMOTE_CMD="export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; SOCK=$SOCK; env -u LC_MARU_PANE tmux -S \$SOCK new-session -d -s e2e -x 80 -y 24 \"printf %s $P1_B64 | base64 -D | sh\""
  if [ "$PANES" = 2 ]; then
    REMOTE_CMD="$REMOTE_CMD; env -u LC_MARU_PANE tmux -S \$SOCK split-window -t e2e \"printf %s $P2_B64 | base64 -D | sh\""
  fi
  REMOTE_CMD="$REMOTE_CMD; exec tmux -S \$SOCK attach -t e2e"
fi
REMOTE_B64=$(printf '%s' "$REMOTE_CMD" | base64 | tr -d '\n')
cat > "$CAP_HOME/pane.sh" <<WRAP
#!/bin/sh
exec $ROOT/zig-out/bin/maru ssh $SSH_T -p $MARU_REMOTE_SCM_PORT -i $MARU_REMOTE_SCM_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes $MARU_REMOTE_SCM_DEST 'sh -c "\$(printf %s $REMOTE_B64 | base64 -D)"'
WRAP
chmod 700 "$CAP_HOME/pane.sh"
{
  printf 'session.keep-alive-after-quit = false\n'
  printf 'shell.command = %s\n' "$CAP_HOME/pane.sh"
  printf 'sidebar.agent-hooks = true\n'
  printf 'shell.args =\n'
} > "$CAP_HOME/.config/maru/config"
# GUI 가 계산할 control socket 경로에 하네스 소켓을 잇는다(ControlMaster=auto 가 재사용 → 인증 불필요).
CTL_WANT=$(zig run "$ROOT/tools/remote-scm/ctl_path.zig" -- "$CAP_HOME" "$MARU_REMOTE_SCM_DEST" 2>&1 | tail -1)
case "$CTL_WANT" in "$CAP_HOME"/*) ;; *) echo "ctl path calc failed: $CTL_WANT" >&2; exit 1 ;; esac
ln -s "$MARU_REMOTE_SCM_CTL" "$CTL_WANT"
SHOT=$CAP_HOME/shot.ppm
echo "settings.json before: $(stat -f '%Sm' $HOME/.claude/settings.json) events=$(python3 -c 'import json,os;print(sorted(json.load(open(os.path.expanduser("~/.claude/settings.json")))["hooks"].keys()))')"
ls ~/.cache/maru/remote-agent-events/ > "$CAP_HOME/remote-events-before.txt" 2>/dev/null || true
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  HOME="$CAP_HOME" CFFIXED_USER_HOME="$CAP_HOME" \
  MARU_FORCE_SCM=1 MARU_FORCE_SCM_TAB=agent \
  MARU_SCREENSHOT="$SHOT" MARU_SCREENSHOT_DELAY_MS=170000 \
  "$APP" > "$CAP_HOME/app.out" 2>&1 || echo "app exit: $?"
cp "$SHOT" "${OUT%.png}.ppm" 2>/dev/null && python3 "$ROOT/tools/remote-scm/ppm_to_png.py" "$SHOT" "$OUT" || echo "no screenshot"
echo "settings.json after: $(stat -f '%Sm' $HOME/.claude/settings.json) events=$(python3 -c 'import json,os;print(sorted(json.load(open(os.path.expanduser("~/.claude/settings.json")))["hooks"].keys()))')"
echo "=== app.out (tail)"; tail -20 "$CAP_HOME/app.out"
echo "=== std.log"; tail -40 "$CAP_HOME/.cache/maru/app.log" 2>/dev/null | grep -iE 'agent|hook|remote|snapshot|turn' | tail -25
echo "=== remote events new files"; ls -la ~/.cache/maru/remote-agent-events/ | grep -v -f "$CAP_HOME/remote-events-before.txt" || true
echo "=== /tmp/maru-turn idx"; ls -la /tmp/maru-turn-*.idx 2>/dev/null || echo none
if [ "$PANES" != 0 ]; then echo "=== tmux servers left"; for sk in /tmp/maru-e2e-tmux.*; do [ -S "$sk" ] && { tmux -S "$sk" list-panes -a -F '#{session_name} #{pane_id} #{pane_current_command}' 2>/dev/null; tmux -S "$sk" kill-server 2>/dev/null; }; done; fi
echo "=== sidecars new"; for f in $(ls ~/.cache/maru/remote-agent-events/*.tmux 2>/dev/null); do b=$(basename "$f"); grep -qx "$b" "$CAP_HOME/remote-events-before.txt" || printf '%s\t%s\n' "$b" "$(tr '\t' ' ' < "$f")"; done
echo "=== repo status"; "$GIT" -C "$MARU_REMOTE_SCM_REPO" status --short; cat "$MARU_REMOTE_SCM_REPO/capture1.txt" "$MARU_REMOTE_SCM_REPO/capture2.txt"
