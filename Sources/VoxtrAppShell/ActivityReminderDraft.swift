import Foundation
import VoxtrCoreContracts
import VoxtrNotificationsDomain

/// Activity Reminder What/When: the ONE small value type both the
/// Planned Activity CREATE flow (`WeeklyPlanningViewModel`) and the
/// EDIT flow (`ActivityDetailViewModel`) use to represent a reminder
/// row while the user is actively working with it — before, during,
/// and after it becomes a genuinely persisted `ActivityReminder`.
///
/// `id` is a LOCAL, UI-only identity (stable across edits to `text`/
/// `leadTimeMinutes` so SwiftUI list diffing/`@FocusState` keep working
/// correctly) — never confused with `persistedId`, the reminder's real
/// `ActivityReminderId` once it actually exists in Notifications truth.
///
/// `persistedId == nil` means one of two things depending on context:
/// in the CREATE flow, this draft has never been submitted at all (the
/// canonical `PlannedActivity` doesn't exist yet — "never schedule/
/// persist a reminder against a temporary/draft activity identity" is
/// enforced by never calling into `NotificationsPlanningCoordinationService`
/// until Save succeeds); in the EDIT flow, this draft was submitted but
/// the attempt did not succeed (see `authorizationDenied`/
/// `errorMessage` below) — the row stays visible so the user can retry
/// or edit it again, never silently disappears.
public struct ActivityReminderDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var leadTimeMinutes: Int
    public var persistedId: ActivityReminderId?
    /// Set when the most recent attempt to persist/update THIS specific
    /// reminder was declined by notification authorization — the same
    /// calm, expected outcome PR #37's own single-reminder
    /// `reminderAuthorizationDenied` already tracked, now per row
    /// instead of once globally.
    public var authorizationDenied: Bool
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        text: String = "",
        leadTimeMinutes: Int = 30,
        persistedId: ActivityReminderId? = nil,
        authorizationDenied: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.text = text
        self.leadTimeMinutes = leadTimeMinutes
        self.persistedId = persistedId
        self.authorizationDenied = authorizationDenied
        self.errorMessage = errorMessage
    }

    /// Whether this draft actually represents a genuine reminder intent
    /// worth persisting — an empty/whitespace-only "what" is never
    /// submitted (matches the create/edit UI's own requirement that
    /// every reminder have user-authored text).
    public var hasMeaningfulText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
