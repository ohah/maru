# Errors and what to do

`maru browser` prints a failure as one line, `error: <message> (<code>)`, sometimes followed by a `hint:` line,
and exits 1. A parse error and "no instance" both exit 1 too — always read the text.

**Never loop.** If the same call fails twice the same way, stop and tell the user what you saw.

## Before the request reaches Maru

| You see | Meaning | Do |
|---|---|---|
| `command not found` for `maru` | maru is not on PATH | Ask the user to run `maru install-cli` in a Maru pane. Stop. |
| `unknown subcommand 'x'` then a `commands (…):` line, or `unknown option '--x'` or `too many arguments: 'x' was not expected` then that command's help lines | A typo, or a command or flag your maru does not have. The message names the word; a hidden character in it shows as `<U+200B>` (often from copied text) — type the flag again by hand. | Read the lines printed under it (or that command's `--help`, like `maru browser click --help`). If what you wanted is not there, do not use it; tell the user their maru is older. |
| `option '--x' needs a value` (older maru: `the option needs a value`) | The flag at the end of the line has no value after it | Put the value right after that flag — quote it if it has spaces. |
| `screenshot: needs --out <file> …` | A screenshot without `--out` (maru never prints PNG bytes) | Add `--out "$TMPDIR/<new name>.png"`. |
| `no running maru instance found.` | Maru is not running, its socket is stale, or a sandbox blocks the socket in `~/.cache/maru/control` | Stop and tell the user. Mention the sandbox if Maru is clearly running. |
| `… (multiple maru instances found; selecting one is not supported yet).` | Two Maru apps (for example a dev build and the installed one), or a dead one's socket | Ask the user to quit one. |
| `… cannot write the output file: something already exists there …` | `--out` names a file that exists; maru never overwrites | Use a new name. Do not delete the old file. |
| `… cannot write the output file: …` with `$TMPDIR` in it | `--out` is outside the current folder or the temp folder, under a hidden part (a dot name, `~/Library`), in a folder that does not exist, or `network-request` outside the temp folder | Write a new name straight into `$TMPDIR` — or `/tmp` if `$TMPDIR` is refused too. Do not work around it. |
| `request too large: …` | One request is over 1 MiB (a very long `type` text or `exec` expression) | Send it in smaller pieces. |

## Refusals and permissions (`-32002`)

| You see | Meaning | Do |
|---|---|---|
| `error: Unauthorized (-32002)` with `hint: maru does not say why it refused …` | The request did not come from a Maru pane (another terminal, screen or ssh inside the pane, a background `&` job, a program outside Maru), **or** the id is closed or unknown. An older Maru also refuses tmux inside the pane and tabs the user declined. Maru does not say which, on purpose. | Do not repeat. Run `maru browser list` to check the id. If you are outside a Maru pane, say so. Otherwise ask the user. |
| `-32603` with a hint that only tabs this pane opened can be closed | An older Maru: `close` on a tab you did not open | Leave the user's tab open. |
| `-32002` saying the tab needs its network permission first | An older Maru: `network-record`, `network-block` or `network-mock` before `network` was allowed on that tab (it may also print the foreground hint under it — ignore that there) | Run `network` on that tab first. |
| `-32002` saying a permission is gone, or that something works only on tabs the agent opened | The user revoked the tab in the Browser Grants menu (what you set there is gone), or the command needs a tab you opened | Do not retry in a loop. Ask the user, or `open` a tab of your own. |
| `(-32603)` with `grants_full` | Maru keeps access for at most 64 pane-and-tab pairs | Close tabs you opened and no longer need; for the user's tabs, ask the user to close them or to choose Revoke All in the Browser Grants menu. Then retry once. |
| `error: the user declined the upload — nothing was uploaded (-32002)` | An older Maru: the user said no | Do not retry. Ask what they want. |
| `error: the user declined browser tabs for this pane … (-32002)` from `open` | An older Maru: the user said no to tabs that use their logged-in sites | Do not retry. Tell the user what you needed the browser for. |
| `error: maru closed the connection without answering …` | Too many connections, Maru quit, or (an older Maru) no answer to a dialog in time | Ask the user whether Maru is still running. Retry at most once. |

