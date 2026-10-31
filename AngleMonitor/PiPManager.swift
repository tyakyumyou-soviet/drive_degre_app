import AVKit
import AVFoundation
import Foundation
import Combine

@MainActor
final class PiPManager: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false
    @Published private(set) var status = "PiP未開始"
    private let pipeline: LiveVideoPipeline
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var layerReadyObservation: NSKeyValueObservation?
    private var startWhenPossible = false

    init(pipeline: LiveVideoPipeline) { self.pipeline = pipeline; super.init() }

    func prepare() {
        guard controller == nil else { return }
        guard isSupported else { status = "この端末ではPiPを利用できません"; return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: pipeline.displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        controller = pip
        if #available(iOS 17.4, *) {
            layerReadyObservation = pipeline.displayLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if layer.isReadyForDisplay {
                        self.controller?.invalidatePlaybackState()
                    }
                    self.refreshAvailability()
                }
            }
        }
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observedController, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateAvailability(observedController.isPictureInPicturePossible, controller: observedController)
            }
        }
        isPossible = pip.isPictureInPicturePossible
        status = isPossible ? "PiP開始可能" : "PiP準備中（映像待ち）"
    }

    func start() {
        // Configure playback before waiting for eligibility; doing this only
        // after isPictureInPicturePossible can leave startup waiting forever.
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            status = "PiP準備エラー: \(error.localizedDescription)"
            return
        }
        if controller == nil { prepare() }
        guard controller != nil else { return }
        pipeline.start()
        startWhenPossible = true
        status = "PiP準備中（映像の再生可能化を待っています）"
        refreshAvailability()
    }
    func stop() {
        startWhenPossible = false
        controller?.stopPictureInPicture()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true; status = "PiP表示中"
        print("[AngleMonitor] PiP did start")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        startWhenPossible = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "PiP終了"
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        startWhenPossible = false
        status = "PiP開始エラー: \(error.localizedDescription)"
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) { /* Live monitor has no pause control. */ }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .zero, duration: .positiveInfinity) }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) { completionHandler() }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }

    private func beginPictureInPicture(using controller: AVPictureInPictureController) {
        status = "PiPを開始しています…"
        print("[AngleMonitor] requesting PiP start")
        controller.startPictureInPicture()
    }

    private func refreshAvailability() {
        guard let controller else { return }
        controller.invalidatePlaybackState()
        updateAvailability(controller.isPictureInPicturePossible, controller: controller)
    }

    private func updateAvailability(_ possible: Bool, controller: AVPictureInPictureController) {
        isPossible = possible
        print("[AngleMonitor] PiP possible=\(possible), layer=\(pipeline.displayReadiness)")
        if startWhenPossible && possible {
            startWhenPossible = false
            beginPictureInPicture(using: controller)
        } else if !isActive && !startWhenPossible {
            status = possible ? "PiP開始可能" : "PiP準備中（映像待ち）"
        }
    }
}
