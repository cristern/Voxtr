import Foundation
import VoxtrCoreContracts

/// Activity Edit -> Split Activity: one row of `ActivityDetailViewModel`'s
/// local split draft, before the user taps "Split" and it becomes a real
/// `PlannedActivitySplitChild` sent to `PlanningService.splitPlannedActivity`.
/// Purely local UI state — the same "draft until an explicit commit
/// action" shape `ActivityReminderDraft` already establishes for this
/// same screen's Reminders section — nothing here is persisted until
/// `ActivityDetailViewModel.splitActivity()` succeeds.
///
/// `id` is LOCAL, UI-only identity for SwiftUI list diffing (`ForEach`,
/// add/remove) — a split child has no canonical identity of its own
/// until `splitActivity()` actually creates (or, for the first child,
/// edits) its `PlannedActivity` row.
public struct SplitChildDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var activityType: ActivityType
    public var startOffsetMinutes: Int
    public var durationMinutes: Int

    public init(
        id: UUID = UUID(),
        activityType: ActivityType,
        startOffsetMinutes: Int,
        durationMinutes: Int
    ) {
        self.id = id
        self.activityType = activityType
        self.startOffsetMinutes = startOffsetMinutes
        self.durationMinutes = durationMinutes
    }
}
