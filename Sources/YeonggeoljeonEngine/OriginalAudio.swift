// SPDX-License-Identifier: GPL-3.0-only
#if !os(Android)
import AVFoundation
#else
import Foundation
#endif

/// Plays the source's music selection through the native OPL2 chip. The
/// engine starts with the first song, so tests and replays never open audio.
final class OriginalAudio {
    private static let key = "musicMuted"
    static var musicEnabled:Bool {
        get { !UserDefaults.standard.bool(forKey:key) }
        set { UserDefaults.standard.set(!newValue,forKey:key) }
    }
    private static let effectsKey = "effectsMuted"
    static var effectsEnabled:Bool {
        get { !UserDefaults.standard.bool(forKey:effectsKey) }
        set { UserDefaults.standard.set(!newValue,forKey:effectsKey) }
    }
    private let catalog:OriginalMusicCatalog
    #if !os(Android)
    private let engine = AVAudioEngine()
    #endif
    private let lock = NSLock()
    private let chip = OPL2Chip()
    private let driver:OriginalMusicDriver
    private var selection:Int?
    private var running = false
    private var paused = false
    func setPaused(_ value:Bool) { lock.lock();paused = value;lock.unlock() }
    private var untilInterrupt = 0.0
    /// Frames the output has asked for, for checks on the live path.
    private(set) var renderedFrames = 0
    #if !os(Android)
    var volume:Float = 1 { didSet { engine.mainMixerNode.outputVolume = volume } }
    #else
    var volume:Float = 1
    /// The Android host pulls mono samples on its own audio thread.
    func pull(_ samples:UnsafeMutablePointer<Float>,count:Int) {
        lock.lock();fill(samples,count:count);renderedFrames += count;lock.unlock()
        if volume != 1 {for i in 0..<count {samples[i] *= volume}}
    }
    #endif
    /// A song chosen in the music room plays over the source's selection.
    var audition:Int?
    private static let samplesPerInterrupt = OPL2Chip.sampleRate/OriginalMusicDriver.interruptRate
    init(catalog:OriginalMusicCatalog) {
        self.catalog = catalog
        let chip = self.chip
        driver = OriginalMusicDriver(tables:catalog.tables,bank:catalog.effectBank) { chip.write($0,$1) }
    }
    /// CF5:61FE. A new effect replaces the one playing; ids stop at 0x2B.
    func playEffect(_ id:Int) {
        guard OriginalAudio.effectsEnabled,(0..<0x2B).contains(id) else { return }
        start()
        lock.lock();driver.playEffect(id);lock.unlock()
    }
    /// OPMUSIC and EDMUSIC: the opening and ending programs choose their own songs.
    func playProgram(bank:Int,member:Int,loop:Bool) {
        let songs = bank == 1 ? catalog.opening : catalog.ending
        guard OriginalAudio.musicEnabled,songs.indices.contains(member),let data = Data(base64Encoded:songs[member].data) else { return }
        selection = nil;start()
        lock.lock();driver.loops = loop;driver.play([UInt8](data));lock.unlock()
    }
    func fadeProgram(_ rate:Int) { lock.lock();driver.fade(UInt8(rate&255));lock.unlock() }
    func stopProgram() { lock.lock();driver.stop();driver.loops = true;lock.unlock() }
    var programPlaying:Bool { lock.lock();defer { lock.unlock() };return driver.playing }
    func stopEffect() { lock.lock();driver.stopEffect();lock.unlock() }
    var effectPlaying:Bool { lock.lock();defer { lock.unlock() };return driver.effect != 0 }
    /// Same selection keeps playing, as CF5:600A does. Nil stops the music.
    func select(_ value:Int?) {
        let wanted = audition ?? (OriginalAudio.musicEnabled ? value.flatMap { catalog.songs.indices.contains($0) ? $0 : nil } : nil)
        guard wanted != selection else { return }
        selection = wanted
        guard let wanted = wanted,let song = catalog.song(wanted) else {
            lock.lock();driver.stop();waiting = nil;lock.unlock()
            return
        }
        start()
        lock.lock();waiting = Self.change(driver,to:song);lock.unlock()
    }
    /// The song that starts once the fade before it ends.
    private var waiting:[UInt8]?
    var switching:Bool { lock.lock();defer { lock.unlock() };return waiting != nil }
    /// CF5:600A fades a playing song over length 8 (CF5:6086, then the wait at
    /// CF5:5F56) before it starts the next. That is 36 effect ticks, about 0.6
    /// seconds. Returns the song left waiting. The source holds the script
    /// during the fade; the engine does not.
    static func change(_ driver:OriginalMusicDriver,to song:[UInt8]) -> [UInt8]? {
        guard driver.playing else { driver.play(song);return nil }
        driver.fade(8)
        return song
    }
    #if !os(Android)
    func shutDown() { select(nil);if running { engine.stop();running = false } }
    #else
    func shutDown() { select(nil);running = false }
    #endif
    #if !os(Android)
    private func start() {
        guard !running,let format = AVAudioFormat(standardFormatWithSampleRate:OPL2Chip.sampleRate,channels:1) else { return }
        let node = AVAudioSourceNode(format:format) { [unowned self] _,_,frames,list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let samples = buffers[0].mData?.assumingMemoryBound(to:Float.self) else { return noErr }
            self.lock.lock();self.fill(samples,count:Int(frames));self.renderedFrames += Int(frames);self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node,to:engine.mainMixerNode,format:format)
        running = (try? engine.start()) != nil
    }
    #else
    private func start() { running = true }
    #endif
    private func fill(_ samples:UnsafeMutablePointer<Float>,count:Int) {
        if paused { samples.update(repeating:0,count:count);return }
        var done = 0
        while done < count {
            if untilInterrupt < 1 {
                driver.interrupt();untilInterrupt += Self.samplesPerInterrupt
                if let next = waiting,!driver.playing { driver.play(next);waiting = nil }
            }
            let run = min(count-done,Int(untilInterrupt))
            chip.render(samples+done,count:run)
            done += run;untilInterrupt -= Double(run)
        }
    }
    /// Exercise the exact live fill routine without starting an audio device.
    static func verifiesPauseContinuity(song:[UInt8],tables:OriginalMusicCatalog.Tables) -> Bool {
        let catalog = OriginalMusicCatalog(format:1,tables:tables,songs:[],opening:[],ending:[],source:nil,limitations:nil)
        let value = OriginalAudio(catalog:catalog)
        value.driver.play(song)
        func chunk(_ count:Int) -> [Float] {
            var samples = Array(repeating:Float(7),count:count)
            samples.withUnsafeMutableBufferPointer { value.fill($0.baseAddress!,count:count) }
            return samples
        }
        let first = chunk(2000)
        value.setPaused(true)
        let ticks = value.driver.ticks,clock = value.untilInterrupt
        let quiet = chunk(5000)
        guard quiet.allSatisfy({$0 == 0}),ticks == value.driver.ticks,clock == value.untilInterrupt else { return false }
        value.setPaused(false)
        let last = chunk(2000)
        let baseline = OriginalAudio(catalog:catalog);baseline.driver.play(song)
        var expected = Array(repeating:Float(0),count:4000)
        expected.withUnsafeMutableBufferPointer { baseline.fill($0.baseAddress!,count:4000) }
        return expected.contains(where:{$0 != 0}) && first+last == expected
    }
    /// Offline render of one song, for checks that must not touch audio hardware.
    static func render(song:[UInt8],tables:OriginalMusicCatalog.Tables,seconds:Double,bank:[UInt8] = [],effect:Int? = nil) -> [Float] {
        let chip = OPL2Chip()
        let driver = OriginalMusicDriver(tables:tables,bank:bank) { chip.write($0,$1) }
        driver.play(song)
        if let effect = effect { driver.playEffect(effect) }
        var samples = [Float](repeating:0,count:Int(seconds*OPL2Chip.sampleRate))
        var done = 0,until = 0.0
        samples.withUnsafeMutableBufferPointer { buffer in
            while done < buffer.count {
                if until < 1 { driver.interrupt();until += samplesPerInterrupt }
                let run = min(buffer.count-done,Int(until))
                chip.render(buffer.baseAddress!+done,count:run)
                done += run;until -= Double(run)
            }
        }
        return samples
    }
    /// 16-bit mono WAV bytes.
    static func wave(_ samples:[Float]) -> Data {
        var data = Data()
        func put<T:FixedWidthInteger>(_ value:T) { withUnsafeBytes(of:value.littleEndian) { data.append(contentsOf:$0) } }
        let rate = UInt32(OPL2Chip.sampleRate),bytes = UInt32(samples.count*2)
        data.append(contentsOf:Array("RIFF".utf8));put(36+bytes);data.append(contentsOf:Array("WAVEfmt ".utf8))
        put(UInt32(16));put(UInt16(1));put(UInt16(1));put(rate);put(rate*2);put(UInt16(2));put(UInt16(16))
        data.append(contentsOf:Array("data".utf8));put(bytes)
        for sample in samples { put(Int16(max(-1,min(1,sample))*32767)) }
        return data
    }
}
