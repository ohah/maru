# Darwin PTY spawn experiment

Run from the repository root on macOS with Xcode Command Line Tools and Python 3:

```sh
python3 tools/pty-spawn-poc/run.py --output /tmp/maru-pty-poc-new
```

The destination must be new or empty. The runner compiles the independent C
syscall model with `-Wall -Wextra -Werror` in `-O0` and `-O2`, then compares 21
conditions for each of four modes. No product source or build wiring is changed.
Each child has an eight-second outer deadline; the Python call has a twelve-second
ceiling. Ctrl+C's expected negative control gets a short grace, then the driver
kills and reaps its own child. No unrelated PID or process group is targeted.
The login cohort invokes the installed Apple login command with the current user,
a controlled target and no shell startup files; normal OS login accounting may occur.

`results.json` and every raw `.log` retain observed values and mismatches. The C
source, compiled probes, compiler, SDK and source hash are retained for provenance.
Paths and login identity are local evidence; do not upload raw logs as public fixtures.

**168/168 expected observations is not 168 product passes.** The direct native
modes intentionally demonstrate missing controlling-terminal/foreground behavior,
failed cwd fallback and Ctrl+C requiring driver SIGKILL. Successful isolated helper
behavior does not prove a packaged, signed, production helper works.

See the [comparison and remaining gates](../../docs/plans/pty-native-spawn-poc.md).

Reproduce the four independent rejection mutations and the equivalent positive
control (all edits occur only on temporary copies):

```sh
python3 tools/pty-spawn-poc/controls.py --output /tmp/maru-pty-controls-new
```

A complete 168-observation behavioral result is required for every control;
compile failures do not count as successful rejection. The tool verifies that
the original C source hash was preserved.

## Real shell lifecycle follow-up

```sh
python3 tools/pty-spawn-poc/lifecycle.py --output /tmp/maru-pty-lifecycle-new
python3 tools/pty-spawn-poc/lifecycle_controls.py --output /tmp/maru-pty-lifecycle-controls-new
```

The default is **bash only**: 20 distinct contracts × fork/helper × O0/O2 = 80
comparisons. Live PTY output and child status/reap reports are retained separately.
`probe.c` uses the same `spawn_target` implementation for the original experiment
and this live bridge. The bridge has a twelve-second outer child deadline; each
readiness/state wait is also bounded. Jobs are tracked and killed only within the
fixture's own still-live session, then reaped by the shell. Child core dumps are disabled.

`--case`, `--mode`, `--optimization`, and `--shell` select focused cohorts; filtered
results are not counted as the full matrix. The controls require complete behavioral
JSON evidence, and include a normal equivalent pause-loop control.

`--shell /bin/zsh` is opt-in for a clean host. System `/etc/zshenv` is read even
with `-f`; the tool refuses zsh when that file contains executable lines. It does
not edit or bypass host init files. The development machine's zsh cohort was
excluded because an unrelated system init job affected termination. Do not count
it as product behavior or validated zsh compatibility.

The experiment waits for actual prompt publication after command completion.
The earlier resize mismatch is retained; the follow-up reproduced a stale bash
TIOCSWINSZ overwrite with explicit order controls (it cannot identify the historical writer retroactively); this matrix does not prove arbitrary mid-transition resize correctness.
See [design candidates, rejected cohorts and remaining product gates](../../docs/plans/pty-helper-lifecycle.md).


## Causal resize diagnostic (macOS arm64)

```sh
python3 tools/pty-spawn-poc/resize_study.py --output /tmp/maru-resize-fork-new --mode fork
python3 tools/pty-spawn-poc/resize_study.py --output /tmp/maru-resize-helper-new --mode spawn-helper
python3 tools/pty-spawn-poc/resize_review.py --study /tmp/maru-resize-fork-new/study.json --output /tmp/maru-resize-review-new.json
```

The tool creates and ad-hoc signs **owned copies** of bash/stty, compares normalized
executable-text fingerprints to the originals, and compiles an arm64/arm64e
interposer. Installed binaries, system init files and product code are not edited.
Only the owned actors/probe get the diagnostic environment. Actor copies stay in
local evidence and must not be committed or uploaded as repository fixtures.

One bash SET is held after command output and before the next prompt. The three
schedules reproduce a stale overwrite, reverse the writer order, and suppress
only the stale write as a counterfactual. That suppression is a diagnostic, not a
runtime fix. Native reads, actor/controller identities, rc and log order are checked.
The gate has a three-second ceiling and the live bridge retains its outer deadline.
Incomplete captures keep `progress.json`; only verified complete studies publish
`study.json`. The 33 independent evidence corruptions are checked with both normal
Python and `python3 -O`; changing scenario serialization order remains accepted.

See [causal findings and limits](../../docs/plans/pty-resize-overwrite.md).

Before causal capture, an owned GET/SET probe compares native return values and errno
with and without the observer. Failed observer conformance prevents study publication.


## Helper initialization status channel

```sh
python3 tools/pty-spawn-poc/init_status.py --output /tmp/maru-init-new
python3 tools/pty-spawn-poc/init_status_controls.py --output /tmp/maru-init-controls-new
```

The independent native helper reports a bounded version/stage/errno frame.
55 distinct contracts run in C O0/O2; EOF and exit zero are never target readiness.
Six compiled behavioral mutations must be rejected, while the original and
bytewise request transmission pass. New output directories retain partial cohorts.
This does not change the product or select a signed helper deployment strategy.
See [wire, ownership and validation limits](../../docs/plans/pty-helper-init-status.md).
