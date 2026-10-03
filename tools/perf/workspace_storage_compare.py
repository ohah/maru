# -*- coding: utf-8 -*-
"""Opt-in design experiments, not a workspace format or product restore implementation.
Measures exact host capture against a Data accumulator, plus filesystem publication prototypes.
ABI validation is mocked. SIGKILL checks process interruption, not power-loss durability.
"""
import ast
import json
import os
from pathlib import Path
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ART = Path(tempfile.mkdtemp(prefix='maru-storage-compare-'))
HEADER = struct.Struct('<QQQ')  # experiment-only: generation, optional generation, bytes


def replace(path, data, crash, stage):
    temp = path.with_suffix('.tmp')
    with temp.open('wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    if crash == stage:
        os.kill(os.getpid(), signal.SIGKILL)
    os.replace(temp, path)
    fd = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    if crash == stage + 1:
        os.kill(os.getpid(), signal.SIGKILL)


def publish(directory, mode, generation, payload, crash=0, optional_failed=False, required_only=False):
    # Fixed topology bytes stand for required state; optional data has explicit generation.
    topology = (str(generation).encode() + b':terminal/browser/layout\n').ljust(4096, b' ')
    optional_generation = 0 if optional_failed else generation
    if required_only and mode == 'split':
        optional_generation = read(directory, mode)[1]
    if mode == 'inline':
        replace(directory / 'manifest', HEADER.pack(generation, optional_generation, len(topology)) + topology + (b'' if optional_failed else payload), crash, 1)
    else:
        if not optional_failed and not required_only:
            replace(directory / ('views-%d' % generation), struct.pack('<Q', generation) + payload, crash, 1)
        replace(directory / 'manifest', HEADER.pack(generation, optional_generation, len(topology)) + topology, crash, 3)


def read(directory, mode):
    raw = (directory / 'manifest').read_bytes()
    generation, optional_generation, length = HEADER.unpack(raw[:HEADER.size])
    topology = raw[HEADER.size:HEADER.size + length]
    assert topology.startswith(str(generation).encode() + b':')
    optional = raw[HEADER.size + length:]
    if mode == 'split' and optional_generation:
        optional_raw = (directory / ('views-%d' % optional_generation)).read_bytes()
        assert struct.unpack('<Q', optional_raw[:8])[0] == optional_generation
        optional = optional_raw[8:]
    assert 0 <= optional_generation <= generation
    if mode == 'inline': assert optional_generation in (0, generation)
    return generation, optional_generation, optional


def filesystem():
    rows = []
    for size in (2328, 1638360, 16 * 1024 * 1024):
        payload = b'v' * size
        for mode in ('inline', 'split'):
            directory = ART / ('%s-%d' % (mode, size)); directory.mkdir()
            writes = []; reads = []
            for generation in range(1, 6):
                start = time.perf_counter_ns(); publish(directory, mode, generation, payload)
                writes.append((time.perf_counter_ns() - start) / 1000)
                start = time.perf_counter_ns(); result = read(directory, mode)
                reads.append((time.perf_counter_ns() - start) / 1000)
                assert result == (generation, generation, payload)
                # Prototype GC only after manifest commit. Current sidecar survives.
                for old in directory.glob('views-*'):
                    if old.name != 'views-%d' % generation: old.unlink()
            rows.append(dict(mode=mode,bytes=size,write_median_us=statistics.median(writes),read_median_us=statistics.median(reads),file_count=len(list(directory.iterdir())),disk_bytes=sum(p.stat().st_size for p in directory.iterdir())))
            required_writes=[]
            for generation in range(6,11):
                start=time.perf_counter_ns();publish(directory,mode,generation,payload,required_only=True)
                required_writes.append((time.perf_counter_ns()-start)/1000)
                assert read(directory,mode)==(generation,5 if mode=='split' else generation,payload)
            rows.append(dict(mode=mode,bytes=size,mutation='required only, optional unchanged',write_median_us=statistics.median(required_writes)))
    for mode, stages in [('inline', (1, 2)), ('split', (1, 2, 3, 4))]:
        for stage in stages:
            directory = ART / ('crash-%s-%d' % (mode,stage)); directory.mkdir()
            publish(directory,mode,1,b'old')
            pid=os.fork()
            if pid==0:
                publish(directory,mode,2,b'new',stage);os._exit(99)
            _,status=os.waitpid(pid,0)
            assert os.WIFSIGNALED(status) and os.WTERMSIG(status)==signal.SIGKILL
            result=read(directory,mode)
            assert result in [(1,1,b'old'),(2,2,b'new')]
            rows.append(dict(mode=mode,crash_stage=stage,recovered_generation=result[0],files=len(list(directory.iterdir()))))
        directory=ART/('fallback-'+mode);directory.mkdir();publish(directory,mode,1,b'old')
        publish(directory,mode,2,b'new',optional_failed=True)
        assert read(directory,mode)==(2,0,b'')
        rows.append(dict(mode=mode,optional_failure='new topology, explicit default views'))
    # Counterexample: two independently replaced fixed filenames mix generations.
    directory=ART/'naive-split';directory.mkdir();publish(directory,'split',1,b'old')
    replace(directory/'views-fixed',struct.pack('<Q',2)+b'new',0,1)
    assert read(directory,'split')[0] != struct.unpack('<Q',(directory/'views-fixed').read_bytes()[:8])[0]
    rows.append(dict(mode='naive fixed-name split',mixed_generation_reproduced=True))
    return rows


def capture():
    original=(ROOT/'src/platform/macos/MaruAppHost.swift').read_text()
    def extract(start,end):
        a=original.index(start);return original[a:original.index(end,a)].replace('private func','func')
    values={}
    for node in ast.parse((ROOT/'tools/perf/workspace_host_impact.py').read_text()).body:
        if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id in ('pre','post') for t in node.targets):
            values[node.targets[0].id]=ast.literal_eval(node.value)
    method=extract('    private func captureWorkspaceSnapshot(', '\n    private func shutdownAppSession(')
    # Experimental alternative: accumulate once in Data and validate the same final bytes.
    alternative=method.replace('func captureWorkspaceSnapshot','func captureData').replace('var blocks = ""','var blocks = Data((MARU_WORKSPACE_HEADER + "\\n").utf8)').replace('blocks += String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self)','blocks.append(bytes, count: len)').replace('let snapshot = MARU_WORKSPACE_HEADER + "\\n" + blocks','let snapshot = blocks').replace('let snapshotBytes = Array(snapshot.utf8)','let snapshotBytes = snapshot').replace('snapshotBytes.withUnsafeBufferPointer { buf in','snapshotBytes.withUnsafeBytes { raw in\n            let buf = raw.bindMemory(to: UInt8.self)').replace('return Data(snapshot.utf8)','return snapshot').replace('            maru_macos_app_session_workspace_window_count(nil, buf.baseAddress, buf.count)', '            return maru_macos_app_session_workspace_window_count(nil, buf.baseAddress, buf.count)')
    normalized=alternative.replace('func captureData', 'func captureNormalizedData').replace('blocks.append(bytes, count: len)', 'blocks.append(contentsOf: String(decoding: UnsafeBufferPointer(start: bytes, count: len), as: UTF8.self).utf8)')
    harness=r'''
}
let mode=CommandLine.arguments[1];let total=Int(CommandLine.arguments[2])!;let count=Int(CommandLine.arguments[3])!
let h=Host();validatedCount=Int64(count)
for _ in 0..<count {h.windows.append(Surface(Session(String(repeating:"x",count:total/count))))}
if mode=="equivalence" {precondition(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==h.captureData(useTerminationKeyWindow:false,publishedOnly:true));h.windows=[Surface(Session("한글\nquote \" slash \\")),Surface(Session("한자\n"))];validatedCount=2;precondition(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==h.captureData(useTerminationKeyWindow:false,publishedOnly:true));h.windows[0].appSession!.buffer[0]=255;precondition(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true) != h.captureData(useTerminationKeyWindow:false,publishedOnly:true));precondition(h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true)==h.captureNormalizedData(useTerminationKeyWindow:false,publishedOnly:true));print("valid UTF8 equivalent, invalid UTF8 behavior differs");exit(0)}
let start=DispatchTime.now().uptimeNanoseconds
let result = mode=="control" ? nil : (mode=="original" ? h.captureWorkspaceSnapshot(useTerminationKeyWindow:false,publishedOnly:true) : (mode=="normalized" ? h.captureNormalizedData(useTerminationKeyWindow:false,publishedOnly:true) : h.captureData(useTerminationKeyWindow:false,publishedOnly:true)))
if mode != "control" {precondition(result?.count == total+MARU_WORKSPACE_HEADER.utf8.count+1)}
print("elapsed_us=\((DispatchTime.now().uptimeNanoseconds-start)/1000) bytes=\(result?.count ?? 0)")
'''
    main=ART/'main.swift';main.write_text(values['pre']+method+alternative+normalized+harness)
    binary=ART/'capture'
    subprocess.run(['xcrun','swiftc','-O',str(ROOT/'src/platform/macos/TerminationWindowPolicy.swift'),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary),'equivalence','4096','2'],check=True)
    rows=[]
    for total,count in [(4096,1),(1638400,64),(16*1024*1024,1),(64*1024*1024,64)]:
        for mode in ('control','original','data','normalized'):
            rss=[];durations=[]
            for repeat in range(5):
                r=subprocess.run(['/usr/bin/time','-l',str(binary),mode,str(total),str(count)],capture_output=True,text=True,check=True)
                (ART/('capture-%d-%d-%s-%d.log'%(total,count,mode,repeat))).write_text(r.stdout+r.stderr)
                rss.append(int(next(x for x in r.stderr.splitlines() if 'maximum resident' in x).split()[0]))
                durations.append(int(r.stdout.split()[0].split('=')[1]))
            rows.append(dict(bytes=total,windows=count,mode=mode,rss_median=statistics.median(rss),elapsed_median_us=statistics.median(durations)))
    # Byte equality at two windows; mocked validator does not prove full workspace semantics.
    return rows


if __name__ == '__main__':
    print('artifacts='+str(ART),flush=True)
    result={'filesystem':filesystem(),'capture':capture()}
    (ART/'results.json').write_text(json.dumps(result,indent=2))
    print(json.dumps(result,indent=2))
