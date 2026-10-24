import CoreGraphics
import Foundation
import ImageIO

@MainActor
final class AvatarImageCache {
    private let images = NSCache<NSString, CGImage>()
    private var requests: [String: Task<CGImage?, Never>] = [:]
    // A broken or missing avatar is retried next session, not on every row that shows it.
    private var failed = Set<String>()
    private var generation = UUID()

    init() {
        // 128 px thumbnails, about 64 KB each: everyone in a few large rooms.
        images.countLimit = 1_024
        images.totalCostLimit = 64 * 1_024 * 1_024
    }

    /// A decoded avatar, if one is already in memory, for drawing it on a row's first frame.
    func cachedImage(for source: String) -> CGImage? { images.object(forKey: source as NSString) }

    func image(for source: String, load: @escaping @MainActor () async throws -> Data) async -> CGImage? {
        if let image = images.object(forKey: source as NSString) { return image }
        if failed.contains(source) { return nil }
        if let request = requests[source] { return await request.value }
        let token = generation
        let request = Task { [weak self] () -> CGImage? in
            defer { if self?.generation == token { self?.requests[source] = nil } }
            let data = try? await load()
            let image = await Task.detached(priority: .utility) { data.flatMap(Self.decode) }.value
            guard !Task.isCancelled, let self, self.generation == token else { return nil }
            guard let image else {
                self.failed.insert(source)
                return nil
            }
            self.images.setObject(image, forKey: source as NSString, cost: image.bytesPerRow * image.height)
            return image
        }
        requests[source] = request
        return await request.value
    }

    func clear() {
        generation = UUID()
        for request in requests.values { request.cancel() }
        requests.removeAll()
        failed.removeAll()
        images.removeAllObjects()
    }

    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }
}
