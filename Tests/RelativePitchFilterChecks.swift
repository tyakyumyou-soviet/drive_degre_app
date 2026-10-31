import Foundation

/// Ground truth comes from physical rotation matrices, not the filter's formula.
@main
struct RelativePitchFilterChecks {
    typealias G = RelativePitchFilter.Gravity
    typealias Matrix = [[Double]]
    static var checks = 0
    static func require(_ ok: @autoclosure () -> Bool, _ reason: String) {
        checks += 1; precondition(ok(), reason)
    }
    static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    static func rotation(_ degrees: Double, axis: Int) -> Matrix {
        let c = cos(degrees * .pi / 180), s = sin(degrees * .pi / 180)
        switch axis {
        case 0: return [[1,0,0],[0,c,-s],[0,s,c]]
        case 1: return [[c,0,s],[0,1,0],[-s,0,c]]
        default: return [[c,-s,0],[s,c,0],[0,0,1]]
        }
    }
    static func gravity(pitch: Double, side: Double = 0, heading: Double = 0,
                        plane: RelativePitchFilter.Plane = .upright, inverted: Bool = false) -> G {
        let offset = plane == .upright ? (inverted ? 270.0 : 90.0) : (inverted ? 180.0 : 0.0)
        // First pitch around the horizontal device X, then side lean around the
        // screen normal (upright) / long edge (flat). Heading is world vertical.
        let pose = multiply(rotation(heading, axis: 2),
                            multiply(rotation(offset + pitch, axis: 0), rotation(side, axis: plane == .upright ? 2 : 1)))
        // R^T * world gravity [0,0,-1], independently of the app's projection.
        return G(x: -pose[2][0], y: -pose[2][1], z: -pose[2][2])
    }
    struct Rig {
        var filter: RelativePitchFilter
        var time = 0.0
        init(plane: RelativePitchFilter.Plane = .upright) { filter = RelativePitchFilter(plane: plane) }
        mutating func step(_ g: G) -> RelativePitchFilter.Sample {
            time += 1.0 / 60
            let result = filter.update(g, timestamp: time)!
            RelativePitchFilterChecks.require(result.degrees.isFinite && (-180..<180).contains(result.degrees), "state escaped signed range")
            return result
        }
        mutating func settle(_ g: G) -> RelativePitchFilter.Sample {
            var result = step(g)
            for _ in 0..<240 { result = step(g) }
            return result
        }
    }
    static func main() {
        // Actual counterexample to the previous relative-X-twist method: start
        // upright, turn heading 90°, lean sideways 60°, with zero forward pitch.
        let oldRelativeX = -sin(Double.pi / 4) * sin(Double.pi / 6)
        let oldRelativeW = cos(Double.pi / 4) * cos(Double.pi / 6)
        let oldTwist = 2 * atan2(oldRelativeX, oldRelativeW) * 180 / .pi
        require(abs(oldTwist + 60) < 1e-8, "old cross-axis bug not reproduced")
        var regression = Rig()
        _ = regression.step(gravity(pitch: 0))
        let corrected = regression.settle(gravity(pitch: 0, side: 60, heading: 90))
        require(abs(corrected.degrees) < 1e-8, "side lean and heading became pitch")
        print("Cross-axis reproduction: previous twist=\(oldTwist)°, gravity-based pitch=\(corrected.degrees)° (expected 0°)")

        // Check known physical pitches at many headings, side leans and reset
        // inclinations. These test angle accuracy, not just bounded output.
        for plane in [RelativePitchFilter.Plane.upright, .flat] {
            for inverted in [false, true] {
                for zero in [-30.0, 0, 30] {
                    for pitch in stride(from: -80.0, through: 80.0, by: 5) {
                        for side in stride(from: -175.0, through: 175.0, by: 10) {
                            for heading in [0.0, 37, 90, 175, 270] {
                                var rig = Rig(plane: plane)
                                require(rig.filter.reset(to: gravity(pitch: zero, plane: plane, inverted: inverted)), "valid reset failed")
                                let result = rig.step(gravity(pitch: pitch, side: side, heading: heading, plane: plane, inverted: inverted))
                                require(abs(result.rawDegrees! - (pitch - zero)) < 1e-7, "wrong pitch: \(plane), zero=\(zero), pitch=\(pitch), side=\(side), heading=\(heading)")
                                require(rig.filter.plane == plane, "plane changed while moving")
                            }
                        }
                    }
                }
            }
        }

        // Repeated heading revolutions + side-to-side motion must preserve a
        // constant 12° forward pitch, then return to zero without reset.
        var repeated = Rig()
        _ = repeated.step(gravity(pitch: 0))
        for index in 0..<30_000 {
            let t = Double(index) / 60
            let result = repeated.step(gravity(pitch: 12, side: 170 * sin(t * 13), heading: t * 180))
            require(abs(result.rawDegrees! - 12) < 1e-7, "repeated sideways motion contaminated pitch")
        }
        require(abs(repeated.settle(gravity(pitch: 12)).degrees - 12) < 1e-6, "lost pitch after side motions")
        require(abs(repeated.settle(gravity(pitch: 0)).degrees) < 1e-6, "did not return to original zero")

        // Sideways-to-upright recovery must not silently change zero or mode.
        let before = repeated.step(gravity(pitch: 0, side: 90))
        require(!before.axisIsAmbiguous && abs(before.rawDegrees!) < 1e-7, "sideways orientation broke established zero")
        require(!repeated.filter.reset(to: G(x: 1,y: 0,z: 0)), "accepted undefined sideways zero")
        require(abs(repeated.settle(gravity(pitch: 0)).degrees) < 1e-6, "bad reset corrupted reference")
        require(repeated.filter.update(G(x: .nan,y: 0,z: -1), timestamp: repeated.time + 1) == nil, "accepted NaN")
        require(repeated.filter.update(G(x: 0,y: 0,z: 0), timestamp: repeated.time + 1) == nil, "accepted zero gravity")
        require(repeated.filter.update(gravity(pitch: 0), timestamp: .infinity) == nil, "accepted invalid time")
        require(repeated.filter.update(gravity(pitch: 0), timestamp: repeated.time) == nil, "accepted duplicate time")
        var initialSideways = Rig()
        require(initialSideways.step(G(x: 1,y: 0,z: 0)).axisIsAmbiguous, "sideways startup chose an unstable sign")
        require(!initialSideways.step(gravity(pitch: 0)).axisIsAmbiguous, "did not recover upright")

        // Simulated small gravity-estimate noise, with large lateral/heading
        // movements, remains small instead of accumulating revolutions.
        var noisy = Rig()
        _ = noisy.step(gravity(pitch: 0))
        for i in 0..<30_000 {
            let t = Double(i) / 60
            let g = gravity(pitch: 0, side: 170 * sin(t * 13), heading: t * 240)
            let sample = noisy.step(G(x: g.x + 0.01*sin(t*61), y: g.y + 0.01*cos(t*53), z: 0.01*sin(t*47)))
            require(abs(sample.degrees) < 1, "gravity noise accumulated into a large angle")
        }
        require(abs(noisy.settle(gravity(pitch: 0)).degrees) < 1e-6, "noise left a persistent offset")
        print("Passed \(checks) assertions. Synthetic physical poses cover forward pitch, side lean, heading, reset poses and noise; real vibration needs field verification.")
    }
}
