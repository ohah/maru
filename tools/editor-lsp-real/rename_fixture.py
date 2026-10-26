"""Three owned files exercise both open buffers and a closed reference file."""
import os
from pathlib import Path
import subprocess
import uuid


def make_case(root, language, nonce):
    if language == 'rust':
        names = ['main.rs', 'values.rs', 'other.rs']
        texts = ['mod values;\nmod other;\nfn main() {\n    /* 한글😀 */ let _value = values::produce() + other::consume();\n    let _label = "produce";\n}\n',
                 '// 한글😀\npub fn produce() -> i32 { 41 }\n// produce in this comment stays unchanged.\npub fn produce_extra() -> i32 { 7 }\n',
                 'pub fn consume() -> i32 { /* 한글😀 */ crate::values::produce() }\n// produce in this comment stays unchanged.\n']
        metadata = ('Cargo.toml', '[package]\nname="maru_lsp_rename_probe"\nversion="0.1.0"\nedition="2021"\n[[bin]]\nname="probe"\npath="main.rs"\n')
    elif language == 'go':
        names = ['main.go', 'values.go', 'other.go']
        texts = ['package main\nfunc main() {\n    /* 한글😀 */ var _ = produce() + consume()\n    var _ = "produce"\n}\n',
                 'package main\n// 한글😀\nfunc produce() int { return 41 }\n// produce in this comment stays unchanged.\nfunc produce_extra() int { return 7 }\n',
                 'package main\nfunc consume() int { /* 한글😀 */ return produce() }\n// produce in this comment stays unchanged.\n']
        metadata = ('go.mod', 'module example.invalid/maru-lsp-rename\n\ngo 1.24\n')
    else:
        raise ValueError('rename supports Rust and Go only')
    files = [dict(path=str(root / n), good=t, renamed=t.replace('produce', 'renamed_produce', 1)) for n, t in zip(names, texts)]
    return dict(scenario='rename', language=language, nonce=nonce, root=str(root), path=files[0]['path'],
                good=texts[0], report_path=str(root / 'product.json'), files=files,
                metadata=dict(path=str(root / metadata[0]), good=metadata[1]),
                rename_offset=texts[0].encode().index(b'produce') + 2, new_name='renamed_produce',
                local=texts[0] + '// local edit while response waits\n')


def fixture(root, language):
    case = make_case(root, language, uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    (root / '.maru-real-lsp-case').write_text(case['nonce'])
    subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True, timeout=15,
                   env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
    for entry in [*case['files'], case['metadata']]:
        Path(entry['path']).write_text(entry['good'])
    return case
