//
//  GenericAudioMixer.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/01/09.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation
import CoreMedia
import AudioUnit

fileprivate class MixWindow {
    fileprivate var start: Date = .init()
    fileprivate let size: Int
    fileprivate var next: MixWindow?
    fileprivate var prev: MixWindow?
    fileprivate var lock: NSLock = .init()
    
    fileprivate var buffer: [UInt8]
    
    public init(size: Int) {
        buffer = .init(repeating: 0, count: size)
        self.size = size
    }
    
    fileprivate func clear() {
        lock.lock()
        _ = (0 ..< buffer.count).map {buffer[$0] = 0}
        lock.unlock()
    }
}

/*!
 *  Basic, cross-platform mixer that uses a very simple nearest neighbour resampling method
 *  and the sum of the samples to mix.  The mixer takes LPCM data from multiple sources, resamples (if needed), and
 *  mixes them to output a single LPCM stream.
 *
 *  Note that this mixer uses an extremely simple sample rate conversion algorithm that will produce undesirable
 *  noise in most cases, but it will be much less CPU intensive than more sophisticated methods.  If you are using an Apple
 *  operating system and can dedicate more CPU resources to sample rate conversion, look at videocore::Apple::AudioMixer.
 */
open class AudioMixer: IAudioMixer {
    private let kMixWindowCount = 10
    
    private let kE: Float = 2.7182818284590
    
    private let windows: [MixWindow]
    private var currentWindow: MixWindow
    private var outgoingWindow: MixWindow?
    
    private var mixQueue: JobQueue = .init("com.videocast.composite")
    
    private var epoch: Date = .init()
    private var nextMixTime: Date = .init()
    private var lastMixTime: Date = .init()
    
    private var frameDuration: TimeInterval
    private var bufferDuration: TimeInterval
    
    private var _mixThread: Thread?
    private var mixThreadCond: NSCondition = .init()
    
    private weak var output: IOutput?
    
    private var inGain: [Int: Float] = .init()
    private var lastSampleTime: [Int: Date] = .init()
    
    private var outChannelCount: Int
    private var outFrequencyInHz: Int
    private var outBitsPerChannel: Int = 16
    private var bytesPerSample: Int
    
    private var exiting: Atomic<Bool> = .init(false)
    
    private var catchingUp: Bool = false
    
    private static var s_samplingRateConverterComplexity = kAudioConverterSampleRateConverterComplexity_Normal
    private static var s_samplingRateConverterQuality = kAudioConverterQuality_Medium

    struct ConverterInst {
        var asbdIn: AudioStreamBasicDescription
        var asbdOut: AudioStreamBasicDescription
        var converter: AudioConverterRef?
    }
    private var converters: [UInt64:ConverterInst] = .init()
    
    struct UserData {
        var data: UnsafeMutableRawPointer
        var p: Int
        var size: Int
        var packetSize: Int
        var numberPackets: UInt32
        var numChannels: Int
        var pd: UnsafePointer<AudioStreamPacketDescription>?
        var isInterleaved: Bool
        var usesOSStruct: Bool
    }
    
    /*!
     *  Constructor.
     *
     *  \param outChannelCount      number of channels to output.
     *  \param outFrequencyInHz     sampling rate to output.
     *  \param outBitsPerChannel    number of bits per channel to output
     *  \param frameDuration        The duration of a single frame of audio.  For example, AAC uses 1024 samples per frame
     *                              and therefore the duration is 1024 / sampling rate
     */
    public init(outChannelCount: Int,
                outFrequencyInHz: Int,
                outBitsPerChannel: Int,
                frameDuration: Double) {
        self.bufferDuration = frameDuration
        self.frameDuration = frameDuration
        self.outChannelCount = outChannelCount
        self.outFrequencyInHz = outFrequencyInHz
        
        self.bytesPerSample = outChannelCount * outBitsPerChannel / 8
        
        windows = .init(repeating: MixWindow(size: Int(Double(bytesPerSample) * frameDuration * Double(outFrequencyInHz))), count: kMixWindowCount)
        
        for i in 0 ..< kMixWindowCount-1 {
            windows[i].next = windows[i+1]
            windows[i+1].prev = windows[i+1]
        }
        windows[kMixWindowCount-1].next = windows[0]
        windows[0].prev = windows[kMixWindowCount-1]
        
        currentWindow = windows[0]
        currentWindow.start = .init()
        
        
    }
    
