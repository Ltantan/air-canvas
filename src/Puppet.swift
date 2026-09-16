import Foundation
import SceneKit

/// A theatrical reconstruction from a two-handed phone grip, never measured body tracking.
struct PuppetMotion {
    enum Joint: Int, CaseIterable {
        case hip, chest, neck, head
        case leftShoulder, leftElbow, leftHand, rightShoulder, rightElbow, rightHand
        case leftHip, leftKnee, leftFoot, rightHip, rightKnee, rightFoot
    }
    struct Frame {
        var time: Double
        var joints: [SIMD3<Float>]
    }
    let frames: [Frame]
    let floor: Float
    let bounds: (center: SIMD3<Float>, extent: Float)

    init(poses: [DevicePose]) {
        guard let first = poses.first else {
            frames = []; floor = 0; bounds = (.zero, 1); return
        }
        // Assume a 170cm person initially holding the phone near chest height.
        // A single fixed floor keeps the reconstruction stable when seeking backwards.
        floor = min(first.position.y - 1.25, (poses.map(\.position.y).min() ?? first.position.y) - 0.18)
        var result: [Frame] = []
        var forward = SIMD3<Float>(0, 0, -1)
        var root = first.position
        var feet = [SIMD3<Float>.zero, SIMD3<Float>.zero]
        var stepStart = feet, stepEnd = feet
        var stepping: Int?
        var stepTime = 0.0
        var nextFoot = 0
        var previousTime = first.time
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for (index, pose) in poses.enumerated() {
            let dt = max(0, pose.time - previousTime)
            let reset = index == 0 || dt >= 0.3
            let rotation = simd_quatf(vector: pose.rotation)
            var direction = rotation.act([0, 0, -1])
            direction.y = 0
            if simd_length(direction) > 0.15 {
                direction = simd_normalize(direction)
                let blend = reset ? Float(1) : Float(1 - exp(-dt * 5))
                let mixed = forward + (direction - forward) * blend
                if simd_length(mixed) > 0.001 { forward = simd_normalize(mixed) }
            }
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            var desiredRoot = pose.position - forward * 0.38
            desiredRoot.y = floor
            root = reset ? desiredRoot : root + (desiredRoot - root) * Float(1 - exp(-dt * 3))
            // Keep a rapidly moving phone within a plausible arm's reach of the torso.
            var lag = desiredRoot - root
            lag.y = 0
            if simd_length(lag) > 0.28 { root = desiredRoot - simd_normalize(lag) * 0.28 }
            let hipY = max(floor + 0.38, min(floor + 0.91, pose.position.y - 0.35))
            let crouch = max(0, min(1, (floor + 1.05 - pose.position.y) / 0.7))
            let hip = SIMD3<Float>(root.x, hipY, root.z) - forward * crouch * 0.08
            let chest = hip + SIMD3<Float>(0, 0.43 - crouch * 0.12, 0) + forward * crouch * 0.2
            let neck = chest + SIMD3<Float>(0, 0.12, 0)
            let head = neck + SIMD3<Float>(0, 0.14, 0) + forward * 0.025
            let shoulders = [chest - right * 0.18, chest + right * 0.18]
            let hands = [pose.position + rotation.act([-0.045, 0, 0]), pose.position + rotation.act([0.045, 0, 0])]
            let hips = [hip - right * 0.12, hip + right * 0.12]
            let targets = [root - right * 0.16, root + right * 0.16]
            if reset {
                feet = targets; stepping = nil; nextFoot = 0
            }
            if let side = stepping {
                let t = Float(min(1, (pose.time - stepTime) / 0.32))
                let smooth = t * t * (3 - 2 * t)
                feet[side] = stepStart[side] + (stepEnd[side] - stepStart[side]) * smooth
                feet[side].y += sin(t * .pi) * 0.1
                if t >= 1 { stepping = nil; nextFoot = 1 - side }
            }
            if stepping == nil {
                let other = 1 - nextFoot
                let side = simd_distance(feet[nextFoot], targets[nextFoot]) > 0.13 ? nextFoot : other
                if simd_distance(feet[side], targets[side]) > 0.13 {
                    stepping = side; stepTime = pose.time
                    stepStart[side] = feet[side]; stepEnd[side] = targets[side]
                }
            }
            var joints = [SIMD3<Float>](repeating: .zero, count: Joint.allCases.count)
            joints[Joint.hip.rawValue] = hip; joints[Joint.chest.rawValue] = chest
            joints[Joint.neck.rawValue] = neck; joints[Joint.head.rawValue] = head
            for side in 0...1 {
                let elbow = Self.bend(from: shoulders[side], to: hands[side], upper: 0.3, lower: 0.28,
                                      pole: right * (side == 0 ? -1 : 1) - SIMD3<Float>(0, 0.8, 0))
                let knee = Self.bend(from: hips[side], to: feet[side], upper: 0.47, lower: 0.46, pole: forward)
                let arm = side == 0 ? Joint.leftShoulder.rawValue : Joint.rightShoulder.rawValue
                joints[arm] = shoulders[side]; joints[arm + 1] = elbow; joints[arm + 2] = hands[side]
                let leg = side == 0 ? Joint.leftHip.rawValue : Joint.rightHip.rawValue
                joints[leg] = hips[side]; joints[leg + 1] = knee; joints[leg + 2] = feet[side]
            }
            for point in joints { low = simd_min(low, point); high = simd_max(high, point) }
            result.append(Frame(time: pose.time, joints: joints))
            previousTime = pose.time
        }
        frames = result
        bounds = ((low + high) / 2, max(0.2, simd_length(high - low) + 0.3))
    }

