#!/usr/bin/env python3
"""pane 안 구문 준비와 본문 색 계산을 외부 사본에서 분리한다."""
import argparse
import importlib.util
import pathlib
import hashlib
import json
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "lowering", ROOT / "tools/editor-lowering-measure/run.py"
)
lower = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lower)
original_setup = lower.setup
EXTRA = {"src/chrome/components/editor_view/syntax_colors.zig"}
lower.EXTRA.update(EXTRA)
TARGET = "pane-syntax-attribution"
SCOPE = "Diagnostic pane-only advance and body colors; layer timings include empty branch checks; work counters mark nonempty branch conditions; no minimap/sticky body colors"
STAGES = (
    "resumeParse",
    "advanceBrackets",
    "promoteFolds",
    "lineColorsInto",
    "captureQuery",
    "captureRoles",
    "semanticLayer",
    "bracketLayer",
    "lineBounds",
    "neutralColor",
)
SYNTAX = "src/platform/macos/app_session/editor/syntax.zig"


def check_contract(info):
    if (
        not isinstance(info, dict)
        or type(info.get("inner_schema")) is not int
        or info["inner_schema"] != 1
        or info.get("inner_target") != TARGET
    ):
        raise ValueError("Unknown pane syntax schema/target")
    if info.get("inner_stages") != list(STAGES) or info.get("inner_scope") != SCOPE:
        raise ValueError("Wrong pane syntax stages/scope")
    if (
        not isinstance(info.get("inner_generator_sha256"), str)
        or re.fullmatch("[0-9a-f]{64}", info["inner_generator_sha256"]) is None
    ):
        raise ValueError("Missing pane syntax generator proof")
    lower.check_contract(info)


def once(s, a, b):
    return lower.pane.provider.base.once(s, a, b)


def enter_function(text, name, index, flag, prefix=""):
    matches = list(
        re.finditer(r"^(?:pub )?fn " + name + r"\([\s\S]*?\) [^{\n]+ \{\n", text, re.M)
    )
    if len(matches) != 1:
        raise ValueError("Nonunique pane syntax function: " + name)
    anchor = matches[0].group()
    return once(
        text,
        anchor,
        anchor
        + f"    const inner_start = {prefix}innerProbeStart({prefix}{flag});\n    defer {prefix}innerProbeFinish({index}, inner_start);\n",
    )


