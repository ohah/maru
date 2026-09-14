#!/bin/sh
# AS4-c fixture-only provider stand-in.  It proves that the terminal child receives exactly the
# provider-native argv; it never contacts an account, network, or a real Codex installation.
set -eu

# The direct child inherits HOME as part of the normal PTY environment.  The explicit marker is
# preferred, while the HOME fallback makes an accidentally stripped non-product test variable a
# visible fixture failure rather than a silent timeout.
marker=${MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER:-"$HOME/.maru-agent-session-archive-marker"}

# Codex 는 축이 둘(승인 정책 · 샌드박스)이라 둘 다 요구한다. 한쪽만 봐도 나머지 한쪽이 조용히
# 빠지는 회귀가 통과한다.
if [ "$#" -eq 6 ] && [ "$1" = "resume" ] && [ "$2" = "fixture-codex-session" ] &&
    [ "$3" = "--ask-for-approval" ] && [ "$4" = "never" ] &&
    [ "$5" = "--sandbox" ] && [ "$6" = "danger-full-access" ]; then
    printf '%s\n' 'codex-resume-direct-argv' > "$marker"
    exit 0
fi

printf '%s\n' 'codex-resume-invalid-argv' > "$marker"
exit 64
