#!/bin/sh
# AS4-c fixture-only provider stand-in. It accepts only Claude's provider-native resume argv;
# it never contacts a real Claude installation, account, or network.
set -eu

marker=${MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER:-"$HOME/.maru-agent-session-archive-marker"}

# 모드 플래그를 선택적으로 받지 않는다 — 2-인자 형태도 통과시키면 "기록된 권한 모드를 그대로 되살린다"
# 가 깨져도 이 판정은 초록이다. fixture 의 마지막 턴이 bypassPermissions 이므로 argv 도 그래야 한다.
if [ "$#" -eq 4 ] && [ "$1" = "--resume" ] && [ "$2" = "fixture-claude-session" ] &&
    [ "$3" = "--permission-mode" ] && [ "$4" = "bypassPermissions" ]; then
    printf '%s\n' 'claude-resume-direct-argv' > "$marker"
    exit 0
fi

printf '%s\n' 'claude-resume-invalid-argv' > "$marker"
exit 64
