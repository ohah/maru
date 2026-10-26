"""Owned, deliberately unformatted inputs for the real format-on-save path."""
import os
from pathlib import Path
import subprocess
import uuid


def make_case(root, language, nonce):
    if language == 'rust':
        filename = 'main.rs'
        good = 'fn probe_add(value:i32)->i32{value+1}\nfn main(){/* 한글😀 */let _value=probe_add(41);}\n'
        formatted = 'fn probe_add(value: i32) -> i32 {\n    value + 1\n}\nfn main() {\n    /* 한글😀 */\n    let _value = probe_add(41);\n}\n// save probe\n'
        symbol = 'probe_add'
        metadata = ('Cargo.toml', '[package]\nname="maru_lsp_format_probe"\nversion="0.1.0"\nedition="2021"\n[[bin]]\nname="probe"\npath="main.rs"\n')
    elif language == 'go':
        filename = 'main.go'
        good = 'package main\nfunc probeAdd(value int)int{return value+1}\nfunc main(){/* 한글😀 */var _=probeAdd(41)}\n'
        formatted = 'package main\n\nfunc probeAdd(value int) int { return value + 1 }\nfunc main()                  { /* 한글😀 */ var _ = probeAdd(41) }\n\n// save probe\n'
        symbol = 'probeAdd'
        metadata = ('go.mod', 'module example.invalid/maru-lsp-format\n\ngo 1.24\n')
    else:
        raise ValueError('format-save supports Rust and Go only')
    before_save = good + '// save probe\n'
    return dict(scenario='format-save', language=language, nonce=nonce, root=str(root), path=str(root / filename),
                good=good, report_path=str(root / 'product.json'), before_save=before_save, formatted=formatted,
                local=before_save + '// local edit while response waits\n',
                timeout_source=before_save + '// timeout probe\n', disabled_source=before_save + '// disabled probe\n',
                definition_offset=good.encode().rindex(symbol.encode()) + 2,
                metadata=dict(path=str(root / metadata[0]), good=metadata[1]))


def fixture(root, language):
    case = make_case(root, language, uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    (root / '.maru-real-lsp-case').write_text(case['nonce'])
    subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True, timeout=15,
                   env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
    Path(case['path']).write_text(case['good'])
    Path(case['metadata']['path']).write_text(case['metadata']['good'])
    return case
