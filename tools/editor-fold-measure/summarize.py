#!/usr/bin/env python3
"""실측 로그를 입력 프레임·유휴 프레임·범위 정확성·메모리로 나눠 집계한다."""
import argparse
import json
from pathlib import Path
import re
import statistics


def percentile(values, fraction):
    data = sorted(values)
    index = (len(data)-1)*fraction
    lo = int(index)
    return data[lo] + (data[min(lo+1,len(data)-1)]-data[lo])*(index-lo)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--prefix", default="run")
    args = parser.parse_args()
    rows = []
    for path in sorted(args.output.glob(args.prefix+"-[0-9]*-*.log")):
        log = path.read_text()
        if "All 5 tests passed." not in log:
            raise RuntimeError(f"Failed or incomplete run: {path}")
        lines = re.findall(r'^EW2 (.+) samples_ns=([\d,]+)$', log, re.M)
        if len(lines) != 1:
            raise RuntimeError(f"Expected one measurement: {path}")
        fields = dict(part.split("=",1) for part in lines[0][0].split())
        row = {k: (v if k in ("file","work") else int(v)) for k,v in fields.items()}
        row["samples_ns"] = [int(x) for x in lines[0][1].split(",") if x]
        if len(row["samples_ns"])!=row["edits"] or row["verified_each_edit"] not in (0,1): raise RuntimeError("Incomplete or unsupported measurement schema")
        rss = re.findall(r'(\d+)\s+maximum resident set size', log)
        row["max_rss_bytes"] = int(rss[0]) if rss else None
        row["log"] = path.name
        rows.append(row)
    grouped = {}
    for row in rows:
        key = (row["file"], row["work"], row["mode"])
        grouped.setdefault(key, []).append(row)
    results = []
    for (file,work,mode), group in sorted(grouped.items()):
        if len(group) != args.repetitions:
            raise RuntimeError(f"Expected {args.repetitions} runs, found {len(group)}: {(file,work,mode)}")
        if len({r["verified_each_edit"] for r in group})!=1: raise RuntimeError("Verification and timing runs were mixed")
        samples = sum((r["samples_ns"] for r in group),[])
        results.append(dict(file=file,work=work,mode=mode,runs=len(group),
            key_p50_ms=statistics.median(samples)/1e6,key_p95_ms=percentile(samples,.95)/1e6,
            key_max_ms=max(samples)/1e6,
            idle_peak_p50_ms=statistics.median(r["idle_max_ns"] for r in group)/1e6,
            tail_peak_p50_ms=statistics.median(r["tail_ns"] for r in group)/1e6,
            settle_timer_ms=statistics.median(r["settle_ns"] for r in group)/1e6,
            verified_each_edit=bool(group[0]["verified_each_edit"]), final_equal=True,
            mismatch=sum(r["mismatch"] for r in group) if group[0]["verified_each_edit"] else None,
            deferred=sum(r["deferred"] for r in group),
            full_nodes_p50=statistics.median(r["full_nodes"] for r in group),
            local_nodes_p50=statistics.median(r["local_nodes"] for r in group),
            scanned_records_p50=statistics.median(r["scanned_records"] for r in group),
            cache_bytes=max(r["cache_bytes"] for r in group),
            max_rss_bytes_p50=statistics.median(r["max_rss_bytes"] for r in group if r["max_rss_bytes"] is not None)))
    expected = 5*8*3
    if len(results) != expected:
        raise RuntimeError(f"Expected {expected} groups, found {len(results)}")
    (args.output/("summary.json" if args.prefix=="run" else args.prefix+"-summary.json")).write_text(json.dumps(dict(scope="ReleaseFast product functions; test allocator and virtual timer, not HID-to-display latency",runs=rows,groups=results),indent=2)+"\n")
    text = ["| 문서 | 입력 | 방식 | 키 p50 / p95 ms | 유휴 최대 ms | 끝난 뒤 최대 ms | 만기 시계 ms | 범위 불일치 | 캐시 KiB |", "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    names = {0:"전체",1:"증분",2:"지연"}
    for r in results:
        text.append(f'| {r["file"]} | {r["work"]} | {names[r["mode"]]} | {r["key_p50_ms"]:.2f} / {r["key_p95_ms"]:.2f} | {r["idle_peak_p50_ms"]:.2f} | {r["tail_peak_p50_ms"]:.2f} | {r["settle_timer_ms"]:.1f} | {r["mismatch"] if r["mismatch"] is not None else "별도 검증"} | {r["cache_bytes"]/1024:.1f} |')
    (args.output/("summary.md" if args.prefix=="run" else args.prefix+"-summary.md")).write_text("\n".join(text)+"\n")
    print(args.output/("summary.json" if args.prefix=="run" else args.prefix+"-summary.json"))


if __name__ == "__main__":
    main()
