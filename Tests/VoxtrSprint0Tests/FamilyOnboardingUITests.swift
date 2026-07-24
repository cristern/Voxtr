import Testing
import Foundation
import SwiftData
import VoxtrCore
import VoxtrCoreContracts
@testable import VoxtrAppShell
import VoxtrParentDomain
import VoxtrAthleteDomain

// NOTE: like the other persistence-backed tests, the CreateFamilyViewModel
// tests require the Xcode/macOS SwiftData runtime — written but not
// executed in this sandbox. The validator tests are pure logic and would
// run anywhere.
//
// Following the S1.1 lesson: no shared private helper methods for
// container/coordinator construction — every test builds its own inline.

@Suite("FamilyOnboardingValidator (S1.4)")
struct FamilyOnboardingValidatorTests {

    @Test("Empty parent name is rejected")
    func emptyParentNameRejected() {
        #expect(FamilyOnboardingValidator.validateParentGivenName("") != nil)
        #expect(FamilyOnboardingValidator.validateParentGivenName("   ") != nil)
    }

    @Test("Parent name up to 80 characters is accepted, 81 is rejected")
    func parentNameLengthBoundary() {
        let eighty = String(repeating: "a", count: 80)
        let eightyOne = String(repeating: "a", count: 81)
        #expect(FamilyOnboardingValidator.validateParentGivenName(eighty) == nil)
        #expect(FamilyOnboardingValidator.validateParentGivenName(eightyOne) != nil)
    }

    @Test("Empty athlete name is rejected")
    func emptyAthleteNameRejected() {
        #expect(FamilyOnboardingValidator.validateAthleteGivenName("") != nil)
    }

    @Test("Athlete name up to 80 characters is accepted, 81 is rejected")
    func athleteNameLengthBoundary() {
        let eighty = String(repeating: "a", count: 80)
        let eightyOne = String(repeating: "a", count: 81)
        #expect(FamilyOnboardingValidator.validateAthleteGivenName(eighty) == nil)
        #expect(FamilyOnboardingValidator.validateAthleteGivenName(eightyOne) != nil)
    }

    @Test("A future birth date is rejected")
    func futureBirthDateRejected() {
        let future = Date.now.addingTimeInterval(60 * 60 * 24 * 365)
        #expect(FamilyOnboardingValidator.validateBirthDate(future) != nil)
    }

    @Test("A past birth date is accepted")
    func pastBirthDateAccepted() {
        let past = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)
        #expect(FamilyOnboardingValidator.validateBirthDate(past) == nil)
    }
}

@Suite("CreateFamilyViewModel (S1.4)", .serialized)
struct CreateFamilyViewModelTests {

    @Test("Submitting with an empty parent name shows a field error and does not create any entities")
    @MainActor
    func emptyParentNameBlocksSubmission() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = ""
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)

        viewModel.submit()

        #expect(viewModel.parentGivenNameError != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 0)
    }

    @Test("Submitting with a future birth date shows a field error and does not create any entities")
    @MainActor
    func futureBirthDateBlocksSubmission() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = "Kari"
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(60 * 60 * 24 * 365)

        viewModel.submit()

        #expect(viewModel.athleteBirthDateError != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
    }

    @Test("Valid input creates the family, clears errors, and calls onFamilyCreated")
    @MainActor
    func validInputCreatesFamily() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = "Kari"
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)

        var wasCalled = false
        viewModel.onFamilyCreated = { wasCalled = true }

        viewModel.submit()

        #expect(viewModel.parentGivenNameError == nil)
        #expect(viewModel.athleteGivenNameError == nil)
        #expect(viewModel.athleteBirthDateError == nil)
        #expect(viewModel.submissionError == nil)
        #expect(wasCalled)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
    }

    @Test("Whitespace-only names are trimmed and rejected as empty")
    @MainActor
    func whitespaceOnlyNameRejected() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = "   "
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)

        viewModel.submit()

        #expect(viewModel.parentGivenNameError != nil)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 0)
    }

    @Test("A reentrant submit() call while the first is still in progress is a no-op, preventing duplicate creation")
    @MainActor
    func reentrantSubmitIsPrevented() throws {
        // onFamilyCreated fires before isSubmitting is cleared (submit()
        // clears it via `defer`, which runs after onFamilyCreated is
        // called) — so setting onFamilyCreated to call submit() again is
        // a genuine, naturally-occurring reentrancy scenario, not an
        // artificial one.
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = "Kari"
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)

        var callCount = 0
        viewModel.onFamilyCreated = {
            callCount += 1
            if callCount == 1 {
                viewModel.submit()
            }
        }

        viewModel.submit()

        #expect(callCount == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 1)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 1)
    }

    @Test("A coordinator failure is surfaced as a submission error, not a crash")
    @MainActor
    func coordinatorFailureSurfacedAsSubmissionError() throws {
        let controller = InMemoryPersistenceController(modelTypes: AppSchema.modelTypes)
        let container = try controller.makeModelContainer()
        let coordinator = FamilyOnboardingCoordinator(
            modelContext: container.mainContext,
            parentWorkspaceRepository: ParentWorkspaceRepository(modelContext: container.mainContext),
            athleteRepository: AthleteRepository(modelContext: container.mainContext),
            athleteAccessGrantRepository: AthleteAccessGrantRepository(modelContext: container.mainContext)
        )
        let viewModel = CreateFamilyViewModel(coordinator: coordinator)
        viewModel.parentGivenName = "Kari"
        viewModel.athleteGivenName = "Jonas"
        viewModel.athleteBirthDate = Date.now.addingTimeInterval(-60 * 60 * 24 * 365 * 12)

        struct InjectedFailure: Error {}
        viewModel.testSaveOverride = { throw InjectedFailure() }

        viewModel.submit()

        #expect(viewModel.submissionError != nil)
        #expect(!viewModel.isSubmitting)
        #expect(try container.mainContext.fetch(FetchDescriptor<ParentProfile>()).count == 0)
        #expect(try container.mainContext.fetch(FetchDescriptor<AthleteProfile>()).count == 0)
    }
}
