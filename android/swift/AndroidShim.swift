// SPDX-License-Identifier: GPL-3.0-only
// Stand-ins for the Apple frameworks the shared engine sources use, so the
// same sources build for Android: a small CoreGraphics image/context subset,
// SHA-256, a PNG reader and the observable-object markers. Only compiled there.
#if os(Android)
import Foundation
import Android

// MARK: Observable markers (no UI framework observes them on Android)
protocol ObservableObject:AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue:Value
    init(wrappedValue:Value) {self.wrappedValue = wrappedValue}
}

// MARK: CoreGraphics subset
typealias CFData = Data
typealias CFString = String
enum CGImageAlphaInfo:UInt32 {case none = 0,premultipliedLast = 1,premultipliedFirst = 2,last = 3,first = 4,noneSkipLast = 5,noneSkipFirst = 6}
struct CGBitmapInfo:OptionSet {var rawValue:UInt32;init(rawValue:UInt32) {self.rawValue = rawValue}}
enum CGColorRenderingIntent {case defaultIntent}
struct CGColorSpace {}
func CGColorSpaceCreateDeviceRGB() -> CGColorSpace {CGColorSpace()}
final class CGDataProvider {
    let data:Data
    init?(data:Data) {self.data = data}
}
struct CGColor {
    var r:Double,g:Double,b:Double,a:Double
    init<T:BinaryFloatingPoint>(gray:T,alpha:T) {r = Double(gray);g = r;b = r;a = Double(alpha)}
    init<T:BinaryFloatingPoint>(red:T,green:T,blue:T,alpha:T) {r = Double(red);g = Double(green);b = Double(blue);a = Double(alpha)}
}

/// RGBA, premultiplied alpha, first row on top.
final class CGImage {
    let width:Int
    let height:Int
    let pixels:[UInt8]
    init(width:Int,height:Int,pixels:[UInt8]) {self.width = width;self.height = height;self.pixels = pixels}
    init?(width:Int,height:Int,bitsPerComponent:Int,bitsPerPixel:Int,bytesPerRow:Int,space:CGColorSpace,bitmapInfo:CGBitmapInfo,
          provider:CGDataProvider,decode:UnsafePointer<CGFloat>?,shouldInterpolate:Bool,intent:CGColorRenderingIntent) {
        guard bitsPerPixel == 32,bitsPerComponent == 8,width > 0,height > 0,provider.data.count >= bytesPerRow*height else {return nil}
        self.width = width;self.height = height
        if bytesPerRow == width*4 {pixels = [UInt8](provider.data.prefix(width*height*4))}
        else {
            var out = [UInt8](repeating:0,count:width*height*4)
            let bytes = [UInt8](provider.data)
            for row in 0..<height {for i in 0..<width*4 {out[row*width*4+i] = bytes[row*bytesPerRow+i]}}
            pixels = out
        }
    }
    func cropping(to rect:CGRect) -> CGImage? {
        let x0 = Int(rect.minX.rounded()),y0 = Int(rect.minY.rounded()),w = Int(rect.width.rounded()),h = Int(rect.height.rounded())
        guard x0 >= 0,y0 >= 0,w > 0,h > 0,x0+w <= width,y0+h <= height else {return nil}
        var out = [UInt8](repeating:0,count:w*h*4)
        for row in 0..<h {
            let from = ((y0+row)*width+x0)*4
            out.replaceSubrange(row*w*4..<(row+1)*w*4,with:pixels[from..<from+w*4])
        }
        return CGImage(width:w,height:h,pixels:out)
    }
}

