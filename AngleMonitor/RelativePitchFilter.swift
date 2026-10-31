import Foundation

/// Gravity-referenced inclination, independent of compass heading. The measuring
/// plane is configured explicitly, never inferred from a moving pose.
struct RelativePitchFilter {
    struct Gravity {
        let x: Double
        let y: Double
        let z: Double

        var normalized: Gravity? {
            let length = sqrt(x * x + y * y + z * z)
            guard length.isFinite, length > 1e-8 else { return nil }
            return Gravity(x: x / length, y: y / length, z: z / length)
        }
    }

    enum Plane: String {
        case upright = "縦向き"
        case flat = "平置き"
    }

    struct Sample {
        let degrees: Double
        let rawDegrees: Double?
        let axisIsAmbiguous: Bool
        var absoluteDegrees: Double? = nil
    }

    private struct Direction {
        let horizontal: Double
        let vertical: Double
    }

    let plane: Plane
    private(set) var mountingCorrectionDegrees: Double?
    private var sign = 1.0
    private var filteredAngle = 0.0
    private var previousTimestamp: TimeInterval?
    private(set) var vibrationSuppressionEnabled = false
    private var stableTarget = 0.0
    private var absoluteAngleMode = false
    private var seedNextSample = false

    mutating func setAbsoluteAngleMode(_ enabled: Bool) {
        guard absoluteAngleMode != enabled else { return }
        absoluteAngleMode = enabled
        seedNextSample = true
    }

    mutating func setVibrationSuppressionEnabled(_ enabled: Bool) {
        vibrationSuppressionEnabled = enabled
        // Preserve the baseline and displayed angle when switching modes.
        stableTarget = filteredAngle
    }

    init(plane: Plane = .upright) { self.plane = plane }

    @discardableResult
    mutating func reset(to gravity: Gravity) -> Bool {
        guard let g = gravity.normalized else { return false }
        // With the phone resting on its long side, neither intended zero pose
        // is established. Ask for a new zero instead of picking an unstable sign.
        let selectedPlane = plane
        guard abs(selectedPlane == .upright ? g.y : g.z) >= 0.25 else { return false }
        let selectedSign = (selectedPlane == .upright ? g.y : g.z) <= 0 ? 1.0 : -1.0
        sign = selectedSign
        let absolute = absolutePitch(for: g)
        mountingCorrectionDegrees = -sign * absolute
        filteredAngle = absoluteAngleMode ? absolute : 0
        stableTarget = filteredAngle
        previousTimestamp = nil
        return true
    }

    mutating func update(_ gravity: Gravity, timestamp: TimeInterval) -> Sample? {
        guard timestamp.isFinite, let g = gravity.normalized else { return nil }
        if let previousTimestamp, timestamp <= previousTimestamp { return nil }
        if mountingCorrectionDegrees == nil { _ = reset(to: g) }
        let dt = previousTimestamp.map { min(0.1, timestamp - $0) } ?? (1.0 / 60.0)
        previousTimestamp = timestamp
        let absolute = absolutePitch(for: g)
        guard absoluteAngleMode || mountingCorrectionDegrees != nil else {
            return Sample(degrees: filteredAngle, rawDegrees: nil, axisIsAmbiguous: true, absoluteDegrees: absolute)
        }
        // Absolute mode uses a fixed device-axis sign and never applies a zero
        // reference. Corrected mode retains the mounting orientation convention.
        let raw = absoluteAngleMode ? absolute : Self.signedDegrees(sign * absolute + (mountingCorrectionDegrees ?? 0))
        if seedNextSample {
            filteredAngle = raw
            stableTarget = raw
            seedNextSample = false
        }
        let target: Double
        if vibrationSuppressionEnabled {
            // A held target rejects tiny oscillations without quantizing the
            // rendered angle. Sustained changes still pass through smoothly.
            if abs(Self.signedDegrees(raw - stableTarget)) > 0.2 {
                stableTarget = raw
            }
            target = stableTarget
        } else {
            stableTarget = raw
            target = raw
        }
        let smoothingTimeConstant = vibrationSuppressionEnabled ? 0.35 : 0.075
        let smoothing = 1 - exp(-dt / smoothingTimeConstant)
        filteredAngle = Self.signedDegrees(filteredAngle + smoothing * Self.signedDegrees(target - filteredAngle))
        return Sample(degrees: filteredAngle, rawDegrees: raw, axisIsAmbiguous: false, absoluteDegrees: absolute)
    }

    private func absolutePitch(for gravity: Gravity) -> Double {
        let d = direction(for: gravity, plane: plane, sign: 1)
        // Upright mode: vertical screen = 0°, forward/backward = ±90°.
        // This is a gravity-defined inclination, not CMAttitude.pitch's Euler
        // representation, which folds at the upright pose.
        return atan2(d.vertical, d.horizontal) * 180 / .pi
    }

    private func direction(for g: Gravity, plane: Plane, sign: Double) -> Direction {
        switch plane {
        case .upright:
            // Screen normal's inclination: in-screen left/right lean changes
            // g.x/g.y but not g.z. World-vertical heading changes no gravity axis.
            return Direction(horizontal: hypot(g.x, g.y), vertical: sign * g.z)
        case .flat:
            // Long-edge elevation: lateral roll about that edge changes g.x/g.z,
            // while g.y (and therefore the forward/back inclination) is unchanged.
            return Direction(horizontal: hypot(g.x, g.z), vertical: -sign * g.y)
        }
    }

    private static func signedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return abs(value) < 1e-10 ? 0 : value
    }
}
