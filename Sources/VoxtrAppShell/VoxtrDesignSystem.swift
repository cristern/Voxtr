import SwiftUI
import UIKit
import VoxtrAthleteDomain
import VoxtrCoreContracts

// MARK: - VoxtrColor

/// Vǫxtr Parent App Design Foundation V0.1 — semantic colour tokens.
///
/// WORKING IMPLEMENTATION VALUES, not final brand values — see this
/// round's own delivery report for the exact hex values chosen and the
/// reasoning behind the dark variant (a deliberate, coherent dark
/// palette, never a mechanical inversion of the light one).
///
/// No asset catalog is used: `VoxtrAppShell` is a Swift Package target,
/// and adding a Colors.xcassets here would require a `Package.swift`
/// resource-declaration change this round has no reason to make.
/// Instead, each token is a `UIColor` dynamic provider (resolved from
/// `UITraitCollection.userInterfaceStyle`) wrapped in `Color` — the
/// standard code-only technique for a SwiftUI colour that follows
/// system light/dark appearance automatically, with no in-app
/// appearance selector and no `@Environment(\.colorScheme)` plumbing
/// required at every call site.
///
/// One consistent palette across Parent App — Family Home and Athlete
/// Home both use exactly these tokens; nothing here is athlete-themed
/// (see `AthleteColor` below for the separate, identity-only palette,
/// restricted to shared/multi-athlete surfaces).
public enum VoxtrColor {
    /// Screen background. Light `#F4F7F6`, dark `#10191D` (deep
    /// charcoal-navy, not a literal inversion of the light value).
    public static let background = dynamic(light: 0xF4F7F6, dark: 0x10191D)
    /// Primary card/group surface. Light `#FFFFFF`, dark `#17242A`
    /// (slightly lighter than `background`, per the working dark
    /// direction).
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x17242A)
    /// Lower-emphasis grouped/selected surface. Light `#EDF3F1`, dark
    /// `#1E2E34`.
    public static let surfaceSubtle = dynamic(light: 0xEDF3F1, dark: 0x1E2E34)
    /// Primary text. Light `#18313D`, dark `#EDF3F1` (off-white, not
    /// pure white).
    public static let textPrimary = dynamic(light: 0x18313D, dark: 0xEDF3F1)
    /// Secondary/metadata text. Light `#57666D`, dark `#8FA39D` (muted
    /// cool grey-green, matching the light value's own cool cast).
    ///
    /// TestFlight visual feedback round: the light value was `#66757C`
    /// — measured ~4.4:1 contrast against `background` (`#F4F7F6`),
    /// under the 4.5:1 AA threshold for normal-size text and genuinely
    /// inadequate for the smaller caption/metadata sizes this token is
    /// mostly used at, which need MORE contrast than body text, not
    /// less. Matches the reported "too faint in normal daylight"
    /// symptom. Darkened to `#57666D` (~5.5:1 against `background`,
    /// ~5.8:1 against `surface`) — the SAME hue/cast, just deepened,
    /// still clearly secondary and far short of `textPrimary`'s
    /// `#18313D` (~13:1). The dark value is unchanged: `#8FA39D`
    /// already measures ~6:1 against `surface`, comfortably passing,
    /// and TestFlight feedback was specific to daylight/light-mode
    /// legibility. Changed here, once, at the token layer — not as a
    /// per-row local override, so every existing caller of this token
    /// picks up the correction automatically.
    public static let textSecondary = dynamic(light: 0x57666D, dark: 0x8FA39D)
    /// Deep navy — a strong, non-accent emphasis tone (distinct from
    /// `accent`). Light `#153243`, dark `#3E6478` (lightened so it
    /// still reads against a dark background — the light value is
    /// itself dark, so it cannot be reused unchanged in dark mode).
    public static let navy = dynamic(light: 0x153243, dark: 0x3E6478)
    /// Primary accent — selection states, tint, links. Light `#177D78`,
    /// dark `#56C2B3` (brighter, for contrast against a dark
    /// background).
    public static let accent = dynamic(light: 0x177D78, dark: 0x56C2B3)
    /// Brightest accent step — reserved for the strongest single
    /// highlight (e.g. a selected value's fill). Light `#45B8AA`, dark
    /// `#7DD9CB`.
    public static let accentBright = dynamic(light: 0x45B8AA, dark: 0x7DD9CB)
    /// Soft accent wash — subtle selected/emphasised backgrounds. Light
    /// `#D8F0EA`, dark `#1C3B38` (a deep, low-luminance teal wash, not
    /// a pale one — a pale wash would be nearly invisible against a
    /// dark surface).
    public static let accentSoft = dynamic(light: 0xD8F0EA, dark: 0x1C3B38)
    /// Divider/border. Light `#DDE5E2`, dark `#2C3D40` (kept visible,
    /// not just a low-opacity white/black).
    public static let divider = dynamic(light: 0xDDE5E2, dark: 0x2C3D40)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - AthleteColor (presentation)

