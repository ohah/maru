# Errors and what to do

`maru browser` prints a failure as one line, `error: <message> (<code>)`, sometimes followed by a `hint:` line,
and exits 1. A parse error and "no instance" both exit 1 too — always read the text.

**Never loop.** If the same call fails twice the same way, stop and tell the user what you saw.

## Before the request reaches Maru

| You see | Meaning | Do |
|---|---|---|
| `command not found` for `maru` | maru is not on PATH | Ask the user to run `maru install-cli` in a Maru pane. Stop. |
| `unknown subcommand 'x'` then a `commands (…):` line, or `unknown option '--x'` or `too many arguments: 'x' was not expected` then that command's help lines | A typo, or a command or flag your maru does not have. The message names the word. | Read the lines printed under it (or that command's `--help`, like `maru browser click --help`). If what you wanted is not there, do not use it; tell the user their maru is older. |
| `screenshot: needs --out <file> …` | A screenshot without `--out` (maru never prints PNG bytes) | Add `--out "$TMPDIR/<new name>.png"`. |
| `no running maru instance found.` | Maru is not running, its socket is stale, or a sandbox blocks the socket in `~/.cache/maru/control` | Stop and tell the user. Mention the sandbox if Maru is clearly running. |
| `… (multiple maru instances found; selecting one is not supported yet).` | Two Maru apps (for example a dev build and the installed one), or a dead one's socket | Ask the user to quit one. |
| `… cannot write the output file: something already exists there …` | `--out` names a file that exists; maru never overwrites | Use a new name. Do not delete the old file. |
| `… cannot write the output file: …` with `$TMPDIR` in it | `--out` is outside the current folder or the temp folder, under a hidden part (a dot name, `~/Library`), in a folder that does not exist, or `network-request` outside the temp folder | Write a new name straight into `$TMPDIR` — or `/tmp` if `$TMPDIR` is refused too. Do not work around it. |
| `request too large: …` | One request is over 1 MiB (a very long `type` text or `exec` expression) | Send it in smaller pieces. |

## Refusals and permissions (`-32002`)

| You see | Meaning | Do |
|---|---|---|
| `error: Unauthorized (-32002)` with `hint: maru does not say why it refused …` | The request did not come from the Maru pane's foreground job (another terminal, tmux or screen inside the pane, a background `&` job), **or** the tab lacks a permission the command needs (the user declined the dialog, or a command that never asks — `network-block` or `network-mock` with `--list`, `--remove` or `--clear`, `emulate` with `--get` or `--clear`, `network-record` with `--off` — before you held that permission), **or** the id is closed or unknown. Maru does not say which, on purpose. | Do not repeat. Run `maru browser list` to check the id. If you are inside tmux/screen, say so. If it was one of the commands that never ask, there is nothing of yours to list or clear there. Otherwise ask the user. |
| `-32002` with a hint that only tabs this pane opened can be closed | `close` on a tab you did not open | Leave the user's tab open. |
| `-32002` saying the tab needs its network permission first | `network-record`, `network-block` or `network-mock` before `network` was allowed on that tab (an older maru also prints the foreground hint under it — ignore that there) | Run `network` on that tab first. |
| `-32002` saying a permission is gone, or that something works only on tabs the agent opened | The user took the permission back, or the command needs your own tab | Do not retry in a loop. Ask the user, or `open` a tab of your own. |
| `error: the user declined the upload — nothing was uploaded (-32002)` | The user said no | Do not retry. Ask what they want. |
| `error: maru closed the connection without answering …` | No answer to a dialog in time (about 2 minutes), too many connections, or Maru quit | Ask the user whether a dialog showed up. Retry at most once. |

## While running

| You see | Meaning | Do |
|---|---|---|
| `(-32003)` | The tab went away after you were allowed | Run `maru browser list` again. |
| `(-32004)` from `wait`, maybe with `hint: N matching element(s) are hidden` | The condition did not come true in time (at most 25 s) | Take a snapshot, then fix the condition or the locator. |
| `(-32004)` from `click`, `type`, `press`, `hover` or `exec` | The page did not answer in time — the input or script **may already have run** | Do not repeat it. Take a snapshot and check what happened first. |
| `(-32005)` | An `exec` result is over the limit | Return less, or use `--out` or `--max-result-bytes`. |
| `(-32006)` with `script error (kind): name: message` | Your `exec` expression threw | Fix the expression. |
| `(-32008)` with `[not a browser tab]`, `[engine=webkit]` or `[param=…]` | A file view or markdown panel, a WebKit tab, or a flag that engine lacks; `trace` on a user's tab | Use a Chromium tab of your own (`open`). |
| `(-32602)` with a `reason` | A bad value (for example `too_many_rules`, `no_site`, `unknown_rule`, an `emulate` value) | Fix the value. |
| `(-32603)` with `emulated_by_other_pane`, `resource_busy` or `trace_busy` | Another pane owns that tab's emulation, more than 10 changes a second, or another trace is running | Wait a little and retry once, or ask. |
| `(-32603)` with `human_input` | The user used the tab | Stop and ask. Do not fight the user. |
| `(-32601)` | The app is older than this CLI | Ask the user to restart or update Maru. |

## Successes that need care

| You see | Meaning | Do |
|---|---|---|
| `ok` then `warning: the page opened a dialog right after the input …` | The input landed and the page opened a dialog | Do not repeat the input. Run `dialog`, then `handle-dialog` if you may, or let the user answer. |
| `opened 42 …` then `warning: the page did not finish loading in time …` | `open` waited 25 s | Run `maru browser wait --surface 42 --load` before acting. |
| `not closed: …` (exit 1) | The page asks before leaving | See [dialogs-and-uploads.md](dialogs-and-uploads.md). |
| `not ok` from `back` | There is nothing to go back to | Use `navigate`. |
