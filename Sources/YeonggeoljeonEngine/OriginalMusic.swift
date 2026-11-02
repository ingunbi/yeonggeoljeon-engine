// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Local music data exported by tools/prepare_music.py.
struct OriginalMusicCatalog:Codable {
    struct Tables:Codable { var fnumbers:[Int]; var bends:[Int]; var depths:[Int]; var randomSeed:Int }
    struct Song:Codable { var member:Int; var offset:Int; var size:Int; var data:String }
    var format:Int
    var tables:Tables
    var songs:[Song]
    var opening:[Song]
    var ending:[Song]
    var source:JSONValue?
    var limitations:[String]?
    static func load(from url:URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard value.format == 1,value.tables.fnumbers.count == 12,value.tables.bends.count == 13,value.tables.depths.count == 16,!value.songs.isEmpty else {
            throw EngineError.invalid("Original music catalog does not match its examined shape")
        }
        return value
    }
    func song(_ index:Int) -> [UInt8]? {
        guard songs.indices.contains(index),let data = Data(base64Encoded:songs[index].data) else { return nil }
        return [UInt8](data)
    }
}

/// SBOPL2.COM's track interpreter (0x30E..0x113F). Each slot of 0x30 bytes
/// becomes a `Slot`, and every OPL register write goes through `write`.
final class OriginalMusicDriver {
    private struct Slot {
        var position = 0,loop = 0
        var flags:UInt8 = 1,volume:UInt8 = 0,lastNote:UInt8 = 0xFF
        var step:UInt8 = 0x30,gate:UInt8 = 0x2D,stepCount:UInt8 = 1,gateCount:UInt8 = 0
        var repeatCount:UInt8 = 0,repeatStart = 0,repeatEnd = 0
        var frequency:UInt16 = 0
        var levels:[UInt8] = [0,0],tremolo:[UInt8] = [0,0]
        var instrument:Int? = nil
        var transpose:Int8 = 0
        var mode:UInt8 = 0
        var speed:UInt16 = 0,depth:UInt16 = 0,counter:UInt16 = 0
        var direction:Int16 = 1,value:Int16 = 0
        // These survive a slot reset (the source clears only 0x26 bytes).
        var keyScale:[UInt8] = [0x3F,0x3F]
        var low:UInt8 = 0,high:UInt8 = 0
        var volumeOffset:UInt8 = 0
        var noteOffset:Int8 = 0
        var releaseCount:UInt8 = 0
    }
    private static let channels = 9,tracks = 7
    private static let operators = [0,1,2,8,9,10,16,17,18]
    private let tables:OriginalMusicCatalog.Tables
    private let write:(Int,Int) -> Void
    private var song:[UInt8] = []
    private var slots = [Slot](repeating:Slot(),count:OriginalMusicDriver.channels)
    private(set) var playing = false
    var loops = true
    private var tempo:UInt8 = 0,tempoStep:UInt16 = 0,accumulator:UInt16 = 0,effectPhase:UInt8 = 0
    private var fadeLength:UInt8 = 0,fadePhase:UInt8 = 0,fadeStep:UInt8 = 0,fadeLevel:UInt8 = 0
    private var freeCounter:UInt16 = 0,random:UInt16
    private var chipFlags:UInt8 = 0
    private(set) var ticks = 0
    /// IRQ0 rate after the driver sets the PIT divisor to 0x1000.
    static let interruptRate = 1_193_182.0/4096

