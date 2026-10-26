"""Owned multi-document inputs; no SDK discovery or protocol implementation."""
import os
from pathlib import Path
import subprocess
import uuid


def inputs(language):
    if language == 'rust':
        good = ('mod values;\nmod types;\nfn main() {\n'
                '    /* 한글😀 */ let _value: i32 = values::produce();\n}\n')
        return dict(filename='main.rs', peer='values.rs', good=good,
                    peer_good='// 한글😀\npub fn produce() -> i32 { 41 }\n',
                    peer_bad='// 한글😀\npub fn produce() -> &\'static str { "bad" }\n',
                    support=[('types.rs', 'pub struct ImportedToken;\n')],
                    symbol='produce', definition_line=1, completion_name='ImportedToken',
                    partial=good[:-2] + '    /* 한글😀 */ let _ = ImportedTok;\n}\n',
                    prefix='ImportedTok', usage='let _ = ImportedToken;',
                    import_marker='types::ImportedToken',
                    metadata=('Cargo.toml', '[package]\nname="maru_lsp_multi_probe"\nversion="0.1.0"\nedition="2021"\n[[bin]]\nname="probe"\npath="main.rs"\n'))
    if language == 'go':
        good = 'package main\n\nfunc main() {\n    /* 한글😀 */ var _ int = produce()\n}\n'
        return dict(filename='main.go', peer='values.go', good=good,
                    peer_good='package main\n\n// 한글😀\nfunc produce() int { return 41 }\n',
                    peer_bad='package main\n\n// 한글😀\nfunc produce() string { return "bad" }\n', support=[],
                    symbol='produce', definition_line=3, completion_name='Duration',
                    partial=good[:-2] + '    /* 한글😀 */ var _ time.Durat\n}\n',
                    prefix='Durat', usage='var _ time.Duration', import_marker='"time"',
                    metadata=('go.mod', 'module example.invalid/maru-lsp-multi\n\ngo 1.24\n'))
    raise ValueError('multi-file supports Rust and Go only')


def fixture(root, language):
    spec = inputs(language)
    root.mkdir(mode=0o700)
    nonce = uuid.uuid4().hex
    (root / '.maru-real-lsp-case').write_text(nonce)
    subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True, timeout=15,
                   env={k: v for k, v in os.environ.items() if not k.startswith('GIT_')})
    for name, text in [(spec['filename'], spec['good']), (spec['peer'], spec['peer_good']),
                       spec['metadata'], *spec['support']]:
        (root / name).write_text(text)
    return make_case(root, language, nonce)


def make_case(root, language, nonce):
    spec = inputs(language)
    partial = spec['partial'].encode()
    start = partial.rindex(spec['prefix'].encode())
    return dict(scenario='multi-file', language=language, nonce=nonce, root=str(root),
                path=str(root / spec['filename']), peer_path=str(root / spec['peer']),
                report_path=str(root / 'product.json'), good=spec['good'],
                peer_good=spec['peer_good'], peer_bad=spec['peer_bad'],
                support=[dict(path=str(root / name), good=text) for name, text in spec['support']],
                definition_offset=spec['good'].encode().rindex(spec['symbol'].encode()) + 2,
                definition_line=spec['definition_line'], partial=spec['partial'],
                completion_name=spec['completion_name'], completion_start=start,
                completion_offset=start + len(spec['prefix'].encode()),
                expected_usage=spec['usage'], import_marker=spec['import_marker'])
