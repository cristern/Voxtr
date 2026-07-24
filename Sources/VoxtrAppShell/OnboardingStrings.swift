import Foundation

/// S1.5: centralizes onboarding's user-facing strings that are built as
/// plain `String` values (validator messages, status text) rather than
/// passed as literals directly to `Text`/`TextField`. SwiftUI already
/// treats a string LITERAL passed straight to `Text("...")` as an
/// automatically-localizable `LocalizedStringKey` — that part of
/// `CreateFamilyView` needed no change. The gap was messages built
/// elsewhere (here, in `FamilyOnboardingValidator`, in `RootView`) and
/// handed to `Text(_:)` as a `String` variable, which SwiftUI treats as
/// already-resolved, non-localizable text.
///
/// `String(localized:defaultValue:)` makes each of these discoverable by
/// Xcode's String Catalog tooling later without touching any call site
/// again — no `.xcstrings` file is being added in S1.5, this only
/// structures the code so adding one later doesn't require a redesign.
public enum OnboardingStrings {
    public static var enterYourName: String {
        String(localized: "onboarding.parentName.empty", defaultValue: "Enter your name.")
    }

    public static var nameTooLong: String {
        String(localized: "onboarding.name.tooLong", defaultValue: "Name must be 80 characters or fewer.")
    }

    public static var enterAthleteName: String {
        String(localized: "onboarding.athleteName.empty", defaultValue: "Enter the athlete's name.")
    }

    public static var birthDateInFuture: String {
        String(localized: "onboarding.birthDate.future", defaultValue: "Birth date can't be in the future.")
    }

    public static var couldNotReadBirthDate: String {
        String(
            localized: "onboarding.birthDate.unreadable",
            defaultValue: "Couldn't read the selected birth date. Please try again."
        )
    }

    public static var genericSubmissionError: String {
        String(
            localized: "onboarding.submission.generic",
            defaultValue: "Something went wrong creating the family. Please try again."
        )
    }

    public static var inconsistentGraphTitle: String {
        String(localized: "onboarding.inconsistentGraph.title", defaultValue: "Something needs attention")
    }

    public static var couldNotReloadAfterCreation: String {
        String(
            localized: "onboarding.restoration.reloadFailedPrefix",
            defaultValue: "Couldn't reload family data after creating it:"
        )
    }
}
