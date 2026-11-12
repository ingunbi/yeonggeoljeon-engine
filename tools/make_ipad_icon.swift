// SPDX-License-Identifier: GPL-3.0-only
// Draws the iPad app icon from vector shapes: crossed swords behind a gold
// character on a night-blue field. Original artwork; no game assets are used.
// Usage: swift tools/make_ipad_icon.swift OUTPUT.png
import AppKit
import CoreGraphics
import CoreText

let side = 1024
guard CommandLine.arguments.count == 2 else { fatalError("usage: make_ipad_icon.swift OUTPUT.png") }
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:0,space:space,
                          bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }
let full = CGRect(x:0,y:0,width:side,height:side)
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat = 1) -> CGColor {CGColor(red:r,green:g,blue:b,alpha:a)}

// Night-blue field with a warm glow behind the middle.
let field = CGGradient(colorsSpace:space,colors:[color(0.10,0.14,0.27),color(0.02,0.03,0.08)] as CFArray,locations:[0,1])!
ctx.drawLinearGradient(field,start:CGPoint(x:512,y:1024),end:CGPoint(x:512,y:0),options:[])
let glow = CGGradient(colorsSpace:space,colors:[color(0.96,0.70,0.30,0.38),color(0.96,0.70,0.30,0)] as CFArray,locations:[0,1])!
ctx.drawRadialGradient(glow,startCenter:CGPoint(x:512,y:520),startRadius:0,endCenter:CGPoint(x:512,y:520),endRadius:520,options:[])

// One sword, point up, then drawn twice at mirrored angles about the centre.
func sword(angle:CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x:512,y:450);ctx.rotate(by:angle)
    let blade = CGMutablePath()
    blade.move(to:CGPoint(x:0,y:480));blade.addLine(to:CGPoint(x:36,y:410))
    blade.addLine(to:CGPoint(x:32,y:-30));blade.addLine(to:CGPoint(x:-32,y:-30));blade.addLine(to:CGPoint(x:-36,y:410));blade.closeSubpath()
    ctx.saveGState()
    ctx.addPath(blade);ctx.clip()
    let steel = CGGradient(colorsSpace:space,colors:[color(0.58,0.64,0.75),color(0.96,0.98,1.0),color(0.58,0.64,0.75)] as CFArray,locations:[0,0.5,1])!
    ctx.drawLinearGradient(steel,start:CGPoint(x:-36,y:0),end:CGPoint(x:36,y:0),options:[])
    ctx.restoreGState()
    ctx.setFillColor(color(0.96,0.79,0.42))
    ctx.fill(CGRect(x:-110,y:-66,width:220,height:36))
    ctx.setFillColor(color(0.55,0.33,0.16))
    ctx.fill(CGRect(x:-17,y:-250,width:34,height:186))
    ctx.setFillColor(color(0.96,0.79,0.42))
    ctx.fillEllipse(in:CGRect(x:-32,y:-296,width:64,height:64))
    ctx.restoreGState()
}
sword(angle:0.75);sword(angle:-0.75)

// A dark medallion over the crossing keeps the character readable.
let medallion = CGRect(x:512-185,y:450-185,width:370,height:370)
ctx.setFillColor(color(0.04,0.06,0.13,1));ctx.fillEllipse(in:medallion)
ctx.setStrokeColor(color(0.96,0.79,0.42));ctx.setLineWidth(14);ctx.strokeEllipse(in:medallion.insetBy(dx:7,dy:7))

// The character 英 in gold.
let font = CTFontCreateWithName("PingFang TC Semibold" as CFString,240,nil)
let attributes:[NSAttributedString.Key:Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String):font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(0.98,0.82,0.45),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string:"英",attributes:attributes))
let bounds = CTLineGetImageBounds(line,ctx)
ctx.textPosition = CGPoint(x:512-bounds.midX,y:450-bounds.midY)
CTLineDraw(line,ctx)

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage:image)
guard let png = rep.representation(using:.png,properties:[:]) else { fatalError("no png") }
try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
