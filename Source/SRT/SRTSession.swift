//
//  SRTSession.swift
//  VideoCast
//
//  Created by Tomohiro Matsuzawa on 2018/03/06.
//  Copyright © 2018年 CyberAgent, Inc. All rights reserved.
//

import Foundation

public typealias SRTSessionParameters = MetaData<(
    chunk: Int32,
    loglevel: SRTLogLevel,
    logfa: SRTLogFAs,
    logfile: String,
    internal_log: Bool,
    autoreconnect: Bool,
    quiet: Bool,
    fullstats: Bool,
    report: UInt32,
    stats: UInt32)>

public enum SRTClientState: Int {
    case none = 0
    case connecting
    case connected
    case error
    case notConnected
}

public typealias SRTSessionStateCallback = (_ session: SRTSession, _ state: SRTClientState) -> Void

open class SRTSession: IOutputSession {
    private let kPollDelay:  TimeInterval = 0.1    // seconds - represents the time between polling
    
    private let uri: String
    
    private let callback: SRTSessionStateCallback
    
    private var loglevel: SRTLogLevel = .err
    private var logfa: SRTLogFAs = .general
    private var logfile: String = ""
    private var internal_log: Bool = false
    private var autoreconnect: Bool = true
    private var quiet: Bool = false
    
    private let jobQueue: JobQueue = .init("srt")
    
    private var state: SRTClientState = .none
    
    private var tar: SrtTarget?
    
    private var wroteBytes: Int = 0
    private var lostBytes: Int = 0
    private var lastReportedtLostBytes: Int = 0
    private var writeErrorLogTimer: Date = .init()
    
    private var thread: Thread? = nil
    private let cond: NSCondition = .init()
    private var started: Bool = false
    private var ending: Atomic<Bool> = .init(false)
    
    public init(uri: String, callback: @escaping SRTSessionStateCallback) {
        self.uri = uri
        self.callback = callback
    }
    
    open func setSessionParameters(_ parameters: IMetaData) {
        guard let params = parameters as? SRTSessionParameters, let data = params.data else {
            Logger.debug("unexpected return")
            return
        }
        SrtConf.transmit_chunk_size = data.chunk
        loglevel = data.loglevel
        logfa = data.logfa
        logfile = data.logfile
        internal_log = data.internal_log
        autoreconnect = data.autoreconnect
        quiet = data.quiet
        SrtConf.transmit_total_stats = data.fullstats
        SrtConf.transmit_bw_report = data.report
        SrtConf.transmit_stats_report = data.stats
        
        start()
    }
    
    open func start() {
        if !started {
            started = true
            thread = Thread(block: transmitThread)
            thread?.start()
        }
    }
    
    open func stop(_ callback: @escaping StopSessionCallback) {
        ending.value = true
        cond.broadcast()
        if started {
            thread?.cancel()
            started = false
        }
    }
    
    open func pushBuffer(_ data: UnsafeRawPointer, size: Int, metadata: IMetaData) {
        guard !ending.value else { return }
        
        // make the lamdba capture the data
        let buf = Buffer(size)
        buf.put(data, size: size)
        
        jobQueue.enqueue {
            if !self.ending.value {
                do {
                    guard let tar = self.tar else { return }
                    
                    var ptr: UnsafePointer<UInt8>?
                    buf.read(&ptr, size: buf.size)
                    guard let p = UnsafeRawPointer(ptr) else {
                        Logger.debug("unexpected return")
                        return
                    }
                    
                    let data = p.assumingMemoryBound(to: Int8.self)
                    if try !tar.isOpen || !tar.write(data, size: buf.size) {
                        self.lostBytes += buf.size
                        
                    } else {
                        self.wroteBytes += buf.size
                    }
                    
                    if !self.quiet && (self.lastReportedtLostBytes != self.lostBytes)
                    {
                        let now: Date = .init()
                        if now.timeIntervalSince(self.writeErrorLogTimer) >= 5 {
                            Logger.debug("\(self.lostBytes) bytes lost, \(self.wroteBytes) bytes sent")
                            self.writeErrorLogTimer = now
                            self.lastReportedtLostBytes = self.lostBytes
                        }
                    }
                } catch {
                    Logger.error("ERROR: \(error)")
                }
            }
        }
    }
    
    open func setBandwidthCallback(_ callback: @escaping BandwidthCallback) {
        
    }
    
