import AVFoundation

extension GraphRenderer {
    /// Builds an `AVAudioSourceNode` wired to this renderer's own
    /// `render`/`process` pipeline -- the Swift-side counterpart to
    /// `WebRenderer.initialize(audioContext) -> AudioWorkletNode`. Unlike that JS
    /// method, this does not take or touch an `AVAudioEngine`: the caller decides
    /// whether/where to `attach`/`connect` the returned node, and owns
    /// starting/stopping whatever engine it ends up in.
    ///
    /// This reinitializes the shared Elementary runtime at the given sample
    /// rate/block size, discarding any graph previously rendered on this
    /// `GraphRenderer` -- call this before `render(_:)`, not after.
    public func getAudioNode(
        sampleRate: Double = 44100,
        blockSize: Int = 512,
        channels: AVAudioChannelCount = 2
    ) -> AVAudioSourceNode {
        initialize(sampleRate: sampleRate, blockSize: blockSize)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        return AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let outputPtrs: [UnsafeMutablePointer<Float>?] = ablPointer.map {
                $0.mData?.assumingMemoryBound(to: Float.self)
            }
            self.process(outputData: outputPtrs, outputChannels: outputPtrs.count, numSamples: Int(frameCount))
            return noErr
        }
    }
}
