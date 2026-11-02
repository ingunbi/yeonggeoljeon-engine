// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation

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
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let chip = OPL2Chip()
    private let driver:OriginalMusicDriver
    private var selection:Int?
    private var running = false
    private var untilInterrupt = 0.0
    /// Frames the output has asked for, for checks on the live path.
    private(set) var renderedFrames = 0
    var volume:Float = 1 { didSet { engine.mainMixerNode.outputVolume = volume } }
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
    /// Same selection keeps playing, as CF5:600A does. Nil stops the music.
    func select(_ value:Int?) {
        let wanted = OriginalAudio.musicEnabled ? value.flatMap { catalog.songs.indices.contains($0) ? $0 : nil } : nil
        guard wanted != selection else { return }
        selection = wanted
        guard let wanted = wanted,let song = catalog.song(wanted) else {
            lock.lock();driver.stop();lock.unlock()
            return
        }
        start()
        lock.lock();driver.play(song);lock.unlock()
    }
    func shutDown() { select(nil);if running { engine.stop();running = false } }
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
    private func fill(_ samples:UnsafeMutablePointer<Float>,count:Int) {
        var done = 0
        while done < count {
            if untilInterrupt < 1 { driver.interrupt();untilInterrupt += Self.samplesPerInterrupt }
            let run = min(count-done,Int(untilInterrupt))
            chip.render(samples+done,count:run)
            done += run;untilInterrupt -= Double(run)
        }
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