    deinit {
        exiting.value = true
        mixThreadCond.broadcast()
        _mixThread?.cancel()
        mixQueue.markExiting()
        mixQueue.enqueueSync {}
        
        for it in converters {
            guard let converter = it.value.converter else {
                Logger.debug("unexpected return")
                continue
            }
            AudioConverterDispose(converter)
        }
    }
    
    /*! IMixer::registerSource */
    open func registerSource(_ source: ISource, inBufferSize: Int) {
        inGain[hash(source)] = 1
    }
    
    /*! IMixer::unregisterSource */
    open func unregisterSource(_ source: ISource) {
        mixQueue.enqueue {
            if let iit = self.inGain.index(forKey: hash(source)) {
                self.inGain.remove(at: iit)
            }
        }
    }

    /*! IOutput::pushBuffer */
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard let inMeta = metadata as? AudioBufferMetadata,
            let metaData = inMeta.data else {
                Logger.debug("unexpected return")
                return
        }
        
        let data = data.assumingMemoryBound(to: UInt8.self)
        let inSource = metaData.source
        let cMixTime = Date()
        let currentWindow = self.currentWindow
        
        let ret = resample(data, size: size, metadata: inMeta)
        
        if ret.size == 0 {
            ret.resize(size)
            ret.put(data, size: size)
        }
        
