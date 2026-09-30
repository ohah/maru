#!/usr/bin/env python3
"""main CI 가 빨개지면 이슈 하나로 알리고, 실패했던 잡이 다시 **성공**하면 닫는다.

**왜 필요한가.** main push 에서만 도는 잡(`session host macOS (Debug)` 등)은 PR 에서 돌지 않아 머지를 막지
못한다. 2026-09-27 ~ 09-30 main push 51 번 중 22 번(43%)이 그 잡에서 빨갰는데, 전부 결정적 결함 하나씩이
만든 **연속 구간**이었다(8 · 17 · 5 연속, 가장 긴 것은 약 22시간). 아무도 제때 알지 못했다.

**무엇을 하나.** CI 가 main 에서 끝날 때마다(`workflow_run`):
  - 실패한 잡이 있으면 — 열린 이슈가 없으면 연다, 있으면 댓글을 단다. 실패한 테스트 이름(로그의
    `...FAIL` / `FAIL (…)` 위 가장 가까운 테스트)과 커밋·실행 링크를 적는다.
  - 실패했던 잡이 이번 실행에서 **성공**하면 목록에서 뺀다. 목록이 비면 이슈를 닫는다.
    **건너뛴(skipped) 잡은 회복으로 치지 않는다** — 문서만 바꾼 push 는 session host 잡을 건너뛰어
    CI 전체가 초록이 되는데, 그때 닫으면 아직 빨간 main 을 초록으로 알린다.

이슈 본문 끝의 `<!-- main-health failing: … -->` 한 줄이 상태다(실패 중인 잡 이름들).

`--dry-run` 이면 GitHub 을 바꾸지 않고 할 일만 출력한다 — 과거 실행 id 로 로컬에서 시험할 수 있다.
"""

import argparse
import json
import os
import re
import subprocess
import sys

MARKER = "main-health"
LABEL = "ci"
STATE_RE = re.compile(r"<!-- main-health failing: (.*?) -->")
MAX_TESTS_PER_JOB = 8


def gh(*args, check=True):
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        sys.stderr.write(out.stderr)
        raise SystemExit(f"gh {' '.join(args[:3])} … 실패")
    return out.stdout


def jobs_of(repo, run_id):
    raw = gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")
    return json.loads(raw)["jobs"]


def failing_tests(repo, job_id):
    """실패 로그에서 실패한 테스트 이름을 뽑는다 — `FAIL` 줄 위로 가장 가까운 테스트 줄."""
    log = subprocess.run(
        ["gh", "run", "view", "--repo", repo, "--job", str(job_id), "--log-failed"],
        capture_output=True, text=True,
    ).stdout
    lines = [re.sub(r"^.*?\dZ ", "", l, count=1) for l in log.split("\n")]
    names = []
    for i, line in enumerate(lines):
        if not re.search(r"FAIL \(|\.\.\.FAIL|\.\.\.expected ", line):
            continue
        for k in range(i, max(-1, i - 60), -1):
            m = re.search(r"\d+/\d+ ([A-Za-z_0-9.]+\.test\.[^\n]*?)\.\.\.", lines[k])
            if m and not re.search(r"\.\.\.(OK|SKIP|FILTERED)\s*$", lines[k]):
                name = re.sub(r"\s+", " ", m.group(1))[:160]
                if name not in names:
                    names.append(name)
                break
        if len(names) >= MAX_TESTS_PER_JOB:
            break
    return names


def open_issue(repo):
    raw = gh("issue", "list", "--repo", repo, "--state", "open", "--label", LABEL,
             "--search", f"{MARKER} in:body", "--json", "number,body", "--limit", "5")
    for issue in json.loads(raw):
        m = STATE_RE.search(issue["body"])
        if m:
            failing = [n for n in m.group(1).split("|") if n]
            return issue["number"], issue["body"], failing
    return None, None, []


def with_state(body, failing):
    line = f"<!-- {MARKER} failing: {'|'.join(sorted(failing))} -->"
    return STATE_RE.sub(line, body) if STATE_RE.search(body) else body.rstrip() + "\n\n" + line + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    repo = os.environ["REPO"]

    run = json.loads(gh("api", f"repos/{repo}/actions/runs/{a.run_id}"))
    sha, url = run["head_sha"], run["html_url"]
    title = run.get("display_title") or ""
    jobs = jobs_of(repo, a.run_id)
    failed = [j for j in jobs if j["conclusion"] == "failure"]
    succeeded = {j["name"] for j in jobs if j["conclusion"] == "success"}

    number, body, tracked = open_issue(repo)
    head = f"`{sha[:9]}` {title} — [실행]({url})"

    def act(desc, *gh_args, show=None):
        print(f"[{'dry-run' if a.dry_run else 'apply'}] {desc}")
        if show:
            print(show)
        if not a.dry_run:
            gh(*gh_args)

    if failed:
        parts = []
        for j in failed:
            tests = failing_tests(repo, j["id"])
            parts.append(f"- **{j['name']}** — [로그]({j['html_url']})")
            parts += [f"  - `{t}`" for t in tests] or ["  - (실패한 테스트 줄을 못 찾았다 — 로그를 본다)"]
        report = f"main 에서 잡이 실패했다: {head}\n\n" + "\n".join(parts)
        now_failing = sorted(set(tracked) | {j["name"] for j in failed})
        if number is None:
            new_body = with_state(
                report + "\n\n실패했던 잡이 다시 **성공**하면 이 이슈는 자동으로 닫힌다"
                " (건너뛴 잡은 회복으로 치지 않는다 — `tools/ci/main_health.py`).", now_failing)
            act(f"새 이슈 — 실패 {now_failing}", "issue", "create", "--repo", repo, "--label", LABEL,
                "--title", f"main CI 가 빨갛다: {', '.join(j['name'] for j in failed)}",
                "--body", new_body, show=new_body)
        else:
            act(f"#{number} 댓글", "issue", "comment", str(number), "--repo", repo, "--body", report, show=report)
            if now_failing != sorted(tracked):
                act(f"#{number} 추적 잡 → {now_failing}", "issue", "edit", str(number), "--repo", repo,
                    "--body", with_state(body, now_failing))
        return

    if number is None:
        print("할 일 없음 — 실패한 잡도 열린 이슈도 없다")
        return
    recovered = [n for n in tracked if n in succeeded]
    still = [n for n in tracked if n not in succeeded]
    if not recovered:
        print(f"#{number} 그대로 — 추적 중인 잡 {tracked} 이 이번 실행에서 돌지 않았다(건너뜀)")
        return
    if still:
        msg = f"일부 회복: {', '.join(recovered)} 가 {head} 에서 성공했다. 아직 실패로 추적 중: {', '.join(still)}"
        act(f"#{number} 댓글", "issue", "comment", str(number), "--repo", repo, "--body", msg, show=msg)
        act(f"#{number} 추적 잡 → {still}", "issue", "edit", str(number), "--repo", repo,
            "--body", with_state(body, still))
        return
    msg = f"초록으로 돌아왔다: {', '.join(recovered)} 가 {head} 에서 성공했다."
    act(f"#{number} 댓글", "issue", "comment", str(number), "--repo", repo, "--body", msg, show=msg)
    act(f"#{number} 닫음", "issue", "close", str(number), "--repo", repo)


if __name__ == "__main__":
    main()
