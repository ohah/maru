#!/bin/sh
# Runs isolated cold AppKit processes so pointer and keyboard archive actions cannot share a
# completed action, terminal, or external-open one-shot.  Paths stay inside the explicit
# zig-out fixture root; the summaries contain only opaque scenario/verdict/count fields.
set -eu

app_path=${1:?Maru app executable path is required}
# AppSession's config/statusline adapters intentionally require absolute HOME-derived paths.
# Resolve once here instead of relying on the build runner's current directory.
workspace=$(pwd -P)
root="$workspace/zig-out/maru-agent-session-archive-smoke"
home="$root/home"
bin="$root/bin"
marker="$root/fake-provider.verdict"
source_path="$home/.codex/sessions/2026/08/03/rollout-fixture.jsonl"
claude_path="$home/.claude/projects/fixture-project/fixture-claude.jsonl"
# The replacement must share the source directory for atomic rename, but it must not be a
# scanner candidate before the stale scenario. A non-JSONL temporary name keeps the published
# archive card bound to `source_path`; rename then gives the replacement its JSONL target name.
replacement_path="$home/.codex/sessions/2026/08/03/.rollout-replacement.tmp"
# This record is deliberately distinct from the opened source. The scroll-anchor scenario only
# changes its mtime while the normal refresh worker is gated, so the expanded source retains its
# inode and the replacement projection must exercise identity-anchor restoration rather than the
# stale-source fallback.
reorder_path="$home/.codex/sessions/2026/08/03/rollout-fixture-scroll-anchor.jsonl"
summary="$workspace/zig-out/maru-macos-app/app.summary.txt"

case "$root" in
    "$workspace"/zig-out/maru-agent-session-archive-smoke) ;;
    *)
        echo "refusing an unexpected archive smoke fixture root: $root" >&2
        exit 2
        ;;
esac

test -x "$app_path"
rm -rf "$root"
mkdir -p "$home/.codex/sessions/2026/08/03" "$home/.claude/projects/fixture-project" "$bin"
mkdir -p "$root/captures"
cp tests/fixtures/agent-session-archive/fake-codex.sh "$bin/codex"
cp tests/fixtures/agent-session-archive/fake-claude.sh "$bin/claude"
chmod 755 "$bin/codex"
chmod 755 "$bin/claude"

run_scenario() {
    scenario=$1
    provider=${2:-codex}
    rm -f "$marker"
    # Each cold process starts from a new pair: a prior atomic replacement cannot leak into the
    # next scenario, and the temporary sibling remains outside the scanner's JSONL candidate set.
    rm -f "$source_path" "$replacement_path" "$claude_path" "$reorder_path"
    for index in 1 2 3 4 5; do
        rm -f "$home/.codex/sessions/2026/08/03/rollout-fixture-scroll-$index.jsonl"
    done
    case "$provider" in
        codex)
            cp tests/fixtures/agent-session-archive/codex-ready.jsonl "$source_path"
            cp tests/fixtures/agent-session-archive/codex-ready.jsonl "$replacement_path"
            # The list capture needs more than one card to make card height and inter-item gap
            # reviewable. Keep these extra scanner-only records deterministically older, so the
            # original source remains the selected resume fixture and its direct argv verdict is
            # unchanged.
            cp tests/fixtures/agent-session-archive/codex-list-second.jsonl "$home/.codex/sessions/2026/08/03/rollout-fixture-list-second.jsonl"
            cp tests/fixtures/agent-session-archive/codex-list-third.jsonl "$home/.codex/sessions/2026/08/03/rollout-fixture-list-third.jsonl"
            touch -t 202001010000 "$home/.codex/sessions/2026/08/03/rollout-fixture-list-second.jsonl" "$home/.codex/sessions/2026/08/03/rollout-fixture-list-third.jsonl"
            if [ "$scenario" = expanded-scroll-anchor ]; then
                # Keep the source record newest at initial scan. Eight distinct records make the
                # expanded row scrollable in the real 1920×960 AppKit viewport; ids differ so
                # scanner dedup cannot collapse the fixture back to a non-scrollable list.
                cp tests/fixtures/agent-session-archive/codex-list-second.jsonl "$reorder_path"
                sed -i '' 's/fixture-codex-list-second/fixture-codex-scroll-anchor/' "$reorder_path"
                for index in 1 2 3 4 5; do
                    path="$home/.codex/sessions/2026/08/03/rollout-fixture-scroll-$index.jsonl"
                    cp tests/fixtures/agent-session-archive/codex-list-third.jsonl "$path"
                    sed -i '' "s/fixture-codex-list-third/fixture-codex-scroll-$index/" "$path"
                    touch -t 202001010000 "$path"
                done
                touch -t 202001010000 "$reorder_path"
            fi
            ;;
        claude)
            cp tests/fixtures/agent-session-archive/claude-ready.jsonl "$claude_path"
            ;;
        *)
            echo "unknown archive smoke provider: $provider" >&2
            exit 2
            ;;
    esac
    HOME="$home" \
    CFFIXED_USER_HOME="$home" \
    MARU_MACOS_APP_SMOKE_MS=15000 \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE=1 \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO="$scenario" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER="$marker" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CODEX="$bin/codex" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CLAUDE="$bin/claude" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REVEAL_PATH="$source_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REPLACEMENT_PATH="$replacement_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REORDER_PATH="$reorder_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR="$root" \
    "$app_path"
    test -f "$summary"
    cp "$summary" "$root/$scenario.summary.txt"
}