/// Athlete Color — IDENTITY ONLY, never performance/readiness/warning/
/// completion/ranking. Restricted to shared/multi-athlete surfaces
/// (Family Home); never used as Athlete Home's own theme — see
/// `HomeDashboardView`, which does not reference this type at all.
///
/// `AthleteColor` itself (the eight cases) is declared in
/// `VoxtrCoreContracts/SharedEnums.swift` — it is the SAME type
/// `AthleteSettings.preferredColor` persists (Design Foundation V0.1,
/// Athlete Color canonical preference round), extended here with the
/// `Color`-rendering and stable-fallback pieces that can only live
/// where SwiftUI/UIKit are importable. One canonical type end to end:
/// domain declares the cases, this extension renders them — never two
/// separate colour enums.
///
/// The eight working hex values below are fixed and identical in light
/// and dark mode — an identity accent, unlike the semantic `VoxtrColor`
/// tokens, is not meant to shift with appearance the way a background
/// or text tone does; each is already legible against both `surface`
/// tones as a thin outline/marker, the only sanctioned treatment, never
/// as a fill behind text.
public extension AthleteColor {
    var color: Color {
        switch self {
        case .blue: Color(uiColor: UIColor(hex: 0x4F7CAC))
        case .indigo: Color(uiColor: UIColor(hex: 0x6667AB))
        case .purple: Color(uiColor: UIColor(hex: 0x8A63A8))
        case .rose: Color(uiColor: UIColor(hex: 0xB56576))
        case .orange: Color(uiColor: UIColor(hex: 0xC77D4A))
        case .amber: Color(uiColor: UIColor(hex: 0xB88A32))
        case .green: Color(uiColor: UIColor(hex: 0x4F8A68))
        case .cyan: Color(uiColor: UIColor(hex: 0x3F8E9D))
        }
    }

    /// Athlete Settings' inline Color picker's own display label — the
    /// one UI-facing string form of this domain enum's raw case name.
    /// Purely presentational (never persisted, never compared) — the
    /// persisted value is always the enum case itself.
    var displayName: String {
        switch self {
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .rose: "Rose"
        case .orange: "Orange"
        case .amber: "Amber"
        case .green: "Green"
        case .cyan: "Cyan"
        }
    }

