import Foundation
import simd

struct InkPoint: Codable {
    var position: SIMD3<Float>
    var time: Double
}

struct InkStroke: Codable {
    var color: Int
    var radius: Float
    var points: [InkPoint] = []
}

struct DevicePose: Codable {
    var position: SIMD3<Float>
    // Quaternion x, y, z, w; records the device, not the person's skeleton.
    var rotation: SIMD4<Float>
    var time: Double
}

struct Artwork: Codable {
    var version = 1
    var strokes: [InkStroke] = []
    var poses: [DevicePose] = []
    var duration: Double { strokes.last?.points.last?.time ?? 0 }
    var isEmpty: Bool { strokes.allSatisfy { $0.points.isEmpty } }

    var bounds: (center: SIMD3<Float>, extent: Float) {
        let points = strokes.flatMap(\.points).map(\.position)
        guard let first = points.first else { return (.zero, 1) }
        var low = first, high = first
        for point in points { low = simd_min(low, point); high = simd_max(high, point) }
        return ((low + high) / 2, max(simd_length(high - low), 0.2))
    }

    func validated() throws -> Artwork {
        func finite(_ value: SIMD3<Float>) -> Bool {
            value.x.isFinite && value.y.isFinite && value.z.isFinite && simd_length(value) < 1000
        }
        guard version == 1, !isEmpty, strokes.count <= 6000,
              poses.count <= 18000,
              strokes.reduce(0, { $0 + max(0, $1.points.count * 2 - 1) }) <= 6000 else {
            throw ArtworkError.invalidFile
        }
        var lastTime = -Double.infinity
        for stroke in strokes {
            guard (0..<4).contains(stroke.color), stroke.radius.isFinite,
                  (0.001...0.05).contains(stroke.radius), !stroke.points.isEmpty else { throw ArtworkError.invalidFile }
            for point in stroke.points {
                guard finite(point.position), point.time.isFinite, point.time >= 0,
                      point.time <= 86400, point.time >= lastTime else { throw ArtworkError.invalidFile }
                lastTime = point.time
            }
        }
        lastTime = -Double.infinity
        for pose in poses {
            let length = simd_length(pose.rotation)
            guard finite(pose.position), length.isFinite, abs(length - 1) < 0.01,
                  pose.time.isFinite, pose.time >= 0, pose.time <= 86400,
                  pose.time >= lastTime else { throw ArtworkError.invalidFile }
            lastTime = pose.time
        }
        return self
    }

    func pose(at time: Double) -> DevicePose? {
        guard let first = poses.first, let last = poses.last,
              time >= first.time, time <= last.time + 0.12 else { return nil }
        var low = 0, high = poses.count
        while low < high {
            let middle = (low + high) / 2
            if poses[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let a = poses[max(0, low - 1)]
        guard low < poses.count else { return a }
        let b = poses[low]
        // Do not invent motion across tracking loss, backgrounding, or preview visits.
        guard b.time - a.time < 0.3 else { return time - a.time < 0.12 ? a : nil }
        let fraction = Float((time - a.time) / max(b.time - a.time, 0.00001))
        return DevicePose(position: a.position + (b.position - a.position) * fraction,
                          rotation: simd_slerp(simd_quatf(vector: a.rotation), simd_quatf(vector: b.rotation), fraction).vector,
                          time: time)
    }
}

enum ArtworkError: LocalizedError {
    case invalidFile, exportFailed
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "対応するAir Canvas作品ファイルではないか、作品のサイズが上限を超えています。"
        case .exportFailed: return "3Dモデルを書き出せませんでした。もう一度お試しください。"
        }
    }
}

enum InkGeometry {
    static func closestPoint(to point: SIMD3<Float>, from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
        let delta = b - a
        let squared = simd_length_squared(delta)
        guard squared > 0.00000001 else { return a }
        let fraction = max(0, min(1, simd_dot(point - a, delta) / squared))
        return a + delta * fraction
    }

    struct Guidance {
        var surfaceGap = Float.infinity
        var depthOffset: Float?
        var overlaps: Bool { surfaceGap <= 0 }
    }

    /// Distance to actual line segments, not just sampled dots. The camera looks along -Z.
    static func guidance(strokes: [InkStroke], camera: simd_float4x4, radius: Float) -> Guidance {
        let tip4 = camera * SIMD4<Float>(0, 0, -0.3, 1)
        let tip = SIMD3<Float>(tip4.x, tip4.y, tip4.z)
        let inverse = camera.inverse
        var result = Guidance()
        var bestDepth = Float.infinity
        for stroke in strokes {
            for index in stroke.points.indices {
                let a = stroke.points[max(0, index - 1)].position
                let b = stroke.points[index].position
                let nearest = closestPoint(to: tip, from: a, to: b)
                result.surfaceGap = min(result.surfaceGap, simd_distance(tip, nearest) - radius - stroke.radius)
                let ca = inverse * SIMD4<Float>(a, 1), cb = inverse * SIMD4<Float>(b, 1)
                let delta = cb - ca
                let lateralSquared = delta.x * delta.x + delta.y * delta.y
                let raw: Float
                if lateralSquared > 0.00000001 {
                    raw = -(ca.x * delta.x + ca.y * delta.y) / lateralSquared
                } else if abs(delta.z) > 0.00001 {
                    raw = (-0.3 - ca.z) / delta.z
                } else { raw = 0 }
                let candidate = ca + delta * max(0, min(1, raw))
                let depth = -candidate.z
                let lateral = hypot(candidate.x, candidate.y)
                if depth > 0.03, lateral <= stroke.radius + radius + 0.012,
                   abs(depth - 0.3) < bestDepth {
                    bestDepth = abs(depth - 0.3)
                    result.depthOffset = depth - 0.3
                }
            }
        }
        return result
    }
}
