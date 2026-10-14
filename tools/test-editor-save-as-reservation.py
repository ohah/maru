#!/usr/bin/env python3
"""승인한 Save As 예약/콜백 판정의 결함을 격리 사본에서 검출한다."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
source = (ROOT / "src/session/editor/ops/save_as_reservation.zig").read_text()
mutations = {
    "요청 번호 재사용": ("self.next_id += 1;", "self.next_id += 0;"),
    "창·surface 콜백 신원 무시": ("entry.token.id == token.id and std.meta.eql(entry.token.origin, token.origin)", "entry.token.id == token.id"),
    "문서 잠금 무시": ("if (std.meta.eql(entry.document, document)) return error.DocumentBusy;", "if (std.meta.eql(entry.document, document) and self.next_id == 0) return error.DocumentBusy;"),
    "목적지 이름 충돌 무시": ("if (std.mem.eql(u8, key, destination.namespace)) return error.DestinationBusy;", "if (std.mem.eql(u8, key, destination.namespace) and self.next_id == 0) return error.DestinationBusy;"),
    "같은 실제 파일 충돌 무시": ("if (std.meta.eql(file, incoming)) return error.DestinationBusy;", "if (std.meta.eql(file, incoming) and self.next_id == 0) return error.DestinationBusy;"),
    "접수 뒤 취소가 예약 해제": ("if (!self.entries.items[i].state.cancel()) return false;", "_ = self.entries.items[i].state.cancel();"),
}



def run(path):
    return subprocess.run(
        ["mise", "exec", "--", "zig", "test", str(path)],
        cwd=ROOT, capture_output=True, text=True,
    )


with tempfile.TemporaryDirectory(prefix="maru-save-as-reservation-") as directory:
    fixture = pathlib.Path(directory) / "save_as.zig"
    (pathlib.Path(directory) / "save_as.zig").write_text((ROOT / "src/session/editor/ops/save_as.zig").read_text())
    fixture = pathlib.Path(directory) / "save_as_reservation.zig"
    fixture.write_text(source)
    control = run(fixture)
    assert control.returncode == 0 and "All 11 tests passed" in control.stderr, control.stderr
    print("정상 대조군: 11개 통과")
    for label, (before, after) in mutations.items():
        assert source.count(before) == 1, label
        mutant = source.replace(before, after)
        fixture.write_text(mutant)
        result = run(fixture)
        assert result.returncode != 0 and "FAIL (" in result.stderr, (label, result.stderr)
        assert "error: unused" not in result.stderr, result.stderr
        print(label + ": 실행 단언에서 검출")
    fixture.write_text(source)
    restored = run(fixture)
    assert restored.returncode == 0 and "All 11 tests passed" in restored.stderr, restored.stderr
    print("복원 대조군: 11개 통과")

# 허용 목록 변경이 OS 호출까지 허용하지 않는지 실제 경계 판정자의 변이로 대조한다.
with tempfile.TemporaryDirectory(prefix="maru-save-as-sans-io-") as directory:
    gate = pathlib.Path(directory) / "editor_ops_sans_io.zig"
    gate_source = (ROOT / "tests/boundary/editor_ops_sans_io.zig").read_text()
    (pathlib.Path(directory) / "posix_walk.zig").write_bytes(
        (ROOT / "tests/boundary/posix_walk.zig").read_bytes())
    gate.write_text(gate_source)
    normal = run(gate)
    assert normal.returncode == 0 and "All 3 tests passed" in normal.stderr, normal.stderr
    meta_line = next(line for line in gate_source.splitlines(True) if '.name = "meta"' in line)
    gate.write_text(gate_source.replace(meta_line, meta_line.replace('"meta"', '"c"')))
    unsafe = run(gate)
    assert unsafe.returncode != 0 and "FAIL (TestExpectedEqual)" in unsafe.stderr, unsafe.stderr
    assert "판정자는 OS 진입점과 우회를 잡는다...expected 1, found 0" in unsafe.stderr, unsafe.stderr
    print("OS namespace 허용 결함: 기존 금지 호출 단언에서 검출")
    gate.write_text(gate_source.replace(meta_line, ""))
    false_positive = run(gate)
    assert false_positive.returncode != 0 and "FAIL (TestExpectedEqual)" in false_positive.stderr, false_positive.stderr
    assert "sans-io 위반:" in false_positive.stderr and "std.meta" in false_positive.stderr, false_positive.stderr
    print("순수 값 비교 오탐 결함: 실제 편집 판정 폴더에서 검출")
    gate.write_text(gate_source)
    restored = run(gate)
    assert restored.returncode == 0 and "All 3 tests passed" in restored.stderr, restored.stderr
    print("경계 판정자 정상·복원 대조군: 3개씩 통과")