enum CGInterpolationQuality {case none,low,medium,high,`default`}
final class CGContext {
    let width:Int
    let height:Int
    private(set) var bytes:[UInt8]
    var interpolationQuality:CGInterpolationQuality = .default
    private var alpha = 1.0
    func setAlpha(_ value:CGFloat) {alpha = Double(value)}
    private struct State {var sx:Double = 1,sy:Double = 1,tx:Double = 0,ty:Double = 0,clip:(x0:Int,y0:Int,x1:Int,y1:Int)? = nil}
    private var state = State()
    private var stack:[State] = []
    private var fillColor = CGColor(gray:0,alpha:1)
    private var strokeColor = CGColor(gray:0,alpha:1)
    private var lineWidth:CGFloat = 1
    /// Pixel memory is exposed through this pointer for the callers that count pixels.
    var data:UnsafeMutableRawPointer? {
        get {
            if scratch == nil {scratch = UnsafeMutableRawPointer.allocate(byteCount:max(1,bytes.count),alignment:4)}
            bytes.withUnsafeBytes {scratch!.copyMemory(from:$0.baseAddress!,byteCount:bytes.count)}
            return scratch
        }
    }
    private var scratch:UnsafeMutableRawPointer?
    deinit {scratch?.deallocate()}
    init?(data:UnsafeMutableRawPointer?,width:Int,height:Int,bitsPerComponent:Int,bytesPerRow:Int,space:CGColorSpace,bitmapInfo:UInt32) {
        guard width > 0,height > 0,bitsPerComponent == 8,bytesPerRow == width*4 else {return nil}
        self.width = width;self.height = height;bytes = [UInt8](repeating:0,count:width*height*4)
    }
    func saveGState() {stack.append(state)}
    func restoreGState() {if let last = stack.popLast() {state = last}}
    func translateBy(x:CGFloat,y:CGFloat) {state.tx += state.sx*Double(x);state.ty += state.sy*Double(y)}
    func scaleBy(x:CGFloat,y:CGFloat) {state.sx *= Double(x);state.sy *= Double(y)}
    func setShouldAntialias(_ value:Bool) {}
    func clip(to rect:CGRect) {
        let box = device(rect)
        if let current = state.clip {state.clip = (max(current.x0,box.x0),max(current.y0,box.y0),min(current.x1,box.x1),min(current.y1,box.y1))}
        else {state.clip = box}
    }
    private func bounds(_ box:(x0:Int,y0:Int,x1:Int,y1:Int)) -> (x0:Int,y0:Int,x1:Int,y1:Int) {
        var out = (x0:max(0,box.x0),y0:max(0,box.y0),x1:min(width,box.x1),y1:min(height,box.y1))
        if let clip = state.clip {out = (max(out.x0,clip.x0),max(out.y0,clip.y0),min(out.x1,clip.x1),min(out.y1,clip.y1))}
        return out
    }
    func setFillColor(_ color:CGColor) {fillColor = color}
    func setStrokeColor(_ color:CGColor) {strokeColor = color}
    func setLineWidth(_ value:CGFloat) {lineWidth = value}
    /// User space has its origin at the bottom left, like CoreGraphics.
    private func device(_ rect:CGRect) -> (x0:Int,y0:Int,x1:Int,y1:Int) {
        let ax = state.sx*Double(rect.minX)+state.tx,bx = state.sx*Double(rect.maxX)+state.tx
        let ay = state.sy*Double(rect.minY)+state.ty,by = state.sy*Double(rect.maxY)+state.ty
        let top = Double(height)-max(ay,by),bottom = Double(height)-min(ay,by)
        return (Int(min(ax,bx).rounded()),Int(top.rounded()),Int(max(ax,bx).rounded()),Int(bottom.rounded()))
    }
    private func blend(_ index:Int,_ r:Double,_ g:Double,_ b:Double,_ a:Double) {
        // Source colour is straight; destination and result are premultiplied.
        let inv = 1-a
        let dr = Double(bytes[index]),dg = Double(bytes[index+1]),db = Double(bytes[index+2]),da = Double(bytes[index+3])
        bytes[index] = UInt8(max(0,min(255,r*a*255+dr*inv)))
        bytes[index+1] = UInt8(max(0,min(255,g*a*255+dg*inv)))
        bytes[index+2] = UInt8(max(0,min(255,b*a*255+db*inv)))
        bytes[index+3] = UInt8(max(0,min(255,a*255+da*inv)))
    }
    func fill(_ rect:CGRect) {fillRegion(rect,fillColor)}
    private func fillRegion(_ rect:CGRect,_ color:CGColor) {
        let box = bounds(device(rect))
        guard box.y0 < box.y1,box.x0 < box.x1 else {return}
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {blend((y*width+x)*4,color.r,color.g,color.b,color.a*alpha)}
        }
    }
    func stroke(_ rect:CGRect) {
        let w = max(1,lineWidth)
        for edge in [CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:w),CGRect(x:rect.minX,y:rect.maxY-w,width:rect.width,height:w),
                     CGRect(x:rect.minX,y:rect.minY,width:w,height:rect.height),CGRect(x:rect.maxX-w,y:rect.minY,width:w,height:rect.height)] {
            fillRegion(edge,strokeColor)
        }
    }
    func draw(_ image:CGImage,in rect:CGRect) {
        guard rect.width > 0,rect.height > 0,state.sx != 0,state.sy != 0 else {return}
        let box = bounds(device(rect))
        guard box.y0 < box.y1,box.x0 < box.x1 else {return}
        for dy in box.y0..<box.y1 {
            for dx in box.x0..<box.x1 {
                let ux = ((Double(dx)+0.5-state.tx)/state.sx-Double(rect.minX))/Double(rect.width)
                let uyUser = (Double(height)-(Double(dy)+0.5)-state.ty)/state.sy
                let v = (Double(rect.maxY)-uyUser)/Double(rect.height)
                let sx = Int(ux*Double(image.width)),sy = Int(v*Double(image.height))
                guard sx >= 0,sx < image.width,sy >= 0,sy < image.height else {continue}
                let s = (sy*image.width+sx)*4,a = Double(image.pixels[s+3])/255*alpha
                guard a > 0 else {continue}
                let d = (dy*width+dx)*4,inv = 1-a
                for c in 0..<3 {bytes[d+c] = UInt8(max(0,min(255,Double(image.pixels[s+c])*alpha+Double(bytes[d+c])*inv)))}
                bytes[d+3] = UInt8(max(0,min(255,a*255+Double(bytes[d+3])*inv)))
            }
        }
    }
    func makeImage() -> CGImage? {CGImage(width:width,height:height,pixels:bytes)}
}

