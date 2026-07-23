import SwiftUI
import VoxtrCore

/// Sprint 0's entire UI: a list proving every domain module registered
/// successfully. No dashboards, no planning UI, no reflections screen —
/// those are explicitly excluded by 05_Sprint0_Specification. This view
/// exists to satisfy the "navigation shell" deliverable and to give a
/// human a way to see Sprint 0 running on a device/simulator.
public struct NavigationShellView: View {
    private let moduleIDs: [String]

    public init(moduleIDs: [String] = ModuleRegistry.allModules().map { type(of: $0).domainID }) {
        self.moduleIDs = moduleIDs
    }

    public var body: some View {
        NavigationStack {
            List(moduleIDs, id: \.self) { id in
                Label(id.capitalized, systemImage: "shippingbox")
            }
            .navigationTitle("Vǫxtr — Sprint 0")
        }
    }
}

#Preview {
    NavigationShellView()
}
