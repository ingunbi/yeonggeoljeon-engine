// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A YM3812 written from the chip's documented behavior: nine two-operator
/// channels, four waveforms, envelopes, vibrato and tremolo. Rhythm mode and
/// the timers are left out because the original music driver never uses them.
final class OPL2Chip {
    static let sampleRate = 49716.0
    private enum Stage:UInt8 { case attack,decay,sustain,release,off }
    private struct Operator {
        var phase:UInt32 = 0
        var envelope:Int32 = 511
        var stage = Stage.off
        var tremolo = false,vibrato = false,sustains = false,keyScale = false
        var multiple:UInt32 = 1
        var level:Int32 = 0,keyLevel:Int32 = 0,keyShift = 0
        var attack:Int32 = 0,decay:Int32 = 0,sustain:Int32 = 0,release:Int32 = 0
        var wave = 0
        var previous:Int32 = 0,older:Int32 = 0
    }
    private struct Channel {
        var fnumber:UInt32 = 0,block:UInt32 = 0
        var key = false,additive = false
        var feedback:Int32 = 0
    }
    private var operators = [Operator](repeating:Operator(),count:18)
    private var channels = [Channel](repeating:Channel(),count:9)
    private var waveforms = false,noteSelect = 0,deepTremolo = false,deepVibrato = false
    private var counter:UInt32 = 0
    private static let levels:[Float] = {
        var table = [Float]()
        table.reserveCapacity(1024)
        for index in 0...1023 {
            let exponent:Float = -Float(index)*0.1875/20
            table.append(powf(10,exponent))
        }
        return table
    }()
    private static let waves:[[Float]] = {
        var sine = [Float]()
        sine.reserveCapacity(1024)
        for index in 0..<1024 {
            let phase:Float = (Float(index)+0.5)*2*Float.pi/1024
            sine.append(sinf(phase))
        }
        var half = [Float](),rectified = [Float](),quarter = [Float]()
        for index in 0..<1024 {
            let value = sine[index]
            half.append(index < 512 ? value : 0)
            rectified.append(abs(value))
            quarter.append(index&256 == 0 ? abs(value) : 0)
        }
        return [sine,half,rectified,quarter]
    }()
    /// Increments per 8-step cycle, by rate row.
    private static let increments:[[Int32]] = [
        [0,1,0,1,0,1,0,1],[0,1,0,1,1,1,0,1],[0,1,1,1,0,1,1,1],[0,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1],[1,1,1,2,1,1,1,2],[1,2,1,2,1,2,1,2],[1,2,2,2,1,2,2,2],
        [2,2,2,2,2,2,2,2],[2,2,2,4,2,2,2,4],[2,4,2,4,2,4,2,4],[2,4,4,4,2,4,4,4],
        [4,4,4,4,4,4,4,4],[8,8,8,8,8,8,8,8]]
    private static let keyLevels:[Int32] = [0,32,40,45,48,51,53,55,56,58,59,60,61,62,63,64]
    private static let keyShifts = [8,1,2,0]
    private static let multiples:[UInt32] = [1,2,4,6,8,10,12,14,16,18,20,20,24,24,30,30]
    /// Register offsets of the two operators per channel.
    private static let offsets = [0,1,2,8,9,10,16,17,18]
    private func slot(_ offset:Int) -> Int? {
        for (channel,base) in Self.offsets.enumerated() {
            if offset == base { return channel*2 }
            if offset == base+3 { return channel*2+1 }
        }
        return nil
    }
    func write(_ register:Int,_ value:Int) {
        let value = value&255
        switch register&0xFF {
        case 0x01:waveforms = value&0x20 != 0
        case 0x08:noteSelect = (value>>6)&1
        case 0xBD:deepTremolo = value&0x80 != 0;deepVibrato = value&0x40 != 0
        case 0x20...0x35:
            guard let index = slot(register-0x20) else { return }
            operators[index].tremolo = value&0x80 != 0;operators[index].vibrato = value&0x40 != 0
            operators[index].sustains = value&0x20 != 0;operators[index].keyScale = value&0x10 != 0
            operators[index].multiple = Self.multiples[value&15]
            update(index/2)
        case 0x40...0x55:
            guard let index = slot(register-0x40) else { return }
            operators[index].level = Int32(value&63)<<2;operators[index].keyShift = Self.keyShifts[value>>6]
            update(index/2)
        case 0x60...0x75:
            guard let index = slot(register-0x60) else { return }
            operators[index].attack = Int32(value>>4);operators[index].decay = Int32(value&15)
        case 0x80...0x95:
            guard let index = slot(register-0x80) else { return }
            operators[index].sustain = value>>4 == 15 ? 496 : Int32(value>>4)<<4
            operators[index].release = Int32(value&15)
        case 0xA0...0xA8:
            let channel = (register&0xFF)-0xA0
            channels[channel].fnumber = (channels[channel].fnumber&0x300)|UInt32(value)
            update(channel)
        case 0xB0...0xB8:
            let channel = (register&0xFF)-0xB0,key = value&0x20 != 0
            channels[channel].fnumber = (channels[channel].fnumber&0xFF)|UInt32(value&3)<<8
            channels[channel].block = UInt32(value>>2)&7
            update(channel)
            if key != channels[channel].key {
                channels[channel].key = key
                for index in [channel*2,channel*2+1] {
                    if key { operators[index].phase = 0;operators[index].stage = .attack }
                    else if operators[index].stage != .off { operators[index].stage = .release }
                }
            }
        case 0xC0...0xC8:
            let channel = (register&0xFF)-0xC0
            channels[channel].additive = value&1 != 0;channels[channel].feedback = Int32(value>>1)&7
        case 0xE0...0xF5:
            guard let index = slot(register-0xE0) else { return }
            operators[index].wave = value&3
        default:break
        }
    }
    private func update(_ channel:Int) {
        let facts = channels[channel]
        let level = (Self.keyLevels[Int(facts.fnumber>>6)]<<2)-(Int32(8-facts.block)<<5)
        for index in [channel*2,channel*2+1] { operators[index].keyLevel = max(0,level)>>Int32(operators[index].keyShift) }
    }
    /// One envelope step on the shared counter; `rate` is the 0...63 effective rate.
    @inline(__always)
    private static func step(_ rate:Int32,_ counter:UInt32,attack:Bool) -> Int32 {
        guard rate >= 4 else { return 0 }
        let high = rate>>2,low = Int(rate&3)
        let shift = high < 12 ? UInt32(12-high) : 0
        guard counter&((1<<shift)-1) == 0 else { return 0 }
        let row:Int
        switch high {
        case ..<12:row = low
        case 12:row = 4+low
        case 13:row = 8+low
        case 14:row = 12
        default:row = attack ? 13 : 12
        }
        return increments[row][Int((counter>>shift)&7)]
    }
    private func advance(_ op:inout Operator,keyRate:Int32) {
        func rate(_ value:Int32) -> Int32 { value == 0 ? 0 : min(63,value*4+keyRate) }
        switch op.stage {
        case .attack:
            let speed = Self.step(rate(op.attack),counter,attack:true)
            if speed > 0 {
                op.envelope += ((-op.envelope-1)*speed)>>3
                if op.envelope <= 0 { op.envelope = 0;op.stage = .decay }
            }
        case .decay:
            op.envelope += Self.step(rate(op.decay),counter,attack:false)
            if op.envelope >= op.sustain { op.envelope = op.sustain;op.stage = .sustain }
        case .sustain:
            if !op.sustains { op.envelope += Self.step(rate(op.release),counter,attack:false) }
        case .release:
            op.envelope += Self.step(rate(op.release),counter,attack:false)
        case .off:break
        }
        if op.envelope >= 511 { op.envelope = 511;if op.stage != .attack { op.stage = .off } }
    }
    /// Advances one operator and returns its output on the chip's 13-bit scale.
    private func output(_ op:inout Operator,_ channel:Channel,modulation:Int32,tremolo:Int32,vibrato:Int32) -> Int32 {
        var fnumber = Int32(channel.fnumber)
        if op.vibrato { fnumber += vibrato*(fnumber>>7)>>2 }
        let keyCode = (channel.block<<1)|((UInt32(fnumber)>>(9-UInt32(noteSelect)))&1)
        advance(&op,keyRate:Int32(keyCode)>>(op.keyScale ? 0 : 2))
        let base = (UInt32(fnumber)<<channel.block)>>1
        let index = (Int32(truncatingIfNeeded:op.phase>>9)&+modulation)&1023
        op.phase = (op.phase&+((base&*op.multiple)>>1))&0x7FFFF
        guard op.stage != .off else { return 0 }
        let attenuation = min(1023,op.envelope+op.level+op.keyLevel+(op.tremolo ? tremolo : 0))
        return Int32(Self.waves[waveforms ? op.wave : 0][Int(index)]*Self.levels[Int(attenuation)]*4095)
    }
    func render(_ buffer:UnsafeMutablePointer<Float>,count:Int) {
        for frame in 0..<count {
            counter &+= 1
            // Vibrato has eight positions, tremolo a triangle of 210 steps.
            let position = (counter>>10)&7
            var vibrato:Int32 = position&3 == 0 ? 0 : position&1 == 1 ? 2 : 4
            if !deepVibrato { vibrato >>= 1 }
            if position&4 != 0 { vibrato = -vibrato }
            let wave = Int32((counter>>6)%210)
            let tremolo = (wave >= 105 ? 209-wave : wave)>>(deepTremolo ? 2 : 4)
            var mix:Int32 = 0
            for index in 0..<9 {
                let channel = channels[index],first = index*2,second = first+1
                if operators[first].stage == .off && operators[second].stage == .off && !channel.key { continue }
                let feedback = channel.feedback == 0 ? 0 : (operators[first].previous+operators[first].older)>>(9-channel.feedback)
                let modulator = output(&operators[first],channel,modulation:feedback,tremolo:tremolo,vibrato:vibrato)
                operators[first].older = operators[first].previous;operators[first].previous = modulator
                if channel.additive {
                    mix += modulator+output(&operators[second],channel,modulation:0,tremolo:tremolo,vibrato:vibrato)
                } else {
                    mix += output(&operators[second],channel,modulation:modulator,tremolo:tremolo,vibrato:vibrato)
                }
            }
            buffer[frame] = Float(mix)/4096*0.28
        }
    }
}
