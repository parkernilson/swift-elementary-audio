import SwiftUI

struct ExampleMenuView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Changing Configs") { ChangingConfigsView() }
                NavigationLink("Raw CustomNode Demo") { ContentView() }
            }
            .navigationTitle("Elementary Audio Examples")
        }
    }
}
