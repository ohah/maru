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
session_root=$(mktemp -d "/tmp/maru-agent-session-archive.XXXXXX")
trap 'rm -rf "$session_root"' EXIT HUP INT TERM
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
    font_size=${3:-}
    render_scale=${4:-}
    font_config=
    summary_name=$scenario
    geometry_name=
    capture_name=
    if [ "$scenario" = font-scale-rects ]; then
        case "$font_size:$render_scale" in
            14:1000|14:2000|24:1000|24:2000)
                font_config="$root/font-size-$font_size.config"
                cp "tests/fixtures/agent-session-archive/font-size-$font_size.config" "$font_config"
                summary_name="$scenario-font-$font_size-scale-$render_scale"
                geometry_name="$root/$summary_name.geometry.json"
                # 캡처 경로는 시나리오 이름 하나로 정해져 네 조합이 같은 파일을 노린다. 캡처 콜백은
                # 덮어쓰기를 막으려고 이미 있는 파일을 거부하므로(그대로 두면 2회차부터 시나리오가 실패),
                # geometry와 같은 규율로 **실행 전에 지우고 실행 후 접미사 이름으로 보관**한다.
                capture_name="$root/captures/$summary_name-list.ppm"
                rm -f "$root/font-scale-rects.geometry.json" "$geometry_name" \
                    "$root/captures/font-scale-rects-list.ppm" "$capture_name"
                ;;
            *)
                echo "font-scale-rects requires 14|24 pt and 1000|2000 scale" >&2
                exit 2
                ;;
        esac
    fi
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
    MARU_SESSION_HOST_ROOT="$session_root" \
    MARU_CONFIG="$font_config" \
    MARU_MACOS_APP_SMOKE_MS=15000 \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE=1 \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO="$scenario" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER="$marker" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CODEX="$bin/codex" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CLAUDE="$bin/claude" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REVEAL_PATH="$source_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REPLACEMENT_PATH="$replacement_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_REORDER_PATH="$reorder_path" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_RENDER_SCALE_MILLI="$render_scale" \
    MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR="$root" \
    "$app_path"
    test -f "$summary"
    cp "$summary" "$root/$summary_name.summary.txt"
    if [ -n "$geometry_name" ]; then
        test -s "$root/font-scale-rects.geometry.json"
        cp "$root/font-scale-rects.geometry.json" "$geometry_name"
    fi
    if [ -n "$capture_name" ]; then
        test -s "$root/captures/font-scale-rects-list.ppm"
        cp "$root/captures/font-scale-rects-list.ppm" "$capture_name"
    fi
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

# Four cold AppKit processes use the real window/view/Metal host path. The fixture can only
# control the render projection (not physical monitor migration), so the JSON records both.
run_scenario font-scale-rects codex 14 1000
run_scenario font-scale-rects codex 14 2000
run_scenario font-scale-rects codex 24 1000
run_scenario font-scale-rects codex 24 2000
for combo in 14-scale-1000 14-scale-2000 24-scale-1000 24-scale-2000; do
    geometry="$root/font-scale-rects-font-$combo.geometry.json"
    summary_file="$root/font-scale-rects-font-$combo.summary.txt"
    test -s "$geometry"
    grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$summary_file"
    grep -Eq '^agent_session_archive_smoke_scenario=font-scale-rects$' "$summary_file"
    jq -e '.schema == "maru.agent-session.font-scale-rects.v1" and (.snapshot_generation > 0) and (.rects | keys == ["expanded_card", "first_card", "header", "resume", "reveal", "scope_row", "search"]) and all(.rects[]; .raw_px.width > 0 and .raw_px.height > 0)' "$geometry" >/dev/null
done

# Within a scale terminal font may change only terminal cells, never Chrome dock/action geometry.
# Across scales the same raw backing rect must be exactly proportional within one low-scale px.
jq -s -e '
  def names: ["header", "scope_row", "search", "first_card", "expanded_card", "resume", "reveal"];
  def fields: ["x", "y", "width", "height"];
  def abs: if . < 0 then -. else . end;
  . as [$f14s1, $f14s2, $f24s1, $f24s2]
  | ($f14s1.render_scale_milli == 1000 and $f14s2.render_scale_milli == 2000 and $f24s1.render_scale_milli == 1000 and $f24s2.render_scale_milli == 2000)
    and all(names[] as $n | $f14s1.rects[$n] == $f24s1.rects[$n])
    and all(names[] as $n | $f14s2.rects[$n] == $f24s2.rects[$n])
    and all(names[] as $n | fields[] as $f | (($f14s2.rects[$n].raw_px[$f] - (2 * $f14s1.rects[$n].raw_px[$f])) | abs) <= 1.0)
    and all(names[] as $n | fields[] as $f | (($f24s2.rects[$n].raw_px[$f] - (2 * $f24s1.rects[$n].raw_px[$f])) | abs) <= 1.0)
' "$root/font-scale-rects-font-14-scale-1000.geometry.json" "$root/font-scale-rects-font-14-scale-2000.geometry.json" "$root/font-scale-rects-font-24-scale-1000.geometry.json" "$root/font-scale-rects-font-24-scale-2000.geometry.json" >/dev/null

# This is a physical `MaruMetalTerminalView.keyDown` route: Cmd+= grows the fully visible
# published scope-row rect, Cmd+- returns it to its original height, and a second Cmd+- shrinks
# it below baseline. The inline resume action may be scroll-clipped, so its visible hit height is
# intentionally not used as a scale witness.
run_scenario font-zoom
grep -Eq '^agent_session_archive_smoke_stage=succeeded$' "$root/font-zoom.summary.txt"
grep -Eq '^agent_session_archive_smoke_scenario=font-zoom$' "$root/font-zoom.summary.txt"
grep -Eq '^agent_session_archive_smoke_terminal_invariant=true$' "$root/font-zoom.summary.txt"

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
for capture in resume-pointer-list resume-pointer-loading resume-pointer-ready detail-stale-loading detail-stale-stale expanded-scroll-anchor-scroll-anchor-before expanded-scroll-anchor-scroll-anchor-after font-scale-rects-font-14-scale-1000-list font-scale-rects-font-24-scale-1000-list; do
    ppm="$root/captures/$capture.ppm"
    png="$root/captures/$capture.png"
    test -s "$ppm"
    test "$(head -n 1 "$ppm")" = 'P6'
    sips -s format png "$ppm" --out "$png" >/dev/null
    test -s "$png"
    file "$png" | grep -q 'PNG image data'
done
