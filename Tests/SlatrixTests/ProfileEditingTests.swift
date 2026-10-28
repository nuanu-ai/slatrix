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

        let photo = try ProfilePhoto(contentsOf: original)

        #expect(AvatarImageCache.decode(photo.data) != nil)
    }

    @Test("A sideways photo uploads upright")
    func sidewaysPhoto() throws {
        let folder = try TemporaryDirectory()
        // EXIF 6: stored landscape, shown rotated a quarter turn.
        let photo = try ProfilePhoto(contentsOf: folder.png("photo.png", width: 300, height: 200, orientation: 6))

        let source = try #require(CGImageSourceCreateWithData(photo.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width < image.height)
    }

    @Test("A file that isn't an image is refused")
    func notAnImage() throws {
        let folder = try TemporaryDirectory()
        #expect(throws: ProfilePhoto.Failure.self) { try ProfilePhoto(contentsOf: folder.file("notes.txt")) }
    }

    @Test("A new photo becomes yours once the server has it")
    func uploadPhoto() async throws {
        let folder = try TemporaryDirectory()
        let client = ProfileClient()
        let matrix = signedIn(client)
        let photo = try ProfilePhoto(contentsOf: folder.png("photo.png", width: 64, height: 64))

        try await matrix.setProfilePhoto(photo)

        #expect(client.uploaded == photo.data)
        #expect(matrix.user?.avatarURL == client.avatar)
        #expect(matrix.user?.avatarURL != nil)
    }

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
    override func getProfile(userId: String) async throws -> UserProfile {
        let profile = UserProfile(userId: userId, displayName: name, avatarUrl: avatar, status: nil, call: nil)
        await profiles.wait()
        return profile
    }
}
