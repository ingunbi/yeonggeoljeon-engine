// SPDX-License-Identifier: GPL-3.0-only
#if !os(Android)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// The opening and ending programs as flat display operations. `tools/
/// screen_programs.py` transcribes them; this replays them on the same model the
/// source used: a 640x400 indexed canvas, a palette and six 64 KB work buffers.
struct OriginalScreenCatalog:Codable {
    var format:Int
    var opcodes:[String:Int]
    var assets:[[Int]]
    var programs:[String:[[Int]]]
    var source:JSONValue?
    var limitations:[String]?
    static let operations = ["clear","mode","mono","load","copy","fill","put","get","stamp","picture","dissolve","bufmask","bufput","cell",
                             "palette","fade","fadestep","wait","tick","clock","music","musicwait","musicstop","cycle","inputwait"]
    static func load(from root:URL) throws -> (catalog:Self,data:[UInt8]) {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:root.appendingPathComponent("screens.json")))
        guard value.format == 1,Self.operations.enumerated().allSatisfy({ value.opcodes[$0.element] == $0.offset }) else {
            throw EngineError.invalid("Original screen programs do not match this player")
        }
        let data = [UInt8](try Data(contentsOf:root.appendingPathComponent("screens.bin")))
        guard value.assets.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[1] >= 0 && $0[0]+$0[1] <= data.count }) else {
            throw EngineError.invalid("Original screen assets leave their file")
        }
        return (value,data)
    }
}

final class OriginalScreenPlayer {
    enum Action:Equatable { case music(bank:Int,member:Int,loop:Bool),stopMusic(Int) }
    /// A driver tick and a palette step, in centiseconds (SBOPL2 0x255; 20 interrupts).
    static let tick = 5.0*4096/1193182*100
    private static let width = 640,height = 400
    private let ops:[[Int]],assets:[[Int]],data:[UInt8]
    private(set) var pc = 0
    private var canvas = [UInt8](repeating:0,count:width*height)
    private var buffers = [[UInt8]](repeating:[UInt8](repeating:0,count:0x10000),count:6)
    private(set) var palette = [Int](repeating:0,count:48)
    private var mode = 0,mono = (mode:0,foreground:0,background:0)
    private var deadline = 0.0,time = 0.0,now = 0.0
    private var cycleLength = 0.0,cycleNext = 0.0,cycleIndex = 0,cycleList:[[Int]] = []
    private var inputPending = false
    private var dirty = true,cached:CGImage?
    var musicBusy:(()->Bool)?
    var finished:Bool { pc >= ops.count }
    /// Where the script stands, for tests and diagnostics.
    var waitingForInput:Bool { inputPending }
    init(ops:[[Int]],assets:[[Int]],data:[UInt8]) { self.ops = ops;self.assets = assets;self.data = data }

