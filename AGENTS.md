# Maru Agent Guide

## Commands

- Install/select toolchain: `mise install`
- Build: `mise run build`
- Test: `mise run test`
- Format: `mise run fmt`
- Check: `mise run check`
- Direct Zig test: `zig build test`

## Project Rules

- Use Zig 0.16.0 from `.mise.toml`.
- Keep Ghostty under `references/` as reference-only material.
- Do not copy source from Ghostty into Maru.
- Keep terminal-core APIs behind local Maru facades.
- Do not push directly to `main`; use a branch and PR.
- Write beginner-friendly comments for new code that explain why the code exists, not just what it does.
- PR descriptions must explain intent, tradeoffs, verification, and any remaining limitations in beginner-friendly language.
- Fix bugs at the root cause. Do not patch symptoms; change structure if the structure is the reason for the bug.
- Prefer TDD for every area where the behavior can be expressed before implementation.
- Every test file must explain what the test is proving and why that matters for a terminal.
- Every feature area should have an E2E path. If an area cannot be E2E-tested, report that limitation to the user before treating the work as complete.
- Keep code extensible with clear responsibility boundaries. If a module starts owning unrelated behavior, split the module instead of adding more flags.

## Structure

- Zig core: `src/`
- E2E tests: `tests/e2e/`
- Architecture notes: `docs/`
- External references: `references/`
