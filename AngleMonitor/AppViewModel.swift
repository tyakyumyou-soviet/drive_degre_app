import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class AppViewModel: ObservableObject {
    let motion = MotionService()
    let pipeline = LiveVideoPipeline()
    let pip: PiPManager
    @Published private(set) var appState = "foreground"
    @Published private(set) var lastFrame: Date?
    @Published var design: HUDDesign = .c {
        didSet {
            UserDefaults.standard.set(design.rawValue, forKey: "hudDesign")
            pipeline.setDesign(design)
        }
    }
    @Published var vibrationSuppressionEnabled = false {
        didSet {
            UserDefaults.standard.set(vibrationSuppressionEnabled, forKey: "vibrationSuppressionEnabled")
            motion.setVibrationSuppressionEnabled(vibrationSuppressionEnabled)
        }
    }
    @Published var absoluteAngleMode = false {
        didSet {
            UserDefaults.standard.set(absoluteAngleMode, forKey: "absoluteAngleMode")
            motion.setAbsoluteAngleMode(absoluteAngleMode)
        }
    }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        pip = PiPManager(pipeline: pipeline)
        design = UserDefaults.standard.string(forKey: "hudDesign").flatMap(HUDDesign.init(rawValue:)) ?? .c
        pipeline.setDesign(design)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appState = "background" }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appState = "foreground" }
        })
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--export-hud") {
            LevelRenderer().exportDiagnosticFrames()
        }
        #endif
        motion.onUpdate = { [weak self] angle, date in
            guard let self else { return }
            self.pipeline.update(AngleSnapshot(degrees: angle, sensorTime: date, appState: self.appState))
        }
        vibrationSuppressionEnabled = UserDefaults.standard.bool(forKey: "vibrationSuppressionEnabled")
        motion.setVibrationSuppressionEnabled(vibrationSuppressionEnabled)
        absoluteAngleMode = UserDefaults.standard.bool(forKey: "absoluteAngleMode")
        motion.setAbsoluteAngleMode(absoluteAngleMode)
        motion.start()
        pipeline.start()
        // This timer only refreshes diagnostic text; it no longer gates live video.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastFrame = self.pipeline.lastFrameTime
            }
        }
    }
    func reset() { motion.resetZero() }
    func deinitStop() { timer?.invalidate(); pipeline.stop(); motion.stop() }
}
