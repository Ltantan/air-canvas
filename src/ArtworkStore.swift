import Foundation

struct SavedArtwork: Codable {
    let id: UUID
    let createdAt: Date
    let artwork: Artwork
}

enum ArtworkStore {
    static func root() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Artworks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func save(_ item: SavedArtwork, in directory: URL? = nil) throws {
        _ = try item.artwork.validated()
        let folder = try directory ?? root()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
    }
    static func load(from url: URL) throws -> SavedArtwork {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 15_000_000 else { throw ArtworkError.invalidFile }
        let item = try JSONDecoder().decode(SavedArtwork.self, from: Data(contentsOf: url))
        _ = try item.artwork.validated()
        return item
    }
    static func list(in directory: URL? = nil) throws -> [SavedArtwork] {
        let folder = try directory ?? root()
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .map { try load(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    static func delete(id: UUID, in directory: URL? = nil) throws {
        let folder = try directory ?? root()
        let file = folder.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