    private func transmitThread() {
        loglevel.setLogLevel()
        logfa.setLogFA()
        
        Thread.current.name = "com.videocast.srt.transmission"
        
        if internal_log {
            var NAME = "SRTLIB".cString(using: String.Encoding.utf8)!
            srt_setlogflags( 0
                | SRT_LOGF_DISABLE_TIME
                | SRT_LOGF_DISABLE_SEVERITY
                | SRT_LOGF_DISABLE_THREADNAME
                | SRT_LOGF_DISABLE_EOL
            )
            srt_setloghandler(&NAME, { (opaque, level, file, line, area, message) in
                let file: String = .init(cString: file!)
                let area: String = .init(cString: area!)
                let message: String = .init(cString: message!)
                
                Logger.debug("[\(file):\(line)(\(area)]{\(level)} \(message)")
            })
        } else if !logfile.isEmpty {
            _ = logfile.withCString { udtSetLogStream($0) }
        }
        
        if (!quiet)
        {
            Logger.debug("Media path: \(uri)")
        }
        
        var tarConnected: Bool = false
        
        let pollid: Int32 = srt_epoll_create()
        guard pollid >= 0 else {
            Logger.error("Can't initialize epoll")
            setClientState(.error)
            return;
        }
        
        do {
            // Now loop until broken
            while !ending.value {
                cond.lock()
                defer {
                    cond.unlock()
                }
                
                if !ending.value {
                    cond.wait(until: Date.init(timeIntervalSinceNow: kPollDelay))
                }
                guard !ending.value else {
                    break
                }

                if (tar == nil)
                {
                    tar = try SrtTarget.create(uri, pollid: pollid)
                    guard tar != nil else {
                        Logger.error("Unsupported target type")
                        setClientState(.error)
                        return
                    }
                    
                    wroteBytes = 0;
                    lostBytes = 0;
                    lastReportedtLostBytes = 0;
                    
                    setClientState(.connecting)
                }
                
                var srtrfdslen: Int32 = 1
                var srtrfds: [SRTSOCKET] = .init(repeating: SRT_INVALID_SOCK, count: 1)
                var srtwfdslen: Int32 = 1
                var srtwfds: [SRTSOCKET] = .init(repeating: SRT_INVALID_SOCK, count: 1)
                if srt_epoll_wait(pollid,
                                  &srtrfds, &srtrfdslen, &srtwfds, &srtwfdslen,
                                  0,
                                  nil, nil, nil, nil) >= 0
                {
                    /*if false
                     {
                     Logger.debug("Event: srtrfdslen \(srtrfdslen) sysrfdslen \(sysrfdslen)")
                     }*/
                    
                    var doabort: Bool = false
                    if srtrfdslen > 0 || srtwfdslen > 0 {
                        let s = srtrfdslen > 0 ? srtrfds[0] : srtwfds[0]
                        guard let t = tar, t.getSRTSocket() == s else {
                            Logger.error("Unexpected socket poll: \(s)")
                            doabort = true;
                            setClientState(.error)
                            break;
                        }
                        
                        let dirstring = "target"
                        
                        let status = srt_getsockstate(s)
                        if false && status != SRTS_CONNECTED
                        {
                            Logger.debug("\(dirstring) status \(status)")
                        }
                        switch status
                        {
                        case SRTS_LISTENING:
                            if false && !quiet {
                                Logger.debug("New SRT client connection")
                            }
                            
                            guard let tar = tar else {
                                Logger.error("SRT client hasn't been created")
                                break
                            }
                            
                            let res = try tar.acceptNewClient()
                            if !res
                            {
                                Logger.error("Failed to accept SRT connection")
                                doabort = true;
                                setClientState(.error)
                                break
                            }
                            
                            srt_epoll_remove_usock(pollid, s)
                            
                            let ns = tar.getSRTSocket()
                            var events: Int32 = Int32(SRT_EPOLL_IN.rawValue | SRT_EPOLL_ERR.rawValue)
                            if srt_epoll_add_usock(pollid, ns, &events) != 0 {
                                Logger.error("Failed to add SRT client to poll, \(ns)")
                                doabort = true;
                                setClientState(.error)
                            }
                            else {
                                if !quiet {
                                    Logger.debug("Accepted SRT \(dirstring) connection")
                                }
                                tarConnected = true
                                setClientState(.connected)
                            }
                        case SRTS_BROKEN, SRTS_NONEXIST, SRTS_CLOSED:
                            if tarConnected {
                                if !quiet {
                                    Logger.debug("SRT target disconnected")
                                }
                                tarConnected = false;
                                setClientState(.notConnected)
                            }
                            
                            if !autoreconnect
                            {
                                doabort = true
                            }
                            else
                            {
                                // force re-connection
                                srt_epoll_remove_usock(pollid, s)
                                tar = nil
                            }
                        case SRTS_CONNECTED:
                            if !tarConnected {
                                if !quiet {
                                    Logger.debug("SRT target connected")
                                }
                                tarConnected = true;
                                setClientState(.connected)
                            }
                            
                        default:
                            // No-Op
                            break;
                        }
                    }
                    
                    if doabort {
                        break
                    }
                }
                else {
                    let str = String(cString: udtGetLastError().message)
                    Logger.debug(str)
                }
            }
        } catch {
            Logger.error("ERROR: \(error)")
            setClientState(.error)
        }
    }
    
    private func setClientState(_ state: SRTClientState) {
        self.state = state
        callback(self, state)
    }
    
}

