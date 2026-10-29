import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Slatrix

@MainActor
struct AvatarImageCacheTests {
    @Test(
        "An avatar that failed to load is not fetched again until the session ends",
        arguments: [Data("not an image".utf8), nil])
    func remembersFailures(response: Data?) async {
        let cache = AvatarImageCache()
        var fetches = 0
        let load: @MainActor () async throws -> Data = {
            fetches += 1
            guard let response else { throw URLError(.notConnectedToInternet) }
            return response
        }
        #expect(await cache.image(for: "mxc://example.org/broken", load: load) == nil)
        #expect(await cache.image(for: "mxc://example.org/broken", load: load) == nil)
        #expect(fetches == 1)
        cache.clear()
        _ = await cache.image(for: "mxc://example.org/broken", load: load)
        #expect(fetches == 2)
    }

    @Test("An avatar that has loaded once is ready to draw without waiting")
    func cachedAvatarIsSynchronous() async throws {
        let cache = AvatarImageCache()
        let png = try Self.png()
        #expect(cache.cachedImage(for: "mxc://example.org/face") == nil)
        #expect(await cache.image(for: "mxc://example.org/face", load: { png }) != nil)
        #expect(cache.cachedImage(for: "mxc://example.org/face") != nil)
    }

    @Test("A photo for the profile pane keeps the detail of its large thumbnail")
    func largeAvatarStaysSharp() async throws {
        let cache = AvatarImageCache()
        let thumbnail = try AvatarDecodingTests.png(width: 400, height: 400)
        let image = try #require(await cache.image(for: "mxc://example.org/face#large", pixels: 512) { thumbnail })
        #expect(image.width == 400)
    }

    private static func png() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
struct AvatarDecodingTests {
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    // capability: people.avatars
    @Test("Avatars decode to a small thumbnail that keeps the aspect ratio")
    func decodesThumbnail() throws {
        let image = try #require(AvatarImageCache.decode(Self.png(width: 512, height: 256)))
        #expect(image.width == 128 && image.height == 64)
    }

    @Test(
        "Empty, corrupt and oversized avatar data is rejected",
        arguments: [Data(), Data("not an image".utf8), Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)])
    func rejectsBadData(data: Data) {
        #expect(AvatarImageCache.decode(data) == nil)
    }

    @Test("Concurrent requests for one avatar share a single download")
    func coalescesRequests() async throws {
        let data = try Self.png(width: 64, height: 64)
        let cache = AvatarImageCache()
        let gate = Gate()
        gate.arm()
        var fetches = 0
        let load: @MainActor () async throws -> Data = {
            fetches += 1
            await gate.wait()
            return data
        }
        let first = Task { await cache.image(for: "mxc://example.org/avatar", load: load) }
        let second = Task { await cache.image(for: "mxc://example.org/avatar", load: load) }
        #expect(await eventually { gate.isWaiting })
        gate.release()
        #expect(await first.value != nil)
        #expect(await second.value != nil)
        #expect(fetches == 1)
    }

    @Test("A loaded avatar is reused until the session clears the cache")
    func reusesUntilCleared() async throws {
        let data = try Self.png(width: 64, height: 64)
        let cache = AvatarImageCache()
        var fetches = 0
        let load: @MainActor () async throws -> Data = {
            fetches += 1
            return data
        }
        #expect(await cache.image(for: "mxc://example.org/avatar", load: load) != nil)
        #expect(await cache.image(for: "mxc://example.org/avatar", load: load) != nil)
        #expect(fetches == 1)
        cache.clear()
        #expect(await cache.image(for: "mxc://example.org/avatar", load: load) != nil)
        #expect(fetches == 2)
    }
}