    @discardableResult
    func advance(centiseconds:Double) -> [Action] {
        now += centiseconds
        var actions:[Action] = []
        while pc < ops.count,time <= now {
            guard run(ops[pc],&actions) else { break }
        }
        if !cycleList.isEmpty {
            while cycleNext <= now {
                palette = cycleList[cycleIndex];cycleIndex = (cycleIndex+1)%cycleList.count
                cycleNext += cycleLength;dirty = true
            }
        }
        return actions
    }
    func acceptInput() { if inputPending { inputPending = false;pc += 1 } }
    /// False holds this operation; the caller stops for now.
    private func run(_ op:[Int],_ actions:inout [Action]) -> Bool {
        switch op[0] {
        case 0:mode = 0;canvas = [UInt8](repeating:0,count:canvas.count);dirty = true
        case 1:mode = op[1]
        case 2:mono = (op[1],op[2],op[3])
        case 3:
            let range = assets[op[1]],target = op[2],offset = op[3],count = min(range[1],0x10000-offset)
            buffers[target].withUnsafeMutableBufferPointer { out in
                data.withUnsafeBufferPointer { source in
                    for index in 0..<max(0,count) { out[offset+index] = source[range[0]+index] }
                }
            }
        case 4:
            let count = min(op[5],0x10000-op[2],0x10000-op[4])
            if op[1] == op[3] { let part = Array(buffers[op[3]][op[4]..<op[4]+count]);buffers[op[1]].replaceSubrange(op[2]..<op[2]+count,with:part) }
            else { for index in 0..<count { buffers[op[1]][op[2]+index] = buffers[op[3]][op[4]+index] } }
        case 5:
            let count = min(op[3],0x10000-op[2])
            for index in 0..<max(0,count) { buffers[op[1]][op[2]+index] = UInt8(op[4]&255) }
        case 6:put(x:op[1],y:op[2],w:op[3],h:op[4],buffer:op[5],offset:op[6])
        case 7:get(x:op[1],y:op[2],w:op[3],h:op[4],buffer:op[5],offset:op[6])
        case 8:stamp(x:op[1],y:op[2],w:op[3],h:op[4],buffer:op[5],offset:op[6])
        case 9:picture(x:op[1],y:op[2],w:op[3],h:op[4],asset:op[5])
        case 10:dissolve(w:op[1],h:op[2],step:op[3],target:op[4],offset:op[5],source:op[6],sourceOffset:op[7],block:op[8])
        case 11:bufferMask(target:op[1],width:op[2],x:op[3],y:op[4],w:op[5],h:op[6],source:op[7],offset:op[8])
        case 12:bufferPut(target:op[1],offset:op[2],width:op[3],x:op[4],y:op[5],w:op[6],h:op[7],mode:op[8],source:op[9],sourceOffset:op[10])
        case 13:cell(target:op[1],offset:op[2],mask:op[3],maskOffset:op[4],color:op[5],colorOffset:op[6])
        case 14:palette = Array(op[1...]);dirty = true
        case 15:
            if fadeStep(Array(op[1...])) { time += 4*Self.tick;return true }
        case 16:if fadeStep(Array(op[1...])) { time += 4*Self.tick }
        case 17:deadline += Double(op[1]);time = max(time,deadline)+Self.tick
        case 18:time += Double(op[1])*Self.tick
        case 19:deadline = Double(op[1]);time = deadline;now = deadline
        case 20:actions.append(.music(bank:op[1],member:op[2],loop:op[3] != 0))
        case 21:if musicBusy?() == true { return false }
        case 22:actions.append(.stopMusic(op[1]))
        case 23:
            let values = Array(op[2...])
            cycleList = stride(from:0,to:values.count,by:48).map { Array(values[$0..<$0+48]) }
            cycleLength = Double(op[1]+1)/18.2065*100;cycleIndex = 0;cycleNext = time
        case 24:inputPending = true;return false
        default:throw_()
        }
        pc += 1
        return true
    }
    private func throw_() { pc = ops.count }
    private func fadeStep(_ target:[Int]) -> Bool {
        var changed = false
        for index in 0..<48 where palette[index] != target[index] {
            palette[index] += palette[index] > target[index] ? -1 : 1;changed = true
        }
        if changed { dirty = true }
        return changed
    }
    private func put(x:Int,y:Int,w:Int,h:Int,buffer:Int,offset:Int) {
        let pitch = w/8*4,width = Self.width
        buffers[buffer].withUnsafeBufferPointer { source in
            canvas.withUnsafeMutableBufferPointer { out in
                for row in max(0,-y)..<max(max(0,-y),min(h,Self.height-y)) {
                    let base = offset+row*pitch
                    for column in max(0,-x)..<max(max(0,-x),min(w,width-x)) {
                        let group = base+column/8*4,bit = UInt8(128>>(column%8))
                        guard group+3 < 0x10000 else { continue }
                        var value:UInt8 = 0
                        if source[group]&bit != 0 { value |= 1 }
                        if source[group+1]&bit != 0 { value |= 2 }
                        if source[group+2]&bit != 0 { value |= 4 }
                        if source[group+3]&bit != 0 { value |= 8 }
                        let at = (y+row)*width+x+column
                        switch mode {
                        case 3:out[at] |= value
                        case 4:if value != 0 { out[at] = value }
                        default:out[at] = value
                        }
                    }
                }
            }
        }
        dirty = true
    }
    private func get(x:Int,y:Int,w:Int,h:Int,buffer:Int,offset:Int) {
        let pitch = w/8*4,width = Self.width
        canvas.withUnsafeBufferPointer { screen in
            buffers[buffer].withUnsafeMutableBufferPointer { out in
                for row in 0..<h {
                    for group in 0..<w/8 {
                        var planes:(UInt8,UInt8,UInt8,UInt8) = (0,0,0,0)
                        for bit in 0..<8 {
                            let px = x+group*8+bit,py = y+row
                            guard (0..<width).contains(px),(0..<Self.height).contains(py) else { continue }
                            let value = screen[py*width+px],mark = UInt8(128>>bit)
                            if value&1 != 0 { planes.0 |= mark }
                            if value&2 != 0 { planes.1 |= mark }
                            if value&4 != 0 { planes.2 |= mark }
                            if value&8 != 0 { planes.3 |= mark }
                        }
                        let at = offset+row*pitch+group*4
                        guard at+3 < 0x10000 else { continue }
                        out[at] = planes.0;out[at+1] = planes.1;out[at+2] = planes.2;out[at+3] = planes.3
                    }
                }
            }
        }
    }
    private func stamp(x:Int,y:Int,w:Int,h:Int,buffer:Int,offset:Int) {
        let pitch = (w+7)/8,width = Self.width,state = mono
        buffers[buffer].withUnsafeBufferPointer { source in
            canvas.withUnsafeMutableBufferPointer { out in
                for row in max(0,-y)..<max(max(0,-y),min(h,Self.height-y)) {
                    for column in max(0,-x)..<max(max(0,-x),min(w,width-x)) {
                        let byte = offset+row*pitch+column/8
                        guard byte < 0x10000 else { continue }
                        let set = source[byte]&UInt8(128>>(column%8)) != 0,at = (y+row)*width+x+column
                        let value = UInt8((set ? state.foreground : state.background)&255)
                        switch state.mode {
                        case 0:out[at] = value
                        case 2:out[at] &= value
                        case 3:out[at] |= value
                        case 4:if set { out[at] = value }
                        default:break
                        }
                    }
                }
            }
        }
        dirty = true
    }
    private func picture(x:Int,y:Int,w:Int,h:Int,asset:Int) {
        let start = assets[asset][0],width = Self.width
        for row in max(0,-y)..<max(max(0,-y),min(h,Self.height-y)) {
            for column in max(0,-x)..<max(max(0,-x),min(w,width-x)) {
                canvas[(y+row)*width+x+column] = data[start+row*w+column]
            }
        }
        dirty = true
    }
    /// END 0:8642 and OPEN 0x8EDE: planes keep `mask`, the rest comes from source.
    private func dissolve(w:Int,h:Int,step:Int,target:Int,offset:Int,source:Int,sourceOffset:Int,block:Int) {
        let pitch = w/8*4
        let phase = block == 4 ? (step*7)%16 : (step*0x17)%64
        let column = phase%block,first = phase/block
        let spread:UInt16 = block == 4 ? 0x8888 : 0x8080
        let mask = ~(spread>>UInt16(column))
        let from = buffers[source]
        buffers[target].withUnsafeMutableBufferPointer { out in
            for row in 0..<h/block {
                let line = (row*block+first)*pitch
                for index in stride(from:0,to:pitch,by:2) {
                    let a = offset+line+index,b = sourceOffset+line+index
                    guard a+1 < 0x10000,b+1 < 0x10000 else { continue }
                    let low = UInt8(mask&255),high = UInt8(mask>>8)
                    out[a] = out[a] & low | from[b] & ~low
                    out[a+1] = out[a+1] & high | from[b+1] & ~high
                }
            }
        }
    }
    private func bufferMask(target:Int,width:Int,x:Int,y:Int,w:Int,h:Int,source:Int,offset:Int) {
        let row = (w+7)/8
        for line in 0..<h {
            for index in 0..<row {
                let mask = buffers[source][offset+line*row+index]
                let at = ((y+line)*(width/8)+x/8+index)*4
                for plane in 0..<4 where at+plane < 0x10000 { buffers[target][at+plane] &= mask }
            }
        }
    }
    private func bufferPut(target:Int,offset:Int,width:Int,x:Int,y:Int,w:Int,h:Int,mode:Int,source:Int,sourceOffset:Int) {
        let row = (w+7)/8
        for line in 0..<h {
            for index in 0..<row {
                let from = sourceOffset+(line*row+index)*4,at = offset+((y+line)*(width/8)+x/8+index)*4
                guard from+3 < 0x10000,at+3 < 0x10000 else { continue }
                let c = (buffers[source][from],buffers[source][from+1],buffers[source][from+2],buffers[source][from+3])
                let keep:UInt8 = mode == 4 ? ~(c.0|c.1|c.2|c.3) : 0
                buffers[target][at] = buffers[target][at]&keep|c.0
                buffers[target][at+1] = buffers[target][at+1]&keep|c.1
                buffers[target][at+2] = buffers[target][at+2]&keep|c.2
                buffers[target][at+3] = buffers[target][at+3]&keep|c.3
            }
        }
    }
    /// One 16x16 sprite through its mask, as END 0x7380 builds them.
    private func cell(target:Int,offset:Int,mask:Int,maskOffset:Int,color:Int,colorOffset:Int) {
        for line in 0..<32 {
            let keep = buffers[mask][maskOffset+line]
            for plane in 0..<4 {
                let at = offset+line*4+plane
                buffers[target][at] = buffers[target][at]&keep|buffers[color][colorOffset+line*4+plane]
            }
        }
    }
    /// Six-bit VGA output from the four-bit stored channels, in the source's byte order.
    static func colors(_ palette:[Int]) -> [UInt32] {
        func channel(_ value:Int) -> UInt32 {
            let dac = value*4+value/4
            return UInt32((dac*4+dac/16)&255)
        }
        return stride(from:0,to:48,by:3).map { channel(palette[$0+1])|channel(palette[$0+2])<<8|channel(palette[$0])<<16|0xFF00_0000 }
    }
    func image() -> CGImage? {
        guard dirty || cached == nil else { return cached }
        let colors = Self.colors(palette)
        var pixels = [UInt32](repeating:0,count:canvas.count)
        for index in canvas.indices { pixels[index] = colors[Int(canvas[index]&15)] }
        let bytes = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data:bytes) else { return nil }
        cached = CGImage(width:Self.width,height:Self.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:Self.width*4,space:CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
        dirty = false
        return cached
    }
}
