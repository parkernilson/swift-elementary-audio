import AVFoundation
import cxxElementaryAudio
@testable import ElementaryAudio
import XCTest

final class GraphRendererAudioNodeTests: XCTestCase {
    private var renderer: GraphRenderer!

    override func setUp() {
        super.setUp()
        renderer = GraphRenderer()
    }

    override func tearDown() {
        renderer.reset()
        renderer = nil
        super.tearDown()
    }

    func testGetAudioNodeReturnsNodeWithRequestedFormat() {
        let node = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)

        // AVAudioSourceNode only reports its constructed format once attached and
        // connected to an audio engine. We do this here in the test to observe the format.
        // GraphRenderer.getAudioNode itself must never do this (per design constraint).
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let nodeFormat = node.outputFormat(forBus: 0)
        XCTAssertEqual(nodeFormat.sampleRate, 48000)
        XCTAssertEqual(nodeFormat.channelCount, 1)
    }

    func testRenderAndProcessStillWorkAfterGetAudioNode() throws {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 1)

        let graph = AudioGraph { El.cycle(440.0) }
        try renderer.render(graph)

        var foundNonZero = false
        for _ in 0 ..< 4 {
            let samples = processBlock(numSamples: 512)
            let maxAmp = samples.map { Swift.abs($0) }.max() ?? 0
            if maxAmp > 0.1 {
                foundNonZero = true
                XCTAssertLessThanOrEqual(maxAmp, 1.0)
                break
            }
        }
        XCTAssertTrue(foundNonZero, "audio should still play via process() after getAudioNode's internal initialize() call")
    }

    func testCallingGetAudioNodeTwiceDoesNotCrash() {
        _ = renderer.getAudioNode(sampleRate: 44100, blockSize: 512, channels: 2)
        _ = renderer.getAudioNode(sampleRate: 48000, blockSize: 256, channels: 1)
    }

    // MARK: - Helpers

    private func processBlock(numSamples: Int) -> [Float] {
        var outputBuffer = [Float](repeating: 0, count: numSamples)
        outputBuffer.withUnsafeMutableBufferPointer { bufPtr in
            var channelPtr: UnsafeMutablePointer<Float>? = bufPtr.baseAddress
            withUnsafeMutablePointer(to: &channelPtr) { channelPtrPtr in
                renderer.process(
                    outputData: channelPtrPtr,
                    outputChannels: 1,
                    numSamples: numSamples
                )
            }
        }
        return outputBuffer
    }
}