## While running

| You see | Meaning | Do |
|---|---|---|
| `(-32003)` | The tab went away after you were allowed | Run `maru browser list` again. |
| `(-32004)` from `open` saying the user did not answer | An older Maru: the first-open dialog got no answer; nothing was opened | Tell the user, then run `open` once more when they are there. |
| `(-32004)` from `wait`, maybe with `hint: N matching element(s) are hidden` | The condition did not come true in time (at most 25 s) | Take a snapshot, then fix the condition or the locator. |
| `(-32004)` from `click`, `type`, `press`, `hover` or `exec` | The page did not answer in time — the input or script **may already have run** | Do not repeat it. Take a snapshot and check what happened first. |
| `(-32005)` | An `exec` result is over the limit | Return less, or use `--out` or `--max-result-bytes`. |
| `(-32006)` with `script error (kind): name: message` | Your `exec` expression threw | Fix the expression. |
| `(-32008)` with `[not a browser tab]`, `[engine=webkit]` or `[param=…]` | A file view or markdown panel, a WebKit tab, or a flag that engine lacks; `trace` on a tab you did not open in an older Maru | Use a Chromium tab of your own (`open`). |
| `(-32602)` with a `reason` | A bad value (for example `too_many_rules`, `no_site`, `unknown_rule`, an `emulate` value) | Fix the value. |
| `(-32603)` with `emulated_by_other_pane`, `resource_busy` or `trace_busy` | An older Maru: another pane owns that tab's emulation; or more than 10 changes a second, or another trace is running | Wait a little and retry once, or ask. |
| `(-32603)` with `human_input` | The user used the tab | Stop and ask. Do not fight the user. |
| `(-32601)` | The app is older than this CLI | Ask the user to restart or update Maru. |

## Successes that need care

| You see | Meaning | Do |
|---|---|---|
| `ok` then `warning: the page opened a dialog right after the input …` | The input landed and the page opened a dialog | Do not repeat the input. Run `dialog`, then `handle-dialog` if you may, or let the user answer. |
| `opened 42 …` then `warning: the page did not finish loading in time …` | `open` waited 25 s | Run `maru browser wait --surface 42 --load` before acting. |
| `opened 42 …` or `ok` (from `navigate`), then a line with `[error page: ERR_…]` — `blocked: request-blocking rule N stopped this navigation [error page: …] — …` when a blocking rule stopped a `navigate`, otherwise `warning: [error page: ERR_…] — the navigation failed …` | The address did not load: Chromium shows its error page (blocked, refused, no DNS, an HTTP error with no body). Look for `[error page:` — it is on whichever of those two lines appears. It is not slow — waiting for the load will not help | Fix the cause or use another address. An older Maru prints no warning after `opened` here (it said the error page loaded). |
| `not closed: …` (exit 1) | The page asks before leaving | See [dialogs-and-uploads.md](dialogs-and-uploads.md). |
| `not ok` from `back` | There is nothing to go back to | Use `navigate`. |
| `get-url` prints an address then `note: error page (ERR_NAME_NOT_RESOLVED) — …`; `list` ends a line with `[error page: …]` | The tab shows Chromium's error page: the navigation failed (blocked — `ERR_BLOCKED_BY_CLIENT` or `blocking rule N` —, refused, no DNS, an HTTP error with no body — `ERR_HTTP_RESPONSE_CODE_FAILURE`). No page is loaded; cookie and storage commands fail there | Do not read or click as if the page loaded. Fix the cause (`network-block --list --surface 42` for a blocked one) or `navigate` elsewhere. A 404 or 500 page that has a body is the server's page, not an error page — no note; check the page text. |
