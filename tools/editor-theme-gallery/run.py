#!/usr/bin/env python3
"""Capture current native-editor colors, using the unmodified product Metal renderer.

This is an opt-in visual inventory, not a golden-image or semantic-token test.
Pillow is only used for lossless PNG conversion and labelled comparison sheets.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from PIL import Image, ImageDraw, ImageFont


REPO = Path(__file__).resolve().parents[2]
DEFAULT_THEMES = ["maru", "one-dark", "catppuccin-mocha", "one-light"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory():
    """Fail when the product gains a grammar or preset we have not accounted for."""
    samples = json.loads(Path(__file__).with_name("samples.json").read_text())
    language = (REPO / "src/session/editor/language.zig").read_text()
    grammar_body = language.split("pub const Grammar = enum {", 1)[1].split("pub fn displayName", 1)[0]
    grammars = re.findall(r"^    ([a-z_]+),", grammar_body, re.M)
    if set(samples) != set(grammars) - {"none"}:
        raise RuntimeError("Fixture inventory differs from the product Grammar enum")
    theme = (REPO / "src/config/theme.zig").read_text()
    body = theme.split("pub const ThemePreset = enum", 1)[1].split("};", 1)[0]
    presets = [name.replace("_", "-") for name in re.findall(r"^    ([a-z_]+),", body, re.M)]
    if not presets or not set(DEFAULT_THEMES) <= set(presets):
        raise RuntimeError("Could not read product theme presets")
    return samples, presets


def capture(app, output, language, sample, theme, delay, scale):
    key = f"{language}--{theme}"
    root = output / "runs" / key
    root.mkdir(parents=True)
    profile = root / "profile"
    profile.mkdir()
    document = root / sample["filename"]
    document.write_text(sample["source"])
    pane = root / "pane.sh"
    pane.write_text("#!/bin/sh\nexec /bin/sleep 60\n")
    pane.chmod(0o755)
    config = root / "config"
    # Only the preset changes. No theme.syntax override can mask current defaults.
    config.write_text(
        f"theme.preset = {theme}\n"
        "theme.follow-system = false\n"
        "ui.language = en\nfont.family = JetBrains Mono\nfont.size = 14\n"
        "lsp.enabled = false\nlsp.shell-environment = false\n"
        "sidebar.agent-hooks = false\n"
        "session.keep-alive-after-quit = false\nworkspace.restore = false\n"
        f"shell.command = {pane}\nshell.args =\n"
    )
    ppm = root / "frame.ppm"
    png = output / "images" / f"{key}.png"
    # Do not inherit HOME/provider settings: startup hook removal also writes to
    # provider files when disabled. With HOME absent, that product path is a no-op.
    # Foundation uses CFFIXED_USER_HOME for its independent profile directory.
    env = {k: os.environ[k] for k in ("PATH", "TMPDIR", "LANG") if k in os.environ}
    env.update(
        CFFIXED_USER_HOME=str(profile),
        XDG_CONFIG_HOME=str(root / "xdg-config"),
        XDG_CACHE_HOME=str(root / "cache"),
        XDG_STATE_HOME=str(root / "state"),
        MARU_CONFIG=str(config),
        MARU_SESSION_HOST_ROOT=str(root / "host"),
        MARU_EDITOR_BACKUP_ROOT=str(root / "backups"),
        MARU_APP_SUMMARY_PATH=str(root / "summary.txt"),
        MARU_NO_WORKSPACE_RESTORE="1",
        MARU_NATIVE_EDITOR=str(document),
        MARU_FT_WINDOW_SIZE="1280x760",
        MARU_SCREENSHOT=str(ppm),
        MARU_SCREENSHOT_DELAY_MS=str(delay),
        MARU_SCREENSHOT_TIMEOUT_MS="20000",
        MARU_SCREENSHOT_RENDER_SCALE_MILLI=str(scale),
    )
    started = time.monotonic()
    with (root / "app.log").open("wb") as log:
        child = subprocess.Popen([str(app)], cwd=root, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            code = child.wait(timeout=35)
        finally:
            # A screenshot intentionally exits the GUI. Reap its isolated shell
            # process group as well, without touching any existing user session.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if child.poll() is None:
                child.wait(timeout=5)
    log_text = (root / "app.log").read_text(errors="replace")
    if code != 0 or not ppm.is_file() or "MARU_SCREENSHOT:" not in log_text:
        raise RuntimeError(f"{key}: capture failed (exit {code}); see {root / 'app.log'}")
    with Image.open(ppm) as frame:
        dimensions = frame.size
        if min(dimensions) < 600:
            raise RuntimeError(f"{key}: unexpectedly small frame {dimensions}")
        frame.save(png)
    # Keep the original PPM as evidence outside git; published PNG is lossless.
    return dict(language=language, theme=theme, filename=sample["filename"],
                image=str(png.relative_to(output)), dimensions=dimensions,
                image_sha256=sha(png), source_sha256=sha(document), config_sha256=sha(config),
                pid=child.pid, exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3))


def sheet(output, name, entries):
    width, height, label_height = 1280, 760, 42
    canvas = Image.new("RGB", (width * 2, (height + label_height) * ((len(entries) + 1) // 2)), "#15171c")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 22)
    for i, entry in enumerate(entries):
        x, y = (i % 2) * width, (i // 2) * (height + label_height)
        draw.text((x + 16, y + 8), f"{entry['language']} | {entry['theme']}", fill="#f2f2f2", font=font)
        with Image.open(output / entry["image"]) as frame:
            canvas.paste(frame.resize((width, height), Image.Resampling.LANCZOS), (x, y + label_height))
    target = output / "sheets" / f"{name}.png"
    canvas.save(target)
    return str(target.relative_to(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New empty directory, outside the repository")
    parser.add_argument("--app", type=Path, default=REPO / "zig-out/Maru.app/Contents/MacOS/maru-macos-app")
    parser.add_argument("--languages", nargs="+", help="Default: every bundled grammar")
    parser.add_argument("--themes", nargs="+", default=DEFAULT_THEMES)
    parser.add_argument("--typescript-all-presets", action="store_true")
    parser.add_argument("--delay-ms", type=int, default=1500)
    parser.add_argument("--scale-milli", type=int, choices=[1000, 2000], default=2000)
    args = parser.parse_args()
    samples, presets = inventory()
    languages = args.languages or list(samples)
    if not set(languages) <= set(samples) or not set(args.themes) <= set(presets):
        parser.error("Unknown language or theme")
    app = args.app.resolve(strict=True)
    output = args.output.resolve()
    if output == REPO or REPO in output.parents:
        parser.error("Capture evidence must be outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output directory must be empty")
    (output / "images").mkdir()
    (output / "sheets").mkdir()
    tasks = [(language, theme) for language in languages for theme in args.themes]
    if args.typescript_all_presets:
        tasks += [("typescript", theme) for theme in presets if ("typescript", theme) not in tasks]
    report = dict(source_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                  app_sha256=sha(app), viewport_points=[1280, 760], render_scale_milli=args.scale_milli,
                  capture_delay_ms=args.delay_ms, languages=languages, themes=args.themes,
                  semantic_tokens=False, syntax_overrides=False, captures=[], sheets=[])
    for index, (language, theme) in enumerate(tasks, 1):
        entry = capture(app, output, language, samples[language], theme, args.delay_ms, args.scale_milli)
        report["captures"].append(entry)
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"[{index}/{len(tasks)}] {language}: {theme} ({entry['elapsed_seconds']}s)", flush=True)
    for language in languages:
        entries = [e for e in report["captures"] if e["language"] == language and e["theme"] in args.themes]
        report["sheets"].append(sheet(output, language, entries))
    if args.typescript_all_presets:
        entries = [next(e for e in report["captures"] if e["language"] == "typescript" and e["theme"] == theme) for theme in presets]
        for offset in range(0, len(entries), 4):
            report["sheets"].append(sheet(output, f"typescript-presets-{offset // 4 + 1}", entries[offset:offset + 4]))
    (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    sections = []
    for language in languages:
        entries = [e for e in report["captures"] if e["language"] == language]
        pictures = "".join(f'<figure><figcaption>{html.escape(e["theme"])}</figcaption><a href="{e["image"]}"><img loading="lazy" src="{e["image"]}"></a></figure>' for e in entries)
        sections.append(f'<section><h2>{html.escape(language)}</h2><div class="grid">{pictures}</div></section>')
    (output / "index.html").write_text('<!doctype html><meta charset="utf-8"><title>Maru editor theme inventory</title><style>body{background:#15171c;color:#eee;font:16px system-ui;margin:24px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}figure{margin:0}img{width:100%}figcaption{padding:8px}section{margin-bottom:32px}</style><h1>Current Maru editor colors</h1><p>Product Metal captures; LSP disabled; no syntax overrides.</p>' + "".join(sections))
    print(f"Captured {len(tasks)} frames; gallery: {output / 'index.html'}")


if __name__ == "__main__":
    main()
