"""Native pure admission controls; no test posts keyboard or mouse events."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'CoreGraphics policy is compiled on macOS')
class PointerPolicyTests(unittest.TestCase):
    def test_owner_freshness_and_bounded_events(self):
        source = r'''
import Foundation
import CoreGraphics
let owner = String((UInt64(1) << 62) + 2)
let window = CGRect(x:0,y:0,width:800,height:600)
var state: [String:Any] = ["pid":77,"address_pointer_mode":true,"window_key":true,"time":10.0,"generation":owner,
 "pointer_targets":["address":["x":20.0,"y":40.0,"w":300.0,"h":40.0],"terminal":["x":20.0,"y":100.0,"w":300.0,"h":400.0]]]
var request: [String:Any] = ["pid":77,"kind":"pointer","action":"drag","target":"address","time":10.0,"generation":owner,"x":100.0,"y":60.0,"end_x":120.0,"end_y":60.0]
func accepted(_ req:[String:Any],_ st:[String:Any],_ rect:CGRect=window) -> Bool {
 (try? IMEPointerPolicy.events(request:req,state:st,window:rect,pid:77,now:10.1)) != nil
}
precondition(accepted(request,state))
let path = try IMEPointerPolicy.events(request:request,state:state,window:window,pid:77,now:10.1)
precondition(path.count == 8 && path.first!.type == .leftMouseDown && path.last!.type == .leftMouseUp)
precondition(path.dropFirst().dropLast().allSatisfy { $0.type == .leftMouseDragged && $0.point.x >= 100 && $0.point.x <= 120 })
for mutation: [String:Any] in [["pid":78],["generation":"0"],["generation":"invalid"],["time":8.0],["time":11.0],["time":Double.nan],["kind":"other"],["target":"terminal"],["x":-1.0],["end_x":799.0],["end_y":Double.infinity]] {
 var req=request;req.merge(mutation){_,new in new};precondition(!accepted(req,state))
}
for mutation: [String:Any] in [["pid":78],["address_pointer_mode":false],["window_key":false],["time":8.0],["time":11.0],["generation":"0"]] {
 var st=state;st.merge(mutation){_,new in new};precondition(!accepted(request,st))
}
precondition(!accepted(request,state,CGRect(x:400,y:0,width:400,height:600)))
request["generation"]="0";state["generation"]="0"
precondition(!accepted(request,state)) // dragging requires an address activation
request["action"]="click"
precondition(accepted(request,state)) // entering a native webview-owned address bar
request["target"]="terminal";request["x"]=100.0;request["y"]=120.0
precondition(accepted(request,state))
print("pointer_policy=passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main = root / 'main.swift'
            main.write_text(source)
            subprocess.run(['xcrun', 'swiftc', str(Path(__file__).with_name('PointerPolicy.swift')), str(main), '-o', str(root / 'test')], check=True, capture_output=True, text=True)
            result = subprocess.run([str(root / 'test')], check=True, capture_output=True, text=True)
            self.assertIn('pointer_policy=passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
