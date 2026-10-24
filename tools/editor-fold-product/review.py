#!/usr/bin/env python3
"""제품 캐시의 독립 결함 가설을 사본에 주입하고 원본 대조군과 비교한다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--deps",type=Path,required=True)
    args=parser.parse_args()
    repo=Path(__file__).resolve().parents[2]
    output=args.output.resolve()
    if output==repo or repo in output.parents or output.exists(): parser.error("Use a new external directory")
    source=output/"source"
    source.mkdir(parents=True)
    subprocess.run(["rsync","-a","--exclude=.git","--exclude=.zig-cache","--exclude=zig-out","--exclude=zig-pkg","--exclude=node_modules","--exclude=references",str(repo)+"/",str(source)+"/"],check=True)
    (source/"zig-pkg").symlink_to(args.deps.resolve(),target_is_directory=True)
    path=source/"src/syntax/folds.zig"
    original=path.read_text()
    cases=[
        ("actual-edit-range","for (0..count + 1) |i| {","for (0..count) |i| {"),
        ("structural-change-range","for (0..count + 1) |i| {","for (0..count + 1) |i| { if (i < count) continue;"),
        ("current-line-index",".row = @intCast(row), .column =", ".row = 0, .column ="),
        ("allocation-failure-reset","errdefer {\n            self.invalidate();\n            out.clearRetainingCapacity();\n        }","errdefer {}"),
        ("native-snapshot-release","if (self.tree) |tree| c.ts_tree_delete(tree);","if (self.tree) |tree| { _ = tree; }"),
    ]
    def run(label):
        with (output/(label+".log")).open("w") as log:
            code=subprocess.run(["mise","exec","--","zig","build","test-editor-fold-cache","-j2"],cwd=source,stdout=log,stderr=subprocess.STDOUT,timeout=600).returncode
        return code,(output/(label+".log")).read_text()
    code,log=run("control-before")
    if code or "All 9 tests passed." not in log: raise RuntimeError("Original control failed")
    results=[]
    try:
        for name,old,new in cases:
            if original.count(old)!=1: raise RuntimeError("Nonunique mutation anchor: "+name)
            mutated=original.replace(old,new)
            path.write_text(mutated)
            code,log=run(name)
            if not code or "FAIL (" not in log: raise RuntimeError("Mutation survived or failed to compile: "+name)
            results.append(dict(hypothesis=name,result="runtime-detected",original_sha256=hashlib.sha256(original.encode()).hexdigest(),mutated_sha256=hashlib.sha256(mutated.encode()).hexdigest()))
            path.write_text(original)
            print(name,"runtime-detected",flush=True)
    finally:
        path.write_text(original)
    code,log=run("control-after")
    if code or "All 9 tests passed." not in log: raise RuntimeError("Restored control failed")
    (output/"results.json").write_text(json.dumps(results,indent=2)+"\n")
    print(output/"results.json",flush=True)


if __name__=="__main__": main()
