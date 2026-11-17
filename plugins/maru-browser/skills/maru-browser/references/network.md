# Network

Chromium tabs only. Check the exact flags in `maru browser --help`.

## What you see

- Current Maru does not ask the user: every network command works on every tab (an older build asks once per site
  on the user's tabs and wants `network` before `network-record`, `network-block` and `network-mock`).
- You see requests made since your pane first used the tab (on tabs you opened: since the tab was created, unless
  the user used it before your first read).
- `Cookie`, `Set-Cookie` and `Authorization` values show, except when the user turned full network detail off.
  Request bodies are not recorded; response bodies only while `network-record` is on.

## Reading

```sh
maru browser network --surface 12 --status 4xx
maru browser network --surface 12 --type xhr --url-contains /api/
maru browser network-request --surface 12 --req 7 --body
```

- `network` lists newest first. Page with `--before-req <n>` (the `next_before_req` of the previous page) and
  `--page-size`. `--blocked` and `--mocked` show only requests your rules stopped or answered.
- `network-request` shows one request: headers, redirects and the recorded response body. `--body` prints up to
  64 KiB per call (`--offset` for the next piece). A binary body needs `--out`.
- `network-request --surface <id> --req <n> --out <file>` writes the whole body to a **new** file in the temp
  folder only (`$TMPDIR` or `/tmp`) — the current folder is refused, and so is a name that already exists. Use a
  fresh name such as `"$TMPDIR/maru-body-1.json"`; see section 4 of SKILL.md.

## Recording response bodies

```sh
maru browser network-record --surface 12 --on
maru browser network-record --surface 12 --off
```

Bodies are recorded only while it is on. The tab title shows ◉. Turn it off when done.

## Blocking and mocking

```sh
maru browser network-block --surface 12 --add "https://ads.example.com/*"
maru browser network-block --surface 12 --list
maru browser network-mock --surface 12 --add "https://api.example.com/v1/user" --status 200 --content-type application/json --body '{"name":"Test"}'
```

- Patterns are `scheme://host[:port]/path` with `*` wildcards. A rule applies on the site where you added it.
- `--list`, `--remove <pattern>`, `--rule <n>` and `--clear` manage rules. At most 32 rules per tab, across all
  panes; at most 10 changes a second. `--list` shows another pane's rules too (`[set by another pane]`), and
  `--remove`, `--rule`, `--clear` and `--strict` change them too (an older Maru: only your own) — the pane that
  changes something owns it. `--clear` removes every rule on the tab; to remove only yours, use `--rule <n>`.
- A site's service worker can answer requests before your rules see them; `--strict on` makes the tab bypass
  that site's service worker (not shared workers).
- Service and shared workers never see mocks. Mocked pages and scripts run as that site.
- Mocks also answer pages the user opens with a link or form on a user's tab (an older Maru leaves those real);
  pages the user types or reaches with back, forward or reload stay real.
- The tab title shows ⊘ while blocking and ▣ while mocking. **Remove your rules when done** — `--rule <n>` for
  yours, or `--clear` when no other pane uses the tab.
