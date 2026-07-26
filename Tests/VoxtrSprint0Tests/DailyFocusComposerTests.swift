import Testing
import Foundation
import VoxtrCoreContracts
@testable import VoxtrAppShell
@testable import VoxtrCoachingDomain
import VoxtrPlanningDomain
import VoxtrTrainingDomain

/// `DailyFocusComposer` is a pure function over already-loaded values —
/// no `@Model`/SwiftData involvement anywhere in this file, so no
/// container/repository setup is needed at all, matching
/// `CoachingEngineTests`' pattern exactly.

@Suite("DailyFocusComposer (Sprint 13, architecture correction)", .serialized)
struct DailyFocusComposerTests {

    private static let athleteId = AthleteId()
    private static let weekStart = LocalDate(year: 2026, month: 1, day: 5)
    private static let oslo = TimeZoneId(rawValue: "Europe/Oslo")

    private static func makePlannedActivity(title: String) -> PlannedActivity {
        PlannedActivity(
            weekPlanId: WeekPlanId(), athleteId: athleteId, activityType: .individualTraining,
            title: title, localDate: weekStart, timeZoneId: oslo
        )
    }

    private static let actionableCoaching = CoachingPresentation(
        athleteId: athleteId, weekStart: weekStart,
        sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
            CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
        ])]
    )

    private static let noActionCoaching = CoachingPresentation(
        athleteId: athleteId, weekStart: weekStart,
        sections: [CoachingPresentationSection(title: "Weekly Reflection", items: [
            CoachingPresentationItem(insight: .weeklyReflectionCompleted, text: "A weekly reflection was recorded.", emphasis: .positive, action: .none),
        ])]
    )

    @Test("An incomplete planned activity becomes the focus")
    func incompleteTrainingBecomesFocus() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]

        let focus = DailyFocusComposer().compose(todaysActivities: activities, coaching: Self.actionableCoaching)

        #expect(focus?.source == .todaysTraining)
        #expect(focus?.title == "Endurance run")
        #expect(focus?.subtitle == TrainingStrings.notCompletedLabel)
    }

    @Test("An actionable coaching item becomes the focus when no incomplete training exists")
    func actionableCoachingBecomesFocusWhenNoIncompleteTraining() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: true)]

        let focus = DailyFocusComposer().compose(todaysActivities: activities, coaching: Self.actionableCoaching)

        #expect(focus?.source == .coaching)
        #expect(focus?.title == "No weekly reflection was recorded.")
        #expect(focus?.action == .startWeeklyReflection)
    }

    @Test("Incomplete training has priority over an actionable coaching item when both are present")
    func incompleteTrainingHasPriorityOverCoaching() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]

        let focus = DailyFocusComposer().compose(todaysActivities: activities, coaching: Self.actionableCoaching)

        #expect(focus?.source == .todaysTraining)
    }

    @Test("No qualifying input produces the empty state, nil")
    func noQualifyingInputProducesEmptyState() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: true)]

        let focus = DailyFocusComposer().compose(todaysActivities: activities, coaching: Self.noActionCoaching)

        #expect(focus == nil)
    }

    @Test("Training data alone (coaching nil) can still produce a focus")
    func trainingAloneProducesFocus() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]

        let focus = DailyFocusComposer().compose(todaysActivities: activities, coaching: nil)

        #expect(focus?.source == .todaysTraining)
    }

    @Test("Coaching data alone (training nil) can still produce a focus")
    func coachingAloneProducesFocus() {
        let focus = DailyFocusComposer().compose(todaysActivities: nil, coaching: Self.actionableCoaching)

        #expect(focus?.source == .coaching)
        #expect(focus?.action == .startWeeklyReflection)
    }

    @Test("Both nil produces nil — the composer never invents fallback content")
    func bothNilProducesNil() {
        let focus = DailyFocusComposer().compose(todaysActivities: nil, coaching: nil)

        #expect(focus == nil)
    }

    @Test("Repeated composition of equivalent input produces equal output")
    func repeatedCompositionProducesEqualOutput() {
        let activities = [PlannedActivityCompletion(plannedActivity: Self.makePlannedActivity(title: "Endurance run"), isCompleted: false)]
        let composer = DailyFocusComposer()

        let first = composer.compose(todaysActivities: activities, coaching: Self.actionableCoaching)
        let second = composer.compose(todaysActivities: activities, coaching: Self.actionableCoaching)

        #expect(first == second)
    }

    @Test("The first actionable coaching item follows the coaching presentation's own existing deterministic section order")
    func firstActionableItemFollowsExistingSectionOrder() {
        let multiSectionCoaching = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [
                CoachingPresentationSection(title: "Planned Activities", items: [
                    CoachingPresentationItem(insight: .allPlannedActivitiesCompleted, text: "All planned activities were completed this week.", emphasis: .positive, action: .none),
                ]),
                CoachingPresentationSection(title: "Weekly Reflection", items: [
                    CoachingPresentationItem(insight: .noWeeklyReflection, text: "No weekly reflection was recorded.", emphasis: .attention, action: .startWeeklyReflection),
                ]),
                CoachingPresentationSection(title: "Parent Observations", items: [
                    CoachingPresentationItem(insight: .noParentObservations, text: "No parent observations were recorded this week.", emphasis: .neutral, action: .addParentObservation),
                ]),
            ]
        )

        let focus = DailyFocusComposer().compose(todaysActivities: nil, coaching: multiSectionCoaching)

        // "Weekly Reflection" is the first section with an actionable
        // item — "Planned Activities" has none (.none), so it's the
        // Weekly Reflection item that wins, not the later Parent
        // Observations one, even though both are actionable.
        #expect(focus?.title == "No weekly reflection was recorded.")
        #expect(focus?.action == .startWeeklyReflection)
    }

    @Test(".addParentObservation is preserved as the action value for traceability, even though no UI control renders it")
    func addParentObservationActionValuePreserved() {
        let observationCoaching = CoachingPresentation(
            athleteId: Self.athleteId, weekStart: Self.weekStart,
            sections: [CoachingPresentationSection(title: "Parent Observations", items: [
                CoachingPresentationItem(insight: .noParentObservations, text: "No parent observations were recorded this week.", emphasis: .neutral, action: .addParentObservation),
            ])]
        )

        let focus = DailyFocusComposer().compose(todaysActivities: nil, coaching: observationCoaching)

        // The composer's job is only to select and preserve this value
        // — whether/how a view renders a control for it is a separate,
        // UI-layer concern (see DailyFocusCardView).
        #expect(focus?.action == .addParentObservation)
        #expect(focus?.source == .coaching)
    }
}
