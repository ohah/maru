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

## Structure

- Zig core: `src/`
- Architecture notes: `docs/`
- External references: `references/`
