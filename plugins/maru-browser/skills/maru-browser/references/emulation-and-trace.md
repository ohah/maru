# Emulation, CPU and network conditions, trace

Chromium tabs only. Check the exact flags in `maru browser --help`.

## `emulate` — make a tab look like another device

```sh
maru browser emulate --surface 12 --viewport 390x844@3,mobile,touch --user-agent "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"
maru browser emulate --surface 12 --locale ko-KR --timezone Asia/Seoul --reload
maru browser emulate --surface 12 --get
maru browser emulate --surface 12 --clear
```

- Setting is additive: only the groups you pass change. `--no-viewport`, `--no-locale` and the other `--no-…`
  flags clear one group; `--clear` clears all of them; `--get` shows what is set.
- The screen is scaled to fit the pane. Cross-site iframes and service workers keep the real values.
- A location change, or a clear, takes effect from the next page load — add `--reload`.
- The tab title shows ◫ while anything is emulated.

### Who owns it, and how long it lasts

| Setting | Lasts until |
|---|---|
| Viewport, user agent, locale, time zone, geolocation, media features, vision | `--clear` (or `--no-…`), the tab closes, or the user revokes it in the Browser Grants menu. On a user's tab it is only paused while another site is shown and comes back with that site. |
| `--cpu` (1–20× slower) and `--network` (presets or `--latency`) | The process that set them exits — for you, this agent process. Clear them yourself before you finish. |

- Current Maru does not ask the user (an older build asks once per site on a user's tab).
- **On a user's tab the emulation applies only on the site the tab shows when you set it**, and its subdomains
  (`site` in the result). Other sites see the real values. Setting it again while the tab shows another site moves
  it there. Set on a tab that shows no web page (about:blank, a file) or is between pages, it applies on every site
  until you set it while a site is shown (a tab already bound keeps its site). On tabs you opened (◈) it applies on
  every site. `--clear` works from any site.
- `--network` takes the presets, `offline` and `--latency` on any tab, the user's too.
- One pane owns a tab's emulation. Another pane gets `emulated_by_other_pane`.
- **If the user clicks or types in the tab, Maru drops your `--cpu` and `--network` there** (`released: human_input`).
  The other settings stay: clear them unless the user wants them kept. Do not apply anything again — the user is
  using the tab. Ask.

## `trace` — record a performance trace

Works on any Chromium tab, the user's too (an older Maru traces only tabs your pane opened and answers `-32008`
on others). A hidden tab keeps rendering while it records. Trace a user's tab only when the task is about it.

```sh
maru browser trace --surface 12 --duration 5s --out "$TMPDIR/maru-trace-1.json.gz"
```

- That one call starts, waits and stops. `trace start --surface <id>`, `trace stop --surface <id>`,
  `trace status --surface <id>` and `trace abort --surface <id>` split it up.
  `trace start --surface <id> --reload` reloads the page first, to trace a page load.
- 1–30 s, 5 s by default. `stop` prints a summary; `--out` also writes the trace (gzip JSON for Chrome DevTools'
  Performance panel) to a new file only — the `--out` rules in section 4 of SKILL.md. Use a fresh name in `$TMPDIR`.
- One trace at a time per browser (`trace_busy` — wait and retry once). The tab title shows ◔ while recording.
- The trace is discarded if the user uses the tab (`human_input` — likely on the user's tabs; ask before trying
  again), or another tab's frame shares its renderer process.
- This is not `maru trace`, which is Maru's own terminal trace tool.
