import SwiftUI

/// While a book opens: a spinner and a small, friendly line that changes every couple of seconds,
/// so a long PDF (or one that needs text recognition) feels like a moment, not a hang.
struct LoadingView: View {
    var theme: TextTheme = .light
    @ViewState private var index = Int.random(in: 0..<LoadingLines.all.count)

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(LoadingLines.all[index])
                .font(.system(.title3, design: .serif))
                .foregroundStyle(Color(nsColor: theme.muted))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .id(index)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening your book")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.easeInOut(duration: 0.4)) { index = (index + 1) % LoadingLines.all.count }
            }
        }
    }
}

enum LoadingLines {
    static let all = [
        "Fluffing the pages…",
        "Brewing a cup of tea for you…",
        "Finding your bookmark…",
        "Dusting off the cover…",
        "Lighting a cosy reading lamp…",
        "Smoothing out the dog-ears…",
        "Asking the words to line up nicely…",
        "Plumping the reading cushion…",
        "Turning to just the right page…",
        "Shushing the library…",
        "Warming up the margins…",
        "Collecting every last comma…",
    ]
}
