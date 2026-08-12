import SwiftUI

struct NativProgressMark: View {
    let progress: Double?
    var width: CGFloat = 92

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var displayedProgress = 0.0

    var body: some View {
        ZStack {
            mark(color: trackColor)
            mark(color: .accentColor)
                .mask(alignment: .bottom) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(
                                    height: geometry.size.height * displayedProgress
                                )
                        }
                    }
                }
        }
        .frame(width: width, height: width / NativMarkImage.visibleAspectRatio)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model loading progress")
        .accessibilityValue(accessibilityValue)
        .onAppear {
            displayedProgress = normalizedProgress ?? 0
        }
        .onChange(of: normalizedProgress) { _, newProgress in
            updateDisplayedProgress(to: newProgress)
        }
    }

    private var normalizedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    private var trackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.11)
    }

    private var accessibilityValue: String {
        guard let normalizedProgress else {
            return "Preparing"
        }
        return "\(Int((normalizedProgress * 100).rounded())) percent"
    }

    private func mark(color: Color) -> some View {
        NativMarkImage()
            .foregroundStyle(color)
    }

    private func updateDisplayedProgress(to newProgress: Double?) {
        let value = newProgress ?? 0
        guard !reduceMotion, value >= displayedProgress else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayedProgress = value
            }
            return
        }

        withAnimation(.easeOut(duration: 0.22)) {
            displayedProgress = value
        }
    }
}

private struct NativMarkImage: View {
    // The source asset is square; these bounds remove its transparent margins so
    // progress maps to the visible mark rather than the image canvas.
    static let visibleAspectRatio: CGFloat = 491 / 280

    private static let sourceSize: CGFloat = 512
    private static let visibleMinX: CGFloat = 11
    private static let visibleMinY: CGFloat = 116
    private static let visibleWidth: CGFloat = 491

    var body: some View {
        GeometryReader { geometry in
            let imageSide = geometry.size.width * Self.sourceSize / Self.visibleWidth

            Image("NativMark")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: imageSide, height: imageSide)
                .offset(
                    x: -imageSide * Self.visibleMinX / Self.sourceSize,
                    y: -imageSide * Self.visibleMinY / Self.sourceSize
                )
        }
        .clipped()
    }
}

#Preview("Progress mark · Light") {
    VStack(spacing: 24) {
        NativProgressMark(progress: nil)
        NativProgressMark(progress: 0.42)
        NativProgressMark(progress: 1)
    }
    .padding(32)
    .preferredColorScheme(.light)
}

#Preview("Progress mark · Dark") {
    VStack(spacing: 24) {
        NativProgressMark(progress: nil)
        NativProgressMark(progress: 0.42)
        NativProgressMark(progress: 1)
    }
    .padding(32)
    .preferredColorScheme(.dark)
}
