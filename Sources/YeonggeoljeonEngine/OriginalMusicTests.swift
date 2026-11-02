// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Synthetic checks for the music driver (SBOPL2.COM) and the OPL2 chip.
func originalMusicSelfTests() throws {
    var checks = 0
    func check(_ value:@autoclosure() throws -> Bool,_ reason:String) throws {
        guard try value() else {throw EngineError.invalid("Original music regression: \(reason)")};checks += 1
    }
    let tables = OriginalMusicCatalog.Tables(fnumbers:[0x157,0x16B,0x181,0x198,0x1B0,0x1CA,0x1E5,0x202,0x220,0x241,0x263,0x287],
        bends:Array(repeating:0x1000,count:13),depths:Array(repeating:0x1000,count:16),randomSeed:0x37D)
    // A song: seven track words, one 22-byte instrument, then the track.
    func song(_ track:[UInt8],volume:UInt8 = 0x40) -> [UInt8] {
        let instrument:[UInt8] = [0x21,0x22,0x06,0x01,0x02,0x13,0x14,0xA1,0xB2,0x72,0x83,0x00,0,0,0,0,0,0,0,0,0,0]
        let start = 14+instrument.count
        var bytes = [UInt8(start&255),UInt8(start>>8)]+Array(repeating:UInt8(0),count:12)+instrument
        // F4 stores a word relative to its own byte; the record sits behind it.
        let relative = UInt16(truncatingIfNeeded:14-start)
        bytes += [0xF4,UInt8(relative&255),UInt8(relative>>8),0xF0,volume]+track
        return bytes
    }
    final class Recorder { var writes:[(Int,Int)] = [] }
    func driver(_ data:[UInt8]) -> (OriginalMusicDriver,Recorder) {
        let recorder = Recorder()
        let value = OriginalMusicDriver(tables:tables) { recorder.writes.append(($0,$1)) }
        recorder.writes.removeAll();value.play(data)
        return (value,recorder)
    }
    // An effect bank: one table entry, then an instrument and a two-byte note track.
    do {
        let instrument:[UInt8] = [0x21,0x22,0x06,0x01,0x02,0x13,0x14,0xA1,0xB2,0x72,0x83,0x00,0,0,0,0,0,0,0,0,0,0]
        let start = 8+instrument.count
        var bank:[UInt8] = [UInt8(start&255),UInt8(start>>8),0,0,0,0,0,0]+instrument
        let relative = UInt16(truncatingIfNeeded:8-start)
        bank += [0xF4,UInt8(relative&255),UInt8(relative>>8),0x24,0x04,0x03,0xFF]
        let recorder = Recorder()
        let effects = OriginalMusicDriver(tables:tables,bank:bank) { recorder.writes.append(($0,$1)) }
        recorder.writes.removeAll();effects.playEffect(0)
        try check(effects.effect == 1,"the driver's effect id is the source id plus one")
        var interrupts = 0
        while effects.effect != 0,interrupts < 4000 { effects.interrupt();interrupts += 1 }
        try check(effects.effect == 0,"an effect ends with its tracks")
        try check(recorder.writes.contains{$0.0 == 0xB7 && $0.1&0x20 != 0},"effect notes key on channel seven")
        try check(!recorder.writes.contains{$0.0 == 0xB0 && $0.1&0x20 != 0},"an effect never keys a music channel")
        // Four effect ticks at 54/256 per interrupt.
        try check(interrupts <= 8*256/54,"effect tracks run on the slower clock: \(interrupts)")
        let quiet = OriginalMusicDriver(tables:tables,bank:bank) { _,_ in }
        quiet.playEffect(40)
        try check(quiet.effect == 0,"an id past the bank plays nothing")
    }
    /// Runs interrupts until `count` music ticks have passed.
    func run(_ value:OriginalMusicDriver,ticks count:Int) {
        let target = value.ticks+count
        var guardCount = 0
        while value.ticks < target,value.playing,guardCount < 100_000 { value.interrupt();guardCount += 1 }
    }
    func keyWrites(_ recorder:Recorder) -> [Int] { recorder.writes.filter{$0.0 == 0xB0 && $0.1&0x20 != 0}.map(\.1) }

    // The first tick reads the instrument and sounds the note.
    var (player,log) = driver(song([60,48,24,0xFF]))
    try check(player.playing,"a song starts")
    run(player,ticks:1)
    let written = Dictionary(log.writes.map{($0.0,$0.1)},uniquingKeysWith:{$1})
    try check(written[0x20] == 0x21 && written[0x23] == 0x22 && written[0xC0] == 0x06,"the instrument loads its first registers")
    try check(written[0xE0] == 0x01 && written[0xE3] == 0x02 && written[0x60] == 0xA1 && written[0x63] == 0xB2,"waves and envelopes follow")
    try check(written[0x80] == 0x72 && written[0x83] == 0x83,"sustain and release close the record")
    // Note 60 is octave five, semitone zero.
    try check(written[0xA0] == 0x57,"the low pitch byte comes from the table")
    try check(keyWrites(log) == [0x20|(5<<2)|1],"the key-on word carries block and high pitch bits")
    // Connection zero leaves the modulator's level alone.
    try check(written[0x40] == 0x13 && written[0x43] == 0x34,"volume reaches only the carrier in FM connection")

    // Gate and step: off after twenty-four ticks, finished after forty-eight.
    log.writes.removeAll()
    run(player,ticks:23)
    try check(!log.writes.contains{$0.0 == 0xB0},"the gate holds the key")
    run(player,ticks:1)
    try check(log.writes.contains{$0.0 == 0xB0 && $0.1&0x20 == 0},"the gate releases the key")

    // Short notes reuse the previous step and gate.
    (player,log) = driver(song([60,10,5,0x60+62,0xFF]));player.loops = false
    run(player,ticks:11)
    try check(log.writes.contains{$0.0 == 0xA0 && $0.1 == 0x81},"a short note plays at its own pitch")
    run(player,ticks:30)
    try check(!player.playing,"a finished song stops without its loop")

    // Tied notes keep the key held; a rest releases nothing new.
    (player,log) = driver(song([60,10,12,62,10,5,0xFF]));player.loops = false
    run(player,ticks:1)
    try check(keyWrites(log).count == 1,"the first tied note keys on")
    log.writes.removeAll()
    run(player,ticks:11)
    try check(log.writes.filter{$0.0 == 0xB0 && $0.1&0x20 == 0}.isEmpty,"a gate past the step ties without a key off")
    try check(log.writes.contains{$0.0 == 0xA0 && $0.1 == 0x81},"the tie still changes pitch")
    (player,log) = driver(song([0,10,0,0xFF]));player.loops = false
    run(player,ticks:5)
    try check(keyWrites(log).isEmpty,"a zero gate is a rest")

    // Repeats and loops.
    (player,log) = driver(song([0xD0,60,2,1,0xD2,0xFF]));player.loops = false
    run(player,ticks:40)
    try check(keyWrites(log).count == 3,"D2 plays a section three times")
    (player,log) = driver(song([62,2,1,0xFE,60,2,1,0xFF]))
    run(player,ticks:8)
    try check(player.playing && keyWrites(log).count == 4,"the loop mark skips the intro on each pass")
    // Tempo: 120 is 96 ticks per second, and the command changes it.
    (player,log) = driver(song([0xF2,60,60,200,1,0xFF]))
    var interrupts = 0
    while player.ticks < 1,interrupts < 10_000 { player.interrupt();interrupts += 1 }
    let startInterrupts = interrupts
    while player.ticks < 61,interrupts < 100_000 { player.interrupt();interrupts += 1 }
    let rate = 60/(Double(interrupts-startInterrupts)/OriginalMusicDriver.interruptRate)
    try check(abs(rate-48) < 1,"tempo sixty runs forty-eight ticks per second")

    // A new selection fades the old song for 36 effect ticks, then starts.
    (player,log) = driver(song([62,2,1,0xFE,60,2,1,0xFF]))
    run(player,ticks:4)
    let next = song([64,2,1,0xFF])
    let left = OriginalAudio.change(player,to:next)
    interrupts = 0
    while player.playing,interrupts < 10_000 { player.interrupt();interrupts += 1 }
    try check(left == next && !player.playing,"the old song fades out before the next one")
    try check(abs(interrupts-36*256/54) <= 5,"length eight lasts thirty-six effect ticks: \(interrupts)")
    let silent = OriginalMusicDriver(tables:tables) { _,_ in }
    try check(OriginalAudio.change(silent,to:next) == nil && silent.playing,"with nothing playing the song starts at once")
    // The chip: pitch, envelope and silence.
    func tone(modulated:Bool,seconds:Double) -> [Float] {
        let chip = OPL2Chip()
        chip.write(0x01,0x20);chip.write(0x20,0x21);chip.write(0x23,0x21)
        chip.write(0x40,modulated ? 0x10 : 0x3F);chip.write(0x43,0x00)
        chip.write(0x60,0xF0);chip.write(0x63,0xF0);chip.write(0x80,0x0F);chip.write(0x83,0x0F)
        chip.write(0xC0,0);chip.write(0xA0,0x44);chip.write(0xB0,0x20|(4<<2)|1)
        var samples = [Float](repeating:0,count:Int(seconds*OPL2Chip.sampleRate))
        samples.withUnsafeMutableBufferPointer { chip.render($0.baseAddress!,count:$0.count) }
        return samples
    }
    func crossings(_ samples:[Float]) -> Double {
        var count = 0
        for index in 1..<samples.count where samples[index-1] < 0 && samples[index] >= 0 { count += 1 }
        return Double(count)/(Double(samples.count)/OPL2Chip.sampleRate)
    }
    let pure = tone(modulated:false,seconds:0.5)
    // F-number 0x144 at block 4 is 0x144*49716/2^16 Hz.
    let expected = Double(0x144)*OPL2Chip.sampleRate/65536
    try check(abs(crossings(pure)-expected) < expected*0.01,"the carrier sounds at the F-number's frequency")
    try check((pure.map(abs).max() ?? 0) > 0.1,"a full-level carrier is audible")
    try check(crossings(tone(modulated:true,seconds:0.5)) > expected*1.2,"a modulator adds partials")
    let chip = OPL2Chip()
    chip.write(0x20,0x01);chip.write(0x23,0x01);chip.write(0x43,0);chip.write(0x40,0x3F)
    chip.write(0x63,0xF0);chip.write(0x60,0xF0);chip.write(0x83,0x0F);chip.write(0x80,0x0F)
    chip.write(0xA0,0x44);chip.write(0xB0,0x31)
    var block = [Float](repeating:0,count:4096)
    block.withUnsafeMutableBufferPointer { chip.render($0.baseAddress!,count:$0.count) }
    chip.write(0xB0,0x11)
    var tail = [Float](repeating:1,count:40000)
    tail.withUnsafeMutableBufferPointer { chip.render($0.baseAddress!,count:$0.count) }
    try check((tail.suffix(1000).map(abs).max() ?? 1) < 0.0005,"a released note falls silent")
    // The volume byte is an attenuation added to the carrier's level.
    let render = OriginalAudio.render(song:song([60,48,24,0xFF],volume:0),tables:tables,seconds:0.5)
    try check(render.count == Int(0.5*OPL2Chip.sampleRate) && (render.map(abs).max() ?? 0) > 0.01,"the offline render makes sound")
    try check(render.allSatisfy{$0.isFinite},"it stays finite")
    let wave = OriginalAudio.wave([0,1,-1])
    try check(wave.count == 50 && wave.prefix(4).elementsEqual(Array("RIFF".utf8)),"the WAV writer keeps its header")
    print("Original music self-tests passed: \(checks)")
}
