//
//  AudioEngine.swift
//  AVFoundationLooper
//
//  Created by David O'Neill on 4/23/19.
//  Copyright © 2019 O'Neill. All rights reserved.
//

import Foundation
import AVFoundation

// MediaTime is hostTime in seconds.
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
            case .looping, .awaitingRecordingStop:
                player.stop()
                state = .idle
            }
        }
    }

    private(set) var state = State.idle
    enum State {
        case idle
        case recording
        case awaitingRecordingStop // When a user presses stop, we may not have recieved all of our audio.
        case looping
    }

    // Set on init, must be standard float
    private let format: AVAudioFormat

    // Used to synchronize access to recordedBuffers and state.
    private let bufferQueue = DispatchQueue(label: "bufferQueue")

    // This is cached to make sure we don't miss the beginning of our recording.
    private var previousBuffer: Buffer?

    // During recording, buffers retrieved through input tap are collected here
    private var recordedBuffers = [Buffer]()

    private var recordStartTime = MediaTime(0)
    private var recordStopTime = MediaTime(0)

    private let avAudioEngine = AVAudioEngine()
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

    // Convenience to tie a time to a buffer.
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

    private func tapInput() {
        inputMixer.installTap(onBus: 0, bufferSize: 4096, format: inputMixer.outputFormat(forBus: 0)) { (audioBuffer, audioTime) in
            self.bufferQueue.sync {
                let buffer = Buffer(audioBuffer: audioBuffer, audioTime: audioTime)
                self.handleInput(buffer: buffer)
                self.previousBuffer = buffer
            }
        }
    }

    private func startRecording(time: MediaTime) {
        guard state == .idle else { return }

        recordStartTime = time + AVAudioSession.sharedInstance().inputLatency
        state = .recording
        recordedBuffers.removeAll()

        if let previousBuffer = self.previousBuffer {
            recordedBuffers.append(previousBuffer)
        }

    }

    private func handleInput(buffer: Buffer) {
        switch state {
        case .recording:
            recordedBuffers.append(buffer)
        case .awaitingRecordingStop:

            guard buffer.startTime < recordStopTime else { break }

            let isFinalBuffer = buffer.endTime >= recordStopTime
            if isFinalBuffer {
                // Effectively truncates the end of the buffer
                buffer.audioBuffer.frameLength -= AVAudioFrameCount((buffer.endTime - recordStopTime) * format.sampleRate)
            }

            player.scheduleBuffer(buffer.audioBuffer)
            recordedBuffers.append(buffer)

            if isFinalBuffer {
                // Audio has been scheduled all the way through recordStopTime, we can now create a complete buffer and loop it.
                let loopBuffer = readBuffers(startTime: recordStartTime, endTime: recordStopTime)
                player.scheduleBuffer(loopBuffer, at: nil, options: [.loops])
                state = .looping
            }

        default:
            break
        }

    }

    private func stopRecording(time: MediaTime) {
        switch state {
        case .recording:
            startLooping(endTime: time + AVAudioSession.sharedInstance().inputLatency)
        default:
            break
        }
    }

    private func startLooping(endTime: MediaTime) {

        guard let lastRenderTime = player.lastRenderTime,
            let recordedEndTime = recordedBuffers.last?.endTime else {
            state = .idle
            return
        }


        let outputLatency = AVAudioSession.sharedInstance().outputLatency
        let bufferDuration = AVAudioSession.sharedInstance().ioBufferDuration

        // Can't start playback in the past, so needs to be in the future.
        let safeStartMediaTime = lastRenderTime.mediaTime + bufferDuration + outputLatency
        let playbackStartTime = max(safeStartMediaTime, endTime)

        // Since we are starting playback at a future time, In order to align the playback of the beginning
        // of the recording with `endTime`, we might need to truncate the head of the buffer.
        let durationTruncatedFromHead = playbackStartTime - endTime
        let partialBuffer = readBuffers(startTime: recordStartTime + durationTruncatedFromHead, endTime: endTime)

        player.scheduleBuffer(partialBuffer)
        player.play(at: AVAudioTime(hostTime: UInt64((playbackStartTime - outputLatency) / ticksToSeconds)))

        if recordedEndTime >= endTime {
            let loopBuffer = readBuffers(startTime: recordStartTime, endTime: endTime)
            player.scheduleBuffer(loopBuffer, at: nil, options: [.loops])
            state = .looping
        } else {
            recordStopTime = endTime
            state = .awaitingRecordingStop
        }

    }

    private func readBuffers(startTime: MediaTime, endTime: MediaTime) -> AVAudioPCMBuffer {

        let frameCapacity = recordedBuffers.reduce(0) { $0 + $1.audioBuffer.frameLength }
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            fatalError("Couldn't allocate buffer!")
        }

        for buffer in recordedBuffers {
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