// Text drawing is left to the app's own chrome; these keep the callers compiling.
struct NSColor {
    static let white = NSColor()
    init() {}
    init<T:BinaryFloatingPoint>(white:T,alpha:T) {}
    init<T:BinaryFloatingPoint>(red:T,green:T,blue:T,alpha:T) {}
}
struct NSFont {
    var fontName = "system"
    init() {}
    init?(name:String,size:CGFloat) {}
    static func systemFont(ofSize:CGFloat) -> NSFont {NSFont()}
    enum Weight {case regular,medium,semibold,bold}
    static func monospacedDigitSystemFont(ofSize:CGFloat,weight:Weight) -> NSFont {NSFont()}
}
enum NSLineBreakMode {case byWordWrapping}
enum NSTextAlignment {case left,right,center}
final class NSMutableParagraphStyle {
    var lineBreakMode:NSLineBreakMode = .byWordWrapping
    var alignment:NSTextAlignment = .left
}
extension NSAttributedString.Key {
    static let font = NSAttributedString.Key("NSFont")
    static let foregroundColor = NSAttributedString.Key("NSColor")
    static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
}
extension NSString {
    func draw(in rect:CGRect,withAttributes attributes:[NSAttributedString.Key:Any]?) {}
    func draw(at point:CGPoint,withAttributes attributes:[NSAttributedString.Key:Any]?) {}
}
func UIGraphicsPushContext(_ context:CGContext) {}
func UIGraphicsPopContext() {}

extension URL {
    func startAccessingSecurityScopedResource() -> Bool {true}
    func stopAccessingSecurityScopedResource() {}
}
struct UTType {
    static let png = UTType()
    var identifier:String {"public.png"}
}
final class CGImageDestination {}
func CGImageDestinationCreateWithData(_ data:Any,_ type:String,_ count:Int,_ options:Any?) -> CGImageDestination? {nil}
func CGImageDestinationAddImage(_ destination:CGImageDestination,_ image:CGImage,_ options:Any?) {}
func CGImageDestinationFinalize(_ destination:CGImageDestination) -> Bool {false}

