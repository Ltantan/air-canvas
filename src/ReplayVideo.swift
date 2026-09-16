import Foundation
import SceneKit
import AVFoundation
import Metal
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ReplayVideoError: LocalizedError, Equatable {
    case cancelled, renderFailed, encodingFailed
    var errorDescription: String? {
        switch self {
        case .cancelled: return "動画の書き出しを中止しました。"
        case .renderFailed: return "動画の画像を作成できませんでした。"
        case .encodingFailed: return "動画を保存できませんでした。空き容量を確認してください。"
        }
    }
}

/// Owns a separate SceneKit scene. Never mutates the visible preview from its worker queue.
final class ReplayVideoExporter {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw ReplayVideoError.cancelled }
    }
    func start(artwork: Artwork, width: Int = 720, height: Int = 1280,
               progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try render(artwork: artwork, width: width, height: height, progress: progress) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // Internal synchronous entry also permits an end-to-end encoder test on macOS.
    func render(artwork: Artwork, width: Int, height: Int, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        _ = try artwork.validated()
        try checkCancellation()
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              let device = MTLCreateSystemDefaultDevice() else { throw ReplayVideoError.renderFailed }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("AirCanvas.mp4")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw ReplayVideoError.encodingFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ReplayVideoError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }

        let result = ArtworkScene.make(artwork)
        let scene = result.scene
        #if canImport(UIKit)
        scene.background.contents = UIColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1)
        #else
        scene.background.contents = NSColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1)
        #endif
        let motion = PuppetMotion(poses: artwork.poses)
        let puppet = PuppetNode()
        scene.rootNode.addChildNode(puppet)
        let phone = SCNNode(geometry: SCNBox(width: 0.07, height: 0.14, length: 0.009, chamferRadius: 0.006))
        #if canImport(UIKit)
        phone.geometry?.firstMaterial?.diffuse.contents = UIColor.systemOrange
        #else
        phone.geometry?.firstMaterial?.diffuse.contents = NSColor.systemOrange
        #endif
        scene.rootNode.addChildNode(phone)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 50
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear = 0.001
        camera.camera?.zFar = 2000
        var low = artwork.bounds.center - SIMD3<Float>(repeating: artwork.bounds.extent / 2)
        var high = artwork.bounds.center + SIMD3<Float>(repeating: artwork.bounds.extent / 2)
        if !artwork.poses.isEmpty {
            low = simd_min(low, motion.bounds.center - SIMD3<Float>(repeating: motion.bounds.extent / 2))
            high = simd_max(high, motion.bounds.center + SIMD3<Float>(repeating: motion.bounds.extent / 2))
        }
        let center = (low + high) / 2
        let extent = max(high.x - low.x, max(high.y - low.y, high.z - low.z))
        let halfFOV = min(Float.pi * 25 / 180, atan(tan(Float.pi * 25 / 180) * Float(width) / Float(height)))
        camera.simdPosition = center + simd_normalize(SIMD3<Float>(1, 0.55, 1.4)) * extent * 0.65 / sin(halfFOV)
        camera.look(at: SCNVector3(center))
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        renderer.autoenablesDefaultLighting = true
        for sample in result.timeline { sample.node.isHidden = true }
        var visible = 0
        let rate = max(1, artwork.duration / 58)
        let duration = max(1, artwork.duration / rate) + 1 // Hold the completed work for a second.
        let fps: Int32 = 30
        let count = Int(ceil(duration * Double(fps)))
        for index in 0..<count {
            try checkCancellation()
            let deadline = Date().addingTimeInterval(15)
            while !input.isReadyForMoreMediaData {
                try checkCancellation()
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? ReplayVideoError.encodingFailed }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try autoreleasepool {
                let time = min(artwork.duration, Double(index) / Double(fps) * rate)
                while visible < result.timeline.count && result.timeline[visible].time <= time {
                    result.timeline[visible].node.isHidden = false
                    visible += 1
                }
                puppet.isHidden = true
                if let joints = motion.joints(at: time) { puppet.update(joints) }
                phone.isHidden = true
                if let pose = artwork.pose(at: time) {
                    phone.simdPosition = pose.position
                    phone.simdOrientation = simd_quatf(vector: pose.rotation)
                    phone.isHidden = false
                }
                let image = renderer.snapshot(atTime: Double(index) / Double(fps), with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
                #if canImport(UIKit)
                let cgImage = image.cgImage
                #else
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #endif
                guard let cgImage, let pool = adaptor.pixelBufferPool else { throw ReplayVideoError.renderFailed }
                var optionalBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                      let buffer = optionalBuffer else { throw ReplayVideoError.renderFailed }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw ReplayVideoError.renderFailed }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                    throw writer.error ?? ReplayVideoError.encodingFailed
                }
            }
            if index % 15 == 0 {
                let value = Double(index + 1) / Double(count)
                DispatchQueue.main.async { progress(value) }
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(count), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        let deadline = Date().addingTimeInterval(30)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            try checkCancellation()
            guard Date() < deadline else { throw ReplayVideoError.encodingFailed }
        }
        try checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? ReplayVideoError.encodingFailed }
        succeeded = true
        return url
    }
}
