//
//  ViewController.swift
//  AVFoundationLooper
//
//  Created by David O'Neill on 4/23/19.
//  Copyright © 2019 O'Neill. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    var audioEngine: AudioEngine?

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        observeAudioInterruptions()
    }

    deinit {
        stopObservingAudioInterruptions()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.addSubview(loopButton)
        self.view.backgroundColor = .black
        NSLayoutConstraint.activate([
            loopButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loopButton.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private var firstAppearance = true
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if firstAppearance {
            firstAppearance = false
            enableMicAndStartAudio()
        }
    }

    @objc func enableMicAndStartAudio() {
        if audioEngine == nil {
            requestMicPermission {
                do {
                    try self.startAudioEngine()
                } catch {
                    self.showFailure(error.localizedDescription)
                }
            }
        }
    }

    func requestMicPermission(completion: @escaping ()->Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { recordPermission in
            doOnMainThread {
                if recordPermission {
                    completion()
                } else {
                    self.showFailure("Need mic access for this demo to work") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            }
        }
    }

    func startAudioEngine() throws {
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setActive(true)
        try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try audioSession.setPreferredIOBufferDuration(256 / audioSession.sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: audioSession.sampleRate, channels: 2) else {
            throw NSError(domain: "AVFoundationLooper", code: 0, userInfo: [NSLocalizedDescriptionKey:"Bunk Format"])
        }

        audioEngine?.stop()
        audioEngine = try AudioEngine(standardFormat: format)
        try audioEngine?.start()
    }

    func showFailure(_ message: String? = nil, completion: (()->Void)? = nil) {
        let alert = UIAlertController(title: "Fail!", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in completion?() } ))
        self.present(alert, animated: true, completion: nil)
    }


    lazy var loopButton: UIButton = {
        let button = UIButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(loopButtonAction(button:event:)), for: .touchDown)
        button.setTitle("Record", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 40)
        return button
    }()

    @objc func loopButtonAction(button: UIButton, event: UIEvent) {



        audioEngine?.toggleLooping(time: event.timestamp)

        switch audioEngine?.state ?? .idle {
        case .recording:
            button.setTitle("Loop", for: .normal)
        case .looping, .awaitingRecordingStop:
            button.setTitle("Clear", for: .normal)
        case .idle:
            button.setTitle("Record", for: .normal)
        }

        button.transform = CGAffineTransform(scaleX: 2, y: 2)
        UIView.animate(withDuration: 0.1, delay: 0, options: .allowUserInteraction, animations: {
            button.transform = .identity
        }, completion: nil)
    }
}





private let interruptionNotifactionNames = [UIApplication.willEnterForegroundNotification,
                                            AVAudioSession.routeChangeNotification,
                                            AVAudioSession.interruptionNotification,
                                            AVAudioSession.mediaServicesWereResetNotification]

extension ViewController { // Brute force interruption handling, discards loop :)
    func observeAudioInterruptions() {
        for name in interruptionNotifactionNames {
            NotificationCenter.default.addObserver(self, selector: #selector(enableMicAndStartAudio), name: name, object: nil)
        }
    }

    func stopObservingAudioInterruptions() {
        for name in interruptionNotifactionNames {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
    }
}


// Utility
private func doOnMainThread(action: @escaping ()->Void) {
    if Thread.current.isMainThread {
        action()
    } else {
        DispatchQueue.main.async { action() }
    }
}
