#!/usr/bin/env python3
"""에이전트 턴의 도구 구성을 provider 트랜스크립트에서 잰다 — AT3b 의 수치 근거.

훅 로그(`~/.cache/maru/agent-turn-events/*.ndjson`)는 **큐**라 소비 즉시 지워진다(agent.zig
`cleanupAgentHookLogs`·`rotateAgentHookLog`). 그래서 수치를 다시 잴 때는 여기서처럼 **트랜스크립트**를
읽는다 — Claude 는 `~/.claude/projects/**/*.jsonl`, Codex 는 `~/.codex/sessions/**/*.jsonl`.

    tools/agent-turn-tool-mix.py            # 둘 다
    tools/agent-turn-tool-mix.py claude     # 한쪽만
    tools/agent-turn-tool-mix.py claude maru5   # 프로젝트 경로 문자열로 거른다

셸 편집 판별은 **측정 도구일 뿐 제품 설계가 아니다**(계획 AT3b — 제품은 명령 문자열을 파싱하지 않는다).
세 등급을 함께 낸다: 느슨(mkdir·rm 포함) / 엄격(내용 변경만) / 저장소(임시 디렉터리 대상 제외).
"""
import collections
import glob
import json
import os
import re
import sys

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
CAPTURE_TOOLS = EDIT_TOOLS | {"Read"}  # PreToolUse 가 file_path 를 싣는 도구
SHELL_TOOLS = {"Bash", "PowerShell"}
TMP = r"/private/tmp|/tmp|\$SP\b|\"\$SP|\$CLAUDE_JOB_DIR|\"\$CLAUDE|\$SCRATCH"

CONTENT = [  # 내용을 바꾸는 것
    (r"\bsed\s+(-[a-zA-Z]*i|--in-place)", "sed -i"),
    (r"\bperl\s+-[a-zA-Z]*i", "perl -i"),
    (r"open\([^)]*['\"][wa]", "py open(w)"),
    (r"\btee\b", "tee"),
    (r"\bmv\s", "mv"),
    (r"\bcp\s", "cp"),
    (r"\bgit\s+(apply|checkout\s+--|checkout\s+[^-]|stash|restore|reset\s+--hard|revert|cherry-pick|merge|rebase|pull|clean|worktree)", "git write"),
    (r"\bpatch\b", "patch"),
    (r"\bzig\s+fmt\b(?!.*--check)", "zig fmt"),
]
LOOSE_EXTRA = [(r"\brm\s", "rm"), (r"\bmkdir\b", "mkdir"), (r"\btouch\b", "touch"), (r"\bchmod\b", "chmod"),
               (r"\bln\s", "ln"), (r"\b(bun|npm|pnpm|yarn)\s+(install|add|i)\b", "pkg install")]
REDIRECT_ANY = (r"(?:^|[\s\d])>{1,2}\s*(?!/dev/null|&)[\"']?[~./A-Za-z_$]", "redirect >")
REDIRECT_REPO = (r"(?:^|[\s\d])>{1,2}\s*(?!/dev/null|&|" + TMP + r")[\"']?[~./A-Za-z_$]", "redirect >")
HEREDOC_ANY = (r"\bcat\s*>{1,2}", "cat >")
HEREDOC_REPO = (r"\bcat\s*>{1,2}\s*(?!" + TMP + r")", "cat >")
TIERS = {
    "loose": CONTENT + LOOSE_EXTRA + [REDIRECT_ANY, HEREDOC_ANY],
    "strict": CONTENT + [REDIRECT_ANY, HEREDOC_ANY],
    "repo": CONTENT + [REDIRECT_REPO, HEREDOC_REPO],
}
TIERS = {k: [(re.compile(p, re.M), n) for p, n in v] for k, v in TIERS.items()}

HEREDOC_BODY = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?\n.*?\n\1\s*$", re.S | re.M)
SELF_BG = re.compile(r"(?<![<>&|])\s&\s*(?:$|;|\n)", re.M)  # 종결자 위치의 `&` 만(리다이렉트·`&&` 제외)
SELF_BG_WORDS = re.compile(r"\b(disown|setsid|coproc|screen\s+-d|tmux\s+new[^\n]*-d|launchctl\s+load|systemctl\s+start)\b")


def self_backgrounds(cmd):
    body = HEREDOC_BODY.sub("<<HEREDOC>>", cmd)  # heredoc 안의 코드(`&self` 등)를 세지 않는다
    return bool(SELF_BG.search(body) or SELF_BG_WORDS.search(body))


