import Foundation
import MatrixRustSDK

enum VideoUpload {
    struct Poster {
        var width: Int
        var height: Int
        var size: UInt64
    }

    static func shown(width: Int?, height: Int?, rotation: Int) -> (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return (width, height)
    }

    static func posterAt(durationMillis: Int?) -> Int { 0 }

    static func posterSize(width: Int, height: Int) -> (width: Int, height: Int) { (width, height) }

    static func info(mimetype: String, size: UInt64, shown: (width: Int, height: Int)?, durationMillis: Int?, poster: Poster?)
        -> VideoInfo
    {
        VideoInfo(
            duration: nil, height: nil, width: nil, mimetype: mimetype, size: size, thumbnailInfo: nil, thumbnailSource: nil,
            blurhash: nil)
    }
}