    /// The stable FALLBACK mapping — used only when an athlete has no
    /// explicit `AthleteSettings.preferredColor` (never set, or the
    /// settings row itself doesn't exist yet). Design Foundation V0.1
    /// correction round: the FIRST working version of this mapping used
    /// the athlete's position in `activeAthletes` — rejected on review,
    /// correctly, because Athlete Color is an identity aid: an athlete
    /// added/archived/reordered elsewhere in the roster must never make
    /// a DIFFERENT athlete's own colour appear to change. This version
    /// derives entirely from the athlete's own stable `AthleteId`
    /// instead — nothing about any other athlete's presence, order, or
    /// count affects it.
    ///
    /// `AthleteId` is `Identifier<AthleteTag>`, whose only stored value
    /// is a `UUID` (see `Identifier`'s own declaration in
    /// `VoxtrCoreContracts/Identifier.swift`). `UUID.uuid` exposes that
    /// UUID's own 16 raw bytes directly — a fixed property of the value
    /// itself, unrelated to Swift's `hashValue` (which this
    /// deliberately does NOT use: `hashValue` is randomly seeded per
    /// process specifically for hash-flooding resistance, so the exact
    /// same `AthleteId` can hash differently on two different app
    /// launches — exactly the instability this mapping must avoid).
    /// Summing those 16 bytes and taking the result modulo the
    /// eight-colour palette is a plain, deterministic function of the
    /// `AthleteId`'s own persisted identity: the same `AthleteId`
    /// always sums to the same total, on every launch, regardless of
    /// where it sits in any list.
    ///
    /// Canonical preference round: this fallback is now used ONLY when
    /// `AthleteSettings.preferredColor` is `nil` — see
    /// `FamilyHomeViewModel.resolvedAthleteColor(for:)` and
    /// `AthleteFamilyManagementViewModel.resolvedColor(for:)`, the two
    /// call sites that apply "explicit preference wins, otherwise this
    /// fallback." Never bypassed by reading this directly wherever an
    /// athlete's resolved colour is actually needed for display.
    static func forAthleteId(_ athleteId: AthleteId) -> AthleteColor {
        let uuid = athleteId.rawValue.uuid
        let bytes: [UInt8] = [
            uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15,
        ]
        let sum = bytes.reduce(0) { $0 + Int($1) }
        return allCases[((sum % allCases.count) + allCases.count) % allCases.count]
    }

    /// Design Foundation extension round: the ONE canonical "explicit
    /// preference wins, otherwise the stable fallback" resolution,
    /// shared by every shared/multi-athlete surface —
    /// `FamilyHomeViewModel.loadAthleteColors()`, `ParentTrainingTabView`
    /// (`ParentTabShellView.swift`), and `FamilyScheduleViewModel`'s
    /// injected resolver all call through this one implementation
    /// rather than each re-deriving the same two-step lookup inline.
    /// One athlete's fetch failure never blocks resolution for another
    /// — falls back to the stable mapping for this athlete only, same
    /// per-athlete isolation `loadAthleteColors()` already established.
    static func resolved(forAthlete athleteId: AthleteId, using athleteRepository: AthleteRepository) -> AthleteColor {
        let settings = try? athleteRepository.fetchAthleteSettings(forAthlete: athleteId)
        let preferred = (settings ?? nil)?.preferredColor
        return preferred ?? forAthleteId(athleteId)
    }
}

// MARK: - VoxtrTypography

/// Semantic type roles, built entirely on the system font and native
/// SwiftUI text styles — no custom font, no one-off point sizes scattered
/// across views. Deliberately small: only the roles this round's two
/// target screens actually need.
public enum VoxtrTypography {
    /// A large heading inside body content (distinct from the
    /// navigation bar's own large title, which SwiftUI already renders
    /// natively via `.navigationTitle`).
    public static let screenTitle: Font = .system(.title2, weight: .semibold)
    /// A `Section` heading.
    public static let sectionTitle: Font = .system(.subheadline, weight: .semibold)
    /// A card/row's own primary title (an activity title, an athlete's
    /// name).
    public static let cardTitle: Font = .system(.headline)
    /// Ordinary body copy.
    public static let body: Font = .system(.body)
    /// A data value read alongside a label (a Sleep score, a date).
    public static let value: Font = .system(.body, weight: .medium)
    /// A secondary metadata line (location, weekday, outcome).
    public static let metadata: Font = .system(.caption)
    /// The smallest supporting text (a small badge like "Recurring").
    public static let caption: Font = .system(.caption2)
}

// MARK: - VoxtrSpacing