class Tally:
    def __init__(self):
        self.tools = collections.Counter()
        self.with_path = collections.Counter()
        self.turns = 0
        self.turns_tool = 0
        self.no_capture = 0
        self.edit_tool = 0
        self.shell_only = 0
        self.shell_write_only = {k: 0 for k in TIERS}
        self.shell_write_and_edit = {k: 0 for k in TIERS}
        self.bash = 0
        self.bg_flag = 0
        self.self_bg = 0
        self.both_bg = 0
        self.monitor = 0
        self.write_kinds = {k: collections.Counter() for k in TIERS}
        self.bash_write = {k: 0 for k in TIERS}
        self.modes = collections.Counter()

    def shell(self, cmd, bg_flag, turn):
        self.bash += 1
        sb = self_backgrounds(cmd)
        self.bg_flag += bg_flag
        self.self_bg += sb
        self.both_bg += bg_flag and sb
        for tier, pats in TIERS.items():
            kinds = {n for r, n in pats if r.search(cmd)}
            if kinds:
                self.bash_write[tier] += 1
                self.write_kinds[tier].update(kinds)
                if turn is not None:
                    turn["sw"].add(tier)

    def close(self, turn):
        if turn is None:
            return
        self.turns += 1
        if not turn["tools"]:
            return
        self.turns_tool += 1
        self.modes[turn["mode"]] += 1
        names = set(turn["tools"])
        has_edit = bool(names & turn["edit_tools"])
        if not names & turn["capture_tools"]:
            self.no_capture += 1
        if has_edit:
            self.edit_tool += 1
        if names <= turn["shell_tools"]:
            self.shell_only += 1
        for tier in turn["sw"]:
            if has_edit:
                self.shell_write_and_edit[tier] += 1
            else:
                self.shell_write_only[tier] += 1

    def report(self, label):
        total = sum(self.tools.values())
        print(f"== {label}: tool_use {total}건 · 턴 {self.turns} · 도구 쓴 턴 {self.turns_tool}")
        for n, c in self.tools.most_common(12):
            print(f"  {n:24s} {c:7d} {100 * c / total:5.1f}%   file_path {self.with_path[n]}")
        wp = sum(self.with_path.values())
        print(f"  file_path 실린 호출 {wp} ({100 * wp / total:.1f}%)")
        tt = max(self.turns_tool, 1)
        print(f"  캡처 트리거 없는 턴 {self.no_capture} ({100 * self.no_capture / tt:.1f}%) · 편집 도구 턴 {self.edit_tool} ({100 * self.edit_tool / tt:.1f}%) · 셸만 {self.shell_only} ({100 * self.shell_only / tt:.1f}%)")
        for tier in TIERS:
            a, b = self.shell_write_only[tier], self.shell_write_and_edit[tier]
            print(f"  [{tier:6s}] 셸 쓰기 O·편집 도구 X {a} ({100 * a / tt:.1f}%) · 둘 다 {b} ({100 * b / tt:.1f}%) · 쓰기 셸 호출 {self.bash_write[tier]}: "
                  + " ".join(f"{k}={v}" for k, v in self.write_kinds[tier].most_common(6)))
        b = max(self.bash, 1)
        union = self.bg_flag + self.self_bg - self.both_bg + self.monitor
        print(f"  셸 {self.bash}: run_in_background {self.bg_flag} ({100 * self.bg_flag / b:.1f}%) · 스스로 배경화 {self.self_bg} ({100 * self.self_bg / b:.1f}%) · ∩ {self.both_bg} · Monitor {self.monitor} → 합집합 {union} ({100 * union / (b + self.monitor):.1f}%)")
        if self.modes:
            print("  permissionMode: " + ", ".join(f"{m}={c}" for m, c in self.modes.most_common()))


def claude(paths):
    t = Tally()
    for path in paths:
        turn = None
        mode = "?"
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                kind = d.get("type")
                if kind == "user":
                    c = d.get("message", {}).get("content")
                    is_result = isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c)
                    if not is_result and not d.get("isMeta") and not d.get("isSidechain"):
                        t.close(turn)
                        mode = d.get("permissionMode", mode)
                        turn = {"tools": [], "sw": set(), "mode": mode, "edit_tools": EDIT_TOOLS,
                                "capture_tools": CAPTURE_TOOLS, "shell_tools": SHELL_TOOLS}
                    continue
                if kind != "assistant":
                    continue
                for b in d.get("message", {}).get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    name = b.get("name", "?")
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    t.tools[name] += 1
                    if inp.get("file_path"):
                        t.with_path[name] += 1
                    if name == "Monitor":
                        t.monitor += 1
                    if name in SHELL_TOOLS:
                        t.shell(inp.get("command") or "", inp.get("run_in_background") is True, turn)
                    if turn is not None and not d.get("isSidechain"):
                        turn["tools"].append(name)
        t.close(turn)
    t.report(f"Claude ({len(paths)} 파일)")


CODEX_SHELL = {"exec_command", "shell"}
CODEX_EDIT = {"apply_patch"}


def codex(paths):
    t = Tally()
    for path in paths:
        turn = None
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                pl = d.get("payload") or {}
                if d.get("type") == "event_msg" and pl.get("type") == "user_message":
                    t.close(turn)
                    turn = {"tools": [], "sw": set(), "mode": "codex", "edit_tools": CODEX_EDIT,
                            "capture_tools": CODEX_EDIT, "shell_tools": CODEX_SHELL | {"write_stdin"}}
                    continue
                if d.get("type") != "response_item" or pl.get("type") not in ("function_call", "custom_tool_call"):
                    continue
                name = pl.get("name", "?")
                t.tools[name] += 1
                if name in CODEX_EDIT:
                    t.with_path[name] += 1  # 경로는 패치 텍스트 안에 있다(계약 §2.1)
                if name in CODEX_SHELL:
                    try:
                        a = json.loads(pl.get("arguments") or "{}")
                    except Exception:
                        a = {}
                    cmd = a.get("cmd") or a.get("command") or ""
                    if isinstance(cmd, list):
                        cmd = " ".join(map(str, cmd))
                    t.shell(str(cmd), False, turn)
                if turn is not None:
                    turn["tools"].append(name)
        t.close(turn)
    t.report(f"Codex ({len(paths)} 파일)")


def main(argv):
    which = argv[1] if len(argv) > 1 else "both"
    needle = argv[2] if len(argv) > 2 else ""
    if which in ("both", "claude"):
        ps = sorted(p for p in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
                    if os.path.getsize(p) > 20_000 and needle in p)
        claude(ps)
    if which in ("both", "codex"):
        ps = sorted(p for p in glob.glob(os.path.expanduser("~/.codex/sessions/**/*.jsonl"), recursive=True)
                    if os.path.getsize(p) > 20_000 and needle in p)
        codex(ps)


if __name__ == "__main__":
    main(sys.argv)