        mixQueue.enqueue {
            var mixTime = cMixTime
            
            let g: Float = 0.70710678118  // 1 / sqrt(2)
            
            guard let lSource = inSource.value else {
                Logger.debug("unexpected return")
                return
            }
            
            let h = hash(lSource)
            
            if let it = self.lastSampleTime[h], mixTime.timeIntervalSince(it) < self.frameDuration * 0.25 {
                mixTime = it
            }
            
            var startOffset = 0
            
            var window: MixWindow? = currentWindow

            let diff = mixTime.timeIntervalSince(currentWindow.start)
            
            if diff > 0 {
                startOffset = Int(diff * Double(self.outFrequencyInHz) * Double(self.bytesPerSample)) & ~(self.bytesPerSample-1)
            
                while let size = window?.size, startOffset >= size {
                    startOffset = (startOffset - size)
                    window = window?.next
                    
                }
            } else {
                startOffset = 0
            }
            
            let sampleDuration = Double(ret.size) / Double(self.bytesPerSample * self.outFrequencyInHz)
            
            let mult = (self.inGain[h] ?? 0) * g
            
            var ptr: UnsafePointer<UInt8>?
            ret.read(&ptr, size: ret.size)
            guard var p = ptr else {
                Logger.debug("unexpected return")
                return
            }
            var bytesLeft = ret.size
            
            var so = startOffset
            
            while bytesLeft > 0 {
                guard let size = window?.size else {
                    Logger.debug("unexpected return")
                    break
                }
                let rawp = UnsafeRawPointer(p)
                let toCopy = min(size - so, bytesLeft)
                
                let count = toCopy / MemoryLayout<Int16>.size

                let mix = rawp.bindMemory(to: Int16.self, capacity: count)
                window?.lock.lock()
                let ptr = window?.buffer.withUnsafeMutableBytes { $0.baseAddress }
                guard let winMix = ptr?.bindMemory(to: Int16.self, capacity: count) else {
                    Logger.debug("unexpected return")
                    break
                }
                
                for i in 0..<count {
                    winMix[i] = self.TPMixSamples(winMix[i], Int16(Float(mix[i])*mult))
                }
                window?.lock.unlock()
                
                p += toCopy
                bytesLeft -= toCopy
                
                if bytesLeft > 0 {
                    window = window?.next
                    so = 0
                }
            }
            self.lastSampleTime[h] = mixTime + sampleDuration
            
        }
        
    }
    
    /*! ITransform::setOutput */
    open func setOutput(_ output: IOutput) {
        self.output = output
    }

    /*! IAudioMixer::setSourceGain */
    open func setSourceGain(_ source: WeakRefISource, gain: Float) {
        if let s = source.value {
            let h = hash(s)
            
            var gain = max(0, min(1, gain))
            gain = powf(gain, kE)
            inGain[h] = gain
        }
    }
    
    /*! IAudioMixer::setChannelCount */
    open func setChannelCount(_ channelCount: Int) {
        outChannelCount = channelCount
    }
    
    /*! IAudioMixer::setFrequencyInHz */
    open func setFrequencyInHz(_ frequencyInHz: Float) {
        outFrequencyInHz = Int(frequencyInHz)
    }
    
    /*! IAudioMixer::setMinimumBufferDuration */
    open func setMinimumBufferDuration(_ duraiton: Double) {
        bufferDuration = duraiton
    }
    
    /*! ITransform::setEpoch */
    open func setEpoch(_ epoch: Date) {
        self.epoch = epoch
        nextMixTime = epoch
    }
    
    open func start() {
        _mixThread = Thread(block: mixThread)
        _mixThread?.name = "com.videocast.audiomixer"
        _mixThread?.start()
    }
    
    /*!
     *  Called to resample a buffer of audio samples.
     *
     * \param buffer    The input samples
     * \param size      The buffer size in bytes
     * \param metadata  The associated AudioBufferMetadata that specifies the properties of this buffer.
     *
     * \return An audio buffer that has been resampled to match the output properties of the mixer.
     */
    private func resample(_ buffer: UnsafeRawPointer, size: Int, metadata: AudioBufferMetadata) -> Buffer {
        guard let metaData = metadata.data else {
            Logger.debug("unexpected return")
            return Buffer()
        }
        let inFrequncyInHz = metaData.frequencyInHz
        let inBitsPerChannel = metaData.bitsPerChannel
        let inChannelCount = metaData.channelCount
        let inFlags = metaData.flags
        let inBytesPerFrame = metaData.bytesPerFrame
        let inNumberFrames = metaData.numberFrames
        let inUsesOSStruct = metaData.usesOSStruct
        
        guard outFrequencyInHz != inFrequncyInHz ||
            outBitsPerChannel != inBitsPerChannel ||
            outChannelCount != inChannelCount ||
            (inFlags & kAudioFormatFlagIsNonInterleaved) != 0 ||
            (inFlags & kAudioFormatFlagIsFloat) != 0 else {
                // No resampling necessary
                return Buffer() }

        let b1 = UInt64(inBytesPerFrame&0xFF) << 56
        let b2 = UInt64(inFlags&0xFF) << 48
        let b3 = UInt64(inChannelCount) << 40
        let b4 = UInt64(inBitsPerChannel&0xFF) << 32
        let b5 = UInt64(inFrequncyInHz)
        let hash = b1 | b2 | b3 | b4 | b5

        let it = converters[hash]
        var converter: ConverterInst
        
        if let it = it {
            converter = it
        } else {
            var asbdIn: AudioStreamBasicDescription = .init()
            var asbdOut: AudioStreamBasicDescription = .init()
            
            asbdIn.mFormatID = kAudioFormatLinearPCM
            asbdIn.mFormatFlags = inFlags
            asbdIn.mChannelsPerFrame = UInt32(inChannelCount)
            asbdIn.mSampleRate = Float64(inFrequncyInHz)
            asbdIn.mBitsPerChannel = UInt32(inBitsPerChannel)
            asbdIn.mBytesPerFrame = UInt32(inBytesPerFrame)
            asbdIn.mFramesPerPacket = 1
            asbdIn.mBytesPerPacket = asbdIn.mBytesPerFrame * asbdIn.mFramesPerPacket
            
            asbdOut.mFormatID = kAudioFormatLinearPCM
            asbdOut.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
            asbdOut.mChannelsPerFrame = UInt32(outChannelCount)
            asbdOut.mSampleRate = Float64(outFrequencyInHz)
            asbdOut.mBitsPerChannel = UInt32(outBitsPerChannel)
            asbdOut.mBytesPerFrame = (asbdOut.mBitsPerChannel * asbdOut.mChannelsPerFrame) / 8
            asbdOut.mFramesPerPacket = 1
            asbdOut.mBytesPerPacket = asbdOut.mBytesPerFrame * asbdOut.mFramesPerPacket
            
            converter = .init(asbdIn: asbdIn, asbdOut: asbdOut, converter: nil)
            
            let ret = AudioConverterNew(&asbdIn, &asbdOut, &converter.converter)
            if let converter = converter.converter {
            
                AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity, UInt32(MemoryLayout<UInt32>.size), &AudioMixer.s_samplingRateConverterComplexity)
                
                AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality, UInt32(MemoryLayout<UInt32>.size), &AudioMixer.s_samplingRateConverterQuality)
                
                var prime = kConverterPrimeMethod_None
                
                AudioConverterSetProperty(converter, kAudioConverterPrimeMethod, UInt32(MemoryLayout<UInt32>.size), &prime)
            }
            
            converters[hash] = converter
            
            if ret != noErr {
                Logger.error("ret = \(ret) (\(String(format:"%x", ret))")
            }
            
        }
        
        guard let inConverter = converter.converter else {
            Logger.debug("unexpected return")
            return Buffer()
        }
        
        let asbdIn = converter.asbdIn
        let asbdOut = converter.asbdOut
        
        let inSampleCount = inNumberFrames
        let ratio = Double(inFrequncyInHz) / Double(outFrequencyInHz)
        
        let outBufferSampleCount: Double = round(Double(inSampleCount) / ratio)
        
        let outBufferSize = Int(Double(asbdOut.mBytesPerPacket) * outBufferSampleCount)
        let outBuffer = Buffer(outBufferSize)
        
        
        var ud: UserData = .init(
            data: UnsafeMutableRawPointer(mutating: buffer),
            p: 0,
            size: size,
            packetSize: Int(asbdIn.mBytesPerPacket),
            numberPackets: UInt32(inSampleCount),
            numChannels: inChannelCount,
            pd: nil,
            isInterleaved: (inFlags & kAudioFormatFlagIsNonInterleaved) == 0,
            usesOSStruct: inUsesOSStruct)
        
        let mData = outBuffer.getMutable()
        var outBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(outChannelCount),
                mDataByteSize: UInt32(outBufferSize),
                mData: mData
        ))
        
        var sampleCount = UInt32(outBufferSampleCount)
        let ret = AudioConverterFillComplexBuffer(inConverter,  /* AudioConverterRef inAudioConverter */
            AudioMixer.ioProc,    /* AudioConverterComplexInputDataProc inInputDataProc */
            &ud, /* void *inInputDataProcUserData */
            &sampleCount, /* UInt32 *ioOutputDataPacketSize */
            &outBufferList,   /* AudioBufferList *outOutputData */
            nil   /* AudioStreamPacketDescription *outPacketDescription */
        )
        if ret != noErr {
            Logger.error("ret = \(ret) (\(String(format:"%x", ret))")
        }
        
        outBuffer.size = Int(outBufferList.mBuffers.mDataByteSize)
        return outBuffer
    }
    
    private static let ioProc: AudioConverterComplexInputDataProc = {audioConverter, ioNumDataPackets, ioData, ioPacketDesc, inUserData
        in
        var err: OSStatus = noErr
        let ud = inUserData!.assumingMemoryBound(to: UserData.self)
        
        let numPackets = min(ioNumDataPackets.pointee, ud.pointee.numberPackets)
        
        ioNumDataPackets.pointee = numPackets
        let ioDataPtr = UnsafeMutableAudioBufferListPointer(ioData)
        if !ud.pointee.usesOSStruct {
            ioDataPtr[0].mData = ud.pointee.data
            ioDataPtr[0].mDataByteSize = numPackets * UInt32(ud.pointee.packetSize)
            ioDataPtr[0].mNumberChannels = UInt32(ud.pointee.numChannels)
        } else {
            let ab = ud.pointee.data.assumingMemoryBound(to: AudioBufferList.self)
            ioData[0].mNumberBuffers = ab.pointee.mNumberBuffers
            let p = ud.pointee.p
            for i in 0..<Int(ab.pointee.mNumberBuffers) {
                let abPtr = UnsafeMutableAudioBufferListPointer(ab)
                guard let data = abPtr[i].mData else {
                    Logger.debug("unexpected return")
                    continue
                }
                ioDataPtr[i].mData = data + p
                ioDataPtr[i].mDataByteSize = numPackets * UInt32(ud.pointee.packetSize)
                ioDataPtr[i].mNumberChannels = abPtr[i].mNumberChannels
            }
            ud.pointee.p += Int(numPackets) * ud.pointee.packetSize
        }
        
        return err
    }
    
    /*!
     *  Start the mixer thread.
     */
    private func mixThread() {
        let us = frameDuration
        
        let start = epoch
        
        nextMixTime = start
        currentWindow.start = start
        currentWindow.next?.start = start + us
        
        while !exiting.value {
            mixThreadCond.lock()
            defer {
                mixThreadCond.unlock()
            }
            
            let now = Date()
            
            if let nextWindow = currentWindow.next, now >= nextWindow.start {
                
                let currentTime = nextMixTime
                
                let currentWindow = self.currentWindow
                
                nextWindow.start = currentWindow.start
                nextWindow.next?.start = nextWindow.start + us
                
                nextMixTime = currentWindow.start
                
                let md = AudioBufferMetadata(ts: .init(seconds: currentTime.timeIntervalSince(epoch), preferredTimescale: VC_TIME_BASE))
                
                md.data = (outFrequencyInHz, outBitsPerChannel, outChannelCount, AudioFormatFlags(0), 0, currentWindow.size, false, false, WeakRefISource(value: nil))
                if let out = output, let outgoingWindow = outgoingWindow {
                    out.pushBuffer(outgoingWindow.buffer, size: outgoingWindow.size, metadata: md)
                    outgoingWindow.clear()
                }
                outgoingWindow = currentWindow
                
                self.currentWindow = nextWindow
            }
            
            if !exiting.value {
                if let start = currentWindow.next?.start {
                    mixThreadCond.wait(until: start)
                }
            }
        }
        Logger.debug("Exiting audio mixer...")
    }
    
    private func deinterleaveDefloat(inBuff: UnsafePointer<Float>, outBuff: UnsafeMutablePointer<Int16>, sampleCount: UInt, channelCount: UInt) {
        let offset = Int(sampleCount)
        
        let mult: Float = 0x7FFF
        
        if channelCount == 2 {
            for i in stride(from: 0, to: Int(sampleCount), by: 2) {
                outBuff[i] = Int16(inBuff[i] * mult)
                outBuff[i+1] = Int16(inBuff[i+offset] * mult)
            }
        } else {
            for i in 0..<Int(sampleCount) {
                outBuff[i] = Int16(min(1,max(-1,inBuff[i])) * mult)
            }
        }
    }
    
    private func TPMixSamples(_ a: Int16, _ b: Int16) -> Int16 {
        let sum = (Int(a) + Int(b))
        let mul = (Int(a) * Int(b))

        if a < 0 && b < 0 {
            // If both samples are negative, mixed signal must have an amplitude between the lesser of A and B, and the minimum permissible negative amplitude
            return Int16(sum - (mul/Int(Int16.min)))
        } else if a > 0 && b > 0 {
            // If both samples are positive, mixed signal must have an amplitude between the greater of A and B, and the maximum permissible positive amplitude
            return Int16(sum - (mul/Int(Int16.max)))
        } else {
            // If samples are on opposite sides of the 0-crossing, mixed signal should reflect that samples cancel each other out somewhat
            return a + b
        }
    }
    
    private func b8_to_b16(_ v: UnsafeRawPointer) -> Int16 {
        let val = v.bindMemory(to: Int16.self, capacity: 1).pointee
        return val * 0xFF
    }
    
    private func b16_to_b16(_ v: UnsafeRawPointer) -> Int16 {
        return v.bindMemory(to: Int16.self, capacity: 1).pointee
    }

    private func b32_to_b16(_ v: UnsafeRawPointer) -> Int16 {
        let val = Int16(v.bindMemory(to: Int32.self, capacity: 1).pointee / 0xFFFF)
        return val
    }

    private func b24_to_b16(_ v: UnsafeRawPointer) -> Int16 {
        
        let m: Int32 = 1 << 23
        
        let p = v.bindMemory(to: UInt8.self, capacity: 1)
        
        let inarr: [UInt8] = [p[0], p[1], p[2], 0]
        
        let x = UnsafeRawPointer(inarr).bindMemory(to: Int32.self, capacity: 1).pointee
        
        var r = (x ^ m) - m
        
        return b32_to_b16(&r)
    }

}
