import SwiftUI

/// The one spinner, for a wait long enough to notice. It draws nothing before then, so callers place it in space
/// that is already reserved or in an overlay.
struct DelayedProgress: View {
    var active = true
    var hasContent = false
    /// Offline, the connection notice speaks for the wait instead.
    var offline = false
    /// Logs the whole wait, shown or not.
    var interval: Performance.Name? = nil
    var body: some View {
        AfterLoadingDelay(active: active, hasContent: hasContent, offline: offline, interval: interval) {
            ProgressView().controlSize(.small)
        }
    }
}

/// Placeholder rows for a list whose shape is known: an avatar block and two bars. They wait like the spinner.
struct SkeletonRows: View {
    var count = 6
    var interval: Performance.Name? = nil
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        AfterLoadingDelay(active: true, hasContent: false, offline: false, interval: interval) {
            let fill = appearance.colors.sunken
            VStack(alignment: .leading, spacing: m.sp20) {
                ForEach(0..<count, id: \.self) { index in
                    HStack(alignment: .top, spacing: m.sp12) {
                        RoundedRectangle(cornerRadius: m.avatar * 0.19).fill(fill).frame(
                            width: m.avatar, height: m.avatar)
                        VStack(alignment: .leading, spacing: m.sp8) {
                            RoundedRectangle(cornerRadius: m.radiusSmall).fill(fill).frame(
                                width: m(120), height: m.sp12)
                            // Varied widths read as text rather than as a grid.
                            RoundedRectangle(cornerRadius: m.radiusSmall).fill(fill)
                                .frame(width: m([320, 240, 280][index % 3]), height: m.sp12)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(m.sp20)
                .accessibilityHidden(true)
        }
    }
}

private struct AfterLoadingDelay<Content: View>: View {
    let active: Bool
    let hasContent: Bool
    let offline: Bool
    let interval: Performance.Name?
    @ViewBuilder let content: Content
    @State private var shown = false
    var body: some View {
        ZStack { if shown { content } }
            .loadingInterval(interval, while: active && !hasContent)
            .task(id: [active && !hasContent, offline]) {
                shown = false
                guard active, !hasContent else { return }
                let start = ContinuousClock.now
                try? await Task.sleep(for: LoadingPresentation.indicatorDelay)
                guard !Task.isCancelled else { return }
                shown = LoadingPresentation.showsIndicator(
                    waited: .now - start, hasContent: hasContent, offline: offline)
            }
    }
}