// MARK: Darwin file calls the engine uses for locks and links
enum Darwin {
    static func open(_ path:UnsafePointer<CChar>,_ flags:Int32,_ mode:mode_t) -> Int32 {
        let descriptor = Android.open(path,flags,mode)
        guard descriptor >= 0 else {return descriptor}
        // O_EXLOCK does not exist here; lock the file the same way once it is open.
        if flock(descriptor,LOCK_EX|LOCK_NB) != 0 {let code = errno;Android.close(descriptor);errno = code;return -1}
        return descriptor
    }
    @discardableResult static func close(_ descriptor:Int32) -> Int32 {Android.close(descriptor)}
    static func link(_ source:UnsafePointer<CChar>,_ target:UnsafePointer<CChar>) -> Int32 {Android.link(source,target)}
    static func lstat(_ path:UnsafePointer<CChar>,_ out:UnsafeMutablePointer<stat>) -> Int32 {Android.lstat(path,out)}
}
let O_EXLOCK:Int32 = 0

// MARK: ImageIO (PNG reading only)
struct CGImageSource {let data:Data}
func CGImageSourceCreateWithData(_ data:Data,_ options:Any?) -> CGImageSource? {CGImageSource(data:data)}
func CGImageSourceCreateImageAtIndex(_ source:CGImageSource,_ index:Int,_ options:Any?) -> CGImage? {PNGReader.decode(source.data)}

