import Testing
@testable import VoxtrAppShell

// Athlete Connection V1 (backend device authorization, review round 4's
// own UI finish). Exercises `AthleteDeviceAuthorizationReauthenticationSheetPresentation`
// directly — a pure, SwiftUI-free type with no reference to the
// coordinator or any network/decision logic — so the actual
// PRESENTATION STATE (whether the sheet should be shown, and how
// dismissal/reopening affects that) is tested deterministically without
// a UI test harness, per this round's own explicit instruction to test
// the presentation state and not only the network outcome.
@Suite("AthleteDeviceAuthorizationReauthenticationSheetPresentation (Athlete Connection V1, review round 4's own UI finish)")
struct AthleteDeviceAuthorizationReauthenticationSheetPresentationTests {

    @Test("A fresh presentation is shown exactly when authenticationRequired is true, and hidden otherwise")
    func freshPresentationTracksAuthenticationRequired() {
        let presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        #expect(presentation.isPresented(authenticationRequired: true) == true)
        #expect(presentation.isPresented(authenticationRequired: false) == false)
    }

    @Test("dismiss() hides the sheet even while authenticationRequired stays true, and sends no decision or retry of any kind — this type has no way to")
    func dismissHidesWhileAuthenticationStillRequired() {
        var presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        presentation.dismiss()

        #expect(presentation.isPresented(authenticationRequired: true) == false, "a dismissed sheet must not reappear on its own while the SAME authentication failure persists")
    }

    @Test("reopen() after dismiss() shows the SAME sheet again for the SAME still-pending operation, without anything else changing")
    func reopenAfterDismissShowsAgain() {
        var presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        presentation.dismiss()
        #expect(presentation.isPresented(authenticationRequired: true) == false)

        presentation.reopen()
        #expect(presentation.isPresented(authenticationRequired: true) == true, "'Sign in to continue' must be able to reopen the SAME sheet after an earlier cancel")
    }

    @Test("noteStateChanged(authenticationRequired: false) clears a dismissal — a LATER, genuinely new authentication failure presents the sheet again without any explicit reopen")
    func stateLeavingAuthenticationRequiredClearsDismissal() {
        var presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        presentation.dismiss()
        presentation.noteStateChanged(authenticationRequired: false)

        #expect(presentation.isPresented(authenticationRequired: true) == true, "a brand-new authentication failure must present the sheet again, not stay suppressed by an earlier unrelated dismissal")
    }

    @Test("noteStateChanged(authenticationRequired: true) is a no-op — it never clears an existing dismissal while the SAME failure is still current")
    func stateStayingAuthenticationRequiredPreservesDismissal() {
        var presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        presentation.dismiss()
        presentation.noteStateChanged(authenticationRequired: true)

        #expect(presentation.isPresented(authenticationRequired: true) == false, "a late-arriving 'still authenticationRequired' notice must never resurrect a dismissal the Parent already made for this SAME failure")
    }

    @Test("dismiss() alone never flips isPresented(authenticationRequired: false) to true — it has no way to cause a presentation when none is required")
    func dismissNeverPresentsWhenNotRequired() {
        var presentation = AthleteDeviceAuthorizationReauthenticationSheetPresentation()

        presentation.dismiss()

        #expect(presentation.isPresented(authenticationRequired: false) == false)
    }
}
