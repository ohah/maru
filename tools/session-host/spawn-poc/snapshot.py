"""Freeze a committed checkout before any prototype is prepared."""
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile


def freeze(repo, destination, head):
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination.parent / "source.tar"
    with archive.open("wb") as out:
        subprocess.run(["git", "archive", "--format=tar", head], cwd=repo, stdout=out, check=True)
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not (member.isfile() or member.isdir()):
                raise ValueError("snapshot requires regular committed files and directories")
        source.extractall(destination)
    archive.unlink()


def copy(snapshot, destination):
    # Independent files: a prototype or an evolving worktree cannot mutate another candidate.
    shutil.copytree(snapshot, destination)