    /// Two-link IK. Extreme gestures may stretch a cartoon limb instead of losing the grip.
    static func bend(from start: SIMD3<Float>, to end: SIMD3<Float>, upper: Float, lower: Float, pole: SIMD3<Float>) -> SIMD3<Float> {
        let delta = end - start
        let distance = simd_length(delta)
        guard distance > 0.00001 else { return start + SIMD3<Float>(0, -upper, 0) }
        let axis = delta / distance
        let stretch = max(1, distance / (upper + lower) * 1.001)
        let a = upper * stretch, b = lower * stretch
        let along = max(-a, min(a, (a * a - b * b + distance * distance) / (2 * distance)))
        let height = sqrt(max(0, a * a - along * along))
        var perpendicular = pole - axis * simd_dot(pole, axis)
        if simd_length(perpendicular) < 0.0001 {
            perpendicular = simd_cross(axis, abs(axis.x) < 0.8 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0))
        }
        return start + axis * along + simd_normalize(perpendicular) * height
    }

    func joints(at time: Double) -> [SIMD3<Float>]? {
        guard let first = frames.first, let last = frames.last,
              time >= first.time, time <= last.time + 0.12 else { return nil }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let a = frames[max(0, low - 1)]
        guard low < frames.count else { return a.joints }
        let b = frames[low]
        guard b.time - a.time < 0.3 else { return time - a.time < 0.12 ? a.joints : nil }
        let fraction = Float((time - a.time) / max(0.00001, b.time - a.time))
        return zip(a.joints, b.joints).map { $0 + ($1 - $0) * fraction }
    }
}

final class PuppetNode: SCNNode {
    private let bones: [(PuppetMotion.Joint, PuppetMotion.Joint)] = [
        (.hip, .chest), (.chest, .neck), (.neck, .head),
        (.leftShoulder, .rightShoulder), (.leftHip, .rightHip),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftHand),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightHand),
        (.leftHip, .leftKnee), (.leftKnee, .leftFoot),
        (.rightHip, .rightKnee), (.rightKnee, .rightFoot)
    ]
    private var limbs: [SCNNode] = []
    private var dots: [SCNNode] = []
    private let face = SCNNode()

    override init() {
        super.init()
        let material = SCNMaterial()
        material.diffuse.contents = InkColor(red: 0.7, green: 0.8, blue: 1, alpha: 1)
        material.roughness.contents = 0.8
        for (index, _) in bones.enumerated() {
            let shape = SCNCylinder(radius: index == 0 ? 0.075 : 0.025, height: 1)
            shape.radialSegmentCount = 10
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            addChildNode(node); limbs.append(node)
        }
        for joint in PuppetMotion.Joint.allCases {
            let shape = SCNSphere(radius: joint == .head ? 0.115 : 0.035)
            shape.segmentCount = 12
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            addChildNode(node); dots.append(node)
        }
        // A small nose makes the gaze readable from an overhead view.
        let nose = SCNSphere(radius: 0.035)
        nose.firstMaterial?.diffuse.contents = InkColor.systemOrange
        face.geometry = nose
        addChildNode(face)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ joints: [SIMD3<Float>]) {
        for (index, bone) in bones.enumerated() {
            let start = joints[bone.0.rawValue], end = joints[bone.1.rawValue]
            let delta = end - start, length = simd_length(end - start)
            limbs[index].simdPosition = (start + end) / 2
            limbs[index].simdScale = [1, max(0.00001, length), 1]
            if length > 0.00001 { limbs[index].simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length) }
        }
        for (index, point) in joints.enumerated() { dots[index].simdPosition = point }
        let head = joints[PuppetMotion.Joint.head.rawValue]
        let hand = (joints[PuppetMotion.Joint.leftHand.rawValue] + joints[PuppetMotion.Joint.rightHand.rawValue]) / 2
        let gaze = hand - head
        face.simdPosition = head + (simd_length(gaze) > 0.001 ? simd_normalize(gaze) : SIMD3<Float>(0, 0, -1)) * 0.105
        isHidden = false
    }
}
