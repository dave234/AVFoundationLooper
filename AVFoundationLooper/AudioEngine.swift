//
//  AudioEngine.swift
//  AVFoundationLooper
//
//  Created by David O'Neill on 4/23/19.
//  Copyright © 2019 O'Neill. All rights reserved.
//

import Foundation
import AVFoundation

typealias MediaTime = Double

class AudioEngine {

    init(standardFormat: AVAudioFormat) throws {
        guard standardFormat.isStandard else { throw AudioEngineError.nonStandardFormat }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw AudioEngineError.noMicAccess }

        self.format = standardFormat
        self.connectNodes()
        self.tapInput()
    }

    deinit {
        stop()
        inputMixer.removeTap(onBus: 0)
    }

    func start() throws {
        if !avAudioEngine.isRunning {
            try avAudioEngine.start()
        }
    }

    func stop() {
        avAudioEngine.stop()
    }

    func toggleLooping(time: MediaTime) {
        bufferQueue.sync {
            switch state {
            case .idle:
                startRecording(time: time)
            case .recording:
                stopRecording(time: time)
            case .looping:
                player.stop()
                state = .idle
            default:
                break
            }
        }
    }

    private let avAudioEngine = AVAudioEngine()
    private let format: AVAudioFormat

    // Allocate enough memory to cache the beginning of a live recording. - 0.5 seconds
    private let loopStartBufferDur = Double(0.5)
    private lazy var loopStartBuffer: AVAudioPCMBuffer = {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * loopStartBufferDur)) else {
            fatalError("Couldn't create buffer")
        }
        return buffer
    }()

    private var loopBuffer: AVAudioPCMBuffer?

    private lazy var inputMixer: AVAudioMixerNode = {
        let mixer = AVAudioMixerNode()
        avAudioEngine.attach(mixer)
        return mixer
    }()

    private lazy var micMuteMixer: AVAudioMixerNode = {
        let mixer = AVAudioMixerNode()
        avAudioEngine.attach(mixer)
        mixer.outputVolume = 0
        return mixer
    }()

    private lazy var inputNode = avAudioEngine.inputNode
    private lazy var outputMixer = avAudioEngine.mainMixerNode

    private lazy var player: AVAudioPlayerNode = {
        let player = AVAudioPlayerNode()
        avAudioEngine.attach(player)
        return player
    }()

    private func connectNodes() {
        avAudioEngine.connect(inputNode, to: inputMixer, format: inputNode.outputFormat(forBus: 0))
        avAudioEngine.connect(inputMixer, to: micMuteMixer, format: format)
        avAudioEngine.connect(micMuteMixer, to: outputMixer, format: format)

        avAudioEngine.connect(player, to: outputMixer, format: format)
    }

    private struct Buffer {
        let audioBuffer: AVAudioPCMBuffer
        let audioTime: AVAudioTime

        var startTime: Double {
            return audioTime.mediaTime
        }

        var endTime: Double {
            return startTime + audioBuffer.duration
        }
    }

    private let bufferQueue = DispatchQueue(label: "bufferQueue")
    private var previousBuffer: Buffer?
    private func tapInput() {
        inputMixer.installTap(onBus: 0, bufferSize: 4096, format: inputMixer.outputFormat(forBus: 0)) { (audioBuffer, audioTime) in
            self.bufferQueue.sync {
                let buffer = Buffer(audioBuffer: audioBuffer, audioTime: audioTime)
                self.handleInput(buffer: buffer)
                self.previousBuffer = buffer
            }
        }
    }

    private var recordedBuffers = [Buffer]()
    private func handleInput(buffer: Buffer) {
        switch state {
        case .recording:
            recordedBuffers.append(buffer)
        case .awaitingRecordingStop(let recordStopTime):

            guard buffer.startTime < recordStopTime else { fatalError() }

            let isFinalBuffer = buffer.endTime >= recordStopTime
            if isFinalBuffer {
                // Effectively truncates the end of the buffer
                buffer.audioBuffer.frameLength -= AVAudioFrameCount((buffer.endTime - recordStopTime) * format.sampleRate)
            }

            player.scheduleBuffer(buffer.audioBuffer)
            recordedBuffers.append(buffer)

            if isFinalBuffer {
                // Audio has been scheduled all the way through recordStopTime, we can now create a complete buffer and loop it.
                let loopBuffer = joinContigous(buffers: recordedBuffers, startTime: recordStartTime, endTime: recordStopTime)
                player.scheduleBuffer(loopBuffer, at: nil, options: [.loops])
                state = .looping
            }

        default:
            break
        }

    }

    enum State {
        case idle
        case recording
        case awaitingRecordingStop(MediaTime)
        case looping
    }

    var state = State.idle
    private var recordStartTime = MediaTime(0)
    private func startRecording(time: MediaTime) {
        switch state {
        case .recording, .awaitingRecordingStop, .looping:
            return
        case .idle:
            break
        }

        recordStartTime = time
        state = .recording
        recordedBuffers.removeAll()
        if let previousBuffer = self.previousBuffer {
            recordedBuffers.append(previousBuffer)
        }

    }



    private func stopRecording(time: MediaTime) {
        switch state {
        case .recording:
            startLooping(buffers: self.recordedBuffers, startTime: recordStartTime, endTime: time)
        default:
            break
        }
    }

    private func startLooping(buffers: [Buffer], startTime: MediaTime, endTime: MediaTime) {

        guard let lastRenderTime = player.lastRenderTime,
            let recordedEndTime = buffers.last?.endTime else {
            state = .idle
            return
        }

        // Can't start playback in the past, so needs to be in the future.
        let safeStartMediaTime = lastRenderTime.mediaTime + AVAudioSession.sharedInstance().ioBufferDuration

        // Since we are starting playback at a future time, In order to align the playback of the beginning
        // of the recording with `endTime`, we need to truncate the head of the buffer.
        let durationTruncatedFromHead = safeStartMediaTime - endTime
        let partialBuffer = joinContigous(buffers: buffers, startTime: startTime + durationTruncatedFromHead, endTime: endTime)

        player.scheduleBuffer(partialBuffer, completionHandler: nil)
        player.play(at: AVAudioTime(hostTime: UInt64(safeStartMediaTime / ticksToSeconds)))

        if recordedEndTime >= endTime {
            let loopBuffer = joinContigous(buffers: buffers, startTime: startTime, endTime: endTime)
            player.scheduleBuffer(loopBuffer, at: nil, options: [.loops])
            state = .looping
        } else {
            state = .awaitingRecordingStop(endTime)
        }

    }

    private func joinContigous(buffers: [Buffer], startTime: MediaTime, endTime: MediaTime) -> AVAudioPCMBuffer {
        let roundingTolerance = AVAudioFrameCount(2)
        let finalFrameCount = AVAudioFrameCount(round((endTime - startTime) * format.sampleRate))
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: finalFrameCount + roundingTolerance) else {
                                                    fatalError("Couldn't allocate buffer!")
        }

        for buffer in buffers {
            copyToBuffer(source: buffer, to: audioBuffer, within: startTime..<endTime)
        }

        return audioBuffer
    }

    private func copyToBuffer(source: Buffer, to destination: AVAudioPCMBuffer, within range: Range<MediaTime>) {

        let startTime = range.lowerBound
        let endTime = range.upperBound

        guard source.endTime > startTime && source.startTime < endTime else { return }

        let shouldTruncateBeginning = source.startTime < startTime && source.endTime > startTime
        let shouldTruncateEnd = source.startTime < endTime && source.endTime > endTime

        let readOffset = shouldTruncateBeginning ? Int((startTime - source.startTime) * format.sampleRate) : 0
        var framesToCopy = Int(source.audioBuffer.frameLength) - readOffset
        if shouldTruncateEnd {
            framesToCopy -= Int((source.endTime - endTime) * format.sampleRate)
        }

        destination.copy(from: source.audioBuffer,
                         readOffset: readOffset,
                         writeOffset: Int(destination.frameLength),
                         frameCount: framesToCopy)

        destination.frameLength += AVAudioFrameCount(framesToCopy)
    }

}




