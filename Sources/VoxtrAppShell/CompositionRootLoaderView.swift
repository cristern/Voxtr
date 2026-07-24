import SwiftUI
import SwiftData

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
                VStack(spacing: 8) {
                    Text("Vǫxtr couldn't start")
                        .font(.headline)
                    Text(loadError.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard root == nil, loadError == nil else { return }
            do {
                root = try await CompositionRoot.build()
            } catch {
                loadError = error
            }
        }
    }
}
