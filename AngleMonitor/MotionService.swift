import CoreMotion
import Foundation
import Combine

@MainActor
final class MotionService: ObservableObject {
    @Published private(set) var angle = 0.0
    @Published private(set) var absolutePitch: Double?
    @Published private(set) var mountingCorrection: Double?
    @Published private(set) var isAvailable = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var status = "センサー待機中"
    var onUpdate: ((Double, Date) -> Void)?

    private var absoluteAngleMode = false
    private let manager = CMMotionManager()
    private var filter = RelativePitchFilter(plane: .upright)
    private var lastShockLogTime = -Double.infinity
    private var lastTraceTime = -Double.infinity
    private let traceMotion = ProcessInfo.processInfo.arguments.contains("--trace-motion")

    func start() {
        guard manager.isDeviceMotionAvailable else {
            status = "この端末では姿勢センサーを利用できません"
            return
        }
        isAvailable = true
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error { self.status = "センサーエラー: \(error.localizedDescription)"; return }
            guard let motion else { return }
            let g = motion.gravity
            let current = RelativePitchFilter.Gravity(x: g.x, y: g.y, z: g.z)
            guard let sample = self.filter.update(current, timestamp: motion.timestamp) else {
                self.status = "姿勢データが不正のため前回値を保持"
                return
            }
            self.angle = sample.degrees
            self.absolutePitch = sample.absoluteDegrees
            self.mountingCorrection = self.filter.mountingCorrectionDegrees
            let a = motion.userAcceleration
            let acceleration = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            if (acceleration > 1.5 || sample.axisIsAmbiguous), motion.timestamp - self.lastShockLogTime >= 1 {
                self.lastShockLogTime = motion.timestamp
                print("[AngleMonitor] motion accelerationG=\(acceleration) raw=\(sample.rawDegrees.map(String.init(describing:)) ?? "undefined") filtered=\(sample.degrees) ambiguous=\(sample.axisIsAmbiguous)")
            }
            let now = Date()
            self.lastUpdate = now
            self.status = sample.axisIsAmbiguous ? "縦に立てて0°設定してください" : "測定中（\(self.filter.plane.rawValue)）"
            if self.traceMotion && motion.timestamp - self.lastTraceTime >= 0.5 {
                self.lastTraceTime = motion.timestamp
                print(String(format: "[AngleMonitor] inclination g=(%.3f,%.3f,%.3f) raw=%.2f filtered=%.2f mode=%@ accelerationG=%.2f", g.x, g.y, g.z, sample.rawDegrees ?? .nan, sample.degrees, self.filter.plane.rawValue, acceleration))
            }
            self.onUpdate?(self.angle, now)
        }
    }

    func setAbsoluteAngleMode(_ enabled: Bool) {
        absoluteAngleMode = enabled
        filter.setAbsoluteAngleMode(enabled)
        print("[AngleMonitor] absolute angle mode=\(enabled)")
    }

    func setVibrationSuppressionEnabled(_ enabled: Bool) {
        filter.setVibrationSuppressionEnabled(enabled)
        print("[AngleMonitor] vibration suppression=\(enabled)")
    }

    func resetZero() {
        guard !absoluteAngleMode else { return }
        guard let motion = manager.deviceMotion else { return }
        let g = motion.gravity
        guard filter.reset(to: RelativePitchFilter.Gravity(x: g.x, y: g.y, z: g.z)) else {
            status = "縦に立てて0°設定してください"
            return
        }
        print("[AngleMonitor] inclination zero reset mode=\(filter.plane.rawValue)")
        mountingCorrection = filter.mountingCorrectionDegrees
        // The next sensor sample refreshes the uncorrected absolute angle.
        angle = 0
        onUpdate?(0, Date())
    }

    func stop() { manager.stopDeviceMotionUpdates(); status = "停止中" }

}
