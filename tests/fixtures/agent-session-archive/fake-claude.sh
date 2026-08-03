#!/bin/sh
# AS4-c fixture-only provider stand-in. It accepts only Claude's provider-native resume argv;
# it never contacts a real Claude installation, account, or network.
set -eu

marker=${MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER:-"$HOME/.maru-agent-session-archive-marker"}

if [ "$#" -eq 2 ] && [ "$1" = "--resume" ] && [ "$2" = "fixture-claude-session" ]; then
    printf '%s\n' 'claude-resume-direct-argv' > "$marker"
    exit 0
fi

printf '%s\n' 'claude-resume-invalid-argv' > "$marker"
exit 64
