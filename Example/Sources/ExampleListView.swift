import SwiftUI

enum ExampleType: String, CaseIterable, Identifiable {
    case customNode = "CustomNodeExample"
    case graphRenderer = "GraphRendererExample"

    var id: String { rawValue }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .customNode:
            CustomNodeExample()
        case .graphRenderer:
            GraphRendererExample()
        }
    }
}

struct ExampleListView: View {
    var body: some View {
        NavigationStack {
            List(ExampleType.allCases) { example in
                NavigationLink(example.rawValue, destination: example.destination)
            }
            .navigationTitle("Examples")
        }
    }
}

#Preview {
    ExampleListView()
}
