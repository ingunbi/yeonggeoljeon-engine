// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// A presentation adapter only. Every tap returns a source cell to the store;
/// movement, commands, random draws and turn transitions remain store-owned.
struct IPadBattleCanvas:UIViewRepresentable {
    let session:OriginalBattleSession
    let data:DataSet
    let selectedSlot:Int?
    let highlighted:Set<GridPoint>
    let animation:OriginalBattleAnimator
    var idlePhase:UInt8 = 0
    let onCellTap:(GridPoint)->Void

    func makeUIView(context:Context)->IPadBattleScrollView {
        let view = IPadBattleScrollView()
        view.update(session:session,data:data,selectedSlot:selectedSlot,highlighted:highlighted,animation:animation,idlePhase:idlePhase,onCellTap:onCellTap)
        return view
    }
    func updateUIView(_ view:IPadBattleScrollView,context:Context) {
        view.update(session:session,data:data,selectedSlot:selectedSlot,highlighted:highlighted,animation:animation,idlePhase:idlePhase,onCellTap:onCellTap)
    }
    static func dismantleUIView(_ view:IPadBattleScrollView,coordinator:()) {
        view.board.onCellTap = nil;view.delegate = nil
    }
}

final class IPadBattleScrollView:UIScrollView,UIScrollViewDelegate,UIGestureRecognizerDelegate {
    fileprivate let board = IPadBattleDrawingView()
    private var currentSession:ObjectIdentifier?
    private var lastSelection:Int?
    private var pendingFocus:GridPoint?
    private var tapGate = IPadBattleTapGate()
    private let issueLabel = UILabel()
    override init(frame:CGRect) {
        super.init(frame:frame)
        delegate = self;backgroundColor = UIColor(red:0.055,green:0.075,blue:0.11,alpha:1)
        minimumZoomScale = 1;maximumZoomScale = 3;bouncesZoom = false
        isDirectionalLockEnabled = false;alwaysBounceVertical = false;alwaysBounceHorizontal = false
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = true;showsHorizontalScrollIndicator = true
        board.isOpaque = true;board.contentMode = .redraw
        addSubview(board)
        issueLabel.numberOfLines = 3;issueLabel.font = .preferredFont(forTextStyle:.caption1)
        issueLabel.adjustsFontForContentSizeCategory = true;issueLabel.textColor = .systemOrange
        issueLabel.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        issueLabel.layer.cornerRadius = 8;issueLabel.clipsToBounds = true;issueLabel.isHidden = true
        addSubview(issueLabel)
        let tap = UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
        tap.numberOfTouchesRequired = 1;tap.delegate = self;board.addGestureRecognizer(tap)
        accessibilityLabel = "전장 지도"
        accessibilityHint = "두 손가락으로 확대하거나 축소할 수 있습니다. 지도를 밀어서 이동하고 부대나 칸을 선택하세요."
        isAccessibilityElement = false
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
    func update(session:OriginalBattleSession,data:DataSet,selectedSlot:Int?,highlighted:Set<GridPoint>,animation:OriginalBattleAnimator,idlePhase:UInt8 = 0,onCellTap:@escaping(GridPoint)->Void) {
        let identity = ObjectIdentifier(session),changed = currentSession != identity
        if changed {
            currentSession = identity;setZoomScale(1,animated:false)
            board.geometry = .init(columns:session.width,rows:session.height)
            board.frame = CGRect(origin:.zero,size:board.geometry.size);contentSize = board.geometry.size
            pendingFocus = selectedSlot.flatMap {slot -> GridPoint? in
                guard let unit = session.units[slot],unit.status == 2,(!unit.enemy || unit.scriptFlags&0x20 != 0) else {return nil}
                return unit.position
            }
                ?? session.units.values.filter {$0.status == 2 && !$0.enemy}.min(by:{$0.slot < $1.slot})?.position
        } else if lastSelection != selectedSlot,let slot = selectedSlot,let unit = session.units[slot],unit.status == 2,
                  !unit.enemy || unit.scriptFlags&0x20 != 0 {pendingFocus = unit.position}
        lastSelection = selectedSlot
        board.update(session:session,data:data,selectedSlot:selectedSlot,highlighted:highlighted,animation:animation,idlePhase:idlePhase,onCellTap:onCellTap)
        issueLabel.text = board.presentationIssue;issueLabel.isHidden = board.presentationIssue == nil
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Insets only center a map smaller than the viewport; no pan/zoom reset
        // occurs during a regular SwiftUI refresh or a changed HP value.
        let horizontal = max(0,(bounds.width-contentSize.width)/2),vertical = max(0,(bounds.height-contentSize.height)/2)
        let next = UIEdgeInsets(top:vertical,left:horizontal,bottom:vertical,right:horizontal)
        if contentInset != next {contentInset = next}
        issueLabel.frame = CGRect(x:bounds.minX+8,y:bounds.minY+8,width:max(1,min(500,bounds.width-16)),height:80)
        if let focus = pendingFocus,bounds.width > 0,bounds.height > 0 {
            pendingFocus = nil
            let offset = board.geometry.centeredOffset(on:focus,zoom:zoomScale,viewport:bounds.size)
            setContentOffset(CGPoint(x:contentSize.width <= bounds.width ? -horizontal : offset.x,
                                     y:contentSize.height <= bounds.height ? -vertical : offset.y),animated:false)
        }
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView? {board}
    func scrollViewDidZoom(_ scrollView:UIScrollView) {setNeedsLayout()}
    func scrollViewDidScroll(_ scrollView:UIScrollView) {setNeedsLayout()}
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        // Stopping inertial scrolling can clear isDecelerating before the tap
        // ends. Preserve the touch-down state instead of testing only on release.
        tapGate.began(isScrolling:isZooming || isDragging || isDecelerating)
        return true
    }
    @objc private func tapped(_ recognizer:UITapGestureRecognizer) {
        guard recognizer.state == .ended,tapGate.permitsCommand(isScrolling:isZooming || isDragging || isDecelerating),
              let point = board.geometry.cell(at:recognizer.location(in:board)) else {return}
        board.onCellTap?(point)
    }
}

private struct IPadBattleAtlasCatalog:Decodable {
    struct Atlas:Decodable {var id:String;var image:String;var tileCount:Int;var columns:Int;var sha256:String}
    var format:Int;var tileSize:Int;var atlases:[Atlas];var mapImages:[String:String]
}
private final class IPadBattleUnitElement:UIAccessibilityElement {
    var activate:(()->Void)?
    var focus:(()->Void)?
    override func accessibilityElementDidBecomeFocused() {super.accessibilityElementDidBecomeFocused();focus?()}
    override func accessibilityActivate()->Bool {guard let activate else {return false};activate();return true}
}

final class IPadBattleDrawingView:UIView {
    fileprivate var geometry = IPadBattleGeometry(columns:0,rows:0)
    fileprivate var onCellTap:((GridPoint)->Void)?
    private struct UnitPicture {
        var slot:Int;var point:GridPoint;var name:String;var level:Int;var troops:Int;var maximum:Int
        var enemy:Bool;var flags:UInt8;var image:CGImage?
        /// Set while the unit walks: its place in cells, between the two cells it crosses.
        var walking:CGPoint?
    }
    private var animation = OriginalBattleAnimator()
    private var selectedSlot:Int?
    private var highlighted:Set<GridPoint> = []
    private var units:[UnitPicture] = []
    private var backdrop:CGImage?
    private var baseline:[UInt8] = []
    private var pictures:[UInt8] = []
    private var pictureColumns = 0
    private var tiles:[Int:CGImage] = [:]
    private var renderer:OriginalBattleSpriteRenderer?
    private var resourceKey:String?
    private var imageIssue:String?
    private var changedTileIssue:String?
    fileprivate var presentationIssue:String? {changedTileIssue ?? imageIssue}
    private var accessibilityBySlot:[Int:IPadBattleUnitElement] = [:]
    private var accessibilityByCell:[GridPoint:IPadBattleUnitElement] = [:]