run_scenario resume-pointer
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=resume-pointer$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=true$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_list=true$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_loading=true$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_ready=true$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_stale=false$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_list_artifact=captures/resume-pointer-list\.ppm$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_loading_artifact=captures/resume-pointer-loading\.ppm$' "$root/resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_ready_artifact=captures/resume-pointer-ready\.ppm$' "$root/resume-pointer.summary.txt"

run_scenario resume-keyboard
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/resume-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=resume-keyboard$' "$root/resume-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=true$' "$root/resume-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/resume-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/resume-keyboard.summary.txt"

run_scenario reveal-pointer
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/reveal-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=reveal-pointer$' "$root/reveal-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/reveal-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=1$' "$root/reveal-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/reveal-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/reveal-pointer.summary.txt"

run_scenario reveal-keyboard
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/reveal-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=reveal-keyboard$' "$root/reveal-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/reveal-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=1$' "$root/reveal-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/reveal-keyboard.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/reveal-keyboard.summary.txt"

run_scenario detail-stale
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=detail-stale$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_loading=true$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_ready=false$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_stale=true$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_loading_artifact=captures/detail-stale-loading\.ppm$' "$root/detail-stale.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_stale_artifact=captures/detail-stale-stale\.ppm$' "$root/detail-stale.summary.txt"

run_scenario detail-close-reopen
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=detail-close-reopen$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/detail-close-reopen.summary.txt"
grep -Eq '^agent_session_archive_smoke_terminal_invariant=true$' "$root/detail-close-reopen.summary.txt"

run_scenario snapshot-replace-pointer
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/snapshot-replace-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=snapshot-replace-pointer$' "$root/snapshot-replace-pointer.summary.txt"
# The held press belongs to a now-stale immutable snapshot. Its later release must not invoke
# the provider, admit the old log path, or create/focus a terminal surface.
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/snapshot-replace-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/snapshot-replace-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/snapshot-replace-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/snapshot-replace-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_terminal_invariant=true$' "$root/snapshot-replace-pointer.summary.txt"

run_scenario expanded-scroll-anchor
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=expanded-scroll-anchor$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_scroll_dispatched=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_anchor_before_present=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_anchor_after_present=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_anchor_raw_top_preserved=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_anchor_snapshot_reordered=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_anchor_new_generation_published=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_terminal_invariant=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_scroll_anchor_before=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_scroll_anchor_after=true$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_scroll_anchor_before_artifact=captures/expanded-scroll-anchor-scroll-anchor-before\.ppm$' "$root/expanded-scroll-anchor.summary.txt"
grep -Eq '^agent_session_archive_smoke_capture_scroll_anchor_after_artifact=captures/expanded-scroll-anchor-scroll-anchor-after\.ppm$' "$root/expanded-scroll-anchor.summary.txt"

run_scenario reveal-recheck-pointer
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/reveal-recheck-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=reveal-recheck-pointer$' "$root/reveal-recheck-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=false$' "$root/reveal-recheck-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/reveal-recheck-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_rejected_count=0$' "$root/reveal-recheck-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=1$' "$root/reveal-recheck-pointer.summary.txt"

run_scenario claude-resume-pointer claude
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/claude-resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=claude-resume-pointer$' "$root/claude-resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_fake_resume_verdict=true$' "$root/claude-resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_claude_model_present=1$' "$root/claude-resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_reveal_allowed_count=0$' "$root/claude-resume-pointer.summary.txt"
grep -Eq '^agent_session_archive_smoke_stale_reveal_count=0$' "$root/claude-resume-pointer.summary.txt"

# The two sentinel cold processes cover every product detail state without making every action
# variant perform expensive Metal readback. `sips` only repackages renderer-written PPM so the
# resulting PNG is reviewable in a PR; it never captures an AppKit view through another path.
for capture in resume-pointer-list resume-pointer-loading resume-pointer-ready detail-stale-loading detail-stale-stale expanded-scroll-anchor-scroll-anchor-before expanded-scroll-anchor-scroll-anchor-after; do
    ppm="$root/captures/$capture.ppm"
    png="$root/captures/$capture.png"
    test -s "$ppm"
    test "$(head -n 1 "$ppm")" = 'P6'
    sips -s format png "$ppm" --out "$png" >/dev/null
    test -s "$png"
    file "$png" | grep -q 'PNG image data'
done
