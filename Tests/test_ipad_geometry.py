# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic UIKit-independent coordinate checks; never launch the game."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin" and shutil.which("xcrun"), "requires installed Xcode Swift tools")
class IPadBattleGeometryTests(unittest.TestCase):
    def test_taps_zoom_focus_and_minimum_target(self):
        source = Path(__file__).resolve().parents[1] / "iOS/IPadBattleGeometry.swift"
        main = '''import Foundation
import CoreGraphics
struct GridPoint:Hashable {var x:Int;var y:Int}
var tap = IPadBattleTapGate()
precondition(!tap.permitsCommand(isScrolling:false))
tap.began(isScrolling:true)
precondition(!tap.permitsCommand(isScrolling:false)) // stopping deceleration is not a command
tap.began(isScrolling:false)
precondition(tap.permitsCommand(isScrolling:false)) // the next deliberate tap works
precondition(!tap.permitsCommand(isScrolling:true)) // a newly begun pan or pinch still blocks
let geometry = IPadBattleGeometry(columns:40,rows:24)
precondition(geometry.cellSide == 44)
precondition(IPadBattleGeometry(columns:1,rows:1,cellSide:12).cellSide == 44)
for point in [CGPoint(x:-1,y:0),CGPoint(x:0,y:-1),CGPoint(x:1760,y:0),CGPoint(x:0,y:1056),CGPoint(x:CGFloat.nan,y:0),CGPoint(x:0,y:CGFloat.infinity)] {
    precondition(geometry.cell(at:point) == nil)
}
for cell in [GridPoint(x:0,y:0),GridPoint(x:39,y:0),GridPoint(x:0,y:23),GridPoint(x:39,y:23),GridPoint(x:18,y:12)] {
    let box = geometry.rect(cell)
    precondition(geometry.cell(at:CGPoint(x:box.midX,y:box.midY)) == cell)
    for zoom:CGFloat in [1,1.5,3] {for viewport in [CGSize(width:744,height:900),CGSize(width:220,height:400)] {
        let offset = geometry.centeredOffset(on:cell,zoom:zoom,viewport:viewport)
        precondition(offset.x >= 0 && offset.x <= max(0,geometry.size.width*zoom-viewport.width))
        precondition(offset.y >= 0 && offset.y <= max(0,geometry.size.height*zoom-viewport.height))
        let screen = CGPoint(x:box.midX*zoom-offset.x,y:box.midY*zoom-offset.y)
        let content = CGPoint(x:(screen.x+offset.x)/zoom,y:(screen.y+offset.y)/zoom)
        precondition(geometry.cell(at:content) == cell)
    }}
}
let first = GridPoint(x:1,y:0),second = GridPoint(x:0,y:1),far = GridPoint(x:2,y:1),occupied = GridPoint(x:0,y:0)
let destinations = geometry.accessibilityDestinations([far,second,first,occupied,GridPoint(x:-1,y:0)],occupied:[occupied],origin:occupied)
precondition(destinations == [first,second,far])
precondition(geometry.accessibilityDestinations([],occupied:[],origin:nil).isEmpty)
precondition(IPadBattleGeometry(columns:0,rows:0).cell(at:.zero) == nil)
print("iPad synthetic geometry passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "main.swift").write_text(main)
            result = subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(root / "cache"), str(source), str(root / "main.swift"), "-o", str(root / "check")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / "check")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("iPad synthetic geometry passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
