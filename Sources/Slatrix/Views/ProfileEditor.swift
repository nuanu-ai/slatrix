import AppKit
import SwiftUI

/// Slack's Edit your profile: fields on the left, the photo on the right, all saved by Save Changes. A Matrix profile
/// holds a display name and a photo, so every client shows what is set here.
struct ProfileEditor: View {
    let matrix: MatrixService
    let onClose: () -> Void
    /// The account being edited; nothing saves once another is signed in.
    private let account: String?
    @State private var name: String
    @State private var photo: PhotoChange?
    /// A photo just picked, being cropped.
    @State private var picked: PickedPhoto?
    @State private var preparing = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    /// What Save Changes does to the photo; nil keeps it.
    private enum PhotoChange {
        /// The square of the picked photo to upload, in its pixels.
        case upload(CGImage, crop: CGRect)
        case remove
    }

    private struct PickedPhoto: Identifiable {
        let id = UUID()
        let image: CGImage
    }

    init(matrix: MatrixService, onClose: @escaping () -> Void) {
        self.matrix = matrix
        self.onClose = onClose
        account = matrix.user?.id
        // Set before the first frame, so the field never shows empty.
        _name = State(initialValue: matrix.user?.name ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var editable: Bool { account != nil && matrix.user?.id == account && !matrix.isPreview && !saving }
    private var canSave: Bool {
        editable && !preparing && !trimmed.isEmpty && (trimmed != matrix.user?.name || photo != nil)
    }
    private var hasPhoto: Bool {
        switch photo {
        case .upload: true
        case .remove: false
        case nil: matrix.user?.avatarURL != nil
        }
    }

    var body: some View {
        let colors = appearance.colors
        Modal(
            title: "Edit your profile", size: .large, busy: saving, onClose: onClose,
            secondary: ModalAction("Cancel", action: onClose),
            primary: ModalAction("Save Changes", disabled: !canSave, action: save)
        ) {
            HStack(alignment: .top, spacing: m.sp24) {
                VStack(alignment: .leading, spacing: m.sp8) {
                    label("Display name")
                    TextField("Display name", text: $name).textFieldStyle(.field).disabled(!editable)
                    if let error {
                        Text(error).font(m.font(.meta)).foregroundStyle(colors.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: m.sp12) {
                    label("Profile photo").frame(maxWidth: .infinity, alignment: .leading)
                    preview.accessibilityHidden(true)
                    Button(action: choosePhoto) {
                        Text("Upload Photo").frame(maxWidth: .infinity)
                    }.buttonStyle(.secondary).controlSize(.large).disabled(!editable || preparing)
                    // Hidden, not removed, so the column keeps its height.
                    Button("Remove Photo") { photo = .remove }.buttonStyle(.textLink)
                        .opacity(hasPhoto ? 1 : 0).disabled(!hasPhoto || !editable || preparing)
                }.frame(width: m.profilePhoto)
            }
        }
        .modal(item: $picked) { picked in
            PhotoCropper(
                image: picked.image, onCancel: { self.picked = nil },
                onSave: {
                    photo = .upload(picked.image, crop: $0)
                    error = nil
                    self.picked = nil
                })
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(m.font(.body, .bold)).foregroundStyle(appearance.colors.textPrimary)
    }

    @ViewBuilder private var preview: some View {
        let side = m.profilePhoto
        let shownName = matrix.user?.name ?? name
        switch photo {
        case .upload(let image, let crop):
            Image(decorative: image.cropping(to: crop) ?? image, scale: 1).resizable().frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
        case .remove: AvatarView(name: shownName, size: side, cornerRadius: m.radiusLarge)
        case nil:
            AvatarView(
                name: shownName, size: side, cornerRadius: m.radiusLarge, matrix: matrix,
                source: matrix.user?.avatarURL)
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        let use = { (url: URL) in
            preparing = true
            Task { @MainActor in
                defer { preparing = false }
                do {
                    // A large photo takes a moment to scale down.
                    let image = try await Task.detached(priority: .userInitiated) {
                        try ProfilePhoto.image(contentsOf: url)
                    }.value
                    picked = PickedPhoto(image: image)
                } catch {
                    self.error = ProfilePhoto.Failure().message
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { use(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            use(url)
        }
    }

    private func save() {
        guard canSave else { return }
        let newName = trimmed == matrix.user?.name ? nil : trimmed
        let change = photo
        saving = true
        error = nil
        Task { @MainActor in
            do {
                if let newName { try await matrix.setProfile(name: newName) }
                switch change {
                case .upload(let image, let crop):
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ProfilePhoto(image, crop: crop)
                    }.value
                    try await matrix.setProfilePhoto(prepared)
                case .remove: try await matrix.setProfilePhoto(nil)
                case nil: break
                }
                saving = false
                onClose()
            } catch {
                // A name already saved now matches the account, so trying again sends only the photo.
                saving = false
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