/// TestFlight visual feedback round (athlete identity outline geometry
/// fix): the first spacing tokens this design layer introduces — the
/// prior outline geometry hardcoded a single `2pt` inset directly in
/// `voxtrAthleteIdentityOutline` with no separate concept of "distance
/// from the true card edge" vs. "distance from the content," which is
/// exactly why the outline could end up simultaneously too far from
/// the white card's true edge AND too close to the text (both distances
/// were the same one hardcoded number). These name the two distances
/// this fix's four-layer hierarchy needs — card → outline → content —
/// so any future row reusing the outline gets both automatically,
/// instead of a new hardcoded value per screen.
public enum VoxtrSpacing {
    /// Horizontal gap between a row's true white-card edge and the
    /// athlete-colour outline stroke (approved range ~8-10pt).
    public static let cardOutlineInset: CGFloat = 9
    /// Vertical counterpart of `cardOutlineInset`. Deliberately smaller
    /// than the horizontal value — the approved range is specified for
    /// the horizontal proximity problem this round fixes (text/chevron
    /// crowding the outline); vertically, rows only need enough margin
    /// that a multi-line row's text can't touch the stroke, not the
    /// same magnitude of inset on every edge.
    public static let cardOutlineInsetVertical: CGFloat = 6
    /// Horizontal gap between the outline stroke and the row's own
    /// content (text, chevron) — the minimum breathing room that
    /// guarantees the outline can never intersect text (approved range
    /// ~14-16pt).
    public static let cardContentPadding: CGFloat = 15
    /// Vertical counterpart of `cardContentPadding`, deliberately more
    /// modest for the same reason `cardOutlineInsetVertical` is smaller
    /// than `cardOutlineInset` — enough clearance above/below text
    /// without making every activity row unnecessarily tall.
    public static let cardContentPaddingVertical: CGFloat = 10
}

// MARK: - Reusable view primitives

