# Session host upgrade recovery — 2026-10-27

## Incident and scope

The signed Debug app installed for PR #4623 replaced the GUI successfully, but the existing host logged
`restore stage failed: stage=activate err=DeadlineExceeded rollback_allowed=yes rollback=armed`.
The GUI then logged `result=upgrade_failed ... reconnect=transient_timeout`, spawned a different host,
and rejected workspace window 0 with `PersistentRuntimeUnavailable / startup_timeout`.
The incomplete-restore latch preserved the saved workspace (10 tabs, 29 runtime handles). The old host
rolled back in the same PID and retained its children. A later GUI restart attached to it.

These observations establish a failed host upgrade and failed first-launch restoration, not deletion
of the workspace or proof that a restored GUI means the host was upgraded.

## Fix

- `connectUpgradingHostWith` shares one monotonic absolute deadline across connect, hello, retries,
  and backoff. Inner transient timeout and stale manifest are retryable; authority/protocol failures
  remain fatal. A late successful connection is disposed instead of accepted after expiry.
- GUI reconnect allows 5s target + 5s rollback preparation + 5s loader/hello scheduling. The product's
  5s pause deadline and its integrity/authority checks are unchanged.
- A pending predecessor hello is retried instead of being mislabeled as a rollback.
  `Client.upgradeStatusUntil` shares that same absolute deadline.
- `HostSet` records the failed manifest publication. A strictly newer publication can be probed once
  after rollback; the same/older/unknown publication remains excluded. Ready, held lease, wire and
  spawn capability gates remain required. A recovered old image is never reported as a committed
  target upgrade.
- Restore logs now include prepared runtime count, elapsed/remaining budget, and the exact deadline
  check boundary. No terminal contents or commands are logged.
- Distribution candidates use `-Doptimize=ReleaseFast`. The previously installed Debug GUI's live
  sample placed BLAKE3 pending-event integrity work at the top of the CPU-active stacks. The app
  footprint was ~257MiB during that sample, so it was not the owner of the system's ~31GiB total use.

## Independent hostile cases

All cases below exercise final source, not repeated runs of one input.

| Case | Expected |
| --- | --- |
| 1. Inner transient timeout before total deadline | Retry under the original expiry |
| 2. Handshake closes during exec | Retry under the original expiry |
| 3. Hello build identity precedes manifest republish | Retry stale manifest |
| 4. Manifest lifecycle is still restoring | Wait within the same expiry |
| 5. Initial manifest is unavailable/invalid | Retry only within that expiry |
| 6. Manifest/endpoint temporarily absent after supervised exec | Bounded retry |
| 7. Unauthorized peer | One attempt, no wait |
| 8. Endpoint access denied | One attempt, no wait |
| 9. Wire version mismatch | One attempt, no wait |
| 10. Out of memory | One attempt, no wait |
| 11. Protocol error | One attempt, no wait |
| 12. Deadline already expired | Zero attempts/waits |
| 13. Repeated failure with same publication | No redundant probe |
| 14. Publication moves backwards | No redundant probe |
| 15. Current publication time unknown | No inferred recovery |
| 16. A different host ID has no failed observation | Unaffected by exclusion set |
| 17. Same host publishes newer ready state | One fresh probe can reuse it |
| 18. New publication is not ready | No probe |
| 19. New publication has incompatible wire | No probe |
| 20. New publication has free/unknown owner lease | No probe |
| 21. Fresh probe fails too | Its publication becomes excluded |
| 22. Failed publication identity was never known | No timestamp-based bypass |
| 23. Definitive transport deadline/resource exhaustion | Fail immediately |
| 24. A ready predecessor still reports pending immediately after accepted | Wait for target/terminal report, do not infer rollback from epoch alone |

`test-session-host-upgrade-recovery` runs the bounded retry test, publication tests in Debug/ReleaseFast,
and the wiring boundary. `test-upgrade-scan-policy` protects the surrounding scan and admission ordering.
Product rollback, nonempty rollback and precommit-failure matrix gates cover existing rollback invariants.

## Signed executable measurements

The isolated harness used the previous installed signed CLI from the preserved application backup,
never the user's live host. The test root was a separate owner-only `/tmp/maru-upgrade-*` directory.

- 29 PTYs, ReleaseFast candidate: committed epoch 0→1; same host PID; all child PIDs preserved;
  before-screen markers preserved; after-upgrade input works; exact GUI-protocol reattach works;
  exit=23 reaps children and inventory removal is checked.
- 29 PTYs with 512 warmup output lines each and 138×69 viewport: the ReleaseFast candidate passed
  the same checks. Artifact: `/tmp/maru-upgrade-rel29-history512-eeae0d59.json`.
