# Errors and what to do

`maru browser` prints a failure as one line, `error: <message> (<code>)`, sometimes followed by a `hint:` line,
and exits 1. A parse error and "no instance" both exit 1 too — always read the text.

**Never loop.** If the same call fails twice the same way, stop and tell the user what you saw.

## Before the request reaches Maru

| You see | Meaning | Do |
|---|---|---|
| `command not found` for `maru` | maru is not on PATH | Ask the user to run `maru install-cli` in a Maru pane. Stop. |
| `unknown subcommand` or `unknown option`, then the whole help | A typo, or an older maru without that command or flag. The message does not name the option. | Check your `maru browser --help`. If it is not there, do not use it; tell the user their maru is older. |
| `no running maru instance found.` | Maru is not running, its socket is stale, or a sandbox blocks the socket in `~/.cache/maru/control` | Stop and tell the user. Mention the sandbox if Maru is clearly running. |
| `… (multiple maru instances found; selecting one is not supported yet).` | Two Maru apps (for example a dev build and the installed one), or a dead one's socket | Ask the user to quit one. |
| `request too large: …` | One request is over 1 MiB (a very long `type` text or `exec` expression) | Send it in smaller pieces. |

## Refusals and permissions (`-32002`)

| You see | Meaning | Do |
|---|---|---|
| `error: Unauthorized (-32002)` with a `hint:` about the pane's foreground job | The request did not come from the Maru pane's foreground job (another terminal, tmux or screen inside the pane, a background `&` job), **or** the user declined the dialog, **or** the id is closed or unknown. Maru does not say which, on purpose. | Do not repeat. Run `maru browser list` to check the id. If you are inside tmux/screen, say so. Otherwise ask the user. |
| `-32002` with a hint that only tabs this pane opened can be closed | `close` on a tab you did not open | Leave the user's tab open. |
| `-32002` saying the tab needs its network permission first | `network-record`, `network-block` or `network-mock` before `network` was allowed on that tab (the foreground hint under it does not apply) | Run `network` on that tab first. |
| `error: the user declined the upload — nothing was uploaded (-32002)` | The user said no | Do not retry. Ask what they want. |
| `error: maru closed the connection without answering …` | No answer to a dialog in time (about 2 minutes), too many connections, or Maru quit | Ask the user whether a dialog showed up. Retry at most once. |

## While running

| You see | Meaning | Do |
|---|---|---|
| `(-32003)` | The tab went away after you were allowed | Run `maru browser list` again. |
| `(-32004)`, maybe with `hint: N matching element(s) are hidden` | `wait` timed out (at most 25 s) | Take a snapshot, then fix the condition or the locator. |
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