enum PNGReader {
    static func decode(_ data:Data) -> CGImage? {
        let b = [UInt8](data)
        guard b.count > 33,b[0] == 0x89,b[1] == 0x50 else {return nil}
        var pos = 8,width = 0,height = 0,depth = 0,color = 0,interlace = 0
        var idat:[UInt8] = [],palette:[UInt8] = [],alphaTable:[UInt8] = []
        while pos+8 <= b.count {
            let length = Int(b[pos])<<24|Int(b[pos+1])<<16|Int(b[pos+2])<<8|Int(b[pos+3])
            let type = String(bytes:b[pos+4..<pos+8],encoding:.ascii) ?? "",body = pos+8
            guard body+length <= b.count else {return nil}
            switch type {
            case "IHDR":
                width = Int(b[body])<<24|Int(b[body+1])<<16|Int(b[body+2])<<8|Int(b[body+3])
                height = Int(b[body+4])<<24|Int(b[body+5])<<16|Int(b[body+6])<<8|Int(b[body+7])
                depth = Int(b[body+8]);color = Int(b[body+9]);interlace = Int(b[body+12])
            case "PLTE":palette = Array(b[body..<body+length])
            case "tRNS":alphaTable = Array(b[body..<body+length])
            case "IDAT":idat += b[body..<body+length]
            default:break
            }
            pos = body+length+4
        }
        guard width > 0,height > 0,interlace == 0,idat.count > 6,let raw = inflate(Array(idat.dropFirst(2))) else {return nil}
        let channels = [0:1,2:3,3:1,4:2,6:4][color] ?? 0
        guard channels > 0,[1,2,4,8].contains(depth) || (depth == 16 && color != 3) else {return nil}
        let bitsPerPixel = channels*depth,stride = (width*bitsPerPixel+7)/8,bpp = max(1,bitsPerPixel/8)
        guard raw.count >= (stride+1)*height else {return nil}
        var rows = [UInt8](repeating:0,count:stride*height)
        for y in 0..<height {
            let filter = raw[y*(stride+1)],line = y*(stride+1)+1
            for x in 0..<stride {
                let value = Int(raw[line+x])
                let left = x >= bpp ? Int(rows[y*stride+x-bpp]) : 0
                let up = y > 0 ? Int(rows[(y-1)*stride+x]) : 0
                let upLeft = (y > 0 && x >= bpp) ? Int(rows[(y-1)*stride+x-bpp]) : 0
                var out:Int
                switch filter {
                case 1:out = value+left
                case 2:out = value+up
                case 3:out = value+(left+up)/2
                case 4:
                    let p = left+up-upLeft,pa = abs(p-left),pb = abs(p-up),pc = abs(p-upLeft)
                    out = value+(pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft))
                default:out = value
                }
                rows[y*stride+x] = UInt8(out&255)
            }
        }
        var rgba = [UInt8](repeating:0,count:width*height*4)
        func sample(_ y:Int,_ index:Int) -> Int {
            switch depth {
            case 8:return Int(rows[y*stride+index])
            case 16:return Int(rows[y*stride+index*2])
            default:
                let bit = index*depth,byte = Int(rows[y*stride+bit/8])
                return (byte>>(8-depth-bit%8))&((1<<depth)-1)
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var r = 0,g = 0,bl = 0,a = 255
                switch color {
                case 0:
                    let v = sample(y,x);let scaled = depth >= 8 ? v : v*255/((1<<depth)-1);r = scaled;g = scaled;bl = scaled
                case 2:r = sample(y,x*3);g = sample(y,x*3+1);bl = sample(y,x*3+2)
                case 3:
                    let i = sample(y,x)
                    if palette.count >= i*3+3 {r = Int(palette[i*3]);g = Int(palette[i*3+1]);bl = Int(palette[i*3+2])}
                    if i < alphaTable.count {a = Int(alphaTable[i])}
                case 4:let v = sample(y,x*2);r = v;g = v;bl = v;a = sample(y,x*2+1)
                default:r = sample(y,x*4);g = sample(y,x*4+1);bl = sample(y,x*4+2);a = sample(y,x*4+3)
                }
                let o = (y*width+x)*4
                rgba[o] = UInt8(r*a/255);rgba[o+1] = UInt8(g*a/255);rgba[o+2] = UInt8(bl*a/255);rgba[o+3] = UInt8(a)
            }
        }
        return CGImage(width:width,height:height,pixels:rgba)
    }

    /// RFC 1951 inflate.
    static func inflate(_ input:[UInt8]) -> [UInt8]? {
        var out:[UInt8] = [];out.reserveCapacity(input.count*4)
        var pos = 0,bitBuffer = 0,bitCount = 0
        func bits(_ n:Int) -> Int? {
            while bitCount < n {
                guard pos < input.count else {return nil}
                bitBuffer |= Int(input[pos])<<bitCount;pos += 1;bitCount += 8
            }
            let value = bitBuffer&((1<<n)-1);bitBuffer >>= n;bitCount -= n;return value
        }
        struct Huffman {
            var counts = [Int](repeating:0,count:16),symbols:[Int] = []
            init(lengths:[Int]) {
                for length in lengths {counts[length] += 1}
                counts[0] = 0
                var offsets = [Int](repeating:0,count:16)
                for i in 1..<16 {offsets[i] = offsets[i-1]+counts[i-1]}
                symbols = [Int](repeating:0,count:lengths.count)
                for (symbol,length) in lengths.enumerated() where length != 0 {symbols[offsets[length]] = symbol;offsets[length] += 1}
            }
        }
        func decode(_ h:Huffman) -> Int? {
            var code = 0,first = 0,index = 0
            for length in 1..<16 {
                guard let bit = bits(1) else {return nil}
                code |= bit
                let count = h.counts[length]
                if code-count < first {return h.symbols[index+(code-first)]}
                index += count;first += count;first <<= 1;code <<= 1
            }
            return nil
        }
        let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        let distExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
        var final = false
        while !final {
            guard let last = bits(1),let type = bits(2) else {return nil}
            final = last == 1
            if type == 0 {
                bitBuffer = 0;bitCount = 0
                guard pos+4 <= input.count else {return nil}
                let len = Int(input[pos])|Int(input[pos+1])<<8;pos += 4
                guard pos+len <= input.count else {return nil}
                out += input[pos..<pos+len];pos += len
            } else if type == 1 || type == 2 {
                var lit:Huffman,dist:Huffman
                if type == 1 {
                    var lengths = [Int](repeating:8,count:288)
                    for i in 144..<256 {lengths[i] = 9};for i in 256..<280 {lengths[i] = 7}
                    lit = Huffman(lengths:lengths);dist = Huffman(lengths:[Int](repeating:5,count:30))
                } else {
                    guard let hlit = bits(5),let hdist = bits(5),let hclen = bits(4) else {return nil}
                    let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                    var codeLengths = [Int](repeating:0,count:19)
                    for i in 0..<hclen+4 {guard let v = bits(3) else {return nil};codeLengths[order[i]] = v}
                    let meta = Huffman(lengths:codeLengths)
                    var lengths:[Int] = []
                    while lengths.count < hlit+257+hdist+1 {
                        guard let symbol = decode(meta) else {return nil}
                        if symbol < 16 {lengths.append(symbol)}
                        else {
                            var repeatValue = 0,count = 0
                            if symbol == 16 {guard let last = lengths.last,let n = bits(2) else {return nil};repeatValue = last;count = 3+n}
                            else if symbol == 17 {guard let n = bits(3) else {return nil};count = 3+n}
                            else {guard let n = bits(7) else {return nil};count = 11+n}
                            lengths += [Int](repeating:repeatValue,count:count)
                        }
                    }
                    lit = Huffman(lengths:Array(lengths[0..<hlit+257]));dist = Huffman(lengths:Array(lengths[(hlit+257)..<(hlit+257+hdist+1)]))
                }
                while true {
                    guard let symbol = decode(lit) else {return nil}
                    if symbol < 256 {out.append(UInt8(symbol))}
                    else if symbol == 256 {break}
                    else {
                        let li = symbol-257
                        guard li < 29,let extra = bits(lengthExtra[li]),let ds = decode(dist),ds < 30,let dExtra = bits(distExtra[ds]) else {return nil}
                        let length = lengthBase[li]+extra,distance = distBase[ds]+dExtra
                        guard distance <= out.count else {return nil}
                        for _ in 0..<length {out.append(out[out.count-distance])}
                    }
                }
            } else {return nil}
        }
        return out
    }
}

