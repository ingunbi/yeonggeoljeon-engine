// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

/// MAIN's own text (research/original-main-font.md). CF5:0D44 reads one glyph
/// per character: a Hangul record in ALL_FONT.16P is a two-byte identity and
/// fourteen two-byte rows, a one-byte code has sixteen rows in HANKAKU.FNT.
/// A cell's top-left is (8·column, y); there is no bold.
struct OriginalFont {
    static let hangulPath = "fonts/ALL_FONT.16P",asciiPath = "fonts/HANKAKU.FNT"
    private static let record = 30,records = 3478
    let hangul:Data
    let ascii:Data
    init(hangul:Data,ascii:Data) throws {
        guard hangul.count == Self.record*Self.records,ascii.count == 96*16 else {
            throw EngineError.invalid("MAIN font files do not have the examined record counts")
        }
        self.hangul = hangul;self.ascii = ascii
    }
    /// Nil when a data set predates the font export.
    static func load(_ data:DataSet) -> OriginalFont? {
        guard let hangul = try? data.containedFile(hangulPath),let ascii = try? data.containedFile(asciiPath),
              let h = try? Data(contentsOf:hangul),let a = try? Data(contentsOf:ascii) else { return nil }
        return try? OriginalFont(hangul:h,ascii:a)
    }
    /// The CP949 bytes MAIN keeps for a decoded string.
    static func bytes(_ text:String) -> [UInt8] {
        let encoding = String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        return Array(text.data(using:encoding,allowLossyConversion:true) ?? Data())
    }
    /// CF5:0A2E for printable text: leads A1..C8 take a trail A1..FE; any other
    /// byte is a one-byte code. Control bytes draw nothing and do not advance.
    static func cells(_ bytes:[UInt8]) -> [(column:Int,code:Int)] {
        var result:[(column:Int,code:Int)] = [],column = 0,lead:UInt8? = nil
        for byte in bytes {
            if let high = lead {
                lead = nil
                if (0xA1...0xFE).contains(byte) { result.append((column,Int(high)<<8|Int(byte)));column += 2;continue }
                result.append((column,Int(byte)));column += 1;continue
            }
            if (0xA1...0xC8).contains(byte) { lead = byte;continue }
            if byte < 0x20 { continue }
            result.append((column,Int(byte)));column += 1
        }
        return result
    }
    /// Columns a string advances (8 pixels each).
    static func columns(_ text:String) -> Int { cells(bytes(text)).last.map { $0.column+($0.code > 0xFF ? 2 : 1) } ?? 0 }
    /// Rows of one glyph, bit 15 leftmost: fourteen 16-pixel rows for a
    /// syllable (index at CF5:0D16), sixteen 8-pixel rows otherwise.
    func rows(_ code:Int) -> [UInt16] {
        if code > 0xFF {
            let high = code>>8,low = code&0xFF
            guard (0xA1A1...0xFDFE).contains(code),(0xA1...0xFE).contains(low) else { return Array(repeating:0,count:14) }
            let index = (high-(high >= 0xB0 ? 0xA4 : 0xA1))*94+low-0xA1,start = index*Self.record+2
            guard index >= 0,start+28 <= hangul.count else { return Array(repeating:0,count:14) }
            return (0..<14).map { UInt16(hangul[start+2*$0])<<8 | UInt16(hangul[start+2*$0+1]) }
        }
        let index = (0x20...0x7F).contains(code) ? code-0x20 : 0
        return (0..<16).map { UInt16(ascii[index*16+$0])<<8 }
    }
    /// Mode 4: set pixels take the colour and the rest stays clear.
    func picture(_ text:String,red:UInt8,green:UInt8,blue:UInt8) -> CGImage? {
        let cells = Self.cells(Self.bytes(text))
        guard let last = cells.last else { return nil }
        let width = 8*(last.column+(last.code > 0xFF ? 2 : 1)),height = 16
        var pixels = [UInt8](repeating:0,count:width*height*4)
        for cell in cells {
            let wide = cell.code > 0xFF
            for (row,bits) in rows(cell.code).enumerated() {
                for bit in 0..<(wide ? 16 : 8) where bits & (0x8000>>UInt16(bit)) != 0 {
                    let at = (row*width+cell.column*8+bit)*4
                    pixels[at] = red;pixels[at+1] = green;pixels[at+2] = blue;pixels[at+3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                       space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}
