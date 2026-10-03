# -*- coding: utf-8 -*-
"""Test/measure a chunked decoding candidate; deliberately not wired into product restore."""
from pathlib import Path
import subprocess, tempfile, json, statistics
ROOT=Path(__file__).resolve().parents[1]
WORK=Path(tempfile.mkdtemp(prefix='maru-workspace-read-test-'))
SWIFT=r'''
import Foundation
func trailingStart(_ bytes:Data)->Int {
 guard !bytes.isEmpty else { return 0 }
 var start=bytes.count-1
 while start>0 && bytes[start]&0xC0==0x80 && bytes.count-start<4 { start -= 1 }
 let b=bytes[start]
 let count = b>=0xC2 && b<=0xDF ? 2 : b>=0xE0 && b<=0xEF ? 3 : b>=0xF0 && b<=0xF4 ? 4 : 1
 return count>bytes.count-start ? start : bytes.count
}
func readChunked(_ url:URL,_ size:Int,_ reserve:Bool=false)->String? {
 guard let file=try? FileHandle(forReadingFrom:url) else { return nil }
 defer { try? file.close() }
 var result="";var pending=Data()
 do {
  if reserve {let count=try file.seekToEnd();try file.seek(toOffset:0);guard count<=UInt64(Int.max) else{return nil};result.reserveCapacity(Int(count))}
  while let chunk=try file.read(upToCount:size), !chunk.isEmpty {
   pending.append(chunk)
   let end=trailingStart(pending)
   result.append(String(decoding:pending.prefix(end),as:UTF8.self))
   // Rebase Data indices, and retain only up to three incomplete bytes.
   pending=Data(pending.suffix(pending.count-end))
  }
  result.append(String(decoding:pending,as:UTF8.self));return result
 } catch { return nil }
}
let args=CommandLine.arguments
if args.count>1 {
 let url=URL(fileURLWithPath:args[2]);let start=DispatchTime.now().uptimeNanoseconds
 let result = args[1]=="whole" ? (try? Data(contentsOf:url)).map {String(decoding:$0,as:UTF8.self)} : readChunked(url,65536,args[1]=="reserved")
 precondition(result != nil)
 print("bytes=\(result!.utf8.count) elapsed_us=\((DispatchTime.now().uptimeNanoseconds-start)/1000)");exit(0)
}
let root=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent();let url=root.appendingPathComponent("fixture")
var seed:UInt64=12345
var corpus:[[UInt8]]=[[],[0xF0,0x9F,0x98,0x80],[0xE0,0x80,0x80],[0xED,0xA0,0x80],[0xF4,0x90,0x80,0x80],[0xF0,0x9F,0x98],[0xC2,0x41],[0x80,0x80,0x80,0x80],Array("한글 한자 漢字\\\"\n".utf8)]
for i in 0..<512 {var bytes:[UInt8]=[];for _ in 0..<(i%97+1){seed=seed &* 6364136223846793005 &+ 1;bytes.append(UInt8(truncatingIfNeeded:seed>>24))};corpus.append(bytes)}
var judges=0
for bytes in corpus {
 try Data(bytes).write(to:url)
 let expected=String(decoding:bytes,as:UTF8.self)
 for size in [1,2,3,4,7,16,64] {for reserve in [false,true] {precondition(readChunked(url,size,reserve)==expected);judges += 1}}
}
try FileManager.default.removeItem(at:url)
precondition(readChunked(url,1)==nil);judges += 1
precondition(readChunked(root,1)==nil);judges += 1
print("decoder_comparisons=\(judges)")
'''
main=WORK/'main.swift';main.write_text(SWIFT)
subprocess.run(['xcrun','swiftc','-O',str(main),'-o',str(WORK/'test')],check=True)
subprocess.run([str(WORK/'test')],check=True)
rows=[]
for size in [1,16,64]:
 p=WORK/'large'
 try:
  with p.open('wb') as f:
   for _ in range(size): f.write(b'x'*(1024*1024))
  for mode in ['whole','chunked','reserved']:
   runs=[]
   for i in range(5):
    r=subprocess.run(['/usr/bin/time','-l',str(WORK/'test'),mode,str(p)],capture_output=True,text=True,check=True)
    (WORK/('%s-%d-%d.log'%(mode,size,i))).write_text(r.stdout+r.stderr)
    values=dict(token.split('=') for token in r.stdout.strip().split())
    rss=int(next(x for x in r.stderr.splitlines() if 'maximum resident' in x).split()[0])
    runs.append((int(values['bytes']),int(values['elapsed_us']),rss))
   assert all(x[0]==size*1024*1024 for x in runs)
   rows.append({'MiB':size,'mode':mode,'us_median':statistics.median(x[1] for x in runs),'rss_median':statistics.median(x[2] for x in runs)})
 finally:p.unlink(missing_ok=True)
(WORK/'results.json').write_text(json.dumps(rows,indent=2));print('artifacts='+str(WORK));print(json.dumps(rows,indent=2))
