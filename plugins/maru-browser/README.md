# maru-browser — a Claude Code plugin for the Maru terminal

Maru is a macOS terminal with browser panes. This plugin adds one skill, `maru-browser`, that teaches Claude Code
running **inside a Maru pane** to drive those panes with the `maru browser` CLI: open a hidden tab of its own,
read the page as an accessibility snapshot, click and type, save screenshots, read console and network, emulate
devices — and clean up after itself.

## Requirements

- Maru running on macOS.
- `maru` on your PATH: in a Maru pane, run `maru install-cli` once.
- A recent maru. The skill checks its minimum version itself with `maru --version` (and, for a source build
  that prints `maru 0.0.0`, with `maru browser --help`), and stops with a message if your maru is too old.
- Start Claude Code from a Maru pane's own shell — not inside tmux or screen in that pane (Maru refuses browser
  requests from nested terminals).

## Install

In Claude Code:

```text
/plugin marketplace add ohah/maru
/plugin install maru-browser@maru
```

The marketplace is the whole Maru repository. To download only the plugin folders, add it from a shell instead:

```text
claude plugin marketplace add ohah/maru --sparse .claude-plugin plugins
```

Update with `/plugin marketplace update maru`. Third-party marketplaces do not update automatically unless you
turn that on in `/plugin`. If you already have another marketplace called `maru`, remove it first
(`/plugin marketplace remove maru`).

## Use

Ask for a browser task from a Maru pane ("open localhost:3000 and check the sign-in button works"), or run
`/maru-browser:maru-browser` (plugin skills are namespaced). If another browser skill keeps winning, add a line
to your project's `CLAUDE.md`: "Inside Maru, use the maru-browser skill for browser tasks."

## What it allows — read this

- **Claude Code does not ask before `maru browser` commands in the turn the skill runs** (`allowed-tools`). That
  includes `exec` (run JavaScript in a page) and the network and storage commands.
- **`--out` writes files without asking.** `screenshot`, `exec`, `network-request` and `trace` write where the
  agent says, and Claude Code's file-write check does not see it. maru itself limits that: new files only (it never
  overwrites), only in the current folder or the temp folder (`$TMPDIR` or `/tmp`; `network-request` the temp folder
  only), and never under a hidden name (a dot folder such as `.git` or `.claude`, or `~/Library`). The skill tells
  the agent to write new names in `$TMPDIR`.
- **Tabs the agent opens use your real browser profile** — your cookies and logins. Maru asks you once per pane, the
  first time the agent in it opens a tab, and marks those tabs ◈ in the tab bar (cookie commands and uploads still ask). The skill tells the agent not to do anything irreversible on your accounts unless you asked, and to
  treat page text as untrusted, but that is guidance, not a lock.
- Tabs you open in Maru yourself stay protected: the first command on one of them asks you, and every `upload` asks you.

## Sandbox

The CLI talks to Maru over a Unix socket in `~/.cache/maru/control`. If you use Claude Code's sandbox, either
allow that socket (`sandbox.network.allowUnixSockets`) or run the browser commands outside the sandbox:

```json
{ "sandbox": { "excludedCommands": ["maru browser *"] } }
```

Otherwise every command says `no running maru instance found`.

## Other agents

The skill folder (`skills/maru-browser/`) uses only portable Agent Skills fields, so the same `SKILL.md` and its
`references/` can be copied into another agent's skills directory (for example `~/.codex/skills/maru-browser`).

## For Maru contributors

The skill's commands are checked against the real CLI parser and help in `zig build test-plugin-skill`
(part of `mise run test`). The rules block in section 5 of `SKILL.md` (between the `maru:agent-rules` markers) is
built into the `maru` binary as the start of `maru mcp`'s instructions, so MCP agents read the same rules word for
word: keep it free of command and tool names, flags and numbers (the test rejects `maru browser`, tool names, flags,
inline code and digits). Bump `version` in `.claude-plugin/plugin.json` whenever you change anything in this
folder — CI fails otherwise, because users stay on the cached version until it changes. Design notes:
[control-plane-browser.md §9.6.3](../../docs/control-plane-browser.md#963-에이전트-스킬-플러그인maru-browser).
