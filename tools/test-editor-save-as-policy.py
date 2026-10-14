#!/usr/bin/env python3
"""승인한 Save As 순서/취소 판정의 결함을 격리 사본에서 검출한다."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
source = (ROOT / "src/session/editor/ops/save_as.zig").read_text()
mutations = {
    "조기 새 경로 라우팅": (".waiting_source, .writing => .deferred", ".waiting_source, .writing => .destination"),
    "선행 저장 장벽 무시": ("!source_settled or !input_settled", "!input_settled"),
    "입력 확정 장벽 무시": ("!source_settled or !input_settled", "!source_settled"),
    "실패를 성공으로 게시": ("if (success) .succeeded else .failed", "if (success) .succeeded else .succeeded"),
    "접수 뒤 취소 허용": ("if (self.phase != .preparing) return false;", "if (self.phase == .succeeded) return false;"),
    "조기 성공 허용": (".waiting_source => if (success) return error.InvalidPhase,", ".waiting_source => {},"),
}


def run(path):
    return subprocess.run(
        ["mise", "exec", "--", "zig", "test", str(path)],
        cwd=ROOT, capture_output=True, text=True,
    )


with tempfile.TemporaryDirectory(prefix="maru-save-as-policy-") as directory:
    fixture = pathlib.Path(directory) / "save_as.zig"
    fixture.write_text(source)
    control = run(fixture)
    assert control.returncode == 0 and "All 5 tests passed" in control.stderr, control.stderr
    print("정상 대조군: 5개 통과")
    for label, (before, after) in mutations.items():
        assert source.count(before) == 1, label
        mutant = source.replace(before, after)
        # 장벽을 제거한 매개변수도 사용하여 컴파일 실패를 검출 성공으로 세지 않는다.
        if label == "선행 저장 장벽 무시":
            mutant = mutant.replace("if (!input_settled)", "_ = source_settled;\n        if (!input_settled)")
        if label == "입력 확정 장벽 무시":
            mutant = mutant.replace("if (!source_settled)", "_ = input_settled;\n        if (!source_settled)")
        fixture.write_text(mutant)
        result = run(fixture)
        assert result.returncode != 0 and "FAIL (" in result.stderr, (label, result.stderr)
        assert "error: unused" not in result.stderr, result.stderr
        print(label + ": 실행 단언에서 검출")
    fixture.write_text(source)
    restored = run(fixture)
    assert restored.returncode == 0 and "All 5 tests passed" in restored.stderr, restored.stderr
    print("복원 대조군: 5개 통과")
