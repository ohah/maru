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
