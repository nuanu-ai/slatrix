import CoreGraphics
import Foundation
import ImageIO
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
@Suite("Profile editing")
struct ProfileEditingTests {
    @Test("A large photo uploads small enough for avatars to show")
    func largePhoto() throws {
        let folder = try TemporaryDirectory()
        // Noise doesn't compress, so this PNG is several megabytes, like a photo from a phone.
        let original = try noisePNG(folder.path("photo.png"), side: 1_500)
        #expect(AvatarImageCache.decode(try Data(contentsOf: original)) == nil)

        let image = try ProfilePhoto.image(contentsOf: original)
        let photo = try ProfilePhoto(image, crop: PhotoCrop.centered(in: size(of: image)))

        #expect(AvatarImageCache.decode(photo.data) != nil)
    }

    @Test("The upload is the square you chose")
    func chosenSquare() throws {
        let folder = try TemporaryDirectory()
        let image = try ProfilePhoto.image(contentsOf: folder.png("photo.png", width: 400, height: 200, halves: true))

        let photo = try ProfilePhoto(image, crop: CGRect(x: 200, y: 0, width: 200, height: 200))

        let pixels = try rgba(photo.data)
        #expect(pixels.width == pixels.height)
        #expect(pixels.allBlue)
    }

    @Test("A sideways photo crops as it is shown")
    func sidewaysPhoto() throws {
        let folder = try TemporaryDirectory()
        // EXIF 6: stored landscape and shown a quarter turn clockwise, so its red left half shows on top.
        let image = try ProfilePhoto.image(
            contentsOf: folder.png("photo.png", width: 400, height: 200, orientation: 6, halves: true))

        let photo = try ProfilePhoto(image, crop: CGRect(x: 0, y: 200, width: 200, height: 200))

        let pixels = try rgba(photo.data)
        #expect(pixels.width == pixels.height)
        #expect(pixels.allBlue)
    }

    @Test("A file that isn't an image is refused")
    func notAnImage() throws {
        let folder = try TemporaryDirectory()
        #expect(throws: ProfilePhoto.Failure.self) { try ProfilePhoto.image(contentsOf: folder.file("notes.txt")) }
    }

    @Test("The crop frame starts as the largest square in the middle")
    func centeredCrop() {
        #expect(PhotoCrop.centered(in: CGSize(width: 300, height: 200)) == CGRect(x: 50, y: 0, width: 200, height: 200))
        #expect(PhotoCrop.centered(in: CGSize(width: 200, height: 300)) == CGRect(x: 0, y: 50, width: 200, height: 200))
    }

