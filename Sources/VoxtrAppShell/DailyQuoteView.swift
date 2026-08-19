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
/// Design Foundation V0.1 correction round: this view previously used
/// raw system semantic fonts/colors (`.largeTitle`/`.body`/
/// `.subheadline`, `.secondary`) directly, making it the one visible
/// default-SwiftUI island inside an otherwise restyled Athlete Home.
/// It now uses the same shared `VoxtrTypography`/`VoxtrColor` tokens
/// and `VoxtrSectionHeading`/`voxtrRowSurface()` every other Athlete
/// Home section already uses — no new, Quote-specific visual language,
/// no change to quote content, loading behaviour, or navigation. Both
/// call sites (`quoteSection` and the `.failed` state below) get the
/// same treatment, since both render as a `Section` on the same
/// screen.
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
                Section {
                    Text(DailyQuoteStrings.unavailable)
                        .font(VoxtrTypography.body)
                        .foregroundStyle(VoxtrColor.textSecondary)
                        .accessibilityIdentifier("dailyQuote.unavailable")
                } header: {
                    VoxtrSectionHeading(DailyQuoteStrings.sectionTitle)
                }
                .voxtrRowSurface()
            }
        }
        .onAppear {
            viewModel.load()
        }
    }

    private func quoteSection(_ quote: Quote) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\u{201C}")
                    .font(.largeTitle)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityHidden(true)
                Text(quote.text)
                    .font(VoxtrTypography.body)
                    .foregroundStyle(VoxtrColor.textPrimary)
                    .accessibilityIdentifier("dailyQuote.text")
                Text("— \(quote.author)")
                    .font(VoxtrTypography.metadata)
                    .foregroundStyle(VoxtrColor.textSecondary)
                    .accessibilityIdentifier("dailyQuote.author")
            }
            .accessibilityElement(children: .combine)
        } header: {
            VoxtrSectionHeading(DailyQuoteStrings.sectionTitle)
        }
        .voxtrRowSurface()
    }
}
