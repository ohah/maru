"""Explicit opt-in local clangd fixture. No installation or user configuration writes."""
import hashlib
import json
from pathlib import Path
import subprocess


def describe_clangd(path):
    path=Path(path)
    if not path.is_absolute():raise ValueError('clangd needs an absolute path')
    path=path.resolve(strict=True)
    if not path.is_file():raise ValueError('clangd must be a regular executable')
    version=subprocess.run([str(path),'--version'],capture_output=True,text=True,check=True,timeout=10).stdout
    if 'clangd version' not in version:raise ValueError('not a clangd version response')
    return dict(kind='clangd',path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),version=version.strip())


def prepare_clangd(project):
    project=project.resolve(strict=True)
    # Both C11 translation units have explicit compatible declarations.
    commands=[dict(directory=str(project),file=str(project/name),
        arguments=['clang','-xc','-std=c11','-c',str(project/name)])
        for name in ('main.c','other.c')]
    (project/'compile_commands.json').write_text(json.dumps(commands,indent=2)+'\n')
