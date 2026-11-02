# Process launch strategy PoC

This is an experiment, not a product repair. It generates separate source trees from Maru's own
current checkout and changes only their `bounded_process.zig` implementation. The checkout's
product files and its existing 24 bounded-process test expectations remain unchanged.

```sh
python3 tools/session-host/spawn-poc/run.py --output /absolute/new/directory --rounds 3
python3 tools/session-host/spawn-poc/analyze.py /absolute/new/directory
```

The directory must not already exist. Sources are linked read-only by convention; files modified
by the experiment are materialized as independent copies. Run the variants sequentially with
`-j1` to avoid making compiler or neighboring test load part of the performance comparison.

| Variant | Group creation | Exec setup |
| --- | --- | --- |
| `baseline` | Existing concurrent parent and child calls | Existing fork/exec |
| `parent-gate` | Parent alone; a private pipe releases the child after successful group creation | Existing fork/exec |
| `posix-spawn` | `POSIX_SPAWN_SETPGROUP`, group 0 | Darwin file actions and `CLOEXEC_DEFAULT` |

The existing bounded-process gate exercises closed environments, stdin, held working directories,
held executable paths, separate capture streams, fd 3 pipe/socket inheritance, output bounds,
deadline cleanup including descendants, and exact child failure observations. Two PoC-only tests
add an actual child PGID check and a non-CLOEXEC descriptor above a lowered soft limit. Their
test count is 26 only in the generated copies; the product gate still expects 24.
The PGID supplement also reports 30 capture-and-reap round trips per optimization mode. Use
`--bounded-only --skip-race-control` for a focused rerun of these contracts.

The exact fence gate runs Debug and ReleaseFast. Round 0 warms the artifacts; later rounds keep
its original 20 samples per profile. Performance records retain their mode, sample count,
median, p95, maximum, FD delta, stderr size, and verifier counts. A successful comparison driver
does **not** mean every prototype passed: `results.json` retains nonzero exits and failed tests.

The independent syscall control synchronizes overlapping group requests, then compares ordered
and child-only requests on the same host. A local success cannot replace macOS 15 CI evidence.

Important interpretation limits:

- Native `posix_spawn` errors are intentionally not turned into a fabricated child exit 126.
  Compatibility failures in the unchanged tests are results to assess, not tests to weaken.
- Existing deadlines start after launch. A production change must explicitly review startup
  time accounting; this PoC does not silently change that contract.
- Timings include the existing capture/reap loop and its 50 ms polling quantum. The three
  implementations run in a fixed order, so runner load and scheduler phase can also affect
  results. These are whole-operation measurements, not a pure spawn API benchmark; do not
  conclude a universal speed ordering from three rounds.
- The input offset reset occurs before spawn in the spawn prototype. The fork implementation
  resets the shared input description in the child. Failure ordering therefore needs review.
- The prototype does not replace the repository's `macos_spawn` facade. A product implementation
  must use that boundary, preserve its FD policy, and run the wider applicable gates.

The temporary workflow option dispatches only the experiment:

```sh
gh workflow run ci.yml --ref test/session-spawn-poc -f spawn_poc=true
```

The source is independently authored from POSIX/Darwin API contracts and Maru's own code.
No external application's implementation was copied. API basis:
[Apple spawn group attributes](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setpgroup.3.html).