/// The small, shared foundation both target screens use — nothing here
/// is a general-purpose component library; each modifier exists only
/// because both Family Home and Athlete Home need it.
public extension View {
    /// Applied once to a screen's own `Form`: replaces the system's
    /// default grouped-list background with `VoxtrColor.background`,
    /// the semantic screen background token. `Form`/`Section`
    /// structure, navigation, swipe actions, and every existing
    /// destination are completely unchanged — only the background
    /// colour underneath them changes; this is the standard, minimal
    /// technique for reskinning a `Form` without replacing it with a
    /// custom container (which would risk exactly the IA/behavior
    /// regressions this round is explicitly asked to avoid).
    func voxtrScreenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(VoxtrColor.background)
    }

    /// Applied to a `Section`'s content (via `.listRowBackground`) to
    /// use the semantic `surface` token instead of the system default —
    /// the Section itself keeps its native grouped corner rounding;
    /// only its fill colour changes. This is "grouping relies on
    /// spacing before adding more boxes": every row in a Section still
    /// reads as one coherent card, exactly as `Form`'s own grouped
    /// style already renders it, just recoloured.
    func voxtrRowSurface() -> some View {
        listRowBackground(VoxtrColor.surface)
    }

    /// The one genuine "card" primitive this round introduces — a
    /// small, explicitly bordered/rounded sub-grouping used only where
    /// a Section's own implicit row-card isn't the right unit (the
    /// inline Sleep value row, an Athlete Home identity marker). Card
    /// radius 14pt (within the requested ~12-16pt range), a hairline
    /// `divider`-coloured border, no shadow.
    func voxtrCardSurface(cornerRadius: CGFloat = 14, fill: Color = VoxtrColor.surfaceSubtle) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(VoxtrColor.divider, lineWidth: 0.5)
        )
    }

    /// TestFlight visual feedback round (Athlete Color inset outline):
    /// the approved replacement for the earlier small identity-dot-only
    /// treatment on athlete-specific ACTIVITY rows (Now/Next, Today's
    /// Schedule, Tomorrow) — a subtle inner colour outline that follows
    /// the row's own rounded card shape. Colour only — no fill, so this
    /// never competes with `voxtrRowSurface()`'s own `VoxtrColor.surface`
    /// row background, and carries no status/performance/readiness
    /// meaning (see `AthleteColor`'s own doc comment). Non-activity,
    /// non-athlete-specific rows (a "View upcoming schedule" link, an
    /// error message) never receive this modifier at all.
    ///
    /// Geometry fix, root cause: the original version applied a single
    /// `2pt` inset directly to whatever content frame this modifier was
    /// attached to (typically a `NavigationLink`'s own label VStack with
    /// no horizontal padding of its own) — with no separate notion of
    /// "distance from the row's TRUE white-card edge" vs. "distance
    /// from the row's own text." In a `Form`/`List`, that content frame
    /// starts well inside the row's true edges (List reserves its own
    /// leading/trailing content inset, then a further system gutter for
    /// the disclosure chevron), so the outline ended up simultaneously
    /// too far inward from the true card edge AND right up against the
    /// text with zero breathing room, and the system chevron — rendered
    /// in that same reserved gutter, outside the content frame this
    /// modifier ever saw — sat outside/crowding the stroke rather than
    /// inside it.
    ///
    /// Fix: this is now a genuine three-layer container-level modifier,
    /// applied to the row/card container itself (a `NavigationLink` or
    /// row `VStack`), not to a content frame that starts at the text:
    /// 1. `VoxtrSpacing.cardContentPadding`/`cardContentPaddingVertical`
    ///    around the caller's own content — guarantees the outline can
    ///    never intersect text.
    /// 2. `.frame(maxWidth: .infinity, alignment: .leading)` — the
    ///    padded content fills the FULL width this modifier is given,
    ///    so the outline stroke drawn next spans the whole row, not
    ///    just the text's own intrinsic width.
    /// 3. The stroke itself, drawn via `.overlay` at that full-width,
    ///    padded frame — genuinely colour-only, no fill, no shadow.
    /// 4. `.listRowInsets(...)`, set to exactly
    ///    `VoxtrSpacing.cardOutlineInset`/`cardOutlineInsetVertical` —
    ///    this is what actually controls the ONE remaining distance,
    ///    "outline to the row's true white-card edge," authoritatively
    ///    (List's own undocumented default inset is neither reliable
    ///    nor under this modifier's control otherwise) — this is also
    ///    why every call site needs the chevron to land inside the
    ///    outline: the approved 8-10pt range is deliberately smaller
    ///    than the disclosure chevron's own system-reserved trailing
    ///    gutter (a well-established, effectively-constant grouped-list
    ///    margin, not something this modifier can query directly), so
    ///    the chevron reliably renders further inward than the stroke.
    ///
    /// Does not affect the tap target: `overlay` is purely decorative
    /// and never participates in hit-testing, so the row's own
    /// `NavigationLink`/tap-target shape (typically the same rounded
    /// rectangle, via `.contentShape` where a caller already sets one)
    /// is completely unaffected by this modifier's presence.
    func voxtrAthleteIdentityOutline(_ color: Color, cornerRadius: CGFloat = 14) -> some View {
        padding(.horizontal, VoxtrSpacing.cardContentPadding)
            .padding(.vertical, VoxtrSpacing.cardContentPaddingVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
            )
            .listRowInsets(EdgeInsets(
                top: VoxtrSpacing.cardOutlineInsetVertical,
                leading: VoxtrSpacing.cardOutlineInset,
                bottom: VoxtrSpacing.cardOutlineInsetVertical,
                trailing: VoxtrSpacing.cardOutlineInset
            ))
    }
}

/// A `Section` header rendered with `VoxtrTypography.sectionTitle` and
/// `VoxtrColor.textSecondary` — the one standard section-heading
/// treatment both target screens use wherever they need a styled
/// (rather than the plain string-convenience) header. `.textCase(nil)`
/// preserves the title's own capitalisation instead of the system
/// default all-caps grouped-list header style, matching this round's
/// calmer, less form-like visual goal.
public struct VoxtrSectionHeading: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(VoxtrTypography.sectionTitle)
            .foregroundStyle(VoxtrColor.textSecondary)
            .textCase(nil)
    }
}