enum AudioEngineError: String, LocalizedError {
    case nonStandardFormat = "Non Standard Format"
    case noMicAccess = "No Mic Access"

    public var errorDescription: String? {
        return self.rawValue
    }
}

private let ticksToSeconds: Double = {
    var tinfo = mach_timebase_info(numer: 0, denom: 0)
    mach_timebase_info(&tinfo)
    return Double(tinfo.numer) / Double(tinfo.denom) * 0.000000001
}()


private extension AVAudioTime {
    var mediaTime: MediaTime {
        return Double(hostTime) * ticksToSeconds
    }
}

private extension AVAudioPCMBuffer {

    var duration: Double {
        return Double(frameLength) / format.sampleRate
    }

    func copy(from buffer: AVAudioPCMBuffer, readOffset: Int, writeOffset: Int, frameCount: Int) {

        guard self.format.isStandard && self.format == buffer.format else { fatalError() }
        guard readOffset + frameCount <= buffer.frameCapacity && writeOffset + frameCount <= self.frameCapacity else { fatalError() }
        guard frameCount > 0 else { return }

        guard let src = buffer.floatChannelData, let dst = self.floatChannelData else { fatalError() }
        let frameSize = Int(self.format.streamDescription.pointee.mBytesPerFrame)
        for channel in 0 ..< Int(self.format.channelCount) {
            memcpy(dst[channel] + Int(writeOffset), src[channel] + Int(readOffset), frameCount * frameSize)
        }

    }

}