    @Test("Dragging the crop frame stops at the photo's edges")
    func moveCrop() {
        let photo = CGSize(width: 400, height: 300)
        let square = CGRect(x: 100, y: 100, width: 100, height: 100)

        #expect(
            PhotoCrop.moved(square, by: CGSize(width: 20, height: -30), in: photo) == square.offsetBy(dx: 20, dy: -30))
        #expect(
            PhotoCrop.moved(square, by: CGSize(width: 900, height: -900), in: photo)
                == CGRect(x: 300, y: 0, width: 100, height: 100))
        #expect(
            PhotoCrop.moved(square, by: CGSize(width: -900, height: 900), in: photo)
                == CGRect(x: 0, y: 200, width: 100, height: 100))
    }

    @Test("A corner resizes the crop frame around the opposite corner, square and inside the photo")
    func resizeCrop() {
        let photo = CGSize(width: 400, height: 300)
        let square = CGRect(x: 100, y: 100, width: 100, height: 100)

        #expect(
            PhotoCrop.resized(square, from: .topLeft, by: CGSize(width: -30, height: -30), in: photo)
                == CGRect(x: 70, y: 70, width: 130, height: 130))
        // Below, the photo ends 200 pixels from the top-left corner that stays put.
        #expect(
            PhotoCrop.resized(square, from: .bottomRight, by: CGSize(width: 500, height: 20), in: photo)
                == CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(
            PhotoCrop.resized(square, from: .topRight, by: CGSize(width: 20, height: -20), in: photo)
                == CGRect(x: 100, y: 80, width: 120, height: 120))
    }

    @Test("The crop frame shrinks only so far")
    func smallestCrop() {
        let photo = CGSize(width: 400, height: 300)
        let square = CGRect(x: 100, y: 100, width: 100, height: 100)

        let smallest = PhotoCrop.resized(square, from: .bottomLeft, by: CGSize(width: 900, height: -900), in: photo)

        #expect(smallest.width > 0)
        #expect(
            smallest == PhotoCrop.resized(smallest, from: .bottomLeft, by: CGSize(width: 50, height: -50), in: photo))
        #expect(smallest.maxX == square.maxX)
        #expect(smallest.minY == square.minY)
    }

    // capability: profile.edit-photo
    @Test("A new photo becomes yours once the server has it")
    func uploadPhoto() async throws {
        let folder = try TemporaryDirectory()
        let client = ProfileClient()
        let matrix = signedIn(client)
        let photo = try ProfilePhoto(
            ProfilePhoto.image(contentsOf: folder.png("photo.png", width: 64, height: 64)),
            crop: CGRect(x: 0, y: 0, width: 64, height: 64))

        try await matrix.setProfilePhoto(photo)

        #expect(client.uploaded == photo.data)
        #expect(matrix.user?.avatarURL == client.avatar)
        #expect(matrix.user?.avatarURL != nil)
    }

    // capability: profile.edit-name
    @Test("A new name becomes yours once the server has it")
    func rename() async throws {
        let client = ProfileClient()
        let matrix = signedIn(client)

        try await matrix.setProfile(name: "Ana Souza")

        #expect(client.name == "Ana Souza")
        #expect(matrix.user?.name == "Ana Souza")
    }

    // capability: profile.edit-photo
    @Test("Removing your photo leaves your initials")
    func removePhoto() async throws {
        let client = ProfileClient()
        client.avatar = "mxc://example.org/old"
        let matrix = signedIn(client)
        matrix.user?.avatarURL = client.avatar

        try await matrix.setProfilePhoto(nil)

        #expect(client.avatar == nil)
        #expect(matrix.user?.avatarURL == nil)
    }

    @Test("A name and photo changed on another device show once Slatrix is back in front")
    func refreshFromAnotherDevice() async {
        let client = ProfileClient()
        client.name = "Ana Lima"
        client.avatar = "mxc://example.org/new"
        let matrix = signedIn(client)

        await matrix.refreshOwnProfile()

        #expect(matrix.user?.name == "Ana Lima")
        #expect(matrix.user?.avatarURL == "mxc://example.org/new")
    }

    @Test("A refresh that started before you saved a photo here doesn't bring the old one back")
    func refreshDoesNotUndoAnEdit() async throws {
        let client = ProfileClient()
        client.avatar = "mxc://example.org/old"
        let matrix = signedIn(client)
        client.profiles.arm()
        let refresh = Task { await matrix.refreshOwnProfile() }
        #expect(await eventually { client.profiles.isWaiting })

        try await matrix.setProfilePhoto(nil)
        client.profiles.release()
        await refresh.value

        #expect(matrix.user?.avatarURL == nil)
    }

    // capability: profile.own
    @Test("Your own profile shows your latest name and photo, not a room's older copy")
    func ownProfileIsCurrent() {
        let me = ChatUser(id: "@ana:example.org", name: "Ana Lima")
        let member = ChatUser(id: me.id, name: "Ana", avatarURL: "mxc://example.org/old")

        let details = ShownProfile(people: PeopleService(), userID: me.id, fallback: member, me: me)

        #expect(details.name == "Ana Lima")
        #expect(details.avatarURL == nil)
    }

    private func signedIn(_ client: Client) -> MatrixService {
        let matrix = MatrixService()
        matrix.configureMessageActionsForChecks(
            client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        matrix.user = ChatUser(id: "@ana:example.org", name: "Ana")
        return matrix
    }

    private func size(of image: CGImage) -> CGSize { CGSize(width: image.width, height: image.height) }

    /// `data` decoded to 8-bit RGBA, and whether every pixel is blue, allowing for compression.
    private func rgba(_ data: Data) throws -> (width: Int, height: Int, allBlue: Bool) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let allBlue = stride(from: 0, to: bytes.count, by: 4).allSatisfy { bytes[$0] < 30 && bytes[$0 + 2] > 225 }
        return (image.width, image.height, allBlue)
    }

    private func noisePNG(_ url: URL, side: Int) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        arc4random_buf(&bytes, bytes.count)
        let context = try #require(
            CGContext(
                data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

/// A homeserver's profile: the photo it was sent, and where it says that photo now is.
private final class ProfileClient: Client, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (data: Data?, avatar: String?, name: String?) = (nil, nil, nil)
    /// Holds `getProfile`'s answer, read when asked, once armed, for an edit to land before it arrives.
    let profiles = Gate()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    var uploaded: Data? { lock.withLock { stored.data } }
    var avatar: String? {
        get { lock.withLock { stored.avatar } }
        set { lock.withLock { stored.avatar = newValue } }
    }
    override func uploadAvatar(mimeType: String, data: Data) async throws {
        lock.withLock { stored = (data, "mxc://example.org/" + UUID().uuidString, stored.name) }
    }
    override func removeAvatar() async throws { avatar = nil }
    override func avatarUrl() async throws -> String? { avatar }
    var name: String? {
        get { lock.withLock { stored.name } }
        set { lock.withLock { stored.name = newValue } }
    }
    override func setDisplayName(name: String) async throws { self.name = name }
    override func getProfile(userId: String) async throws -> UserProfile {
        let profile = UserProfile(userId: userId, displayName: name, avatarUrl: avatar, status: nil, call: nil)
        await profiles.wait()
        return profile
    }
}
