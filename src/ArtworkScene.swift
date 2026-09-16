import SceneKit
#if canImport(UIKit)
import UIKit
typealias InkColor = UIColor
#else
import AppKit
typealias InkColor = NSColor
#endif

enum ArtworkScene {
    static let colors: [InkColor] = [.systemCyan, .systemPink, .systemYellow, .white]

    /// A scene containing only ink. Guides, device markers, cameras and the room are never exported.
    static func make(_ artwork: Artwork) -> (scene: SCNScene, timeline: [(node: SCNNode, time: Double)]) {
        let scene = SCNScene()
        var timeline: [(node: SCNNode, time: Double)] = []
        for stroke in artwork.strokes {
            let material = SCNMaterial()
            material.diffuse.contents = colors[stroke.color]
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.65
            material.metalness.contents = 0
            for index in stroke.points.indices {
                let point = stroke.points[index]
                let sample = SCNNode()
                let sphere = SCNSphere(radius: CGFloat(stroke.radius))
                sphere.segmentCount = 8
                sphere.materials = [material]
                let dot = SCNNode(geometry: sphere)
                dot.simdPosition = point.position
                sample.addChildNode(dot)
                if index > 0 {
                    let previous = stroke.points[index - 1].position
                    let delta = point.position - previous
                    let length = simd_length(delta)
                    if length > 0.000001 {
                        let cylinder = SCNCylinder(radius: CGFloat(stroke.radius), height: CGFloat(length))
                        cylinder.radialSegmentCount = 8
                        cylinder.materials = [material]
                        let segment = SCNNode(geometry: cylinder)
                        segment.simdPosition = (previous + point.position) / 2
                        segment.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
                        sample.addChildNode(segment)
                    }
                }
                scene.rootNode.addChildNode(sample)
                timeline.append((sample, point.time))
            }
        }
        return (scene, timeline)
    }

    static func exportUSDZ(_ artwork: Artwork, to url: URL) throws {
        let (scene, _) = make(artwork)
        // Center the model for viewers while preserving its real-world scale in meters.
        let root = SCNNode()
        for node in scene.rootNode.childNodes { root.addChildNode(node) }
        root.simdPosition = -artwork.bounds.center
        scene.rootNode.addChildNode(root)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw ArtworkError.exportFailed }
    }
}
