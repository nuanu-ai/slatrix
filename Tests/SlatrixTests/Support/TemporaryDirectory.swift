import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// A private scratch folder per test, removed when the test releases it.
final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SlatrixTests-" + UUID().uuidString, isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }

    func file(_ name: String, _ contents: Data = Data("Fixture content\n".utf8)) throws -> URL {
        let file = path(name)
        try contents.write(to: file)
        return file
    }

    /// A PNG filled with one red, which a pixel check can find on screen, or blue on its right half when `halves`.
    /// `orientation` is its EXIF orientation.
    func png(_ name: String, width: Int, height: Int, orientation: Int = 1, halves: Bool = false) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if halves {
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        let file = path(name)
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// A Motion JPEG movie of `seconds`, its frames red on the left half and blue on the right, as its track stores them,
    /// and turned `rotation` degrees by its track's transform, as a phone records an upright video.
    func video(_ name: String, width: Int, height: Int, rotation: Double, seconds: Int) async throws -> URL {
        let file = path(name)
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.transform = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(frame), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        CVPixelBufferUnlockBaseAddress(frame, [])
        // Ten frames a second, appended whenever the writer asks for more.
        let frames = FrameFeed(input: input, adaptor: adaptor, frame: frame, count: seconds * 10)
        await withCheckedContinuation { done in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "TemporaryDirectory.video")) {
                if frames.feed() { done.resume() }
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return file
    }

    /// A file that reports `bytes` in size without using the disk space.
    func sparse(_ name: String, bytes: Int) throws -> URL {
        let file = path(name)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return file
    }
}

func posixPermissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

/// Feeds one frame to a writer until it has `count`, on the writer's queue only.
private final class FrameFeed: @unchecked Sendable {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let frame: CVPixelBuffer
    let count: Int
    var index = 0

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, frame: CVPixelBuffer, count: Int) {
        (self.input, self.adaptor, self.frame, self.count) = (input, adaptor, frame, count)
    }

    /// Appends what the writer takes now; true once the last frame is in and the input finished.
    func feed() -> Bool {
        while input.isReadyForMoreMediaData && index < count {
            adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
            index += 1
        }
        guard index == count else { return false }
        input.markAsFinished()
        return true
    }
}