    init(tables:OriginalMusicCatalog.Tables,write:@escaping (Int,Int) -> Void) {
        self.tables = tables;self.write = write;random = UInt16(truncatingIfNeeded:tables.randomSeed)
        // 0x115A enables waveform select and note select.
        write(0x01,0x20);write(0x08,0x40);write(0xBD,0)
        for channel in 0..<Self.channels { silence(channel) }
    }
    private func silence(_ channel:Int) {
        let op = Self.operators[channel]
        slots[channel].low = 0;slots[channel].high = 0
        write(0xA0+channel,0);write(0xB0+channel,0)
        write(0x80+op,0x0F);write(0x83+op,0x0F)
        write(0x40+op,0x3F);write(0x43+op,0x3F)
        slots[channel].keyScale = [0x3F,0x3F]
        slots[channel].flags &= 0x1F;slots[channel].mode &= 0xBF;slots[channel].releaseCount = 0
    }
    private func reset(_ channel:Int) {
        let old = slots[channel]
        var fresh = Slot()
        fresh.keyScale = old.keyScale;fresh.low = old.low;fresh.high = old.high
        fresh.volumeOffset = old.volumeOffset;fresh.noteOffset = old.noteOffset;fresh.releaseCount = 0
        slots[channel] = fresh
    }
    /// API 01: 0x30E preceded by the stop at 0x93E.
    func play(_ data:[UInt8]) {
        stop()
        guard data.count >= Self.tracks*2 else { return }
        song = data;ticks = 0;fadeLength = 0;fadePhase = 0;fadeStep = 0;fadeLevel = 0
        for track in 0..<Self.tracks {
            reset(track)
            let start = Int(data[track*2])|Int(data[track*2+1])<<8
            slots[track].position = start;slots[track].loop = start
        }
        chipFlags = 0;write(0xBD,0)
        setTempo(0x78);playing = true
    }
    func stop() {
        playing = false;fadeLength = 0;fadeLevel = 0
        for track in 0..<Self.tracks { silence(track);slots[track].position = 0 }
        tempoStep = 0;tempo = 0
    }
    /// API 02 with a length: 0x10A0 eases the volume out every fourth step.
    func fade(_ length:UInt8) { if length == 0 { stop() } else { fadeLength = length } }
    private func setTempo(_ value:UInt8) {
        guard value != 0 else { return }
        tempo = value
        tempoStep = UInt16(truncatingIfNeeded:UInt32(value)*0x464E/100);accumulator = 0
    }
    /// One timer interrupt. Music ticks and effect ticks run on separate fractions.
    func interrupt() {
        let (sum,carry) = accumulator.addingReportingOverflow(tempoStep)
        accumulator = sum
        if carry { musicTick() }
        let (phase,over) = effectPhase.addingReportingOverflow(0x36)
        effectPhase = phase
        if over { effectTick() }
    }
    private func musicTick() {
        guard playing else { return }
        var alive = false
        for track in 0..<Self.tracks {
            advance(track)
            if slots[track].position != 0 { alive = true }
        }
        ticks += 1
        if !alive { playing = false;tempoStep = 0;tempo = 0 }
    }
    private func advance(_ channel:Int) {
        guard slots[channel].position != 0 else { return }
        slots[channel].stepCount &-= 1
        if slots[channel].stepCount == 0 {
            slots[channel].position = events(channel,from:slots[channel].position)
            slots[channel].flags &= 0xFE
        } else if slots[channel].gateCount != 0 {
            slots[channel].gateCount -= 1
            if slots[channel].gateCount == 0 { keyOff(channel) }
        }
    }
    private func byte(_ position:inout Int) -> UInt8 {
        guard song.indices.contains(position) else { position = 0;return 0xFF }
        defer { position += 1 }
        return song[position]
    }
    /// 0xCF1: commands until a note or the end of the track.
    private func events(_ channel:Int,from start:Int) -> Int {
        var si = start
        while si != 0 {
            let code = byte(&si)
            switch code {
            case 0...0x5F:
                let step = byte(&si),gate = byte(&si)
                slots[channel].step = step;slots[channel].gate = gate
                note(channel,code,gate)
                return si
            case 0x60...0xBF:
                note(channel,code-0x60,slots[channel].gate)
                return si
            case 0xD0...0xDF:repeatMark(channel,code&15,&si)
            case 0xE0...0xED,0xF3:si += 1
            case 0xEE:
                chipFlags = (byte(&si)&1)<<7|(chipFlags&0x7F);write(0xBD,Int(chipFlags))
            case 0xEF:
                chipFlags = (byte(&si)&1)<<6|(chipFlags&0xBF);write(0xBD,Int(chipFlags))
            case 0xF0:
                let volume = byte(&si)&0x7F
                slots[channel].volume = volume;applyVolume(channel,volume)
            case 0xF1:
                // 0xAF7: a timer style value turned into beats per minute.
                let value = UInt32(UInt8(~byte(&si)))+1
                setTempo(UInt8(truncatingIfNeeded:0x1312D/(value*0x12)))
            case 0xF2:
                let value = byte(&si)
                if channel < 7 || channel == 9 { setTempo(value) }
            case 0xF4:
                let low = Int(byte(&si)),high = Int(byte(&si))
                setInstrument(channel,(si+(low|high<<8)-3)&0xFFFF)
            case 0xF5:si += 2
            case 0xF6:
                let interval = byte(&si),raw = byte(&si)
                let length = (raw == 0 ? 256 : UInt32(raw))*0x4E2/(UInt32(max(tempo,1))<<4)
                portamento(channel,interval,max(1,UInt16(truncatingIfNeeded:length)))
            case 0xF7:
                let interval = byte(&si),length = UInt16(byte(&si))+1
                portamento(channel,interval,length)
            case 0xF8:
                if slots[channel].mode&0x80 == 0 {
                    slots[channel].flags |= 8
                    if slots[channel].flags&4 != 0 { slots[channel].mode |= 0x83 }
                }
            case 0xF9:
                if slots[channel].mode&0x80 != 0 {
                    slots[channel].flags &= 0xF7;slots[channel].mode &= 0x7F
                    if slots[channel].flags&0xC0 != 0 { restorePitch(channel) }
                }
            case 0xFD:
                if slots[channel].repeatCount == 1 {
                    slots[channel].repeatCount = 0;slots[channel].repeatStart = 0;si = slots[channel].repeatEnd
                }
            case 0xFE:slots[channel].loop = si
            case 0xFF:
                keyOff(channel);si = 0
                if channel < Self.tracks,loops,slots[channel].flags&1 == 0 {
                    slots[channel].step = 0x30;slots[channel].gate = 0x2D;slots[channel].stepCount = 1
                    slots[channel].gateCount = 0;slots[channel].repeatCount = 0;slots[channel].repeatStart = 0
                    si = slots[channel].loop
                }
            default:break
            }
        }
        return 0
    }
    /// 0xA3E: D0 opens a repeat; D1..DF close it with that many extra passes.
    private func repeatMark(_ channel:Int,_ count:UInt8,_ si:inout Int) {
        guard count != 0 else {
            if slots[channel].repeatStart == 0 { slots[channel].repeatStart = si }
            return
        }
        let start = slots[channel].repeatStart
        guard start != 0 else { return }
        if slots[channel].repeatCount == 0 { slots[channel].repeatCount = count+1;slots[channel].repeatEnd = si }
        slots[channel].repeatCount -= 1
        if slots[channel].repeatCount != 0 { si = start } else { slots[channel].repeatStart = 0 }
    }
    private func keyOn(_ channel:Int) {
        if slots[channel].volumeOffset&0x80 == 0 {
            slots[channel].high |= 0x20
            write(0xB0+channel,Int(slots[channel].high))
            slots[channel].flags |= 0xC0;slots[channel].mode |= 3
        }
        slots[channel].releaseCount = 0
    }
    private func keyOff(_ channel:Int) {
        slots[channel].high &= 0xDF
        write(0xB0+channel,Int(slots[channel].high))
        slots[channel].flags &= 0x5F;slots[channel].mode &= 0xBF;slots[channel].releaseCount = 0xFF
    }
    /// 0x8D2: writes the pitch only when it changed.
    private func setFrequency(_ channel:Int,_ value:UInt16) {
        let old = UInt16(slots[channel].low)|UInt16(slots[channel].high&0xDF)<<8
        let new = value&0xDFFF
        guard old != new else { return }
        slots[channel].low = UInt8(value&255)
        write(0xA0+channel,Int(slots[channel].low))
        slots[channel].high = (slots[channel].high&0x20)|UInt8((new>>8)&255)
        write(0xB0+channel,Int(slots[channel].high))
    }
    /// 0xD31: a note with its gate, or a rest when the gate is zero.
    private func note(_ channel:Int,_ pitch:UInt8,_ gate:UInt8) {
        if gate == 0 {
            slots[channel].lastNote = 0xFF
            if slots[channel].flags&0x80 != 0 { keyOff(channel) }
        } else {
            let value = Int(pitch)+Int(slots[channel].transpose)+Int(slots[channel].noteOffset)
            var octave = value/12,semitone = value%12
            var written = UInt8(truncatingIfNeeded:value)
            if value >= 0 {
                if octave > 7 { octave = 7;written = UInt8(truncatingIfNeeded:semitone+0x54) }
            } else {
                octave = 0
                if semitone != 0 { semitone += 12 }
                written = UInt8(truncatingIfNeeded:semitone)
            }
            let tied = slots[channel].flags&0x20 != 0
            if !(tied && written == slots[channel].lastNote) {
                if !tied && slots[channel].flags&0x80 != 0 { keyOff(channel) }
                slots[channel].lastNote = written
                let frequency = UInt16(tables.fnumbers[semitone])|UInt16(octave)<<10
                setFrequency(channel,frequency)
                slots[channel].frequency = frequency
                if !tied { keyOn(channel) }
                slots[channel].mode &= 0xBF
            }
            if slots[channel].flags&2 != 0 { slots[channel].mode |= 0x40 }
        }
        slots[channel].stepCount = slots[channel].step;slots[channel].gateCount = slots[channel].gate
        slots[channel].flags &= 0xDD
        if slots[channel].gate > slots[channel].step { slots[channel].flags |= 0x20 }
    }
    /// 0x8A2: the operator level with the tremolo share taken off.
    private func applyLevel(_ channel:Int,_ op:Int,_ level:UInt8) {
        let inverted = UInt16(~level&0x3F)
        let share = inverted*UInt16(slots[channel].tremolo[op])/0x7F
        let kept = inverted >= share ? inverted-share : 0
        let current = slots[channel].keyScale[op]
        let value = (~UInt8(kept)&0x3F)|(current&0xC0)
        guard value != current else { return }
        slots[channel].keyScale[op] = value
        write(0x40+Self.operators[channel]+op*3,Int(value))
    }
    /// 0xA76: note volume on top of the instrument's own level.
    private func applyVolume(_ channel:Int,_ volume:UInt8) {
        var value = min(Int(volume)+Int(slots[channel].volumeOffset&0x7F),0x7F)
        if channel < Self.tracks {
            let fade = fadeLevel >= 0x80 ? fadeLevel-0x40 : fadeLevel>>1
            value = min(value+Int(fade),0x7F)
        }
        let share = UInt8(value>>1)
        guard let at = slots[channel].instrument,song.indices.contains(at+6) else { return }
        var connection = song[at+2]|2
        for op in 0..<2 {
            var level = song[at+5+op]&0x3F
            if connection&1 != 0 { level = min(level+share,0x3F) }
            connection >>= 1
            slots[channel].levels[op] = level
            applyLevel(channel,op,level)
        }
    }
    private func refreshVolume(_ channel:Int) {
        slots[channel].tremolo = [0,0]
        applyVolume(channel,slots[channel].volume)
    }
    /// 0xB18: reloads every operator register from the instrument record.
    private func setInstrument(_ channel:Int,_ at:Int) {
        guard song.indices.contains(at+0x15) else { return }
        slots[channel].instrument = at
        silence(channel)
        let op = Self.operators[channel]
        write(0x20+op,Int(song[at]));write(0x23+op,Int(song[at+1]))
        write(0xC0+channel,Int(song[at+2]))
        write(0xE0+op,Int(song[at+3]));write(0xE3+op,Int(song[at+4]))
        write(0x40+op,Int(song[at+5]));write(0x43+op,Int(song[at+6]))
        write(0x60+op,Int(song[at+7]));write(0x63+op,Int(song[at+8]))
        write(0x80+op,Int(song[at+9]));write(0x83+op,Int(song[at+10]))
        slots[channel].keyScale = [song[at+5],song[at+6]]
        slots[channel].transpose = Int8(bitPattern:song[at+11])
        slots[channel].mode &= 0x7F;slots[channel].flags &= 0xFB
        if song[at+0x15] != 0 {
            slots[channel].flags |= 4
            if slots[channel].flags&8 != 0 {
                slots[channel].mode |= 0x80
                slots[channel].counter = 0;slots[channel].value = 0;slots[channel].direction = 1
            }
        }
        refreshVolume(channel)
    }
    private func portamento(_ channel:Int,_ interval:UInt8,_ length:UInt16) {
        slots[channel].speed = UInt16(0x8000/UInt32(length))
        slots[channel].mode &= 0xFB
        var distance = Int(Int8(bitPattern:interval))
        if distance < 0 { distance = -distance;slots[channel].mode |= 4 }
        if distance > 12 { distance = 0 }
        slots[channel].depth = UInt16(tables.bends[distance])
        slots[channel].value = 0;slots[channel].counter = 0;slots[channel].direction = 1
        slots[channel].flags |= 2
        restorePitch(channel)
    }
    private func restorePitch(_ channel:Int) {
        setFrequency(channel,slots[channel].frequency)
        refreshVolume(channel)
    }
    /// 0xE52: moves the value; a sign change is undone and reported.
    private func stepValue(_ channel:Int) -> (value:Int16,crossed:Bool) {
        let delta = Int16(truncatingIfNeeded:Int32(Int16(bitPattern:slots[channel].speed))*Int32(slots[channel].direction))
        let old = slots[channel].value,new = old&+delta
        if (old^new) < 0 { return (old,true) }
        slots[channel].value = new
        return (new,false)
    }
    /// 0xF02: one sample of the instrument's wave.
    private func wave(_ channel:Int,_ kind:UInt8) -> Int16 {
        var result:Int16
        switch kind {
        case 1:
            let period = 0x7FFF/UInt32(max(slots[channel].speed,1))
            let index = period == 0 ? 0 : UInt32(slots[channel].counter)/period
            slots[channel].value = index&1 == 0 ? 0x7FFF : Int16.min
            result = slots[channel].value
        case 2:
            let delta = Int16(truncatingIfNeeded:Int32(Int16(bitPattern:slots[channel].speed&*2))*Int32(slots[channel].direction))
            let old = slots[channel].value,new = old&+delta
            slots[channel].value = new
            if (old^new) < 0,(slots[channel].direction^new) < 0 {
                slots[channel].value = old;slots[channel].direction = -slots[channel].direction
            }
            result = slots[channel].value
        case 3:
            let period = Int32(0x7FFF/UInt32(max(slots[channel].speed,1)))|1
            if Int32(Int16(bitPattern:slots[channel].counter))%period == 0 {
                random = UInt16(bitPattern:Int16(truncatingIfNeeded:(Int32(Int16(bitPattern:random))*0x383)%0x7FFF))
            }
            result = Int16(bitPattern:random)
        case 4:
            result = oneShot(channel)
        default:
            let step = stepValue(channel)
            if step.crossed { slots[channel].value = 0&-slots[channel].value }
            result = step.value
        }
        if result == Int16.min { result += 1 }
        return result
    }
    /// 0xE98: runs once to full scale and stays there.
    private func oneShot(_ channel:Int) -> Int16 {
        guard slots[channel].value != 0x7FFF else { return 0x7FFF }
        let step = stepValue(channel)
        if step.crossed { slots[channel].value = 0x7FFF;return 0x7FFF }
        return step.value
    }
    /// 0xF2A: bends the note by a signed share of its depth.
    @discardableResult private func bend(_ channel:Int,_ amount:Int16) -> UInt16 {
        let base = slots[channel].frequency
        var block = base&0x1C00
        let fnumber = UInt32(base&0x3FF),depth = UInt32(slots[channel].depth)
        var result:UInt32
        if amount >= 0 {
            result = (fnumber*UInt32(amount)/0x7FFF)*depth/0x7FFF+fnumber
            while result > 0x3FF {
                if block >= 0x1C00 { block = 0x1C00;result = 0x3FF;break }
                block += 0x400;result >>= 1
            }
        } else {
            let scaled = UInt32(UInt16(truncatingIfNeeded:-Int32(amount)))*depth/0x7FFF
            result = fnumber*0x7FFF/(scaled+0x7FFF)
        }
        let value = UInt16(truncatingIfNeeded:result)|block
        setFrequency(channel,value)
        return value
    }
    /// 0xF91: tremolo share per operator.
    private func tremolo(_ channel:Int,_ sample:Int16,_ at:Int) {
        let kind = song[at+0xE]
        var ax = sample
        switch kind {
        case 1:ax = sample < 0 ? -1 : 0
        case 2:ax = Int16(truncatingIfNeeded:abs(Int32(sample)))&<<1
        case 4:ax = sample&<<1
        default:break
        }
        let raw = Int8(bitPattern:song[at+0x11])
        let amount = UInt32(UInt8(truncatingIfNeeded:abs(Int(raw))))&0x7F
        let word = raw < 0 ? ~UInt16(bitPattern:ax) : UInt16(bitPattern:ax)
        let scaled = UInt32(word)*amount/0xFFFE
        for op in 0..<2 {
            slots[channel].tremolo[op] = UInt8(truncatingIfNeeded:scaled*UInt32(song[at+0x12+op]&15)/15)
            applyLevel(channel,op,slots[channel].levels[op])
        }
    }
    /// 0xFFC: delay, then the wave drives pitch and level.
    private func modulate(_ channel:Int,_ at:Int) {
        guard slots[channel].mode&0x80 != 0 else { slots[channel].counter &+= 1;return }
        if slots[channel].flags&0xC0 != 0 {
            if slots[channel].releaseCount != 0 {
                slots[channel].releaseCount -= 1
                if slots[channel].releaseCount == 0 { silence(channel) }
            }
            slots[channel].depth = UInt16(tables.depths[Int(song[at+0x10]&15)])
            slots[channel].speed = UInt16(song[at+0xC])|UInt16(song[at+0xD])<<8
        }
        guard slots[channel].flags&0xC0 != 0,slots[channel].speed != 0 else {
            slots[channel].mode |= 3;slots[channel].counter &+= 1
            return
        }
        func begin() {
            slots[channel].counter = 0;slots[channel].value = 0;slots[channel].direction = 1
            slots[channel].mode = (slots[channel].mode&0xFC)|2
        }
        switch slots[channel].mode&3 {
        case 0:slots[channel].counter &+= 1;return
        case 1:
            slots[channel].counter &-= 1
            guard slots[channel].counter == 0 else { return }
            begin()
        case 2:break
        default:
            slots[channel].mode = (slots[channel].mode&0xFC)|1
            let delay = song[at+0x14]
            if delay == 0,song[at+0xE] != 4 {
                slots[channel].counter = freeCounter
                slots[channel].mode = (slots[channel].mode&0xFC)|2
            } else if delay <= 1 { begin() }
            else { slots[channel].counter = (UInt16(delay)-1)<<2&+1;return }
        }
        let sample = wave(channel,song[at+0xE])
        bend(channel,Int16(truncatingIfNeeded:Int32(sample)*Int32(Int8(bitPattern:song[at+0xF]))/127))
        tremolo(channel,sample,at)
        slots[channel].counter &+= 1
    }
    /// 0x10A0: fade, then pitch glides and modulation on all channels.
    private func effectTick() {
        if fadeLength != 0 {
            fadePhase += 1
            if fadePhase >= 4 {
                fadePhase = 0
                if fadeStep >= fadeLength { stop();return }
                fadeStep += 1
                let level = min(UInt32(fadeStep)*UInt32(fadeStep)*0xFF/(UInt32(fadeLength)*UInt32(fadeLength)),0xFF)
                if UInt8(level) != fadeLevel {
                    fadeLevel = UInt8(level)
                    for track in 0..<Self.tracks { applyVolume(track,slots[track].volume) }
                }
            }
        }
        for channel in 0..<Self.channels {
            if slots[channel].mode&0x40 != 0 {
                var value = oneShot(channel)
                if slots[channel].mode&4 != 0 { value = 0&-value }
                let result = bend(channel,value)
                if slots[channel].value == 0x7FFF {
                    slots[channel].frequency = result;slots[channel].mode &= 0xBF
                }
            } else if let at = slots[channel].instrument { modulate(channel,at) }
        }
        freeCounter &+= 1
    }
}
