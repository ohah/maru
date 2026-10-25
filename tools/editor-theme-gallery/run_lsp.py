#!/usr/bin/env python3
"""Capture real-server LSP highlighting through the product Metal renderer.

The built-in AppKit test driver answers trust for an owned synthetic repository.
Server startup/token observations come from a byte-preserving stdio proxy, never
from a fake server. Product code and palettes are unchanged.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

from PIL import Image, ImageChops

from run import DEFAULT_THEMES, REPO, inventory, sha, sheet


def events(root):
    path = root / "protocol.ndjson"
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # A concurrently written final line is read on the next poll.
    return result


def complete_ppm(path):
    """The renderer creates a path before finishing its pixel write."""
    try:
        with path.open("rb") as stream:
            header = [stream.readline() for _ in range(3)]
        width, height = map(int, header[1].split())
        return header[0] == b"P6\n" and header[2] == b"255\n" and path.stat().st_size == sum(map(len, header)) + width * height * 3
    except (OSError, ValueError):
        return False


def configuration(theme, pane, enabled):
    return (f"theme.preset = {theme}\ntheme.follow-system = false\n"
            "ui.language = en\nfont.family = JetBrains Mono\nfont.size = 14\n"
            f"lsp.enabled = {'true' if enabled else 'false'}\n"
            "lsp.shell-environment = false\nlsp.repository-environment = false\n"
            "sidebar.agent-hooks = false\nsession.keep-alive-after-quit = false\n"
            f"workspace.restore = false\nshell.command = {pane}\nshell.args =\n")


def prepare_project(root, language, sample, support):
    document = root / sample["filename"]
    document.write_text(sample["source"])
    subprocess.run(["/usr/bin/git", "init", "-q", str(root)], check=True, timeout=10,
                   env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
    # Project metadata permits actual type analysis; no application fixture is run.
    files = {
        "typescript": {"tsconfig.json": '{"compilerOptions":{"strict":true,"target":"es2022","module":"esnext","noEmit":true},"include":["sample.ts"]}'},
        "javascript": {"jsconfig.json": '{"compilerOptions":{"checkJs":true,"target":"es2022"},"include":["sample.js"]}'},
        "tsx": {"tsconfig.json": '{"compilerOptions":{"strict":true,"target":"es2022","jsx":"react-jsx","noEmit":true},"include":["sample.tsx"]}'},
        "rust": {"Cargo.toml": '[package]\nname = "theme_preview"\nversion = "0.1.0"\nedition = "2021"\n[[bin]]\nname = "preview"\npath = "sample.rs"\n'},
        "go": {"go.mod": 'module example.invalid/theme-preview\n\ngo 1.24\n'},
        "dart": {"pubspec.yaml": 'name: theme_preview\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n'},
        "csharp": {"preview.csproj": '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>'},
        "scala": {"build.sbt": 'scalaVersion := "3.3.6"\n'},
    }.get(language, {})
    for name, content in files.items():
        (root / name).write_text(content)
    for source in support:
        origin = Path(source).resolve(strict=True)
        (root / origin.name).write_bytes(origin.read_bytes())
    return document


def capture_language(args, output, language, sample, specification, themes):
    root = output / "runs" / language
    root.mkdir(parents=True)
    document = prepare_project(root, language, sample, specification.get("support", []))
    pane = root / "pane.sh"
    pane.write_text("#!/bin/sh\nexec /bin/sleep 180\n")
    pane.chmod(0o755)
    config = root / "config"
    config.write_text(configuration(themes[0], pane, True))
    server_env = {k: v for k, v in os.environ.items()
                  if k in ("HOME", "PATH", "TMPDIR", "LANG", "JAVA_HOME", "DOTNET_ROOT", "GOPATH", "GOROOT", "CARGO_HOME", "RUSTUP_HOME")}
    server_env.update(specification.get("environment", {}))
    proxy_config = root / "proxy.json"
    proxy_config.write_text(json.dumps(dict(root=str(root), argv=specification["argv"], server_environment=server_env)))
    wrapper = root / "server-proxy"
    proxy = Path(__file__).with_name("lsp_proxy.py").resolve()
    wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(proxy))} {shlex.quote(str(proxy_config))}\n")
    wrapper.chmod(0o755)
    lines = ["sleep 1000"]
    captures = []
    for enabled in (True,):
        if enabled:
            lines += ["config " + configuration(themes[0], pane, True).strip().replace("\n", " ;; "),
                      "menu Reload Config", "inspect-report trust-ready", f"waitfile {root / 'trust-point.json'}", "sleep 200"]
            if args.debug_state:
                lines += [f"inspect-main-capture {root / 'pretrust.ppm'}", "sleep 200"]
            lines += [f"inspect-owner-pointer {root / 'trust-point.json'} click", "sleep 200"]
            if args.debug_state:
                lines += ["action lsp_show_server_info", "sleep 200", f"inspect-main-capture {root / 'info.ppm'}", "sleep 500", "key 53 U+001B"]
            lines += [f"waitfile {root / 'ready'}", "sleep 3500"]
        for theme in themes:
            key = f"{language}--{theme}--{'lsp' if enabled else 'syntax'}"
            lines += ["config " + configuration(theme, pane, enabled).strip().replace("\n", " ;; "),
                      "menu Reload Config", "sleep 1000", f"inspect-main-capture {root / (key + '.ppm')}", "sleep 150"]
            captures.append(dict(language=language, theme=theme, lsp_enabled=enabled,
                                 filename=sample["filename"], image=f"images/{key}.png", ppm=root / (key + ".ppm")))
    script = root / "input.txt"
    script.write_text("\n".join(lines) + "\n")
    env = {k: os.environ[k] for k in ("PATH", "TMPDIR", "LANG") if k in os.environ}
    env.update(CFFIXED_USER_HOME=str(root / "profile"), XDG_CONFIG_HOME=str(root / "xdg-config"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
               MARU_CONFIG=str(config), MARU_SESSION_HOST_ROOT=str(root / "host"),
               MARU_EDITOR_BACKUP_ROOT=str(root / "backups"), MARU_APP_SUMMARY_PATH=str(root / "summary.txt"),
               MARU_NO_WORKSPACE_RESTORE="1", MARU_NATIVE_EDITOR=str(document), MARU_FT_WINDOW_SIZE="1280x760",
               MARU_SCREENSHOT=str(root / "offscreen-frame.ppm"), MARU_SCREENSHOT_DELAY_MS="0",
               MARU_SCREENSHOT_KEEP_PROCESS="maru-test-only-v1",
               MARU_SCREENSHOT_TIMEOUT_MS="660000", MARU_SCREENSHOT_RENDER_SCALE_MILLI="2000",
               MARU_INSPECTOR_APP_TEST="1", MARU_WEB_OSR_TEST_INPUT=str(script),
               MARU_MACOS_APP_SMOKE_MS="300000", MARU_EDITOR_THEME_GALLERY="1",
               MARU_WEB_OSR_TEST_REPORT=str(root / "input-report.txt"), MARU_LSP_SERVER_OVERRIDE=str(wrapper))
    started = time.monotonic()
    observed = []
    failure = None
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(args.app)], cwd=root, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            while time.monotonic() - started < args.timeout:
                observed = events(root)
                # This only synchronizes synthetic trust keys with an already
                # painted dialog; protocol responses remain the success oracle.
                # The empty left padding of the wide trust sheet is uniform,
                # unlike the code background below it. All runs start in maru.
                frame_path = root / "offscreen-frame.ppm"
                input_report = root / "input-report.txt"
                layout_ready = input_report.exists() and "label=trust-ready " in input_report.read_text()
                if layout_ready and not (root / "trust-point.json").exists() and frame_path.exists():
                    try:
                        with Image.open(frame_path) as frame:
                            points = [frame.getpixel((400, y)) for y in (600, 750, 900)]
                            background = frame.getpixel((2400, 1400))
                            if len(set(points)) == 1 and max(abs(a - b) for a, b in zip(points[0], background)) > 10:
                                modal = root / "trust.png"
                                frame.save(modal)
                                point = subprocess.run([str(args.trust_helper), str(modal)], capture_output=True, text=True, timeout=10)
                                if point.returncode == 0:
                                    (root / "trust-point.json").write_text(point.stdout)
                    except (OSError, ValueError):
                        pass
                initial = next((e for e in observed if e["event"] == "initialize_response" and not e.get("error")), None)
                opened = any(e.get("method") == "textDocument/didOpen" for e in observed)
                responses = [e for e in observed if e["event"] == "semantic_response"]
                provider = initial.get("semantic_provider") if initial else None
                supports_tokens = isinstance(provider, dict) and (provider.get("full") or provider.get("range"))
                semantic_wait_expired = time.monotonic() - started >= args.semantic_wait
                if initial and opened and (not supports_tokens or responses or semantic_wait_expired):
                    (root / "ready").touch(exist_ok=True)
                if all(e["ppm"].exists() for e in captures) and complete_ppm(captures[-1]["ppm"]):
                    break
                if child.poll() is not None:
                    failure = f"app exited before all captures: {child.returncode}"
                    break
                time.sleep(0.1)
            else:
                failure = f"LSP/capture deadline exceeded: {args.timeout}s"
        finally:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
    observed = events(root)
    initial = next((e for e in observed if e["event"] == "initialize_response"), {})
    responses = [e for e in observed if e["event"] == "semantic_response"]
    result = dict(language=language, argv=specification["argv"], app_pid=child.pid,
                  server_info=initial.get("server_info"), semantic_provider=initial.get("semantic_provider"),
                  initialized=any(e.get("method") == "initialized" for e in observed),
                  did_open=any(e.get("method") == "textDocument/didOpen" for e in observed),
                  semantic_responses=responses, failure=failure, captures=[])
    for entry in captures:
        ppm = entry.pop("ppm")
        if not ppm.exists():
            continue
        # The writer may have just published the path; wait for complete PPM bytes.
        with Image.open(ppm) as frame:
            frame.load()
            entry["dimensions"] = list(frame.size)
            frame.save(output / entry["image"])
        entry["sha256"] = sha(output / entry["image"])
        result["captures"].append(entry)
    differences = {}
    for theme in themes:
        off = args.baseline_gallery / f"images/{language}--{theme}.png" if args.baseline_gallery else output / "missing-baseline"
        on = output / f"images/{language}--{theme}--lsp.png"
        if off.exists() and on.exists():
            with Image.open(off) as a, Image.open(on) as b:
                # Only the code body; exclude status-bar LSP labels and sidebar.
                diff = ImageChops.difference(a.crop((420, 140, 2200, 1050)), b.crop((420, 140, 2200, 1050)))
                red, green, blue = diff.split()
                peak = ImageChops.lighter(ImageChops.lighter(red, green), blue)
                differences[theme] = sum(peak.histogram()[9:])
    result["changed_code_pixels"] = differences
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--servers-json", type=Path, required=True, help="Language -> real argv, optional environment/support files")
    parser.add_argument("--app", type=Path, required=True, help="Prepared fixture app: see prepare_lsp.py")
    parser.add_argument("--languages", nargs="+")
    parser.add_argument("--themes", nargs="+", default=DEFAULT_THEMES)
    parser.add_argument("--typescript-all-presets", action="store_true")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--semantic-wait", type=int, default=30, help="After this deadline, capture a connected server even if token response is still pending; record that separately")
    parser.add_argument("--debug-state", action="store_true")
    parser.add_argument("--trust-helper", type=Path)
    parser.add_argument("--baseline-gallery", type=Path)
    args = parser.parse_args()
    args.app = args.app.resolve(strict=True)
    fixture_path = args.app.parents[4] / "theme-gallery-fixture.json"
    if not fixture_path.is_file():
        parser.error("App fixture manifest is missing; run prepare_lsp.py first")
    fixture = json.loads(fixture_path.read_text())
    if fixture.get("app_sha256") != sha(args.app):
        parser.error("App does not match its prepared fixture manifest")
    samples, presets = inventory()
    servers = json.loads(args.servers_json.read_text())
    languages = args.languages or list(servers)
    if not set(languages) <= set(samples) or not set(languages) <= set(servers) or not set(args.themes) <= set(presets):
        parser.error("Unknown language, missing server argv, or unknown preset")
    output = args.output.resolve()
    if output == REPO or REPO in output.parents:
        parser.error("Output must be outside repository")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be empty")
    (output / "images").mkdir()
    (output / "sheets").mkdir()
    if args.trust_helper is None:
        args.trust_helper = output / "trust-button"
        subprocess.run(["xcrun", "swiftc", str(Path(__file__).with_name("trust_button.swift")), "-o", str(args.trust_helper)], check=True, timeout=60)
    report = dict(app_sha256=sha(args.app), source_commit=fixture["source_commit"], fixture=fixture,
                  scope="real servers; byte-preserving protocol observation; synthetic AppKit trust click and Metal capture; no physical keyboard", languages=[], captures=[], sheets=[])
    for i, language in enumerate(languages, 1):
        themes = presets if language == "typescript" and args.typescript_all_presets else args.themes
        result = capture_language(args, output, language, samples[language], servers[language], themes)
        report["languages"].append(result)
        report["captures"].extend(result["captures"])
        on = [e for e in result["captures"] if e["lsp_enabled"] and e["theme"] in args.themes]
        if on:
            report["sheets"].append(sheet(output, f"{language}-lsp", on))
        if language == "typescript" and args.typescript_all_presets:
            entries = [e for e in result["captures"] if e["lsp_enabled"]]
            for offset in range(0, len(entries), 4):
                report["sheets"].append(sheet(output, f"typescript-lsp-presets-{offset // 4 + 1}", entries[offset:offset + 4]))
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"[{i}/{len(languages)}] {language}: initialized={result['initialized']} token_responses={len(result['semantic_responses'])} frames={len(result['captures'])} failure={result['failure']}", flush=True)
    if any(e["failure"] for e in report["languages"]):
        print("Some languages did not complete; see per-language failure and protocol evidence.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
