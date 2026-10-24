#!/usr/bin/env python3
"""기존 pane 대조를 유지하고 색 계산·그리기 목록 변환을 외부 사본에서 분리한다."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pane_measure', ROOT/'tools/editor-pane-measure/run.py')
pane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pane)
parent_setup = pane.setup
LEGACY_STAGES = ('tokens', 'background', 'textDrawList', 'syntaxColors', 'minimapSide', 'maxColsForRender', 'storeHitRows')
STAGES = LEGACY_STAGES + ('advanceSyntax', 'buildPaneOps')
EXTRA = {'src/platform/macos/app_session.zig', 'src/platform/macos/chrome/chrome_draw_lowering.zig'}


def stage_names(info):
    if not isinstance(info, dict):
        raise ValueError('Lowering setup must be an object')
    if type(info.get('lowering_schema')) is not int or info['lowering_schema'] not in (1, 2) or info.get('lowering_target') != 'pane-lowering-attribution':
        raise ValueError('Unknown lowering schema/target')
    stages = LEGACY_STAGES if info['lowering_schema'] == 1 else STAGES
    if info.get('lowering_stages') != list(stages) or type(info.get('pane_schema')) is not int or info['pane_schema'] != 3 or info.get('pane_summary_execution') != 'retained-ranges':
        raise ValueError('Wrong lowering stage/model contract')
    return stages


def check_contract(info):
    stage_names(info)


def setup(repo, output, deps, mode):
    source = parent_setup(repo, output, deps, mode)
    path = source/pane.HOST
    text = path.read_text()
    once = pane.provider.base.once
    # 함수 선언을 감싸되 pane 밖의 편집/대조 호출은 기존 깊이 guard로 제외한다.
    for index, name in enumerate(STAGES[3:], 3):
        matches = list(re.finditer(r'^(?:pub )?fn '+name+r'\([\s\S]*?\) [^{\n]+ \{\n', text, re.M))
        if len(matches) != 1:
            raise ValueError('Nonunique lowering function: '+name)
        anchor = matches[0].group()
        text = once(text, anchor, anchor+f'    const lowering_start = paneProbeStart();\n    defer loweringProbeFinish({index}, lowering_start);\n')
    # 호출의 원래 인수 문맥·오류 처리를 유지한다. 반환 타입을 바꾸는 공통 wrapper는 쓰지 않는다.
    text = once(text, '    const tokens = self.buildChromeTokens();', '''    const tokens = lowering_tokens: {
        const start = paneProbeStart();
        defer loweringProbeFinish(0, start);
        break :lowering_tokens self.buildChromeTokens();
    };''')
    text = once(text, '    chrome_draw_lowering.appendBackgroundQuadsWithTerminalOpacity(\n', '''    {
    const start = paneProbeStart();
    defer loweringProbeFinish(1, start);
    chrome_draw_lowering.appendBackgroundQuadsWithTerminalOpacity(
''')
    text = once(text, '        workspace_ops.windowOpacityByte(self),\n    );', '        workspace_ops.windowOpacityByte(self),\n    );\n    }')
    text = once(text, '    const dl = chrome_draw_lowering.buildTextDrawList(\n', '''    const dl = lowering_text: {
        const start = paneProbeStart();
        defer loweringProbeFinish(2, start);
        break :lowering_text chrome_draw_lowering.buildTextDrawList(
''')
    text = once(text, '        return null;\n    };\n    if (diag_gate.maruDebugEnabled()) editor_diag.debug(\n        "pane rect=', '        return null;\n    };\n    };\n    if (diag_gate.maruDebugEnabled()) editor_diag.debug(\n        "pane rect=')
    anchor = '        pane_probe_ns = @splat(0);'
    text = once(text, anchor, anchor+'\n        lowering_probe_ns = @splat(0);\n        lowering_probe_calls = @splat(0);')
    fields = ' '.join(name+'={d} '+name+'_calls={d}' for name in STAGES)
    values = ', '.join(f'lowering_probe_ns[{i}], lowering_probe_calls[{i}]' for i in range(len(STAGES)))
    anchor = '        const live_doc = term.rt.editorDocument().opened.?;'
    text = once(text, anchor, '        std.debug.print("LOWERING key={d} '+fields+'\\n", .{i, '+values+'});\n'+anchor)
    text += f'''
var lowering_probe_ns: [{len(STAGES)}]i128 = @splat(0);
var lowering_probe_calls: [{len(STAGES)}]u64 = @splat(0);
fn loweringProbeFinish(index: usize, start: ?i128) void {{
    if (start) |value| {{
        lowering_probe_ns[index] += frameProbeNow() - value;
        lowering_probe_calls[index] += 1;
    }}
}}
'''
    path.write_text(text)
    info_path = output/'setup-1.json'
    info = json.loads(info_path.read_text())
    info['instrumented_sha256'][pane.HOST] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in sorted(EXTRA):
        raw = (repo/name).read_bytes()
        if (source/name).read_bytes() != raw:
            raise ValueError('Unexpected original lowering module: '+name)
        saved = output/'original-product'/name
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        info['original_sha256'][name] = digest
        info['instrumented_sha256'][name] = digest
    info.update(lowering_schema=2, lowering_target='pane-lowering-attribution', lowering_stages=list(STAGES),
                lowering_scope='Inclusive calls within appendPaneFrame only; separate performance/full oracle runs; no product or GUI/HID change')
    check_contract(info)
    info_path.write_text(json.dumps(info, indent=2)+'\n')
    return source


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--run-only', action='store_true')
    args, _ = parser.parse_known_args()
    if args.run_only and args.output is not None:
        try:
            check_contract(json.loads((args.output/'setup-1.json').read_text()))
        except (ValueError, FileNotFoundError) as error:
            parser.error(str(error))
    pane.setup = setup
    pane.main()


if __name__ == '__main__':
    main()
