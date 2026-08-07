import SwiftUI
import AVFoundation
import ElementaryAudio

/// Cycles through a handful of `AudioGraph` configurations on each button
/// press so the graph reconciliation engine's behavior can be heard
/// directly: a keyed value change updates the running oscillator in place
/// (no pop), while a structurally different node forces a full rebuild.
@MainActor
private final class ToneEngine: ObservableObject {
    let configurations: [(label: String, build: () -> AudioGraph)] = [
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 440.0)) * 0.3 } }
        ),
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 660)) * 0.3  — keyed value change",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 660.0)) * 0.3 } }
        ),
        (
            label: "El.blepsquare(440.0) * 0.3  — structurally different",
            build: { AudioGraph { El.blepsquare(440.0) * 0.3 } }
        ),
        (
            label: "El.cycle(El.const(key: \"frequency\", value: 440)) * 0.3  — back to config 1's shape",
            build: { AudioGraph { El.cycle(El.const(key: "frequency", value: 440.0)) * 0.3 } }
        ),
    ]

    @Published private(set) var currentConfigIndex = 0

    private let engine = AVAudioEngine()
    private let renderer = GraphRenderer()
    private var sourceNode: AVAudioSourceNode?

    init() {
        let node = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 1)
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))

        do {
            try renderer.render(configurations[currentConfigIndex].build())
        } catch {
            print("[ToneEngine] render failed: \(error)")
        }
    }

    func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            print("[ToneEngine] failed to start: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }

    func advanceConfiguration() {
        let next = (currentConfigIndex + 1) % configurations.count
        do {
            try renderer.render(configurations[next].build())
            currentConfigIndex = next
        } catch {
            print("[ToneEngine] render failed: \(error)")
        }
    }
}

struct ChangingConfigsView: View {
    @StateObject private var toneEngine = ToneEngine()

    var body: some View {
        VStack(spacing: 12) {
            Text("Tap Next to cycle graph configurations")
                .font(.headline)
            Text(toneEngine.configurations[toneEngine.currentConfigIndex].label)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Next Configuration") {
                toneEngine.advanceConfiguration()
            }
            .padding(.top, 8)
        }
        .padding()
        .navigationTitle("Changing Configs")
        .onAppear { toneEngine.start() }
        .onDisappear { toneEngine.stop() }
    }
}
