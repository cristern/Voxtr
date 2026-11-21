import SwiftUI
import SwiftData
import VoxtrParentAuthentication

/// Builds `CompositionRoot` once, asynchronously, at app launch, and
/// injects the resulting `ModelContainer` into the SwiftUI environment
/// for whatever content view is passed in.
///
/// Both `AthleteApp` and `ParentApp` use this — it's the one place the
/// async composition step happens, so neither app target has to
/// duplicate loading/error-state handling. Sprint 1 (S1.0): this is
/// infrastructure only — the `content` closure still receives whatever
/// placeholder or real view each app target wants to show; this view
/// doesn't know or care what Sprint 1's onboarding UI (S1.4) looks like.
@MainActor
public struct CompositionRootLoaderView<Content: View>: View {
    @State private var root: CompositionRoot?
    @State private var loadError: Error?
    private let content: (CompositionRoot) -> Content

    public init(@ViewBuilder content: @escaping (CompositionRoot) -> Content) {
        self.content = content
    }

    public var body: some View {
        Group {
            if let root {
                content(root)
                    .modelContainer(root.modelContainer)
            } else if let loadError {
                ScrollView {
                    VStack(spacing: 8) {
                        Text("Vǫxtr couldn't start")
                            .font(.headline)
                        // Critical startup diagnostics fix: was
                        // `loadError.localizedDescription` alone —
                        // for a SwiftDataError this was often just
                        // "The operation couldn't be completed.
                        // (SwiftData.SwiftDataError error 1.)", with
                        // no way to diagnose a real TestFlight
                        // failure from feedback alone. See
                        // StartupDiagnostics.swift for exactly what
                        // this now captures.
                        Text(StartupDiagnostics.describe(loadError))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal)
                            .textSelection(.enabled)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard root == nil, loadError == nil else { return }
            do {
                #if DEBUG
                // T1 (issue #122): unchanged local-development path —
                // `CompositionRoot.build()`'s own default parameters
                // (local Supabase Functions port, placeholder gateway
                // key), exactly as before this task. Never reads
                // `HostedBackendConfigurationResolver` or the app
                // bundle's Info.plist at all, so Debug/Simulator/CI
                // native-test builds (which host inside AthleteApp but
                // carry no real hosted configuration) are byte-for-byte
                // unaffected by the Release branch below.
                root = try await CompositionRoot.build()
                #else
                // T1 (issue #122) §4: a physical Release build never
                // silently falls back to the Debug defaults above.
                // Missing/malformed hosted configuration fails closed,
                // legibly, through the SAME `loadError`/`StartupDiagnostics`
                // path any other startup failure already uses — before
                // `CompositionRoot.build()` is ever called, so no
                // Parent/Athlete network call can be attempted with an
                // unreviewed base URL or gateway key.
                switch HostedBackendConfigurationResolver.resolveFromMainBundle() {
                case .success(let values):
                    root = try await CompositionRoot.build(
                        parentAuthenticationConfiguration: ParentAuthenticationConfiguration(baseURL: values.baseURL),
                        athleteDeviceAuthorizationGatewayConfiguration: AthleteDeviceAuthorizationGatewayConfiguration(anonKey: values.anonKey)
                    )
                case .failure(let configurationError):
                    loadError = configurationError
                    return
                }
                #endif
            } catch {
                loadError = error
            }
        }
    }
}
