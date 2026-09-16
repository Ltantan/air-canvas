import Foundation
import AVFoundation
import SceneKit

@main enum ReleaseTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var stroke = InkStroke(color: 0, radius: 0.02)
        var poses: [DevicePose] = []
        for i in 0...30 {
            let t = Double(i) / 30
            let angle = Float(t) * .pi * 2
            let position = SIMD3<Float>(cos(angle) * 0.3, sin(angle) * 0.3, -0.3)
            stroke.points.append(InkPoint(position: position, time: t))
            poses.append(DevicePose(position: position + [0, 0, 0.3], rotation: [0, 0, 0, 1], time: t))
        }
        let artwork = Artwork(strokes: [stroke], poses: poses)
        let first = SavedArtwork(id: UUID(), createdAt: Date(timeIntervalSince1970: 1), artwork: artwork)
        try ArtworkStore.save(first, in: root)
        try ArtworkStore.save(first, in: root)
        precondition(tryCount(root) == 1, "Saving the same drawing must not create duplicate works")
        let loaded = try ArtworkStore.list(in: root)
        precondition(loaded[0].artwork.poses.count == 31 && loaded[0].artwork.strokes[0].points.count == 31)
        var bad = artwork
        bad.strokes[0].points[0].position.x = .nan
        do { try ArtworkStore.save(SavedArtwork(id: first.id, createdAt: first.createdAt, artwork: bad), in: root); fatalError("Invalid save accepted") }
        catch { }
        precondition(tryCount(root) == 1, "An invalid update must preserve the previous file")
        try ArtworkStore.delete(id: first.id, in: root)
        precondition(tryCount(root) == 0)
        let cancelled = ReplayVideoExporter()
        cancelled.cancel()
        do { _ = try cancelled.render(artwork: artwork, width: 240, height: 426); fatalError("Cancellation ignored") }
        catch ReplayVideoError.cancelled { }
        let url = try ReplayVideoExporter().render(artwork: artwork, width: 240, height: 426)
        let movie = root.appendingPathComponent("replay.mp4")
        try FileManager.default.copyItem(at: url, to: movie)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let asset = AVURLAsset(url: movie)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.count == 1 && audio.isEmpty)
        let size = try await videos[0].load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        precondition(size == CGSize(width: 240, height: 426))
        precondition(abs(duration - 2) < 0.05)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videos[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var count = 0, last = -Double.infinity
        var samples: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            precondition(t > last)
            last = t; count += 1
            if let buffer = CMSampleBufferGetImageBuffer(sample), count == 1 || count == 31 || count == 60 {
                let ci = CIImage(cvPixelBuffer: buffer)
                let ctx = CIContext()
                let cg = ctx.createCGImage(ci, from: ci.extent)!
                let bitmap = NSBitmapImageRep(cgImage: cg)
                let data = bitmap.representation(using: .png, properties: [:])!
                try data.write(to: root.appendingPathComponent("frame-\(count).png"))
                samples.append(data)
            }
        }
        precondition(reader.status == .completed && count == 60)
        precondition(samples[0] != samples[1], "Drawing and puppet must change over time")
        print("PASS: atomic artwork save/update/reload/delete; invalid-save preservation; cancellation; MP4 240x426, 60 monotonic frames, 2 seconds, silent, changing frames")
    }
    static func tryCount(_ url: URL) -> Int { try! ArtworkStore.list(in: url).count }
}
