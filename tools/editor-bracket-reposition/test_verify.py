"""판독기 자체의 대조군이다. 합성 로그를 실제 제품 실행 근거로 사용하지 않는다."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "bracket_comparison_verify", Path(__file__).with_name("verify.py")
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def log_for(shared=0, structure=0, variant="baseline", verified=False):
    views = shared + 1
    rows = [
        dict(
            key=key,
            views=views,
            edit_ns=20,
            frame_ns=30,
            total_ns=50,
            resolves=views if structure or variant == "baseline" else 0,
            rounds=1,
            tokens_before=100 + key * structure,
            tokens_after=100 + (key + 1) * structure,
            oracle=int(verified),
        )
        for key in range(20)
    ]
    text = f"BRACKET_WARM pending_before=1 rounds=2 views={views}\n"
    text += "".join(
        "BRACKET " + " ".join(f"{k}={v}" for k, v in row.items()) + "\n" for row in rows
    )
    return text + "All 5 tests passed.\n", rows


class ComparisonTests(unittest.TestCase):
    def test_input_matrix_order_missing_duplicate(self):
        good, _ = log_for()
        checker.samples(good, 0, 0, "baseline", False)
        lines = good.splitlines(keepends=True)
        for bad in (
            "".join(lines[:2] + lines[3:]),
            good + lines[1],
            good.replace("key=0 ", "key=1 ", 1),
        ):
            with self.assertRaises(ValueError):
                checker.samples(bad, 0, 0, "baseline", False)

    def test_fields_are_unique_typed_and_closed(self):
        good, _ = log_for()
        for old, new in (
            ("key=0 ", "key=0 key=0 "),
            ("edit_ns=20", "edit_ns=-20"),
            ("oracle=0", "oracle=False"),
            ("rounds=1", "unused=1"),
        ):
            with self.subTest(new=new), self.assertRaises(ValueError):
                checker.samples(good.replace(old, new, 1), 0, 0, "baseline", False)

    def test_scope_and_real_work_oracle(self):
        for shared in (0, 1):
            for structure in (0, 1):
                for variant in ("baseline", "reuse"):
                    for verified in (False, True):
                        good, _ = log_for(shared, structure, variant, verified)
                        checker.samples(good, shared, structure, variant, verified)
        good, _ = log_for()
        for old, new in (
            ("views=1", "views=2"),
            ("resolves=1", "resolves=0"),
            ("oracle=0", "oracle=1"),
        ):
            with self.subTest(new=new), self.assertRaises(ValueError):
                checker.samples(good.replace(old, new), 0, 0, "baseline", False)

    def test_time_and_preparation_bounds(self):
        good, _ = log_for()
        for bad in (
            good.replace("total_ns=50", "total_ns=51", 1),
            good.replace("rounds=1 ", "rounds=0 ", 1),
            good.replace("rounds=1 ", "rounds=129 ", 1),
            good.replace("rounds=2 ", "rounds=4097 ", 1),
            good + "BRACKET_WARM pending_before=0 rounds=1 views=1\n",
        ):
            with self.assertRaises(ValueError):
                checker.samples(bad, 0, 0, "baseline", False)

    def test_artifact_identity_execution_and_saved_types(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            info = dict(
                schema=1,
                target="bracket-reposition-comparison",
                workload_model="exact-prefix-and-canonical-delimiter-growth",
                repetitions=3,
                source_head="a" * 40,
                original_unchanged=True,
                original_sha256={},
                fixtures={},
                generators={},
                binaries={},
                execution=[],
            )
            for name in checker.NAMES:
                path = root / "fixtures" / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(name)
                info["fixtures"][name] = checker.sha(path)
            for name in ("measure.py", "benchmark.zig.inc"):
                (root / name).write_text("synthetic generator")
                info["generators"][name] = checker.sha(root / name)
            for variant in ("baseline", "reuse"):
                inventory = {}
                for name in ("src/test.zig", "build.zig"):
                    path = root / variant / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("synthetic source")
                    inventory[name] = checker.sha(path)
                info[variant + "_sha256"] = inventory
                info["original_sha256"] = dict(inventory)
                path = root / variant / "zig-out/bin/test"
                path.parent.mkdir(parents=True)
                path.write_bytes(b"synthetic binary, not product proof")
                info["binaries"][variant] = dict(
                    path=str(path), sha256=checker.sha(path)
                )
            rows = []
            for phase, repeats in (("run", 3), ("verify", 1)):
                for rep in range(repeats):
                    for fi, name in enumerate(checker.NAMES):
                        for shared in (0, 1):
                            for structure in (0, 1):
                                variants = (
                                    ("baseline", "reuse")
                                    if (rep + fi + shared + structure) % 2 == 0
                                    else ("reuse", "baseline")
                                )
                                for variant in variants:
                                    key = f"{phase}-{rep}-{name}-{shared}-{structure}-{variant}"
                                    text, samples = log_for(
                                        shared, structure, variant, phase == "verify"
                                    )
                                    path = root / (key + ".log")
                                    path.write_text(text)
                                    info["execution"].append(
                                        dict(
                                            key=key,
                                            exit_code=0,
                                            log_sha256=checker.sha(path),
                                        )
                                    )
                                    rows.append(
                                        dict(
                                            phase=phase,
                                            rep=rep,
                                            file=name,
                                            shared=shared,
                                            structure=structure,
                                            variant=variant,
                                            samples=samples,
                                        )
                                    )
            summary = []
            for name in checker.NAMES:
                for shared in (0, 1):
                    for structure in (0, 1):
                        for variant in ("baseline", "reuse"):
                            item = dict(
                                file=name,
                                shared=shared,
                                structure=structure,
                                variant=variant,
                                n=60,
                            )
                            for field, value in (
                                ("edit_ms", 20e-6),
                                ("frame_ms", 30e-6),
                                ("total_ms", 50e-6),
                            ):
                                item[field] = dict(p50=value, p95=value, maximum=value)
                            summary.append(item)
            (root / "summary.json").write_text(json.dumps(summary))
            (root / "receipt.json").write_text(json.dumps(info))
            (root / "samples.json").write_text(json.dumps(rows))
            # 이 fixture에는 Git 소스가 없다. 실제 CLI는 역사 대조를 끄는 옵션이 없다.
            self.assertEqual(checker.verify(root, historical=False)["processes"], 160)
            targets = [
                root / "fixtures" / checker.NAMES[0],
                root / "measure.py",
                root / "baseline/src/test.zig",
                root / "reuse/zig-out/bin/test",
                root / (info["execution"][0]["key"] + ".log"),
            ]
            for path in targets:
                saved = path.read_bytes()
                try:
                    path.write_bytes(saved + b"corruption")
                    with self.subTest(path=path.name), self.assertRaises(ValueError):
                        checker.verify(root, historical=False)
                finally:
                    path.write_bytes(saved)
            corruptions = []
            bad = copy.deepcopy(info)
            bad["execution"][0], bad["execution"][1] = (
                bad["execution"][1],
                bad["execution"][0],
            )
            corruptions.append(bad)
            bad = copy.deepcopy(info)
            bad["original_unchanged"] = False
            corruptions.append(bad)
            bad = copy.deepcopy(info)
            bad["source_head"] = "--output=unsafe"
            corruptions.append(bad)
            for bad in corruptions:
                (root / "receipt.json").write_text(json.dumps(bad))
                with self.assertRaises(ValueError):
                    checker.verify(root, historical=False)
            (root / "receipt.json").write_text(json.dumps(info))
            bad_rows = copy.deepcopy(rows)
            bad_rows[0]["samples"][0]["rounds"] = True
            (root / "samples.json").write_text(json.dumps(bad_rows))
            with self.assertRaises(ValueError):
                checker.verify(root, historical=False)
            (root / "samples.json").write_text(json.dumps(rows))
            checker.verify(root, historical=False)


if __name__ == "__main__":
    unittest.main()
