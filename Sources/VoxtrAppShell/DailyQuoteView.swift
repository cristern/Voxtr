import SwiftUI
import VoxtrMotivationDomain

/// Sprint 15: renders today's `Quote`. Self-contained, unlike
/// `DailyFocusCardView` — it owns its own `DailyQuoteViewModel`
/// directly, because nothing else in `HomeDashboardView` already loads
/// this data (unlike Daily Focus, which duplicated data
/// `HomeDashboardViewModel` already owned, and was corrected for
/// exactly that reason). There is no "single owner" conflict to avoid
/// here — Daily Quote is a genuinely independent pipeline.
///
/// Native SwiftUI only: semantic fonts (`.largeTitle`/`.body`/
/// `.subheadline`) for Dynamic Type support, semantic colors
/// (`.secondary`, default foreground) for Dark Mode — no fixed point
/// sizes, no hardcoded RGB, no custom design system. No animation
/// anywhere in this file.
public struct DailyQuoteView: View {
    @State private var viewModel: DailyQuoteViewModel

    public init(viewModel: DailyQuoteViewModel = DailyQuoteViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                EmptyView()
            case .loaded(let quote):
                if let quote {
                    quoteSection(quote)
                }
                // An empty repository (`quote == nil`) renders nothing
                // — no invented placeholder text, matching this
                // project's established rule against inventing
                // fallback content. Distinct from `.failed` below —
                // this is "loaded successfully, nothing to show," not
                // a failure.
            case .failed:
                Section(DailyQuoteStrings.sectionTitle) {
                    Text(DailyQuoteStrings.unavailable)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("dailyQuote.unavailable")
                }
            }
        }
        .onAppear {
            viewModel.load()
        }
    }

    private func quoteSection(_ quote: Quote) -> some View {
        Section(DailyQuoteStrings.sectionTitle) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\u{201C}")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(quote.text)
                    .font(.body)
                    .accessibilityIdentifier("dailyQuote.text")
                Text("— \(quote.author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dailyQuote.author")
            }
            .accessibilityElement(children: .combine)
        }
    }
}