def setup(repo, output, deps, mode):
    source = original_setup(repo, output, deps, mode)
    hostpath = source / lower.pane.HOST
    host = hostpath.read_text()
    path = source / SYNTAX
    text = path.read_text()
    # 편집 중 같은 호출과 미니맵 색은 제외하고, pane 안 준비·본문 색만 구분한다.
    for name, flag in [
        ("advanceSyntax", "inner_probe_advance"),
        ("syntaxColors", "inner_probe_body"),
    ]:
        matches = list(
            re.finditer(
                r"^(?:pub )?fn " + name + r"\([^\n]*\) [^{\n]+ \{\n", host, re.M
            )
        )
        if len(matches) != 1:
            raise ValueError("Nonunique pane scope function: " + name)
        anchor = matches[0].group()
        host = once(
            host,
            anchor,
            anchor
            + f"    const inner_previous = syntax_color.{flag};\n    syntax_color.{flag} = pane_probe_depth != 0;\n    defer syntax_color.{flag} = inner_previous;\n",
        )
    host = enter_function(
        host, "promoteFoldRangesToSyntax", 2, "inner_probe_advance", "syntax_color."
    )
    text = enter_function(text, "resumeParse", 0, "inner_probe_advance")
    text = enter_function(text, "advanceBrackets", 1, "inner_probe_advance")
    text = enter_function(text, "lineColorsInto", 3, "inner_probe_body")
    # 같은 버퍼를 쓰는 병합 helper가 있으므로 본문 색 함수의 소유 범위로 제한한다.
    first = "pub fn lineColorsInto("
    following = "pub fn bracketRole("
    if text.count(first) != 1 or text.count(following) != 1:
        raise ValueError("Nonunique body color owner")
    begin = text.index(first)
    end = text.index(following, begin)
    before, text, after = text[:begin], text[begin:end], text[end:]
    anchor = "    p.spansForRange(allocator, doc_content, range, &bufs.spans);"
    text = once(
        text,
        anchor,
        "    {\n        const start = innerProbeStart(inner_probe_body);\n        defer innerProbeFinish(4, start);\n"
        + anchor
        + "\n    }",
    )
    a = "    bufs.byte_spans.clearRetainingCapacity();"
    b = "    // **2층을 섞는다**"
    if text.count(a) != 1 or text.count(b) != 1:
        raise ValueError("Nonunique pane syntax region")
    start = text.index(a)
    end = text.index(b, start)
    part = text[start:end]
    text = (
        text[:start]
        + "    {\n        const start = innerProbeStart(inner_probe_body);\n        defer innerProbeFinish(5, start);\n"
        + part
        + "    }\n"
        + text[end:]
    )
    for index, needle, work in [
        (
            6,
            "    if (extra.len > 0) mergeSecondLayer(allocator, bufs, extra, range) catch return &.{};",
            "semantic",
        ),
        (
            7,
            "    if (brackets.toks.len > 0) mergeBracketLayer(allocator, bufs, brackets, range) catch return &.{};",
            "bracket",
        ),
    ]:
        predicate = "extra.len > 0" if work == "semantic" else "brackets.toks.len > 0"
        replacement = (
            "    {\n        const start = innerProbeStart(inner_probe_body);\n        defer innerProbeFinish("
            + str(index)
            + ", start);\n        if (inner_probe_body and "
            + predicate
            + ") inner_probe_"
            + work
            + "_work += 1;\n"
            + needle
            + "\n    }"
        )
        text = once(text, needle, replacement)
    a = "    bufs.line_bounds.clearRetainingCapacity();"
    b = "    return syntax_colors.lineColors(\n"
    if text.count(a) != 1 or text.count(b) != 1:
        raise ValueError("Nonunique pane syntax region")
    start = text.index(a)
    end = text.index(b, start)
    part = text[start:end]
    text = (
        text[:start]
        + "    {\n        const start = innerProbeStart(inner_probe_body);\n        defer innerProbeFinish(8, start);\n"
        + part
        + "    }\n"
        + text[end:]
    )
    a = "    return syntax_colors.lineColors(\n"
    b = "        line_inlays,\n    );"
    if text.count(a) != 1 or text.count(b) != 1:
        raise ValueError("Nonunique pane syntax region")
    start = text.index(a)
    end = text.index(b, start) + len(b)
    part = text[start:end]
    text = (
        text[:start]
        + "    {\n        const start = innerProbeStart(inner_probe_body);\n        defer innerProbeFinish(9, start);\n"
        + part
        + "\n    }"
        + text[end:]
    )
    text = before + text + after
    text += """
pub var inner_probe_advance: bool = false;
pub var inner_probe_body: bool = false;
pub var inner_probe_ns: [INNER_STAGE_COUNT]i128 = @splat(0);
pub var inner_probe_calls: [INNER_STAGE_COUNT]u64 = @splat(0);
pub var inner_probe_semantic_work: u64 = 0;
pub var inner_probe_bracket_work: u64 = 0;
pub fn innerProbeStart(active: bool) ?i128 {
    return if (active) std.Io.Clock.awake.now(std.testing.io).nanoseconds else null;
}
pub fn innerProbeFinish(index: usize, start: ?i128) void {
    if (start) |value| {
        inner_probe_ns[index] += std.Io.Clock.awake.now(std.testing.io).nanoseconds - value;
        inner_probe_calls[index] += 1;
    }
}
""".replace(
        "INNER_STAGE_COUNT", str(len(STAGES))
    )
    anchor = "        lowering_probe_calls = @splat(0);"
    host = once(
        host,
        anchor,
        anchor
        + """
        try testing.expect(pane_probe_depth == 0 and !syntax_color.inner_probe_advance and !syntax_color.inner_probe_body);
        syntax_color.inner_probe_ns = @splat(0);
        syntax_color.inner_probe_calls = @splat(0);
        syntax_color.inner_probe_semantic_work = 0;
        syntax_color.inner_probe_bracket_work = 0;
""",
    )
    fields = " ".join(name + "={d} " + name + "_calls={d}" for name in STAGES)
    values = ", ".join(
        f"syntax_color.inner_probe_ns[{i}], syntax_color.inner_probe_calls[{i}]"
        for i in range(len(STAGES))
    )
    anchor = "        const live_doc = term.rt.editorDocument().opened.?;"
    host = once(
        host,
        anchor,
        '        std.debug.print("INNER key={d} '
        + fields
        + ' semanticWork={d} bracketWork={d}\\n", .{i, '
        + values
        + ", syntax_color.inner_probe_semantic_work, syntax_color.inner_probe_bracket_work});\n"
        + anchor,
    )
    hostpath.write_text(host)
    path.write_text(text)
    info_path = output / "setup-1.json"
    info = json.loads(info_path.read_text())
    for name in [lower.pane.HOST, SYNTAX]:
        info["instrumented_sha256"][name] = hashlib.sha256(
            (source / name).read_bytes()
        ).hexdigest()
    info.update(
        inner_schema=1,
        inner_stages=list(STAGES),
        inner_scope=SCOPE,
        inner_target=TARGET,
        inner_generator_sha256=hashlib.sha256(
            pathlib.Path(__file__).read_bytes()
        ).hexdigest(),
    )
    # 실행 전 생성기 사본도 고정해, 이후 도구 변경으로 과거 실행을 바꾸어 설명하지 않는다.
    check_contract(info)
    (output / "inner-generator.py").write_bytes(pathlib.Path(__file__).read_bytes())
    info_path.write_text(json.dumps(info, indent=2) + "\n")
    return source


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--run-only", action="store_true")
    args, _ = parser.parse_known_args()
    if args.run_only and args.output is not None:
        spec = importlib.util.spec_from_file_location(
            "provider_summary", ROOT / "tools/editor-provider-measure/summarize.py"
        )
        proof = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(proof)
        try:
            info = proof.load(args.output / "setup-1.json")
            check_contract(info)
            proof.digest(
                args.output / "inner-generator.py", info["inner_generator_sha256"]
            )
        except (ValueError, FileNotFoundError) as error:
            parser.error(str(error))
    lower.setup = setup
    lower.main()


if __name__ == "__main__":
    main()
