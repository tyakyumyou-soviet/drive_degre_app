import AVFoundation
import Foundation
import UIKit

final class LiveVideoPipeline {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let renderer = LevelRenderer()
    private let queue = DispatchQueue(label: "AngleMonitor.video", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var latest = AngleSnapshot(degrees: 0, sensorTime: nil, appState: "foreground")
    private var design = HUDDesign.b
    private let frameLock = NSLock()
    private var frameTime: Date?
    private var metricsStart = ProcessInfo.processInfo.systemUptime
    private var framesInWindow = 0
    private var droppedInWindow = 0
    private var maxRenderMilliseconds = 0.0

    var lastFrameTime: Date? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return frameTime
    }

    var displayReadiness: String {
        let ready: String
        if #available(iOS 17.4, *) {
            ready = displayLayer.isReadyForDisplay ? "準備完了" : "未準備"
        } else {
            ready = "状態取得非対応"
        }
        switch displayLayer.status {
        case .unknown: return "\(ready) / 待機"
        case .rendering: return "\(ready) / 再生中"
        case .failed: return "\(ready) / エラー: \(displayLayer.error?.localizedDescription ?? "不明")"
        @unknown default: return "\(ready) / 不明な状態"
        }
    }

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr,
           let timebase {
            displayLayer.controlTimebase = timebase
            // Frame PTS uses host time. A new timebase starts at zero, so it must
            // be aligned before playback or every frame is scheduled hours ahead.
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            let delta = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            print("[AngleMonitor] video clock delta seconds: \(delta)")
        }
    }
    func update(_ snapshot: AngleSnapshot) { queue.async { self.latest = snapshot } }
    func setDesign(_ design: HUDDesign) {
        queue.async {
            self.design = design
            print("[AngleMonitor] video design=\(design.rawValue)")
        }
    }
    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(LevelRenderer.frameRate)), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.renderFrame() }
        timer = source; source.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    private func renderFrame() {
        let now = Date(); let snap = latest
        let renderStart = ProcessInfo.processInfo.systemUptime
        defer {
            let end = ProcessInfo.processInfo.systemUptime
            maxRenderMilliseconds = max(maxRenderMilliseconds, (end - renderStart) * 1000)
            let elapsed = end - metricsStart
            if elapsed >= 5 {
                let sensorAge = snap.sensorTime.map { now.timeIntervalSince($0) * 1000 } ?? -1
                print(String(format: "[AngleMonitor] video fps=%.1f dropped=%d renderMaxMs=%.1f sensorAgeMs=%.1f app=%@", Double(framesInWindow) / elapsed, droppedInWindow, maxRenderMilliseconds, sensorAge, snap.appState))
                metricsStart = end; framesInWindow = 0; droppedInWindow = 0; maxRenderMilliseconds = 0
            }
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        // Drop before allocating/drawing when the layer cannot accept a frame.
        guard displayLayer.isReadyForMoreMediaData else { droppedInWindow += 1; return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sample = renderer.makeSample(angle: snap.degrees, timestamp: pts, appState: snap.appState, design: design) else { droppedInWindow += 1; return }
        displayLayer.enqueue(sample)
        frameLock.lock(); frameTime = now; frameLock.unlock()
        framesInWindow += 1
    }
}
