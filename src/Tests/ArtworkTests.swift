import Foundation
import SceneKit

@main
enum ArtworkTests {
    static func main() throws {
        let identity = matrix_identity_float4x4
        func line(_ z: Float) -> InkStroke {
            InkStroke(color: 0, radius: 0.004, points: [
                InkPoint(position: [-0.1, 0, z], time: 0),
                InkPoint(position: [0.1, 0, z], time: 1)
            ])
        }
        // Mid-segment overlap: endpoint-only distance would incorrectly miss this.
        let overlap = InkGeometry.guidance(strokes: [line(-0.3)], camera: identity, radius: 0.004)
        precondition(overlap.overlaps)
        let farther = InkGeometry.guidance(strokes: [line(-0.5)], camera: identity, radius: 0.004)
        precondition(!farther.overlaps && abs(farther.depthOffset! - 0.2) < 0.0001)
        let nearer = InkGeometry.guidance(strokes: [line(-0.15)], camera: identity, radius: 0.004)
        precondition(!nearer.overlaps && abs(nearer.depthOffset! + 0.15) < 0.0001)
        let behind = InkGeometry.guidance(strokes: [line(0.2)], camera: identity, radius: 0.004)
        precondition(behind.depthOffset == nil)
        var translatedCamera = identity
        translatedCamera.columns.3 = [1, 2, 3, 1]
        var translatedLine = line(-0.3)
        translatedLine.points = translatedLine.points.map { InkPoint(position: $0.position + SIMD3<Float>(1, 2, 3), time: $0.time) }
        precondition(InkGeometry.guidance(strokes: [translatedLine], camera: translatedCamera, radius: 0.004).overlaps)
        let dot = InkStroke(color: 1, radius: 0.009, points: [InkPoint(position: [0, 0, -0.3], time: 2)])
        precondition(InkGeometry.guidance(strokes: [dot], camera: identity, radius: 0.004).overlaps)

        let a = DevicePose(position: [0, 0, 0], rotation: [0, 0, 0, 1], time: 0)
        let b = DevicePose(position: [0.1, 0, 0], rotation: [0, 0, 0, 1], time: 0.1)
        let c = DevicePose(position: [5, 0, 0], rotation: [0, 0, 0, 1], time: 1)
        let artwork = Artwork(strokes: [line(-0.3), dot], poses: [a, b, c])
        precondition(abs(artwork.pose(at: 0.05)!.position.x - 0.05) < 0.0001)
        precondition(artwork.pose(at: 0.5) == nil, "Must hide the device across tracking gaps")
        precondition(artwork.pose(at: 1.5) == nil, "Must not invent positions after recording stops")
        let puppet = PuppetMotion(poses: [a, b, c])
        precondition(puppet.joints(at: 0.5) == nil, "Puppet must disappear across tracking gaps")
        precondition(puppet.joints(at: 1.5) == nil)
        precondition(PuppetMotion(poses: []).joints(at: 0) == nil)
        var gestures: [DevicePose] = []
        for index in 0..<160 {
            let t = Double(index) * 0.1
            let position = SIMD3<Float>(Float(t) * 0.09, 1.25 + 0.55 * sin(Float(t)), 0)
            let rotation = simd_quatf(angle: Float(t) * 0.3, axis: [0, 1, 0]).vector
            gestures.append(DevicePose(position: position, rotation: rotation, time: t))
        }
        let motion = PuppetMotion(poses: gestures)
        var liftedFoot = false
        var hipHeights: [Float] = []
        for (frame, pose) in zip(motion.frames, gestures) {
            precondition(frame.joints.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            let left = frame.joints[PuppetMotion.Joint.leftHand.rawValue]
            let right = frame.joints[PuppetMotion.Joint.rightHand.rawValue]
            let rotation = simd_quatf(vector: pose.rotation)
            precondition(simd_distance(left, pose.position + rotation.act([-0.045, 0, 0])) < 0.00001)
            precondition(simd_distance(right, pose.position + rotation.act([0.045, 0, 0])) < 0.00001)
            for joint in [PuppetMotion.Joint.leftFoot, .rightFoot] {
                let height = frame.joints[joint.rawValue].y
                precondition(height >= motion.floor - 0.00001)
                if height > motion.floor + 0.02 { liftedFoot = true }
            }
            hipHeights.append(frame.joints[PuppetMotion.Joint.hip.rawValue].y)
        }
        precondition(liftedFoot, "Movement must produce footsteps")
        precondition(hipHeights.max()! - hipHeights.min()! > 0.25, "Low phone gestures must crouch")
        let seekA = motion.joints(at: 4.35)!
        _ = motion.joints(at: 10)
        precondition(seekA == motion.joints(at: 4.35)!, "Seeking must be independent of playback history")
        let elbow = PuppetMotion.bend(from: .zero, to: [0, 0, -0.4], upper: 0.3, lower: 0.28, pole: [1, -1, 0])
        precondition(abs(simd_length(elbow) - 0.3) < 0.0001)
        precondition(abs(simd_distance(elbow, [0, 0, -0.4]) - 0.28) < 0.0001)
        let puppetNode = PuppetNode()
        puppetNode.update(seekA)
        precondition(!puppetNode.isHidden)
        let encoded = try JSONEncoder().encode(artwork)
        let decoded = try JSONDecoder().decode(Artwork.self, from: encoded).validated()
        precondition(decoded.duration == 2 && decoded.strokes.count == 2)
        func rejects(_ value: Artwork) {
            do { _ = try value.validated(); preconditionFailure("Invalid artwork accepted") }
            catch { }
        }
        var invalid = artwork
        invalid.strokes[0].color = 99
        rejects(invalid)
        invalid = artwork
        invalid.strokes[0].points[1].time = -1
        rejects(invalid)
        invalid = artwork
        invalid.strokes[0].radius = .nan
        rejects(invalid)
        invalid = artwork
        invalid.poses[0].rotation = .zero
        rejects(invalid)
        invalid = artwork
        invalid.strokes = Array(repeating: dot, count: 6001)
        rejects(invalid)

        let generated = ArtworkScene.make(decoded)
        precondition(generated.timeline.map(\.time) == [0, 1, 2])
        precondition(generated.scene.rootNode.childNodes.count == 3)
        let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/AirCanvas-test.usdz")
        try ArtworkScene.exportUSDZ(decoded, to: url)
        let loaded = try SCNScene(url: url, options: nil)
        var geometryCount = 0
        loaded.rootNode.enumerateChildNodes { node, _ in
            if node.geometry != nil { geometryCount += 1 }
            precondition(node.camera == nil && node.light == nil)
        }
        precondition(geometryCount > 0, "USDZ must contain actual geometry")
        let bounds = loaded.rootNode.boundingBox
        precondition(abs(bounds.max.x - bounds.min.x - 0.208) < 0.02, "Meter scale must survive export")
        print("PASS: overlap/depth, pose gaps, puppet grip/crouch/steps/IK/seek, JSON validation/roundtrip, timeline, USDZ reload and scale")
    }
}
