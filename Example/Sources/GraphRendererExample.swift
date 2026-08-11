import SwiftUI
import AVFoundation
import ElementaryAudio
import cxxElementaryAudio

struct GraphRendererExample: View {
    @StateObject private var audioEngine = GraphAudioEngine()

    var body: some View {
        VStack(spacing: 32) {
            Text("Elementary Audio")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("iOS Example")
                .font(.title2)
                .foregroundColor(.secondary)

            Spacer()

            // Frequency control
//            VStack(spacing: 8) {
//                Text("Frequency: \(Int(audioEngine.frequency)) Hz")
//                    .font(.headline)
//
//                Slider(value: $audioEngine.frequency, in: 100...1000) { _ in
//                    audioEngine.updateFrequency()
//                }
//                .tint(.blue)
//            }
//            .padding(.horizontal, 32)

            // Play/Stop button
            Button(action: {
                if audioEngine.isPlaying {
                    audioEngine.stop()
                } else {
                    audioEngine.play()
                }
            }) {
                Image(systemName: audioEngine.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(audioEngine.isPlaying ? .red : .green)
            }

            Text(audioEngine.isPlaying ? "Playing" : "Stopped")
                .font(.headline)
                .foregroundColor(audioEngine.isPlaying ? .green : .secondary)

            Spacer()
        }
        .padding()
    }
}

// Simple audio engine using our library
@MainActor
class GraphAudioEngine: ObservableObject {
    @Published var isPlaying = false

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderer: GraphRenderer

    init() {
        renderer = GraphRenderer()
        setupAudio()
    }

    private func setupAudio() {
        engine = AVAudioEngine()
        sourceNode = renderer.getAudioNode()
        do {
            try renderer.render {
                El.cycle(440.0) * 0.5
            }
        } catch {
            print("Failed to render the audio graph")
        }

        guard let engine = engine else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        if let sourceNode = sourceNode {
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        }
    }

    func play() {
        guard let engine = engine, !isPlaying else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isPlaying = true
        } catch {
            print("Failed to start audio: \(error)")
        }
    }

    func stop() {
        engine?.stop()
        isPlaying = false
    }
}

#Preview {
    CustomNodeExample()
}
