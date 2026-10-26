#!/usr/bin/env python3
"""Observe one real Tab without claiming full IME/candidate/pixel validation."""
import argparse
import hashlib
import json
import os
from pathlib import Path

import run as project
from tab_delivery import require, validate_root


def validate_short(report):
    require(report['mode'] == 'diagnostic' and report['window_inventory_validated'] is False, 'diagnostic separation')
    require(report['passed'] and not report['failures'] and report['step'] == 40 and report['candidate_count'] == 0 and report['target_field'] == 3, 'first Tab only')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True)
    here = Path(__file__).resolve().parent
    manifest = {name: hashlib.sha256((here/name).read_bytes()).hexdigest() for name in ('tab_probe.py','tab_delivery.py','tab_trace.swift.inc','prepare.py','driver.swift.inc','probe.zig.inc')}
    manifest['relay.swift'] = hashlib.sha256((here.parent/'palette-ime/relay.swift').read_bytes()).hexdigest()
    (args.output/'tab-probe-harness.json').write_text(json.dumps(manifest, indent=2)+'\n')
    project.common.validate_diagnostic = validate_short
    os.environ['MARU_PROJECT_TAB_ONLY'] = '1'
    os.environ['MARU_PROJECT_FIELD'] = '3'
    project.shared_run(args.app, args.output, 'diagnostic', wait_timeout=60)
    verdict = validate_root(args.output/'run')
    (args.output/'delivery-check.json').write_text(json.dumps(verdict, indent=2)+'\n')
    print(json.dumps(verdict))


if __name__ == '__main__':
    main()
