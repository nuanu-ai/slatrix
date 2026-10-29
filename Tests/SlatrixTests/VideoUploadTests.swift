import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

struct VideoUploadTests {
    struct Video: Decodable {
        var name: String
        var mimetype: String
        var size: UInt64
        var width: Int
        var height: Int
        var rotation: Int
        var durationMillis: Int?
    }
    struct Frame: Decodable {
        var atMillis: Int
        var width: Int
        var height: Int
    }
    struct Thumbnail: Decodable, Equatable {
        var w: UInt64
        var h: UInt64
        var mimetype: String
        var size: UInt64
    }
    struct Info: Decodable, Equatable {
        var w: UInt64
        var h: UInt64
        var duration: Int?
        var mimetype: String
        var size: UInt64
        var thumbnailInfo: Thumbnail?

        enum CodingKeys: String, CodingKey {
            case w, h, duration, mimetype, size
            case thumbnailInfo = "thumbnail_info"
        }
    }
    struct Sent: Decodable {
        var msgtype: String
        var body: String
        var info: Info
    }
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var video: Video
        var posterBytes: UInt64?
        var posterFrame: Frame
        var sent: Sent
        var testDescription: String { name }
    }
    struct Spec: Decodable { var cases: [Case] }

    // capability: composer.video
    @Test(
        "A video sends what the shared cases say",
        arguments: try SharedSpec.decode("spec/video-upload.json", as: Spec.self).cases)
    func sharedCases(spec: Case) throws {
        let shown = try #require(
            VideoUpload.shown(width: spec.video.width, height: spec.video.height, rotation: spec.video.rotation))
        let poster = VideoUpload.posterSize(width: shown.width, height: shown.height)
        #expect(VideoUpload.posterAt(durationMillis: spec.video.durationMillis) == spec.posterFrame.atMillis)
        #expect(poster.width == spec.posterFrame.width && poster.height == spec.posterFrame.height)
        let info = VideoUpload.info(
            mimetype: spec.video.mimetype, size: spec.video.size, shown: shown,
            durationMillis: spec.video.durationMillis,
            poster: spec.posterBytes.map { VideoUpload.Poster(width: poster.width, height: poster.height, size: $0) })
        // m.video and its info; the body is the file's own name, which the upload keeps.
        #expect(spec.sent.msgtype == "m.video")
        let sent = Info(
            w: info.width ?? 0, h: info.height ?? 0, duration: info.duration.map { Int(($0 * 1_000).rounded()) },
            mimetype: info.mimetype ?? "", size: info.size ?? 0,
            thumbnailInfo: info.thumbnailInfo.map {
                Thumbnail(w: $0.width ?? 0, h: $0.height ?? 0, mimetype: $0.mimetype ?? "", size: $0.size ?? 0)
            })
        #expect(sent == spec.sent.info)
    }
}
