// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

/// A touch used to stop map motion must never become a game command when that
/// motion ends before the finger is lifted. A subsequent stationary tap may act.
struct IPadBattleTapGate {
    private var beganDuringScroll = true
    mutating func began(isScrolling:Bool) {beganDuringScroll = isScrolling}
    func permitsCommand(isScrolling:Bool)->Bool {!beganDuringScroll && !isScrolling}
}

/// Source cells remain square. UIKit converts the gesture into this unzoomed
/// content space once; applying the zoom factor a second time is incorrect.
struct IPadBattleGeometry {
    static let minimumTouchSide:CGFloat = 44
    let columns:Int
    let rows:Int
    let cellSide:CGFloat
    init(columns:Int,rows:Int,cellSide:CGFloat = minimumTouchSide) {
        self.columns = max(0,min(256,columns));self.rows = max(0,min(256,rows))
        self.cellSide = cellSide.isFinite ? max(Self.minimumTouchSide,cellSide) : Self.minimumTouchSide
    }
    var size:CGSize {CGSize(width:CGFloat(columns)*cellSide,height:CGFloat(rows)*cellSide)}
    func cell(at point:CGPoint)->GridPoint? {
        guard point.x.isFinite,point.y.isFinite,point.x >= 0,point.y >= 0,point.x < size.width,point.y < size.height else {return nil}
        return GridPoint(x:Int(point.x/cellSide),y:Int(point.y/cellSide))
    }
    func contains(_ point:GridPoint)->Bool {(0..<columns).contains(point.x) && (0..<rows).contains(point.y)}
    func rect(_ point:GridPoint)->CGRect {CGRect(x:CGFloat(point.x)*cellSide,y:CGFloat(point.y)*cellSide,width:cellSide,height:cellSide)}
    /// Only caller-highlighted public destinations. Occupied cells retain their
    /// existing officer element; this must not discover hidden units itself.
    func accessibilityDestinations(_ highlighted:Set<GridPoint>,occupied:Set<GridPoint>,origin:GridPoint?)->[GridPoint] {
        highlighted.filter {contains($0) && !occupied.contains($0)}.sorted {a,b in
            if let origin {
                let da = abs(a.x-origin.x)+abs(a.y-origin.y),db = abs(b.x-origin.x)+abs(b.y-origin.y)
                if da != db {return da < db}
            }
            return a.y == b.y ? a.x < b.x : a.y < b.y
        }
    }
    func centeredOffset(on point:GridPoint,zoom:CGFloat,viewport:CGSize)->CGPoint {
        let scale = zoom.isFinite ? max(1,zoom) : 1
        let box = rect(point)
        return CGPoint(x:max(0,min(max(0,size.width*scale-viewport.width),box.midX*scale-viewport.width/2)),
                       y:max(0,min(max(0,size.height*scale-viewport.height),box.midY*scale-viewport.height/2)))
    }
}