    private func loadImage(_ url:URL)throws->CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let picture = CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw EngineError.invalid("전장 그림을 읽을 수 없습니다: "+url.lastPathComponent)
        }
        return picture
    }
    private func prepareImages(session:OriginalBattleSession,data:DataSet) {
        resourceKey = data.root.path+"/"+session.definition.id
        backdrop = nil;tiles = [:];renderer = nil;imageIssue = nil
        baseline = (session.definition.pictureTiles ?? []).compactMap(UInt8.init(exactly:))
        pictureColumns = session.width*2
        do {
            guard let path = session.definition.image else {throw EngineError.invalid("전장 원본 그림 정보가 없습니다.")}
            let image = try loadImage(data.containedFile(path))
            guard image.width == session.width*32,image.height == session.height*32 else {throw EngineError.invalid("전장 원본 그림 크기가 맞지 않습니다.")}
            backdrop = image
            let url = try data.containedFile("battle-tile-atlases.json")
            if FileManager.default.fileExists(atPath:url.path) {
                let bytes = try Data(contentsOf:url)
                guard bytes.count <= 2_097_152 else {throw EngineError.invalid("전장 타일 목록이 허용 크기를 넘었습니다.")}
                let catalog = try JSONDecoder().decode(IPadBattleAtlasCatalog.self,from:bytes)
                guard catalog.format == 1,catalog.tileSize == 16,catalog.atlases.count <= 8,
                      let id = catalog.mapImages[path],let atlas = catalog.atlases.first(where:{$0.id == id}),
                      (1...256).contains(atlas.tileCount),(1...16).contains(atlas.columns) else {throw EngineError.invalid("이 전장의 원본 타일 은행을 확인할 수 없습니다.")}
                let atlasURL = try data.containedFile(atlas.image),png = try Data(contentsOf:atlasURL)
                guard png.count <= 4_194_304,SHA256.hash(data:png).map({String(format:"%02x",$0)}).joined() == atlas.sha256 else {throw EngineError.invalid("전장 타일 그림의 검증값이 맞지 않습니다.")}
                let full = try loadImage(atlasURL)
                guard full.width == atlas.columns*16,full.height == ((atlas.tileCount+atlas.columns-1)/atlas.columns)*16 else {throw EngineError.invalid("전장 타일 은행 크기가 맞지 않습니다.")}
                for index in 0..<atlas.tileCount {tiles[index] = full.cropping(to:CGRect(x:(index%atlas.columns)*16,y:(index/atlas.columns)*16,width:16,height:16))}
            } else if baseline.count == session.width*session.height*4 {
                // Older data remains readable. Only source tiles actually present
                // in its PNG are reused; unknown replacements are visibly refused.
                for (index,id) in baseline.enumerated() where tiles[Int(id)] == nil {
                    tiles[Int(id)] = image.cropping(to:CGRect(x:(index%pictureColumns)*16,y:(index/pictureColumns)*16,width:16,height:16))
                }
            }
        } catch {imageIssue = String(describing:error)}
        do {renderer = try OriginalBattleSpriteRenderer(root:data.root)}
        catch {imageIssue = [imageIssue,String(describing:error)].compactMap {$0}.joined(separator:"\n")}
    }
    fileprivate func update(session:OriginalBattleSession,data:DataSet,selectedSlot:Int?,highlighted:Set<GridPoint>,animation:OriginalBattleAnimator,idlePhase:UInt8 = 0,onCellTap:@escaping(GridPoint)->Void) {
        if resourceKey != data.root.path+"/"+session.definition.id {prepareImages(session:session,data:data)}
        self.onCellTap = onCellTap;self.selectedSlot = selectedSlot;self.animation = animation
        self.highlighted = Set(highlighted.filter(geometry.contains))
        pictures = session.pictureTiles ?? baseline
        changedTileIssue = nil
        if pictures.count != session.width*session.height*4 {changedTileIssue = "변경된 지도의 원본 타일 배열을 표시할 수 없습니다."}
        else if let missing = pictures.enumerated().first(where: {index,id in
            (!baseline.indices.contains(index) || baseline[index] != id) && tiles[Int(id)] == nil
        }) {changedTileIssue = "변경된 지형 그림 #\(missing.element)의 원본 타일이 없습니다. 자료를 다시 준비해 주세요."}
        units = session.units.values.sorted {$0.slot < $1.slot}.compactMap {unit in
            guard unit.status == 2,(!unit.enemy || unit.scriptFlags&0x20 != 0),geometry.contains(unit.position),
                  let person = try? session.people.person(unit.person),
                  let maximum = try? OriginalCombat.maxTroops(classID:person.classID,level:person.level,tables:session.combat) else {return nil}
            let walker = animation.walker.flatMap {$0.slot == unit.slot ? $0 : nil}
            let picture = walker.flatMap {try? renderer?.image(unit:unit,classID:person.classID,direction:$0.direction,stepPixels:$0.stepPixels)}
                ?? (try? renderer?.image(unit:unit,classID:person.classID,phase:idlePhase))
            return UnitPicture(slot:unit.slot,point:unit.position,name:person.name,level:person.level,troops:person.rawTroops,maximum:maximum,
                enemy:unit.enemy,flags:unit.scriptFlags,image:picture,walking:walker.map {CGPoint(x:$0.x,y:$0.y)})
        }
        updateAccessibility();setNeedsDisplay()
    }
    private func updateAccessibility() {
        isAccessibilityElement = false
        let valid = Set(units.map(\.slot));accessibilityBySlot = accessibilityBySlot.filter {valid.contains($0.key)}
        for unit in units {
            let element = accessibilityBySlot[unit.slot] ?? IPadBattleUnitElement(accessibilityContainer:self)
            element.accessibilityLabel = "\(unit.enemy ? "적군" : "아군") \(unit.name), 레벨 \(unit.level)"
            var state = "병력 \(unit.troops) / \(unit.maximum), \(unit.point.x+1)열 \(unit.point.y+1)행"
            if unit.flags&2 != 0 {state += ", 혼란"};if unit.flags&0x80 != 0 {state += ", 행동 완료"}
            element.accessibilityValue = state
            element.accessibilityTraits = unit.slot == selectedSlot ? [.button,.selected] : [.button]
            element.accessibilityHint = "이 부대의 칸 선택"
            element.accessibilityFrameInContainerSpace = geometry.rect(unit.point)
            element.activate = { [weak self] in self?.onCellTap?(unit.point) }
            element.focus = { [weak self] in self?.revealAccessibilityCell(unit.point) }
            accessibilityBySlot[unit.slot] = element
        }
        let origin = units.first(where:{$0.slot == selectedSlot})?.point
        let destinations = geometry.accessibilityDestinations(highlighted,occupied:Set(units.map(\.point)),origin:origin)
        let validCells = Set(destinations)
        accessibilityByCell = accessibilityByCell.filter {validCells.contains($0.key)}
        for point in destinations {
            let element = accessibilityByCell[point] ?? IPadBattleUnitElement(accessibilityContainer:self)
            element.accessibilityLabel = "이동 가능한 빈 칸, \(point.x+1)열 \(point.y+1)행"
            element.accessibilityHint = "이중 탭하면 이 위치로 이동합니다. 공격이나 대기를 확정하기 전에는 이동을 취소할 수 있습니다."
            element.accessibilityTraits = [.button]
            element.accessibilityFrameInContainerSpace = geometry.rect(point)
            element.activate = { [weak self] in
                guard let self,self.highlighted.contains(point),self.geometry.contains(point),!self.units.contains(where:{$0.point == point}) else {return}
                self.onCellTap?(point)
            }
            element.focus = { [weak self] in self?.revealAccessibilityCell(point) }
            accessibilityByCell[point] = element
        }
        let selected = selectedSlot.flatMap {accessibilityBySlot[$0]}.map {[$0]} ?? []
        accessibilityElements = selected+destinations.compactMap {accessibilityByCell[$0]}+units.filter {$0.slot != selectedSlot}.compactMap {accessibilityBySlot[$0.slot]}
    }
    private func revealAccessibilityCell(_ point:GridPoint) {
        guard let scroll = superview as? UIScrollView,geometry.contains(point) else {return}
        // A deliberate VoiceOver focus action may scroll to its target. Regular
        // state refreshes never call this path or reset the user's viewport.
        scroll.scrollRectToVisible(convert(geometry.rect(point).insetBy(dx:-8,dy:-8),to:scroll),animated:false)
    }
    override func draw(_ rect:CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {return}
        context.setFillColor(UIColor(red:0.055,green:0.075,blue:0.11,alpha:1).cgColor);context.fill(rect)
        if let backdrop {Renderer.image(backdrop,in:bounds,context:context)}
        let half = geometry.cellSide/2
        if pictures.count == geometry.columns*geometry.rows*4 {
            for (index,id) in pictures.enumerated() where !baseline.indices.contains(index) || baseline[index] != id {
                let box = CGRect(x:CGFloat(index%pictureColumns)*half,y:CGFloat(index/pictureColumns)*half,width:half,height:half)
                guard rect.intersects(box) else {continue}
                if let image = tiles[Int(id)] {Renderer.image(image,in:box,context:context)}
                else {context.setFillColor(UIColor.black.cgColor);context.fill(box);drawText("?",in:box,color:.systemOrange,size:16)}
            }
        }
        for point in highlighted {
            let box = geometry.rect(point).insetBy(dx:1,dy:1)
            context.setFillColor(UIColor.systemCyan.withAlphaComponent(0.24).cgColor);context.fill(box)
            context.setStrokeColor(UIColor.systemCyan.withAlphaComponent(0.75).cgColor);context.setLineWidth(1);context.stroke(box)
            // The inset corner also makes reachable cells identifiable by shape.
            context.move(to:CGPoint(x:box.minX+4,y:box.minY+11));context.addLine(to:CGPoint(x:box.minX+4,y:box.minY+4));context.addLine(to:CGPoint(x:box.minX+11,y:box.minY+4));context.strokePath()
        }
        let side = geometry.cellSide
        for unit in units {
            var box = geometry.rect(unit.point)
            if let place = unit.walking {box = CGRect(x:place.x*side,y:place.y*side,width:side,height:side)}
            guard rect.intersects(box) else {continue}
            if let image = unit.image {
                context.saveGState();if unit.flags&0x80 != 0 {context.setAlpha(0.58)}
                Renderer.image(image,in:box,context:context);context.restoreGState()
            } else {drawText(unit.name+"\n그림 없음",in:box.insetBy(dx:2,dy:1),color:.white,size:10)}
            let bar = CGRect(x:box.minX+3,y:box.maxY-5,width:box.width-6,height:4)
            context.setFillColor(UIColor.black.withAlphaComponent(0.8).cgColor);context.fill(bar)
            context.setFillColor((unit.enemy ? UIColor.systemRed : UIColor.systemMint).cgColor)
            context.fill(CGRect(x:bar.minX,y:bar.minY,width:bar.width*min(1,max(0,CGFloat(unit.troops)/CGFloat(max(1,unit.maximum)))),height:bar.height))
            if unit.slot == selectedSlot {
                context.setStrokeColor(UIColor.systemYellow.cgColor);context.setLineWidth(3);context.stroke(box.insetBy(dx:2,dy:2))
            }
        }
        drawCues(context,side:side)
    }
    /// Strikes, shots and damage numbers of the action that is playing.
    private func drawCues(_ context:CGContext,side:CGFloat) {
        if let effect = animation.effect,let image = (try? renderer?.effectImage(effect.frame)) ?? nil {
            Renderer.image(image,in:CGRect(x:CGFloat(effect.halfX)*side/2,y:CGFloat(effect.halfY)*side/2,width:side,height:side),context:context)
        }
        if let shot = animation.shot,let image = (try? renderer?.shotImage(shot.frame)) ?? nil {
            let quarter = side/4
            Renderer.image(image,in:CGRect(x:CGFloat(shot.x)*side+quarter,y:CGFloat(shot.y)*side+quarter,width:quarter*2,height:quarter*2),context:context)
        }
        if let number = animation.number,number.visible,let unit = units.first(where:{$0.slot == number.slot}) {
            let box = geometry.rect(unit.point),badge = CGRect(x:box.midX-24,y:box.midY-11,width:48,height:22)
            context.setFillColor(UIColor(red:0.06,green:0.07,blue:0.11,alpha:0.92).cgColor)
            context.addPath(UIBezierPath(roundedRect:badge,cornerRadius:6).cgPath);context.fillPath()
            let recovery = number.color == 15
            drawText(String(number.value),in:badge.offsetBy(dx:0,dy:2),color:recovery ? UIColor.systemMint : UIColor(red:1,green:0.86,blue:0.44,alpha:1),size:15)
        }
    }
    private func drawText(_ text:String,in rect:CGRect,color:UIColor,size:CGFloat) {
        let paragraph = NSMutableParagraphStyle();paragraph.alignment = .center;paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(in:rect,withAttributes:[.font:UIFont.systemFont(ofSize:size,weight:.semibold),.foregroundColor:color,.paragraphStyle:paragraph])
    }
}