// MARK: SHA-256 (CryptoKit replacement)
struct SHA256Digest:Sequence {
    let bytes:[UInt8]
    func makeIterator() -> IndexingIterator<[UInt8]> {bytes.makeIterator()}
}
struct SHA256 {
    private var buffer = Data()
    init() {}
    mutating func update(data:Data) {buffer.append(data)}
    func finalize() -> SHA256Digest {SHA256.hash(data:buffer)}
    static func hash(data:Data) -> SHA256Digest {
        let k:[UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var h:[UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var message = [UInt8](data);let bitLength = UInt64(message.count)*8
        message.append(0x80)
        while message.count%64 != 56 {message.append(0)}
        for shift in stride(from:56,through:0,by:-8) {message.append(UInt8((bitLength>>UInt64(shift))&0xff))}
        func rotr(_ x:UInt32,_ n:UInt32) -> UInt32 {(x>>n)|(x<<(32-n))}
        for chunk in stride(from:0,to:message.count,by:64) {
            var w = [UInt32](repeating:0,count:64)
            for i in 0..<16 {
                let o = chunk+i*4
                w[i] = UInt32(message[o])<<24|UInt32(message[o+1])<<16|UInt32(message[o+2])<<8|UInt32(message[o+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15],7)^rotr(w[i-15],18)^(w[i-15]>>3),s1 = rotr(w[i-2],17)^rotr(w[i-2],19)^(w[i-2]>>10)
                w[i] = w[i-16]&+s0&+w[i-7]&+s1
            }
            var a = h[0],b = h[1],c = h[2],d = h[3],e = h[4],f = h[5],g = h[6],hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e,6)^rotr(e,11)^rotr(e,25),ch = (e&f)^(~e&g),t1 = hh&+s1&+ch&+k[i]&+w[i]
                let s0 = rotr(a,2)^rotr(a,13)^rotr(a,22),maj = (a&b)^(a&c)^(b&c),t2 = s0&+maj
                hh = g;g = f;f = e;e = d&+t1;d = c;c = b;b = a;a = t1&+t2
            }
            h[0] = h[0]&+a;h[1] = h[1]&+b;h[2] = h[2]&+c;h[3] = h[3]&+d;h[4] = h[4]&+e;h[5] = h[5]&+f;h[6] = h[6]&+g;h[7] = h[7]&+hh
        }
        var out:[UInt8] = []
        for value in h {for shift in stride(from:24,through:0,by:-8) {out.append(UInt8((value>>UInt32(shift))&0xff))}}
        return SHA256Digest(bytes:out)
    }
}
#endif