- Early harness runs against the Debug target raised `UpgradeEpochMismatch`. Investigation found a
  false-negative race: the first reconnect can still be the pending predecessor. Those early epoch
  failures alone are **not** evidence of rollback. The harness now polls the attempt result and target
  build before evaluating epoch; the incident's real `DeadlineExceeded`/rollback remains established
  by the preserved user-host log. Log of the earlier incomplete measurement:
  `/tmp/maru-upgrade-debug-history29.log`.
- These two executables also differ by recovery/diagnostic changes; this is not claimed to be a
  perfectly single-variable optimizer benchmark. A separate live GUI sample supports the Debug CPU
  diagnosis: `/tmp/maru-gui-highcpu.sample.txt`.

The signed harness previously set namespace override only in the child and could reject its own
manifest; it now scopes/restores the parent override too. It retries initial publication and exec-time
manifest transitions. It accepts bash as the predecessor's implementation of the controlled sh
fixture while still requiring PID continuity, output/input markers and exact exit status.

## Limits and operational safety

The user's running GUI and host were not restarted, upgraded, or killed during these tests. A newly
built app is not evidence that the running process has been replaced. Full installed-GUI quit/relaunch
and an after-install GUI CPU measurement must be distinguished from the isolated signed-host tests.
Local `/tmp` artifacts are reproducible evidence paths, not uploaded GitHub attachments.


## Final-code results

- `test-session-host-upgrade-recovery`: retry deadline case passed; publication tests passed in both
  Debug and ReleaseFast; 2 wiring checks passed.
- `test-upgrade-scan-policy`, product rollback, nonempty rollback and restore-precommit failure matrix:
  passed. Log: `/tmp/maru-upgrade-final-verified-tests.log`.
- Client public receiver/guard audit: 4 passed, including `upgradeStatusUntil` and its shared fence.
  Log: `/tmp/maru-upgrade-client-api-audit.log`.
- Final signed ReleaseFast bundle's CLI, with the corrected pending-state harness, 29 PTYs and 512
  warmup lines: passed, epoch 0→1, all PID/input/marker/inventory checks true.
  Artifact: `/tmp/maru-upgrade-verified-rel29-eeae0d59.json`.
- Build: `zig build -j1 -Doptimize=ReleaseFast macos-app-bundle`; Developer ID signing and strict/deep
  verification passed. Local copies of the above evidence are in
  `dist/verification/session-host-upgrade-recovery/`.


## Approved installed-app check and launcher color regression

After notarization `982f7305-1324-42aa-b64c-261f464df899` was accepted, the user
approved replacement. The ReleaseFast GUI was installed and normally relaunched.
The existing host PID 2902 committed epoch 0→1; the log reported `result=upgraded`.
All 26 recorded child PIDs and the saved runtime handles survived (7 tabs, 26 surfaces).
A short post-startup CPU sample was 21.2% of one core; this is not a long-term benchmark.
Evidence: `/tmp/maru-release-install-before.json` and
`/tmp/maru-release-install-processes-before.json`.

The launch environment introduced a separate color regression: the new GUI inherited
`NO_COLOR=1`, and a newly launched Codex process also had it, while existing Codex and
Claude processes did not. Only whitelisted color variables were inspected; no secrets
or terminal input were collected. The shared inherited-environment filter previously
removed FORCE_COLOR and CLICOLOR_FORCE but omitted NO_COLOR. It now removes NO_COLOR
from inherited environments, including the GUI parent snapshot sent to the shared host.
Explicit complete environments and user config overrides remain intentional and preserved.
No renderer or provider-specific color forcing is introduced.

Additional adversarial cases:

| Case | Evidence / expected behavior |
| --- | --- |
| 25. NO_COLOR=1 inherited from launcher | EnvStorage drops it |
| 26. GUI parent snapshot contains NO_COLOR=1 | Snapshot path drops it too |
| 27. Explicit NO_COLOR=1 environment | Preserved |
| 28. Config override NO_COLOR=1 | Preserved exactly once |
| 29. NO_COLORFUL=1 or lowercase on POSIX | Not mistaken for NO_COLOR |
| 30. Empty NO_COLOR and Windows mixed-case key | Recognized by shared filter |

`zig test src/inherited_env.zig`: 1 passed.
`zig build -j1 test-terminal-environment`: 46 passed.
`zig build -j1 test-pty`: all 15 test bodies passed, but the runner failed because
OSC 11 response buffer allocations leaked in two reader-processing cases. This is
not reported as a passing gate; log `/tmp/maru-no-color-pty-tests.log`. The allocations
are in `pty_reader.appendResponseBounded`, outside the changed environment filter.
The whole installed-app visual result still requires approval and a new launch after
this color fix is signed and notarized. Already-running monochrome providers retain
their old process environment until they are relaunched.
