# Network

Chromium tabs only. Check the exact flags in `maru browser --help`.

## Permissions come in layers

- On your tabs (`open`) nothing asks.
- On a user's tab, `network` asks once per site. `network-record`, `network-block` and `network-mock` need that
  network permission first (an error says so — run `network` on that tab), and `network-mock` also needs control
  of the tab. Each asks once per site.
- You see requests made after the permission (on your tabs: since the tab was created, unless the user used it
  before your first read).
- `Cookie`, `Set-Cookie` and `Authorization` values show only for sites whose cookie permission you also hold on
  that tab, and never when the user turned full network detail off. Request bodies are not recorded.

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
  panes; at most 10 changes a second.
- A site's service worker can answer requests before your rules see them; `--strict on` makes the tab bypass
  that site's service worker (not shared workers).
- Service and shared workers never see mocks. Mocked pages and scripts run as that site.
- The tab title shows ⊘ while blocking and ▣ while mocking. **Remove your rules when done** — `--clear`.
