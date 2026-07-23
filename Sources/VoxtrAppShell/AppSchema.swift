import Foundation
import SwiftData
import VoxtrCore
import VoxtrAthleteDomain
import VoxtrParentDomain

/// The set of `@Model` types the running app persists locally.
///
/// `VoxtrCore` cannot know these types — no `*Domain` package may be
/// imported by Core (see `Package.swift`'s dependency rule). `VoxtrAppShell`
/// is the one package allowed to see every domain, so this is where the
/// real schema gets assembled and handed down to
/// `SwiftDataPersistenceController`.
///
/// SCOPE NOTE (Sprint 1, story S1.0): only entities Sprint 1 actually
/// creates are listed here — `AthleteProfile`, `ParentProfile`,
/// `FamilyWorkspace`, `WorkspaceParticipant`, `AthleteAccessGrant` — plus
/// `AppDiagnosticsRecord` from Sprint 0. Do NOT add Planning/Training/
/// Reflection/Development/DecisionSupport/Notifications model types here
/// until a sprint that actually creates them (Sprint 2+, per the
/// approved roadmap). An unused registered type wouldn't break anything
/// technically, but keeping this list matched to what's actually
/// implemented keeps it honest about Sprint 1's real scope.
public enum AppSchema {
    public static var modelTypes: [any PersistentModel.Type] {
        [
            AppDiagnosticsRecord.self,
            AthleteProfile.self,
            ParentProfile.self,
            FamilyWorkspace.self,
            WorkspaceParticipant.self,
            AthleteAccessGrant.self,
        ]
    }
}
