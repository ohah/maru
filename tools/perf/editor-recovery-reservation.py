"""Isolated Zig OwnerLease/atomic-writer experiments, not product restore."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import signal
import statistics
import subprocess
import tempfile
import time

ID = "000102030405060708090a0b0c0d0eff"
PEER_ID = "ff0102030405060708090a0b0c0d0eff"
TIMEOUT = 30  # Child hang guard, not a performance assertion.


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def paths(root, kind, identity=ID):
    data = root if kind == "claim" else root / ("d-" + identity)
    lock = root / ("d-" + identity + ".claim") if kind == "claim" else data / "owner.lock"
    return data, lock, data / ("d-" + identity + ".bak")


def body(record):
    header, content = record.read_bytes().split(b"\n\n", 1)
    require(header.startswith(b"maru.editor-backup.v2\n"), "wrong record header")
    return content


class Peer:
    def __init__(self, fixture, root, kind, mode="fresh", identity=ID, umask=-1):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [str(fixture), kind, str(root), mode, identity],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, bufsize=0, umask=umask,
        )
        self.owned = False
        try:
            require(self.read() == "waiting", "child did not reach start barrier")
        except BaseException:
            self.close()
            raise

    def send(self, text):
        self.process.stdin.write((text + "\n").encode())
        self.process.stdin.flush()

    def read(self):
        deadline, out = time.monotonic() + TIMEOUT, bytearray()
        while len(out) < 4096:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "child response deadline")
            require(select.select([self.process.stdout], [], [], remaining)[0], "child response timeout")
            byte = os.read(self.process.stdout.fileno(), 1)
            if not byte:
                self.stderr.seek(0)
                raise AssertionError("child EOF: " + self.stderr.read(8192).decode(errors="replace"))
            if byte == b"\n":
                return out.decode()
            out.extend(byte)
        raise AssertionError("unbounded response")

    def start(self):
        self.send("start")
        return self.admission()

    def admission(self):
        outcome = self.read()
        self.owned = outcome == "owned"
        if not self.owned:
            require(outcome.startswith("error:"), outcome)
            require(self.process.wait(timeout=TIMEOUT) == 0, "admission error was not reported cleanly")
        return outcome

    def command(self, text, expected="ok"):
        self.send(text)
        outcome = self.read()
        require(outcome.startswith("error:") if expected == "error" else outcome == expected,
                (text, expected, outcome))
        return outcome

    def publish(self, version="old"):
        self.command("prepare-" + version)
        self.command("publish")

    def kill(self):
        self.process.kill()
        require(self.process.wait(timeout=TIMEOUT) == -signal.SIGKILL, "SIGKILL not observed")
        self.owned = False

    def close(self):
        try:
            if self.process.poll() is None and self.owned:
                self.command("release", "released")
                self.owned = False
                require(self.process.wait(timeout=TIMEOUT) == 0, "release failed")
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=TIMEOUT)
            self.process.stdin.close()
            self.process.stdout.close()
            self.stderr.close()


@contextlib.contextmanager
def peer(fixture, root, kind, mode="fresh", identity=ID):
    child = Peer(fixture, root, kind, mode, identity)
    try:
        require(child.start() == "owned", "owner admission failed")
        yield child
    finally:
        child.close()


def refused(fixture, root, kind, mode, expected, identity=ID):
    child = Peer(fixture, root, kind, mode, identity)
    try:
        outcome = child.start()
        require(outcome == expected, outcome)
    finally:
        child.close()


def inode(path):
    stat = path.lstat()
    return stat.st_dev, stat.st_ino


def inventory(root):
    return sorted(str(p.relative_to(root)) for p in root.rglob("*"))


def race(fixture, root, kind):
    children = []
    try:
        for _ in range(2):
            children.append(Peer(fixture, root, kind))
        for child in children:
            child.send("start")
        outcomes = [child.admission() for child in children]
        require(sorted(outcomes) == ["error:Reserved", "owned"], outcomes)
        winner = next(child for child in children if child.owned)
        winner.publish()
        require(body(paths(root, kind)[2]) == b"old-complete", "race winner did not publish")
    finally:
        for child in children:
            child.close()


def lifecycle(fixture, root, kind):
    _, lock, record = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        reserved_entries = len(inventory(root))
        original = inode(lock)
        refused(fixture, root, kind, "reopen", "error:AlreadyOwned")
        owner.publish()
        owner.publish("new")
        published_entries = len(inventory(root))
        require(body(record) == b"new-complete" and inode(lock) == original, "atomic replace changed ownership")
        require(record.stat().st_mode & 0o777 == 0o600, "record is not private")
        refused(fixture, root, kind, "reopen", "error:AlreadyOwned")
    refused(fixture, root, kind, "fresh", "error:Reserved")
    with peer(fixture, root, kind, "reopen") as owner:
        require(inode(lock) == original, "reopen changed the reserved inode")
        owner.publish("empty")
        require(body(record) == b"", "empty edit lost")
        owner.command("mark-drop")
        owner.command("drop")
        owner.command("retire")
        owner.command("check", "error:Retired")
    require(not inventory(root), "retired reservation remains")
    return {"reserved_entries": reserved_entries, "published_entries": published_entries}


def restrictive_umask(fixture, root, kind):
    data, lock, record = paths(root, kind)
    child = Peer(fixture, root, kind, umask=0o777)
    try:
        require(child.start() == "owned", "restrictive umask prevented private reservation")
        require(lock.stat().st_mode & 0o777 == 0o600, "lock mode follows umask")
        require(data.stat().st_mode & 0o777 == 0o700, "directory mode follows umask")
        child.publish()
        require(record.stat().st_mode & 0o777 == 0o600, f"atomic record mode {record.stat().st_mode & 0o777:o}")
    finally:
        if data.exists():
            data.chmod(0o700)
        child.close()


def independent(fixture, root, kind):
    with peer(fixture, root, kind) as first, peer(fixture, root, kind, identity=PEER_ID) as second:
        first.publish()
        second.publish("new")
        survivor = paths(root, kind, PEER_ID)[2]
        first.command("mark-drop")
        first.command("drop")
        first.command("retire")
        require(body(survivor) == b"new-complete", "independent document was deleted")
        second.publish()
        require(body(survivor) == b"old-complete", "surviving owner cannot back up again")


def failures(fixture, root, kind):
    data, _, record = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        owner.command("encode-oom")
        require(not record.exists(), "OOM published a record")
        owner.command("rollback")
    require(not inventory(root), "first reservation rollback leaked")
    with peer(fixture, root, kind) as owner:
        data.chmod(0o500)
        try:
            owner.command("prepare-old", "error")
            require(not record.exists(), "failed first write published")
        finally:
            data.chmod(0o700)
        owner.publish()
        old = record.read_bytes()
        owner.command("encode-oom")
        require(record.read_bytes() == old, "encoding OOM changed old bytes")
        owner.command("rollback", "error:RecordPresent")
        owner.command("prepare-new")
        data.chmod(0o500)
        try:
            owner.command("publish", "error")
            require(record.read_bytes() == old, "failed replacement changed old bytes")
        finally:
            data.chmod(0o700)
        owner.command("abort")
        owner.publish("new")
        owner.command("mark-drop")
        data.chmod(0o500)
        try:
            owner.command("drop", "error")
            require(body(record) == b"new-complete", "failed delete lost bytes")
        finally:
            data.chmod(0o700)
        owner.command("drop")
        data.chmod(0o500)
        try:
            owner.command("retire", "error")
        finally:
            data.chmod(0o700)
        owner.command("retire")
    require(not inventory(root), "retry after cleanup failure leaked")


def killed(fixture, root, kind, point):
    data, lock, record = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        if point in ("published", "prepared-replacement", "record-removed"):
            owner.publish()
        if point.startswith("prepared"):
            owner.command("prepare-new")
        if point == "record-removed":
            owner.command("mark-drop")
            owner.command("drop")
        owner.kill()
    require(lock.exists(), "SIGKILL should leave reservation object")
    has_old = point in ("published", "prepared-replacement")
    require(record.exists() == has_old, "crash publication boundary changed")
    if has_old:
        require(body(record) == b"old-complete", "unpublished body escaped")
    residues = [p.name for p in data.iterdir() if p.name not in (lock.name, record.name)]
    require(len(residues) == int(point.startswith("prepared")), "unexpected atomic temporary inventory")
    refused(fixture, root, kind, "fresh", "error:Reserved")
    with peer(fixture, root, kind, "reopen") as owner:
        owner.command("rollback", "error:RestoredReservation")
        owner.publish("new")
        require(body(record) == b"new-complete", "reacquired owner cannot publish")
    return {"point": point, "temporary_files": len(residues), "reacquired": True}


def replaced_lock(fixture, root, kind):
    data, lock, record = paths(root, kind)
    with peer(fixture, root, kind) as old:
        old.publish()
        old.command("mark-drop")
        old.command("prepare-new")
        lock.rename(data / "old-owner.lock")
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        with peer(fixture, root, kind, "reopen") as new:
            # 다른 owner가 아직 게시하지 않아도 old owner의 쓰기 권한은 사라진다.
            # 새 record의 inode 검사가 owner 검사 누락을 대신 잡는 것을 피한다.
            before = record.read_bytes()
            old.command("publish", "error")
            require(record.read_bytes() == before, "replaced owner published over unchanged record")
            new.publish("new")
            protected = record.read_bytes()
            for command in ("publish", "drop", "retire"):
                old.command(command, "error")
                require(record.read_bytes() == protected, "replaced owner mutated new record")
            old.command("abort")
            require(record.read_bytes() == protected, "abort touched new owner's record")


def replaced_directory(fixture, root, kind, replace_root):
    data, _, _ = paths(root, kind)
    with peer(fixture, root, kind) as old:
        old.publish()
        old.command("mark-drop")
        old.command("prepare-old")
        target = root if replace_root else data
        saved = target.with_name(target.name + "-previous")
        target.rename(saved)
        if replace_root:
            target.mkdir(mode=0o700)
        with peer(fixture, root, kind) as new:
            new.publish("new")
            protected = paths(root, kind)[2].read_bytes()
            for command in ("publish", "drop", "retire"):
                old.command(command, "error")
                require(paths(root, kind)[2].read_bytes() == protected, "directory replacement changed new owner")
            old.command("abort")
            require(paths(root, kind)[2].read_bytes() == protected, "abort followed replacement directory")


def symlink(fixture, root, kind):
    data, lock, _ = paths(root, kind)
    if kind == "directory":
        data.mkdir(mode=0o700)
    target = root / "foreign"
    target.write_bytes(b"do-not-touch")
    target.chmod(0o600)
    lock.symlink_to(target)
    refused(fixture, root, kind, "fresh", "error:Reserved")
    refused(fixture, root, kind, "reopen", "error:InvalidOwnerFile")
    require(lock.is_symlink() and target.read_bytes() == b"do-not-touch", "symlink target changed")


def stale_drop(fixture, root, kind):
    record = paths(root, kind)[2]
    with peer(fixture, root, kind) as owner:
        owner.publish()
        owner.command("mark-drop")
        owner.publish("new")
        owner.command("drop", "error:StaleDrop")
        require(body(record) == b"new-complete", "stale selection deleted newer backup")


def foreign_record(fixture, root, kind):
    record = paths(root, kind)[2]
    with peer(fixture, root, kind) as owner:
        owner.publish()
        foreign = record.read_bytes().replace(ID.encode(), PEER_ID.encode())
        record.write_bytes(foreign)
        owner.command("mark-drop", "error:ForeignRecord")
        owner.command("prepare-new", "error:ForeignRecord")
        require(record.read_bytes() == foreign, "foreign identity was consumed")
        record.write_bytes(b"broken")
        owner.command("mark-drop", "error")
        owner.command("prepare-new", "error")
        require(record.read_bytes() == b"broken", "malformed record was consumed")


def changed_record(fixture, root, kind):
    _, lock, record = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        owner.publish()
        owner.command("prepare-new")
        original = record.read_bytes()
        record.rename(record.with_suffix(".previous"))
        record.write_bytes(original)
        record.chmod(0o600)
        owner.command("publish", "error:RecordChanged")
        require(record.read_bytes() == original, "prepared replacement ignored changed inode")
        owner.command("abort")
    if kind == "claim":
        lock.unlink()
        refused(fixture, root, kind, "fresh", "error:Reserved")
        require(record.read_bytes() == original and not lock.exists(), "fresh collision claimed existing backup")


def late_first_record(fixture, root, kind):
    record = paths(root, kind)[2]
    with peer(fixture, root, kind) as owner:
        owner.command("prepare-new")
        record.write_bytes(b"foreign-preserve")
        record.chmod(0o600)
        owner.command("publish", "error")
        require(record.read_bytes() == b"foreign-preserve", "first publication overwrote an occupied name")
        owner.command("abort")


def unowned_residue(fixture, root, kind):
    data, lock, _ = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        owner.publish()
        unknown = data / "unowned-residue"
        unknown.write_bytes(b"do-not-delete")
        owner.command("mark-drop")
        owner.command("drop")
        if kind == "directory":
            owner.command("retire", "error:NotEmpty")
            require(lock.exists(), "refused directory cleanup released ownership")
            owner.publish("new")
        else:
            owner.command("retire")
            require(not lock.exists(), "flat retirement retained its claim")
        require(unknown.read_bytes() == b"do-not-delete", "cleanup consumed unowned residue")


def parent_cleanup_failure(fixture, root, kind):
    data, lock, _ = paths(root, kind)
    with peer(fixture, root, kind) as owner:
        owner.publish()
        owner.command("mark-drop")
        owner.command("drop")
        root.chmod(0o500)
        try:
            owner.command("retire", "error:CleanupFailed")
        finally:
            root.chmod(0o700)
        owner.command("check", "error:Retired")
    require(data.is_dir() and not lock.exists(), "directory cleanup failure inventory changed")
    refused(fixture, root, kind, "fresh", "error:Reserved")
    refused(fixture, root, kind, "reopen", "error:Missing")


def benchmark(fixture, root, kind):
    result = subprocess.run([str(fixture), kind, str(root), "bench"], capture_output=True, text=True, timeout=TIMEOUT)
    require(result.returncode == 0, result.stderr)
    rows = []
    for line in result.stdout.splitlines():
        tokens = line.split()
        require(len(tokens) == 4 and tokens[0] == "sample", line)
        rows.append([int(n) for n in tokens[1:]])
    require(len(rows) == 64 and not inventory(root), "benchmark incomplete or cleanup leaked")
    return {
        "samples_ns": rows,
        "median_ns": dict(zip(("reserve", "publish", "retire"),
                              (statistics.median(row[i] for row in rows) for i in range(3)))),
        "timing_gate": False, "process_startup_included": False,
    }


def run(fixture, measure):
    results = []
    with tempfile.TemporaryDirectory(prefix="maru-recovery-reservation-") as tmp:
        base = Path(tmp).resolve()
        for kind in ("claim", "directory"):
            case_names = []
            def case(name, fn, *args):
                root = base / (kind + "-" + name)
                root.mkdir(mode=0o700)
                result = fn(fixture, root, kind, *args)
                case_names.append(name)
                return result
            for i in range(10):
                case("exclusive-" + str(i), race)
            storage_inventory = case("lifetime-and-empty", lifecycle)
            case("restrictive-umask", restrictive_umask)
            case("independent-same-path", independent)
            case("failures-and-retry", failures)
            crashes = []
            for point in ("owned", "prepared-first", "published", "prepared-replacement", "record-removed"):
                root = base / (kind + "-crash-" + point)
                root.mkdir(mode=0o700)
                crashes.append(killed(fixture, root, kind, point))
                case_names.append("crash-" + point)
            case("reservation-replaced", replaced_lock)
            case("root-replaced", replaced_directory, True)
            case("symlink", symlink)
            case("stale-drop", stale_drop)
            case("foreign-record", foreign_record)
            case("changed-record", changed_record)
            case("late-first-record", late_first_record)
            case("unowned-residue", unowned_residue)
            if kind == "directory":
                case("directory-replaced", replaced_directory, False)
                case("parent-cleanup-failure", parent_cleanup_failure)
            row = {"candidate": kind, "passed_scenarios": case_names, "crash_results": crashes, "storage_inventory": storage_inventory}
            if measure:
                root = base / (kind + "-benchmark")
                root.mkdir(mode=0o700)
                row["benchmark"] = benchmark(fixture, root, kind)
            results.append(row)
    return {
        "scope": "isolated candidate adapters using Maru OwnerLease and std atomic writer; not product backup/restore, OS reboot or power-loss evidence",
        "platform": platform.platform(),
        "fixture_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(), "results": results,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    require(platform.system() == "Darwin", "this fixture requires macOS")
    require(os.getuid() != 0, "permission-failure oracle must run as a regular user")
    text = json.dumps(run(args.fixture.resolve(strict=True), args.benchmark), indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
