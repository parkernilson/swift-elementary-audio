import AVFoundation

/// Builds an `AVAudioSourceNode` wired to this renderer's own
/// `render`/`process` pipeline -- the Swift-side counterpart to
/// `WebRenderer.initialize(audioContext) -> AudioWorkletNode`. Unlike that JS
/// method, this does not take or touch an `AVAudioEngine`: the caller decides
/// whether/where to `attach`/`connect` the returned node, and owns
/// starting/stopping whatever engine it ends up in.
extension GraphRenderer {
    public func getAudioNode(
        sampleRate: Double = 44100,
        blockSize: Int = 512,
        channels: AVAudioChannelCount = 2
    ) -> AVAudioSourceNode {
        initialize(sampleRate: sampleRate, blockSize: blockSize)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let renderer = self
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let outputPtrs: [UnsafeMutablePointer<Float>?] = ablPointer.map {
                $0.mData?.assumingMemoryBound(to: Float.self)
            }
            renderer.process(outputData: outputPtrs, outputChannels: outputPtrs.count, numSamples: Int(frameCount))
            return noErr
        }

        // Attach and connect the node to an internal audio engine so it properly reports the format
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        return node
    }
}
